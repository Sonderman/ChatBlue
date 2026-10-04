// Message data class for Bluetooth chat application.
// This class represents a single chat message with its content, sender status, and timestamp.

import 'package:hive_ce/hive.dart';

/// Field indexes are part of the persisted schema — keep them stable.
/// The generator appends `id` at the end (index 9); older records simply
/// lack it (read back as null and backfilled on chat open).
class MessageModel extends HiveObject {
  @HiveField(0)
  final String text;

  @HiveField(1)
  final bool isSentByMe;

  @HiveField(2)
  final DateTime timestamp;

  @HiveField(3)
  final String? id;

  @HiveField(4)
  final bool isTransferring;

  @HiveField(5)
  final int? transferCurrent;

  @HiveField(6)
  final int? transferTotal;

  @HiveField(7)
  final String? transferKind; // 'bytes' | 'text'

  @HiveField(8)
  final String? imagePath;

  MessageModel({
    this.id,
    required this.text,
    required this.isSentByMe,
    required this.timestamp,
    this.imagePath,
    this.isTransferring = false,
    this.transferCurrent,
    this.transferTotal,
    this.transferKind,
  });

  /// True when this message carries a voice recording instead of text/image.
  bool get isAudio => transferKind == 'audio';

  MessageModel copyWith({
    String? id,
    String? text,
    bool? isSentByMe,
    DateTime? timestamp,
    String? imagePath,
    bool? isTransferring,
    int? transferCurrent,
    int? transferTotal,
    String? transferKind,
  }) {
    return MessageModel(
      id: id ?? this.id,
      text: text ?? this.text,
      isSentByMe: isSentByMe ?? this.isSentByMe,
      timestamp: timestamp ?? this.timestamp,
      imagePath: imagePath ?? this.imagePath,
      isTransferring: isTransferring ?? this.isTransferring,
      transferCurrent: transferCurrent ?? this.transferCurrent,
      transferTotal: transferTotal ?? this.transferTotal,
      transferKind: transferKind ?? this.transferKind,
    );
  }

  // Convert MessageModel instance to JSON map for serialization
  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'isSentByMe': isSentByMe,
      'timestamp': timestamp.toIso8601String(),
      'imagePath': imagePath,
    };
  }

  // Create MessageModel instance from JSON map for deserialization
  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      text: json['text'] ?? '',
      isSentByMe: json['isSentByMe'] ?? false,
      timestamp: json['timestamp'] != null ? DateTime.parse(json['timestamp']) : DateTime.now(),
      imagePath: json['imagePath'],
    );
  }
}