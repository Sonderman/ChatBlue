// Storage maintenance for Settings → Clear cache: deletes local media
// copies (turning their bubbles into deferred-download placeholders),
// sweeps orphaned media files and empties the temporary directory.
//
// Safety rules (deliberate — see the feature design):
// - only the app's OWN copies are touched: a picked file can live in
//   public storage (the bubble points at the user's original) or in the
//   picker cache, and paths outside the app's documents/temp dirs are
//   NEVER touched;
// - the database is reset to the placeholder state BEFORE any file is
//   deleted: a pass interrupted mid-way leaves at worst an orphan file
//   (swept below) — never a message referencing a missing file;
// - media over the sync protocol's 16 MB fetch cap is KEPT: it could
//   never be re-downloaded from the peer;
// - sent media without a `delivered` ack is KEPT: the peer may not hold
//   a copy, so removing the file would destroy it permanently — this
//   protection also covers a picked file that lives inside the app's
//   cache directory;
// - the database rows (chat history, sessions, settings, device id) are
//   never deleted.

import 'dart:io';

import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Outcome of a cache-clear pass.
class CacheClearResult {
  const CacheClearResult({
    required this.freedBytes,
    required this.filesDeleted,
    required this.messagesReset,
  });

  /// Bytes reclaimed across media and temp files.
  final int freedBytes;

  /// Files removed from disk.
  final int filesDeleted;

  /// Message rows converted to re-downloadable placeholders.
  final int messagesReset;
}

/// Deletes the app's cache: local media copies, orphaned media files and
/// the temp directory. Chat history and settings stay intact.
class CacheCleaner {
  CacheCleaner(this._repo);

  final SessionRepository _repo;

  /// The sync protocol's fetch cap (`_syncMaxFetchBytes` in the chat
  /// controller): media larger than this cannot be re-downloaded, so it is
  /// never deleted here.
  static const int refetchableMediaBytes = 16 * 1024 * 1024;

  /// Runs the pass against the app's real directories.
  Future<CacheClearResult> clearCache() async {
    final docs = await getApplicationDocumentsDirectory();
    final temp = await getTemporaryDirectory();
    return clearIn(docs: docs, temp: temp);
  }

  /// Test seam: the pass against explicit directories.
  @visibleForTesting
  Future<CacheClearResult> clearIn({
    required Directory docs,
    required Directory temp,
  }) async {
    var freedBytes = 0;
    var filesDeleted = 0;

    // 1) Referenced media: decide what may go, write the placeholder state
    // FIRST (each row keeps its byte size so the bubble can re-fetch), and
    // only then delete the files. Reset-before-delete is the crash-safe
    // order: a pass interrupted after the reset leaves an orphan file
    // (picked up by the sweeps below or the next run), never a live
    // message pointing at a missing file.
    final media = await _repo.messagesWithLocalMedia();
    final keep = <String>{};
    final sizes = <String, int>{};
    final toDelete = <String>[];
    final resets = <({String id, int size})>[];

    for (final m in media) {
      final path = m.imagePath;
      if (path == null) continue;
      final id = m.id;
      if (id == null || id.isEmpty) {
        // Cannot reset the row — keep its file rather than orphan it.
        keep.add(path);
        continue;
      }
      final size = await _fileSize(path);
      if (size == null) {
        // File already gone — the placeholder flip is the only repair
        // left: without it the bubble keeps rendering as playable/openable
        // media that can never resolve (device-reported: "cache
        // temizliğinden sonra mevcut chatdeki ses dosyası için placeholder
        // görünmüyor" — rows orphaned by an older pass stayed broken
        // forever). The keep rules are moot (there is no file to protect);
        // the size is unknown now — 0 is the "unknown" sentinel (the
        // bubble shows the size-less hint; the fetch resolves by id).
        resets.add((id: id, size: 0));
        continue;
      }
      if (!_isInside(path, docs) && !_isInside(path, temp)) {
        // Not the app's own copy (a picked file in public storage) —
        // deleting it would destroy the user's original.
        keep.add(path);
        continue;
      }
      if (size > refetchableMediaBytes) {
        keep.add(path);
        continue;
      }
      if (m.isSentByMe && m.delivery != MessageModel.deliveryDelivered) {
        keep.add(path);
        continue;
      }
      sizes[path] = size;
      toDelete.add(path);
      resets.add((id: id, size: size));
    }

    if (resets.isNotEmpty) {
      await _repo.markMediaAsRemote(resets);
    }
    for (final path in toDelete) {
      try {
        await File(path).delete();
        freedBytes += sizes[path] ?? 0;
        filesDeleted++;
      } catch (_) {
        // Left behind — an in-scope path is retried by the sweeps below.
      }
    }

    // 2) Orphan sweep: media files no message references (leftovers of
    // deleted chats used to accumulate forever). `received/` is scooped
    // whole; the documents root is swept for media extensions and
    // timestamp-built names only — the database, the asset bundle and
    // protected files stay.
    Future<void> sweepFlat(
      Directory dir,
      bool Function(String name) matches,
    ) async {
      if (!await dir.exists()) return;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (!matches(name)) continue;
        if (keep.contains(e.path)) continue;
        final size = await _fileSize(e.path);
        try {
          await e.delete();
        } catch (_) {
          continue;
        }
        freedBytes += size ?? 0;
        filesDeleted++;
      }
    }

    final received = Directory('${docs.path}${Platform.pathSeparator}received');
    await sweepFlat(received, (_) => true);
    await sweepFlat(docs, _looksLikeManagedMedia);

    // 3) The temp directory: everything inside is cache by definition
    // (file-share `open/` copies, picker temporaries, plugin scratch) —
    // EXCEPT the files of protected messages (e.g. an undelivered sent
    // file picked from a content provider can live in the picker's cache
    // subdirectory): those are skipped and their directory shells stay.
    Future<void> sweepTemp(Directory dir) async {
      if (!await dir.exists()) return;
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) {
          if (keep.contains(e.path)) continue;
          final size = await _fileSize(e.path);
          try {
            await e.delete();
          } catch (_) {
            continue;
          }
          freedBytes += size ?? 0;
          filesDeleted++;
        } else if (e is Directory) {
          await sweepTemp(e);
          try {
            // Fails while a protected file remains inside — the shell then
            // stays, which is what keeps that file reachable.
            await e.delete();
          } catch (_) {}
        }
      }
    }

    await sweepTemp(temp);

    return CacheClearResult(
      freedBytes: freedBytes,
      filesDeleted: filesDeleted,
      messagesReset: resets.length,
    );
  }

  /// True when [path] lives inside [dir] — the app's own storage areas.
  static bool _isInside(String path, Directory dir) {
    final prefix = dir.path.endsWith(Platform.pathSeparator)
        ? dir.path
        : '${dir.path}${Platform.pathSeparator}';
    return path.startsWith(prefix);
  }

  /// Root-level names this app manages: timestamped media (`<ms>.jpg` /
  /// `<ms>.m4a`) and timestamp-materialized copies (`<ms>_name.ext`).
  static bool _looksLikeManagedMedia(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.m4a') ||
        RegExp(r'^\d{10,16}_').hasMatch(name);
  }

  static Future<int?> _fileSize(String path) async {
    final file = File(path);
    try {
      if (!await file.exists()) return null;
      return (await file.stat()).size;
    } catch (_) {
      return null;
    }
  }
}
