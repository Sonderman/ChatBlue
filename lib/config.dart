import 'package:flutter/foundation.dart';

const appName = 'ChatBlue';

/// Fallback label for the About screen when the installed package info is
/// unavailable (tests / headless sessions). The real installed version —
/// kept in sync with pubspec `version:` — is read at runtime via
/// `packageInfoProvider` (package_info_plus), so the displayed version
/// always matches the build on the device.
const appVersion = '1.0.1';

/// Data-plane protocol version (frame envelope + history-sync packets).
/// Bump on ANY wire-format change: the sync manifest carries it and both
/// sides log the peer's version, so two phones running different builds can
/// be identified as incompatible from the logs in one line.
const syncProtocolVersion = 3;

// Debug builds log init failures so device issues are diagnosable;
// release builds stay silent.
const showDebugLogs = kDebugMode;
