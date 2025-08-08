// Message data class for Bluetooth chat application.
// This class represents a single chat message with its content, sender status, and timestamp.

import 'dart:typed_data';

class MessageModel {
  final String text;
  final bool isSentByMe;
  final DateTime timestamp;
  final Uint8List? imageBytes;
  final bool isTransferring;
  final int? transferCurrent;
  final int? transferTotal;
  final String? transferKind; // 'bytes' | 'text'

  MessageModel({
    required this.text,
    required this.isSentByMe,
    required this.timestamp,
    this.imageBytes,
    this.isTransferring = false,
    this.transferCurrent,
    this.transferTotal,
    this.transferKind,
  });

  MessageModel copyWith({
    String? text,
    bool? isSentByMe,
    DateTime? timestamp,
    Uint8List? imageBytes,
    bool? isTransferring,
    int? transferCurrent,
    int? transferTotal,
    String? transferKind,
  }) {
    return MessageModel(
      text: text ?? this.text,
      isSentByMe: isSentByMe ?? this.isSentByMe,
      timestamp: timestamp ?? this.timestamp,
      imageBytes: imageBytes ?? this.imageBytes,
      isTransferring: isTransferring ?? this.isTransferring,
      transferCurrent: transferCurrent ?? this.transferCurrent,
      transferTotal: transferTotal ?? this.transferTotal,
      transferKind: transferKind ?? this.transferKind,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'isSentByMe': isSentByMe,
      'timestamp': timestamp.toIso8601String(),
      // Not serializing imageBytes in this simple model
    };
  }

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      text: json['text'],
      isSentByMe: json['isSentByMe'],
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}
