import 'package:chatblue/core/models/message_model.dart';
import 'package:hive_ce/hive.dart';

class ChatSessionModel extends HiveObject {
  /// Transport ids persisted in [transport].
  static const String transportBluetooth = 'bt';
  static const String transportWifiDirect = 'wfd';

  final String id;
  final String name;
  final DateTime createdAt;
  DateTime updatedAt;
  List<MessageModel> messages;
  final Map<String, dynamic> device;

  /// Channel this chat was created over ([transportBluetooth] /
  /// [transportWifiDirect]); null on sessions persisted before the field
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
