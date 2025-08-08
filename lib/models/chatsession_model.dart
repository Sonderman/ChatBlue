import 'package:chatblue/models/message_model.dart';

class ChatSessionModel {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<MessageModel> messages;
  final Map<String, dynamic> device;

  ChatSessionModel({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    required this.device,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'messages': messages.map((e) => e.toJson()).toList(),
      'device': device,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory ChatSessionModel.fromJson(Map<String, dynamic> json) {
    return ChatSessionModel(
      id: json['id'],
      name: json['name'],
      messages: json['messages'].map((e) => MessageModel.fromJson(e)).toList(),
      device: json['device'],
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
    );
  }
}
