import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:uuid/uuid.dart';

/// Stable per-install device identifier.
///
/// Wi‑Fi Direct P2P MACs are randomized and rotate across P2P restarts, so
/// they cannot persistently key a chat session (the same peer would spawn a
/// new session on every MAC change, and the accepting vs initiating sides
/// key differently). Each install generates one uuid (stored in the
/// `settings` Hive box) and shares it inside the WFD identity frame; the
/// peer uses it as its session key, so the same phone always merges into
/// the same session regardless of MAC rotation or who initiated.
class DeviceIdService {
  static const String _boxName = 'settings';
  static const String _key = 'device_id';

  static String? _cached;

  /// Returns this device's stable id, generating and persisting it on first
  /// use. Fail-open: if Hive is not available yet, a per-process random id
  /// still lets sessions merge within the current run.
  static Future<String> get() async {
    if (_cached != null) return _cached!;
    try {
      final box = Hive.box(_boxName);
      var id = box.get(_key) as String?;
      if (id == null || id.isEmpty) {
        id = const Uuid().v4();
        await box.put(_key, id);
      }
      _cached = id;
      return id;
    } catch (e) {
      // Persistence unavailable (fail-open): a per-process id still merges
      // within this run, but a RESTART generates a new id — the peer would
      // then key sessions under a new id and old conversations would look
      // lost. Log it so this condition is visible.
      if (kDebugMode) {
        debugPrint('DeviceIdService: Hive unavailable, per-process id: $e');
      }
      return _cached ??= const Uuid().v4();
    }
  }
}