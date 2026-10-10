import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/format_utils.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/location_message.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/core/platform/util_platform_channel.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/screens/chat_ui/connection_notice.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

typedef _ImageWriteJob = ({String path, Uint8List bytes});

/// Writes image bytes to disk on a background isolate so large payloads
/// don't jank the UI thread.
Future<void> _writeBytesToFile(_ImageWriteJob job) async {
  await File(job.path).writeAsBytes(job.bytes);
}

enum _SendKind { text, bytes }

/// A queued outgoing payload. Text jobs write one string; bytes jobs are
/// full image transfers (their progress bubbles are driven by transport
/// progress callbacks while the job is active).
class _OutgoingJob {
  _OutgoingJob.text(String this.text)
      : kind = _SendKind.text,
        bytes = null,
        imagePath = null,
        audioText = null,
        fileName = null;

  _OutgoingJob.bytes(
    Uint8List this.bytes,
    this.imagePath, {
    this.audioText,
    this.fileName,
  })  : kind = _SendKind.bytes,
        text = null;

  final _SendKind kind;
  final String? text;
  final Uint8List? bytes;
  final String? imagePath;

  /// When set, the transferred bytes are a voice recording and the bubble
  /// finalizes as an audio message with this duration caption.
  final String? audioText;

  /// When set, the transferred bytes are a FILE with this name: an
  /// announcement frame (name+size) precedes the bytes and the bubble
  /// finalizes as a file message.
  final String? fileName;
}

/// Identifies one chat open: the transport plus (for home-list opens) the
/// stored session. Identity equality — the screen keeps ONE instance in its
/// State, so every open gets a fresh notifier (matching the old per-open
/// GetX registration semantics) and autoDispose tears it down on route pop.
class ChatOpenArg {
  ChatOpenArg({required this.transport, this.session});

  /// One of [ChatSessionModel.transportBluetooth] /
  /// [ChatSessionModel.transportWifiDirect] / [ChatSessionModel.transportNearby].
  final String transport;

  /// Seeded session for home-list opens; null for scan/incoming opens (the
  /// session is then reconstructed from the live transport identity).
  final ChatSessionModel? session;
}

/// High-frequency playback surface of the single voice player — kept OUT of
/// [ChatState] so position ticks never rebuild the message list.
class AudioPlaybackState {
  const AudioPlaybackState({
    this.playingId,
    this.playing = false,
    this.progress = 0,
    this.durationMs = 0,
  });

  /// Id of the audio bubble currently playing (null when idle).
  final String? playingId;

  /// Mirror of the player's playing state (drives play/pause icons).
  final bool playing;

  /// 0..1 playback position of the playing bubble.
  final double progress;

  /// Duration of the loaded track in milliseconds (0 when nothing loaded).
  final double durationMs;
}

const Object _sentinel = Object();

/// Per-chat-open link counters feeding the connection-quality panel: byte
/// and frame totals in both directions plus a short sliding window whose
/// rate is computed at read time (the panel's 1 s ticker re-reads it — the
/// stats own no timers).
class LinkStats {
  int bytesIn = 0;
  int bytesOut = 0;
  int framesIn = 0;
  int framesOut = 0;

  static const Duration _rateWindow = Duration(seconds: 5);
  final List<({DateTime at, int bytes})> _samples = [];

  void recordIn(int bytes) {
    bytesIn += bytes;
    framesIn++;
    final now = DateTime.now();
    _samples.add((at: now, bytes: bytes));
    _prune(now);
  }

  void recordOut(int bytes) {
    bytesOut += bytes;
    framesOut++;
    final now = DateTime.now();
    _samples.add((at: now, bytes: bytes));
    _prune(now);
  }

  /// Bytes/second over the last [_rateWindow]. [now] is injectable so tests
  /// can age the window without sleeping.
  double currentBytesPerSecond({DateTime? now}) {
    final at = now ?? DateTime.now();
    _prune(at);
    var sum = 0;
    for (final s in _samples) {
      sum += s.bytes;
    }
    return sum / _rateWindow.inSeconds;
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(_rateWindow);
    while (_samples.isNotEmpty && _samples.first.at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }
}

/// Immutable chat-session UI state — the Rx fields of the old
/// `ChatScreenControllerBase` as one value.
class ChatState {
  const ChatState({
    required this.chatSession,
    required this.messages,
    this.peerName = '',
    this.isConnecting = false,
    this.isSyncing = false,
    this.syncProgress = 0,
    this.isRecording = false,
    this.recordSeconds = 0,
    this.isConnected = false,
    this.linkPanelVisible = false,
    this.outgoingTransfer,
    this.incomingTransfer,
  });

  final ChatSessionModel chatSession;
  final List<MessageModel> messages;

  /// Peer-reported device name (WFD peers don't carry a name on the socket);
  /// drives the app bar title reactively when the transport has no name.
  final String peerName;

  /// True while a manual reconnect (Connect button) attempt is in flight.
  final bool isConnecting;

  /// Visible while a history sync packet is being received/applied.
  final bool isSyncing;

  /// 0..1 progress of the incoming sync frame (drives the thin header bar).
  final double syncProgress;

  final bool isRecording;
  final int recordSeconds;

  /// Transport connection mirror (binding signals keep it fresh).
  final bool isConnected;

  /// Connection-quality strip visibility (persisted in the settings store;
  /// default hidden — the app bar icon toggles it).
  final bool linkPanelVisible;

  final TransferState? outgoingTransfer;
  final TransferState? incomingTransfer;

  /// True while either an outgoing or incoming byte transfer is in flight.
  bool get hasActiveTransfer {
    bool active(TransferState? s) =>
        s != null && s.total > 0 && s.current < s.total;
    return active(outgoingTransfer) || active(incomingTransfer);
  }

  ChatState copyWith({
    ChatSessionModel? chatSession,
    List<MessageModel>? messages,
    String? peerName,
    bool? isConnecting,
    bool? isSyncing,
    double? syncProgress,
    bool? isRecording,
    int? recordSeconds,
    bool? isConnected,
    bool? linkPanelVisible,
    Object? outgoingTransfer = _sentinel,
    Object? incomingTransfer = _sentinel,
  }) {
    return ChatState(
      chatSession: chatSession ?? this.chatSession,
      messages: messages ?? this.messages,
      peerName: peerName ?? this.peerName,
      isConnecting: isConnecting ?? this.isConnecting,
      isSyncing: isSyncing ?? this.isSyncing,
      syncProgress: syncProgress ?? this.syncProgress,
      isRecording: isRecording ?? this.isRecording,
      recordSeconds: recordSeconds ?? this.recordSeconds,
      isConnected: isConnected ?? this.isConnected,
      linkPanelVisible: linkPanelVisible ?? this.linkPanelVisible,
      outgoingTransfer: identical(outgoingTransfer, _sentinel)
          ? this.outgoingTransfer
          : outgoingTransfer as TransferState?,
      incomingTransfer: identical(incomingTransfer, _sentinel)
          ? this.incomingTransfer
          : incomingTransfer as TransferState?,
    );
  }
}

/// Riverpod port of `ChatScreenControllerBase`: the single implementation of
/// the conversation logic (messages, image/voice transfers, persistence,
/// history sync, send queue) shared by all three chat screens.
///
/// Family + autoDispose: one instance per chat open. `close()` mirrors the
/// old `onClose` exactly and runs synchronously from the screen's dispose
/// (the same deterministic ordering the old GetX delete→onClose had),
/// with `ref.onDispose` as an idempotent backup.
final chatControllerProvider =
    NotifierProvider.family<ChatController, ChatState, ChatOpenArg>(
  ChatController.new,
  isAutoDispose: true,
);

class ChatController extends Notifier<ChatState>
    implements ChatTransportListener {
  ChatController(this._arg);

  final ChatOpenArg _arg;

  late final ChatTransportBinding _binding;

  /// Captured at build time: `close()` may run inside `ref.onDispose`,
  /// where using `ref` is forbidden — the repository must not be reached
  /// through it.
  late final SessionRepository _repo;

  final TextEditingController textController = TextEditingController();

  /// Playback surface (ValueListenableBuilder in the audio bubble).
  final ValueNotifier<AudioPlaybackState> audioPlayback =
      ValueNotifier(const AudioPlaybackState());

  /// Connection-quality panel counters (per-open traffic + rolling rate).
  final LinkStats linkStats = LinkStats();

  /// Wall-clock start of the CURRENT link (null while disconnected): drives
  /// the panel's uptime label; re-set on every (re)connection.
  DateTime? _connectedSince;

  // ── Voice messages ──────────────────────────────────────────────────────
  Timer? _recordTimer;
  AudioRecorder? _recorder;
  String? _recordingPath;
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// Duration caption of an incoming voice transfer (announced by the peer
  /// right before the bytes arrive).
  String? _pendingAudioMeta;

  /// When set, the outgoing byte transfer is a voice recording; used to
  /// finalize its bubble as an audio message.
  String? _pendingOutgoingAudioText;

  /// When set, the incoming bytes are a FILE: the announcement frame
  /// carries the original name (JSON) — same lifecycle as [_pendingAudioMeta]
  /// (cleared on disconnect/teardown so a dead announcement cannot misroute
  /// the next connection's first bytes).
  String? _pendingIncomingFileMeta;

  /// When set, the outgoing byte transfer is a file with this name: an
  /// announcement frame rides before the bytes and the bubble finalizes as
  /// a file message.
  String? _pendingOutgoingFileText;

  // Progress bubbles are tracked by message id (bubble UUID) instead of list
  // index, so concurrent in/out transfers can never corrupt each other.
  String? _outgoingProgressId;
  String? _incomingProgressId;

  /// A bytes transfer that stops producing progress events is dead — a BT
  /// link can die silently (or a frame's tail / a single platform-channel
  /// event can be lost) and nothing else ever resolves the bubble: the user
  /// is left staring at an eternal "100%" that the rounding produces even at
  /// 99.5%. One watchdog per direction; every bytes progress event re-arms
  /// its timer, a fire converts the stuck bubble into a visible failure.
  /// Overridable in tests (the suite runs with milliseconds, not 20 s).
  @visibleForTesting
  static Duration transferStallTimeout = const Duration(seconds: 20);

  /// Delay before the signal-read request is re-sent once (the peer's chat
  /// may open a beat after ours). Test-overridable like the stall timeout.
  static Duration linkShareRetryDelay = const Duration(milliseconds: 2500);

  /// Outgoing FILE cap: the transports carry whole frames in memory, so
  /// this keeps both sides' RAM sane (images ride compressed, far below).
  /// Overridable in tests (20 MB on device).
  @visibleForTesting
  static int maxFileBytes = 20 * 1024 * 1024;
  Timer? _incomingStallTimer;
  Timer? _outgoingStallTimer;

  /// True while the current INCOMING bytes transfer has been declared dead
  /// (watchdog fired / persist failed). Suppresses ghost progress bubbles
  /// from a late trickle of the same stale frame; cleared when a fresh
  /// frame starts (its first progress event reads ≤ one accumulation
  /// window) or when the data event arrives late and resurrects the bubble.
  bool _incomingTransferFailed = false;

  /// Same for OUTGOING: set when the transfer was declared dead, cleared
  /// when a new bytes job starts draining (see the guard in
  /// [_updateOutgoingProgress] — a late unblocking write used to recreate
  /// the bubble the watchdog had just failed).
  bool _outgoingTransferFailed = false;

  // Holds bytes for the currently sending image to convert the progress
  // bubble into a final image message.
  Uint8List? _pendingOutgoingBytes;
  String? _sendingImagePath;

  // Debounces session writes during message bursts (text/image/traffic storms).
  Timer? _saveDebounce;

  // History sync between previously-chatting peers:
  // - The prefix makes sync packets distinguishable from plain chat text.
  static const String _syncPrefix = '@@CHATBLUE_SYNC@@';

  // Voice-message announcement prefix (duration meta sent before the bytes).
  static const String _audioPrefix = '@@CHATBLUE_AUDIO@@';

  // File-transfer announcement prefix (name+size meta sent before bytes).
  static const String _filePrefix = '@@CHATBLUE_FILE@@';

  /// Voice recordings are cut off (and sent) automatically at this length.
  static const int _maxRecordSeconds = 120;

  // A sync packet is sent once per (re)connection.
  static const int _syncHistoryCount = 10;

  // One history sync per connection: re-armed on every disconnect.
  bool _syncSentForSession = false;

  /// Peer's data-plane protocol version (from its sync manifest; null until
  /// one arrives). File sharing needs >= 2 — a peer that reported 1 (or an
  /// older build whose manifest has no `pv` field) cannot render the
  /// announcement/bytes pair, so files are blocked for it.
  int? _peerPv;

  /// Scan-time RSSI the peer shared over the sync channel (the accepting
  /// side never scanned, so this is the only reading it can show).
  int? _peerReportedRssi;
  Timer? _linkShareRetry;

  // True when this chat open created a BRAND-NEW session because the peer
  // identity was not (fully) known yet (rotated MAC / identity frame still
  // in flight). A late identity frame then re-checks for a stored session
  // of the same peer and merges it in (see _mergeLatePeerSession).
  bool _openedAsFreshSession = false;
  bool _lateMergeDone = false;

  // Serializes outgoing sends: while a byte transfer (image) is in flight,
  // any further text/image send is queued and only dispatched once the
  // current transfer completes. This keeps the wire order FIFO and prevents
  // two transfers from clobbering each other's progress state.
  final List<_OutgoingJob> _sendQueue = <_OutgoingJob>[];
  bool _sendJobActive = false;

  /// Media up to this size rides along with the history sync automatically;
  /// larger payloads sync as a placeholder only (a size marker) and are
  /// fetched from the peer when the user taps download.
  static const int _syncInlineMediaBytes = 512 * 1024;

  /// Payloads above this are never offered for download (they keep only
  /// their caption): a single JSON frame should never carry absurdly large
  /// files.
  static const int _syncMaxFetchBytes = 16 * 1024 * 1024;

  /// Image payloads larger than this are not embedded in the history sync
  /// (they fall back to their text caption; a fresh transfer can always be
  /// requested manually). Frames are length-prefixed on both transports and
  /// written in 8 KB chunks, so multi-MB payloads are fine. Also the
  /// hashing cutoff: bigger media hashes by its caption text.
  static const int _syncMaxImageBytes = 3 * 1024 * 1024;

  /// Incoming text frames at or above this size are treated as history sync
  /// packets for the thin progress bar under the app bar (plain messages
  /// are far smaller).
  static const int _syncProgressThreshold = 4 * 1024;

  // ── Deferred media download (sync placeholders) ────────────────────────
  // Large media syncs as a placeholder only (kind + size); the file is
  // fetched from the peer on tap. One watchdog per requested id keeps a
  // lost reply from leaving the bubble spinning forever.
  final Map<String, Timer> _fetchWatchdogs = <String, Timer>{};

  // Seed bookkeeping for transport-reconstructed opens (set in [build]).
  String? _seedKey;
  bool _seedMacUsable = false;

  /// True once [close] ran — guards every post-await state write (Riverpod
  /// throws on a disposed notifier where the old GetX controller silently
  /// accepted writes).
  bool _closed = false;

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  ChatState build() {
    _binding = ref.read(chatBindingProvider(_arg.transport));
    _repo = ref.read(sessionRepositoryProvider);
    _binding.addListener(this);
    ref.onDispose(_disposeSafe);
    // Connection-quality panel: the persisted preference decides visibility
    // (fail-open hidden without a settings store); the uptime clock starts
    // now when the chat opens onto an already-live link — the connection
    // signal would never fire in that case.
    final bool panelVisible =
        SettingsRepository.instance?.getString('connectionPanelVisible') ==
            'true';
    _connectedSince = _binding.isConnected ? DateTime.now() : null;

    final ChatSessionModel? argSession = _arg.session;
    ChatSessionModel session;
    if (argSession != null) {
      session = argSession;
    } else {
      // Session keying: prefer the peer's STABLE per-install id (WFD
      // identity frame) so the same device always merges into one session
      // despite randomized P2P MAC rotation; fall back to the device
      // address (BT / WFD before the frame), but never to the placeholder
      // 'unknown' or the dummy P2P MAC (02:00:00:00:00:00) — uuid in that
      // case. The MAC stays in device['address'] for display/reconnects.
      final peerId = _binding.connectedDeviceId;
      final mac = _binding.connectedDeviceKey;
      final bool macUsable = mac != null &&
          mac.isNotEmpty &&
          mac != 'unknown' &&
          mac != '02:00:00:00:00:00';
      final keySource = peerId ?? mac;
      final bool keyUsable = keySource != null &&
          keySource.isNotEmpty &&
          keySource != 'unknown' &&
          keySource != '02:00:00:00:00:00';
      final String key = keyUsable ? keySource : Uuid().v4();
      _seedKey = key;
      _seedMacUsable = macUsable;
      if (kDebugMode) {
        debugPrint(
          'Chat open: key=$key (peerId=$peerId, mac=$mac) — merge will '
          'match by key, then MAC, then name',
        );
      }
      session = ChatSessionModel(
        id: key,
        name: _binding.connectedDeviceName ?? key,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: const [],
        device: {
          'name': _binding.connectedDeviceName,
          'address': macUsable ? mac : null,
        },
        // Tag the new session with the channel it was created on — the
        // home list shows (and reopens) chats by this value.
        transport: _binding.transportType,
      );
    }

    // Microtask: `_open` reads `state`, which only exists after build
    // returns — running it inline hits the uninitialized-provider assert.
    Future.microtask(() => _open(seeded: argSession != null));

    return ChatState(
      chatSession: session,
      messages: session.messages,
      isConnected: _binding.isConnected,
      linkPanelVisible: panelVisible,
    );
  }

  /// Async part of the open — the old `onInit` body after its synchronous
  /// seed: session load/merge/re-key (transport-reconstructed opens), the
  /// transport tag stamp, callbacks, legacy id backfill, `onChatOpened`
  /// and the initial history-sync microtask. Same order and logs as before.
  Future<void> _open({required bool seeded}) async {
    if (!seeded) {
      final repo = _repo;
      var session = await repo.loadChatSession(_seedKey!);
      session ??= await _findExistingSessionForPeer();
      if (kDebugMode) {
        debugPrint(
          'Session load: key=$_seedKey -> ${session?.id ?? 'MISS'}'
          '${session == null ? '' : (session.id == _seedKey ? ' (direct hit)' : ' (merged)')}',
        );
      }
      if (_closed) return;
      if (session != null && session.id == _seedKey) {
        // DIRECT key hit: load the existing session's messages. Re-bind the
        // stored identity to the live connection: a stale address left
        // behind by an earlier cross-transport merge (e.g. a Nearby-era uid
        // under a Bluetooth MAC key) would otherwise make every later
        // reconnect fail — Bluetooth dials `device['address']` verbatim.
        // This also heals such rows on their next connection open.
        final rebound = session.reboundTo(
          address: _seedMacUsable ? _binding.connectedDeviceKey : null,
          peerName: _binding.connectedDeviceName,
          transport: _binding.transportType,
        );
        final bool identityChanged =
            rebound.device['address'] != session.device['address'] ||
                rebound.transport != session.transport ||
                rebound.name != session.name ||
                rebound.device['name'] != session.device['name'];
        state = state.copyWith(
          chatSession: rebound,
          messages: rebound.messages,
        );
        if (identityChanged) {
          _scheduleSave();
        }
      } else if (session != null && session.id != _seedKey) {
        // Re-key + adopt: move the matched session under the computed key so
        // future opens hit it directly (no repeated merge search), and use
        // the re-keyed instance — `chatSession.id` is final, so the session
        // is re-created with the new id; the nested message objects are
        // reused as-is. The stored identity is re-bound to the CURRENT
        // connection (device address + transport tag).
        final rebound = session.reboundTo(
          address: _seedMacUsable ? _binding.connectedDeviceKey : null,
          peerName: _binding.connectedDeviceName,
          transport: _binding.transportType,
        );
        state = state.copyWith(
          chatSession: rebound,
          messages: rebound.messages,
        );
        try {
          await repo.saveChatSession(rebound);
          await repo.deleteChatSession(session.id);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Session re-key failed: $e');
          }
        }
        if (_closed) return;
        _scheduleSave();
      } else if (session == null) {
        // BRAND-NEW session: persist it right away. Saves are otherwise
        // triggered only by dirty events (message, rename, sync) — a chat
        // opened and closed without any of those would never touch the
        // store and silently vanish on restart. The identity frame may
        // still be in flight (or the MAC rotated): flag the open so a late
        // identity frame re-checks for a stored session of the same peer
        // and merges it in instead of leaving two chats for one device.
        _openedAsFreshSession = true;
        _scheduleSave();
      }
    }

    if (_closed) return;

    // Sessions persisted before the transport field existed carry no tag:
    // stamp the transport in use now — the home list both labels and
    // reopens chats by this value, so it always matches the screen the
    // chat was reached on.
    if (state.chatSession.transport == null) {
      state.chatSession.transport = _binding.transportType;
      _scheduleSave();
    }

    _setupCallbacks();

    // Backfill ids for messages persisted by the legacy Hive-era schema
    // (which never wrote `id`): deletion and progress bookkeeping key on
    // ids, so legacy history needs one before it can be deleted.
    final msgs = List.of(state.messages);
    var backfilled = false;
    for (var i = 0; i < msgs.length; i++) {
      if (msgs[i].id == null) {
        msgs[i] = msgs[i].copyWith(id: Uuid().v4());
        backfilled = true;
      }
    }
    if (backfilled) {
      state = state.copyWith(messages: msgs);
      _scheduleSave();
    }

    // Opening the chat counts as "chat open" for the transport: a connection
    // arriving while this screen is visible must not push a second chat.
    _binding.onChatOpened();

    // Share our scan-time reading — the accepting side never scanned and
    // has no local RSSI of its own.
    _sharePeerSignal();

    // When this is not the first session with this peer, share the last
    // messages on (re)connection so both devices converge on the same
    // history. Chat screens opened through the scan flow already have a
    // socket, so the initial microtask send works; sessions opened without
    // a connection (home -> chat -> Connect button) get the sync as soon as
    // the socket comes up. A drop re-arms the sync (connection signal).
    Future.microtask(_sendHistorySync);
  }

  /// Idempotent full teardown — the old `onClose` body exactly. Runs
  /// synchronously from the screen's dispose (outside any provider
  /// lifecycle; the same deterministic ordering the old
  /// GetX delete→onClose had). The `ref.onDispose` backup ([_disposeSafe])
  /// skips the transport calls — provider lifecycles forbid `ref`/`state`
  /// access, and in the app the screen's dispose always runs this first.
  void close() {
    if (_closed) return;
    _closed = true;
    _teardown(disconnectTransport: true);
  }

  /// Lifecycle-safe teardown for `ref.onDispose`: resources + the pending
  /// save flush only (both are plain objects/snapshots — no `ref`, no
  /// `state`). Also what test teardowns hit when a test never calls
  /// [close] explicitly.
  void _disposeSafe() {
    if (_closed) return;
    _closed = true;
    _teardown(disconnectTransport: false);
  }

  void _teardown({required bool disconnectTransport}) {
    _saveDebounce?.cancel();
    _linkShareRetry?.cancel();
    _linkShareRetry = null;
    _incomingStallTimer?.cancel();
    _incomingStallTimer = null;
    _outgoingStallTimer?.cancel();
    _outgoingStallTimer = null;
    // Capture the flush future: the pending write must land. Calling
    // _flushPendingSave() again later would be a no-op (the debounce is
    // already consumed).
    final Future<void> flush = _flushPendingSave();
    // Discard queued sends: there is no socket after the chat closes.
    _sendQueue.clear();
    // A voice announcement whose bytes never arrived must not survive the
    // teardown: the next connection's first bytes frame would be routed to
    // the audio handler and saved as a .m4a instead of an image.
    _pendingAudioMeta = null;
    _pendingIncomingFileMeta = null;
    // No peer answers deferred-download requests once the chat closes.
    for (final t in _fetchWatchdogs.values) {
      t.cancel();
    }
    _fetchWatchdogs.clear();
    // Stop any active recording and release the player.
    _recordTimer?.cancel();
    _recorder?.dispose();
    _audioPlayer.dispose();
    audioPlayback.dispose();
    textController.dispose();
    _binding.removeListener(this);
    if (disconnectTransport) {
      // Disconnect when leaving the chat screen to release the socket
      // cleanly. PopScope on the screen confirms there is no active
      // transfer first.
      _binding.disconnectFromDevice();
      _binding.onChatClosed();
    }
    unawaited(flush.whenComplete(() {
      // Home list refresh is handled by the drift stream in
      // home_providers.dart — no manual refresh needed after a chat closes.
    }));
  }

  // ── Transport signals (ChatTransportListener) ──────────────────────────

  @override
  void onTransportConnectionChanged(bool connected) {
    if (_closed) return;
    state = state.copyWith(isConnected: connected);
    if (connected) {
      _connectedSince = DateTime.now();
      _sendHistorySync();
      // Re-share on every (re)connection: the reading is per-link.
      _sharePeerSignal();
    } else {
      _connectedSince = null;
      _peerReportedRssi = null;
      _syncSentForSession = false;
      // Same for an announcement whose bytes died with the link: without
      // this clear the next connection's first bytes frame misroutes.
      _pendingAudioMeta = null;
      _pendingIncomingFileMeta = null;
      // A dropped link kills any in-flight byte transfer: resolve its
      // bubble now instead of leaving it stuck at its last reading.
      _failActiveTransfers();
    }
  }

  @override
  void onTransportDisconnectReason(String reason) {
    if (_closed || reason.isEmpty) return;
    final l10n = ref.read(appLocalizationsProvider);
    _showNotice(l10n.disconnectedTitle, l10n.peerClosedConnectionMessage);
  }

  @override
  void onTransportPeerName(String name) {
    if (_closed) return;
    _updateSessionName(name);
  }

  // ── Public surface (the old controller's API) ──────────────────────────

  /// Live name of the connected peer (transport-provided; null before the
  /// peer's name frame arrives on transports that announce it).
  String? get connectedDeviceName => _binding.connectedDeviceName;

  /// Toggles the connection-quality strip; the choice is persisted so it
  /// survives restarts (same cached key/value store as theme/locale).
  void toggleLinkPanel() {
    if (_closed) return;
    final next = !state.linkPanelVisible;
    state = state.copyWith(linkPanelVisible: next);
    final write = SettingsRepository.instance
        ?.setString('connectionPanelVisible', next ? 'true' : 'false');
    if (write != null) unawaited(write);
  }

  /// Quality-panel data: uptime clock of the current link, traffic counters
  /// and — Bluetooth only — the dial-time scan RSSI.
  DateTime? get connectedSince => _connectedSince;
  int? get connectedDeviceRssi => _binding.connectedDeviceRssi;

  /// RSSI the peer shared over the sync channel (the accepting side has no
  /// local reading — no platform API exists for a connected RFCOMM link).
  int? get peerReportedRssi => _peerReportedRssi;

  /// Live link RSSI readback for the quality panel — best effort: each
  /// transport returns null where the platform exposes no readback.
  Future<int?> fetchLiveRssi() async {
    try {
      return await _binding.getLiveRssi();
    } catch (_) {
      return null;
    }
  }
  String get transportKind => _arg.transport;

  /// The app's unified notice card — the same surface the transport
  /// notifiers and the scan screens raise (no plain snackbars anymore).
  void _showNotice(
    String title,
    String message, {
    IconData icon = Icons.link_off,
    Color accent = Colors.redAccent,
  }) {
    ConnectionNotice.show(
      title: title,
      message: message,
      isChatScreen: true,
      icon: icon,
      accent: accent,
    );
  }

  /// Reconnects to the device this chat session belongs to. Used by the
  /// Connect button shown when the chat is opened without a connection.
  Future<void> connectToCurrentSession() async {
    if (state.isConnected || state.isConnecting) return;
    final address = state.chatSession.device['address'] as String?;
    state = state.copyWith(isConnecting: true);
    // The transport decides how to reach the stored peer: Bluetooth dials
    // the stored address; Wi‑Fi Direct discovers the device first (P2P
    // addresses rotate) and connects on a match — hence the name, used as
    // the fallback match when the stored address went stale.
    final bool ok = await _binding.connectToSessionPeer(
      address: address,
      name: state.chatSession.name,
    );
    if (_closed) return;
    state = state.copyWith(isConnecting: false);
    // Not connected yet, but the link is alive (socket up and/or the peer
    // is still deciding): that is not a failure — tell the user we are
    // waiting for the peer's acceptance instead. Only a genuinely dead
    // attempt (no socket, nothing pending) reports failure.
    final bool connected = state.isConnected;
    final l10n = ref.read(appLocalizationsProvider);
    // A declined request is announced by the transport's notice card (and
    // lastConnectError carries its reason), so don't stack a second,
    // plain notification on top of it.
    final bool declined =
        _binding.lastConnectError == l10n.connectionDeclinedMessage;
    if (!connected && !ok && !_binding.isAwaitingAcceptance && !declined) {
      _showNotice(
        l10n.couldNotConnectTitle,
        _binding.lastConnectError ?? l10n.couldNotConnectMessage,
        icon: Icons.error_outline,
      );
    } else if (!connected && !declined) {
      _showNotice(
        l10n.waitingAcceptanceTitle,
        l10n.waitingAcceptanceMessage,
        icon: Icons.hourglass_top,
        accent: Colors.amber,
      );
    }
  }

  /// Applies a peer-reported device name (WFD sockets carry no name on the
  /// wire) to the app bar and the persisted session — an UPGRADE only: a
  /// raw model code must not downgrade a stored display name.
  void _updateSessionName(String name) {
    if (_closed) return;
    if (name.isEmpty || state.peerName == name) return;
    final session = state.chatSession;
    if (session.name == name) {
      state = state.copyWith(peerName: name);
    } else if (ChatSessionModel.shouldReplaceDisplayName(session.name, name)) {
      final renamed = ChatSessionModel(
        id: session.id,
        name: name,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        messages: session.messages,
        device: session.device,
        transport: session.transport,
      );
      state = state.copyWith(peerName: name, chatSession: renamed);
      _scheduleSave();
    }
    // else: downgrade blocked — keep both the stored title and peerName.
    // The real (model) device name just landed: if this chat opened as a
    // fresh session on an unknown identity, an existing session for the
    // same peer may now be findable and must absorb into this one.
    unawaited(_mergeLatePeerSession());
  }

  /// Late identity merge: the chat opened while the peer identity was still
  /// unknown (rotated P2P MAC / identity frame in flight), so the open
  /// MISSed and created a fresh session; the identity frame has now arrived
  /// — if a stored session matches the peer (address, or a
  /// normalization-insensitive name), it is the same conversation: adopt
  /// its history here and delete the duplicate so the history sync and the
  /// home list stay in ONE chat.
  Future<void> _mergeLatePeerSession() async {
    if (_closed || !_openedAsFreshSession || _lateMergeDone) return;
    final duplicate = await _findExistingSessionForPeer();
    if (_closed) return;
    if (duplicate == null || duplicate.id == state.chatSession.id) return;
    _lateMergeDone = true;
    final seen = <String>{};
    final combined = <MessageModel>[];
    for (final m in [...duplicate.messages, ...state.messages]) {
      final k = m.id ??
          '${m.timestamp.microsecondsSinceEpoch}|${m.isSentByMe}|'
              '${m.text}|${m.imagePath}';
      if (seen.add(k)) combined.add(m);
    }
    // Newest-first, matching the list contract everywhere else (live frames
    // are inserted at index 0; the list renders with reverse: true and the
    // repo persists index order) — an ascending merge showed (and persisted)
    // the whole conversation upside down.
    combined.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final session = state.chatSession;
    final merged = ChatSessionModel(
      id: session.id,
      name: session.name,
      createdAt: duplicate.createdAt.isBefore(session.createdAt)
          ? duplicate.createdAt
          : session.createdAt,
      updatedAt: DateTime.now(),
      messages: combined,
      device: {
        'name': session.device['name'] ?? duplicate.device['name'],
        'address': session.device['address'] ?? duplicate.device['address'],
      },
      transport: session.transport,
    );
    state = state.copyWith(chatSession: merged, messages: combined);
    try {
      final repo = _repo;
      await repo.saveChatSession(merged);
      await repo.deleteChatSession(duplicate.id);
      if (kDebugMode) {
        debugPrint(
          'Late identity merge: adopted "${duplicate.name}" '
          '(${duplicate.id}) into ${merged.id} — '
          '${combined.length} messages',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Late identity merge failed: $e');
      }
    }
    if (_closed) return;
    _scheduleSave();
    // The merged history may be exactly what the peer is missing: run the
    // sync again now that the session holds the real conversation.
    _syncSentForSession = false;
    unawaited(_sendHistorySync());
  }

  /// Finds an existing session for the current peer when the computed key
  /// misses: first by the peer's device address (MAC), then by the peer's
  /// reported name (model — so the same device always shows up as one chat;
  /// the identical-model edge case of two same phones is accepted for a P2P
  /// app).
  Future<ChatSessionModel?> _findExistingSessionForPeer() async {
    try {
      final all = await _repo.getAllChatSessions();
      final peerMac = _binding.connectedDeviceKey;
      final peerName = _binding.connectedDeviceName;
      if (kDebugMode) {
        debugPrint(
          'Peer merge search: mac=$peerMac name=$peerName over '
          '${all.map((s) => '${s.name}[${s.id}]').toList()}',
        );
      }
      if (peerMac != null &&
          peerMac.isNotEmpty &&
          peerMac != 'unknown' &&
          peerMac != '02:00:00:00:00:00') {
        for (final s in all) {
          if (s.device['address'] == peerMac) return s;
        }
      }
      if (peerName != null && peerName.isNotEmpty && peerName != 'unknown') {
        // Names reach us from different sources (discovery name, identity
        // frame's model name, socket map) and may differ in case, spacing
        // or punctuation — compare normalized.
        final target = _normalizePeerName(peerName);
        for (final s in all) {
          if (_normalizePeerName(s.name) == target) return s;
        }
      }
    } catch (_) {
      // Fail-open: no merge found.
    }
    return null;
  }

  /// Normalized device-name comparison for peer merging: lowercase and
  /// strip everything that is not a letter or digit ("SM-G610F" ==
  /// "sm g610f" == "SM_G610F").
  String _normalizePeerName(String? value) =>
      (value ?? '').toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  void _setupCallbacks() {
    // Playback position of the active voice bubble.
    _audioPlayer.positionStream.listen((position) {
      final duration = _audioPlayer.duration;
      if (duration != null && duration.inMilliseconds > 0) {
        _setPlayback(
          progress: (position.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0),
          durationMs: duration.inMilliseconds.toDouble(),
        );
      }
    });
    _audioPlayer.durationStream.listen((duration) {
      _setPlayback(durationMs: duration?.inMilliseconds.toDouble() ?? 0);
    });
    _audioPlayer.playerStateStream.listen((state) {
      _setPlayback(playing: state.playing);
      if (state.processingState == ProcessingState.completed) {
        _setPlayback(playingId: null, progress: 0);
      }
    });

    _binding.onSocketData((bytes, text, {required String kind}) async {
      if (_closed) return;
      // Link-panel counters: every frame carries its payload size here
      // (bytes frames binary, text frames UTF-8).
      linkStats.recordIn(
        kind == 'bytes' ? bytes.length : utf8.encode(text).length,
      );
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket data: $text\n Kind: $kind');
      }
      if (kind == 'bytes' && bytes.isNotEmpty) {
        // A voice/file announcement precedes its bytes; route accordingly.
        if (_pendingAudioMeta != null) {
          await _handleIncomingAudio(bytes);
        } else if (_pendingIncomingFileMeta != null) {
          await _handleIncomingFile(bytes);
        } else {
          await _handleIncomingImage(bytes);
        }
      } else if (text.startsWith(_audioPrefix)) {
        // Voice transfer announcement: remember the duration for the coming
        // bytes; nothing is added to the chat at this point.
        _pendingAudioMeta = text.substring(_audioPrefix.length);
      } else if (text.startsWith(_filePrefix)) {
        // File transfer announcement: remember the name for the coming
        // bytes; nothing is added to the chat at this point.
        _pendingIncomingFileMeta = text.substring(_filePrefix.length);
      } else if (text.startsWith(_syncPrefix)) {
        // History sync packet from the peer: not a real message, apply it to
        // the local history instead of appending it to the chat.
        await _applyHistorySync(text.substring(_syncPrefix.length));
      } else {
        final msgs = List.of(state.messages);
        msgs.insert(
          0,
          MessageModel(
            id: Uuid().v4(),
            text: text,
            isSentByMe: false,
            timestamp: DateTime.now(),
          ),
        );
        if (_closed) return;
        state = state.copyWith(messages: msgs);
        _scheduleSave();
      }
    });

    _binding.onTransferProgress(({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) {
      if (_closed) return;
      // History sync packets travel as one large text frame: reflect their
      // reception as a thin progress bar under the app bar. Plain messages
      // are far below the threshold.
      if (direction == 'in' &&
          kind == 'text' &&
          total >= _syncProgressThreshold) {
        state = state.copyWith(
          syncProgress: total == 0 ? 0 : (current / total).clamp(0, 1).toDouble(),
          isSyncing: current < total,
        );
      }
      final transfer = TransferState(
        direction: direction,
        current: current,
        total: total,
        kind: kind,
      );
      if (direction == 'out') {
        state = state.copyWith(outgoingTransfer: transfer);
        if (kind == 'bytes') {
          _armOutgoingStallWatchdog();
          _updateOutgoingProgress(transfer);
        }
      } else {
        state = state.copyWith(incomingTransfer: transfer);
        if (kind == 'bytes') {
          _armIncomingStallWatchdog();
          // A reading within the first accumulation window marks a fresh
          // frame: a previously failed attempt is no longer "dead" (the
          // peer may simply retry the same picture).
          if (transfer.current <= 4096) _incomingTransferFailed = false;
          if (!_incomingTransferFailed) {
            // The FINAL (current >= total) event must land too: the bubble
            // then carries the exact byte count, which is what tells a
            // complete-but-stuck frame apart from a stalled wire.
            _updateIncomingProgress(transfer);
          }
        }
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint('Transfer progress: $direction $current $total $kind');
      }
    });
  }

  /// Updates the playback ValueNotifier from any of the player streams.
  void _setPlayback({
    Object? playingId = _sentinel,
    bool? playing,
    double? progress,
    double? durationMs,
  }) {
    if (_closed) return;
    final cur = audioPlayback.value;
    audioPlayback.value = AudioPlaybackState(
      playingId:
          identical(playingId, _sentinel) ? cur.playingId : playingId as String?,
      playing: playing ?? cur.playing,
      progress: progress ?? cur.progress,
      durationMs: durationMs ?? cur.durationMs,
    );
  }

  /// Sends through the binding while counting the payload for the link
  /// panel. Counted only when a link is really up (the transports no-op
  /// sends while disconnected, so the counters must not drift).
  Future<void> _sendText(String message) {
    if (_binding.isConnected) {
      linkStats.recordOut(utf8.encode(message).length);
    }
    return _binding.sendMessage(message);
  }

  Future<void> _sendBytesFrame(Uint8List bytes) {
    if (_binding.isConnected) {
      linkStats.recordOut(bytes.length);
    }
    return _binding.sendBytes(bytes);
  }

  /// Sends the sync **manifest** — a light SHA-256 digest of the last
  /// [_syncHistoryCount] messages (what the peer may need) — as a single
  /// small packet. The peer compares it against its own set and only
  /// requests what it is actually missing; no message payload (and no image
  /// bytes) is transferred unless needed. Called once per CONNECTION (a
  /// drop re-arms it) — on (re)connect, and via the late-identity merge.
  Future<void> _sendHistorySync() async {
    if (_closed) return; // queued via microtask — the chat may have closed
    // One sync per connection: re-armed on every disconnect; a re-connect
    // then re-syncs without a screen reopen.
    if (_syncSentForSession) return;
    // No socket yet (chat opened from the session list): nothing to send;
    // the connection signal re-invokes this as soon as the link is up.
    if (!_binding.isConnected) return;

    final history = state.messages.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final recent = history.take(_syncHistoryCount).toList();

    final counts = await _localHashCounts(recent);
    // Nothing to offer yet: leave the flag unset so a later trigger (a
    // re-connect, or the late identity merge that brings the real history
    // into this session) can still run the sync.
    if (counts.isEmpty) return;
    // Marked before sending: the state must not allow another trigger while
    // the handshake is in flight.
    _syncSentForSession = true;

    // Sync traffic rides OUTSIDE the user send queue: live messages are
    // never blocked behind sync packets (the single socket still orders
    // frames FIFO natively).
    _sendText(
      _syncPrefix +
          jsonEncode({
            'type': 'manifest',
            // Data-plane protocol version: absent on pre-versioning builds
            // (read as v1). A mismatch against the peer's is logged.
            'pv': syncProtocolVersion,
            'items': [
              for (final e in counts.entries) {'h': e.key, 'n': e.value},
            ],
          }),
    );
  }

  /// Asks the peer for the media file behind a placeholder bubble.
  Future<void> downloadMedia(MessageModel message) async {
    final id = message.id;
    if (id == null || !message.hasRemoteMedia) return;
    if (!_binding.isConnected) {
      final l10n = ref.read(appLocalizationsProvider);
      _showNotice(
        l10n.downloadFailedTitle,
        l10n.downloadNeedConnection,
        icon: Icons.file_download_off,
      );
      return;
    }
    _setMediaFetchBusy(id, true);
    _fetchWatchdogs[id]?.cancel();
    _fetchWatchdogs[id] = Timer(const Duration(seconds: 90), () {
      _fetchWatchdogs.remove(id);
      _setMediaFetchBusy(id, false);
      if (_closed) return;
      final l10n = ref.read(appLocalizationsProvider);
      _showNotice(
        l10n.downloadFailedTitle,
        l10n.downloadTimeoutMessage,
        icon: Icons.file_download_off,
      );
    });
    _sendText(
      _syncPrefix + jsonEncode({'type': 'fetch', 'id': id}),
    );
  }

  /// Flips the placeholder bubble's busy flag (spinner) for [id].
  void _setMediaFetchBusy(String id, bool busy) {
    if (_closed) return;
    final msgs = List.of(state.messages);
    final idx = msgs.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final cur = msgs[idx];
    if (!cur.hasRemoteMedia || cur.isTransferring == busy) return;
    msgs[idx] = cur.copyWith(isTransferring: busy);
    state = state.copyWith(messages: msgs);
  }

  /// Stops the watchdog of [id] (the file arrived or the peer said no).
  void _settleFetch(String id) {
    _fetchWatchdogs.remove(id)?.cancel();
  }

  /// Logs the peer's data-plane protocol version (carried by its sync
  /// manifest). Absent on builds older than the versioning round → read as
  /// v1. A mismatch prints both versions so an incompatible pair of builds
  /// (two phones, different installs) is identifiable from the logs in one
  /// line.
  void _logPeerProtocolVersion(Object? raw) {
    final int peer = raw is int ? raw : 1;
    // Remembered for the file-sharing capability gate (needs >= 2).
    _peerPv = peer;
    if (kDebugMode && showDebugLogs) {
      debugPrint(
        'Sync protocol: peer v$peer, local v$syncProtocolVersion'
        '${peer == syncProtocolVersion ? '' : ' — MISMATCH'}',
      );
    }
  }

  /// Shares our scan-time reading with the peer: the accepting side never
  /// scanned and has no local RSSI (no platform API reads a connected
  /// RFCOMM link live), so the dialer pushes its value; the retry covers
  /// the peer's chat opening / wiring a beat after ours.
  void _sharePeerSignal() {
    if (_closed || !state.isConnected) return;
    final reading = _binding.connectedDeviceRssi;
    if (reading == null) return;
    unawaited(
      _sendText(
        '$_syncPrefix${jsonEncode({'type': 'linkShare', 'rssi': reading})}',
      ),
    );
    _linkShareRetry?.cancel();
    _linkShareRetry = Timer(linkShareRetryDelay, () {
      if (_closed || !state.isConnected) return;
      final retry = _binding.connectedDeviceRssi;
      if (retry != null) {
        unawaited(
          _sendText(
            '$_syncPrefix${jsonEncode({'type': 'linkShare', 'rssi': retry})}',
          ),
        );
      }
    });
  }

  /// Dispatches an incoming sync packet by its `type`:
  /// - `manifest`  → compare against local messages, request what's missing
  /// - `request`   → send the requested messages (as `message` packets)
  /// - `message`   → integrate the peer's messages into local history
  /// - `fetch`     → send one message's media file (deferred download)
  /// - `download`  → the file we asked for (fills a placeholder bubble)
  /// - `fetchMiss` → the peer no longer holds the requested file
  /// - `linkShare` → the dialer's scan-time RSSI, pushed for the quality
  ///   panel (older builds ignore the unknown type via their `default:`).
  Future<void> _applyHistorySync(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final type = decoded['type'] as String? ?? 'message';
      switch (type) {
        case 'message':
          await _applySyncMessages(decoded['messages']);
        case 'manifest':
          _logPeerProtocolVersion(decoded['pv']);
          await _handleSyncManifest(decoded['items']);
        case 'request':
          await _handleSyncRequest(decoded['items']);
        case 'fetch':
          await _handleSyncFetch(decoded['id']);
        case 'download':
          await _applySyncMessages(decoded['messages']);
        case 'fetchMiss':
          _handleFetchMiss(decoded['id']);
        case 'linkShare':
          final rssi = (decoded['rssi'] as num?)?.toInt();
          if (rssi != null && rssi >= -100 && rssi <= -1) {
            _peerReportedRssi = rssi;
          }
        default:
          break;
      }
    } catch (_) {
      // Malformed sync packet — ignore silently.
    }
  }

  /// Compares the peer's manifest against the local message set and requests
  /// the hashes we are missing (with the missing count each).
  Future<void> _handleSyncManifest(dynamic itemsRaw) async {
    if (itemsRaw is! List || itemsRaw.isEmpty) return;
    final myCounts = await _localHashCounts(state.messages);

    final missing = <Map<String, dynamic>>[];
    for (final item in itemsRaw) {
      if (item is! Map) continue;
      final h = item['h'] as String?;
      final n = item['n'] as int? ?? 1;
      if (h == null) continue;
      final need = n - (myCounts[h] ?? 0);
      if (need > 0) missing.add({'h': h, 'n': need});
    }
    if (missing.isEmpty) return;

    _sendText(
      _syncPrefix + jsonEncode({'type': 'request', 'items': missing}),
    );
  }

  /// Sends the requested messages back to the peer: for each requested hash,
  /// the newest [n] local messages matching it, each in its own packet (so a
  /// dropped frame only costs one message).
  Future<void> _handleSyncRequest(dynamic itemsRaw) async {
    if (itemsRaw is! List || itemsRaw.isEmpty) return;
    final sorted = state.messages.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    for (final item in itemsRaw) {
      if (item is! Map) continue;
      final h = item['h'] as String?;
      final n = item['n'] as int? ?? 1;
      if (h == null || n <= 0) continue;
      var sent = 0;
      for (final m in sorted) {
        if (sent >= n) break;
        if (await _messageHash(m) != h) continue;
        _sendText(
          _syncPrefix +
              jsonEncode({
                'type': 'message',
                'messages': [await _syncEntryFor(m)],
              }),
        );
        sent++;
      }
    }
  }

  /// Peer asked for the file behind a placeholder (deferred download): send
  /// that single message with its bytes embedded (up to the fetch cap), or a
  /// miss so the requester's spinner can stop.
  Future<void> _handleSyncFetch(dynamic idRaw) async {
    final id = idRaw is String ? idRaw : null;
    if (id == null) return;
    for (final m in state.messages) {
      if (m.id != id) continue;
      final path = m.imagePath;
      if (path != null) {
        try {
          final file = File(path);
          if (await file.exists() && file.lengthSync() <= _syncMaxFetchBytes) {
            _sendText(
              _syncPrefix +
                  jsonEncode({
                    'type': 'download',
                    'messages': [await _syncEntryFor(m, forceBytes: true)],
                  }),
            );
            return;
          }
        } catch (_) {
          // Unreadable file: fall through to the miss below.
        }
      }
      break;
    }
    _sendText(
      _syncPrefix + jsonEncode({'type': 'fetchMiss', 'id': id}),
    );
  }

  /// The peer no longer holds the file behind a placeholder: clear the
  /// spinner and say so.
  void _handleFetchMiss(dynamic idRaw) {
    final id = idRaw is String ? idRaw : null;
    if (id == null) return;
    _settleFetch(id);
    _setMediaFetchBusy(id, false);
    if (_closed) return;
    final l10n = ref.read(appLocalizationsProvider);
    _showNotice(
      l10n.downloadFailedTitle,
      l10n.downloadUnavailableMessage,
      icon: Icons.file_download_off,
    );
  }

  /// Builds the wire entry for one message. Media is embedded as base64 only
  /// when small enough to ride the sync automatically; larger payloads ship
  /// as a size marker (the peer shows a download placeholder and fetches the
  /// file explicitly — see [_handleSyncFetch] with `forceBytes`).
  Future<Map<String, dynamic>> _syncEntryFor(
    MessageModel m, {
    bool forceBytes = false,
  }) async {
    final entry = <String, dynamic>{
      if (m.id != null) 'id': m.id,
      'text': m.text,
      'sentByMe': m.isSentByMe,
      'timestamp': m.timestamp.toIso8601String(),
    };
    final imagePath = m.imagePath;
    final bool isFile = m.transferKind == 'file';
    final String? fileName = isFile && imagePath != null
        ? imagePath.split(Platform.pathSeparator).last
        : null;
    if (imagePath == null) {
      // This side holds the message as a placeholder: pass the marker along
      // so any further sync keeps knowing where the file lives.
      final pendingSize = m.remoteMediaSize;
      if (pendingSize != null && pendingSize > 0) {
        entry['type'] = m.transferKind == 'audio'
            ? 'audio'
            : (isFile ? 'file' : 'image');
        entry['remoteSize'] = pendingSize;
      }
      return entry;
    }
    try {
      final file = File(imagePath);
      if (await file.exists()) {
        final int size = file.lengthSync();
        final bool isAudio = m.transferKind == 'audio';
        final int embedLimit =
            forceBytes ? _syncMaxFetchBytes : _syncInlineMediaBytes;
        if (size <= embedLimit) {
          entry['type'] = isFile ? 'file' : (isAudio ? 'audio' : 'image');
          if (fileName != null) entry['fileName'] = fileName;
          entry['bytes'] = base64Encode(await file.readAsBytes());
        } else if (size <= _syncMaxFetchBytes) {
          // Too large to auto-transfer: advertise it for download-on-tap.
          entry['type'] = isFile ? 'file' : (isAudio ? 'audio' : 'image');
          if (fileName != null) entry['fileName'] = fileName;
          entry['remoteSize'] = size;
        }
        // Beyond the fetch cap: only the text caption travels.
      }
    } catch (_) {
      // Unreadable media: keep its text caption instead.
    }
    return entry;
  }

  /// SHA-256 based content fingerprint of a message:
  /// - images: `i:<sha256(file bytes)>` — identical pictures hash equal on
  ///   both devices, different bytes (even same size) hash differently;
  /// - text:   `t:<sha256(text)>`.
  Future<String> _messageHash(MessageModel m) async {
    final imagePath = m.imagePath;
    if (imagePath != null) {
      try {
        final file = File(imagePath);
        if (await file.exists() && file.lengthSync() <= _syncMaxImageBytes) {
          final digest = sha256.convert(await file.readAsBytes());
          return 'i:${digest.toString()}';
        }
      } catch (_) {
        // Fall through to the text fingerprint.
      }
    }
    return 't:${sha256.convert(utf8.encode(m.text)).toString()}';
  }

  /// Hash → occurrence count map over [msgs].
  Future<Map<String, int>> _localHashCounts(List<MessageModel> msgs) async {
    final counts = <String, int>{};
    for (final m in msgs) {
      final h = await _messageHash(m);
      counts[h] = (counts[h] ?? 0) + 1;
    }
    return counts;
  }

  /// Applies an incoming `message` packet: integrates the peer's messages
  /// into the local history, deduplicating against messages that already
  /// exist locally (same text, same direction and almost-same timestamp —
  /// the peer's copy of a message we already hold).
  Future<void> _applySyncMessages(dynamic raw) async {
    if (raw is! List || _closed) return;
    state = state.copyWith(isSyncing: true);
    try {
      final entries = raw;
      // Collect the changes while awaiting disk writes; the state list is
      // only re-read ONCE, synchronously, in the final phase. Writing back
      // a snapshot captured before the awaits silently dropped every state
      // change that landed meanwhile (live frames, back-to-back media) —
      // the old live RxList never had that window.
      final List<({String id, String path, bool isAudio})> completions = [];
      final List<
          ({
            MessageModel model,
            String text,
            bool sentByMe,
            DateTime ts,
            int? incomingHash,
          })> additions = [];

      for (final entry in entries) {
        if (entry is! Map) continue;
        final text = entry['text'] as String? ?? '';
        // Flip the sender's perspective: a message the peer sent to us is
        // "received" here, and one the peer received from us is "sent".
        final sentByMe = !(entry['sentByMe'] as bool? ?? false);
        final tsRaw = entry['timestamp'] as String?;
        final ts = tsRaw != null ? DateTime.tryParse(tsRaw) : null;
        if (text.isEmpty || ts == null) continue;

        // Rehydrate embedded media bytes (decoded early so the content hash
        // can be used for a robust dedup and the file written only once).
        final bool isAudioEntry = entry['type'] == 'audio';
        final bool isFileEntry = entry['type'] == 'file';
        final String? fileEntryName =
            isFileEntry ? (entry['fileName'] as String?) : null;
        Uint8List? mediaBytes;
        final b64 = entry['bytes'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          try {
            mediaBytes = base64Decode(b64);
          } catch (_) {
            mediaBytes = null;
          }
        }
        final int? incomingHash =
            mediaBytes == null ? null : _quickHash(mediaBytes);

        // Deferred-download completion: an entry that carries the media of
        // a message we already hold as a placeholder (same id, no file yet)
        // is not a duplicate — it is the file we asked for. Fill the bubble
        // (clears the spinner and the pending marker in one step).
        final entryId = entry['id'] as String?;
        if (mediaBytes != null && entryId != null) {
          final int idx = state.messages.indexWhere((m) => m.id == entryId);
          if (idx != -1 && state.messages[idx].hasRemoteMedia) {
            String? downloaded;
            try {
              downloaded = isFileEntry
                  ? await _persistIncomingNamedBytes(
                      mediaBytes,
                      fileEntryName ?? 'file',
                    )
                  : await _persistMediaBytes(
                      mediaBytes,
                      isAudioEntry ? 'm4a' : 'jpg',
                    );
            } catch (_) {
              downloaded = null;
            }
            if (downloaded != null) {
              completions.add(
                (id: entryId, path: downloaded, isAudio: isAudioEntry),
              );
              _settleFetch(entryId);
              continue;
            }
          }
        }

        bool alreadyHave = state.messages.any(
          (m) =>
              m.text == text &&
              m.isSentByMe == sentByMe &&
              // Primary: nearly-identical timestamps (the peer's copy of a
              // message we already hold).
              (m.timestamp.difference(ts).abs().inSeconds <= 10 ||
                  // Fallback for images: identical content (same bytes) is
                  // the same picture even when clocks/transfer time differ.
                  (incomingHash != null &&
                      m.imagePath != null &&
                      _fileHash(m.imagePath!) == incomingHash)),
        );
        if (alreadyHave) continue;

        // Persist the embedded media to a local file (once, after dedup).
        String? mediaPath;
        if (mediaBytes != null) {
          try {
            mediaPath = isFileEntry
                ? await _persistIncomingNamedBytes(
                    mediaBytes,
                    fileEntryName ?? 'file',
                  )
                : await _persistMediaBytes(
                    mediaBytes,
                    isAudioEntry ? 'm4a' : 'jpg',
                  );
          } catch (_) {
            mediaPath = null;
          }
        }

        // Large media arrives as a size marker WITHOUT bytes: create the
        // placeholder bubble (download on tap) instead of a local file.
        final int? remoteSize = entry['remoteSize'] as int?;
        additions.add((
          model: MessageModel(
            // Keep the peer's id so future syncs can deduplicate on it.
            id: entryId,
            text: text,
            isSentByMe: sentByMe,
            timestamp: ts,
            imagePath: mediaPath,
            transferKind: isAudioEntry
                ? 'audio'
                : (isFileEntry ? 'file' : null),
            remoteMediaSize:
                mediaPath == null && remoteSize != null && remoteSize > 0
                    ? remoteSize
                    : null,
          ),
          text: text,
          sentByMe: sentByMe,
          ts: ts,
          incomingHash: incomingHash,
        ));
      }

      if ((completions.isNotEmpty || additions.isNotEmpty) && !_closed) {
        // Final phase: fresh read + id-based merge in a single state write.
        final msgs = List.of(state.messages);
        for (final c in completions) {
          final idx = msgs.indexWhere((m) => m.id == c.id);
          if (idx != -1 && msgs[idx].hasRemoteMedia) {
            final cur = msgs[idx];
            msgs[idx] = MessageModel(
              id: cur.id,
              text: cur.text,
              isSentByMe: cur.isSentByMe,
              timestamp: cur.timestamp,
              imagePath: c.path,
              transferKind: c.isAudio ? 'audio' : cur.transferKind,
            );
          }
        }
        for (final a in additions) {
          // Re-check the dedup against the FRESH list: a live frame may have
          // integrated the same message while this batch was on disk.
          final dup = msgs.any(
            (m) =>
                m.text == a.text &&
                m.isSentByMe == a.sentByMe &&
                (m.timestamp.difference(a.ts).abs().inSeconds <= 10 ||
                    (a.incomingHash != null &&
                        m.imagePath != null &&
                        _fileHash(m.imagePath!) == a.incomingHash)),
          );
          if (!dup) msgs.add(a.model);
        }
        msgs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        state = state.copyWith(messages: msgs);
        _scheduleSave();
      }
    } catch (_) {
      // Malformed sync packet — ignore silently.
    } finally {
      // Frame may have finished before applying (images written to disk);
      // hide the banner only once everything is processed.
      if (!_closed) {
        state = state.copyWith(isSyncing: false);
      }
    }
  }

  /// FNV-1a 32-bit hash of [bytes]: a cheap content fingerprint used to
  /// deduplicate synced images against local files.
  int _quickHash(Uint8List bytes) {
    var hash = 0x811C9DC5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Content hash of the image file at [path], or null if unreadable.
  int? _fileHash(String path) {
    try {
      return _quickHash(File(path).readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleIncomingImage(Uint8List bytes) async {
    if (_closed) return;
    // Capture the target id and consume it BEFORE the disk write; the list
    // is re-read afterwards so concurrent state changes (live frames, a
    // second transfer) are not clobbered by a stale write-back.
    final targetId = _incomingProgressId;
    _incomingProgressId = null;
    _incomingStallTimer?.cancel();
    _incomingStallTimer = null;

    final String filePath;
    try {
      filePath = await _persistMediaBytes(bytes, 'jpg');
    } catch (e) {
      // A failed disk write used to strand the progress bubble at its last
      // reading (an unhandled async error the UI never reflected).
      if (kDebugMode && showDebugLogs) {
        debugPrint('Incoming image persist failed: $e');
      }
      if (_closed) return;
      _failIncomingTransfer();
      return;
    }
    if (_closed) return;

    _incomingTransferFailed = false;
    final l10n = ref.read(appLocalizationsProvider);
    final caption = l10n.imageCaption('${bytes.lengthInBytes}');
    final msgs = List.of(state.messages);
    int idx =
        targetId == null ? -1 : msgs.indexWhere((m) => m.id == targetId);
    if (idx == -1) {
      // Bubble may have been cleared or restored without an id: fall back to
      // any incoming progress bubble still in the list.
      idx = msgs.indexWhere(
        (m) => m.isTransferring && m.transferKind == 'bytes' && !m.isSentByMe,
      );
    }
    if (idx == -1) {
      // The stall watchdog may have failed the bubble before a late tail
      // arrived: resurrect that placeholder instead of appending a second
      // message for the same picture.
      idx = msgs.indexWhere(
        (m) =>
            !m.isSentByMe &&
            m.imagePath == null &&
            m.text == l10n.imageReceiveFailed,
      );
    }
    if (idx != -1) {
      msgs[idx] = msgs[idx].copyWith(
        text: caption,
        isSentByMe: false,
        timestamp: DateTime.now(),
        imagePath: filePath,
        isTransferring: false,
      );
    } else {
      msgs.insert(
        0,
        MessageModel(
          id: Uuid().v4(),
          text: caption,
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
        ),
      );
    }
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }

  void _updateOutgoingProgress(TransferState transfer) {
    if (_closed) return;
    final msgs = List.of(state.messages);
    int idx = _outgoingProgressId == null
        ? -1
        : msgs.indexWhere((m) => m.id == _outgoingProgressId);
    if (idx == -1) {
      // A straggler event after the transfer was declared dead (blocked
      // write unblocking late) must not plant a ghost bubble that nothing
      // will ever resolve; a fresh job clears the flag.
      if (_outgoingTransferFailed) return;
      _outgoingProgressId = null;
      final bubble = _newProgressBubble(isSentByMe: true, state: transfer);
      _outgoingProgressId = bubble.id;
      msgs.insert(0, bubble);
      idx = 0;
    } else {
      msgs[idx] = msgs[idx].copyWith(
        text: _progressPercent(transfer),
        transferCurrent: transfer.current,
        transferTotal: transfer.total,
        isTransferring: transfer.current < transfer.total,
      );
    }

    // Finalize outgoing: convert the progress bubble into the real
    // image/voice/file message.
    var finalized = false;
    if (transfer.total > 0 && transfer.current >= transfer.total) {
      final bytesToAttach = _pendingOutgoingBytes;
      final audioText = _pendingOutgoingAudioText;
      final fileText = _pendingOutgoingFileText;
      final l10n = ref.read(appLocalizationsProvider);
      msgs[idx] = msgs[idx].copyWith(
        text: audioText ??
            (fileText != null
                ? l10n.fileCaption(
                    fileText,
                    '${bytesToAttach?.lengthInBytes ?? 0}',
                  )
                : (bytesToAttach != null
                    // Localized like the incoming path: the hardcoded English
                    // caption shipped "[Image] (…)" even on the TR UI.
                    ? l10n.imageCaption('${bytesToAttach.lengthInBytes}')
                    : msgs[idx].text)),
        imagePath: _sendingImagePath ?? msgs[idx].imagePath,
        isTransferring: false,
        transferCurrent: transfer.total,
        transferTotal: transfer.total,
        transferKind: audioText != null
            ? 'audio'
            : (fileText != null ? 'file' : 'bytes'),
      );
      finalized = true;
      _sendingImagePath = null;
      _pendingOutgoingBytes = null;
      _pendingOutgoingAudioText = null;
      _pendingOutgoingFileText = null;
      _outgoingProgressId = null;
    }
    state = state.copyWith(messages: msgs);
    // Persist AFTER the state write: _scheduleSave snapshots the CURRENT
    // state — scheduling before the finalize write stored the bubble still
    // mid-transfer (the old timer read the live list at fire time).
    if (finalized) _scheduleSave();
  }

  void _updateIncomingProgress(TransferState transfer) {
    if (_closed) return;
    final msgs = List.of(state.messages);
    int idx = _incomingProgressId == null
        ? -1
        : msgs.indexWhere((m) => m.id == _incomingProgressId);
    if (idx == -1) {
      // Only genuine intermediate readings create a bubble: a straggler
      // FINAL event (fired after the data frame already consumed the id)
      // must not plant a ghost bubble that nothing will resolve. Tiny
      // single-read images never show a progress bubble — the data frame
      // inserts its message directly (same as before). Degenerate
      // zero-total readings still create (an RF-5 counter-case), and the
      // stall watchdog resolves them like any other dead transfer.
      if (transfer.total > 0 && transfer.current >= transfer.total) return;
      _incomingProgressId = null;
      final bubble = _newProgressBubble(isSentByMe: false, state: transfer);
      _incomingProgressId = bubble.id;
      msgs.insert(0, bubble);
      idx = 0;
    } else {
      msgs[idx] = msgs[idx].copyWith(
        text: _progressPercent(transfer),
        transferCurrent: transfer.current,
        transferTotal: transfer.total,
        // Stays a progress bubble even after the final progress event: the
        // data frame is what finalizes it — or the stall watchdog fails it.
        isTransferring: true,
      );
    }
    state = state.copyWith(messages: msgs);
  }

  /// (Re)arms the stall watchdog for the INCOMING bytes transfer. A healthy
  /// transfer emits a progress event per socket read (tens of milliseconds
  /// apart); a timed-out silent gap means the link died mid-frame or a
  /// frame tail / platform event was lost — nothing else would ever resolve
  /// the bubble, which is exactly the "receiving 100% forever" bug.
  void _armIncomingStallWatchdog() {
    _incomingStallTimer?.cancel();
    _incomingStallTimer = Timer(transferStallTimeout, () {
      _incomingStallTimer = null;
      if (_closed) return;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Incoming transfer stalled — failing its bubble');
      }
      _failIncomingTransfer();
    });
  }

  /// Same for the OUTGOING bytes transfer: a write loop blocked on a dead
  /// link emits no further progress and its send future never completes.
  void _armOutgoingStallWatchdog() {
    _outgoingStallTimer?.cancel();
    _outgoingStallTimer = Timer(transferStallTimeout, () {
      _outgoingStallTimer = null;
      if (_closed) return;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Outgoing transfer stalled — failing its bubble');
      }
      _failOutgoingTransfer();
    });
  }

  /// Converts the in-flight incoming bytes bubble into a visible failure.
  /// Called by the stall watchdog, a failed disk write, and on disconnect —
  /// without it the bubble sat at its last reading (rounded up to a
  /// deceptive "100%") forever, even after the link was long gone.
  void _failIncomingTransfer({bool asFile = false}) {
    if (_closed) return;
    _incomingStallTimer?.cancel();
    _incomingStallTimer = null;
    _incomingTransferFailed = true;
    final msgs = List.of(state.messages);
    int idx = _incomingProgressId == null
        ? -1
        : msgs.indexWhere((m) => m.id == _incomingProgressId);
    if (idx == -1) {
      idx = msgs.indexWhere(
        (m) => m.isTransferring && m.transferKind == 'bytes' && !m.isSentByMe,
      );
    }
    _incomingProgressId = null;
    if (idx == -1) return;
    final l10n = ref.read(appLocalizationsProvider);
    msgs[idx] = msgs[idx].copyWith(
      text: asFile ? l10n.fileReceiveFailed : l10n.imageReceiveFailed,
      isTransferring: false,
    );
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }

  /// Same for the outgoing bubble (see [_failIncomingTransfer]). Also drops
  /// the pending payload and flags the transfer dead so a late straggler
  /// progress event (a blocked write unblocking) cannot recreate a bubble.
  void _failOutgoingTransfer() {
    if (_closed) return;
    // Captured BEFORE the cleanup below: the failed transfer's kind picks
    // its label (a voice/file failure must not read "image").
    final wasAudio = _pendingOutgoingAudioText != null;
    final wasFile = _pendingOutgoingFileText != null;
    _outgoingStallTimer?.cancel();
    _outgoingStallTimer = null;
    _outgoingTransferFailed = true;
    final msgs = List.of(state.messages);
    int idx = _outgoingProgressId == null
        ? -1
        : msgs.indexWhere((m) => m.id == _outgoingProgressId);
    if (idx == -1) {
      idx = msgs.indexWhere(
        (m) => m.isTransferring && m.transferKind == 'bytes' && m.isSentByMe,
      );
    }
    _outgoingProgressId = null;
    _pendingOutgoingBytes = null;
    _pendingOutgoingAudioText = null;
    _pendingOutgoingFileText = null;
    _sendingImagePath = null;
    if (idx == -1) return;
    final l10n = ref.read(appLocalizationsProvider);
    msgs[idx] = msgs[idx].copyWith(
      text: wasFile
          ? l10n.fileSendFailed
          : (wasAudio ? l10n.audioSendFailed : l10n.imageSendFailed),
      isTransferring: false,
    );
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }

  /// Fails every in-flight byte transfer — a dropped link resolves all of
  /// them NOW instead of leaving "100%" bubbles behind.
  void _failActiveTransfers() {
    _failIncomingTransfer();
    _failOutgoingTransfer();
  }

  MessageModel _newProgressBubble({
    required bool isSentByMe,
    required TransferState state,
  }) {
    return MessageModel(
      id: Uuid().v4(),
      text: _progressPercent(state),
      isSentByMe: isSentByMe,
      timestamp: DateTime.now(),
      transferCurrent: state.current,
      transferTotal: state.total,
      isTransferring: true,
      transferKind: 'bytes',
    );
  }

  String _progressPercent(TransferState state) {
    final pct = state.total == 0 ? 0 : (state.current / state.total * 100);
    return '${pct.toStringAsFixed(0)}%';
  }

  void sendTextMessage() {
    if (_closed) return;
    if (state.isConnected) {
      final text = textController.text;
      // Show the bubble immediately (user feedback); the actual write is
      // serialized behind any in-flight transfer.
      final msgs = List.of(state.messages);
      msgs.insert(
        0,
        MessageModel(
          id: Uuid().v4(),
          text: text,
          isSentByMe: true,
          timestamp: DateTime.now(),
        ),
      );
      state = state.copyWith(messages: msgs);
      _scheduleSave();
      textController.clear();
      _enqueueSend(_OutgoingJob.text(text));
    }
  }

  Future<void> _saveChatSession() async {
    final session = state.chatSession;
    session.messages = List.of(state.messages);
    session.updatedAt = DateTime.now();
    await _repo.saveChatSession(session);
  }

  /// Clears the conversation (the old kit's `messages.clear() +
  /// saveChatSession()` pair as one call — same behavior).
  Future<void> clearConversation() async {
    if (_closed) return;
    // Drop any pending debounced write first — a stale snapshot must not
    // race the cleared conversation back into the store.
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _pendingSaveSnapshot = null;
    state = state.copyWith(messages: const []);
    await _saveChatSession();
  }

  /// Snapshot of the session as of the last scheduled save. Captured
  /// OUTSIDE any provider lifecycle: the flush path may run inside
  /// `ref.onDispose`, where reading `state` is forbidden.
  ChatSessionModel? _pendingSaveSnapshot;

  ChatSessionModel _snapshotSession() {
    final session = state.chatSession;
    session.messages = List.of(state.messages);
    session.updatedAt = DateTime.now();
    return session;
  }

  /// Debounced persistence: bursts of events (message storms, transfer
  /// progress) result in a single write. [close] flushes the pending write
  /// so no change is lost.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _pendingSaveSnapshot = _snapshotSession();
    _saveDebounce = Timer(const Duration(milliseconds: 250), () async {
      _saveDebounce = null;
      final snapshot = _pendingSaveSnapshot;
      _pendingSaveSnapshot = null;
      if (snapshot == null) return;
      try {
        await _repo.saveChatSession(snapshot);
      } catch (e) {
        // Never let a persistence failure vanish silently — it previously
        // made sessions disappear after restart with no trace.
        if (kDebugMode) {
          debugPrint('Chat session save failed: $e');
        }
      }
    });
  }

  Future<void> _flushPendingSave() async {
    final snapshot = _pendingSaveSnapshot;
    if (_saveDebounce == null || snapshot == null) return;
    _saveDebounce!.cancel();
    _saveDebounce = null;
    _pendingSaveSnapshot = null;
    try {
      await _repo.saveChatSession(snapshot);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Chat session flush failed: $e');
      }
    }
  }

  /// Remove a message at the given index from the shared message list.
  void deleteMessageAt(int index) {
    if (_closed) return;
    if (index >= 0 && index < state.messages.length) {
      final msgs = List.of(state.messages)..removeAt(index);
      state = state.copyWith(messages: msgs);
    }
  }

  /// Removes one of the user's own messages by id (UI + persisted session).
  /// Local only: the peer's copy is untouched, so a later history sync may
  /// re-deliver the message.
  void deleteMessage(String? id) {
    if (_closed || id == null) return;
    final msgs = List.of(state.messages);
    final idx = msgs.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    msgs.removeAt(idx);
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }

  Future<void> pickAndSendImage() => _pickAndSend(ImageSource.gallery);

  /// Attachment chooser (gallery, camera, file, location). Pure Flutter
  /// (`showModalBottomSheet` via the caller's context); the sheet is
  /// dismissed through its own route before the picker/dialogs open.
  Future<void> showAttachmentSheet(BuildContext context) async {
    if (!state.isConnected) return;
    final Color cardColor = Theme.of(context).cardColor;
    final l10n = ref.read(appLocalizationsProvider);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: false,
      builder: (sheetContext) => SafeArea(
        child: Material(
          // Material instead of Container(decoration): a DecoratedBox between
          // the sheet and the ListTiles would hide their ink splashes.
          color: cardColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: Text(l10n.gallerySource),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _pickAndSend(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: Text(l10n.cameraSource),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _pickAndSend(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(l10n.fileSource),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await pickAndSendFile(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(l10n.locationSource),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await shareLocationFlow(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Picks a file (system picker) and sends it. Bluetooth confirms first
  /// (a multi-MB RFCOMM transfer can take minutes); the cap is enforced
  /// before any byte is queued.
  Future<void> pickAndSendFile(BuildContext context) async {
    if (_closed || !state.isConnected) return;
    final l10n = ref.read(appLocalizationsProvider);
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile();
    } catch (e) {
      if (kDebugMode && showDebugLogs) debugPrint('File picker failed: $e');
      return;
    }
    if (_closed || picked == null) return;
    // SAF may hand back a content:// uri with no local path: materialize a
    // cache-backed copy so the bubble has a real openable file.
    var path = picked.path;
    if (path == null) {
      try {
        final bytes = await picked.readAsBytes();
        final dir = await getApplicationDocumentsDirectory();
        path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_'
            '${_sanitizeFileName(picked.name)}';
        await compute(_writeBytesToFile, (path: path, bytes: bytes));
      } catch (e) {
        if (kDebugMode && showDebugLogs) {
          debugPrint('File materialize failed: $e');
        }
      }
    }
    if (_closed) return;
    if (path == null) {
      _showNotice(
        l10n.fileOpenFailedTitle,
        l10n.fileOpenFailed,
        icon: Icons.error_outline,
      );
      return;
    }
    final int pickedSize = (await picked.length()) ?? 0;
    if (pickedSize > maxFileBytes) {
      _showNotice(
        l10n.fileTooLargeTitle,
        l10n.fileTooLargeMessage(
          '${(maxFileBytes / (1024 * 1024)).round()} MB',
        ),
        icon: Icons.error_outline,
      );
      return;
    }
    // Bluetooth is the slow channel: confirm before a potentially long
    // transfer (WFD/Nearby are fast enough to just send).
    if (_arg.transport == ChatSessionModel.transportBluetooth &&
        context.mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.btFileSlowTitle),
          content: Text(l10n.btFileSlowMessage(formatFileSize(pickedSize))),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.sendAction),
            ),
          ],
        ),
      );
      if (ok != true || _closed) return;
    }
    await sendFile(path, name: picked.name);
  }

  /// One-shot location share: permission → single fix → confirm preview →
  /// [sendLocation]. Every failure surfaces as a themed notice.
  Future<void> shareLocationFlow(BuildContext context) async {
    if (_closed || !state.isConnected) return;
    final l10n = ref.read(appLocalizationsProvider);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showNotice(
          l10n.locationOffTitle,
          l10n.locationOffMessage,
          icon: Icons.location_off,
          accent: Colors.amber,
        );
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showNotice(
          l10n.permissionTitle,
          l10n.locationPermissionMessage,
          icon: Icons.lock_outline,
          accent: Colors.amber,
        );
        return;
      }
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Location permission failed: $e');
      }
      _showNotice(
        l10n.permissionTitle,
        l10n.locationPermissionMessage,
        icon: Icons.lock_outline,
        accent: Colors.amber,
      );
      return;
    }
    if (_closed) return;

    Position? fix;
    try {
      fix = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (_) {
      // Timeout / provider failure: fall back to the last known fix.
    }
    if (fix == null) {
      try {
        fix = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }
    if (_closed) return;
    if (fix == null) {
      _showNotice(
        l10n.locationFailedTitle,
        l10n.locationFailedMessage,
        icon: Icons.gps_off,
        accent: Colors.redAccent,
      );
      return;
    }
    final Position pos = fix;
    final int? accuracy =
        pos.accuracy.isFinite && pos.accuracy > 0 ? pos.accuracy.round() : null;

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.locationConfirmTitle),
        content: Text(
          '${pos.latitude.toStringAsFixed(6)}, '
          '${pos.longitude.toStringAsFixed(6)}'
          '${accuracy == null ? '' : '\n±$accuracy m'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.sendAction),
          ),
        ],
      ),
    );
    if (ok != true || _closed) return;
    sendLocation(
      lat: pos.latitude,
      lng: pos.longitude,
      accuracyMeters: accuracy,
    );
  }

  /// Opens a received file with the system viewer (util channel); shows a
  /// notice when the file is missing or nothing can open it, and a
  /// settings pointer when an APK still needs the install-unknown-apps
  /// grant (the native side opens that settings page instead of the
  /// installer, which would otherwise swallow the intent silently).
  Future<void> openReceivedFile(String path) async {
    if (_closed) return;
    var outcome = 'failed';
    try {
      outcome = await UtilPlatformChannel.openFile(path);
    } catch (e) {
      if (kDebugMode && showDebugLogs) debugPrint('openFile failed: $e');
    }
    if (_closed || outcome == 'opened') return;
    final l10n = ref.read(appLocalizationsProvider);
    if (outcome == 'permission') {
      _showNotice(
        l10n.installPermissionTitle,
        l10n.installPermissionMessage,
        icon: Icons.app_settings_alt_outlined,
      );
      return;
    }
    _showNotice(
      l10n.fileOpenFailedTitle,
      l10n.fileOpenFailed,
      icon: Icons.error_outline,
    );
  }

  /// Opens coordinates in a maps app (util channel); shows a notice when
  /// none handles the geo/https intents.
  Future<void> openLocationInMaps(double lat, double lng) async {
    if (_closed) return;
    var ok = false;
    try {
      ok = await UtilPlatformChannel.openMap(lat: lat, lng: lng);
    } catch (e) {
      if (kDebugMode && showDebugLogs) debugPrint('openMap failed: $e');
    }
    if (_closed || ok) return;
    final l10n = ref.read(appLocalizationsProvider);
    _showNotice(
      l10n.locationFailedTitle,
      l10n.mapsOpenFailed,
      icon: Icons.map_outlined,
    );
  }

  Future<void> _pickAndSend(ImageSource source) async {
    if (_closed || !state.isConnected) return;
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: source);
    if (file == null || _closed) return;

    final bytes = await file.readAsBytes();
    if (_closed) return;
    await enqueuePickedImage(bytes);
  }

  /// Test seam for the outgoing compression pass: tests swap in a stand-in
  /// so the stored-bytes == wire-bytes invariant stays observable without
  /// the platform plugin.
  @visibleForTesting
  static Future<Uint8List> Function(Uint8List bytes) imageCompressor =
      _compressImage;

  static Future<Uint8List> _compressImage(Uint8List bytes) async {
    // Single compression pass: pickImage is used without imageQuality so
    // the JPEG is not decoded twice.
    try {
      final compressed =
          await FlutterImageCompress.compressWithList(bytes, quality: 70);
      if (compressed.isNotEmpty) return Uint8List.fromList(compressed);
    } catch (_) {}
    return bytes;
  }

  /// Compresses one pass, then queues the transfer pointing the message at
  /// EXACTLY the bytes that go on the wire. The stored copy must stay
  /// byte-identical to what the peer receives: a divergent copy (stored
  /// original vs sent compressed) defeats the content-hash dedup fallback,
  /// so a re-served copy can only be recognised by the ±10 s timestamp
  /// window — which slow transfers and clock skew break (duplicate image
  /// bubbles after sync). Byte-identical replicas also keep history-sync
  /// manifest hashes matching, so no side re-serves the other's images.
  @visibleForTesting
  Future<void> enqueuePickedImage(Uint8List rawBytes) async {
    if (_closed || !state.isConnected) return;
    final bytes = await imageCompressor(rawBytes);
    if (_closed) return;
    final sentPath = await _persistMediaBytes(bytes, 'jpg');
    if (_closed) return;
    _sendingImagePath = sentPath;
    // Queue the transfer instead of sending immediately: it starts only
    // after any currently in-flight send completes, so wire order and
    // progress state of concurrent image transfers never interleave.
    _enqueueSend(_OutgoingJob.bytes(bytes, sentPath));
  }

  /// Queues one file for sending. [name] defaults to the path's basename;
  /// the bytes are read into memory (transports frame whole payloads), so
  /// [maxFileBytes] caps both sides' RAM.
  Future<void> sendFile(String path, {String? name}) async {
    if (_closed || !state.isConnected) return;
    final l10n = ref.read(appLocalizationsProvider);
    // A pre-file peer build cannot render the announcement/bytes pair at
    // all — block instead of shipping bytes it would mis-save as an image.
    final peerPv = _peerPv;
    if (peerPv != null && peerPv < 2) {
      _showNotice(
        l10n.fileUnsupportedTitle,
        l10n.fileUnsupportedMessage,
        icon: Icons.system_update_alt,
      );
      return;
    }
    Uint8List bytes;
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw const FileSystemException('file is gone');
      }
      bytes = await file.readAsBytes();
    } catch (e) {
      if (kDebugMode && showDebugLogs) debugPrint('File read failed: $e');
      if (_closed) return;
      _showNotice(
        l10n.fileOpenFailedTitle,
        l10n.fileOpenFailed,
        icon: Icons.error_outline,
      );
      return;
    }
    if (_closed) return;
    if (bytes.length > maxFileBytes) {
      _showNotice(
        l10n.fileTooLargeTitle,
        l10n.fileTooLargeMessage(
          '${(maxFileBytes / (1024 * 1024)).round()} MB',
        ),
        icon: Icons.error_outline,
      );
      return;
    }
    final fileName = _sanitizeFileName(
      (name == null || name.trim().isEmpty)
          ? path.split(Platform.pathSeparator).last
          : name,
    );
    _enqueueSend(_OutgoingJob.bytes(bytes, path, fileName: fileName));
  }

  /// Queues a one-shot location share. The message text is the encoded
  /// plain-text form (readable on every build; see location_message.dart).
  void sendLocation({
    required double lat,
    required double lng,
    int? accuracyMeters,
  }) {
    if (_closed || !state.isConnected) return;
    final text = encodeLocationMessage(
      lat: lat,
      lng: lng,
      accuracyMeters: accuracyMeters,
    );
    final msgs = List.of(state.messages);
    msgs.insert(
      0,
      MessageModel(
        id: Uuid().v4(),
        text: text,
        isSentByMe: true,
        timestamp: DateTime.now(),
      ),
    );
    state = state.copyWith(messages: msgs);
    _scheduleSave();
    _enqueueSend(_OutgoingJob.text(text));
  }

  /// Adds a send job and starts draining the queue when idle.
  void _enqueueSend(_OutgoingJob job) {
    _sendQueue.add(job);
    _drainSendQueue();
  }

  /// Process queued sends one at a time. A bytes job is considered finished
  /// when its send future completes (native send is serialized on a single
  /// executor), and then the next job is dispatched.
  Future<void> _drainSendQueue() async {
    if (_sendJobActive) return;
    _sendJobActive = true;
    try {
      while (_sendQueue.isNotEmpty) {
        final job = _sendQueue.removeAt(0);
        await _processSendJob(job);
      }
    } finally {
      _sendJobActive = false;
    }
  }

  Future<void> _processSendJob(_OutgoingJob job) async {
    try {
      if (job.kind == _SendKind.bytes) {
        // A fresh job revives the outgoing transfer state: the previous
        // one's failure flag must not suppress this job's progress bubbles.
        _outgoingTransferFailed = false;
        // A file announces itself first (name + size) so the receiver can
        // label/name the incoming bytes — the same text-channel contract
        // the voice-message announcement uses.
        final fileName = job.fileName;
        if (fileName != null) {
          await _sendText(
            _filePrefix +
                jsonEncode({'name': fileName, 'size': job.bytes!.length}),
          );
        }
        // Wire these before sendBytes so progress callbacks can finalize the
        // bubble; cleared on completion/failure in _updateOutgoingProgress.
        _pendingOutgoingBytes = job.bytes;
        _sendingImagePath = job.imagePath;
        _pendingOutgoingAudioText = job.audioText;
        _pendingOutgoingFileText = fileName;
        await _sendBytesFrame(job.bytes!);
      } else {
        await _sendText(job.text!);
      }
    } catch (_) {
      // A thrown send resolves the transfer through the same failure path
      // the stall watchdog and disconnects use: every pending marker is
      // cleared (audio text included) and only the transfer's OWN bubble is
      // marked — the old inline fallback could overwrite the newest message
      // (index 0) when no progress event had ever arrived.
      if (job.kind == _SendKind.bytes && !_closed) {
        _failOutgoingTransfer();
      }
    }
    // Even when the future completes without any progress events, the next
    // queued job may proceed (progress-driven finalization also calls
    // _drainSendQueue; _sendJobActive guard makes the double call a no-op).
    _drainSendQueue();
  }

  Future<String> _persistMediaBytes(Uint8List bytes, String ext) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.$ext';
    // Write on a background isolate so large payloads don't jank the UI
    await compute(_writeBytesToFile, (path: path, bytes: bytes));
    return path;
  }

  /// Sanitizes a peer-supplied file name for disk use: separators/control
  /// chars replaced, never empty, length-capped with the extension kept.
  static String _sanitizeFileName(String raw) {
    var name = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    if (name.isEmpty || name == '.' || name == '..') name = 'file';
    if (name.length > 100) {
      final dot = name.lastIndexOf('.');
      final ext =
          (dot > 0 && name.length - dot <= 12) ? name.substring(dot) : '';
      name = name.substring(0, 100 - ext.length) + ext;
    }
    return name;
  }

  /// Persists incoming FILE bytes under [name] in a `received/` folder —
  /// unlike media (timestamped names), file bubbles must show their real
  /// name; a collision gets a timestamp prefix instead of an overwrite.
  Future<String> _persistIncomingNamedBytes(
    Uint8List bytes,
    String name,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final received = Directory('${dir.path}/received');
    if (!await received.exists()) {
      await received.create(recursive: true);
    }
    final safe = _sanitizeFileName(name);
    var path = '${received.path}/$safe';
    if (await File(path).exists()) {
      path =
          '${received.path}/${DateTime.now().millisecondsSinceEpoch}_$safe';
    }
    await compute(_writeBytesToFile, (path: path, bytes: bytes));
    return path;
  }

  // ── Voice recording & playback ─────────────────────────────────────────

  /// Starts a voice recording (hold-to-record). Requires the microphone
  /// runtime permission; the file is AAC-LC (.m4a) in app documents.
  Future<void> startRecording() async {
    if (_closed || state.isRecording || !state.isConnected) return;
    final status = await Permission.microphone.request();
    if (_closed) return;
    if (!status.isGranted) {
      final l10n = ref.read(appLocalizationsProvider);
      _showNotice(
        l10n.micPermissionTitle,
        l10n.recordingUnavailableMessage,
        icon: Icons.mic_off,
        accent: Colors.amber,
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    if (_closed) return;
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    _recorder = AudioRecorder();
    try {
      await _recorder!.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _recordingPath!,
      );
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Recording start failed: $e');
      }
      _recorder = null;
      _recordingPath = null;
      if (_closed) return;
      final l10n = ref.read(appLocalizationsProvider);
      _showNotice(
        l10n.recordingErrorTitle,
        l10n.recordingStartFailedMessage,
        icon: Icons.error_outline,
      );
      return;
    }
    if (_closed) return;
    state = state.copyWith(recordSeconds: 0, isRecording: true);
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (_closed) return;
        final seconds = state.recordSeconds + 1;
        state = state.copyWith(recordSeconds: seconds);
        // Automatic cut-off: stop and send at the configured limit.
        if (seconds >= _maxRecordSeconds) {
          stopRecordingAndSend();
        }
      },
    );
  }

  /// Stops the recording and queues it for sending (≥ 1 s; shorter takes are
  /// discarded to avoid accidental taps).
  Future<void> stopRecordingAndSend() async {
    if (_closed || !state.isRecording) return;
    final path = _recordingPath;
    final seconds = state.recordSeconds;
    await cancelRecording(deleteFile: false);
    if (_closed || path == null) return;
    final file = File(path);
    if (!await file.exists() || file.lengthSync() == 0) return;
    if (_closed) return;
    if (seconds < 1) {
      await file.delete().catchError((_) => file);
      return;
    }
    _enqueueSend(
      _OutgoingJob.text(
          _audioPrefix + jsonEncode({'duration': _formatDuration(seconds)})),
    );
    _enqueueSend(
      _OutgoingJob.bytes(await file.readAsBytes(), path,
          audioText: _formatDuration(seconds)),
    );
  }

  /// Aborts the current recording (used when the press is cancelled).
  Future<void> cancelRecording({bool deleteFile = true}) async {
    _recordTimer?.cancel();
    _recordTimer = null;
    if (!_closed) {
      state = state.copyWith(isRecording: false, recordSeconds: 0);
    }
    final path = _recordingPath;
    _recordingPath = null;
    try {
      final recorder = _recorder;
      if (recorder != null && await recorder.isRecording()) {
        await recorder.stop();
      }
    } catch (_) {}
    _recorder = null;
    if (deleteFile && path != null) {
      await File(path).delete().catchError((_) => File(path));
    }
  }

  /// Toggles playback of a voice bubble (single player instance).
  Future<void> toggleAudio(MessageModel msg) async {
    final path = msg.imagePath;
    if (path == null) return;
    if (audioPlayback.value.playingId == msg.id) {
      if (_audioPlayer.playing) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play();
      }
      return;
    }
    await _audioPlayer.stop();
    _setPlayback(playingId: msg.id, progress: 0);
    try {
      await _audioPlayer.setFilePath(path);
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Audio load failed: $e');
      }
      _setPlayback(playingId: null);
      return;
    }
    await _audioPlayer.play();
  }

  /// Seeks the given bubble to [millis]. Loads the track first when another
  /// message is currently bound to the player.
  Future<void> seekAudio(MessageModel msg, double millis) async {
    if (audioPlayback.value.playingId != msg.id) {
      await toggleAudio(msg);
    }
    if (millis < 0) millis = 0;
    await _audioPlayer.seek(Duration(milliseconds: millis.round()));
  }

  /// Jumps [delta] (e.g. ±10 s) from the current playback position.
  Future<void> skipAudio(Duration delta) async {
    final duration = _audioPlayer.duration;
    var target = _audioPlayer.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration != null && target > duration) target = duration;
    await _audioPlayer.seek(target);
  }

  String _formatDuration(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Processes an incoming voice transfer: persists the bytes and finalizes
  /// the transfer bubble as an audio message.
  Future<void> _handleIncomingAudio(Uint8List bytes) async {
    if (_closed) return;
    final meta = _pendingAudioMeta;
    _pendingAudioMeta = null;
    String? durationText;
    if (meta != null && meta.isNotEmpty) {
      try {
        durationText = (jsonDecode(meta)['duration'] as String?) ?? '0:00';
      } catch (_) {
        durationText = meta;
      }
    }

    // Capture the target id and consume it BEFORE the disk write; the list
    // is re-read afterwards (see _handleIncomingImage).
    final targetId = _incomingProgressId;
    _incomingProgressId = null;
    _incomingStallTimer?.cancel();
    _incomingStallTimer = null;

    final String filePath;
    try {
      filePath = await _persistMediaBytes(bytes, 'm4a');
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Incoming audio persist failed: $e');
      }
      if (_closed) return;
      _failIncomingTransfer();
      return;
    }
    if (_closed) return;

    _incomingTransferFailed = false;
    final msgs = List.of(state.messages);
    int idx =
        targetId == null ? -1 : msgs.indexWhere((m) => m.id == targetId);
    if (idx == -1) {
      idx = msgs.indexWhere(
        (m) => m.isTransferring && m.transferKind == 'bytes' && !m.isSentByMe,
      );
    }
    if (idx != -1) {
      msgs[idx] = msgs[idx].copyWith(
        text: durationText ?? msgs[idx].text,
        isSentByMe: false,
        timestamp: DateTime.now(),
        imagePath: filePath,
        isTransferring: false,
        transferKind: 'audio',
      );
    } else {
      msgs.insert(
        0,
        MessageModel(
          id: Uuid().v4(),
          text: durationText ?? '0:00',
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
          transferKind: 'audio',
        ),
      );
    }
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }

  /// Processes an incoming file transfer: persists the bytes under the
  /// announced name (sanitized; collisions get a timestamp prefix) and
  /// finalizes the transfer bubble as a file message.
  Future<void> _handleIncomingFile(Uint8List bytes) async {
    if (_closed) return;
    final meta = _pendingIncomingFileMeta;
    _pendingIncomingFileMeta = null;
    var name = 'file';
    if (meta != null && meta.isNotEmpty) {
      try {
        name = _sanitizeFileName(
          (jsonDecode(meta)['name'] as String?) ?? name,
        );
      } catch (_) {
        name = _sanitizeFileName(meta);
      }
    }

    // Capture the target id and consume it BEFORE the disk write; the list
    // is re-read afterwards (see _handleIncomingImage).
    final targetId = _incomingProgressId;
    _incomingProgressId = null;
    _incomingStallTimer?.cancel();
    _incomingStallTimer = null;

    final String filePath;
    try {
      filePath = await _persistIncomingNamedBytes(bytes, name);
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Incoming file persist failed: $e');
      }
      if (_closed) return;
      _failIncomingTransfer(asFile: true);
      return;
    }
    if (_closed) return;

    _incomingTransferFailed = false;
    final l10n = ref.read(appLocalizationsProvider);
    final caption = l10n.fileCaption(name, '${bytes.lengthInBytes}');
    final msgs = List.of(state.messages);
    int idx =
        targetId == null ? -1 : msgs.indexWhere((m) => m.id == targetId);
    if (idx == -1) {
      idx = msgs.indexWhere(
        (m) =>
            m.isTransferring && m.transferKind == 'bytes' && !m.isSentByMe,
      );
    }
    if (idx != -1) {
      msgs[idx] = msgs[idx].copyWith(
        text: caption,
        isSentByMe: false,
        timestamp: DateTime.now(),
        imagePath: filePath,
        isTransferring: false,
        transferKind: 'file',
      );
    } else {
      msgs.insert(
        0,
        MessageModel(
          id: Uuid().v4(),
          text: caption,
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
          transferKind: 'file',
        ),
      );
    }
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }
}
