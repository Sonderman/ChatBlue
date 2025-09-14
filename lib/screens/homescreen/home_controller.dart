import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:get/get.dart';

/// GetX controller responsible for managing chat sessions (in-memory).
/// Sessions are created/updated when a Bluetooth connection is established
/// and can be enriched by recording messages during a conversation.
class HomeController extends GetxController {
  /// Reactive list of chat sessions shown on the chats screen.
  final RxList<ChatSessionModel> sessions = <ChatSessionModel>[].obs;

  @override
  void onInit() async {
    sessions.value = await HiveService.to.getAllChatSessions();
    super.onInit();
  }

  void refreshSessions() async {
    sessions.value = await HiveService.to.getAllChatSessions();
  }

  void deleteSession(ChatSessionModel session) async {
    await HiveService.to.deleteChatSession(session.id);
    refreshSessions();
  }
}
