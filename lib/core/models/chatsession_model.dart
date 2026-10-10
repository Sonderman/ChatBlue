import 'package:chatblue/core/models/message_model.dart';

/// Plain data model (was `HiveObject` until the drift migration, P1):
/// sessions/messages persist through `SessionRepository`, which mirrors these
/// fields 1:1 in the drift `sessions`/`messages` tables.
class ChatSessionModel {
  /// Transport ids persisted in [transport].
  static const String transportBluetooth = 'bt';
  static const String transportWifiDirect = 'wfd';
  static const String transportNearby = 'nearby';

  final String id;
  final String name;
  final DateTime createdAt;
  DateTime updatedAt;
  List<MessageModel> messages;
  final Map<String, dynamic> device;

  /// Channel this chat was created over ([transportBluetooth] /
  /// [transportWifiDirect] / [transportNearby]); null on sessions persisted before the field
  /// existed (backfilled with the transport in use when the chat opens).
  String? transport;

  ChatSessionModel({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    required this.device,
    this.transport,
  });

  /// Transport this chat is displayed and reopened with: the recorded
  /// [transport] when present, otherwise inferred from the stored device
  /// address — Wi‑Fi Direct P2P MACs are randomized (locally-administered
  /// bit set in the first octet) while Bluetooth MACs are globally
  /// administered; anything inconclusive falls back to Bluetooth, the
  /// channel every pre-tagging session was opened with.
  String get transportKind {
    final tagged = transport;
    if (tagged != null && tagged.isNotEmpty) return tagged;
    final address = device['address'];
    if (address is String && _isLocallyAdministeredMac(address)) {
      return transportWifiDirect;
    }
    return transportBluetooth;
  }

  /// True for a locally administered MAC (bit 1 of the first octet set):
  /// the framework randomizes P2P device addresses while Bluetooth
  /// addresses are globally administered vendor OUIs.
  static bool _isLocallyAdministeredMac(String mac) {
    final parts = mac.split(':');
    if (parts.length != 6) return false;
    final firstOctet = int.tryParse(parts.first, radix: 16);
    return firstOctet != null && (firstOctet & 0x02) != 0;
  }

  /// True for a raw hardware model code ("M2101K6G", "2412DPC0AG",
  /// "SM-G610F"): no lowercase letters, no whitespace, at least one digit.
  /// These make two phones indistinguishable and are never preferred over a
  /// human-readable display name.
  static bool isRawModelCode(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return false;
    if (RegExp(r'\s').hasMatch(v)) return false;
    if (RegExp(r'[a-z]').hasMatch(v)) return false;
    if (!RegExp(r'[0-9]').hasMatch(v)) return false;
    return RegExp(r'^[A-Z0-9][A-Z0-9-]*$').hasMatch(v);
  }

  /// Whether a live peer name should replace the stored display name: any
  /// non-empty change EXCEPT a raw model code replacing a real display name
  /// (older peers report models over identity frames; a stored display name
  /// must never be downgraded, while stale model titles are upgraded).
  static bool shouldReplaceDisplayName(String? current, String? incoming) {
    final next = (incoming ?? '').trim();
    if (next.isEmpty) return false;
    final cur = (current ?? '').trim();
    if (cur.isEmpty) return true;
    if (cur == next) return false;
    if (isRawModelCode(next) && !isRawModelCode(cur)) return false;
    return true;
  }

  /// Returns a copy of this session bound to the CURRENT connection's
  /// identity: the stored device address and the transport tag are refreshed
  /// so the persisted identity always matches the channel the chat is
  /// actually running on.
  ///
  /// Needed after cross-transport merges (the same peer reached over another
  /// transport): those keep the OLD session's device map, so e.g. a
  /// Nearby-era session carries the peer's uid in `device['address']` while
  /// re-keyed under a Bluetooth MAC — a later Bluetooth reconnect would then
  /// dial the uid and the native side rejects it ("not a valid Bluetooth
  /// address"). With this, the address always belongs to the scheme of the
  /// transport the session is tagged with.
  ///
  /// [address] overrides the stored one only when non-null and non-empty
  /// (pass null to keep the old value); [peerName], when it is a usable
  /// upgrade, refreshes the display name — the title and the device name —
  /// so a stale raw model code heals to the peer's real name on reconnect
  /// (and a display name is never downgraded); [transport] is the channel in
  /// use now.
  ChatSessionModel reboundTo({
    String? address,
    String? peerName,
    required String transport,
  }) {
    final live = (peerName ?? '').trim();
    final bool upgrade = shouldReplaceDisplayName(name, live);
    final Object? stored = device['name'];
    final String? resolvedName = upgrade
        ? live
        : (stored is String && stored.isNotEmpty
            ? stored
            : (live.isNotEmpty ? live : null));
    return ChatSessionModel(
      id: id,
      name: upgrade ? live : name,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
      device: {
        'name': resolvedName,
        'address': (address != null && address.isNotEmpty)
            ? address
            : device['address'],
      },
      transport: transport,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'messages': messages.map((e) => e.toJson()).toList(),
      'device': device,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'transport': transport,
    };
  }

  factory ChatSessionModel.fromJson(Map<String, dynamic> json) {
    return ChatSessionModel(
      id: json['id'],
      name: json['name'],
      messages: (json['messages'] as List)
          .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      device: json['device'],
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
      transport: json['transport'],
    );
  }
}
