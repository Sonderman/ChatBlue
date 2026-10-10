# AGENTS.md — ChatBlue

ChatBlue: Flutter P2P mesajlaşma uygulaması; state katmanı tamamen Riverpod (app state + transport notifier'ları + chat controller), GetX bağımlılığı tamamen kaldırıldı; çevirilerin tek kaynağı gen-l10n. Üç taşıma kanalı vardır: **Bluetooth Classic (RFCOMM)**, **Wi‑Fi Direct (TCP socket)** ve **Nearby Connections**. Üçü de Android'de native Kotlin (Platform Channels) ile uygulanmıştır.

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
- UI dili: **İngilizce varsayılan + Türkçe seçeneği** (Settings → Language; ilk açılışta cihaz dili Türkçe ise Türkçe başlar; tüm çeviriler gen-l10n tek kaynağından tüketilir (`lib/l10n`, `AppLocalizations`; `.tr` sistemi kaldırıldı).
- Göreve başlamadan önce `project_overview.md` oku; önemli değişikliklerden sonra onu güncelle (architecture / directory / recent-changes bölümleri).
- Commit istendiğinde: tek commit, mesaj tüm değişiklikleri kapsar, commit öncesi `project_overview.md` güncellenir. Mesajlar **İngilizce** ve Conventional Commits formatındadır: `feat:`/`fix:` başlığı + neden odaklı, alan alan bölümlenmiş gövde; sonuna `project_overview.md updated.` satırı eklenir; uzun mesaj scratch dosyaya yazılıp `git commit -F <dosya>` ile verilir.
- Kod: mevcut stile ve katman düzenine (services → transport notifier'ları → chat controller → screens) uy; mevcut özellikleri bozmadan değişiklik yap.

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
- WFD taraması Konum kapalıyken opak `ERROR (0)` ile düşer → tarama öncesi pre-flight: ekran "Konum'u Aç" paneline geçer (native `startDiscovery` de location kontrol eder); buton `ACTION_LOCATION_SOURCE_SETTINGS` açar + 15 sn poll, resume'da yeniden okunur.

## Durum (snapshot: 2026-10-10)

- **GetX sökümü tamamlandı, commit'lendi ve main'e FF edildi** (tek commit; `origin/main`'ın 2 önünde — push atılmadı). Branch `migration/getx-removal` korunuyor.
- `lib/` GetX'siz (import/API/`.tr` = 0; `test/no_getx_test.dart` guard'ı), pubspec + lock'ta `get` yok, host `MaterialApp`; chat `ChatController` (Riverpod family+autoDispose) + `ChatTransportBinding`; silinenler: `app_translations.dart` / `transport_adapter.dart` / `chat_transport.dart` / `chat_screen_controller_base.dart` / b-w-n chatscreen controller'ları.
- Whole-branch review düzeltmeleri dahil (race ×3 + finalize persist + clear invariant; 6 regresyon testi) — suite **85/85**, analyze 0.
- Cihaz geri bildirimleri işlendi: WFD location pre-flight + "Konum'u Aç" paneli; Nearby dialer red çift-yüzeyi → tek sahip; **tüm bildirimler tek tip `ConnectionNotice` kartına dönüştü** (17 çağrı noktası; `showSnackBar` = 0; ikon/renk türe göre).
- **Cihaz turu (2026-10-10 sabah) bulguları + düzeltmeleri (commit'lenmedi):** POCO logcat kanıtı: Nearby discovery `8034: MISSING_PERMISSION_ACCESS_COARSE_LOCATION` ile düşüyordu — A13 runtime listesi location iznini hiç istemiyordu (kullanıcı elle verince düzeliyordu). Fix: nearby izin listesine her API dalında FINE+COARSE (A12+ kuralı: FINE ancak COARSE ile birlikte istenirse verilir; GMS coğrafi konumu tam COARSE üzerinden kontrol eder), WFD/BT listelerine COARSE; Nearby scan ekranına **izin paneli** ("İzin Ver" + "Ayarları Aç" → yeni native `openAppSettings`) + **konum paneli** ("Konum'u Aç" → `requestEnableLocation`) + Wi‑Fi kapalı bilgi notu; `getNearbyStatus` → `locationPermission`/`locationEnabled`/`wifiEnabled`; `startScan`/`connectToSessionPeer` pre-flight; scan hatası 8034 → anlaşılır localized mesaj; mount+resume refresh. **Session title = display name**: ortak native `DeviceNameResolver` (device_name → bluetooth_name → adapter → `Build.MODEL` son çare; WFD kanalına da `getDeviceName` eklendi — WFD identity frame'i `DeviceInfo.model` gönderdiği için karşı tarafın session'ı model koda rename ediliyordu); `ChatSessionModel.isRawModelCode`/`shouldReplaceDisplayName` + `reboundTo` isim tazeleme → eski model-kod title'ları **reconnect'te kendiliğinden düzelir** (silme gerekmez), display name asla model koda düşürülmez; `identityChanged` isim değişimini de persist eder. Kullanıcı sil-yeniden bağlan ile yeni oturumda doğru ismi doğruladı. **Nearby BT-aç butonu fix'i:** consent pref'i + targetSdk 36 → 13+'ta `BluetoothAdapter.enable()` belgelenmiş no-op (her zaman false) → buton hiçbir şey yapmıyordu (Dart `false` görüp UI'sız çıkıyordu); artık 13+'ta jest akışı doğrudan sistem dialog'unu (`ACTION_REQUEST_ENABLE`) açar, <13'te sessiz enable + 500 ms poll, sessiz deneme tutmazsa dialog'a düşer; Dart sonucu işleyip status'u poll'lar (panel kendiliğinden kapanır). **WFD wifi-aç butonu takılması fix'i:** sistem panelinden işlem yapmadan dönünce buton 15 sn'lik poll penceresi boyunca disable kalıyordu → enable akışları (wifi+konum) generation-guard'lı; ekran mount+resume'da yeni `onAppResumed()` çağırır (bekleyen akışı bırakır + iki radyoyu tazeler); Nearby konum akışına da aynısı uygulandı. analyze 0; suite **96/96** (+11).
- Kalan: yeni build'in cihaz testi (Nearby izin/konum panelleri + 8034 akışı; WFD title'ın display name'e geçişi; varsa eski kayıtların reconnect'te heal'i) → istenirse push.
- **Sürümleme altyapısı uygulandı:** pubspec `1.0.1+3` (SemVer + monoton versionCode; bump her turun commit'ine dahil edilir), About artık kurulu APK'nın gerçek sürümünü gösterir (`packageInfoProvider` + `package_info_plus` → "Version 1.0.1 (build 3)"; `config.appVersion` yalnızca headless fallback), `syncProtocolVersion` (v1) sync manifest'inde `pv` alanı + "Sync protocol: peer vX, local vX" logu (alan yoksa v1; identity frame'e dokunulmadı). **Tag kuralı: yalnızca cihazda doğrulanmış commit'e annotated tag** — `v1.0.1` doğrulama sonrası atılacak. analyze 0; suite **97/97**.
- Branch'ler: `migration/riverpod-state` (`6d240d6`) ve `migration/hive-to-drift` (`e7e80b3`) main'e FF edilmiş; `feature/nearby-transport` = `98301d0`; `migration/riverpod-drift-nearby` (`dab6d9a`) **PARK** (dersler `chatblue-stack-migration` skill'inde); `migration/getx-removal` = bu commit.
- Cihazda doğrulanmış (önceki turlar): Nearby connect; BT reconnect fix ("düzelmiş"); POCO'daki karışık adres self-heal. Bekleyen cihaz testi: bu commit'in build'i.

## Mimari Özet

```
lib/
  main.dart               → ProviderContainer + UncontrolledProviderScope; Sizer + MaterialApp (locale/themeMode provider'lardan), drift açılışı + settings cache, HomeScreen açılır
  config.dart             → appName, appVersion, showDebugLogs
  core/
    models/               → ChatSessionModel, MessageModel (plain data class'lar)
    platform/             → Bt/Wd/NearbyPlatformChannel (Method/Event Channel tanımları)
    services/             → BtClassicService, WifiDirectService, NearbyService, DeviceIdService
    theme/                → AppTheme (light/dark ThemeData, cyan seed + navy canvas)
  l10n/                   → app_en.arb + app_tr.arb + generated app_localizations*.dart (tek çeviri kaynağı)
  data/
    db/                   → tables.dart + app_database.dart (+ generated .g.dart)
    session_repository.dart  → drift CRUD (sessions/messages) + reactive watchSessions()
    settings_repository.dart → cache'li key/value deposu (themeMode/locale/device_id)
  controllers/
    chat_transport_binding.dart → chat ↔ transport bağlama katmanı (chatBindingProvider; typed listener fan-out + metot delegasyonu)
  providers/
    app_providers.dart    → themeMode/locale notifier'ları, navigatorKey/scaffoldMessengerKey, appLocalizationsProvider
    home_providers.dart   → homeSessionsProvider (drift watchSessions stream), deleteChatSessionProvider
    transport_providers.dart → Bt/WdTransportNotifier (scan/socket/handshake)
    nearby_transport_providers.dart → NearbyTransportNotifier
    chat_controller.dart  → ChatController + chatControllerProvider (family+autoDispose) — sohbet mantığının TEK implementasyonu (mesaj, transfer, senkronizasyon, gönderim kuyruğu)
  screens/
    chat_ui/              → chat_ui.dart: ortak modern sohbet widget kiti (ChatAppBar, Balon, InputBar, SyncBanner, ConnectBar, Preview; connecting_panel, connection_notice, connection_request) — ChatPalette ile tema-duyarlı
    homescreen/           → HomeScreen (bottom nav: Chats/Settings; Riverpod Consumer)
    settings/             → SettingsScreen (tema seçimi + hakkında)
    b_chatscreen/         → BChatScreen (BT sohbet; ConsumerStatefulWidget)
    w_chatscreen/         → WChatScreen (WFD sohbet)
    n_chatscreen/         → NChatScreen (Nearby sohbet)
    bluetooth_scan_screen.dart
    wifid_scan_screen.dart
    nearby_scan_screen.dart
test/                     → model/TransferState + drift repo/şema + Riverpod provider/chat/binding/i18n + no-getx guard testleri (flutter test ile çalışır)

android/app/src/main/kotlin/com/sondermium/chatblue/
  MainActivity.kt                  → kanal kurulumu, handler yönlendirme, runtime istekleri
  BluetoothClassicManager.kt       → RFCOMM server/client, discovery, transfer (accept döngüsü kalıcı — yeniden bağlantı)
  WifiDirectManager.kt             → P2P group/peer, framed TCP I/O, transfer (server döngüsü kalıcı)
  NearbyManager.kt                 → Nearby Connections advertise+discover, BYTES framing, accept lifecycle
```

**Platform kanalları:**
- BT: `com.sondermium.chatblue/bt` (method), `/scan` + `/socket` (event)
- WFD: `com.sondermium.chatblue/wd` (method), `/wd_scan` + `/wd_socket` (event)
- Nearby: `com.sondermium.chatblue/nearby` (method), `/nearby_scan` + `/nearby_socket` (event)

**Veri akışı:** `Manager (Kotlin) → PlatformChannel → Service (callback/stream) → Transport notifier (Riverpod) → ChatTransportBinding → ChatController (Riverpod) → Screen`.

**Not:** B/W/N sohbet ekranları `ChatController`'ı paylaşır; taşıma farkları `ChatTransportBinding` ile soyutlanır. Unit testler `flutter test` ile koşulur (yalnızca kullanıcı isterse çalıştırılır).