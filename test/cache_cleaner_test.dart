import 'dart:io';

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/core/services/cache_cleaner.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SessionRepository repo;
  late Directory root;
  late Directory docs;
  late Directory temp;
  late CacheCleaner cleaner;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = SessionRepository(db);
    root = await Directory.systemTemp.createTemp('cache_cleaner_test');
    docs = Directory('${root.path}/docs')..createSync();
    temp = Directory('${root.path}/tmp')..createSync();
    cleaner = CacheCleaner(repo);
  });

  tearDown(() async {
    await db.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// Writes a sparse file of [size] bytes (no 16 MB allocation).
  File writeFile(String path, int size) {
    final f = File(path)..createSync(recursive: true);
    final raf = f.openSync(mode: FileMode.write);
    raf.truncateSync(size);
    raf.closeSync();
    return f;
  }

  MessageModel message({
    String? id,
    String text = 'hello',
    bool isSentByMe = false,
    String? imagePath,
    String? transferKind,
    String? delivery,
  }) =>
      MessageModel(
        id: id,
        text: text,
        isSentByMe: isSentByMe,
        timestamp: DateTime(2026, 10, 10, 12),
        imagePath: imagePath,
        transferKind: transferKind,
        delivery: delivery,
      );

  Future<void> save(List<MessageModel> messages) => repo.saveChatSession(
        ChatSessionModel(
          id: 'peer-1',
          name: 'Redmi',
          createdAt: DateTime(2026, 10, 10, 10),
          updatedAt: DateTime(2026, 10, 10, 11),
          messages: messages,
          device: const {'name': 'Redmi', 'address': 'AA:BB:CC:DD:EE:FF'},
          transport: 'bt',
        ),
      );

  test('referenced media is deleted and reset to a re-downloadable '
      'placeholder', () async {
    final file = writeFile('${docs.path}/111.jpg', 1000);
    await save([
      message(id: 'm1', text: '[Image] (1000 bytes)', imagePath: file.path),
    ]);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(file.existsSync(), isFalse);
    final loaded = await repo.loadChatSession('peer-1');
    final m = loaded!.messages.single;
    expect(m.imagePath, isNull);
    expect(m.remoteMediaSize, 1000);
    expect(m.hasRemoteMedia, isTrue);
    expect(m.text, '[Image] (1000 bytes)');
    expect(result.freedBytes, 1000);
    expect(result.filesDeleted, 1);
    expect(result.messagesReset, 1);
  });

  test('media beyond the fetch cap is kept on disk and untouched', () async {
    final big = writeFile(
      '${docs.path}/big.bin',
      CacheCleaner.refetchableMediaBytes + 1,
    );
    await save([
      message(
        id: 'm2',
        imagePath: big.path,
        transferKind: 'file',
        text: '[File] big.bin',
      ),
    ]);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(big.existsSync(), isTrue);
    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.messages.single.imagePath, big.path);
    expect(result.freedBytes, 0);
    expect(result.messagesReset, 0);
  });

  test('sent media without a delivered ack is kept; the delivered copy is '
      'cleared', () async {
    final pending = writeFile('${docs.path}/p.jpg', 2000);
    final delivered = writeFile('${docs.path}/d.jpg', 3000);
    await save([
      message(
        id: 'm3',
        isSentByMe: true,
        imagePath: pending.path,
        delivery: MessageModel.deliverySent,
      ),
      message(
        id: 'm4',
        isSentByMe: true,
        imagePath: delivered.path,
        delivery: MessageModel.deliveryDelivered,
      ),
    ]);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(pending.existsSync(), isTrue);
    expect(delivered.existsSync(), isFalse);
    final loaded = await repo.loadChatSession('peer-1');
    MessageModel byId(String id) =>
        loaded!.messages.firstWhere((m) => m.id == id);
    expect(byId('m3').imagePath, pending.path);
    expect(byId('m3').delivery, MessageModel.deliverySent);
    expect(byId('m4').imagePath, isNull);
    expect(byId('m4').remoteMediaSize, 3000);
    // Delivery state survives the placeholder reset (the tick stays
    // meaningful if the file ever comes back from the peer).
    expect(byId('m4').delivery, MessageModel.deliveryDelivered);
    expect(result.messagesReset, 1);
    expect(result.freedBytes, 3000);
  });

  test('orphan media is swept; the database file and protected files stay',
      () async {
    // Orphans: media from deleted chats.
    writeFile('${docs.path}/orphan.jpg', 500);
    writeFile('${docs.path}/1234567890123_report.pdf', 700);
    writeFile('${docs.path}/received/old.bin', 900);
    // Non-media root files must never be touched.
    writeFile('${docs.path}/chatblue.sqlite', 123);
    writeFile('${docs.path}/notes.txt', 456);
    // A protected (over-cap) received file survives the received/ sweep.
    final huge = writeFile(
      '${docs.path}/received/huge.bin',
      CacheCleaner.refetchableMediaBytes + 1,
    );
    await save([
      message(
        id: 'm5',
        imagePath: huge.path,
        transferKind: 'file',
        text: '[File] huge.bin',
      ),
    ]);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(File('${docs.path}/orphan.jpg').existsSync(), isFalse);
    expect(File('${docs.path}/1234567890123_report.pdf').existsSync(), isFalse);
    expect(File('${docs.path}/received/old.bin').existsSync(), isFalse);
    expect(File('${docs.path}/chatblue.sqlite').existsSync(), isTrue);
    expect(File('${docs.path}/notes.txt').existsSync(), isTrue);
    expect(huge.existsSync(), isTrue);
    expect(result.freedBytes, 500 + 700 + 900);
  });

  test('temp directory is emptied (open/share copies and picker temps)',
      () async {
    writeFile('${temp.path}/open/doc.pdf', 400);
    writeFile('${temp.path}/picked.jpg', 600);
    writeFile('${temp.path}/nested/deeper/x.tmp', 1000);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(temp.listSync(), isEmpty);
    expect(result.freedBytes, 400 + 600 + 1000);
    expect(result.filesDeleted, 3); // doc.pdf, picked.jpg, x.tmp
  });

  test('a protected message file inside the temp dir survives the sweep',
      () async {
    // A picked file (content provider) can live in the app's cache dir;
    // an undelivered sent message must keep it even though everything
    // else under temp is cache.
    final picked = writeFile('${temp.path}/file_picker/notes.pdf', 4000);
    await save([
      message(
        id: 'm7',
        isSentByMe: true,
        imagePath: picked.path,
        transferKind: 'file',
        delivery: MessageModel.deliverySent,
        text: '[File] notes.pdf',
      ),
    ]);
    writeFile('${temp.path}/open/junk.bin', 500);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(picked.existsSync(), isTrue);
    final loaded = await repo.loadChatSession('peer-1');
    final m = loaded!.messages.single;
    expect(m.imagePath, picked.path); // Row untouched — file still there.
    expect(m.delivery, MessageModel.deliverySent);
    expect(File('${temp.path}/open/junk.bin').existsSync(), isFalse);
    // The emptied shell around the kept file is pruned; the shell that
    // still holds it stays.
    expect(Directory('${temp.path}/open').existsSync(), isFalse);
    expect(Directory('${temp.path}/file_picker').existsSync(), isTrue);
    expect(result.freedBytes, 500);
    expect(result.messagesReset, 0);
  });

  test('a path outside the app directories is never touched (public file)',
      () async {
    // A file-picker result can point at the user's original in public
    // storage — deleting it would destroy data the app never owned.
    final public = writeFile('${root.path}/public/photo.jpg', 2000);
    await save([
      message(
        id: 'm8',
        isSentByMe: true,
        imagePath: public.path,
        delivery: MessageModel.deliveryDelivered,
      ),
    ]);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    expect(public.existsSync(), isTrue);
    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.messages.single.imagePath, public.path);
    expect(result.freedBytes, 0);
    expect(result.messagesReset, 0);
  });

  test('voice placeholders keep their duration caption and audio kind',
      () async {
    final voice = writeFile('${docs.path}/222.m4a', 5000);
    await save([
      message(
        id: 'm6',
        text: '0:12',
        imagePath: voice.path,
        transferKind: 'audio',
      ),
    ]);

    await cleaner.clearIn(docs: docs, temp: temp);

    final loaded = await repo.loadChatSession('peer-1');
    final m = loaded!.messages.single;
    expect(m.imagePath, isNull);
    expect(m.remoteMediaSize, 5000);
    expect(m.transferKind, 'audio');
    expect(m.text, '0:12');
    expect(m.isAudio, isTrue);
    expect(m.hasRemoteMedia, isTrue);
  });

  test('a second pass finds nothing to clear', () async {
    writeFile('${docs.path}/111.jpg', 1000);
    await save([
      message(id: 'm1', imagePath: '${docs.path}/111.jpg'),
    ]);

    final first = await cleaner.clearIn(docs: docs, temp: temp);
    final second = await cleaner.clearIn(docs: docs, temp: temp);

    expect(first.freedBytes, 1000);
    expect(second.freedBytes, 0);
    expect(second.messagesReset, 0);
    expect(second.filesDeleted, 0);
  });

  test('a row whose file is already gone is flipped to a size-less '
      'placeholder (device-reported: no placeholder appeared for an audio '
      'file orphaned by an older pass)', () async {
    // The path references a file that does not exist (deleted by an earlier
    // cleanup round while its row kept the reference).
    await save([
      message(
        id: 'm9',
        text: '0:18',
        imagePath: '${docs.path}/ghost.m4a',
        transferKind: 'audio',
      ),
    ]);

    final result = await cleaner.clearIn(docs: docs, temp: temp);

    final loaded = await repo.loadChatSession('peer-1');
    final m = loaded!.messages.single;
    expect(m.imagePath, isNull,
        reason: 'a dead reference must become a placeholder — not stay a '
            'playable bubble that can never resolve');
    expect(m.remoteMediaSize, 0, reason: 'unknown size sentinel');
    expect(m.hasRemoteMedia, isTrue);
    expect(m.transferKind, 'audio');
    expect(m.text, '0:18');
    expect(result.messagesReset, 1);
    expect(result.freedBytes, 0, reason: 'nothing was on disk to free');

    // The next pass is a no-op: the row is already a placeholder.
    final second = await cleaner.clearIn(docs: docs, temp: temp);
    expect(second.messagesReset, 0);
  });
}
