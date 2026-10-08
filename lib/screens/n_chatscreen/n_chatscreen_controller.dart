import 'package:chatblue/controllers/transport_adapter.dart';
import 'package:chatblue/screens/chat_screen_controller_base.dart';
import 'package:get/get.dart';

/// Nearby Connections–flavored chat controller; all logic lives in
/// [ChatScreenControllerBase].
class NChatScreenController extends ChatScreenControllerBase {
  NChatScreenController() : super(_obtainAdapter());

  /// Only builds an adapter on a registry MISS — unlike the B/W siblings'
  /// `ensureRegistered<T>(T instance)`, which constructs its argument even
  /// when an instance is already registered (leaking one live
  /// `container.listen` subscription per screen open).
  static NearbyTransportAdapter _obtainAdapter() {
    if (Get.isRegistered<NearbyTransportAdapter>()) {
      return Get.find<NearbyTransportAdapter>();
    }
    return Get.put<NearbyTransportAdapter>(NearbyTransportAdapter());
  }
}
