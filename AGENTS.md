# AGENTS.md — ChatBlue

ChatBlue: Flutter P2P mesajlaşma uygulaması; state katmanı GetX'ten Riverpod'a taşınıyor (app state + transport notifier'ları Riverpod; chat ekranları geçiş boyunca GetX + `transport_adapter.dart` köprüsü ile çalışır). İki taşıma kanalı vardır: **Bluetooth Classic (RFCOMM)** ve **Wi‑Fi Direct (TCP socket)**. Her iki taşıma da Android'de native Kotlin (Platform Channels) ile uygulanmıştır.

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
- UI dili: **İngilizce varsayılan + Türkçe seçeneği** (Settings → Language; ilk açılışta cihaz dili Türkçe ise Türkçe başlar; çeviriler chat ekranlarında `.tr` (`lib/core/translations/app_translations.dart`), ported ekranlarda gen-l10n (`lib/l10n`, `AppLocalizations`) üzerinden tüketilir).
- Göreve başlamadan önce `project_overview.md` oku; önemli değişikliklerden sonra onu güncelle (architecture / directory / recent-changes bölümleri).
- Commit istendiğinde: tek commit, mesaj tüm değişiklikleri kapsar, commit öncesi `project_overview.md` güncellenir. Mesajlar **İngilizce** ve Conventional Commits formatındadır: `feat:`/`fix:` başlığı + neden odaklı, alan alan bölümlenmiş gövde; sonuna `project_overview.md updated.` satırı eklenir; uzun mesaj scratch dosyaya yazılıp `git commit -F <dosya>` ile verilir.
- Kod: mevcut stile ve GetX katman düzenine (services → controllers → screens) uy; mevcut özellikleri bozmadan değişiklik yap.

## Ortam

- Flutter SDK: `/Volumes/eXSSD/Sdks/flutter/bin` — PATH'te **yok**, tam yol kullanılmalı.
- Bağımlılık güncelleme akışı: `flutter pub outdated` → major bump'larda changelog/migration kontrolü → pubspec constraint patch → `flutter pub upgrade` → analyze.
- Drift codegen: şema değişikliğinde `lib/data/db/` (tables + app_database) → `dart run build_runner build` (`app_database.g.dart` üretilir; commit kapsamına dahildir). (Hive CE codegen'i P3'te söküldü.)
- **minSdk 24 tabanı**: `play-services-nearby` 19.5.1 `minSdkVersion=24` gerektirir (AAR manifestinden doğrulandı) — mevcut minSdk 24 ile uyumlu (Gradle değişikliği gerekmez), ancak minSdk 24'ün altına inilemez; cihazda Google Play Services şart.

## Test Ortamı

- Cihazlar: **Redmi Note 10 (Android 13, MIUI 14)** ve **POCO X7 Pro**.
- POCO X7 Pro Wi‑Fi Direct'i fiilen desteklemiyor: P2P servisi var (`manager` null değil) ama tüm P2P işlemleri firmware seviyesinde başarısız (`discoverPeers` ERROR(0), gelen müzakere yok, sistem davetiyesi çıkmaz) → **WFD testleri Redmi ile yapılır**.
- MIUI'de Bluetooth taraması Konum servisi kapalıyken sessizce başarısız olabilir (`startDiscovery` false döner) — native taraf görünür hata döndürür.
- Log yakalama: flutter-mcp-toolkit (fmtk) `print()`'i yakalamaz → loglar `debugPrint` ile verilir.

## Wi‑Fi Direct (kritik notlar)

Detaylı P2P teşhis sırası ve OEM davranışları için `android-wifi-direct-p2p` skill'i kullanılır. En sık ısıranlar:

- `NEARBY_WIFI_DEVICES` (API 33+) yoksa `discoverPeers` SecurityException yerine opak `ERROR (0)` döner — izin + Konum toggle'ı pre-flight kontrol edilir.
- Tek seferlik `discoverPeers` yetmez: MIUI'de `PEERS_CHANGED` fırlamaz → tarama boyunca periyodik re-arm + `requestPeers` poll gerekir.
- Hedef cihaz taramadayken gelen negotiation OEM build'lerde bloklanır → connected gelince `stopPeerDiscovery`.
- İlk connect denemesi `groupOwnerIntent = 15` ile yapılır (0 ile pasif eşin intent'i eşitlenince negotiation sessizce ölür).
- **Bayat `WifiP2pManager.Channel`** ("bir kez bağlanıp bir daha bağlanamama"nın bilinen nedeni): teardown sonrası tüm ops ERROR/BUSY döner → `STATE_CHANGED DISABLED`'da `channelDirty`, connect öncesi `manager.initialize()`.
- Xiaomi gelen P2P isteğini önce sistem davetiyesi (bildirim perdesi) ile sorar — bağlantı testlerinde iki cihazın ekranı da izlenir.

## Durum (snapshot: 2026-10-09)

- Aktif branch `main` (`963da0f` + bu tur commit'i); `origin/main` ile senkron (ahead 0 / behind 0), working tree temiz.
- Son commit'ler: `98301d0` Nearby Connections 3. taşıma + connect-UX hardening → `963da0f` connect kök-neden fix (connecting panel dial'ı `initState`'te başlatıyordu → build-fazı Riverpod assert'i boş catch'te yutuluyor, istek hiç gönderilmiyordu → panel post-frame'de başlatılıyor + hatalar loglanıyor; `scaffoldMessengerKey` GetMaterialApp'e bağlandı; BT tarama canlı liste + 1 dk re-arm; BT/WFD alıcı-red bildirimleri) → **bu tur**: BT chat reconnect kök-neden fix (cross-transport merge'ün adres zehirlemesi → `reboundTo` self-heal + MAC guard + native try/catch), red bildirimleri `ConnectionNotice` kartına geçti (çift snackbar de-dup), chat tarafındaki tüm Get UI API'leri saf Flutter'a çevrildi, chat app bar çöp ikonu tema uyumlu (accent).
- Branch'ler: `migration/riverpod-state` (`6d240d6`) ve `migration/hive-to-drift` (`e7e80b3`) main'e FF edilmiş; `feature/nearby-transport` = `98301d0`; `migration/riverpod-drift-nearby` (`dab6d9a`) **PARK** (dersler `chatblue-stack-migration` skill'inde).
- Cihazda doğrulandı: Nearby connect çalışıyor; BT reconnect fix kullanıcı tarafından doğrulandı ("düzelmiş"), POCO'daki karışmış oturum adresi kendini onardı (DB + ana ekran kontrolde). Bildirim kartı / Get-free dönüşümü / tema düzeltmesi bir sonraki build ile cihazda test edilecek.

## Mimari Özet

```
lib/
  main.dart               → ProviderContainer + UncontrolledProviderScope; Sizer + GetMaterialApp (locale/themeMode provider'lardan), drift açılışı + settings cache, HomeScreen açılır
  config.dart             → appName, appVersion, showDebugLogs
  core/
    models/               → ChatSessionModel, MessageModel (plain data class'lar)
    platform/             → BtPlatformChannel, WdPlatformChannel (Method/Event Channel tanımları)
    services/             → BtClassicService, WifiDirectService, DeviceIdService
    theme/                → AppTheme (light/dark ThemeData, cyan seed + navy canvas)
  data/
    db/                   → tables.dart + app_database.dart (+ generated .g.dart)
    session_repository.dart  → drift CRUD (sessions/messages) + reactive watchSessions()
    settings_repository.dart → cache'li key/value deposu (themeMode/locale/device_id)
  controllers/
    transport_adapter.dart → GetX↔Riverpod köprüsü (Bt/WdTransportAdapter; Rx ChatTransport yüzeyi)
    chat_transport.dart   → chat tarafı için ortak arayüz (connectToPeer, onChatOpened/Closed)
  providers/
    app_providers.dart    → themeMode/locale notifier'ları, navigatorKey/scaffoldMessengerKey, rootProviderContainer
    home_providers.dart   → homeSessionsProvider (drift watchSessions stream), deleteChatSessionProvider
    transport_providers.dart → Bt/WdTransportNotifier (scan/socket/handshake — eski GetX controller'ların Riverpod portu)
  screens/
    chat_screen_controller_base.dart → B/W sohbet mantığının TEK implementasyonu (mesaj, transfer, senkronizasyon, gönderim kuyruğu)
    chat_ui/              → chat_ui.dart: ortak modern sohbet widget kiti (ChatAppBar, Balon, InputBar, SyncBanner, ConnectBar, Preview) — ChatPalette ile tema-duyarlı
    homescreen/           → HomeScreen (bottom nav: Chats/Settings; Riverpod Consumer)
    settings/             → SettingsScreen (tema seçimi + hakkında)
    b_chatscreen/         → BChatScreen + BChatScreenController (BT sohbet)
    w_chatscreen/         → WChatScreen + WChatScreenController (WFD sohbet)
    bluetooth_scan_screen.dart
    wifid_scan_screen.dart
test/                     → model/TransferState + drift repo/şema + Riverpod provider/i18n unit testleri (flutter test ile çalışır)

android/app/src/main/kotlin/com/sondermium/chatblue/
  MainActivity.kt                  → kanal kurulumu, handler yönlendirme, runtime istekleri
  BluetoothClassicManager.kt       → RFCOMM server/client, discovery, transfer (accept döngüsü kalıcı — yeniden bağlantı)
  WifiDirectManager.kt             → P2P group/peer, framed TCP I/O, transfer (server döngüsü kalıcı)
```

**Platform kanalları:**
- BT: `com.sondermium.chatblue/bt` (method), `/scan` + `/socket` (event)
- WFD: `com.sondermium.chatblue/wd` (method), `/wd_scan` + `/wd_socket` (event)

**Veri akışı:** `Manager (Kotlin) → PlatformChannel → Service (callback/stream) → Transport notifier (Riverpod) → transport_adapter (GetX köprüsü) → Chat controller (GetX reactive) → Screen`.

**Not:** B/W sohbet ekranları `ChatScreenControllerBase`'i paylaşır; taşıma farkları `ChatTransport` arayüzü ile soyutlanır. Unit testler `flutter test` ile koşulur (yalnızca kullanıcı isterse çalıştırılır).