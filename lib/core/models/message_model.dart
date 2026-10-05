// Message data class for Bluetooth chat application.
// This class represents a single chat message with its content, sender status, and timestamp.

import 'package:hive_ce/hive.dart';

/// Field indexes are part of the persisted schema — keep them stable.
/// The generator appends `id` at the end (index 9); older records simply
/// lack it (read back as null and backfilled on chat open). Message-level
/// additions keep appending: `remoteMediaSize` is index 10.
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
  final String? transferKind; // 'bytes' | 'text' | 'audio'

  @HiveField(8)
  final String? imagePath;

  /// Byte size of the media file when it is deliberately NOT stored locally
  /// yet: the file lives on the peer (deferred sync of large media), the
  /// bubble renders a download placeholder and fetches it on tap. Null for
  /// ordinary messages and once the file has been downloaded.
  @HiveField(10)
  final int? remoteMediaSize;

  MessageModel({
    this.id,
    required this.text,
    required this.isSentByMe,
    required this.timestamp,
    this.imagePath,
    this.remoteMediaSize,
    this.isTransferring = false,
    this.transferCurrent,
    this.transferTotal,
    this.transferKind,
  });

  /// True when this message carries a voice recording instead of text/image.
  bool get isAudio => transferKind == 'audio';

  /// True when this message is a placeholder for media that still lives on
  /// the peer (deferred sync): the bubble offers download-on-tap.
  bool get hasRemoteMedia => remoteMediaSize != null && imagePath == null;

  /// Returns a copy with the given fields replaced. Note: `remoteMediaSize`
  /// is carried through (not settable to null here) — clearing it happens
  /// by constructing the message explicitly with the downloaded file.
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
      remoteMediaSize: remoteMediaSize,
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
      'remoteMediaSize': remoteMediaSize,
    };
  }

  // Create MessageModel instance from JSON map for deserialization
  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      text: json['text'] ?? '',
      isSentByMe: json['isSentByMe'] ?? false,
      timestamp: json['timestamp'] != null ? DateTime.parse(json['timestamp']) : DateTime.now(),
      imagePath: json['imagePath'],
      remoteMediaSize: json['remoteMediaSize'] as int?,
    );
  }
}
