// In-app incoming connection request notification.
//
// Shown on the receiving device when a peer connects: as an overlay card
// positioned at the TOP when the chat screen is visible, otherwise at the
// BOTTOM. Auto-declines after a timeout.

import 'dart:async';

import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Overlay-based connection request banner.
class ConnectionRequestBanner {
  ConnectionRequestBanner._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// Shows the request card. [onAccept] fires on Accept (or auto-accept
  /// never — only manual), [onDecline] on a manual Decline tap, and
  /// [onTimeout] (falling back to [onDecline]) on timeout expiry.
  /// [liveName], when provided, is a listenable that updates the banner
  /// title in place (used when the peer's device name arrives over the
  /// socket right after the request — WFD peers carry no name pre-accept).
  /// [isChatScreen] positions the card (top over a chat screen, bottom
  /// elsewhere); callers pass their transport's chat-open flag — the old
  /// ModalRoute.of(overlay.context) detection is always null (the overlay
  /// sits above every route scope).
  static void show({
    required String deviceName,
    ValueListenable<String>? liveName,
    required VoidCallback onAccept,
    required VoidCallback onDecline,
    bool isChatScreen = false,
    VoidCallback? onTimeout,
    Duration timeout = const Duration(seconds: 15),
  }) {
    _insert(
      deviceName: deviceName,
      liveName: liveName,
      isChatScreen: isChatScreen,
      onAccept: onAccept,
      onDecline: onDecline,
    );
    // Auto-decline if the user does not answer in time. [onTimeout] (when
    // given) runs instead of [onDecline] so the expiry path can stay silent
    // while a manual decline still notifies.
    _timer = Timer(timeout, () {
      dismiss();
      (onTimeout ?? onDecline)();
    });
  }

  static void _insert({
    required String deviceName,
    ValueListenable<String>? liveName,
    required bool isChatScreen,
    required VoidCallback onAccept,
    required VoidCallback onDecline,
  }) {
    dismiss();
    // Overlay must be taken from the ROOT NAVIGATOR state itself:
    // neither the MaterialApp root context nor the NavigatorState context
    // sits UNDER an Overlay — both throw "No Overlay widget found" when
    // used with Overlay.of().
    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      onDecline();
      return;
    }
    final p = ChatPalette.of(ctx);
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) {
      onDecline();
      return;
    }
    final topInset = MediaQuery.paddingOf(ctx).top;
    final bottomInset = MediaQuery.paddingOf(ctx).bottom;
    final l10n = AppLocalizations.of(ctx)!;

    _entry = OverlayEntry(
      builder: (_) => Positioned(
        // Chat screen: under the app bar; anywhere else: above the bottom.
        top: isChatScreen ? topInset + 74 : null,
        bottom: isChatScreen ? null : bottomInset + 14,
        left: 12,
        right: 12,
        child: _ConnectionRequestCard(
          palette: p,
          l10n: l10n,
          deviceName: deviceName,
          liveName: liveName,
          onAccept: () {
            dismiss();
            onAccept();
          },
          onDecline: () {
            dismiss();
            onDecline();
          },
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  /// Dismisses the banner and cancels the auto-decline timer. Safe to call
  /// multiple times: the entry reference is cleared before removal, and a
  /// second removal attempt (e.g. raced with the timeout) is swallowed.
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      try {
        entry.remove();
      } catch (_) {
        // Already removed — either by an earlier dismiss or by the overlay
        // being torn down; nothing left to do.
      }
    }
  }
}

class _ConnectionRequestCard extends StatelessWidget {
  const _ConnectionRequestCard({
    required this.palette,
    required this.l10n,
    required this.deviceName,
    this.liveName,
    required this.onAccept,
    required this.onDecline,
  });

  final ChatPalette palette;
  final AppLocalizations l10n;
  final String deviceName;

  /// Optional listenable that live-updates the title (peer name arrives
  /// over the socket while the banner is up).
  final ValueListenable<String>? liveName;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            // Device avatar.
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: palette.sentGradient),
                border: Border.all(
                  color: palette.accent.withValues(alpha: 0.55),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: liveName == null
                    ? _AvatarLetter(
                        name: deviceName,
                        fallback: '?',
                      )
                    : ValueListenableBuilder<String>(
                        valueListenable: liveName!,
                        builder: (_, n, _) =>
                            _AvatarLetter(name: n, fallback: '?'),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.connectionRequestTitle,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
                  const SizedBox(height: 2),
                  liveName == null
                      ? Text(
                          deviceName.trim().isEmpty
                              ? l10n.unknownDevice
                              : deviceName.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: palette.messageText,
                          ),
                        )
                      : ValueListenableBuilder<String>(
                          valueListenable: liveName!,
                          builder: (_, n, _) => Text(
                            n.trim().isEmpty ? l10n.unknownDevice : n.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: palette.messageText,
                            ),
                          ),
                        ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Decline.
            GestureDetector(
              onTap: onDecline,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.redAccent.withValues(alpha: 0.14),
                  border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.5),
                  ),
                ),
                child: const Icon(Icons.close, color: Colors.redAccent, size: 20),
              ),
            ),
            const SizedBox(width: 8),
            // Accept.
            GestureDetector(
              onTap: onAccept,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 46,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(colors: palette.sentGradient),
                  boxShadow: [
                    BoxShadow(
                      color: palette.sentGlow,
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First letter of [name] (uppercased), or [fallback] when empty.
class _AvatarLetter extends StatelessWidget {
  const _AvatarLetter({required this.name, required this.fallback});

  final String name;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    return Text(
      trimmed.isEmpty ? fallback : trimmed[0].toUpperCase(),
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    );
  }
}