import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:hive_ce/hive.dart';

@GenerateAdapters([AdapterSpec<ChatSessionModel>(), AdapterSpec<MessageModel>()])
part 'hive_adapters.g.dart';
