import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Root Hive service. `main()` overrides it after the async init; tests
/// override it with an in-memory instance. Null when Hive could not start
/// (fail-open — consumers render empty states).
final hiveServiceProvider = Provider<HiveService?>((ref) => null);

/// Live chat-session list for the home screen. The stream re-emits whenever
/// the box changes, so new messages reorder chats, renames and deletions
/// show up without manual refreshes (replaces HomeController/Refresh flows).
final homeSessionsProvider = StreamProvider<List<ChatSessionModel>>((ref) {
  final service = ref.watch(hiveServiceProvider);
  if (service == null) return Stream.value(const <ChatSessionModel>[]);
  return _sessionsStream(service);
});

Stream<List<ChatSessionModel>> _sessionsStream(HiveService service) async* {
  yield await service.getAllChatSessions();
  await for (final _ in service.chatSessionsBox.watch()) {
    yield await service.getAllChatSessions();
  }
}

/// Deletes a chat session; the list stream then re-emits automatically.
final deleteChatSessionProvider =
    Provider<Future<void> Function(ChatSessionModel)>(
  (ref) => (session) async {
    final service = ref.read(hiveServiceProvider);
    if (service == null) return;
    await service.deleteChatSession(session.id);
  },
);