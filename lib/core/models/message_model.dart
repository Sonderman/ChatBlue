// Message data class for Bluetooth chat application.
// This class represents a single chat message with its content, sender status, and timestamp.

import 'package:hive_ce/hive.dart';

class MessageModel extends HiveObject {
  final String text;
  final bool isSentByMe;
  final DateTime timestamp;
  final String? imagePath;
  final bool isTransferring;
  final int? transferCurrent;
  final int? transferTotal;
  final String? transferKind; // 'bytes' | 'text'

  MessageModel({
    required this.text,
    required this.isSentByMe,
    required this.timestamp,
    this.imagePath,
    this.isTransferring = false,
    this.transferCurrent,
    this.transferTotal,
    this.transferKind,
  });

  MessageModel copyWith({
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
