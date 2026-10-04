import 'package:chatblue/controllers/bt_controller.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/screens/chat_screen_controller_base.dart';

/// Bluetooth-flavored chat controller; all logic lives in
/// [ChatScreenControllerBase].
class BChatScreenController extends ChatScreenControllerBase {
  BChatScreenController() : super(ensureRegistered<BtController>(BtController()));
}