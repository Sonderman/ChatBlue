import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/bt_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:chatblue/screens/device_scan_screen.dart';
import 'package:sizer/sizer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    Get.put(BtController()); // Initialize controller
    return Sizer(
      builder: (context, orientation, deviceType) => GetMaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
        home: DeviceScanScreen(),
      ),
    );
  }
}
