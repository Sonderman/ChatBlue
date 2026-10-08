// ChatScreen for Nearby Connections — modern UI built from the shared
// chat_ui kit (dark navy canvas, cyan accents, gradient bubbles).

import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:chatblue/screens/n_chatscreen/n_chatscreen_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class NChatScreen extends StatefulWidget {
  const NChatScreen({super.key});

  @override
  State<NChatScreen> createState() => _NChatScreenState();
}

class _NChatScreenState extends State<NChatScreen> {
  bool _allowPop = false;

  @override
  void dispose() {
    // Get.put controllers are never auto-deleted on route pop: without this,
    // onClose (disconnect + _chatOpen reset) never runs and the next
    // session's connection/accept flow starts from dirty state.
    Get.delete<NChatScreenController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(NChatScreenController());
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final current = Get.find<NChatScreenController>();
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
