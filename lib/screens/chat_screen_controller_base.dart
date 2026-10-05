import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:chatblue/screens/homescreen/home_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:get/get.dart';
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
        audioText = null;

  _OutgoingJob.bytes(Uint8List this.bytes, this.imagePath, {this.audioText})
      : kind = _SendKind.bytes,
        text = null;

  final _SendKind kind;
  final String? text;
  final Uint8List? bytes;
  final String? imagePath;

  /// When set, the transferred bytes are a voice recording and the bubble
  /// finalizes as an audio message with this duration caption.
  final String? audioText;
}

/// Shared implementation for the Bluetooth and Wi‑Fi Direct chat screens.
///
/// Both transports expose the same surface through [ChatTransport], so all
/// conversation logic — message list, image transfers with progress bubbles,
/// persistence — lives here once instead of being duplicated per transport.
abstract class ChatScreenControllerBase extends GetxController {
  ChatScreenControllerBase(this.transport);

  final ChatTransport transport;

  late ChatSessionModel chatSession;
  final RxList<MessageModel> messages = <MessageModel>[].obs;
  final TextEditingController textController = TextEditingController();

  RxBool get isConnected => transport.isConnected;

  /// Peer-reported device name (WFD peers don't carry a name on the socket);
  /// drives the app bar title reactively when the transport has no name.
  final RxString peerName = RxString('');

  /// True while a manual reconnect (Connect button) attempt is in flight.
  final RxBool isConnecting = false.obs;

  /// Visible while a history sync packet is being received/applied.
  final RxBool isSyncing = false.obs;

  /// 0..1 progress of the incoming sync frame (drives the thin header bar).
  final RxDouble syncProgress = 0.0.obs;

  // ── Voice messages ──────────────────────────────────────────────────────
  final RxBool isRecording = false.obs;
  final RxInt recordSeconds = 0.obs;
  Timer? _recordTimer;
  AudioRecorder? _recorder;
  String? _recordingPath;

  /// Id of the audio bubble currently playing (null when idle).
  final Rxn<String> playingAudioId = Rxn<String>();

  /// Mirror of the player's playing state (drives play/pause icons).
  final RxBool isAudioPlaying = false.obs;

  /// 0..1 playback position of the playing bubble.
  final RxDouble audioProgress = 0.0.obs;

  /// Duration of the loaded track in milliseconds (0 when nothing loaded).
  double get audioDurationMs =>
      _audioPlayer.duration?.inMilliseconds.toDouble() ?? 0;
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// Duration caption of an incoming voice transfer (announced by the peer
  /// right before the bytes arrive).
  String? _pendingAudioMeta;

  /// When set, the outgoing byte transfer is a voice recording; used to
  /// finalize its bubble as an audio message.
  String? _pendingOutgoingAudioText;

  /// Reconnects to the device this chat session belongs to. Used by the
  /// Connect button shown when the chat is opened without a connection.
  Future<void> connectToCurrentSession() async {
    if (transport.isConnected.value || isConnecting.value) return;
    final address = chatSession.device['address'] as String?;
    isConnecting.value = true;
    // The transport decides how to reach the stored peer: Bluetooth dials
    // the stored address; Wi‑Fi Direct discovers the device first (P2P
    // addresses rotate) and connects on a match — hence the name, used as
    // the fallback match when the stored address went stale.
    transport.lastConnectError.value = null;
    final bool ok = await transport.connectToSessionPeer(
      address: address,
      name: chatSession.name,
    );
    isConnecting.value = false;
    // Not connected yet, but the link is alive (socket up and/or the peer
    // is still deciding): that is not a failure — tell the user we are
    // waiting for the peer's acceptance instead. Only a genuinely dead
    // attempt (no socket, nothing pending) reports failure. Previously the
    // waiting message required `ok == false`, so a fast socket-up produced
    // no feedback at all on the initiating side.
    final bool connected = transport.isConnected.value;
    if (!connected && !ok && !transport.isAwaitingAcceptance) {
      Get.snackbar(
        'couldNotConnectTitle'.tr,
        transport.lastConnectError.value ?? 'couldNotConnectMessage'.tr,
      );
    } else if (!connected) {
      Get.snackbar(
        'waitingAcceptanceTitle'.tr,
        'waitingAcceptanceMessage'.tr,
      );
    }
  }

  /// True while either an outgoing or incoming byte transfer is in flight.
  bool get hasActiveTransfer {
    bool active(TransferState? s) => s != null && s.total > 0 && s.current < s.total;
    return active(transport.outgoingTransfer.value) ||
        active(transport.incomingTransfer.value);
  }

  // Progress bubbles are tracked by message id (bubble UUID) instead of list
  // index, so concurrent in/out transfers can never corrupt each other.
  String? _outgoingProgressId;
  String? _incomingProgressId;

  // Holds bytes for the currently sending image to convert the progress
  // bubble into a final image message.
  Uint8List? _pendingOutgoingBytes;
  String? sendingImagePath;

  StreamSubscription<String?>? _disconnectSubscription;
  StreamSubscription<bool>? _connectionSubscription;

  // Debounces Hive writes during message bursts (text/image/traffic storms).
  Timer? _saveDebounce;

  // History sync between previously-chatting peers:
  // - The prefix makes sync packets distinguishable from plain chat text.
  static const String _syncPrefix = '@@CHATBLUE_SYNC@@';

  // Voice-message announcement prefix (duration meta sent before the bytes).
  static const String _audioPrefix = '@@CHATBLUE_AUDIO@@';

  /// Voice recordings are cut off (and sent) automatically at this length.
  static const int _maxRecordSeconds = 120;

  // A sync packet is sent once per (re)connection; the connection listener
  // in onInit re-triggers it whenever the socket comes up.
  static const int _syncHistoryCount = 10;

  // One history sync per chat screen lifetime: re-connects within the same
  // session re-send nothing unless a new chat screen is opened.
  bool _syncSentForSession = false;

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

  /// Applies a peer-reported device name (WFD sockets carry no name on the
  /// wire) to the app bar and the persisted session.
  void updateSessionName(String name) {
    if (name.isEmpty || peerName.value == name) return;
    peerName.value = name;
    if (chatSession.name != name) {
      chatSession = ChatSessionModel(
        id: chatSession.id,
        name: name,
        createdAt: chatSession.createdAt,
        updatedAt: chatSession.updatedAt,
        messages: chatSession.messages,
        device: chatSession.device,
        transport: chatSession.transport,
      );
      _scheduleSave();
    }
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
  /// home list stay in ONE chat (a split makes the sync look like it did
  /// nothing while the old history sits in a second chat).
  Future<void> _mergeLatePeerSession() async {
    if (!_openedAsFreshSession || _lateMergeDone) return;
    final duplicate = await _findExistingSessionForPeer();
    if (duplicate == null || duplicate.id == chatSession.id) return;
    _lateMergeDone = true;
    final seen = <String>{};
    final combined = <MessageModel>[];
    for (final m in [...duplicate.messages, ...messages]) {
      final k = m.id ??
          '${m.timestamp.microsecondsSinceEpoch}|${m.isSentByMe}|'
              '${m.text}|${m.imagePath}';
      if (seen.add(k)) combined.add(m);
    }
    combined.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    chatSession = ChatSessionModel(
      id: chatSession.id,
      name: chatSession.name,
      createdAt: duplicate.createdAt.isBefore(chatSession.createdAt)
          ? duplicate.createdAt
          : chatSession.createdAt,
      updatedAt: DateTime.now(),
      messages: combined,
      device: {
        'name': chatSession.device['name'] ?? duplicate.device['name'],
        'address':
            chatSession.device['address'] ?? duplicate.device['address'],
      },
      transport: chatSession.transport,
    );
    messages.value = combined;
    try {
      await HiveService.to.saveChatSession(chatSession);
      await HiveService.to.deleteChatSession(duplicate.id);
      if (kDebugMode) {
        debugPrint(
          'Late identity merge: adopted "${duplicate.name}" '
          '(${duplicate.id}) into ${chatSession.id} — '
          '${combined.length} messages',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Late identity merge failed: $e');
      }
    }
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
      final all = await HiveService.to.getAllChatSessions();
      final peerMac = transport.connectedDeviceKey;
      final peerName = transport.connectedDeviceName;
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

  @override
  void onInit() async {
    if (Get.arguments is ChatSessionModel) {
      chatSession = Get.arguments as ChatSessionModel;
      messages.value = chatSession.messages;
    } else {
      // Session keying: prefer the peer's STABLE per-install id (WFD
      // identity frame) so the same device always merges into one session
      // despite randomized P2P MAC rotation; fall back to the device
      // address (BT / WFD before the frame), but never to the placeholder
      // 'unknown' or the dummy P2P MAC (02:00:00:00:00:00) — uuid in that
      // case. The MAC stays in device['address'] for display/reconnects.
      final peerId = transport.connectedDeviceId;
      final mac = transport.connectedDeviceKey;
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
      if (kDebugMode) {
        debugPrint(
          'Chat open: key=$key (peerId=$peerId, mac=$mac) — merge will '
          'match by key, then MAC, then name',
        );
      }
      // Assign the session BEFORE the first await: the first frame builds
      // while onInit is still suspended on the Hive lookup, and widgets
      // (ChatAppBar reads `chatSession.name`) would hit the uninitialized
      // `late` field with a LateInitializationError — seen when a chat
      // opens through the scan/connect flow (no Get.arguments). The lookup
      // below hydrates the existing session (and its messages) in place.
      chatSession =
          ChatSessionModel(
            id: key,
            name: transport.connectedDeviceName ?? key,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            messages: messages.toList(),
            device: {
              'name': transport.connectedDeviceName,
              'address': macUsable ? mac : null,
            },
            // Tag the new session with the channel it was created on the
            // home list shows (and reopens) chats by this value.
            transport: transport.transportType,
          );
      messages.value = chatSession.messages;
      var session = await HiveService.to.loadChatSession(key);
      session ??= await _findExistingSessionForPeer();
      if (kDebugMode) {
        debugPrint(
          'Session load: key=$key -> ${session?.id ?? 'MISS'}'
          '${session == null ? '' : (session.id == key ? ' (direct hit)' : ' (merged)')}',
        );
      }
      if (session != null && session.id == key) {
        // DIRECT key hit: load the existing session's messages. (The
        // sync-created shell above is replaced; this branch was missing —
        // every connect to an existing session opened an empty shell.)
        chatSession = session;
        messages.value = session.messages;
      } else if (session != null && session.id != key) {
        // Re-key + adopt: move the matched session under the computed key so
        // future opens hit it directly (no repeated merge search), and use
        // the re-keyed instance — `chatSession.id` is final, so the session
        // is re-created with the new id; the nested message objects are
        // reused as-is.
        chatSession = ChatSessionModel(
          id: key,
          name: session.name,
          createdAt: session.createdAt,
          updatedAt: session.updatedAt,
          messages: session.messages,
          device: session.device,
          transport: session.transport,
        );
        messages.value = chatSession.messages;
        try {
          await HiveService.to.saveChatSession(chatSession);
          await HiveService.to.deleteChatSession(session.id);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Session re-key failed: $e');
          }
        }
        _scheduleSave();
      } else if (session == null) {
        // BRAND-NEW session: persist it right away. Saves are otherwise
        // triggered only by dirty events (message, rename, sync) — a chat
        // opened and closed without any of those would never touch Hive and
        // silently vanish on restart. The identity frame may still be in
        // flight (or the MAC rotated): flag the open so a late identity
        // frame re-checks for a stored session of the same peer and merges
        // it in instead of leaving two chats for one device.
        _openedAsFreshSession = true;
        _scheduleSave();
      }
    }

    // Sessions persisted before the transport field existed carry no tag:
    // stamp the transport in use now — the home list both labels and
    // reopens chats by this value, so it always matches the screen the
    // chat was reached on.
    if (chatSession.transport == null) {
      chatSession.transport = transport.transportType;
      _scheduleSave();
    }

    setupCallbacks();
    // Backfill ids for messages persisted by the old Hive schema (which
    // never wrote `id`): deletion and progress bookkeeping key on ids, so
    // legacy history needs one before it can be deleted.
    var backfilled = false;
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].id == null) {
        messages[i] = messages[i].copyWith(id: Uuid().v4());
        backfilled = true;
      }
    }
    if (backfilled) {
      _scheduleSave();
    }
    // Opening the chat counts as "chat open" for the transport: a connection
    // arriving while this screen is visible must not push a second chat.
    transport.onChatOpened();
    _disconnectSubscription = transport.lastDisconnectReason.listen((reason) {
      if (reason != null && reason.isNotEmpty) {
        Get.snackbar('disconnectedTitle'.tr, 'peerClosedConnectionMessage'.tr);
      }
    });

    // When this is not the first session with this peer, share the last
    // messages on (re)connection so both devices converge on the same
    // history. Chat screens opened through the scan flow already have a
    // socket, so the initial microtask send works; sessions opened without
    // a connection (home -> chat -> Connect button) get the sync as soon as
    // the socket comes up.
    Future.microtask(_sendHistorySync);
    _connectionSubscription = transport.isConnected.listen((connected) {
      if (connected) _sendHistorySync();
    });
    super.onInit();
  }

  @override
  void onClose() {
    _saveDebounce?.cancel();
    unawaited(_flushPendingSave());
    // Discard queued sends: there is no socket after the chat closes.
    _sendQueue.clear();
    // No peer answers deferred-download requests once the chat closes.
    for (final t in _fetchWatchdogs.values) {
      t.cancel();
    }
    _fetchWatchdogs.clear();
    // Stop any active recording and release the player.
    _recordTimer?.cancel();
    _recorder?.dispose();
    _audioPlayer.dispose();
    textController.dispose();
    // Disconnect when leaving the chat screen to release the socket cleanly.
    // PopScope on the screen confirms there is no active transfer first.
    transport.disconnectFromDevice();
    _disconnectSubscription?.cancel();
    _connectionSubscription?.cancel();
    transport.onChatClosed();
    // The session list may have new/renamed sessions after a chat: refresh
    // it AFTER the pending save has actually landed (the flush is debounced
    // 250 ms and may still be in flight when the screen closes).
    unawaited(_flushPendingSave().whenComplete(() {
      if (Get.isRegistered<HomeController>()) {
        Get.find<HomeController>().refreshSessions();
      }
    }));
    super.onClose();
  }

  void setupCallbacks() {
    // Playback position of the active voice bubble.
    _audioPlayer.positionStream.listen((position) {
      final duration = _audioPlayer.duration;
      if (duration != null && duration.inMilliseconds > 0) {
        audioProgress.value =
            (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      }
    });
    _audioPlayer.playerStateStream.listen((state) {
      isAudioPlaying.value = state.playing;
      if (state.processingState == ProcessingState.completed) {
        playingAudioId.value = null;
        audioProgress.value = 0;
      }
    });

    transport.onSocketData((bytes, text, {required String kind}) async {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket data: $text\n Kind: $kind');
      }
      if (kind == 'bytes' && bytes.isNotEmpty) {
        // A voice announcement precedes the audio bytes; route accordingly.
        if (_pendingAudioMeta != null) {
          await _handleIncomingAudio(bytes);
        } else {
          await _handleIncomingImage(bytes);
        }
      } else if (text.startsWith(_audioPrefix)) {
        // Voice transfer announcement: remember the duration for the coming
        // bytes; nothing is added to the chat at this point.
        _pendingAudioMeta = text.substring(_audioPrefix.length);
      } else if (text.startsWith(_syncPrefix)) {
        // History sync packet from the peer: not a real message, apply it to
        // the local history instead of appending it to the chat.
        await _applyHistorySync(text.substring(_syncPrefix.length));
      } else {
        messages.insert(
          0,
          MessageModel(
            id: Uuid().v4(),
            text: text,
            isSentByMe: false,
            timestamp: DateTime.now(),
          ),
        );
        _scheduleSave();
      }
      update();
    });

    transport.onTransferProgress(({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) {
      // History sync packets travel as one large text frame: reflect their
      // reception as a thin progress bar under the app bar. Plain messages
      // are far below the threshold.
      if (direction == 'in' &&
          kind == 'text' &&
          total >= _syncProgressThreshold) {
        syncProgress.value =
            total == 0 ? 0 : (current / total).clamp(0, 1).toDouble();
        isSyncing.value = current < total;
      }
      final state = TransferState(
        direction: direction,
        current: current,
        total: total,
        kind: kind,
      );
      if (direction == 'out') {
        transport.outgoingTransfer.value = state;
        if (kind == 'bytes') {
          _updateOutgoingProgress(state);
        }
      } else {
        transport.incomingTransfer.value = state;
        // For incoming, only render intermediate progress; finalization
        // happens when the actual data bytes arrive in onSocketData.
        if (kind == 'bytes' && !(state.total > 0 && state.current >= state.total)) {
          _updateIncomingProgress(state);
        }
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint('Transfer progress: $direction $current $total $kind');
      }
    });
  }

  /// Sends the sync **manifest** — a light SHA-256 digest of the last
  /// [_syncHistoryCount] messages (what the peer may need) — as a single
  /// small packet. The peer compares it against its own set and only
  /// requests what it is actually missing; no message payload (and no image
  /// bytes) is transferred unless needed. Called once per chat screen on
  /// (re)connection.
  Future<void> _sendHistorySync() async {
    // One sync per chat screen: if a previous connection already synced this
    // session, a re-connect adds nothing new unless the screen was reopened.
    if (_syncSentForSession) return;
    // No socket yet (chat opened from the session list): nothing to send;
    // the connection listener re-invokes this as soon as the link is up.
    if (!transport.isConnected.value) return;

    final history = messages.toList()
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
    transport.sendMessage(
      _syncPrefix +
          jsonEncode({
            'type': 'manifest',
            'items': [
              for (final e in counts.entries) {'h': e.key, 'n': e.value},
            ],
          }),
    );
  }

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

  /// Asks the peer for the media file behind a placeholder bubble.
  Future<void> downloadMedia(MessageModel message) async {
    final id = message.id;
    if (id == null || !message.hasRemoteMedia) return;
    if (!transport.isConnected.value) {
      Get.snackbar('downloadFailedTitle'.tr, 'downloadNeedConnection'.tr);
      return;
    }
    _setMediaFetchBusy(id, true);
    _fetchWatchdogs[id]?.cancel();
    _fetchWatchdogs[id] = Timer(const Duration(seconds: 90), () {
      _fetchWatchdogs.remove(id);
      _setMediaFetchBusy(id, false);
      Get.snackbar('downloadFailedTitle'.tr, 'downloadTimeoutMessage'.tr);
    });
    transport.sendMessage(
      _syncPrefix + jsonEncode({'type': 'fetch', 'id': id}),
    );
  }

  /// Flips the placeholder bubble's busy flag (spinner) for [id].
  void _setMediaFetchBusy(String id, bool busy) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final cur = messages[idx];
    if (!cur.hasRemoteMedia || cur.isTransferring == busy) return;
    messages[idx] = cur.copyWith(isTransferring: busy);
    update();
  }

  /// Stops the watchdog of [id] (the file arrived or the peer said no).
  void _settleFetch(String id) {
    _fetchWatchdogs.remove(id)?.cancel();
  }

  /// Dispatches an incoming sync packet by its `type`:
  /// - `manifest`  → compare against local messages, request what's missing
  /// - `request`   → send the requested messages (as `message` packets)
  /// - `message`   → integrate the peer's messages into local history
  /// - `fetch`     → send one message's media file (deferred download)
  /// - `download`  → the file we asked for (fills a placeholder bubble)
  /// - `fetchMiss` → the peer no longer holds the requested file
  Future<void> _applyHistorySync(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final type = decoded['type'] as String? ?? 'message';
      switch (type) {
        case 'message':
          await _applySyncMessages(decoded['messages']);
        case 'manifest':
          await _handleSyncManifest(decoded['items']);
        case 'request':
          await _handleSyncRequest(decoded['items']);
        case 'fetch':
          await _handleSyncFetch(decoded['id']);
        case 'download':
          await _applySyncMessages(decoded['messages']);
        case 'fetchMiss':
          _handleFetchMiss(decoded['id']);
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
    final myCounts = await _localHashCounts(messages);

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

    transport.sendMessage(
      _syncPrefix + jsonEncode({'type': 'request', 'items': missing}),
    );
  }

  /// Sends the requested messages back to the peer: for each requested hash,
  /// the newest [n] local messages matching it, each in its own packet (so a
  /// dropped frame only costs one message).
  Future<void> _handleSyncRequest(dynamic itemsRaw) async {
    if (itemsRaw is! List || itemsRaw.isEmpty) return;
    final sorted = messages.toList()
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
        transport.sendMessage(
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
    for (final m in messages) {
      if (m.id != id) continue;
      final path = m.imagePath;
      if (path != null) {
        try {
          final file = File(path);
          if (await file.exists() && file.lengthSync() <= _syncMaxFetchBytes) {
            transport.sendMessage(
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
    transport.sendMessage(
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
    Get.snackbar('downloadFailedTitle'.tr, 'downloadUnavailableMessage'.tr);
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
    if (imagePath == null) {
      // This side holds the message as a placeholder: pass the marker along
      // so any further sync keeps knowing where the file lives.
      final pendingSize = m.remoteMediaSize;
      if (pendingSize != null && pendingSize > 0) {
        entry['type'] = m.transferKind == 'audio' ? 'audio' : 'image';
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
          entry['type'] = isAudio ? 'audio' : 'image';
          entry['bytes'] = base64Encode(await file.readAsBytes());
        } else if (size <= _syncMaxFetchBytes) {
          // Too large to auto-transfer: advertise it for download-on-tap.
          entry['type'] = isAudio ? 'audio' : 'image';
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
    if (raw is! List) return;
    isSyncing.value = true;
    try {
      final entries = raw;

      bool changed = false;
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
          final int idx = messages.indexWhere((m) => m.id == entryId);
          if (idx != -1 && messages[idx].hasRemoteMedia) {
            String? downloaded;
            try {
              downloaded = await _persistIncomingBytes(
                mediaBytes,
                isAudioEntry ? 'm4a' : 'jpg',
              );
            } catch (_) {
              downloaded = null;
            }
            if (downloaded != null) {
              final cur = messages[idx];
              messages[idx] = MessageModel(
                id: cur.id,
                text: cur.text,
                isSentByMe: cur.isSentByMe,
                timestamp: cur.timestamp,
                imagePath: downloaded,
                transferKind: isAudioEntry ? 'audio' : cur.transferKind,
              );
              _settleFetch(entryId);
              changed = true;
              continue;
            }
          }
        }

        bool alreadyHave = messages.any(
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
            mediaPath = await _persistIncomingBytes(
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
        messages.add(
          MessageModel(
            // Keep the peer's id so future syncs can deduplicate on it.
            id: entryId,
            text: text,
            isSentByMe: sentByMe,
            timestamp: ts,
            imagePath: mediaPath,
            transferKind: isAudioEntry ? 'audio' : null,
            remoteMediaSize:
                mediaPath == null && remoteSize != null && remoteSize > 0
                    ? remoteSize
                    : null,
          ),
        );
        changed = true;
      }

      if (changed) {
        messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        _scheduleSave();
        update();
      }
    } catch (_) {
      // Malformed sync packet — ignore silently.
    } finally {
      // Frame may have finished before applying (images written to disk);
      // hide the banner only once everything is processed.
      isSyncing.value = false;
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
    int idx = _incomingProgressId == null
        ? -1
        : messages.indexWhere((m) => m.id == _incomingProgressId);
    if (idx == -1) {
      // Bubble may have been cleared or restored without an id: fall back to
      // any incoming progress bubble still in the list.
      idx = messages.indexWhere(
        (m) => m.isTransferring && m.transferKind == 'bytes' && !m.isSentByMe,
      );
    }
    _incomingProgressId = null;

    final filePath = await _persistIncomingBytes(bytes, 'jpg');

    if (idx != -1 && idx < messages.length) {
      messages[idx] = messages[idx].copyWith(
        text: 'imageCaption'.trParams({'size': '${bytes.lengthInBytes}'}),
        isSentByMe: false,
        timestamp: DateTime.now(),
        imagePath: filePath,
        isTransferring: false,
      );
    } else {
      messages.insert(
        0,
        MessageModel(
          id: Uuid().v4(),
          text: 'imageCaption'.trParams({'size': '${bytes.lengthInBytes}'}),
          isSentByMe: false,
          timestamp: DateTime.now(),
          imagePath: filePath,
        ),
      );
    }
    _scheduleSave();
  }

  void _updateOutgoingProgress(TransferState state) {
    int idx = _outgoingProgressId == null
        ? -1
        : messages.indexWhere((m) => m.id == _outgoingProgressId);
    if (idx == -1) {
      _outgoingProgressId = null;
      final bubble = _newProgressBubble(isSentByMe: true, state: state);
      _outgoingProgressId = bubble.id;
      messages.insert(0, bubble);
      idx = 0;
    } else {
      messages[idx] = messages[idx].copyWith(
        text: _progressPercent(state),
        transferCurrent: state.current,
        transferTotal: state.total,
        isTransferring: state.current < state.total,
      );
    }

    // Finalize outgoing: convert the progress bubble into the real image message
    if (state.total > 0 && state.current >= state.total) {
      final bytesToAttach = _pendingOutgoingBytes;
      final audioText = _pendingOutgoingAudioText;
      messages[idx] = messages[idx].copyWith(
        text: audioText ??
            (bytesToAttach != null
                ? '[Image] (${bytesToAttach.lengthInBytes} bytes)'
                : messages[idx].text),
        imagePath: sendingImagePath ?? messages[idx].imagePath,
        isTransferring: false,
        transferCurrent: state.total,
        transferTotal: state.total,
        transferKind: audioText != null ? 'audio' : 'bytes',
      );
      _scheduleSave();
      sendingImagePath = null;
      _pendingOutgoingBytes = null;
      _pendingOutgoingAudioText = null;
      _outgoingProgressId = null;
    }
    update();
  }

  void _updateIncomingProgress(TransferState state) {
    int idx = _incomingProgressId == null
        ? -1
        : messages.indexWhere((m) => m.id == _incomingProgressId);
    if (idx == -1) {
      _incomingProgressId = null;
      final bubble = _newProgressBubble(isSentByMe: false, state: state);
      _incomingProgressId = bubble.id;
      messages.insert(0, bubble);
      idx = 0;
    } else {
      messages[idx] = messages[idx].copyWith(
        text: _progressPercent(state),
        transferCurrent: state.current,
        transferTotal: state.total,
        isTransferring: state.current < state.total,
      );
    }
    update();
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
    if (isConnected.value) {
      final text = textController.text;
      // Show the bubble immediately (user feedback); the actual write is
      // serialized behind any in-flight transfer.
      messages.insert(
        0,
        MessageModel(
          id: Uuid().v4(),
          text: text,
          isSentByMe: true,
          timestamp: DateTime.now(),
        ),
      );
      _scheduleSave();
      textController.clear();
      _enqueueSend(_OutgoingJob.text(text));
      update();
    }
  }

  Future<void> saveChatSession() async {
    chatSession.messages = messages.toList();
    chatSession.updatedAt = DateTime.now();
    await HiveService.to.saveChatSession(chatSession);
  }

  /// Debounced persistence: bursts of events (message storms, transfer
  /// progress) result in a single Hive write. [onClose] flushes the pending
  /// write so no change is lost.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 250), () async {
      _saveDebounce = null;
      try {
        await saveChatSession();
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
    if (_saveDebounce == null) return;
    _saveDebounce!.cancel();
    _saveDebounce = null;
    try {
      await saveChatSession();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Chat session flush failed: $e');
      }
    }
  }

  /// Remove a message at the given index from the shared message list
  void deleteMessageAt(int index) {
    if (index >= 0 && index < messages.length) {
      messages.removeAt(index);
    }
  }

  /// Removes one of the user's own messages by id (UI + persisted Hive
  /// session). Local only: the peer's copy is untouched, so a later history
  /// sync may re-deliver the message.
  void deleteMessage(String? id) {
    if (id == null) return;
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    messages.removeAt(idx);
    _scheduleSave();
    update();
  }

  Future<void> pickAndSendImage() => _pickAndSend(ImageSource.gallery);

  Future<void> showImageSourceSheet() async {
    if (!isConnected.value) return;
    Get.bottomSheet(
      SafeArea(
        child: Material(
          // Material instead of Container(decoration): a DecoratedBox between
          // the sheet and the ListTiles would hide their ink splashes.
          color: Get.theme.cardColor,
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
                title: Text('gallerySource'.tr),
                onTap: () async {
                  Get.back();
                  await _pickAndSend(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: Text('cameraSource'.tr),
                onTap: () async {
                  Get.back();
                  await _pickAndSend(ImageSource.camera);
                },
              ),
            ],
          ),
        ),
      ),
      isScrollControlled: false,
      ignoreSafeArea: false,
      backgroundColor: Colors.transparent,
    );
  }

  Future<void> _pickAndSend(ImageSource source) async {
    if (!isConnected.value) return;
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: source);
    if (file == null) return;

    Uint8List bytes = await file.readAsBytes();
    sendingImagePath = file.path;
    // Single compression pass: pickImage is used without imageQuality so the
    // JPEG is not decoded twice (previous code compressed twice).
    try {
      final compressed = await FlutterImageCompress.compressWithList(bytes, quality: 70);
      if (compressed.isNotEmpty) {
        bytes = Uint8List.fromList(compressed);
      }
    } catch (_) {}

    // Queue the transfer instead of sending immediately: it starts only
    // after any currently in-flight send completes, so wire order and
    // progress state of concurrent image transfers never interleave.
    _enqueueSend(_OutgoingJob.bytes(bytes, file.path));
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
        // Wire these before sendBytes so progress callbacks can finalize the
        // bubble; cleared on completion/failure in _updateOutgoingProgress.
        _pendingOutgoingBytes = job.bytes;
        sendingImagePath = job.imagePath;
        _pendingOutgoingAudioText = job.audioText;
        await transport.sendBytes(job.bytes!);
      } else {
        await transport.sendMessage(job.text!);
      }
    } catch (_) {
      if (job.kind == _SendKind.bytes) {
        final int? idx = _outgoingProgressId == null
            ? (messages.isNotEmpty ? 0 : null)
            : messages.indexWhere((m) => m.id == _outgoingProgressId);
        if (idx != null && idx >= 0 && idx < messages.length) {
          messages[idx] = messages[idx].copyWith(
            text: 'imageSendFailed'.tr,
            isTransferring: false,
          );
        }
        _pendingOutgoingBytes = null;
        _outgoingProgressId = null;
        sendingImagePath = null;
        update();
      }
    }
    // Even when the future completes without any progress events, the next
    // queued job may proceed (progress-driven finalization also calls
    // _drainSendQueue; _sendJobActive guard makes the double call a no-op).
    _drainSendQueue();
  }

  Future<String> _persistIncomingBytes(Uint8List bytes, String ext) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.$ext';
    // Write on a background isolate so large payloads don't jank the UI
    await compute(_writeBytesToFile, (path: path, bytes: bytes));
    return path;
  }

  // ── Voice recording & playback ───────────────────────────────────────────

  /// Starts a voice recording (hold-to-record). Requires the microphone
  /// runtime permission; the file is AAc-LC (.m4a) in app documents.
  Future<void> startRecording() async {
    if (isRecording.value || !transport.isConnected.value) return;
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      Get.snackbar('micPermissionTitle'.tr, 'recordingUnavailableMessage'.tr);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
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
      Get.snackbar('recordingErrorTitle'.tr, 'recordingStartFailedMessage'.tr);
      return;
    }
    recordSeconds.value = 0;
    isRecording.value = true;
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        recordSeconds.value++;
        // Automatic cut-off: stop and send at the configured limit.
        if (recordSeconds.value >= _maxRecordSeconds) {
          stopRecordingAndSend();
        }
      },
    );
  }

  /// Stops the recording and queues it for sending (≥ 1 s; shorter takes are
  /// discarded to avoid accidental taps).
  Future<void> stopRecordingAndSend() async {
    if (!isRecording.value) return;
    final path = _recordingPath;
    final seconds = recordSeconds.value;
    await cancelRecording(deleteFile: false);
    if (path == null) return;
    final file = File(path);
    if (!await file.exists() || file.lengthSync() == 0) return;
    if (seconds < 1) {
      await file.delete().catchError((_) => file);
      return;
    }
    _enqueueSend(
      _OutgoingJob.text(_audioPrefix + jsonEncode({'duration': _formatDuration(seconds)})),
    );
    _enqueueSend(
      _OutgoingJob.bytes(await file.readAsBytes(), path, audioText: _formatDuration(seconds)),
    );
  }

  /// Aborts the current recording (used when the press is cancelled).
  Future<void> cancelRecording({bool deleteFile = true}) async {
    _recordTimer?.cancel();
    _recordTimer = null;
    isRecording.value = false;
    recordSeconds.value = 0;
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
    if (playingAudioId.value == msg.id) {
      if (_audioPlayer.playing) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play();
      }
      return;
    }
    await _audioPlayer.stop();
    playingAudioId.value = msg.id;
    audioProgress.value = 0;
    try {
      await _audioPlayer.setFilePath(path);
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Audio load failed: $e');
      }
      playingAudioId.value = null;
      return;
    }
    await _audioPlayer.play();
  }

  /// Seeks the given bubble to [millis]. Loads the track first when another
  /// message is currently bound to the player.
  Future<void> seekAudio(MessageModel msg, double millis) async {
    if (playingAudioId.value != msg.id) {
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

    int idx = _incomingProgressId == null
        ? -1
        : messages.indexWhere((m) => m.id == _incomingProgressId);
    if (idx == -1) {
      idx = messages.indexWhere(
        (m) => m.isTransferring && m.transferKind == 'bytes' && !m.isSentByMe,
      );
    }
    _incomingProgressId = null;

    final filePath = await _persistIncomingBytes(bytes, 'm4a');

    if (idx != -1 && idx < messages.length) {
      messages[idx] = messages[idx].copyWith(
        text: durationText ?? messages[idx].text,
        isSentByMe: false,
        timestamp: DateTime.now(),
        imagePath: filePath,
        isTransferring: false,
        transferKind: 'audio',
      );
    } else {
      messages.insert(
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
    _scheduleSave();
    update();
  }
}