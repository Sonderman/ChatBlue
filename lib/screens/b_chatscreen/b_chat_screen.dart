// ChatScreen for Bluetooth Classic — modern UI built from the shared
// chat_ui kit (dark navy canvas, cyan accents, gradient bubbles).

import 'package:chatblue/screens/b_chatscreen/b_chatscreen_controller.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class BChatScreen extends StatefulWidget {
  const BChatScreen({super.key});

  @override
  State<BChatScreen> createState() => _BChatScreenState();
}

class _BChatScreenState extends State<BChatScreen> {
  bool _allowPop = false;

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(BChatScreenController());
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final current = Get.find<BChatScreenController>();
        if (current.hasActiveTransfer) {
          // Warn before leaving mid-transfer: leaving closes the connection
          // and cancels the image transfer.
          final leave = await showChatTransferDialog();
          if (leave != true) return;
          if (!context.mounted) return;
        }
        setState(() => _allowPop = true);
        Navigator.of(context).pop();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: ChatAppBar(controller: controller),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                ChatPalette.of(context).canvasTop,
                ChatPalette.of(context).canvasBottom,
              ],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                ChatSyncBanner(controller: controller),
                Expanded(child: ChatMessageList(controller: controller)),
                ChatInputBar(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
  }
}