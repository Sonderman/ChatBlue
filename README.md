## ChatBlue

![ChatBlue Logo](assets/chatblue_logo.png)

Bluetooth Classic tabanlı, tamamen çevrimdışı çalışan bir uçtan uca sohbet uygulaması. İnternet ve yerel ağların kullanılamadığı, özellikle deprem gibi afet senaryolarında kısa mesafede cihazdan cihaza iletişim kurmayı hedefler.

> Note: This repository targets Android (Bluetooth Classic via RFCOMM). iOS support is not configured in this branch.

### Purpose
- Enable peer-to-peer messaging over Bluetooth Classic without any internet or local network.
- Designed for emergency scenarios (e.g., earthquakes) when connectivity is unavailable.
- Also useful for short-range communication when you intentionally stay offline.

TR — Amaç: Bu uygulamanın temel amacı, internet ve yerel haberleşme ağlarının mevcut olmadığı özellikle deprem felaketinin meydana geldiği durumlarda insanların haberleşebilmesini sağlamaktır. Böyle felaketler olmasa bile internet erişiminin olmadığı durumlarda kısa mesafelerde iletişim kurabilmeyi hedefler.

### Features
- Offline chat over Bluetooth Classic (RFCOMM)
- Device discovery, connect/disconnect flow, paired devices support
- Send/receive text and image messages with transfer progress indicators
- Local persistence of chat sessions and messages (Hive)
- Modern Flutter UI with GetX state management

### How It Works
- Uses a custom Android native Bluetooth Classic implementation exposed to Flutter via Platform Channels.
- When devices are paired and connected, messages are exchanged as text or bytes. Incoming images are saved to local storage.
- No server, no internet, no cloud — everything is local to the devices.

### Screens at a Glance
- Home: list of previous chat sessions and quick actions
- Device Scan: scan nearby devices and connect
- Chat: conversation view with text/image bubbles and progress

### Requirements
- Flutter SDK >= 3.8
- Android device with Bluetooth Classic capability
- Android Studio (or VS Code) and an Android device/emulator (physical device recommended for Bluetooth)

### Android Build Targets
- compileSdk: 36
- targetSdk: 36
- minSdk: 24
- Java/Kotlin: 17

### Permissions
Depending on Android version, the app may request:
- BLUETOOTH, BLUETOOTH_ADMIN or (Android 12+) BLUETOOTH_SCAN, BLUETOOTH_CONNECT
- ACCESS_COARSE_LOCATION / ACCESS_FINE_LOCATION (scanning requirements on older Android versions)
- READ/WRITE/PHOTOS permissions for saving received images to the gallery

### Getting Started
```bash
git clone https://github.com/Sonderman/ChatBlue.git
cd chatblue
flutter pub get
# Open Android device/emulator with Bluetooth enabled, then run from your IDE or:
flutter run -d <your-android-device-id>
```

Once running:
1) Ensure Bluetooth is enabled on both devices.
2) From Device Scan, discover and connect to a nearby device (pairing may be required).
3) Start chatting and optionally send images. Transfer progress will be shown in bubbles.

### Architecture & Tech Stack
- Flutter with GetX state management
- Hive CE for local storage and offline persistence
- Android native Bluetooth Classic implementation (Kotlin) bridged via Platform Channels

For a deeper technical overview, see: `project_overview.md`.

### Limitations and Safety Notes
- Short-range only: Bluetooth Classic range is limited and environment-dependent.
- Not a replacement for emergency services. Do not rely on the app as the sole communication method in life-threatening situations.
- Messages are not end-to-end encrypted in this branch. Do not share sensitive information.
- Android only in this branch; iOS configuration was removed and would need re-setup.

### Privacy
- No internet connectivity is used by the app.
- Messages and sessions are stored locally on the device using Hive.

### Contributing
Contributions are welcome! Please open an issue to discuss significant changes before submitting a PR. Make sure to run formatting and address lints.

### License
This project is available under the license found in `LICENSE`.

### Acknowledgements
- Flutter team and ecosystem packages: GetX, Hive, image picker/compress, permission handler, etc.
