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
import 'package:chatblue/screens/chat_ui/connecting_panel.dart';
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
  _OutgoingJob.text(String this.text, {this.messageId})
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
    this.messageId,
  })  : kind = _SendKind.bytes,
        text = null;

  final _SendKind kind;
  final String? text;
  final Uint8List? bytes;
  final String? imagePath;

  /// Bubble id of the message this job carries: for a text job the sender
  /// stamps the send result's delivery state (sent / failed) on it; for a
  /// bytes job (voice/file) it is the id minted UP FRONT and announced on
  /// the wire — both replicas must end up on ONE identity, or an id-based
  /// flow (the deferred-download fetch) misses on the peer even though it
  /// holds the file. The progress bubble adopts it at mint time.
  final String? messageId;

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
    this.hasMoreOlder = false,
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

  /// True while older messages still exist below the loaded window — the
  /// message list's load-more trigger reads it (see
  /// [ChatController.loadOlderMessages]).
  final bool hasMoreOlder;

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
    bool? hasMoreOlder,
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
      hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
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

  /// One-shot safety re-delivery window: if no peer manifest arrived this
  /// long after connecting, both first passes may have raced — re-deliver
  /// the manifest + reading once (see [_redeliverManifestAndReading]).
  static Duration syncNudgeDelay = const Duration(seconds: 10);

  /// Cadence of the live-read re-share while connected (Wi‑Fi Direct client
  /// side): the peer's "(peer reading)" tracks the real link instead of a
  /// frozen snapshot. Test-overridable like the other timeouts.
  @visibleForTesting
  static Duration linkShareRefreshInterval = const Duration(seconds: 5);

  /// Re-share the live reading only when it moved at least this many dBm —
  /// a stable link must not chatter.
  static const int _linkShareMinDelta = 2;

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

  /// Sender-minted id of the active bytes job (voice/file): the progress
  /// bubble is minted with it and the announcement carried it, so both
  /// replicas converge on one message identity.
  String? _pendingOutgoingMessageId;

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

  // ── Delivery ticks (pending → sent → delivered) ────────────────────────
  // The receiver confirms received peer messages with batched `ack` sync
  // frames carrying content fingerprints; the sender flips matching
  // outgoing messages to `delivered`. The same matching also runs against
  // the peer's sync manifest as a backstop — an ack frame lost with a
  // dropped link still heals on the next (re)connection.
  final Set<String> _pendingAckFps = <String>{};
  final Map<String, String> _deliveryFpCache = <String, String>{};
  Timer? _ackFlushTimer;

  /// Batch window before queued receiver acks go out as one `ack` frame
  /// (a history burst acks once, not per message). Test-overridable.
  @visibleForTesting
  static Duration ackFlushDelay = const Duration(milliseconds: 400);

  /// Undelivered outgoing messages examined per ack/manifest batch — caps
  /// the file reads behind media fingerprints.
  static const int _deliveryMatchScanCap = 20;

  /// Hard cap on one ack batch: flush early past this (the frame should
  /// stay far below the sync-progress banner threshold).
  static const int _ackBatchCap = 200;

  /// Scan-time RSSI the peer shared over the sync channel (the accepting
  /// side never scanned, so this is the only reading it can show).
  int? _peerReportedRssi;
  Timer? _linkShareRetry;

  /// Last reading pushed to the peer (change-guard for the live re-share).
  int? _lastSharedRssi;

  /// Periodic re-share of the LIVE link reading while connected — Wi‑Fi
  /// Direct client side only (the side that has a readback).
  Timer? _linkShareTicker;

  /// The peer's manifest arrived on this connection — the frame is only
  /// sent after the peer's callback wiring, so it doubles as their
  /// readiness signal (and silences the nudge).
  bool _receivedPeerManifest = false;

  /// Manifest + reading were re-delivered once on this connection (see
  /// [_redeliverManifestAndReading]) — bounds the exchange, no ping-pong.
  bool _redeliveredManifest = false;

  /// The exact manifest frame last sent on this connection — re-delivered
  /// verbatim (no re-hash) when the first pass may have missed the peer.
  String? _lastManifestFrame;

  /// One-shot safety net for the (rare) case where BOTH first passes raced
  /// and no manifest arrived at either side.
  Timer? _syncNudgeTimer;

  // True when this chat open created a BRAND-NEW session because the peer
  // identity was not (fully) known yet (rotated MAC / identity frame still
  // in flight). A late identity frame then re-checks for a stored session
  // of the same peer and merges it in (see _mergeLatePeerSession).
  bool _openedAsFreshSession = false;
  bool _lateMergeDone = false;

  /// True while an older page is being fetched — the message list's
  /// load-more trigger fires per built item, so this guard collapses the
  /// burst into a single fetch.
  bool _loadingOlder = false;

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

  // ── Paged message history ──────────────────────────────────────────────
  /// Messages loaded into the visible window when a chat opens.
  static const int initialMessageWindow = 20;

  /// Older messages fetched per load-more step (the window grows upward).
  static const int olderPageSize = 5;

  /// Load-more trigger: the message list pulls the next older page when the
  /// build window reaches within this many messages of the oldest loaded
  /// one — with the initial 20-message window that is the 15th message.
  static const int olderPrefetchBuffer = 5;

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
      final String? liveAddr = _livePeerAddress();
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
        // Seed the per-transport map with the live address: the fresh row
        // already carries the address of the link that created it (the
        // absorb/merge then unions it with the stored row's entries).
        deviceAddresses: liveAddr == null
            ? const {}
            : {_binding.transportType: liveAddr},
      );
    }

    // Microtask: `_open` reads `state`, which only exists after build
    // returns — running it inline hits the uninitialized-provider assert.
    Future.microtask(() => _open(seeded: argSession != null));

    // Paged open: the visible window is the newest slice of the history. A
    // seeded (home-list) open already carries the stored list — slice it
    // here; a transport-reconstructed open loads its window from the store
    // in `_open`, BEFORE the callbacks are wired (a live frame must never
    // be overwritten by the window write).
    final List<MessageModel> initialWindow =
        argSession == null ? const [] : _windowSlice(argSession.messages);
    return ChatState(
      chatSession: session,
      messages: initialWindow,
      hasMoreOlder: argSession != null &&
          argSession.messages.length > initialWindow.length,
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
      var session = await repo.loadSessionMeta(_seedKey!);
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
                rebound.device['name'] != session.device['name'] ||
                // A healed entry in the per-transport map (a live link's
                // address learned) is an identity change worth persisting.
                !mapEquals(rebound.deviceAddresses, session.deviceAddresses);
        // The state carries only session meta here; the visible window
        // fills via loadRecentMessages (both paths load it below).
        state = state.copyWith(chatSession: rebound);
        // A direct hit skips the miss-path peer search: a same-peer row
        // from another transport era (e.g. a BT-era row beside this WFD
        // row) would stay split — and the two devices could then open
        // DIFFERENT conversations for one connection (device-reported:
        // Redmi reopened the BT-era chat while the J7 opened its old WFD
        // row). Absorb any sibling row before the open continues.
        await _reconcilePeerSiblings();
        if (_closed) return;
        if (identityChanged) {
          _scheduleSave();
        }
      } else if (session != null && session.id != _seedKey) {
        // Re-key + adopt: move the matched session under the computed key so
        // future opens hit it directly (no repeated merge search), and use
        // the re-keyed instance — `chatSession.id` is final, so the session
        // is re-created with the new id (`reboundTo`'s `newId`); the nested
        // message objects are reused as-is. The stored identity is re-bound
        // to the CURRENT connection (device address + transport tag). The
        // search loaded session META rows only: the re-created row needs the
        // FULL message list (the full-state rewrite below carries it), and
        // the visible window fills from the store afterwards.
        session = await repo.loadChatSession(session.id) ?? session;
        if (_closed) return;
        final rebound = session.reboundTo(
          // THE re-key: the full-state save below moves every message row
          // under this key (PK conflict-update) before the old row is
          // deleted — a rebound that kept the old id would make the save
          // and the delete target the SAME row, wiping the session and its
          // history (FK cascade).
          newId: _seedKey!,
          address: _seedMacUsable ? _binding.connectedDeviceKey : null,
          peerName: _binding.connectedDeviceName,
          transport: _binding.transportType,
        );
        state = state.copyWith(chatSession: rebound);
        try {
          await repo.saveChatSession(rebound);
          await repo.deleteChatSession(session.id);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Session re-key failed: $e');
          }
        }
        if (_closed) return;
        // A further same-peer row (another era) may still exist — absorb it
        // too, mirroring the direct-hit reconcile.
        await _reconcilePeerSiblings();
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

    // Paged open: fill the visible window from the store (a seeded open
    // already holds its slice). The callbacks are wired AFTER this, so a
    // live frame can never be overwritten by the window write.
    if (!seeded) {
      await _loadInitialWindow(state.chatSession.id);
      if (_closed) return;
    }

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

    // Share our signal reading — the accepting side never scanned and has
    // no local RSSI of its own; whoever HAS a reading pushes it.
    unawaited(_sharePeerSignal());

    // When this is not the first session with this peer, share the last
    // messages on (re)connection so both devices converge on the same
    // history. Chat screens opened through the scan flow already have a
    // socket, so the initial microtask send works; sessions opened without
    // a connection (home -> chat -> Connect button) get the sync as soon as
    // the socket comes up. A drop re-arms the sync (connection signal).
    Future.microtask(_sendHistorySync);
    // Safety net for the first-pass race (see syncNudgeDelay): arm here too,
    // not only on the connection signal — a scan-flow chat opens AFTER the
    // connection event, so the signal alone would never arm it.
    if (_binding.isConnected) {
      _syncNudgeTimer ??= Timer(syncNudgeDelay, _onSyncNudge);
    }
  }

  /// The newest [initialMessageWindow] messages of [full] (a fresh list) —
  /// the visible window.
  List<MessageModel> _windowSlice(List<MessageModel> full) =>
      full.length <= initialMessageWindow
          ? List.of(full)
          : full.sublist(0, initialMessageWindow);

  /// Loads the initial visible window: the newest [initialMessageWindow]
  /// messages (one extra fetched to learn whether older history exists).
  Future<void> _loadInitialWindow(String sessionId) async {
    final page = await _repo.loadRecentMessages(
      sessionId,
      limit: initialMessageWindow + 1,
    );
    if (_closed) return;
    final hasMore = page.length > initialMessageWindow;
    final window =
        hasMore ? page.sublist(0, initialMessageWindow) : page;
    state = state.copyWith(messages: window, hasMoreOlder: hasMore);
  }

  /// Loads the next older page of history into the visible window —
  /// [olderPageSize] messages per call. The message list calls this when
  /// the user scrolls within [olderPrefetchBuffer] messages of the oldest
  /// loaded one; a no-op while a page is in flight or when the history is
  /// exhausted ([ChatState.hasMoreOlder]). Older pages append to the END of
  /// the newest-first list, so the reverse ListView never jumps.
  Future<void> loadOlderMessages() async {
    if (_closed || _loadingOlder || !state.hasMoreOlder) return;
    final msgs = state.messages;
    if (msgs.isEmpty) return;
    final oldest = msgs.last;
    _loadingOlder = true;
    try {
      final older = await _repo.loadMessagesBefore(
        state.chatSession.id,
        before: oldest.timestamp,
        beforeId: oldest.id,
        limit: olderPageSize + 1,
      );
      if (_closed) return;
      // The keyset query matches the store's read order exactly; the id
      // filter is a safety net for a legacy row without an id.
      String keyOf(MessageModel m) =>
          m.id ??
          '${m.timestamp.microsecondsSinceEpoch}|${m.isSentByMe}|'
              '${m.text}|${m.imagePath}';
      final known = {for (final m in state.messages) keyOf(m)};
      final fresh = [
        for (final m in older)
          if (known.add(keyOf(m))) m,
      ];
      final hasMore = fresh.length > olderPageSize;
      final page = hasMore ? fresh.sublist(0, olderPageSize) : fresh;
      state = state.copyWith(
        messages: page.isEmpty ? state.messages : [...state.messages, ...page],
        hasMoreOlder: hasMore,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Older message load failed: $e');
      }
    } finally {
      _loadingOlder = false;
    }
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
    _linkShareTicker?.cancel();
    _linkShareTicker = null;
    _syncNudgeTimer?.cancel();
    _syncNudgeTimer = null;
    _ackFlushTimer?.cancel();
    _ackFlushTimer = null;
    _pendingAckFps.clear();
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
      _recordPeerAddress();
      _syncNudgeTimer ??= Timer(syncNudgeDelay, _onSyncNudge);
      _sendHistorySync();
      // Re-share on every (re)connection: the reading is per-link.
      unawaited(_sharePeerSignal());
    } else {
      _connectedSince = null;
      _peerReportedRssi = null;
      _syncSentForSession = false;
      _receivedPeerManifest = false;
      _redeliveredManifest = false;
      _lastManifestFrame = null;
      _syncNudgeTimer?.cancel();
      _syncNudgeTimer = null;
      // The live-reading ticker describes the link that just died — stop
      // it and forget the last pushed value; the next connection restarts
      // both.
      _linkShareTicker?.cancel();
      _linkShareTicker = null;
      _lastSharedRssi = null;
      // Same for an announcement whose bytes died with the link: without
      // this clear the next connection's first bytes frame misroutes.
      _pendingAudioMeta = null;
      _pendingIncomingFileMeta = null;
      // Queued acks describe a link that just died — nothing to answer on
      // anymore; a re-encounter re-acks.
      _ackFlushTimer?.cancel();
      _ackFlushTimer = null;
      _pendingAckFps.clear();
      // A dropped link kills any in-flight byte transfer: resolve its
      // bubble now instead of leaving it stuck at its last reading.
      _failActiveTransfers();
    }
  }

  /// The live peer address of the current link, keyed by the transport's
  /// identity semantics: Bluetooth → the peer's MAC (connectedDeviceKey),
  /// Wi‑Fi Direct → the peer's p2p address, Nearby → its per-install uid
  /// (endpoint id as the fallback). Null when nothing usable is bound yet;
  /// the placeholder markers never leak into the map.
  String? _livePeerAddress() {
    final kind = _binding.transportType;
    final String? raw = switch (kind) {
      ChatSessionModel.transportNearby =>
        _binding.connectedDeviceId ?? _binding.connectedDeviceKey,
      _ => _binding.connectedDeviceKey,
    };
    final a = (raw ?? '').trim();
    if (a.isEmpty || a == 'unknown' || a == '02:00:00:00:00:00') return null;
    return a;
  }

  /// Records the live peer address under the CURRENT transport in the
  /// session's per-transport map ({bt: MAC, wfd: p2p address}): every live
  /// link teaches the app the peer's address on that channel, so a later
  /// pick of the same transport can dial it directly instead of
  /// re-discovering — and the knowledge persists across restarts with the
  /// session row.
  void _recordPeerAddress() {
    final a = _livePeerAddress();
    if (a == null) return;
    final session = state.chatSession;
    final updated = session.recordingPeerAddress(_binding.transportType, a);
    if (identical(updated, session)) return;
    state = state.copyWith(chatSession: updated);
    _scheduleSave();
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
  /// and the per-transport signal metrics (BT dial-time scan RSSI, Nearby
  /// GMS bandwidth quality).
  DateTime? get connectedSince => _connectedSince;
  int? get connectedDeviceRssi => _binding.connectedDeviceRssi;

  /// Coarse link-quality code for the quality panel (Nearby Connections
  /// only — GMS bandwidth-change events; null on the other transports).
  int? get linkQuality => _binding.linkQuality;

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
    // This transport's own entry from the per-transport map, with the
    // legacy single address as the fallback for rows older than the map.
    final address = state.chatSession.addressFor(_arg.transport) ??
        state.chatSession.device['address'] as String?;
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

  /// Connects to this chat's peer over [kind] — the transport picker's
  /// entry point. The current transport delegates to the classic reconnect
  /// ([connectToCurrentSession]); another transport runs THAT transport's
  /// session-reconnect flow (discovery + match, with its own device-picker
  /// fallback) behind the cancellable connecting panel. On success the
  /// target transport pushes its own chat screen, and the session
  /// reconciliation merges both channels into one conversation.
  Future<void> connectViaTransport(String kind, BuildContext context) async {
    if (_closed || state.isConnected || state.isConnecting) return;
    if (kind == _arg.transport) {
      await connectToCurrentSession();
      return;
    }
    // The TARGET transport's own address from the per-transport map: a
    // chat created over another radio holds no meaningful value in its
    // single stored address (a Wi‑Fi Direct p2p MAC is not dialable over
    // Bluetooth). The map entry — learned whenever a link over that
    // transport was live — is dialed instead; a missing entry means
    // "discover the peer by name" on the target transport.
    final address = state.chatSession.addressFor(kind);
    final name = state.chatSession.name;
    final target = ref.read(chatBindingProvider(kind));
    final l10n = ref.read(appLocalizationsProvider);
    final outcome = await showConnectingPanel(
      context: context,
      deviceName: name,
      // The panel closes when the dial stops (this closure resolves); the
      // outcome reporting below reads the TARGET transport's live state.
      connect: () async {
        await dialTransportPeer(kind, address: address, name: name);
      },
      onCancel: target.cancelPendingConnect,
    );
    if (_closed || outcome == ConnectingOutcome.cancelled) return;
    // Mirror the scan screens' outcome reporting against the TARGET
    // transport: only a genuinely dead attempt (no link, nothing pending)
    // reports failure; a live link still awaiting the peer's acceptance
    // gets the waiting notice; a decline is already surfaced by the
    // target's own notice card — never stack a second one on it.
    final connected = target.isConnected;
    final awaiting = target.isAwaitingAcceptance;
    final declined = target.lastConnectError == l10n.connectionDeclinedMessage;
    if (!connected && !declined) {
      if (!awaiting) {
        _showNotice(
          l10n.couldNotConnectTitle,
          target.lastConnectError ?? l10n.couldNotConnectMessage,
          icon: Icons.error_outline,
        );
      } else {
        _showNotice(
          l10n.waitingAcceptanceTitle,
          l10n.waitingAcceptanceMessage,
          icon: Icons.hourglass_top,
          accent: Colors.amber,
        );
      }
    }
  }

  /// Dials the stored peer over [kind] through that transport's binding:
  /// its session-reconnect flow (discovery + match + connect), then waits
  /// until the dial settles (acceptance / rejection / drop / cancel) — the
  /// same sequence the scan screens run. Returns the dial result (null when
  /// the attempt threw). Kept UI-free so the cross-transport flow is
  /// testable without a widget tree.
  @visibleForTesting
  Future<bool?> dialTransportPeer(
    String kind, {
    required String? address,
    required String? name,
  }) async {
    final target = ref.read(chatBindingProvider(kind));
    bool ok;
    try {
      ok = await target.connectToSessionPeer(address: address, name: name);
    } catch (e) {
      if (kDebugMode) debugPrint('Cross-transport connect failed: $e');
      return null;
    }
    if (!ok && !target.isAwaitingAcceptance) return ok;
    await target.dialSettled;
    return ok;
  }

  /// Applies a peer-reported device name (WFD sockets carry no name on the
  /// wire) to the app bar and the persisted session — an UPGRADE only: a
  /// raw model code must not downgrade a stored display name.
  void _updateSessionName(String name) {
    if (_closed || name.isEmpty) return;
    if (state.peerName != name) {
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
          deviceAddresses: session.deviceAddresses,
          // The user's nickname rides the rename — a live name upgrade must
          // never drop the chosen title.
          nickname: session.nickname,
        );
        state = state.copyWith(peerName: name, chatSession: renamed);
        _scheduleSave();
      }
      // else: downgrade blocked — keep both the stored title and peerName.
    }
    // Attempted even for a repeated name: a first emission can land while
    // the open is still settling (the fresh-open flag is only set after its
    // DB round-trips), burning the once-only merge attempt — the repeat
    // (the peer re-sends its identity right after the handshake) must be
    // able to retry it. The merge's own flags make repeats cheap.
    unawaited(_mergeLatePeerSession());
  }

  /// Late identity merge: the chat opened while the peer identity was still
  /// unknown (rotated P2P MAC / identity frame in flight), so the open
  /// MISSed and created a fresh session; the identity frame has now arrived
  /// — if a stored session matches the peer (address, uid or a
  /// normalization-insensitive name), it is the same conversation: adopt
  /// its history here and delete the duplicate so the history sync and the
  /// home list stay in ONE chat.
  Future<void> _mergeLatePeerSession() async {
    if (_closed || !_openedAsFreshSession || _lateMergeDone) return;
    final duplicate = await _findExistingSessionForPeer(
      excludeId: state.chatSession.id,
    );
    if (_closed) return;
    if (duplicate == null || duplicate.id == state.chatSession.id) return;
    _lateMergeDone = true;
    await _absorbPeerSession(duplicate);
    if (_closed) return;
    _scheduleSave();
    // The merged history may be exactly what the peer is missing: run the
    // sync again now that the session holds the real conversation.
    _syncSentForSession = false;
    unawaited(_sendHistorySync());
  }

  /// Absorbs a stored session of the SAME peer into the open session: the
  /// message union (identity dedup, newest-first — matching the list
  /// contract everywhere else) persists under the open session's id, and
  /// the duplicate row is removed. The union runs over the COMPLETE stored
  /// histories (loaded here on demand): the in-memory list only holds the
  /// visible window, and the full-state rewrite below must not drop the
  /// unloaded part.
  Future<void> _absorbPeerSession(ChatSessionModel duplicate) async {
    final session = state.chatSession;
    final targetFull = await _repo.loadChatSession(session.id);
    final duplicateFull =
        await _repo.loadChatSession(duplicate.id) ?? duplicate;
    if (_closed) return;
    final seen = <String>{};
    final combined = <MessageModel>[];
    for (final m in [
      ...duplicateFull.messages,
      ...(targetFull?.messages ?? state.messages),
    ]) {
      final k = m.id ??
          '${m.timestamp.microsecondsSinceEpoch}|${m.isSentByMe}|'
              '${m.text}|${m.imagePath}';
      if (seen.add(k)) combined.add(m);
    }
    combined.sort((a, b) => b.timestamp.compareTo(a.timestamp));
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
      // The absorbed row may hold the OTHER transport's address (sibling
      // rows split by channel): the union keeps both entries — a later
      // pick of either transport dials its own address.
      deviceAddresses: {
        ...duplicate.deviceAddresses,
        ...session.deviceAddresses,
      },
      // The user's chosen title survives the absorb: the live row's
      // nickname wins, the absorbed sibling's is adopted when the live row
      // has none (a nickname set on the old row keeps showing after the
      // merge).
      nickname: session.nickname ?? duplicate.nickname,
    );
    try {
      await _repo.saveChatSession(merged);
      await _repo.deleteChatSession(duplicate.id);
      if (kDebugMode) {
        debugPrint(
          'Peer session merged: absorbed "${duplicate.name}" '
          '(${duplicate.id}) into ${merged.id} — ${combined.length} messages',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Peer session merge failed: $e');
      }
    }
    if (_closed) return;
    // The state carries the visible window of the merged history.
    final window = _windowSlice(combined);
    merged.messages = window;
    state = state.copyWith(
      chatSession: merged,
      messages: window,
      hasMoreOlder: combined.length > window.length,
    );
  }

  /// Absorbs every stored session that belongs to the CURRENT peer into the
  /// open one. A direct top-level key hit skips the miss-path peer search,
  /// so a same-peer row left behind by another transport era (or by the
  /// pre-display-name era, when the name search could not match) would stay
  /// split — and worse, each device could open ITS row for one connection
  /// and end up in DIFFERENT conversations (device-reported: after a BT →
  /// Wi‑Fi Direct connect the Redmi reopened the BT-era chat while the J7
  /// opened its old WFD row). Repeated matches are capped defensively.
  Future<void> _reconcilePeerSiblings() async {
    for (var i = 0; i < 5; i++) {
      final duplicate = await _findExistingSessionForPeer(
        excludeId: state.chatSession.id,
      );
      if (_closed) return;
      if (duplicate == null) return;
      await _absorbPeerSession(duplicate);
      if (_closed) return;
    }
  }

  /// Finds an existing session for the current peer when the computed key
  /// misses: by the peer's device address (MAC), by the peer's STABLE
  /// per-install uid (WFD identity frame — a session keyed on it is this
  /// peer's by construction), then by the peer's reported name (model — so
  /// the same device always shows up as one chat; the identical-model edge
  /// case of two same phones is accepted for a P2P app). [excludeId] skips
  /// the live session's own row so the search never returns itself and
  /// shadows the real sibling.
  Future<ChatSessionModel?> _findExistingSessionForPeer({
    String? excludeId,
  }) async {
    try {
      final all = await _repo.getAllSessionsMeta();
      final peerMac = _binding.connectedDeviceKey;
      final peerUid = _binding.connectedDeviceId;
      final peerName = _binding.connectedDeviceName;
      if (kDebugMode) {
        debugPrint(
          'Peer merge search: mac=$peerMac uid=$peerUid name=$peerName '
          'exclude=$excludeId over '
          '${all.map((s) => '${s.name}[${s.id}]').toList()}',
        );
      }
      if (peerMac != null &&
          peerMac.isNotEmpty &&
          peerMac != 'unknown' &&
          peerMac != '02:00:00:00:00:00') {
        for (final s in all) {
          if (s.id == excludeId) continue;
          // The single stored address — or any per-transport entry: a
          // sibling row may carry this MAC in its map while its single
          // address (the winning transport's) holds something else.
          if (s.device['address'] == peerMac ||
              s.deviceAddresses.containsValue(peerMac)) {
            return s;
          }
        }
      }
      if (peerUid != null && peerUid.isNotEmpty && peerUid != 'unknown') {
        for (final s in all) {
          if (s.id != excludeId && s.id == peerUid) return s;
        }
      }
      if (peerName != null && peerName.isNotEmpty && peerName != 'unknown') {
        // Names reach us from different sources (discovery name, identity
        // frame's model name, socket map) and may differ in case, spacing
        // or punctuation — compare normalized.
        final target = _normalizePeerName(peerName);
        for (final s in all) {
          if (s.id != excludeId && _normalizePeerName(s.name) == target) {
            return s;
          }
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
        // Confirm receipt back to the peer: its bubble flips to delivered.
        _queueDeliveryAck(_textDeliveryFp(text));
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

  // ── Delivery fingerprints & the ack exchange ───────────────────────────
  //
  // The receiver confirms every peer message it stores with a content
  // fingerprint batched into an `ack` sync frame; the sender flips matching
  // outgoing bubbles to `delivered`. Fingerprints are content-based and
  // identical on both ends by construction: text → `d:t:<sha256(text)>`,
  // media → `d:m:<sha256(exact stored bytes)>` (the stored media copy IS
  // the wire copy — the byte-identity invariant the image pipeline keeps).

  /// Receiver fingerprint of a text message.
  String _textDeliveryFp(String text) =>
      'd:t:${sha256.convert(utf8.encode(text)).toString()}';

  /// Receiver fingerprint of a media message (exact stored bytes).
  String _mediaDeliveryFp(Uint8List bytes) =>
      'd:m:${sha256.convert(bytes).toString()}';

  /// Sets the delivery state of the message with [id] (no-op without one).
  /// Never downgrades a delivered message and skips same-state writes.
  void _markDelivery(String? id, String status) {
    if (_closed || id == null) return;
    final msgs = List.of(state.messages);
    final idx = msgs.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final cur = msgs[idx];
    if (cur.delivery == status ||
        cur.delivery == MessageModel.deliveryDelivered) {
      return;
    }
    msgs[idx] = cur.copyWith(delivery: status);
    state = state.copyWith(messages: msgs);
    _scheduleSave();
  }

  /// Queues a receipt confirmation for one received peer message. Acks are
  /// batched ([ackFlushDelay]) into a single `ack` frame — syncing ten
  /// messages acks once. Set semantics dedupe fingerprints.
  void _queueDeliveryAck(String fp) {
    if (_closed) return;
    _pendingAckFps.add(fp);
    // A very large batch (long history sync) flushes early: the frame must
    // stay far below the sync-progress banner threshold.
    if (_pendingAckFps.length >= _ackBatchCap) {
      _flushDeliveryAcks();
      return;
    }
    _ackFlushTimer ??= Timer(ackFlushDelay, _flushDeliveryAcks);
  }

  void _flushDeliveryAcks() {
    _ackFlushTimer?.cancel();
    _ackFlushTimer = null;
    if (_pendingAckFps.isEmpty) return;
    final items = _pendingAckFps.toList();
    _pendingAckFps.clear();
    if (_closed || !_binding.isConnected) return; // no socket to answer on
    // Rides outside the user send queue, like every other sync frame.
    _sendText(
      _syncPrefix + jsonEncode({'type': 'ack', 'items': items}),
    );
  }

  /// Applies an incoming `ack` batch: the peer stored these fingerprints →
  /// matching outgoing messages flip to `delivered`.
  Future<void> _applyDeliveryAcks(dynamic itemsRaw) async {
    if (itemsRaw is! List || itemsRaw.isEmpty) return;
    final fps = itemsRaw.whereType<String>().toSet();
    if (fps.isEmpty) return;
    await _markDeliveredMatching(fps);
  }

  /// Marks outgoing messages delivered when one of their fingerprints is in
  /// [hashes]. Text matches by the text fingerprint (cheap); media by the
  /// stored-bytes fingerprint with a lazy per-message hash cache. Async
  /// file reads run against a snapshot and the final write re-reads the
  /// list, applying by id — a live frame landing mid-scan is never
  /// clobbered.
  Future<void> _markDeliveredMatching(Set<String> hashes) async {
    if (_closed) return;
    final snapshot = List.of(state.messages);
    final matched = <String>{};
    var examined = 0;
    for (final m in snapshot) {
      if (examined >= _deliveryMatchScanCap) break;
      if (!m.isSentByMe ||
          m.isTransferring ||
          m.delivery == MessageModel.deliveryDelivered) {
        continue;
      }
      examined++;
      final textHash = sha256.convert(utf8.encode(m.text)).toString();
      if (hashes.contains('d:t:$textHash')) {
        if (m.id != null) matched.add(m.id!);
        continue;
      }
      final path = m.imagePath;
      if (path == null || path.isEmpty) continue;
      final cacheKey = m.id ?? 'p:$path';
      var mediaHash = _deliveryFpCache[cacheKey];
      if (mediaHash == null) {
        try {
          mediaHash = sha256.convert(await File(path).readAsBytes()).toString();
          _deliveryFpCache[cacheKey] = mediaHash;
        } catch (_) {
          continue; // unreadable file: keep the message as sent
        }
      }
      if (hashes.contains('d:m:$mediaHash')) {
        if (m.id != null) matched.add(m.id!);
      }
    }
    if (_closed || matched.isEmpty) return;
    final msgs = List.of(state.messages);
    var changed = false;
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.id != null &&
          matched.contains(m.id) &&
          m.delivery != MessageModel.deliveryDelivered) {
        msgs[i] = m.copyWith(delivery: MessageModel.deliveryDelivered);
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(messages: msgs);
      _scheduleSave();
    }
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
    // frames FIFO natively). The exact frame is kept so a re-delivery
    // (see _redeliverManifestAndReading) costs no re-hash.
    final frame = _syncPrefix +
        jsonEncode({
          'type': 'manifest',
          // Data-plane protocol version: absent on pre-versioning builds
          // (read as v1). A mismatch against the peer's is logged.
          'pv': syncProtocolVersion,
          'items': [
            for (final e in counts.entries) {'h': e.key, 'n': e.value},
          ],
        });
    _lastManifestFrame = frame;
    _sendText(frame);
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
      _syncPrefix +
          jsonEncode({
            'type': 'fetch',
            'id': id,
            // Repair keys for id-diverged replicas (live voice/file
            // transfers used to mint receiver-side ids): the peer falls
            // back to a content match when the id misses. Old peers read
            // only `id`.
            'kind': message.transferKind,
            'caption': message.text,
            'size': message.remoteMediaSize,
          }),
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

  /// Shares our signal reading with the peer — the accepting side never
  /// scanned and cannot read the link itself, so whoever HAS a reading
  /// pushes it:
  /// - Bluetooth: the dialer's scan-time value. It is static, so a single
  ///   share (plus one retry for the peer's chat opening a beat late) is
  ///   enough; no platform API reads a connected RFCOMM link live.
  /// - Wi‑Fi Direct: the CLIENT side's live readback (`connectionInfo`) —
  ///   the GO side has none, so this push is the only way the GO's panel
  ///   can show a signal. The value changes over time: it is re-shared on
  ///   [linkShareRefreshInterval] while connected (change-guarded), so the
  ///   peer's "(peer reading)" tracks the real link.
  Future<void> _sharePeerSignal() async {
    if (_closed || !state.isConnected) return;
    final scan = _binding.connectedDeviceRssi;
    final int? reading = scan ?? await _binding.getLiveRssi();
    if (_closed || !state.isConnected) return;
    if (reading != null) {
      _lastSharedRssi = reading;
      _sendLinkShare(reading);
      _linkShareRetry?.cancel();
      _linkShareRetry = Timer(linkShareRetryDelay, () {
        if (_closed || !state.isConnected) return;
        _sendLinkShare(reading);
      });
    }
    if (scan == null &&
        _binding.transportType == ChatSessionModel.transportWifiDirect) {
      // No dial-time value on Wi‑Fi Direct: whatever we have (or may read
      // once the association settles) is the LIVE link readback — keep
      // (re)sharing it; the ticker also retries the first read.
      _startLinkShareTicker();
    }
  }

  void _sendLinkShare(int rssi) {
    unawaited(
      _sendText(
        '$_syncPrefix${jsonEncode({'type': 'linkShare', 'rssi': rssi})}',
      ),
    );
  }

  void _startLinkShareTicker() {
    if (_linkShareTicker != null) return;
    _linkShareTicker = Timer.periodic(linkShareRefreshInterval, (_) async {
      if (_closed || !state.isConnected) return;
      final live = await _binding.getLiveRssi();
      if (_closed || !state.isConnected || live == null) return;
      final last = _lastSharedRssi;
      if (last != null && (live - last).abs() < _linkShareMinDelta) return;
      _lastSharedRssi = live;
      _sendLinkShare(live);
    });
  }

  /// One-shot safety net (see [syncNudgeDelay]): a live peer's manifest
  /// should have arrived by now — its absence means both first passes may
  /// have raced, so re-deliver once.
  void _onSyncNudge() {
    _syncNudgeTimer = null;
    if (_closed || !state.isConnected) return;
    if (_receivedPeerManifest) return;
    _redeliverManifestAndReading();
  }

  /// Re-delivers our manifest frame (verbatim — the peer's pull heals from
  /// its diff) and our reading, at most once per connection. Fired by the
  /// peer's first manifest (their readiness signal) or the nudge safety
  /// net; the once-guard keeps the exchange bounded (no ping-pong).
  void _redeliverManifestAndReading() {
    if (_closed || _redeliveredManifest) return;
    _redeliveredManifest = true;
    final frame = _lastManifestFrame;
    if (frame != null) _sendText(frame);
    unawaited(_sharePeerSignal());
  }

  /// Dispatches an incoming sync packet by its `type`:
  /// - `manifest`  → compare against local messages, request what's missing
  /// - `request`   → send the requested messages (as `message` packets)
  /// - `message`   → integrate the peer's messages into local history
  /// - `fetch`     → send one message's media file (deferred download)
  /// - `download`  → the file we asked for (fills a placeholder bubble)
  /// - `fetchMiss` → the peer no longer holds the requested file
  /// - `linkShare` → the peer's signal reading (the dialer's scan value on
  ///   Bluetooth; the client side's live readback on Wi‑Fi Direct), pushed
  ///   for the quality panel (older builds ignore the unknown type via
  ///   their `default:`).
  /// - `ack`       → the peer confirmed it stored the listed message
  ///   fingerprints — matching outgoing bubbles flip to `delivered` (the
  ///   delivery-tick confirmation; unknown to older builds, which ignore
  ///   it via `default:` and simply stay on single ticks).
  Future<void> _applyHistorySync(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final type = decoded['type'] as String? ?? 'message';
      switch (type) {
        case 'message':
          await _applySyncMessages(decoded['messages']);
        case 'manifest':
          _receivedPeerManifest = true;
          // Their manifest exists only once their callback wiring is done —
          // it doubles as their readiness signal. Our first pass can race a
          // slow peer (device-reported: the receiver's panel showed no
          // signal because both our frames landed pre-wiring), so respond
          // once with our manifest + reading.
          _redeliverManifestAndReading();
          _logPeerProtocolVersion(decoded['pv']);
          await _handleSyncManifest(decoded['items']);
        case 'request':
          await _handleSyncRequest(decoded['items']);
        case 'fetch':
          await _handleSyncFetch(decoded);
        case 'download':
          await _applySyncMessages(decoded['messages']);
        case 'fetchMiss':
          _handleFetchMiss(decoded['id']);
        case 'linkShare':
          final rssi = (decoded['rssi'] as num?)?.toInt();
          if (rssi != null && rssi >= -100 && rssi <= -1) {
            _peerReportedRssi = rssi;
          }
        case 'ack':
          await _applyDeliveryAcks(decoded['items']);
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
    // Counts over the loaded window (it always covers the newest messages a
    // manifest can name); a race with paged loading only causes an
    // over-request, and the apply side dedups against the full store.
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
  ///
  /// The lookup is by id first — then by CONTENT (kind + caption + exact
  /// byte size): live voice/file transfers used to mint receiver-side ids,
  /// so the same message can carry different ids on the two replicas while
  /// this side still holds the file. The requester's placeholder has
  /// exactly those three keys, and for a live transfer they are exact.
  Future<void> _handleSyncFetch(Map<dynamic, dynamic> frame) async {
    final id = frame['id'] is String ? frame['id'] as String : null;
    if (id == null) return;
    MessageModel? target;
    for (final m in state.messages) {
      if (m.id == id) {
        target = m;
        break;
      }
    }
    if (target?.imagePath == null) {
      final kind = frame['kind'];
      final caption = frame['caption'];
      final size = frame['size'];
      if (kind is String && caption is String && size is int && size > 0) {
        for (final m in state.messages) {
          if (m.imagePath == null) continue;
          if (m.transferKind != kind || m.text != caption) continue;
          try {
            final f = File(m.imagePath!);
            if (await f.exists() && f.lengthSync() == size) {
              target = m;
              break;
            }
          } catch (_) {
            // Unreadable candidate: keep looking.
          }
        }
      }
    }
    final path = target?.imagePath;
    if (target != null && path != null) {
      try {
        final file = File(path);
        if (await file.exists() && file.lengthSync() <= _syncMaxFetchBytes) {
          _sendText(
            _syncPrefix +
                jsonEncode({
                  'type': 'download',
                  'messages': [await _syncEntryFor(target, forceBytes: true)],
                }),
          );
          return;
        }
      } catch (_) {
        // Unreadable file: fall through to the miss below.
      }
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

        // Confirm receipt back to the peer — media by the exact persisted
        // bytes, everything else by the text (placeholder entries included:
        // their text IS the peer's caption). Queued even for duplicates: a
        // re-serve after a lost ack must still flip the sender's tick.
        if (mediaBytes != null) {
          _queueDeliveryAck(_mediaDeliveryFp(mediaBytes));
        } else {
          _queueDeliveryAck(_textDeliveryFp(text));
        }

        // Deferred-download completion: an entry that carries the media of
        // a message we already hold as a placeholder (same id, no file yet)
        // is not a duplicate — it is the file we asked for. Fill the bubble
        // (clears the spinner and the pending marker in one step).
        final entryId = entry['id'] as String?;
        if (mediaBytes != null && entryId != null) {
          final int payloadLen = mediaBytes.length;
          var idx = state.messages.indexWhere((m) => m.id == entryId);
          if (idx == -1 || !state.messages[idx].hasRemoteMedia) {
            // Id-diverged replicas (live voice/file transfers used to mint
            // receiver-side ids — the mirror of the serve-side content
            // fallback): the file we asked for may belong to a LOCAL
            // placeholder under a different id. Match by content: same
            // kind + same caption, size equal to the payload (or unknown).
            final String? wantKind =
                isAudioEntry ? 'audio' : (isFileEntry ? 'file' : null);
            if (wantKind != null) {
              final localIdx = state.messages.indexWhere(
                (m) =>
                    m.hasRemoteMedia &&
                    m.transferKind == wantKind &&
                    m.text == text &&
                    (m.remoteMediaSize == 0 ||
                        m.remoteMediaSize == payloadLen),
              );
              if (localIdx != -1) idx = localIdx;
            }
          }
          if (idx != -1 && state.messages[idx].hasRemoteMedia) {
            final String? localId = state.messages[idx].id;
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
            if (downloaded != null && localId != null) {
              completions.add(
                (id: localId, path: downloaded, isAudio: isAudioEntry),
              );
              _settleFetch(localId);
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
        if (!alreadyHave) {
          // The loaded window may not cover the whole history: a copy of
          // this message may already exist BELOW it (a manifest over-request
          // re-serves old messages), and integrating it again would
          // duplicate the row. One indexed existence check.
          alreadyHave = await _repo.hasMessageNear(
            state.chatSession.id,
            text: text,
            isSentByMe: sentByMe,
            timestamp: ts,
          );
        }
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
              // A fetched file coming back must not erase the delivery
              // tick (the row kept it through the placeholder flip).
              delivery: cur.delivery,
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
    // Receipt confirmation back to the sender (exact persisted bytes).
    _queueDeliveryAck(_mediaDeliveryFp(bytes));
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
        // The write loop reached the final byte: handed to the socket. The
        // peer's ack upgrades this to delivered later.
        delivery: MessageModel.deliverySent,
      );
      finalized = true;
      _sendingImagePath = null;
      _pendingOutgoingBytes = null;
      _pendingOutgoingAudioText = null;
      _pendingOutgoingFileText = null;
      _pendingOutgoingMessageId = null;
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
    _pendingOutgoingMessageId = null;
    _sendingImagePath = null;
    if (idx == -1) return;
    final l10n = ref.read(appLocalizationsProvider);
    msgs[idx] = msgs[idx].copyWith(
      text: wasFile
          ? l10n.fileSendFailed
          : (wasAudio ? l10n.audioSendFailed : l10n.imageSendFailed),
      isTransferring: false,
      delivery: MessageModel.deliveryFailed,
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
      // An outgoing voice/file bubble is born with the SENDER-MINTED id
      // (already on the wire in its announcement): the finalize keeps the
      // bubble's id, so both replicas stay on one identity.
      id: (isSentByMe ? _pendingOutgoingMessageId : null) ?? Uuid().v4(),
      text: _progressPercent(state),
      isSentByMe: isSentByMe,
      timestamp: DateTime.now(),
      transferCurrent: state.current,
      transferTotal: state.total,
      isTransferring: true,
      transferKind: 'bytes',
      // Only outgoing transfers carry a delivery state (incoming messages
      // need none — their arrival is self-evident).
      delivery: isSentByMe ? MessageModel.deliveryPending : null,
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
      // serialized behind any in-flight transfer. The bubble starts
      // `pending` and flips to `sent` when the socket write completes.
      final id = Uuid().v4();
      final msgs = List.of(state.messages);
      msgs.insert(
        0,
        MessageModel(
          id: id,
          text: text,
          isSentByMe: true,
          timestamp: DateTime.now(),
          delivery: MessageModel.deliveryPending,
        ),
      );
      state = state.copyWith(messages: msgs);
      _scheduleSave();
      textController.clear();
      _enqueueSend(_OutgoingJob.text(text, messageId: id));
    }
  }

  /// Clears the conversation: the visible window empties, the stored
  /// messages are removed explicitly (windowed saves can no longer drop
  /// them implicitly) and the session row is stamped via the regular save.
  Future<void> clearConversation() async {
    if (_closed) return;
    // Drop any pending debounced write first — a stale snapshot must not
    // race the cleared conversation back into the store.
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _pendingSaveSnapshot = null;
    state = state.copyWith(messages: const [], hasMoreOlder: false);
    try {
      await _repo.clearSessionMessages(state.chatSession.id);
      await _repo.saveChatSessionWindow(_snapshotSession());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Chat clear failed: $e');
      }
    }
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
        await _repo.saveChatSessionWindow(snapshot);
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
      await _repo.saveChatSessionWindow(snapshot);
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

  /// Removes one of the user's own messages by id (UI + stored row).
  /// Local only: the peer's copy is untouched, so a later history sync may
  /// re-deliver the message.
  void deleteMessage(String? id) {
    if (_closed || id == null) return;
    final msgs = List.of(state.messages);
    final idx = msgs.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    msgs.removeAt(idx);
    state = state.copyWith(messages: msgs);
    // The windowed save is an upsert — a removed message needs an explicit
    // row delete (the old full rewrite used to drop it implicitly). The
    // scheduled save is kept too: it replaces any PENDING snapshot taken
    // before the removal (its late flush would upsert the message back in).
    unawaited(_deleteStoredMessage(id));
    _scheduleSave();
  }

  Future<void> _deleteStoredMessage(String id) async {
    try {
      await _repo.deleteMessageRow(id);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Message delete failed: $e');
      }
    }
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

  /// Opens a received file with the system viewer (util channel). Package
  /// archives (APK) are NOT opened here — the app holds no install-packages
  /// permission (Google Play restricts it), so they are saved into the
  /// public Downloads folder and the notice points at the file manager.
  Future<void> openReceivedFile(String path) async {
    if (_closed) return;
    if (path.toLowerCase().endsWith('.apk')) {
      await _saveApkToDownloads(path);
      return;
    }
    var outcome = 'failed';
    try {
      outcome = await UtilPlatformChannel.openFile(path);
    } catch (e) {
      if (kDebugMode && showDebugLogs) debugPrint('openFile failed: $e');
    }
    if (_closed || outcome == 'opened') return;
    final l10n = ref.read(appLocalizationsProvider);
    _showNotice(
      l10n.fileOpenFailedTitle,
      l10n.fileOpenFailed,
      icon: Icons.error_outline,
    );
  }

  /// Copies a received APK into the public Downloads folder so the user can
  /// install it from the file manager (Android 10+ via MediaStore — no
  /// permission needed; below 10 a storage grant is requested and the copy
  /// retried once).
  Future<void> _saveApkToDownloads(String path) async {
    var outcome = 'failed';
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        outcome = await UtilPlatformChannel.saveApkToDownloads(path);
      } catch (e) {
        if (kDebugMode && showDebugLogs) {
          debugPrint('saveApkToDownloads failed: $e');
        }
        outcome = 'failed';
      }
      if (outcome != 'permission' || _closed) break;
      final status = await Permission.storage.request();
      if (!status.isGranted) break;
    }
    if (_closed) return;
    final l10n = ref.read(appLocalizationsProvider);
    if (outcome == 'saved') {
      _showNotice(
        l10n.apkSavedTitle,
        l10n.apkSavedMessage,
        icon: Icons.download_done_outlined,
        accent: Colors.green,
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
    // Sender-minted id: announced with the file so the receiver's row
    // adopts it (see _OutgoingJob.messageId) — the replicas share ONE
    // identity and the fetch flow resolves on either side.
    _enqueueSend(
      _OutgoingJob.bytes(bytes, path,
          fileName: fileName, messageId: Uuid().v4()),
    );
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
    final id = Uuid().v4();
    final msgs = List.of(state.messages);
    msgs.insert(
      0,
      MessageModel(
        id: id,
        text: text,
        isSentByMe: true,
        timestamp: DateTime.now(),
        delivery: MessageModel.deliveryPending,
      ),
    );
    state = state.copyWith(messages: msgs);
    _scheduleSave();
    _enqueueSend(_OutgoingJob.text(text, messageId: id));
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
                jsonEncode({
                  'name': fileName,
                  'size': job.bytes!.length,
                  // Sender-minted id; old receivers ignore the extra key
                  // (they keep minting locally — healed by the fetch
                  // content fallback).
                  if (job.messageId != null) 'id': job.messageId,
                }),
          );
        }
        // Wire these before sendBytes so progress callbacks can finalize the
        // bubble; cleared on completion/failure in _updateOutgoingProgress.
        _pendingOutgoingBytes = job.bytes;
        _sendingImagePath = job.imagePath;
        _pendingOutgoingAudioText = job.audioText;
        _pendingOutgoingFileText = fileName;
        _pendingOutgoingMessageId = job.messageId;
        await _sendBytesFrame(job.bytes!);
      } else {
        await _sendText(job.text!);
        // The socket write completed — the message is on its way; the
        // peer's ack upgrades it to `delivered` later.
        _markDelivery(job.messageId, MessageModel.deliverySent);
      }
    } catch (_) {
      // A thrown send resolves the transfer through the same failure path
      // the stall watchdog and disconnects use: every pending marker is
      // cleared (audio text included) and only the transfer's OWN bubble is
      // marked — the old inline fallback could overwrite the newest message
      // (index 0) when no progress event had ever arrived.
      if (job.kind == _SendKind.bytes && !_closed) {
        _failOutgoingTransfer();
      } else if (job.kind == _SendKind.text && !_closed) {
        // A failed text write used to vanish silently; the bubble's red
        // alert icon is now the visible outcome.
        _markDelivery(job.messageId, MessageModel.deliveryFailed);
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
    // One id for the wire and both bubbles: the announcement carries it so
    // the receiver adopts it, and the sender's progress bubble is minted
    // with it — the two replicas stay on ONE identity (the fetch flow then
    // resolves on either side; without this each side minted its own id
    // and a deferred download missed on the peer that held the file).
    final id = Uuid().v4();
    _enqueueSend(
      _OutgoingJob.text(
        _audioPrefix +
            jsonEncode({'duration': _formatDuration(seconds), 'id': id}),
      ),
    );
    _enqueueSend(
      _OutgoingJob.bytes(await file.readAsBytes(), path,
          audioText: _formatDuration(seconds), messageId: id),
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
    String? senderId;
    if (meta != null && meta.isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        durationText = (decoded['duration'] as String?) ?? '0:00';
        // Sender-minted id (new senders): adopting it keeps both replicas
        // on ONE identity — the deferred-download fetch and every id-based
        // flow then resolve on both sides. Old senders omit it.
        final rawId = decoded['id'];
        if (rawId is String && rawId.isNotEmpty) senderId = rawId;
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
    final existingIdx =
        senderId == null ? -1 : msgs.indexWhere((m) => m.id == senderId);
    if (existingIdx != -1) {
      // The sync path already materialized this message (possibly as a
      // placeholder): fill its file and drop the local transfer bubble.
      msgs[existingIdx] = msgs[existingIdx].copyWith(
        text: durationText ?? msgs[existingIdx].text,
        imagePath: filePath,
        isTransferring: false,
        transferKind: 'audio',
      );
      if (idx != -1) msgs.removeAt(idx);
    } else if (idx != -1) {
      final bubble = msgs[idx];
      if (senderId != null && bubble.id != senderId) {
        // Finalize under the sender's id: MessageModel.id is final, so the
        // row is re-created (the transfer bubble has no other referents).
        msgs[idx] = MessageModel(
          id: senderId,
          text: durationText ?? bubble.text,
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
          transferKind: 'audio',
        );
      } else {
        msgs[idx] = bubble.copyWith(
          text: durationText ?? bubble.text,
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
          isTransferring: false,
          transferKind: 'audio',
        );
      }
    } else {
      msgs.insert(
        0,
        MessageModel(
          id: senderId ?? Uuid().v4(),
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
    // Receipt confirmation back to the sender (exact persisted bytes).
    _queueDeliveryAck(_mediaDeliveryFp(bytes));
  }

  /// Processes an incoming file transfer: persists the bytes under the
  /// announced name (sanitized; collisions get a timestamp prefix) and
  /// finalizes the transfer bubble as a file message.
  Future<void> _handleIncomingFile(Uint8List bytes) async {
    if (_closed) return;
    final meta = _pendingIncomingFileMeta;
    _pendingIncomingFileMeta = null;
    var name = 'file';
    String? senderId;
    if (meta != null && meta.isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        name = _sanitizeFileName((decoded['name'] as String?) ?? name);
        // Sender-minted id (see _handleIncomingAudio).
        final rawId = decoded['id'];
        if (rawId is String && rawId.isNotEmpty) senderId = rawId;
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
    final existingIdx =
        senderId == null ? -1 : msgs.indexWhere((m) => m.id == senderId);
    if (existingIdx != -1) {
      // The sync path already materialized this message (possibly as a
      // placeholder): fill its file and drop the local transfer bubble.
      msgs[existingIdx] = msgs[existingIdx].copyWith(
        text: caption,
        imagePath: filePath,
        isTransferring: false,
        transferKind: 'file',
      );
      if (idx != -1) msgs.removeAt(idx);
    } else if (idx != -1) {
      final bubble = msgs[idx];
      if (senderId != null && bubble.id != senderId) {
        // Finalize under the sender's id (see _handleIncomingAudio).
        msgs[idx] = MessageModel(
          id: senderId,
          text: caption,
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
          transferKind: 'file',
        );
      } else {
        msgs[idx] = bubble.copyWith(
          text: caption,
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
          isTransferring: false,
          transferKind: 'file',
        );
      }
    } else {
      msgs.insert(
        0,
        MessageModel(
          id: senderId ?? Uuid().v4(),
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
    // Receipt confirmation back to the sender (exact persisted bytes).
    _queueDeliveryAck(_mediaDeliveryFp(bytes));
  }
}
