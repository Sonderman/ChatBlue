// ChatScreen for Nearby Connections — modern UI built from the shared
// chat_ui kit (dark navy canvas, cyan accents, gradient bubbles).

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/providers/chat_controller.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NChatScreen extends ConsumerStatefulWidget {
  const NChatScreen({super.key});

  @override
  ConsumerState<NChatScreen> createState() => _NChatScreenState();
}

class _NChatScreenState extends ConsumerState<NChatScreen> {
  bool _allowPop = false;
  ChatOpenArg? _arg;
  ChatController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_arg != null) return;
    // Home-list opens carry the stored session; scan/incoming opens pass no
    // arguments and the controller reconstructs the session from the live
    // transport identity.
    final session = ModalRoute.of(context)?.settings.arguments;
    _arg = ChatOpenArg(
      transport: ChatSessionModel.transportNearby,
      session: session is ChatSessionModel ? session : null,
    );
    _controller = ref.read(chatControllerProvider(_arg!).notifier);
  }

  @override
  void dispose() {
    // Deterministic teardown on route pop — the old GetX onClose ordering:
    // socket disconnect + transport chat-open reset happen synchronously
    // here, so reconnects start from clean state. The provider's autoDispose
    // keeps a lifecycle-safe backup teardown.
    _controller?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatControllerProvider(_arg!));
    final controller = _controller!;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (ref.read(chatControllerProvider(_arg!)).hasActiveTransfer) {
          // Warn before leaving mid-transfer: leaving closes the connection
          // and cancels the image transfer.
          final leave = await showChatTransferDialog(context);
          if (leave != true) return;
          if (!context.mounted) return;
        }
        setState(() => _allowPop = true);
        Navigator.of(context).pop();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: ChatAppBar(state: state, controller: controller),
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
                ChatLinkPanel(state: state, controller: controller),
                ChatSyncBanner(state: state),
                Expanded(
                  child: ChatMessageList(state: state, controller: controller),
                ),
                ChatInputBar(state: state, controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
