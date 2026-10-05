import 'package:get/get.dart';

/// App-wide UI strings for the supported locales (English / Turkish).
///
/// Strings are consumed with GetX's `.tr` (plain), `.trParams` (with
/// placeholders) and `.trPlural` extensions. English is the base locale
/// (fallbackLocale in main.dart); Turkish is the secondary one.
class AppTranslations extends Translations {
  @override
  Map<String, Map<String, String>> get keys => {
        'en_US': _en,
        'tr_TR': _tr,
      };

  static const Map<String, String> _en = {
    // Home
    'settingsTab': 'Settings',
    'chatsTab': 'Chats',
    'bluetoothTab': 'Bluetooth',
    'wifiTab': 'Wi-Fi',
    'noChatsYet': 'No chats yet',
    'noChatsHint': 'Tap Bluetooth below to find a device to chat with',
    'deleteChatTitle': 'Delete "@name"',
    'deleteChatMessage': 'Are you sure you want to delete this chat session?',
    'cancel': 'Cancel',
    'delete': 'Delete',

    // Settings
    'appearanceSection': 'Appearance',
    'themeLabel': 'Theme',
    'themeSystem': 'System',
    'themeLight': 'Light',
    'themeDark': 'Dark',
    'themeSystemHint': 'Follows the device setting when System is selected.',
    'languageLabel': 'Language',
    'languageEnglish': 'English',
    'languageTurkish': 'Turkish',
    'languageHint': 'The app language changes immediately.',
    'aboutSection': 'About',
    'versionLabel': 'Version @version',

    // Scan screens
    'discoverConnectTitle': 'Discover & Connect',
    'discoverConnectWifiTitle': 'Discover & Connect via Wifi',
    'makeDiscoverable': 'Make Discoverable',
    'stopDiscoverable': 'Stop Discoverable',
    'scanForDevices': 'Scan for Devices',
    'stopScanning': 'Stop Scanning',
    'nearbyDevices': 'Nearby Devices (@count)',
    'pairedDevices': 'Paired Devices (@count)',
    'scanningForDevices': 'Scanning for Devices',
    'unknownDevice': 'Unknown',
    'previouslyConnected': 'Previously connected',
    'couldNotConnectTitle': 'Could not connect!',
    'couldNotConnectMessage':
        'Make sure the other device is discoverable and in range.',
    'waitingAcceptanceTitle': 'Waiting for acceptance',
    'waitingAcceptanceMessage':
        'The request was sent. The other device has not answered yet.',
    'connectionError': 'Connection Error',
    'connectErrorDetail': 'Could not connect to device: @error',
    'startServer': 'Start Server',
    'stopServer': 'Stop Server',
    'startDiscovery': 'Start Discovery',
    'stopDiscovery': 'Stop Discovery',
    'wifiOffTitle': 'Wi‑Fi is off. Turn it on to discover nearby devices.',
    'enableWifi': 'Turn on Wi‑Fi',
    'wfdNoDevicesFound':
        'No Wi‑Fi Direct devices found nearby — check that Wi‑Fi is on '
        'and the other device is in range.',
    'wfdTargetNotFound':
        'Target device not found (@count nearby device(s) seen) — check '
        'that the other device has the app open.',
    'wfdPickDeviceTitle': 'Select the other device',
    'wfdPickDeviceHint':
        'The target could not be identified automatically — pick the '
        'other device from the discovered list.',

    // Chat UI
    'connectedStatus': 'Connected',
    'notConnectedStatus': 'Not Connected',
    'clearChatTooltip': 'Clear Chat',
    'clearConversationTitle': 'Clear conversation',
    'clearConversationMessage': 'Are you sure you want to clear all messages?',
    'clearAction': 'Clear',
    'copyAction': 'Copy',
    'deleteMessageTitle': 'Delete this message?',
    'deleteMessageBody': 'This removes the message from this device.',
    'transferInProgressTitle': 'Transfer in progress',
    'transferInProgressMessage':
        'An image transfer is still running. Leaving now will close '
        'the connection and cancel it.',
    'stayAction': 'Stay',
    'leaveAction': 'Leave',
    'syncingHistory': 'Syncing history…',
    'sendingLabel': 'Sending',
    'receivingLabel': 'Receiving',
    'sendImageTooltip': 'Send image',
    'typeMessageHint': 'Type a message',
    'recordingLabel': 'Recording @time',
    'notConnectedBar': 'Not connected',
    'connectAction': 'Connect',
    'saveToGalleryTooltip': 'Save to Gallery',
    'permissionRequiredMessage': 'Permission is required to save images.',
    'photosPermissionRequiredMessage':
        'Photos permission is required to save images.',
    'savedToGallery': 'Saved to gallery',
    'saveFailed': 'Save failed',
    'connectionRequestTitle': 'Connection request',
    'gallerySource': 'Gallery',
    'cameraSource': 'Camera',
    'imageCaption': '[Image] (@size bytes)',
    'imageSendFailed': '[Failed to send image]',

    // Chat controller
    'cannotConnectTitle': 'Cannot connect',
    'noDeviceAddressMessage': 'No device address stored for this chat.',
    'disconnectedTitle': 'Disconnected',
    'peerClosedConnectionMessage': 'Other device closed the connection',
    'micPermissionTitle': 'Microphone permission',
    'recordingUnavailableMessage': 'Recording is not available.',
    'recordingErrorTitle': 'Recording error',
    'recordingStartFailedMessage': 'Could not start recording.',

    // Transport controllers
    'scanErrorTitle': 'Scan error',
    'connectionDeclinedTitle': 'Connection declined',
    'connectionDeclinedMessage':
        'The peer declined the request or the link was lost.',
  };

  static const Map<String, String> _tr = {
    // Home
    'settingsTab': 'Ayarlar',
    'chatsTab': 'Sohbetler',
    'bluetoothTab': 'Bluetooth',
    'wifiTab': 'Wi-Fi',
    'noChatsYet': 'Henüz sohbet yok',
    'noChatsHint': 'Sohbet edecek bir cihaz bulmak için alttaki Bluetooth sekmesine dokun',
    'deleteChatTitle': '"@name" silinsin mi?',
    'deleteChatMessage': 'Bu sohbeti silmek istediğine emin misin?',
    'cancel': 'İptal',
    'delete': 'Sil',

    // Settings
    'appearanceSection': 'Görünüm',
    'themeLabel': 'Tema',
    'themeSystem': 'Sistem',
    'themeLight': 'Açık',
    'themeDark': 'Koyu',
    'themeSystemHint': 'Sistem seçiliyken cihaz ayarını takip eder.',
    'languageLabel': 'Dil',
    'languageEnglish': 'İngilizce',
    'languageTurkish': 'Türkçe',
    'languageHint': 'Uygulama dili anında değişir.',
    'aboutSection': 'Hakkında',
    'versionLabel': 'Sürüm @version',

    // Scan screens
    'discoverConnectTitle': 'Keşfet ve Bağlan',
    'discoverConnectWifiTitle': 'Wi-Fi ile Keşfet ve Bağlan',
    'makeDiscoverable': 'Görünür Yap',
    'stopDiscoverable': 'Görünürlüğü Kapat',
    'scanForDevices': 'Cihazları Tara',
    'stopScanning': 'Taramayı Durdur',
    'nearbyDevices': 'Yakındaki Cihazlar (@count)',
    'pairedDevices': 'Eşleşmiş Cihazlar (@count)',
    'scanningForDevices': 'Cihazlar taranıyor',
    'unknownDevice': 'Bilinmiyor',
    'previouslyConnected': 'Daha önce bağlanıldı',
    'couldNotConnectTitle': 'Bağlanılamadı!',
    'couldNotConnectMessage':
        'Diğer cihazın keşfedilebilir ve yakın mesafede olduğundan emin ol.',
    'waitingAcceptanceTitle': 'Onay bekleniyor',
    'waitingAcceptanceMessage':
        'İstek gönderildi. Karşı cihaz henüz yanıt vermedi.',
    'connectionError': 'Bağlantı Hatası',
    'connectErrorDetail': 'Cihaza bağlanılamadı: @error',
    'startServer': 'Sunucuyu Başlat',
    'stopServer': 'Sunucuyu Durdur',
    'startDiscovery': 'Keşfi Başlat',
    'stopDiscovery': 'Keşfi Durdur',
    'wifiOffTitle': 'Wi‑Fi kapalı. Yakındaki cihazları bulmak için Wi‑Fi\'yi açın.',
    'enableWifi': 'Wi‑Fi\'yi Aç',

    'wfdNoDevicesFound':
        'Yakında Wi‑Fi Direct cihazı bulunamadı — Wi‑Fi açık ve diğer '
        'cihaz yakında mı?',
    'wfdTargetNotFound':
        'Hedef cihaz bulunamadı (yakında @count cihaz görüldü) — diğer '
        'cihazda uygulama açık mı?',
    'wfdPickDeviceTitle': 'Diğer cihazı seç',
    'wfdPickDeviceHint':
        'Hedef cihaz otomatik tanınamadı — keşfedilen listeden diğer '
        'cihazı seç.',

    // Chat UI
    'connectedStatus': 'Bağlı',
    'notConnectedStatus': 'Bağlı Değil',
    'clearChatTooltip': 'Sohbeti Temizle',
    'clearConversationTitle': 'Sohbeti temizle',
    'clearConversationMessage': 'Tüm mesajları temizlemek istediğine emin misin?',
    'clearAction': 'Temizle',
    'copyAction': 'Kopyala',
    'deleteMessageTitle': 'Bu mesaj silinsin mi?',
    'deleteMessageBody': 'Bu mesaj bu cihazdan kaldırılır.',
    'transferInProgressTitle': 'Aktarım sürüyor',
    'transferInProgressMessage':
        'Görsel aktarımı hâlâ sürüyor. Şimdi ayrılırsan bağlantı '
        'kapanır ve aktarım iptal edilir.',
    'stayAction': 'Kal',
    'leaveAction': 'Ayrıl',
    'syncingHistory': 'Geçmiş senkronize ediliyor…',
    'sendingLabel': 'Gönderiliyor',
    'receivingLabel': 'Alınıyor',
    'sendImageTooltip': 'Görsel gönder',
    'typeMessageHint': 'Mesaj yaz',
    'recordingLabel': 'Kayıt @time',
    'notConnectedBar': 'Bağlı değil',
    'connectAction': 'Bağlan',
    'saveToGalleryTooltip': 'Galeriye Kaydet',
    'permissionRequiredMessage': 'Görselleri kaydetmek için izin gerekli.',
    'photosPermissionRequiredMessage':
        'Görselleri kaydetmek için fotoğraf izni gerekli.',
    'savedToGallery': 'Galeriye kaydedildi',
    'saveFailed': 'Kaydetme başarısız',
    'connectionRequestTitle': 'Bağlantı isteği',
    'gallerySource': 'Galeri',
    'cameraSource': 'Kamera',
    'imageCaption': '[Görsel] (@size bytes)',
    'imageSendFailed': '[Görsel gönderilemedi]',

    // Chat controller
    'cannotConnectTitle': 'Bağlanılamıyor',
    'noDeviceAddressMessage': 'Bu sohbet için kayıtlı bir cihaz adresi yok.',
    'disconnectedTitle': 'Bağlantı kesildi',
    'peerClosedConnectionMessage': 'Diğer cihaz bağlantıyı kapattı',
    'micPermissionTitle': 'Mikrofon izni',
    'recordingUnavailableMessage': 'Kayıt kullanılamıyor.',
    'recordingErrorTitle': 'Kayıt hatası',
    'recordingStartFailedMessage': 'Kayıt başlatılamadı.',

    // Transport controllers
    'scanErrorTitle': 'Tarama hatası',
    'connectionDeclinedTitle': 'Bağlantı reddedildi',
    'connectionDeclinedMessage':
        'Karşı taraf isteği reddetti veya bağlantı koptu.',
  };
}