import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/controllers/transport_adapter.dart';
import 'package:chatblue/screens/chat_screen_controller_base.dart';

/// Wi‑Fi Direct–flavored chat controller; all logic lives in
/// [ChatScreenControllerBase].
class WChatScreenController extends ChatScreenControllerBase {
  WChatScreenController()
      : super(ensureRegistered<WdTransportAdapter>(WdTransportAdapter()));
}