# Project Overview: ChatBlue

## Project Description
ChatBlue is a Flutter-based peer-to-peer chat application supporting **two transports**: Bluetooth Classic (RFCOMM) and Wi‑Fi Direct (P2P over framed TCP sockets). Both transports are implemented natively in Kotlin and exposed via Platform Channels. State management is powered by GetX; chat sessions and messages are persisted locally with Hive (CE), including image message transfer with progress tracking. The UI follows a modern navy/cyan design language with full light/dark theming.

## Architecture
- **Framework**: Flutter
- **State Management**: GetX (controllers + reactive state)
- **Local Storage**: Hive (CE) with codegen (`hive_ce_generator`) — chat sessions + theme mode (`settings` box)
- **Bluetooth (Classic)**: Custom Android native implementation via Platform Channels
- **Wi‑Fi Direct (P2P)**: Custom Android native implementation via Platform Channels
- **Platform Channels**:
  - Bluetooth
    - MethodChannel: `com.sondermium.chatblue/bt` (isBluetoothAvailable, isBluetoothEnabled, requestEnableBluetooth, requestBluetoothPermissions, requestDiscoverable, startScan, stopScan, getDiscoveredDevices, clearDiscoveredDevices, getPairedDevices, startServer, stopServer, connect, disconnect, isConnected, sendString, sendBytes)
    - EventChannels: `com.sondermium.chatblue/scan` (started/device/finished), `com.sondermium.chatblue/socket` (connected/disconnected/data/progress)
  - Wi‑Fi Direct
    - MethodChannel: `com.sondermium.chatblue/wd` (isWifiP2pSupported, requestWifiDirectPermissions, startDiscovery, stopDiscovery, getDiscoveredPeers, clearDiscoveredPeers, createGroup, removeGroup, connect, disconnect, isConnected, sendString, sendBytes)
    - EventChannels: `com.sondermium.chatblue/wd_scan` (started/peer/finished), `com.sondermium.chatblue/wd_socket` (connected/disconnected/data/progress)
- **Data Models**: `ChatSessionModel` and `MessageModel` (HiveObject) in `lib/core/models`
- **Services**:
  - `HiveService` — Hive init + CRUD on `chat_sessions` box (`lib/core/services/hive_service.dart`)
  - `ThemeService` — persistent theme mode (system/light/dark) in a `settings` box, applied via `Get.changeThemeMode` (`lib/core/services/theme_service.dart`)
  - `LocaleService` — persistent app language (en/tr) in the same `settings` box, applied via `Get.updateLocale`; first launch follows the device language (TR device → Turkish, else English) (`lib/core/services/locale_service.dart`)
  - `BtClassicService` — Bluetooth ops with typed event streams + callbacks (`lib/core/services/bt_classic_service.dart`) over `BtPlatformChannel`
  - `WifiDirectService` — Wi‑Fi Direct ops, same pattern (`lib/core/services/wd_service.dart`) over `WdPlatformChannel`
- **Theming**: `AppTheme` (light/dark, cyan seed, navy canvas) in `lib/core/theme/app_theme.dart`; chat screens use a theme-aware `ChatPalette` (dark = navy glass, light = bright variant)
- **Controllers**:
  - `BtController` — Bluetooth scan/server/socket lifecycle, reactive states, transfer progress; implements `ChatTransport` (`lib/controllers/bt_controller.dart`)
  - `WifiController` — Wi‑Fi Direct equivalent, implements `ChatTransport` (`lib/controllers/wifi_controller.dart`)
  - `ChatTransport` — shared interface over both transport controllers (`lib/controllers/chat_transport.dart`): connection state, send/message APIs, `connectToPeer(address)`, `onChatOpened()`/`onChatClosed()`
  - `HomeController` — chat session list (load/refresh/delete)
  - `ChatScreenControllerBase` — single implementation of the conversation logic (messages, image transfers, persistence, history sync, send queue) shared by both transports (`lib/screens/chat_screen_controller_base.dart`)
  - `BChatScreenController` / `WChatScreenController` — thin subclasses binding the transport (`Get.find<BtController>` / `Get.find<WifiController>`)
- **Screens**:
  - `HomeScreen` — session list + bottom navigation (Chats / Settings tabs)
  - `SettingsScreen` — theme switching (System/Light/Dark) + app info (`lib/screens/settings/settings_screen.dart`)
  - `BluetoothScanScreen` — BT discovery/paired devices/server mode/connect
  - `WifiDirectScanScreen` — WFD discovery/server (group) mode/connect
  - `BChatScreen` / `WChatScreen` — per-transport conversation UI built from the shared `chat_ui` kit (ChatAppBar, ChatMessageList, ChatMessageBubble, ChatInputBar, ChatSyncBanner, Connect bar, image preview)
- **UI Kit**: `lib/screens/chat_ui/chat_ui.dart` — shared modern chat widgets (navy/cyan, gradient bubbles, glass surfaces, theme-aware `ChatPalette`)
- **Entry Point**: `main.dart` — Sizer + GetMaterialApp (`theme`/`darkTheme`/`themeMode`), async `HiveService` + `ThemeService` init (fail-open), `HomeScreen` as home

## Key Dependencies
- get, sizer, auto_size_text
- hive_ce, hive_ce_generator, build_runner
- path_provider, uuid
- image_picker, flutter_image_compress, image_gallery_saver_plus, device_info_plus
- permission_handler, cupertino_icons
- record (voice recording), just_audio (voice playback), crypto (SHA-256 sync digests)

## Directory Structure
- `lib/`
  - `main.dart`: entry point; `config.dart`: app constants
  - `core/`
    - `models/`: `chatsession_model.dart`, `message_model.dart`
    - `platform/`: `bt_platform_channel.dart`, `wd_platform_channel.dart`
    - `services/`: `bt_classic_service.dart`, `wd_service.dart`, `hive_service.dart`, `theme_service.dart`, `locale_service.dart`
    - `translations/`: `app_translations.dart` (GetX Translations — en_US/tr_TR UI strings)
    - `theme/`: `app_theme.dart` (light/dark ThemeData)
    - `hive/`: `hive_adapters.dart` (`@GenerateAdapters`) + generated `.g.dart` files
  - `controllers/`: `bt_controller.dart`, `wifi_controller.dart`, `chat_transport.dart`
  - `screens/`: `chat_screen_controller_base.dart`, `chat_ui/` (chat_ui.dart — shared chat widget kit), `homescreen/` (home_screen + home_controller), `settings/` (settings_screen.dart), `b_chatscreen/` (b_chat_screen + b_chatscreen_controller), `w_chatscreen/` (w_chat_screen + w_chatscreen_controller), `bluetooth_scan_screen.dart`, `wifid_scan_screen.dart`
- `test/`: unit tests — model serialization, `TransferState`, Hive persistence contract
- `android/`: Gradle config + native Kotlin
  - `app/src/main/kotlin/com/sondermium/chatblue/`: `MainActivity.kt`, `BluetoothClassicManager.kt`, `WifiDirectManager.kt`
- `ios/`: scaffolding removed; iOS target not configured on this branch

## Notable Implementation Details
- Android Bluetooth Classic (`BluetoothClassicManager`): discovery with RSSI, bonded devices, discoverable request, RFCOMM SPP server/client (accept + connect threads), framed byte-stream protocol, string/byte transfer with progress callbacks, known-address persistence via SharedPreferences. The accept loop stays alive after a connection (peers can reconnect to an already-started server; a new peer replaces the current socket with "replaced").
- Android Wi‑Fi Direct (`WifiDirectManager`): peer discovery, group creation/removal (GO negotiation), client connection via WifiP2pInfo, TCP server/client socket threads with the same framed protocol and progress events; server thread also keeps accepting (same reconnect semantics); permission feature checks.
- Framed protocol: message frames carry a type flag ('text' vs 'bytes') and a 4-byte length; both managers emit `onTransferProgress(direction, current, total, kind)` and `onSocketData(bytes, text, kind)` on separate reader threads; writes run on a single-thread executor (atomic frames, FIFO order).
- `HiveService` persists sessions in the `chat_sessions` box; sessions keyed by id, sorted by `updatedAt`; `MessageModel` stores `imagePath` (not in-memory bytes) plus optional transfer state fields.
- **History sync** (`ChatScreenControllerBase`, SHA-256 based): on (re)connection each side sends a tiny **manifest** — digests of its last 10 messages (text: `sha256(text)`, images/voice: `sha256(file bytes)` + occurrence count). The peer compares against its local set and **requests only what it actually misses**; requested messages travel as `message` packets, each media file in its own packet (base64, ≤ 3 MB). When both sides match, no payload is transferred at all. Dedup uses (text + direction + ±10 s) with the SHA content-hash as fallback. Sync runs once per chat screen, outside the user send queue; a thin "Syncing history…" banner shows frame progress.
- **Send queue**: user text/image sends are serialized in a FIFO queue — an in-flight image transfer never interleaves with other sends; bubbles appear immediately, writes are ordered.
- Image messages: outgoing images are compressed pre-send; both directions use progress bubbles that finalize to image bubbles once transfer completes; incoming bytes saved under application documents directory (background isolate).
- Chat UX: connection status in the header (glowing dot), composer hidden when disconnected and replaced by a **Connect** button that reconnects to the session's device (`connectToPeer`); clearing conversation and full-screen image preview with save-to-gallery (Android 13+ `Permission.photos`/READ_MEDIA_IMAGES, older `Permission.storage`; iOS `photosAddOnly`/`photos`).
- **Voice messages**: tap-to-record (mic button in the composer, runtime `RECORD_AUDIO`), live "Recording 0:12 · Cancel" banner, automatic cut-off & send at 120 s. Files are AAC-LC (.m4a) written to app documents; a short announcement frame (`@@CHATBLUE_AUDIO@@{"duration":…}`) precedes the bytes; transfers reuse the image byte channel (progress bubbles). Voice bubbles offer play/pause, a draggable seek slider and ±10 s jumps (single `just_audio` player); messages persist as `transferKind: 'audio'` + file path (no new Hive fields) and sync as `type: "audio"` packets.
- Dialog/snackbar hygiene: loading dialogs are closed via the root navigator (GetX snackbars are overlay entries, not routes), never via `Get.back()` while a snackbar is open; socket errors are logged only (no snackbar spam); scan errors still surface.
- Progress bubbles are tracked by message id (bubble UUID); Hive writes are debounced (250 ms) and flushed on close; outgoing images are compressed exactly once.
- Chat screens use `PopScope` to warn before leaving while a transfer is in flight; theme-aware dialogs (`ChatPalette` via `Get.context`).
- `analysis_options.yaml` excludes `build/**` and `android/**` from analysis.

## Android Build Configuration
- AGP: 9.4.1 (settings.gradle.kts), Kotlin: 2.4.20, foojay-resolver-convention 1.0.0
- compileSdk: 37, targetSdk: 36, minSdk: 24
- Java/Kotlin: 17 — `compileOptions` (Java) + Kotlin `jvmTarget` via `compilerOptions` DSL (kotlinOptions kaldırıldı; KGP ≥2.2'de error)
- Gradle wrapper: 9.6.0
- `gradle.properties`: AGP 9 compatibility flags (`android.newDsl=false`, `android.builtInKotlin=false`, `android.uniquePackageNames=false`, `android.usesSdkInManifest.disallowed=false`, enableJetifier, R8/resource flags)
- Manifest: `WRITE_EXTERNAL_STORAGE maxSdkVersion=29` overrides `image_gallery_saver_plus`'s 28 via `tools:replace`; `requestLegacyExternalStorage="true"`

## Recent Changes (This Branch)
- **Self-initiated popup race fix (first-try scenario)**: the "Connection request" card appearing on the side that just initiated a connect (seen on the very first attempt, when both devices are typically acting at once) is a simultaneous-two-way-connect race: the peer's back-connection can arrive before/after `connectToPeer`'s guard flags flip. Both controllers now record `_connectInitiatedAt` and treat **every socket event within 20 s of an initiation as part of that initiation** (`_outgoingConnect || _pendingAccept || withinInitiationWindow`), so a card can never appear for a link we started; the window clears on READY/disconnect.
- **False "Could not connect!" fix**: when the peer hadn't answered yet (its request popup still up), a connect timeout reported "Could not connect!" even though the link was alive and waiting. `ChatTransport` gained `isAwaitingAcceptance` (backed by `_pendingAccept` in both controllers); scan screens and the chat reconnect button now show a neutral "Waiting for acceptance" snackbar in that state and only report failure when the socket actually died — the READY frame still opens the chat when the peer accepts late.
- **Message deletion + id persistence fix**: users can now delete their own messages — long-press a text bubble opens its selection toolbar with **Copy** (whole message when nothing selected) plus **Delete** for own messages; image/voice/progress bubbles get a themed confirm dialog on long-press (own messages only, transfers in flight excluded); `ChatScreenControllerBase.deleteMessage(id)` removes from UI + Hive. Root cause of "deletion does nothing": `MessageModelAdapter` never wrote `id` to Hive (generator skipped it — no `@HiveField`), so restored sessions had all-null ids and `deleteMessage` bailed. The model is now `@HiveField`-annotated and the regenerated adapter appends `id` at index 9 (backward compatible: old records read `null`); chat open backfills ids on legacy messages and persists them. `flutter analyze lib` → 0.
- **Initiator "Connection request" popup fix**: the side that initiated a connect could still get a request card for its own link. `connectToPeer`'s 10 s timeout branch cleared `_pendingAccept` while the socket was often still alive (peer accepting late, or a second connection event for the same link) — the next `onSocketConnected` then fell into `_showIncomingRequest`. The flag is now released only by the READY frame, an actual socket disconnect or a socket error, so the initiator never sees its own request popup (and accepting it can no longer open the peer's chat).
- **Sync banner position fix**: `ChatSyncBanner` hung ~status-bar-height below the app bar because its top margin re-added `MediaQuery.padding.top` inside a `SafeArea` that already consumed it (double counting). Banner now sits flush at 66 px (toolbar 64 + 2 gap); `ChatMessageList` head inset fixed the same way (72 px) — no `padding.top + …` offsets remain inside the SafeArea body.
- **READY frame leak fix**: the `@@CHATBLUE_CONNECT@@` handshake frame could surface as a regular chat bubble on the initiating side. `_pendingAccept` is reset by the 10 s connect timeout / disconnect handler; a READY frame arriving afterwards (peer accepted late) fell through to the chat consumer. Both controllers now match the frame **unconditionally** in `_dispatchSocketData` (and use `connectedDevice ??=`, so an already-bound device is preserved) — the frame binds the connection and can never be rendered as a message.
- **trParams placeholder fix**: GetX 4.7.x's `trParams` only replaces `@param` placeholders (never `{param}`) — all localized strings with parameters (`nearbyDevices`, `pairedDevices`, `deleteChatTitle`, `versionLabel`, `connectErrorDetail`, `recordingLabel`, `imageCaption`) switched from `{...}` to `@...` syntax; previously the raw `{count}` text was rendered on screen.
- **Scan screen TR layout fixes**: Turkish button labels overflowed the two-button row on narrow screens ('Keşfedilebilirliği Durdur' + 'Taramayı Durdur' > 360dp) — buttons now sit in `Expanded` + `FittedBox(scaleDown)` rows on both scan screens; TR labels shortened ('Görünür Yap' / 'Görünürlüğü Kapat'). Bluetooth scan error strings moved from hardcoded Kotlin literals to `res/values/strings.xml` + `values-tr/strings.xml` (`bt_scan_error_*`), so the snackbar body follows the device language too.
- **Language switch (TR/EN)**: full app localization via GetX `Translations` (`lib/core/translations/app_translations.dart`, ~60 keys, consumed with `.tr`/`.trParams`). New `LocaleService` (ThemeService pattern) persists the locale in the Hive `settings` box and applies it via `Get.updateLocale`; first launch follows the device language (Turkish device → Turkish, otherwise English). `GetMaterialApp` wires `translations`/`locale`/`fallbackLocale`; Settings gained a Language card (segmented English/Türkçe, same style as Theme). All user-facing strings across home, both scan screens, chat UI, dialogs and snackbars are localized; `flutter analyze lib` → 0 errors.
- **In-app connection request popup** (`ConnectionRequestBanner`): on the receiving device an overlay card ("Connection request") is shown for each incoming link — positioned under the app bar when a chat screen is visible, sliding from the bottom on every other screen; Accept/Decline + 15 s auto-decline. Rendered via the root navigator's own `OverlayState` (`Get.key.currentState.overlay`) — `Get.overlayContext`/`Get.context` both sit above the overlay and would throw "No Overlay widget found". `dismiss()` is idempotent (entry reference cleared before removal, double-removal swallowed).
- **Two-stage connection handshake**: the accepting side no longer marks the link connected on raw socket accept. It shows the request card and only on Accept sets `isConnected`, sends the `@@CHATBLUE_CONNECT@@` READY frame and opens the chat (Decline/timeout tears the socket down). The initiating side holds `isConnected` false and shows **no banner** (the user knows they asked to connect; `_pendingAccept || _outgoingConnect` guards against stray "Connection request" cards); only the READY frame flips it to connected and opens the chat. Disconnect while pending surfaces "Connection declined". The controller owns the service `onSocketData` slot via a dispatcher so the handshake frame never reaches the (closed) chat screen.
- **Voice messages**: `record` (AAC-LC .m4a) + `just_audio` added; tap-to-record mic button with live counter banner (Cancel via button or long-press), **120 s automatic cut-off**, announcement-frame + byte-transfer protocol (no native changes), voice bubbles with play/pause, draggable seek slider and ±10 s jumps; persisted via existing Hive fields (`transferKind: 'audio'`); included in history sync as `type: "audio"` packets.
- **SHA-256 diff sync**: history sync switched from "send everything" to a manifest → request → message handshake (digests of the last 10 messages + counts; only genuinely missing messages are transferred).
- **record fix**: `record` bumped 5.x → 6.2.1 (resolves `record_linux 0.7.2` incompatibility with `record_platform_interface 1.6.0` — `startStream`/`hasPermission` API drift); `record_linux 1.3.1` now resolves. `crypto` added for the sync digests.
- **Scan diagnostics (native)**: `startDiscovery()` return value is now checked (`SecurityException` + failure snackbar on MIUI) so a refused scan is no longer silent.
- **Theme system**: `AppTheme` light/dark themes (cyan seed, navy canvas); `ThemeService` persists the mode (system/light/dark) in a Hive `settings` box and applies it via `Get.changeThemeMode`; `main.dart` wires `theme`/`darkTheme`/`themeMode`; fails open on init errors.
- **Settings panel + bottom navigation**: `HomeScreen` now has a Material 3 `NavigationBar` with Chats / Settings tabs (`IndexedStack`); `SettingsScreen` provides Appearance (segmented System/Light/Dark) and About sections; session-list colors became theme-aware.
- **Modern chat UI kit** (`lib/screens/chat_ui/chat_ui.dart`): shared widgets for both transports — gradient glass app bar with device avatar + glowing status dot, gradient own-bubbles / glass incoming bubbles, rounded glass composer with gradient send button, image preview screen; all theme-aware through `ChatPalette` (dark: navy glass, light: bright variant); both chat screens rewritten as thin shells.
- **Connect on demand**: `ChatTransport.connectToPeer(address)` (refactored out of `connectToDevice`) + `onChatOpened()`; chat opened from the session list shows a **Connect** button when offline (loading spinner while connecting, "Could not connect!" on failure); `onChatOpened` prevents pushing a second chat screen when a connection arrives while the chat is already visible.
- **History sync for reconnecting peers**: on (re)connection the last 10 messages are exchanged once per chat screen — texts first, each image in its own base64 packet (≤ 3 MB), content-hash dedup, thin "Syncing history…" progress banner under the app bar; one sync per chat screen (no resync on every reconnect); sync is sent outside the user send queue so live sends are never blocked behind it.
- **Send queue**: user text/image sends are serialized FIFO — no interleaving during image transfers; queued jobs discarded on chat close.
- **Reconnect fixes (native)**: both `AcceptThread`/server-threads previously stopped after the first connection — peers could not reconnect to an already-started server; they now accept until cancelled (single-connection semantics preserved via "replaced").
- **Dialog/snackbar fixes**: loading dialogs dismissed via root-navigator pop (GetX counts snackbars as dialogs and `Get.back()` would close the wrong route / assert); removed snackbars from socket-error callbacks (log-only); bottom sheet converted from `Container(decoration)` to `Material` (ListTile ink visibility assertion); dark-themed chat dialogs.
- **Git hygiene**: `android/.gitignore` ignores `/build/` and `gradle-daemon-jvm.properties`; removed dead `#wifi_direct_plugin` line from pubspec.
- **AGENTS.md added at repo root** (agent rules moved out of `.cursor/rules`, which were deleted): prohibitions (no build/run without explicit permission, no git writes), verification via `flutter analyze lib` only, Turkish responses, overview maintenance.
- **Android toolchain upgrade** (settings.gradle.kts): AGP 8.13.0 → 9.4.1, Kotlin 2.1.0 → 2.4.20, added `org.gradle.toolchains.foojay-resolver-convention` 1.0.0; `gradle.properties` got AGP 9 compatibility flags; `kotlin-android` plugin id removed from the app module (Flutter Gradle Plugin applies Kotlin internally).
- Kotlin `jvmTarget` migrated from deprecated `kotlinOptions {}` (error in KGP ≥2.2) to `compilerOptions` DSL (`JvmTarget.JVM_17`).
- Gradle wrapper 8.14.3 → 8.14.5 → 9.6.0; `analysis_options.yaml` excludes `build/**` and `android/**`.
- Dependency update: all packages bumped (`flutter pub upgrade`, 90 dependencies changed).
  - Major bumps: `cupertino_icons` 1.x → 2.0.0, `image_gallery_saver_plus` 4.x → 5.1.1, `permission_handler` 12.x → 13.0.2 (requires Android compileSdk 37), `flutter_lints` 5.x → 6.0.0.
  - In-constraint bumps: `get` 4.7.3, `hive_ce` 2.20.1, `hive_ce_generator` 1.11.3, `image_picker` 1.2.3, `flutter_image_compress` 2.5.1, `path_provider` 2.1.6, `sizer` 3.1.3, `uuid` 4.6.0, `build_runner` 2.16.1.
  - `flutter analyze lib` → 0 errors.
- Android Build Configuration section aligned with compileSdk 37 / manifest `tools:replace` fix for the manifest-merger conflict with `image_gallery_saver_plus`.
- (Earlier on branch) Wi‑Fi Direct implementation; classes renamed to B/W split (`BtController`/`WifiController`, `BChatScreen`/`WChatScreen`, `BluetoothScanScreen`/`WifiDirectScanScreen`); Hive persistence; image messaging with progress bubbles; HomeScreen session list.

This overview will be kept up-to-date as the project evolves.