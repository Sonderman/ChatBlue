// Shared display formatters for the chat surfaces (connection panel,
// bubbles, dialogs). Kept OUT of chat_ui.dart so the controller (dialogs,
// notices) can use them without importing the widget kit.

/// Compact byte size ("1.2 MB", "184 KB").
String formatFileSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).round()} KB';
  }
  return '$bytes B';
}

/// Uptime label for the connection panel: "04:32" or "1:04:32".
String formatUptime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
