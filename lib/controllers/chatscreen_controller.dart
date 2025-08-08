import 'dart:async';
import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/bt_controller.dart';
import 'package:chatblue/models/message_model.dart';
import 'package:chatblue/services/bt_classic_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class ChatScreenController extends GetxController {
  final RxList<MessageModel> messages = <MessageModel>[].obs;
  final BtController btController = Get.find();
  final TextEditingController textController = TextEditingController();
  RxBool get isConnected => btController.isConnected;
  StreamSubscription<bool>? connectionSubscription;
  StreamSubscription? _messagesSubscription;
  StreamSubscription<String?>? _disconnectSubscription;
  // Tracks progress message indices separately for outgoing and incoming transfers
  int? _outgoingProgressIndex;
  int? _incomingProgressIndex;
  // Holds bytes for the currently sending image to convert progress bubble into final image
  Uint8List? _pendingOutgoingBytes;

  @override
  void onInit() {
    // Ensure any pending modal/progress dialog from previous screen is closed
    if (Get.isDialogOpen == true) {
      Get.back();
    }
    connectionSubscription = btController.isConnected.listen((event) {
      // Do not auto-close chat screen; UI reflects connection state via AppBar
      // When disconnected, leave messages as-is and show 'Offline' in header
    });
    setupCallbacks();
    _disconnectSubscription = btController.lastDisconnectReason.listen((reason) {
      if (reason != null && reason.isNotEmpty) {
        Get.snackbar('Disconnected', 'Peer closed the connection ($reason)');
      }
    });
    super.onInit();
  }

  @override
  void onClose() {
    textController.dispose();
    // Disconnect when leaving the chat screen to release the socket cleanly
    btController.disconnectFromDevice();
    connectionSubscription?.cancel();
    _messagesSubscription?.cancel();
    _disconnectSubscription?.cancel();
    btController.onChatClosed();
    super.onClose();
  }

  void setupCallbacks() {
    btController.onSocketData((bytes, text, {required String kind}) {
      if (kDebugMode) {
        print('Socket data: $text\n Kind: $kind');
      }
      if (kind == 'bytes' && bytes.isNotEmpty) {
        // Prefer updating the existing incoming progress bubble if present
        if (_incomingProgressIndex != null &&
            _incomingProgressIndex! >= 0 &&
            _incomingProgressIndex! < messages.length) {
          final int idx = _incomingProgressIndex!;
          messages[idx] = messages[idx].copyWith(
            isSentByMe: false,
            timestamp: DateTime.now(),
            imageBytes: bytes,
            isTransferring: false,
          );
          // Completed: clear pointer to avoid further updates
          _incomingProgressIndex = null;
        } else {
          // Try to find any existing incoming progress bubble in the list
          final int foundIdx = messages.indexWhere(
            (m) => m.isTransferring == true && m.transferKind == 'bytes' && m.isSentByMe == false,
          );
          if (foundIdx != -1) {
            messages[foundIdx] = messages[foundIdx].copyWith(
              isSentByMe: false,
              timestamp: DateTime.now(),
              imageBytes: bytes,
              isTransferring: false,
            );
            _incomingProgressIndex = null;
          } else if (messages.isNotEmpty &&
              messages[0].isTransferring == true &&
              messages[0].transferKind == 'bytes' &&
              messages[0].isSentByMe == false) {
            // Fallback to top bubble if it looks like an incoming transfer
            messages[0] = messages[0].copyWith(
              isSentByMe: false,
              timestamp: DateTime.now(),
              imageBytes: bytes,
              isTransferring: false,
            );
            _incomingProgressIndex = null;
          } else {
            // If no progress bubble exists (edge case), insert a complete image message
            messages.insert(
              0,
              MessageModel(
                text: "[Image] (${bytes.lengthInBytes} bytes)",
                isSentByMe: false,
                timestamp: DateTime.now(),
                imageBytes: bytes,
              ),
            );
            // Reindex pointers due to head insertion
            if (_incomingProgressIndex != null) {
              _incomingProgressIndex = _incomingProgressIndex! + 1;
            }
            if (_outgoingProgressIndex != null) {
              _outgoingProgressIndex = _outgoingProgressIndex! + 1;
            }
          }
        }
      } else {
        messages.insert(0, MessageModel(text: text, isSentByMe: false, timestamp: DateTime.now()));
        // Reindex any existing progress pointers when a new incoming text message is added
        if (_incomingProgressIndex != null) {
          _incomingProgressIndex = _incomingProgressIndex! + 1;
        }
        if (_outgoingProgressIndex != null) {
          _outgoingProgressIndex = _outgoingProgressIndex! + 1;
        }
      }
    });
    btController.onTransferProgress(({
      required direction,
      required current,
      required total,
      required kind,
    }) {
      final state = TransferState(direction: direction, current: current, total: total, kind: kind);
      if (direction == 'out') {
        btController.outgoingTransfer.value = state;
        if (kind == 'bytes') {
          final bool needsNew =
              _outgoingProgressIndex == null ||
              _outgoingProgressIndex! < 0 ||
              _outgoingProgressIndex! >= messages.length ||
              messages[_outgoingProgressIndex!].isTransferring == false ||
              messages[_outgoingProgressIndex!].isSentByMe == false;

          if (needsNew) {
            messages.insert(
              0,
              MessageModel(
                text:
                    "${(state.total == 0 ? 0 : (state.current / state.total * 100)).toStringAsFixed(0)}%",
                isSentByMe: true,
                timestamp: DateTime.now(),
                transferCurrent: state.current,
                transferTotal: state.total,
                isTransferring: true,
                transferKind: 'bytes',
              ),
            );
            // Reindex incoming pointer due to head insertion
            if (_incomingProgressIndex != null) {
              _incomingProgressIndex = _incomingProgressIndex! + 1;
            }
            _outgoingProgressIndex = 0;
          } else {
            final int idx = _outgoingProgressIndex!;
            messages[idx] = messages[idx].copyWith(
              text:
                  "${(state.total == 0 ? 0 : (state.current / state.total * 100)).toStringAsFixed(0)}%",
              transferCurrent: state.current,
              transferTotal: state.total,
              isTransferring: state.current < state.total,
            );
          }

          // Finalize outgoing: convert progress bubble into the actual image message
          if (state.total > 0 && state.current >= state.total && _outgoingProgressIndex != null) {
            final int idx = _outgoingProgressIndex!;
            final Uint8List? bytesToAttach = _pendingOutgoingBytes;
            messages[idx] = messages[idx].copyWith(
              text: bytesToAttach != null
                  ? "[Image] (${bytesToAttach.lengthInBytes} bytes)"
                  : messages[idx].text,
              imageBytes: bytesToAttach ?? messages[idx].imageBytes,
              isTransferring: false,
              transferCurrent: state.total,
              transferTotal: state.total,
              transferKind: 'bytes',
            );
            _pendingOutgoingBytes = null;
            _outgoingProgressIndex = null;
          }
        }
      } else {
        btController.incomingTransfer.value = state;
        if (kind == 'bytes') {
          // If transfer already completed, avoid creating/updating bubble here; wait for data finalize
          if (state.total > 0 && state.current >= state.total) {
            return;
          }
          final bool needsNew =
              _incomingProgressIndex == null ||
              _incomingProgressIndex! < 0 ||
              _incomingProgressIndex! >= messages.length ||
              messages[_incomingProgressIndex!].isTransferring == false ||
              messages[_incomingProgressIndex!].isSentByMe == true;

          if (needsNew) {
            messages.insert(
              0,
              MessageModel(
                text:
                    "${(state.total == 0 ? 0 : (state.current / state.total * 100)).toStringAsFixed(0)}%",
                isSentByMe: false,
                timestamp: DateTime.now(),
                transferCurrent: state.current,
                transferTotal: state.total,
                isTransferring: true,
                transferKind: 'bytes',
              ),
            );
            // Reindex outgoing pointer due to head insertion
            if (_outgoingProgressIndex != null) {
              _outgoingProgressIndex = _outgoingProgressIndex! + 1;
            }
            _incomingProgressIndex = 0;
          } else {
            final int idx = _incomingProgressIndex!;
            messages[idx] = messages[idx].copyWith(
              text:
                  "${(state.total == 0 ? 0 : (state.current / state.total * 100)).toStringAsFixed(0)}%",
              transferCurrent: state.current,
              transferTotal: state.total,
              isTransferring: state.current < state.total,
            );
          }

          // For incoming, finalize only when data bytes arrive in onSocketData
        }
      }

      if (kDebugMode && showDebugLogs) {
        print('Transfer progress: $direction $current $total $kind');
      }
    });
  }

  void sendTextMessage() {
    if (isConnected.value) {
      btController.sendMessage(textController.text);
      messages.insert(
        0,
        MessageModel(text: textController.text, isSentByMe: true, timestamp: DateTime.now()),
      );
      // Reindex existing progress pointers due to head insertion
      if (_incomingProgressIndex != null) {
        _incomingProgressIndex = _incomingProgressIndex! + 1;
      }
      if (_outgoingProgressIndex != null) {
        _outgoingProgressIndex = _outgoingProgressIndex! + 1;
      }
      textController.clear();
    }
  }

  /// Remove a message at the given index from the shared message list
  void deleteMessageAt(int index) {
    if (index >= 0 && index < messages.length) {
      messages.removeAt(index);
    }
  }

  Future<void> pickAndSendImage() async {
    if (!isConnected.value) return;
    final ImagePicker picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null) return;

    Uint8List bytes = await file.readAsBytes();
    // Compress before sending to reduce transfer time
    try {
      final compressed = await FlutterImageCompress.compressWithList(bytes, quality: 70);
      if (compressed.isNotEmpty) {
        bytes = Uint8List.fromList(compressed);
      }
    } catch (_) {}

    try {
      // Keep bytes to finalize the outgoing progress bubble into an image message
      _pendingOutgoingBytes = bytes;
      await btController.sendBytes(bytes);
    } catch (_) {
      final int? idx = _outgoingProgressIndex ?? (messages.isNotEmpty ? 0 : null);
      if (idx != null && idx < messages.length) {
        messages[idx] = messages[idx].copyWith(
          text: '[Failed to send image] ${file.name}',
          isTransferring: false,
        );
      }
      _pendingOutgoingBytes = null;
      _outgoingProgressIndex = null;
    }
  }

  Future<void> showImageSourceSheet() async {
    if (!isConnected.value) return;
    Get.bottomSheet(
      SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: Get.theme.cardColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
            ),
          ),
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
    final ImagePicker picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: source, imageQuality: 85);
    if (file == null) return;

    Uint8List bytes = await file.readAsBytes();
    try {
      final compressed = await FlutterImageCompress.compressWithList(bytes, quality: 70);
      if (compressed.isNotEmpty) {
        bytes = Uint8List.fromList(compressed);
      }
    } catch (_) {}

    try {
      // Keep bytes to finalize the outgoing progress bubble into an image message
      _pendingOutgoingBytes = bytes;
      await btController.sendBytes(bytes);
    } catch (_) {
      final int? idx = _outgoingProgressIndex ?? (messages.isNotEmpty ? 0 : null);
      if (idx != null && idx < messages.length) {
        messages[idx] = messages[idx].copyWith(
          text: '[Failed to send image] ${file.name}',
          isTransferring: false,
        );
      }
      _pendingOutgoingBytes = null;
      _outgoingProgressIndex = null;
    }
  }
}
