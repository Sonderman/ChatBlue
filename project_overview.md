# Project Overview: ChatBlue

## Project Description
ChatBlue is a Flutter-based Bluetooth Classic chat application. The app enables device-to-device messaging over RFCOMM. State management is powered by GetX. Chat sessions and messages are now persisted locally using Hive, including support for sending/receiving image messages with transfer progress.

## Architecture
- **Framework**: Flutter
- **State Management**: GetX
- **Local Storage**: Hive (CE)
- **Bluetooth (Classic)**: Custom Android native implementation via Platform Channels
- **Platform Channels**:
  - MethodChannel: `com.sondermium.chatblue/bt`
  - EventChannels:
    - Scan events: `com.sondermium.chatblue/scan` (started/device/finished)
    - Socket events: `com.sondermium.chatblue/socket` (connected/disconnected/data)
- **Data Models**:
  - `ChatSessionModel` and `MessageModel` (HiveObject) in `lib/core/models`
- **Services**:
  - `HiveService` for Hive initialization and CRUD on chat sessions (`lib/core/services/hive_service.dart`)
  - `BtClassicService` for Bluetooth operations (`lib/core/services/bt_classic_service.dart`) backed by `lib/core/platform/bt_platform_channel.dart`
- **Controllers**:
  - `BtController` orchestrates scan/connect/socket lifecycle and exposes reactive states
  - `HomeController` manages persisted chat sessions list (load/refresh/delete)
  - `ChatScreenController` manages per-chat messages, sending text/images, transfer progress, and persistence
- **Screens**:
  - `HomeScreen`: Lists previous chat sessions with quick action to scan/connect
  - `DeviceScanScreen`: Discover nearby/paired devices and connect
  - `ChatScreen`: Conversation UI with text and image bubbles, progress indicators
- **Entry Point**:
  - `main.dart` initializes `HiveService` asynchronously and sets `HomeScreen` as the home widget

## Key Dependencies
- get, sizer, auto_size_text
- hive_ce, hive_ce_generator, build_runner
- path_provider, uuid
- image_picker, flutter_image_compress, image_gallery_saver_plus
- permission_handler, cupertino_icons

## Directory Structure
- `lib/`
  - `main.dart`: Entry point with `GetMaterialApp`
  - `config.dart`: App constants
  - `core/`
    - `models/`: `chatsession_model.dart`, `message_model.dart`
    - `platform/`: `bt_platform_channel.dart`
    - `services/`: `bt_classic_service.dart`, `hive_service.dart`
    - `hive/`: adapters and registrar (`hive_adapters.dart`, generated files)
  - `controllers/`: `bt_controller.dart`, `home_controller.dart`, `chatscreen_controller.dart`
  - `screens/`: `home_screen.dart`, `device_scan_screen.dart`, `chat_screen.dart`
- `android/`: Android-specific configuration and native Bluetooth manager
- `ios/`: iOS scaffolding was removed in this branch (see Recent Changes)

## Notable Implementation Details
- Android Bluetooth Classic is implemented natively in Kotlin (`BluetoothClassicManager`) and exposed via platform channels. Discovery, discoverable mode, paired devices, RFCOMM server/client, and string/byte transfer are supported.
- `HiveService` initializes Hive and persists chat sessions in a `chat_sessions` box. Sessions are keyed by device address (or a generated id) and sorted by `updatedAt`.
- Image messages are transferred as bytes with progress bubbles. Incoming bytes are saved to application documents directory and the bubble is finalized with an `imagePath`. Outgoing progress bubbles are converted to final image bubbles once transfer completes.
- `ChatScreen` shows connection status, prevents sending when disconnected, supports clearing the conversation, and allows full-screen image preview with optional save-to-gallery (runtime permissions handled per platform).
- `DeviceScanScreen` exposes discoverable/server mode, start/stop scanning, lists nearby and paired devices, and connects with feedback dialogs and snackbars.

## Android Build Configuration
- compileSdk: 36
- targetSdk: 36
- minSdk: 24
- Java/Kotlin: 17 (sourceCompatibility/targetCompatibility/jvmTarget)

## Recent Changes (This Branch)
- Moved platform channel file to `lib/core/platform/bt_platform_channel.dart` and updated imports accordingly.
- Introduced `HiveService` and full chat session persistence.
  - Added Hive adapters/registrar for `ChatSessionModel` and `MessageModel`.
  - `MessageModel` uses `imagePath` instead of in-memory bytes.
  - Added `path_provider` and `uuid` dependencies.
- Enhanced image messaging with progress bubbles and finalization, persisting messages after each update.
- Added `HomeScreen` and `HomeController` to manage and navigate chat sessions.
- Updated `main.dart` to initialize Hive and set `HomeScreen` as the start screen.
- Improved `DeviceScanScreen` UI/UX (button states, paired devices tab, loading dialog, connection failure snackbar).
- `BtController` now handles connection attempt errors immediately and uses a 10-second timeout for connections.
- Android Gradle updates: compile/target SDKs, minSdk, and Java/Kotlin 17.
- iOS: Runner workspace/storyboards/Info.plist and asset catalog files were removed; iOS target is currently not configured in this branch and would need re-setup if required.

This overview will be kept up-to-date as the project evolves. 