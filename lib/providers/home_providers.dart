import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live chat-session list for the home screen — drift `watchSessions()`
/// akışı: oturum satırı her değiştiğinde (yeni mesaj, rename, silme) stream
/// yeniden yayınlar; manuel refresh gerekmez (eski `box.watch()` köprüsünün
/// drift karşılığı).
final homeSessionsProvider = StreamProvider<List<ChatSessionModel>>((ref) {
  try {
    return ref.watch(sessionRepositoryProvider).watchSessions();
  } catch (_) {
    // Fail-open: veritabanı override edilmediyse (açılış hatası) boş liste —
    // Hive dönemindeki null-service davranışıyla aynı.
    return Stream.value(const <ChatSessionModel>[]);
  }
});

/// Deletes a chat session; the list stream then re-emits automatically.
final deleteChatSessionProvider =
    Provider<Future<void> Function(ChatSessionModel)>(
  (ref) => (session) async {
    try {
      await ref.read(sessionRepositoryProvider).deleteChatSession(session.id);
    } catch (_) {
      // Fail-open: veritabanı yoksa silme sessizce atlanır (Hive dönemiyle
      // aynı davranış).
      return;
    }
  },
);
