import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:chatblue/screens/home_screen.dart';
import 'package:sizer/sizer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupServices();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Sizer(
      builder: (context, orientation, deviceType) => GetMaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
        home: const HomeScreen(),
      ),
    );
  }
}

Future<void> setupServices() async {
  await Get.putAsync(() => HiveService().init());
}
