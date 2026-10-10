// Message data class for Bluetooth chat application.
// This class represents a single chat message with its content, sender status, and timestamp.

/// Plain message record (was `HiveObject` until the drift migration, P1).
/// Legacy Hive records may lack `id` (read back null) — the chat-open
/// backfill repairs those and persists them; drift rows carry every field 1:1.
class MessageModel {
  final String text;

  final bool isSentByMe;

  final DateTime timestamp;

  final String? id;

  final bool isTransferring;

  final int? transferCurrent;

  final int? transferTotal;

  final String? transferKind; // 'bytes' | 'text' | 'audio'

  final String? imagePath;

  /// Byte size of the media file when it is deliberately NOT stored locally
  /// yet: the file lives on the peer (deferred sync of large media), the
  /// bubble renders a download placeholder and fetches it on tap. Null for
  /// ordinary messages and once the file has been downloaded.
  final int? remoteMediaSize;

  /// Delivery state of an OUTGOING message ('pending' → 'sent' →
  /// 'delivered', or 'failed'); null for incoming messages and for rows
  /// persisted before the delivery-tick feature. Drives the bubble's tick
  /// icon (the state machine lives in the chat controller).
  final String? delivery;

  /// [delivery] state values.
  static const String deliveryPending = 'pending';
  static const String deliverySent = 'sent';
  static const String deliveryDelivered = 'delivered';
  static const String deliveryFailed = 'failed';

  MessageModel({
    this.id,
    required this.text,
    required this.isSentByMe,
    required this.timestamp,
    this.imagePath,
    this.remoteMediaSize,
    this.delivery,
    this.isTransferring = false,
    this.transferCurrent,
    this.transferTotal,
    this.transferKind,
  });

  /// True when this message carries a voice recording instead of text/image.
  bool get isAudio => transferKind == 'audio';

  /// True when this message carries a file attachment (see the chat
  /// controller's file pipeline: `imagePath` holds the file's path, the
  /// caption its display name/size).
  bool get isFile => transferKind == 'file';

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
    String? delivery,
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
      delivery: delivery ?? this.delivery,
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
      'delivery': delivery,
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
      delivery: json['delivery'] as String?,
    );
  }
}
