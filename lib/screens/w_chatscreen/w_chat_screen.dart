// ChatScreen for Wi‑Fi Direct — modern UI built from the shared chat_ui kit
// (dark navy canvas, cyan accents, gradient bubbles).

import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:chatblue/screens/w_chatscreen/w_chatscreen_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WChatScreen extends StatefulWidget {
  const WChatScreen({super.key});

  @override
  State<WChatScreen> createState() => _WChatScreenState();
}

class _WChatScreenState extends State<WChatScreen> {
  bool _allowPop = false;

  @override
  void dispose() {
    // The chat controller is registered via Get.put but never auto-deleted
    // when the route pops: without this, onClose (socket disconnect + P2P
    // group teardown + _chatOpen reset) never runs, the first connection
    // stays alive and the next attempt fails — "connects once, then never
    // again".
    Get.delete<WChatScreenController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(WChatScreenController());
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final current = Get.find<WChatScreenController>();
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