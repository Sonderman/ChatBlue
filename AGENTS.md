# AGENTS.md — ChatBlue

ChatBlue: GetX tabanlı Flutter P2P mesajlaşma uygulaması. İki taşıma kanalı vardır: **Bluetooth Classic (RFCOMM)** ve **Wi‑Fi Direct (TCP socket)**. Her iki taşıma da Android'de native Kotlin (Platform Channels) ile uygulanmıştır.

---

## Yasaklar (açık izin olmadan asla)

- **Build/run/install komutları çalıştırma**: `flutter run`, `flutter build *`, emülatör/simülatör başlatma, web/desktop başlatma, APK kurulumu. Değişiklik doğrulaması yalnızca `flutter analyze lib` ile yapılır.
- **Git yazma işlemleri**: commit, push, branch açma — yalnızca kullanıcı açıkça istediğinde. Salt okunur komutlar (status/log/diff) serbesttir.
- **`flutter pub upgrade --tighten` kullanımı**: pubspec.yaml'ın düzenli inline-yorum yapısını bozar; bağımlılık constraint'leri hedefli `patch` ile değiştirilir.
- Drive-by refactor/rename/reformat yapma; görev kapsamı dışındaki koda dokunma.
- `.env`, kimlik ve credential dosyalarını okuma/değiştirme.

## Doğrulama

- Değişiklik sonrası tek doğrulama aracı: `/Volumes/eXSSD/Sdks/flutter/bin/flutter analyze lib` → **0 error**.
- Mevcut lint infoları (avoid_print, unnecessary_import, deprecated_member_use vb.) baseline'dır; yalnızca **yeni error'lar** sorun sayılır.
- Android/Gradle tarafı doğrulaması kullanıcıya bırakılır; kullanıcı build hatası paylaşırsa düzeltilir (build'i kendin çalıştırma).

## Konvansiyonlar

- Yanıt dili: **Türkçe** (kullanıcı İngilizce yazarsa o dile geçilir).
- UI dili: **İngilizce varsayılan + Türkçe seçeneği** (Settings → Language; ilk açılışta cihaz dili Türkçe ise Türkçe başlar; çeviriler `lib/core/translations/app_translations.dart` üzerinden `.tr` ile tüketilir).
- Göreve başlamadan önce `project_overview.md` oku; önemli değişikliklerden sonra onu güncelle (architecture / directory / recent-changes bölümleri).
- Commit istendiğinde: tek commit, mesaj tüm değişiklikleri kapsar, commit öncesi `project_overview.md` güncellenir.
- Kod: mevcut stile ve GetX katman düzenine (services → controllers → screens) uy; mevcut özellikleri bozmadan değişiklik yap.

## Ortam

- Flutter SDK: `/Volumes/eXSSD/Sdks/flutter/bin` — PATH'te **yok**, tam yol kullanılmalı.
- Bağımlılık güncelleme akışı: `flutter pub outdated` → major bump'larda changelog/migration kontrolü → pubspec constraint patch → `flutter pub upgrade` → analyze.
- Hive CE codegen: `lib/core/hive/hive_adapters.dart` içindeki `@GenerateAdapters` + `build_runner` (`flutter pub run build_runner build` gerekirse).

## Mimari Özet

```
lib/
  main.dart               → Sizer + GetMaterialApp (light/dark/themeMode), HiveService + ThemeService başlatılır, HomeScreen açılır
  config.dart             → appName, appVersion, showDebugLogs
  core/
    models/               → ChatSessionModel, MessageModel (HiveObject)
    platform/             → BtPlatformChannel, WdPlatformChannel (Method/Event Channel tanımları)
    services/             → HiveService, ThemeService, BtClassicService, WifiDirectService
    theme/                → AppTheme (light/dark ThemeData, cyan seed + navy canvas)
    hive/                 → hive_adapters.dart + generated (.g.dart)
  controllers/
    bt_controller.dart    → Bluetooth Classic akışı (GetX); ChatTransport implementasyonu
    wifi_controller.dart  → Wi‑Fi Direct akışı (GetX); ChatTransport implementasyonu
    chat_transport.dart   → Bt/Wifi için ortak arayüz (connectToPeer, onChatOpened/Closed)
  screens/
    chat_screen_controller_base.dart → B/W sohbet mantığının TEK implementasyonu (mesaj, transfer, senkronizasyon, gönderim kuyruğu)
    chat_ui/              → chat_ui.dart: ortak modern sohbet widget kiti (ChatAppBar, Balon, InputBar, SyncBanner, ConnectBar, Preview) — ChatPalette ile tema-duyarlı
    homescreen/           → HomeScreen (bottom nav: Chats/Settings) + HomeController
    settings/             → SettingsScreen (tema seçimi + hakkında)
    b_chatscreen/         → BChatScreen + BChatScreenController (BT sohbet)
    w_chatscreen/         → WChatScreen + WChatScreenController (WFD sohbet)
    bluetooth_scan_screen.dart
    wifid_scan_screen.dart
test/                     → model/TransferState/Hive unit testleri (flutter test ile çalışır)

android/app/src/main/kotlin/com/sondermium/chatblue/
  MainActivity.kt                  → kanal kurulumu, handler yönlendirme, runtime istekleri
  BluetoothClassicManager.kt       → RFCOMM server/client, discovery, transfer (accept döngüsü kalıcı — yeniden bağlantı)
  WifiDirectManager.kt             → P2P group/peer, framed TCP I/O, transfer (server döngüsü kalıcı)
```

**Platform kanalları:**
- BT: `com.sondermium.chatblue/bt` (method), `/scan` + `/socket` (event)
- WFD: `com.sondermium.chatblue/wd` (method), `/wd_scan` + `/wd_socket` (event)

**Veri akışı:** `Manager (Kotlin) → PlatformChannel → Service (callback/stream) → Controller (GetX reactive) → Screen`.

**Not:** B/W sohbet ekranları `ChatScreenControllerBase`'i paylaşır; taşıma farkları `ChatTransport` arayüzü ile soyutlanır. Unit testler `flutter test` ile koşulur (yalnızca kullanıcı isterse çalıştırılır).