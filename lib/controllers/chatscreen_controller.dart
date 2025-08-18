import 'dart:async';
import 'dart:io';
import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/bt_controller.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:chatblue/controllers/home_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class ChatScreenController extends GetxController {
  late ChatSessionModel chatSession;
  final RxList<MessageModel> messages = <MessageModel>[].obs;
  final BtController btController = Get.find();
  final HomeController chatsController = Get.find();
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

  String? sendingImagePath;

  @override
  void onInit() async {
    if (Get.arguments is ChatSessionModel) {
      chatSession = Get.arguments as ChatSessionModel;
      messages.value = chatSession.messages;
    } else {
      final foundSession = await HiveService.to.loadChatSession(
        btController.connectedDevice?.address ?? Uuid().v4(),
      );
      chatSession =
          foundSession ??
          ChatSessionModel(
            id: btController.connectedDevice?.address ?? Uuid().v4(),
            name:
                btController.connectedDevice?.name ??
                btController.connectedDevice?.address ??
                'Unknown',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            messages: messages,
            device: {
              'name': btController.connectedDevice?.name,
              'address': btController.connectedDevice?.address,
              'type': btController.connectedDevice?.type,
              'rssi': btController.connectedDevice?.rssi,
            },
          );
      messages.value = chatSession.messages;
    }

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
        Get.snackbar('Disconnected', 'Other device closed the connection');
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
    btController.onSocketData((bytes, text, {required String kind}) async {
      if (kDebugMode) {
        print('Socket data: $text\n Kind: $kind');
      }
      if (kind == 'bytes' && bytes.isNotEmpty) {
        // Prefer updating the existing incoming progress bubble if present
        if (_incomingProgressIndex != null &&
            _incomingProgressIndex! >= 0 &&
            _incomingProgressIndex! < messages.length) {
          final int idx = _incomingProgressIndex!;
          // Persist incoming image to app documents and finalize the bubble
          final Directory path = await getApplicationDocumentsDirectory();
          final File file = File('${path.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
          await file.writeAsBytes(bytes);

          messages[idx] = messages[idx].copyWith(
            text: "[Image] (${bytes.lengthInBytes} bytes)",
            isSentByMe: false,
            timestamp: DateTime.now(),
            imagePath: file.path,
            isTransferring: false,
          );
          saveChatSession();
          // Completed: clear pointer to avoid further updates
          _incomingProgressIndex = null;
        } else {
          // Try to find any existing incoming progress bubble in the list
          final int foundIdx = messages.indexWhere(
            (m) => m.isTransferring == true && m.transferKind == 'bytes' && m.isSentByMe == false,
          );
          if (foundIdx != -1) {
            // Persist incoming image and convert the found progress bubble
            final Directory path = await getApplicationDocumentsDirectory();
            final File file = File('${path.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
            await file.writeAsBytes(bytes);
            messages[foundIdx] = messages[foundIdx].copyWith(
              text: "[Image] (${bytes.lengthInBytes} bytes)",
              isSentByMe: false,
              timestamp: DateTime.now(),
              imagePath: file.path,
              isTransferring: false,
            );
            saveChatSession();
            _incomingProgressIndex = null;
          } else if (messages.isNotEmpty &&
              messages[0].isTransferring == true &&
              messages[0].transferKind == 'bytes' &&
              messages[0].isSentByMe == false) {
            // Fallback to top bubble if it looks like an incoming transfer
            final Directory path = await getApplicationDocumentsDirectory();
            final File file = File('${path.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
            await file.writeAsBytes(bytes);
            messages[0] = messages[0].copyWith(
              text: "[Image] (${bytes.lengthInBytes} bytes)",
              isSentByMe: false,
              timestamp: DateTime.now(),
              imagePath: file.path,
              isTransferring: false,
            );
            saveChatSession();
            _incomingProgressIndex = null;
          } else {
            final Directory path = await getApplicationDocumentsDirectory();
            final File file = File('${path.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
            await file.writeAsBytes(bytes);
            // If no progress bubble exists (edge case), insert a complete image message
            messages.insert(
              0,
              MessageModel(
                text: "[Image] (${bytes.lengthInBytes} bytes)",
                isSentByMe: false,
                timestamp: DateTime.now(),
                imagePath: file.path,
              ),
            );
            saveChatSession();

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
        final msg = MessageModel(text: text, isSentByMe: false, timestamp: DateTime.now());
        messages.insert(0, msg);
        saveChatSession();

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
              imagePath: sendingImagePath ?? messages[idx].imagePath,
              isTransferring: false,
              transferCurrent: state.total,
              transferTotal: state.total,
              transferKind: 'bytes',
            );
            saveChatSession();
            sendingImagePath = null;
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
      final msg = MessageModel(
        text: textController.text,
        isSentByMe: true,
        timestamp: DateTime.now(),
      );
      messages.insert(0, msg);
      saveChatSession();

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

  Future<void> saveChatSession() async {
    chatSession.messages = messages.toList();
    chatSession.updatedAt = DateTime.now();
    await HiveService.to.saveChatSession(chatSession);
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
    sendingImagePath = file.path;
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
