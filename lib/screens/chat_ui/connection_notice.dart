// Styled, auto-dismissing in-app notice card — pure Flutter, no GetX.
//
// Used for connection-decline feedback (both sides of a request, all
// transports) instead of plain snackbars: the card mirrors the design of
// the connection-request banner (glass surface, icon avatar, soft shadow).
// Positioned at the TOP under the chat app bar when a chat screen is
// visible, at the BOTTOM elsewhere — the same convention as the request
// banner. Auto-dismisses after [duration]; tapping dismisses early.
//
// Rendered through the root navigator's Overlay taken from `navigatorKey`
// (app_providers), so transport notifiers can raise it without a
// BuildContext — and it no-ops safely when no UI is mounted (tests, cold
// start).

import 'dart:async';

import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:flutter/material.dart';

class ConnectionNotice {
  ConnectionNotice._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// Shows the notice card. A previously shown notice is replaced.
  static void show({
    required String title,
    required String message,
    bool isChatScreen = false,
    Duration duration = const Duration(seconds: 4),
  }) {
    dismiss();
    // Overlay must be taken from the ROOT navigator state itself (same as
    // ConnectionRequestBanner): the app root context does not sit under an
    // Overlay. Null when no UI is mounted — fail silently.
    final ctx = navigatorKey.currentContext;
    final overlay = navigatorKey.currentState?.overlay;
    if (ctx == null || overlay == null) return;

    final p = ChatPalette.of(ctx);
    final topInset = MediaQuery.paddingOf(ctx).top;
    final bottomInset = MediaQuery.paddingOf(ctx).bottom;

    _entry = OverlayEntry(
      builder: (_) => Positioned(
        // Chat screen: under the app bar; anywhere else: above the bottom.
        top: isChatScreen ? topInset + 74 : null,
        bottom: isChatScreen ? null : bottomInset + 14,
        left: 12,
        right: 12,
        child: _ConnectionNoticeCard(
          palette: p,
          title: title,
          message: message,
          onDismiss: dismiss,
        ),
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(duration, dismiss);
  }

  /// Dismisses the notice and cancels its timer. Safe to call repeatedly:
  /// a second removal attempt is swallowed.
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      try {
        entry.remove();
      } catch (_) {
        // Already removed — nothing left to do.
      }
    }
  }
}

class _ConnectionNoticeCard extends StatelessWidget {
  const _ConnectionNoticeCard({
    required this.palette,
    required this.title,
    required this.message,
    required this.onDismiss,
  });

  final ChatPalette palette;
  final String title;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      behavior: HitTestBehavior.opaque,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (_, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 12),
            child: child,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
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
                // Icon avatar (declined link) — the request card's avatar
                // geometry, red-tinted for the declined state.
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.redAccent.withValues(alpha: 0.14),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.link_off,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(fontSize: 11, color: palette.muted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: palette.messageText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
