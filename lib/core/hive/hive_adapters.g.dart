// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hive_adapters.dart';

// **************************************************************************
// AdaptersGenerator
// **************************************************************************

class ChatSessionModelAdapter extends TypeAdapter<ChatSessionModel> {
  @override
  final typeId = 0;

  @override
  ChatSessionModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChatSessionModel(
      id: fields[0] as String,
      name: fields[1] as String,
      createdAt: fields[2] as DateTime,
      updatedAt: fields[3] as DateTime,
      messages: (fields[4] as List).cast<MessageModel>(),
      device: (fields[5] as Map).cast<String, dynamic>(),
    );
  }

  @override
  void write(BinaryWriter writer, ChatSessionModel obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.messages)
      ..writeByte(5)
      ..write(obj.device);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatSessionModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MessageModelAdapter extends TypeAdapter<MessageModel> {
  @override
  final typeId = 1;

  @override
  MessageModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MessageModel(
      text: fields[0] as String,
      isSentByMe: fields[1] as bool,
      timestamp: fields[2] as DateTime,
      imagePath: fields[8] as String?,
      isTransferring: fields[4] == null ? false : fields[4] as bool,
      transferCurrent: (fields[5] as num?)?.toInt(),
      transferTotal: (fields[6] as num?)?.toInt(),
      transferKind: fields[7] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, MessageModel obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.text)
      ..writeByte(1)
      ..write(obj.isSentByMe)
      ..writeByte(2)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.isTransferring)
      ..writeByte(5)
      ..write(obj.transferCurrent)
      ..writeByte(6)
      ..write(obj.transferTotal)
      ..writeByte(7)
      ..write(obj.transferKind)
      ..writeByte(8)
      ..write(obj.imagePath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
