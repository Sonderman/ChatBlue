import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
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
        imagePath = null;

  _OutgoingJob.bytes(Uint8List this.bytes, this.imagePath)
      : kind = _SendKind.bytes,
        text = null;

  final _SendKind kind;
  final String? text;
  final Uint8List? bytes;
  final String? imagePath;
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

  /// True while a manual reconnect (Connect button) attempt is in flight.
  final RxBool isConnecting = false.obs;

  /// Visible while a history sync packet is being received/applied.
  final RxBool isSyncing = false.obs;

  /// 0..1 progress of the incoming sync frame (drives the thin header bar).
  final RxDouble syncProgress = 0.0.obs;

  /// Reconnects to the device this chat session belongs to. Used by the
  /// Connect button shown when the chat is opened without a connection.
  Future<void> connectToCurrentSession() async {
    if (transport.isConnected.value || isConnecting.value) return;
    final address = chatSession.device['address'] as String?;
    if (address == null || address.isEmpty) {
      Get.snackbar('Cannot connect', 'No device address stored for this chat.');
      return;
    }
    isConnecting.value = true;
    final bool ok = await transport.connectToPeer(address);
    isConnecting.value = false;
    if (!ok && !transport.isConnected.value) {
      Get.snackbar(
        'Could not connect!',
        'Make sure the other device is discoverable and in range.',
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

  // A sync packet is sent once per (re)connection; the connection listener
  // in onInit re-triggers it whenever the socket comes up.
  static const int _syncHistoryCount = 10;

  // One history sync per chat screen lifetime: re-connects within the same
  // session re-send nothing unless a new chat screen is opened.
  bool _syncSentForSession = false;

  // Serializes outgoing sends: while a byte transfer (image) is in flight,
  // any further text/image send is queued and only dispatched once the
  // current transfer completes. This keeps the wire order FIFO and prevents
  // two transfers from clobbering each other's progress state.
  final List<_OutgoingJob> _sendQueue = <_OutgoingJob>[];
  bool _sendJobActive = false;

  @override
  void onInit() async {
    if (Get.arguments is ChatSessionModel) {
      chatSession = Get.arguments as ChatSessionModel;
      messages.value = chatSession.messages;
    } else {
      final key = transport.connectedDeviceKey ?? Uuid().v4();
      final foundSession = await HiveService.to.loadChatSession(key);
      chatSession =
          foundSession ??
          ChatSessionModel(
            id: key,
            name: transport.connectedDeviceName ?? key,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            messages: messages.toList(),
            device: {
              'name': transport.connectedDeviceName,
              'address': transport.connectedDeviceKey,
            },
          );
      messages.value = chatSession.messages;
    }

    setupCallbacks();
    // Opening the chat counts as "chat open" for the transport: a connection
    // arriving while this screen is visible must not push a second chat.
    transport.onChatOpened();
    _disconnectSubscription = transport.lastDisconnectReason.listen((reason) {
      if (reason != null && reason.isNotEmpty) {
        Get.snackbar('Disconnected', 'Other device closed the connection');
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
    textController.dispose();
    // Disconnect when leaving the chat screen to release the socket cleanly.
    // PopScope on the screen confirms there is no active transfer first.
    transport.disconnectFromDevice();
    _disconnectSubscription?.cancel();
    _connectionSubscription?.cancel();
    transport.onChatClosed();
    super.onClose();
  }

  void setupCallbacks() {
    transport.onSocketData((bytes, text, {required String kind}) async {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket data: $text\n Kind: $kind');
      }
      if (kind == 'bytes' && bytes.isNotEmpty) {
        await _handleIncomingImage(bytes);
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

  /// Sends the last [_syncHistoryCount] messages of this session to the peer
  /// as sync packets. Called on (re)connection.
  ///
  /// Images travel as base64. Each image is sent in its **own** packet — a
  /// dropped frame only costs that one image, never the whole history — and
  /// text messages go first as one small packet. All packets are enqueued on
  /// the same send queue so they never interleave with live user messages.
  Future<void> _sendHistorySync() async {
    // One sync per chat screen: if a previous connection already synced this
    // session, a re-connect adds nothing new unless the screen was reopened.
    if (_syncSentForSession) return;
    // No socket yet (chat opened from the session list): nothing to send;
    // the connection listener re-invokes this as soon as the link is up.
    if (!transport.isConnected.value) return;
    // Marked before enqueue: sending is serialized on the queue, but the
    // state must not allow another trigger while packets are pending.
    _syncSentForSession = true;

    final history = messages.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final recent = history.take(_syncHistoryCount);

    final textEntries = <Map<String, dynamic>>[];
    final imagePackets = <Map<String, dynamic>>[];

    for (final m in recent) {
      final entry = <String, dynamic>{
        if (m.id != null) 'id': m.id,
        'text': m.text,
        'sentByMe': m.isSentByMe,
        'timestamp': m.timestamp.toIso8601String(),
      };
      final imagePath = m.imagePath;
      if (imagePath != null) {
        try {
          final file = File(imagePath);
          if (await file.exists() && file.lengthSync() <= _syncMaxImageBytes) {
            final bytes = await file.readAsBytes();
            entry['type'] = 'image';
            entry['bytes'] = base64Encode(bytes);
            imagePackets.add(entry);
            continue;
          }
        } catch (_) {
          // Unreadable image: keep its text caption instead.
        }
      }
      textEntries.add(entry);
    }

    if (textEntries.isNotEmpty) {
      // History sync rides OUTSIDE the user send queue: live messages are
      // never blocked behind sync packets (the single socket still orders
      // frames FIFO natively, but user sends submit independently and the
      // sync is split into small per-image packets, so worst-case wait is
      // one frame, not the whole history).
      transport.sendMessage(_syncPrefix + jsonEncode({'messages': textEntries}));
    }
    for (final imageEntry in imagePackets) {
      transport.sendMessage(
        _syncPrefix + jsonEncode({'messages': [imageEntry]}),
      );
    }
  }

  /// Image payloads larger than this are not embedded in the history sync
  /// (they fall back to their text caption; a fresh transfer can always be
  /// requested manually). Frames are length-prefixed on both transports and
  /// written in 8 KB chunks, so multi-MB payloads are fine.
  static const int _syncMaxImageBytes = 3 * 1024 * 1024;

  /// Incoming text frames at or above this size are treated as history sync
  /// packets for the thin progress bar under the app bar (plain messages are
  /// far smaller).
  static const int _syncProgressThreshold = 4 * 1024;

  /// Applies an incoming history sync packet: integrates the peer's last
  /// messages into the local history, deduplicating against messages that
  /// already exist locally (same text, same direction and almost-same
  /// timestamp — the peer's copy of a message we already hold).
  Future<void> _applyHistorySync(String payload) async {
    isSyncing.value = true;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map || decoded['messages'] is! List) return;
      final entries = decoded['messages'] as List;

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

        // Rehydrate embedded image bytes (decoded early so the content hash
        // can be used for a robust dedup and the file written only once).
        Uint8List? imageBytes;
        if (entry['type'] == 'image') {
          final b64 = entry['bytes'] as String?;
          if (b64 != null && b64.isNotEmpty) {
            try {
              imageBytes = base64Decode(b64);
            } catch (_) {
              imageBytes = null;
            }
          }
        }
        final int? incomingHash =
            imageBytes == null ? null : _quickHash(imageBytes);

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

        // Persist the embedded image to a local file (once, after dedup).
        String? imagePath;
        if (imageBytes != null) {
          try {
            imagePath = await _persistIncomingImage(imageBytes);
          } catch (_) {
            imagePath = null;
          }
        }

        messages.add(
          MessageModel(
            // Keep the peer's id so future syncs can deduplicate on it.
            id: entry['id'] as String?,
            text: text,
            isSentByMe: sentByMe,
            timestamp: ts,
            imagePath: imagePath,
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

    final filePath = await _persistIncomingImage(bytes);

    if (idx != -1 && idx < messages.length) {
      messages[idx] = messages[idx].copyWith(
        text: '[Image] (${bytes.lengthInBytes} bytes)',
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
          text: '[Image] (${bytes.lengthInBytes} bytes)',
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
      messages[idx] = messages[idx].copyWith(
        text: bytesToAttach != null
            ? '[Image] (${bytesToAttach.lengthInBytes} bytes)'
            : messages[idx].text,
        imagePath: sendingImagePath ?? messages[idx].imagePath,
        isTransferring: false,
        transferCurrent: state.total,
        transferTotal: state.total,
        transferKind: 'bytes',
      );
      _scheduleSave();
      sendingImagePath = null;
      _pendingOutgoingBytes = null;
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
    _saveDebounce = Timer(const Duration(milliseconds: 250), () {
      _saveDebounce = null;
      saveChatSession();
    });
  }

  Future<void> _flushPendingSave() async {
    if (_saveDebounce == null) return;
    _saveDebounce!.cancel();
    _saveDebounce = null;
    await saveChatSession();
  }

  /// Remove a message at the given index from the shared message list
  void deleteMessageAt(int index) {
    if (index >= 0 && index < messages.length) {
      messages.removeAt(index);
    }
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
                title: const Text('Gallery'),
                onTap: () async {
                  Get.back();
                  await _pickAndSend(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Camera'),
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
            text: '[Failed to send image]',
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

  Future<String> _persistIncomingImage(Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
    // Write on a background isolate so large payloads don't jank the UI
    await compute(_writeBytesToFile, (path: path, bytes: bytes));
    return path;
  }
}