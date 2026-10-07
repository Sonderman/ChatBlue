import 'package:chatblue/core/hive/hive_registrar.g.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

class HiveService extends GetxService {
  /// App-wide instance, assigned by `main()` right after creation.
  ///
  /// [to] prefers this plain static reference over the GetX registry so the
  /// app path never depends on GetX's instance lifecycle — and not on its
  /// `Type.toString()` keying, which silently broke once: `Get.put` in a
  /// `HiveService?` assignment context inferred `S = HiveService?` and keyed
  /// the entry as "HiveService?", so every `Get.find<HiveService>()` missed
  /// and the first chat open crashed (see main.dart). Contexts without a
  /// `main()` (unit tests) still fall back to `Get.find`.
  static HiveService? instance;

  static HiveService get to {
    final local = instance;
    if (local != null) return local;
    return Get.find<HiveService>();
  }

  late final Box<ChatSessionModel> _chatSessionBox;

  /// Exposed for reactive consumers (Riverpod stream over box.watch()).
  Box<ChatSessionModel> get chatSessionsBox => _chatSessionBox;

  Future<HiveService> init({String? directoryPath}) async {
    // Initialize Hive
    if (directoryPath != null) {
      Hive.init(directoryPath);
    } else {
      final appDocumentDir = await getApplicationDocumentsDirectory();
      Hive.init(appDocumentDir.path);
    }
    if (kDebugMode) {
      print("Setting up Hive");
    }
    Hive.registerAdapters();

    // Open boxes
    _chatSessionBox = await Hive.openBox<ChatSessionModel>('chat_sessions');
    return this;
  }

  Future<void> saveChatSession(ChatSessionModel session) async {
    try {
      await _chatSessionBox.put(session.id, session);
      if (kDebugMode) {
        print('Saved chat session: ${session.name}');
      }
    } catch (e) {
      throw Exception('Failed to save chat session: $e');
    }
  }

  Future<ChatSessionModel?> loadChatSession(String id) async {
    try {
      return _chatSessionBox.get(id);
    } catch (e) {
      throw Exception('Failed to load chat session: $e');
    }
  }

  Future<List<ChatSessionModel>> getAllChatSessions({String? chatID}) async {
    try {
      var sessions = _chatSessionBox.values.toList();
      if (chatID != null) {
        sessions = sessions.where((s) => s.id == chatID).toList();
      }
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return sessions;
    } catch (e) {
      throw Exception('Failed to get chat sessions: $e');
    }
  }

  Future<void> deleteChatSession(String id) async {
    try {
      await _chatSessionBox.delete(id);
    } catch (e) {
      throw Exception('Failed to delete chat session: $e');
    }
  }

  Future<void> clearAllChatSessions() async {
    try {
      await _chatSessionBox.clear();
    } catch (e) {
      throw Exception('Failed to clear chat sessions: $e');
    }
  }
}
