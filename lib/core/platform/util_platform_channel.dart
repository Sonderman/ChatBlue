import 'package:flutter/services.dart';

/// Small app-level utility channel: open a received file with the system
/// viewer (the native side owns the FileProvider uri dance), save received
/// APKs into the public Downloads folder (the app holds no install-packages
/// permission — Google Play restricts it), and launch a maps app for
/// coordinates (geo: intent with an https fallback).
class UtilPlatformChannel {
  UtilPlatformChannel._();

  static const MethodChannel _channel =
      MethodChannel('com.sondermium.chatblue/util');

  /// Opens [path] with the system viewer. Returns 'opened' or 'failed'
  /// (file missing, unreachable, or no app can open it).
  static Future<String> openFile(String path) async =>
      await _channel.invokeMethod<String>('openFile', {'path': path}) ??
      'failed';

  /// Copies a received package archive (APK) into the public Downloads
  /// folder — MediaStore on Android 10+, the legacy public dir below.
  /// Returns 'saved', 'permission' (pre-Android-10 storage grant missing —
  /// request it and retry once) or 'failed'.
  static Future<String> saveApkToDownloads(String path) async =>
      await _channel.invokeMethod<String>('saveApkToDownloads', {
        'path': path,
      }) ??
      'failed';

  /// Opens the coordinates in a maps app. False when no app handles them.
  static Future<bool> openMap({
    required double lat,
    required double lng,
  }) async =>
      await _channel.invokeMethod<bool>('openMap', {'lat': lat, 'lng': lng}) ??
      false;
}
