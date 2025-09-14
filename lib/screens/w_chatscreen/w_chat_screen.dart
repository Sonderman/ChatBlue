// ChatScreen for displaying and sending chat messages over Bluetooth.
// Uses GetX for state management.

import 'dart:io';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/screens/w_chatscreen/w_chatscreen_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sizer/sizer.dart';

class WChatScreen extends StatelessWidget {
  const WChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(WChatScreenController());
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AutoSizeText(
              controller.wifiController.connectedDevice?.deviceName ??
                  controller.wifiController.connectedDevice?.deviceAddress ??
                  controller.chatSession.name,
              maxLines: 1,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Obx(
              () => Text(
                controller.isConnected.value ? 'Connected' : 'Not Connected !',
                style: TextStyle(
                  fontSize: 11,
                  color: controller.isConnected.value ? Colors.green : Colors.redAccent,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear Chat',
            onPressed: () {
              Get.defaultDialog(
                title: 'Clear conversation',
                middleText: 'Are you sure you want to clear all messages?',
                textCancel: 'Cancel',
                textConfirm: 'Clear',
                onConfirm: () {
                  controller.messages.clear();
                  controller.saveChatSession();
                  Get.back();
                },
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Obx(
                () => ListView.builder(
                  reverse: true,
                  itemCount: controller.messages.length,
                  itemBuilder: (context, index) {
                    final MessageModel msg = controller.messages[index];
                    final bubbleColor = msg.isSentByMe ? Colors.blue : Colors.grey;
                    final align = msg.isSentByMe ? Alignment.centerRight : Alignment.centerLeft;
                    final radius = BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: msg.isSentByMe
                          ? const Radius.circular(16)
                          : const Radius.circular(4),
                      bottomRight: msg.isSentByMe
                          ? const Radius.circular(4)
                          : const Radius.circular(16),
                    );

                    Widget bubbleContent;
                    if (msg.imagePath != null) {
                      final showProgress = msg.isTransferring && (msg.transferKind == 'bytes');
                      bubbleContent = GestureDetector(
                        onTap: showProgress
                            ? null
                            : () {
                                Get.to(() => _ImagePreviewScreen(path: msg.imagePath!));
                              },
                        child: IntrinsicWidth(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Compact image thumbnail: limit width and height to keep bubbles small
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: 45.w, maxHeight: 30.h),
                                  child: Image.file(File(msg.imagePath!), fit: BoxFit.cover),
                                ),
                              ),
                              if (showProgress)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      LinearProgressIndicator(
                                        value:
                                            ((msg.transferCurrent ?? 0) / (msg.transferTotal ?? 1))
                                                .clamp(0, 1)
                                                .toDouble(),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${msg.isSentByMe ? 'Sending' : 'Receiving'} ${(msg.transferCurrent ?? 0)}/${(msg.transferTotal ?? 0)} bytes',
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(fontSize: 10, color: Colors.black54),
                                      ),
                                    ],
                                  ),
                                ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _formatTimestamp(msg.timestamp),
                                  style: const TextStyle(fontSize: 10, color: Colors.black45),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    } else {
                      final bool showProgress = msg.isTransferring && (msg.transferKind == 'bytes');
                      if (showProgress) {
                        bubbleContent = Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(
                              value: ((msg.transferCurrent ?? 0) / (msg.transferTotal ?? 1))
                                  .clamp(0, 1)
                                  .toDouble(),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${msg.isSentByMe ? 'Sending' : 'Receiving'} ${(msg.transferCurrent ?? 0)}/${(msg.transferTotal ?? 0)} bytes (${((msg.transferTotal ?? 0) == 0 ? 0 : ((msg.transferCurrent ?? 0) / (msg.transferTotal ?? 1) * 100)).toStringAsFixed(0)}%)',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 10, color: Colors.black54),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                _formatTimestamp(msg.timestamp),
                                style: const TextStyle(fontSize: 10, color: Colors.black45),
                              ),
                            ),
                          ],
                        );
                      } else {
                        bubbleContent = Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SelectableText(msg.text, style: const TextStyle(height: 1.2)),
                            const SizedBox(height: 4),
                            Text(
                              _formatTimestamp(msg.timestamp),
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        );
                      }
                    }

                    return Align(
                      alignment: align,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: bubbleColor.withOpacity(msg.imagePath != null ? 0.15 : 1.0),
                          borderRadius: radius,
                        ),
                        child: bubbleContent,
                      ),
                    );
                  },
                ),
              ),
            ),
            if (controller.isConnected.value)
              Padding(
                padding: EdgeInsets.all(8),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.image),
                      onPressed: () async {
                        final c = Get.find<WChatScreenController>();
                        await c.showImageSourceSheet();
                      },
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller.textController,
                        decoration: InputDecoration(hintText: 'Type a message'),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.send),
                      tooltip: 'Send',
                      onPressed: () {
                        if (controller.isConnected.value &&
                            controller.textController.text.isNotEmpty) {
                          controller.sendTextMessage();
                        }
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Formats timestamp in 24-hour format as HH:mm
  String _formatTimestamp(DateTime t) {
    final time = TimeOfDay.fromDateTime(t);
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _ImagePreviewScreen extends StatelessWidget {
  const _ImagePreviewScreen({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Save to Gallery',
            onPressed: () async {
              // Request runtime permissions before saving
              if (GetPlatform.isAndroid) {
                final status = await Permission.storage.request();
                if (!status.isGranted) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Storage permission is required to save images.'),
                      ),
                    );
                  }
                  return;
                }
              } else if (GetPlatform.isIOS) {
                var status = await Permission.photosAddOnly.request();
                if (!status.isGranted) {
                  status = await Permission.photos.request();
                  if (!status.isGranted) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Photos permission is required to save images.'),
                        ),
                      );
                    }
                    return;
                  }
                }
              }
              final file = File(path);
              final res = await ImageGallerySaverPlus.saveImage(
                file.readAsBytesSync(),
                quality: 95,
                name: 'chatblue_${DateTime.now().millisecondsSinceEpoch}',
              );
              if (context.mounted) {
                final ok = res is Map && (res['isSuccess'] == true || res['filePath'] != null);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(ok ? 'Saved to gallery' : 'Save failed')));
              }
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
      ),
    );
  }
}
