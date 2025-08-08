# Project Overview: ChatBlue

## Project Description
ChatBlue is a Flutter-based Bluetooth chat application. The primary feature is communication via Bluetooth between devices. State management is handled using GetX. Currently, messages are not stored locally, but data classes are defined for messages.

## Architecture
- **Framework**: Flutter
- **State Management**: GetX
- **Bluetooth (Classic)**: Custom Android native implementation via Platform Channels
- **Data Models**: Message class for chat messages
- **Screens**:
  - Device Scan Screen: For discovering and connecting to Bluetooth devices
  - Chat Screen: For sending and receiving messages
- **Controllers**: BluetoothController for managing Bluetooth operations
- **Platform Channels**:
  - MethodChannel: `com.sondermium.chatblue/bt`
  - EventChannels:
    - Scan events: `com.sondermium.chatblue/scan` (started/device/finished)
    - Socket events: `com.sondermium.chatblue/socket` (connected/disconnected/data)

## Key Dependencies
- get: For state management
- Others: cupertino_icons, etc.

## Directory Structure
- lib/
  - main.dart: Entry point with GetMaterialApp
  - config.dart: App constants
  - models/message.dart: Message data class
  - controllers/bluetooth_controller.dart: GetX controller for Bluetooth
  - screens/device_scan_screen.dart: Screen for scanning devices
  - screens/chat_screen.dart: Screen for chatting
- android/: Android-specific configurations, including Manifest for permissions
- ios/: iOS-specific configurations

## Notable Implementation Details
- Android Bluetooth Classic is implemented natively in Kotlin (`BluetoothClassicManager`).
- Discovery (scan), discoverable request, paired devices, RFCOMM server/client, and byte/string data transfer are supported.
- Platform API is wrapped in Dart (`lib/platform/bt_platform_channel.dart`).
- Bluetooth permissions added to `AndroidManifest.xml` (including Android 12+ runtime perms).
- Default SPP UUID: `00001101-0000-1000-8000-00805F9B34FB`, overridable via MethodChannel args.
- GetX used for state management in controllers and UI updates.

## Recent Changes
- Chat progress bubbles: `ChatScreenController` now creates and updates progress message bubbles for both outgoing and incoming image transfers using `onTransferProgress`. When the transfer completes:
  - Outgoing: progress bubble is converted into the final image message using the bytes kept in memory until completion.
  - Incoming: progress bubble is updated, and once the actual bytes arrive via `onSocketData`, the bubble is finalized into an image message.
- `ChatScreen` renders progress UI for both text-less progress bubbles and image-in-progress bubbles (linear progress and byte counters).

This overview will be updated as the project evolves. 