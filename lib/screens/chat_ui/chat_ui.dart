// Shared modern chat UI kit for the Bluetooth, Wi‑Fi Direct and Nearby
// Connections chat screens.
//
// Design language: navy/cyan identity with theme-aware palettes — dark mode
// keeps the deep navy canvas, light mode uses a bright variant. All chat
// screens build from these widgets so the transports share one visual
// identity.
//
// State comes in as immutable [ChatState] values (watched by the screens via
// Riverpod); the widgets stay stateless. Playback ticks flow through the
// controller's dedicated [AudioPlaybackState] notifier so position updates
// never rebuild the message list.

import 'dart:async';
import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:chatblue/core/format_utils.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/location_message.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/chat_controller.dart';
import 'package:chatblue/screens/chat_ui/connection_notice.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sizer/sizer.dart';

// ── Palette ─────────────────────────────────────────────────────────────────

/// Theme-aware color set for the chat screens. Pick with [ChatPalette.of].
class ChatPalette {
  const ChatPalette({
    required this.canvasTop,
    required this.canvasBottom,
    required this.bar,
    required this.barForeground,
    required this.surface,
    required this.bubbleIn,
    required this.border,
    required this.muted,
    required this.messageText,
    required this.accent,
    required this.accentDeep,
    required this.sentGlow,
    required this.progressTrack,
  });

  /// Top of the chat canvas gradient.
  final Color canvasTop;

  /// Bottom of the chat canvas gradient.
  final Color canvasBottom;

  /// Glassy header / input bar surface.
  final Color bar;

  /// Text and icons drawn on top of [bar].
  final Color barForeground;

  /// Dialog / input fill surface.
  final Color surface;

  /// Incoming bubble fill (dark glass / white card).
  final Color bubbleIn;

  /// Subtle border on surfaces and bubbles.
  final Color border;

  /// Muted text.
  final Color muted;

  /// Body text of incoming messages.
  final Color messageText;

  /// Primary cyan accent.
  final Color accent;

  /// Deeper blue used as the gradient start.
  final Color accentDeep;

  /// Surrounding glow for own bubbles.
  final Color sentGlow;

  /// Progress bar track.
  final Color progressTrack;

  /// Gradient for own messages (blue → cyan).
  List<Color> get sentGradient => [accentDeep, accent];

  static const ChatPalette dark = ChatPalette(
    canvasTop: Color(0xFF0A1122),
    canvasBottom: Color(0xFF111E3A),
    bar: Color(0xE60A1122),
    barForeground: Colors.white,
    surface: Color(0xFF16233F),
    bubbleIn: Color(0xE816233F),
    border: Color(0x40FFFFFF),
    muted: Color(0xB3FFFFFF),
    messageText: Color(0xFFE8EEFA),
    accent: Color(0xFF00D2FF),
    accentDeep: Color(0xFF2E7CF6),
    sentGlow: Color(0x2E00D2FF),
    progressTrack: Color(0x40FFFFFF),
  );

  static const ChatPalette light = ChatPalette(
    canvasTop: Color(0xFFF4F7FC),
    canvasBottom: Color(0xFFE3ECF9),
    bar: Color(0xF2FFFFFF),
    barForeground: Color(0xFF1A2740),
    surface: Color(0xFFFFFFFF),
    bubbleIn: Color(0xFFFFFFFF),
    border: Color(0x1F0A1122),
    muted: Color(0x8A0A1122),
    messageText: Color(0xFF1A2740),
    accent: Color(0xFF0091C2),
    accentDeep: Color(0xFF2E6BEC),
    sentGlow: Color(0x26007FA8),
    progressTrack: Color(0x1F0A1122),
  );

  static ChatPalette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// Formats a message timestamp as 24-hour HH:mm.
String formatChatTimestamp(DateTime t) {
  final time = TimeOfDay.fromDateTime(t);
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

// ── App bar ────────────────────────────────────────────────────────────────

/// Header with device avatar, live connection status and the clear action.
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({super.key, required this.state, required this.controller});

  final ChatState state;
  final ChatController controller;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final l10n = AppLocalizations.of(context)!;
    // Fallback order matters (BT carries a transport name immediately, WFD
    // only after READY): transport name → peer-reported name → stored name.
    final name =
        controller.connectedDeviceName ?? (state.peerName.isNotEmpty ? state.peerName : state.chatSession.name);
    return AppBar(
      // Status bar icons follow the chat palette, not the app theme: the
      // chat bar stays dark navy on the light theme too.
      systemOverlayStyle: p.barForeground == Colors.white ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      backgroundColor: p.bar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: p.barForeground),
      toolbarHeight: 64,
      titleSpacing: 4,
      title: Row(
        children: [
          _DeviceAvatar(name: name, palette: p),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AutoSizeText(
                  name,
                  maxLines: 1,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: p.barForeground),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StatusDot(connected: state.isConnected, palette: p),
                    const SizedBox(width: 6),
                    Text(
                      state.isConnected ? l10n.connectedStatus : l10n.notConnectedStatus,
                      style: TextStyle(fontSize: 11, color: state.isConnected ? p.accent : Colors.redAccent),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          // Connection-quality strip toggle (hidden by default; the
          // preference persists across restarts).
          icon: Icon(Icons.signal_cellular_alt, color: p.accent),
          tooltip: l10n.connectionPanelTooltip,
          onPressed: controller.toggleLinkPanel,
        ),
        IconButton(
          // Action icons follow the palette accent (like the composer's and
          // the status indicators) — `muted` rendered as a washed-out gray
          // against the crisp bar foreground in both themes and read as
          // disabled / off-theme.
          icon: Icon(Icons.delete_sweep_outlined, color: p.accent),
          tooltip: l10n.clearChatTooltip,
          onPressed: () => showChatClearDialog(context, controller),
        ),
      ],
    );
  }
}

/// Gradient circle avatar with the device name initial.
class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({required this.name, required this.palette});

  final String name;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: palette.sentGradient),
        border: Border.all(color: palette.accent.withValues(alpha: 0.55), width: 1.5),
        boxShadow: [
          BoxShadow(color: palette.accent.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      ),
    );
  }
}

/// Small glowing dot showing the socket state.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected, required this.palette});

  final bool connected;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
    final color = connected ? palette.accent : Colors.redAccent;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6)],
      ),
    );
  }
}

/// Theme-aware confirmation dialog for clearing the conversation.
Future<void> showChatClearDialog(BuildContext context, ChatController controller) async {
  final p = ChatPalette.of(context);
  final l10n = AppLocalizations.of(context)!;
  final clear = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      title: Text(l10n.clearConversationTitle, style: TextStyle(color: p.messageText)),
      content: Text(l10n.clearConversationMessage, style: TextStyle(color: p.muted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel, style: TextStyle(color: p.muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828), foregroundColor: Colors.white),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.clearAction),
        ),
      ],
    ),
  );
  if (clear == true) {
    await controller.clearConversation();
  }
}

/// Theme-aware confirmation dialog for removing one of the user's own
/// messages (local only — the peer's copy is untouched).
Future<void> showDeleteMessageDialog(BuildContext context, ChatController controller, MessageModel message) async {
  final p = ChatPalette.of(context);
  final l10n = AppLocalizations.of(context)!;
  final delete = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      title: Text(l10n.deleteMessageTitle, style: TextStyle(color: p.messageText)),
      content: Text(l10n.deleteMessageBody, style: TextStyle(color: p.muted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel, style: TextStyle(color: p.muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828), foregroundColor: Colors.white),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  if (delete == true) {
    controller.deleteMessage(message.id);
  }
}

/// Long-press actions for a plain text bubble: copy (both directions) and —
/// for own, finished messages — the delete confirm. Deliberately NOT the
/// framework's SelectableText selection toolbar: its follower-layer
/// machinery trips a layout assertion in this Flutter version, and its copy
/// action took the whole message anyway.
Future<void> showMessageActionsDialog(
  BuildContext context,
  ChatController? controller,
  MessageModel message, {
  required bool mine,
}) async {
  final p = ChatPalette.of(context);
  final l10n = AppLocalizations.of(context)!;
  final bool canDelete =
      mine && controller != null && !message.isTransferring;
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      content: Text(
        message.text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.messageText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop('copy'),
          child: Text(l10n.copyAction, style: TextStyle(color: p.accent)),
        ),
        if (canDelete)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop('delete'),
            child: Text(l10n.delete),
          ),
      ],
    ),
  );
  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: message.text));
    // Clear any visible notice card (the old toolbar's copy did the same).
    ConnectionNotice.dismiss();
  } else if (action == 'delete' && controller != null && context.mounted) {
    await showDeleteMessageDialog(context, controller, message);
  }
}

/// Theme-aware dialog shown before leaving mid-transfer.
Future<bool?> showChatTransferDialog(BuildContext context) {
  final p = ChatPalette.of(context);
  final l10n = AppLocalizations.of(context)!;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      title: Text(l10n.transferInProgressTitle, style: TextStyle(color: p.messageText)),
      content: Text(l10n.transferInProgressMessage, style: TextStyle(color: p.muted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.stayAction, style: TextStyle(color: p.accent)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: p.accentDeep, foregroundColor: Colors.white),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.leaveAction),
        ),
      ],
    ),
  );
}

// ── Message list ───────────────────────────────────────────────────────────

/// Thin indicator shown under the app bar while a history sync packet is
/// being received (large text frame progress) or applied (images rehydrated
/// to disk).
class ChatSyncBanner extends StatelessWidget {
  const ChatSyncBanner({super.key, required this.state});

  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final l10n = AppLocalizations.of(context)!;
    if (!state.isSyncing) return const SizedBox.shrink();
    // The app bar floats above the canvas (extendBodyBehindAppBar). The
    // body sits inside a SafeArea that already consumes the status bar
    // inset, so the banner only needs the app bar's 64 px toolbar height
    // to sit flush against its bottom edge.
    return Container(
      // The quality panel above already carries the 66 px app-bar offset
      // when it is visible; without it the banner starts the content.
      margin: EdgeInsets.only(top: state.linkPanelVisible ? 2 : 66, left: 10, right: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: p.bar,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent)),
              const SizedBox(width: 8),
              Text(l10n.syncingHistory, style: TextStyle(fontSize: 11, color: p.muted)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: state.syncProgress,
              minHeight: 2,
              backgroundColor: p.progressTrack,
              valueColor: AlwaysStoppedAnimation<Color>(p.accent),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible connection-quality strip: link type + state, uptime, live
/// traffic counters/rate, the dial-time scan RSSI (Bluetooth) and the GMS
/// bandwidth-quality reading (Nearby). Visibility lives in
/// [ChatState.linkPanelVisible] (the app bar icon toggles it; the
/// preference is persisted); when hidden it renders nothing and its 1 s
/// ticker is stopped.
class ChatLinkPanel extends StatefulWidget {
  const ChatLinkPanel({super.key, required this.state, required this.controller});

  final ChatState state;
  final ChatController controller;

  @override
  State<ChatLinkPanel> createState() => _ChatLinkPanelState();
}

class _ChatLinkPanelState extends State<ChatLinkPanel> {
  Timer? _ticker;
  int _ticks = 0;
  bool _rssiBusy = false;
  int? _liveRssi;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ChatLinkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// The 1 s ticker runs only while the strip is visible: it refreshes the
  /// uptime and rate labels by re-reading the controller, and polls the
  /// live link RSSI every 3 s (best effort — the platform may expose
  /// none, in which case the label falls back to the dial-time value).
  void _syncTicker() {
    final visible = widget.state.linkPanelVisible;
    if (visible && _ticker == null) {
      unawaited(_refreshLiveRssi());
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _ticks++;
        if (_ticks % 3 == 0) unawaited(_refreshLiveRssi());
        setState(() {});
      });
    } else if (!visible && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
      _liveRssi = null;
    }
  }

  Future<void> _refreshLiveRssi() async {
    if (_rssiBusy) return;
    if (!widget.state.isConnected) {
      if (_liveRssi != null && mounted) setState(() => _liveRssi = null);
      return;
    }
    _rssiBusy = true;
    try {
      final value = await widget.controller.fetchLiveRssi();
      if (mounted && value != _liveRssi) setState(() => _liveRssi = value);
    } finally {
      _rssiBusy = false;
    }
  }

  /// GMS bandwidth-quality code → localized word (codes verified against
  /// play-services-nearby 19.5.1: 0 unknown, 1 low, 2 medium, 3 high).
  String _qualityWord(AppLocalizations l10n, int quality) {
    switch (quality) {
      case 3:
        return l10n.linkQualityHigh;
      case 2:
        return l10n.linkQualityMedium;
      case 1:
        return l10n.linkQualityLow;
      default:
        return l10n.linkQualityUnknown;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.state.linkPanelVisible) return const SizedBox.shrink();
    final p = ChatPalette.of(context);
    final l10n = AppLocalizations.of(context)!;
    final controller = widget.controller;
    final connected = widget.state.isConnected;
    final since = controller.connectedSince;
    final uptime = (connected && since != null) ? formatUptime(DateTime.now().difference(since)) : null;
    final stats = controller.linkStats;
    final rate = stats.currentBytesPerSecond();
    final dialRssi = controller.connectedDeviceRssi;
    final peerRssi = controller.peerReportedRssi;
    final liveRssi = _liveRssi;
    // Live value when the platform provides one; otherwise the dial-time
    // scan value (labelled), falling back to the reading the dialing side
    // shared — the accepting side never scanned (no platform API reads a
    // connected RFCOMM link live).
    final String? rssiText = !connected
        ? null
        : liveRssi != null
            ? '${l10n.signalLabel}: $liveRssi dBm'
            : dialRssi != null
                ? '${l10n.signalLabel}: $dialRssi dBm ${l10n.lastScanTag}'
                : peerRssi == null
                    ? null
                    : '${l10n.signalLabel}: $peerRssi dBm ${l10n.peerReadingTag}';
    // Nearby's only official link metric: GMS bandwidth quality — coarse
    // (0 unknown / 1 low / 2 medium / 3 high) and event-driven; the code
    // stays 0 (unknown) until the first change event of the connection
    // arrives.
    final quality = controller.linkQuality;
    final String? qualityText = !connected || quality == null
        ? null
        : '${l10n.linkQualityLabel}: ${_qualityWord(l10n, quality)}';
    final linkLabel = switch (controller.transportKind) {
      'wfd' => l10n.wifiTab,
      'nearby' => l10n.nearbyTab,
      _ => l10n.bluetoothTab,
    };
    return Container(
      // Docked flush under the app bar — no gap: the SafeArea above already
      // consumed the status-bar inset and the bar itself is 64 tall, so
      // the strip's top edge meets the bar's bottom edge exactly (top
      // corners stay square so it reads as attached).
      margin: const EdgeInsets.only(top: 2, left: 10, right: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: p.bar,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        border: Border.all(color: p.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.signal_cellular_alt : Icons.link_off,
                size: 15,
                color: connected ? p.accent : Colors.redAccent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$linkLabel · '
                  '${connected ? l10n.connectedStatus : l10n.notConnectedStatus}'
                  '${uptime == null ? '' : ' · $uptime'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.messageText),
                ),
              ),
              GestureDetector(
                onTap: controller.toggleLinkPanel,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.keyboard_arrow_up, size: 18, color: p.muted),
                ),
              ),
            ],
          ),
          if (connected)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '↑ ${formatFileSize(stats.bytesOut)}  '
                      '↓ ${formatFileSize(stats.bytesIn)}  ·  '
                      '${rate > 0 ? '${formatFileSize(rate.round())}/s' : '—'}'
                      '${rssiText == null ? '' : '  ·  $rssiText'}'
                      '${qualityText == null ? '' : '  ·  $qualityText'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.muted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Reverse chronological message list driving the shared controller state.
class ChatMessageList extends StatelessWidget {
  const ChatMessageList({super.key, required this.state, required this.controller});

  final ChatState state;
  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    // The app bar floats above the canvas (extendBodyBehindAppBar). The
    // body sits inside a SafeArea that already consumes the status bar
    // inset, so the list only needs the app bar's 64 px toolbar height plus
    // a small breathing gap to start below it.
    const topInset = 72.0;
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.fromLTRB(10, topInset, 10, 8),
      itemCount: state.messages.length,
      itemBuilder: (context, index) => ChatMessageBubble(message: state.messages[index], controller: controller),
    );
  }
}

// ── Message bubble ─────────────────────────────────────────────────────────

/// A single message: text, image thumbnail, transfer progress or voice note.
class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({super.key, required this.message, this.controller});

  final MessageModel message;

  /// Optional controller: needed only when the message is a voice note
  /// (playback controls).
  final ChatController? controller;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final l10n = AppLocalizations.of(context)!;
    final bool mine = message.isSentByMe;
    final bool showProgress = message.isTransferring && message.transferKind == 'bytes';
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 4),
      bottomRight: Radius.circular(mine ? 4 : 18),
    );

    final Widget content;
    // True when this bubble renders a plain text message (drives the
    // long-press actions below).
    bool textBubble = false;
    // Location messages are stored as plain text (readable on every build);
    // the rich bubble below is a pure render-time view.
    final DecodedLocation? location =
        (message.imagePath == null && !message.hasRemoteMedia && message.transferKind == null)
        ? parseLocationMessage(message.text)
        : null;
    if (message.hasRemoteMedia) {
      // Deferred media from the history sync: the file still lives on the
      // peer — offer a download placeholder instead of the media.
      content = _downloadBubble(p, mine, l10n);
    } else if (message.isAudio && message.imagePath != null) {
      content = _audioBubble(p, mine);
    } else if (message.isFile && message.imagePath != null) {
      content = _fileBubble(context, p, mine, l10n);
    } else if (message.imagePath != null) {
      content = _imageBubble(context, p, mine, showProgress);
    } else if (showProgress) {
      content = _progressBubble(p, mine, l10n);
    } else if (location != null) {
      content = _locationBubble(p, mine, l10n, location);
    } else {
      textBubble = true;
      content = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Plain Text on purpose: the framework's SelectableText selection
          // toolbar trips a layout assertion in this Flutter version
          // (RenderFollowerLayer vs the OverlayPortal deferred layout), and
          // its copy action took the whole message anyway — long-press
          // opens the themed actions dialog instead (showMessageActionsDialog).
          Text(
            message.text,
            style: TextStyle(height: 1.25, fontSize: 15, color: mine ? Colors.white : p.messageText),
          ),
          const SizedBox(height: 3),
          _MessageMeta(message: message, mine: mine, palette: p),
        ],
      );
    }

    // Long-press: text bubbles get the copy/delete actions dialog (delete
    // only for own messages); other own, finished bubbles ask before
    // deleting. Transfers in flight are excluded — mid-transfer deletions
    // would corrupt the progress-bubble bookkeeping.
    return GestureDetector(
      onLongPress: message.isTransferring
          ? null
          : textBubble
              ? () => showMessageActionsDialog(
                    context,
                    controller,
                    message,
                    mine: mine,
                  )
              : (mine && controller != null)
                  ? () => showDeleteMessageDialog(context, controller!, message)
                  : null,
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: 78.w),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: mine ? LinearGradient(colors: p.sentGradient) : null,
            color: mine ? null : p.bubbleIn,
            borderRadius: radius,
            border: mine ? null : Border.all(color: p.border),
            boxShadow: mine ? [BoxShadow(color: p.sentGlow, blurRadius: 14, offset: const Offset(0, 4))] : null,
          ),
          child: content,
        ),
      ),
    );
  }

  /// Placeholder bubble for media that was NOT auto-downloaded during the
  /// history sync (large files live on the peer): shows the kind and size,
  /// fetches the file on tap and spins while the fetch is in flight.
  Widget _downloadBubble(ChatPalette p, bool mine, AppLocalizations l10n) {
    final bool audio = message.isAudio;
    final bool file = message.isFile;
    final bool busy = message.isTransferring;
    final int size = message.remoteMediaSize ?? 0;
    final Color iconColor = mine ? Colors.white : p.accent;
    return GestureDetector(
      onTap: busy ? null : () => controller?.downloadMedia(message),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                audio ? Icons.mic_none : (file ? Icons.insert_drive_file_outlined : Icons.image_outlined),
                size: 20,
                color: iconColor,
              ),
              const SizedBox(width: 8),
              Text(
                audio ? l10n.audioLabel : (file ? l10n.fileSource : l10n.photoLabel),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mine ? Colors.white : p.messageText),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                  ),
                )
              else
                Icon(Icons.download_rounded, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Text(
                busy ? l10n.downloadingLabel : '${_formatMediaSize(size)} • ${l10n.downloadMediaHint}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: mine ? Colors.white.withValues(alpha: 0.85) : p.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _MessageMeta(message: message, mine: mine, palette: p),
        ],
      ),
    );
  }

  /// Compact human size for the download placeholder ("2.4 MB").
  String _formatMediaSize(int bytes) => formatFileSize(bytes);

  /// Image thumbnail bubble with progress bar while transferring.
  Widget _imageBubble(BuildContext context, ChatPalette p, bool mine, bool showProgress) {
    return GestureDetector(
      onTap: showProgress
          ? null
          : () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => ChatImagePreviewScreen(path: message.imagePath!))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 60.w, maxHeight: 32.h),
              child: Image.file(File(message.imagePath!), fit: BoxFit.cover),
            ),
          ),
          if (showProgress) ...[
            const SizedBox(height: 8),
            _chatProgressBar(
              p,
              value: ((message.transferCurrent ?? 0) / (message.transferTotal ?? 1)).clamp(0, 1).toDouble(),
            ),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 4),
          _MessageMeta(message: message, mine: mine, palette: p),
        ],
      ),
    );
  }

  /// Voice-note bubble: play/pause button, duration caption and a thin
  /// playback progress line. The file path lives in `imagePath` (see the
  /// chat controller). Playback state flows through the controller's
  /// [AudioPlaybackState] notifier — a dedicated listenable so position
  /// ticks don't rebuild the message list.
  Widget _audioBubble(ChatPalette p, bool mine) {
    final c = controller;
    if (c == null) {
      return _audioBubbleBody(const AudioPlaybackState(), p, mine);
    }
    return ValueListenableBuilder<AudioPlaybackState>(
      valueListenable: c.audioPlayback,
      builder: (_, playback, _) => _audioBubbleBody(playback, p, mine),
    );
  }

  Widget _audioBubbleBody(AudioPlaybackState playback, ChatPalette p, bool mine) {
    final isThis = playback.playingId == message.id;
    final playing = isThis && playback.playing;
    final durationMs = playback.durationMs;
    final value = isThis ? (playback.progress * durationMs) : 0.0;
    return Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: controller == null ? null : () => controller!.toggleAudio(message),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: p.sentGradient),
                  border: Border.all(color: mine ? Colors.white.withValues(alpha: 0.45) : p.border),
                ),
                child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 26),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      message.text,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: mine ? Colors.white : p.messageText,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // ±10 s seek buttons.
                    if (controller != null) ...[
                      _AudioSkipButton(
                        icon: Icons.replay_10,
                        color: mine ? Colors.white : p.accent,
                        onTap: () => controller!.skipAudio(const Duration(seconds: -10)),
                      ),
                      const SizedBox(width: 10),
                      _AudioSkipButton(
                        icon: Icons.forward_10,
                        color: mine ? Colors.white : p.accent,
                        onTap: () => controller!.skipAudio(const Duration(seconds: 10)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                // Draggable seek bar (thin slider).
                SizedBox(
                  width: 170,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: mine ? Colors.white : p.accent,
                      inactiveTrackColor: mine ? Colors.white.withValues(alpha: 0.3) : p.progressTrack,
                      thumbColor: mine ? Colors.white : p.accent,
                      overlayColor: (mine ? Colors.white : p.accent).withValues(alpha: 0.15),
                    ),
                    child: Slider(
                      value: value.clamp(0.0, durationMs),
                      max: durationMs > 0 ? durationMs : 1,
                      onChanged: controller == null ? null : (v) => controller!.seekAudio(message, v),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        _MessageMeta(message: message, mine: mine, palette: p),
      ],
    );
  }

  /// File attachment bubble: document icon, name + size and an Open action
  /// (system viewer via the util channel). The path's basename is the
  /// file's real name; a collision copy carries a timestamp prefix.
  Widget _fileBubble(BuildContext context, ChatPalette p, bool mine, AppLocalizations l10n) {
    final path = message.imagePath!;
    final name = path.split(Platform.pathSeparator).last;
    int? size;
    try {
      size = File(path).lengthSync();
    } catch (_) {}
    final fg = mine ? Colors.white : p.messageText;
    return GestureDetector(
      onTap: () => controller?.openReceivedFile(path),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined, size: 26, color: mine ? Colors.white : p.accent),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg),
                    ),
                    Text(
                      '${size == null ? '' : '${formatFileSize(size)} · '}'
                      '${l10n.openAction}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: mine ? Colors.white.withValues(alpha: 0.85) : p.accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.open_in_new, size: 16, color: mine ? Colors.white : p.accent),
            ],
          ),
          const SizedBox(height: 4),
          _MessageMeta(message: message, mine: mine, palette: p),
        ],
      ),
    );
  }

  /// Rich location bubble (see [parseLocationMessage]): coordinates +
  /// accuracy and an Open-in-Maps action. The message text itself stays the
  /// encoded plain text.
  Widget _locationBubble(ChatPalette p, bool mine, AppLocalizations l10n, DecodedLocation location) {
    final fg = mine ? Colors.white : p.messageText;
    final coords = '${location.lat.toStringAsFixed(5)}, ${location.lng.toStringAsFixed(5)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on_outlined, size: 22, color: mine ? Colors.white : p.accent),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  coords,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: fg),
                ),
                if (location.accuracyMeters != null)
                  Text(
                    '±${location.accuracyMeters} m',
                    style: TextStyle(fontSize: 11, color: mine ? Colors.white.withValues(alpha: 0.85) : p.muted),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => controller?.openLocationInMaps(location.lat, location.lng),
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 15, color: mine ? Colors.white : p.accent),
              const SizedBox(width: 5),
              Text(
                l10n.openInMaps,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: mine ? Colors.white : p.accent),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _MessageMeta(message: message, mine: mine, palette: p),
      ],
    );
  }

  /// Bare transfer progress bubble (bubble without a thumbnail yet).
  Widget _progressBubble(ChatPalette p, bool mine, AppLocalizations l10n) {
    final current = message.transferCurrent ?? 0;
    final total = message.transferTotal ?? 0;
    // Never render 100% before the transfer truly completed: rounding
    // turned a stalled 99.7% into a deceptive "100%" that read as done
    // (the stall watchdog resolves such bubbles, but the reading itself
    // must stay honest in the meantime).
    final int pctNum = total == 0 ? 0 : ((current / total) * 100).round();
    final int pct = (current < total && pctNum >= 100) ? 99 : pctNum;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _chatProgressBar(p, value: (current / (total == 0 ? 1 : total)).clamp(0, 1).toDouble()),
        const SizedBox(height: 6),
        Text(
          '${mine ? l10n.sendingLabel : l10n.receivingLabel} '
          '$current/$total bytes ($pct%)',
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 11, color: mine ? Colors.white.withValues(alpha: 0.75) : p.muted),
        ),
      ],
    );
  }

  Widget _chatProgressBar(ChatPalette p, {required double value}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 4,
        backgroundColor: p.progressTrack,
        valueColor: AlwaysStoppedAnimation<Color>(p.accent),
      ),
    );
  }
}

/// One-line meta under a bubble: the timestamp, plus the delivery ticks for
/// outgoing messages (see [_DeliveryTicks]).
class _MessageMeta extends StatelessWidget {
  const _MessageMeta({
    required this.message,
    required this.mine,
    required this.palette,
  });

  final MessageModel message;
  final bool mine;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatChatTimestamp(message.timestamp),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: mine ? Colors.white.withValues(alpha: 0.75) : palette.muted,
          ),
        ),
        // Ticks on outgoing messages only (the standard convention — a
        // received message's arrival is self-evident); progress bubbles
        // are excluded while transferring.
        if (mine && !message.isTransferring) ...[
          const SizedBox(width: 4),
          _DeliveryTicks(message: message),
        ],
      ],
    );
  }
}

/// Delivery indicator of an outgoing bubble: ⏱ waiting to send → ✓ written
/// to the socket → ✓✓ the peer confirmed storage; a failed write shows a
/// red alert. Legacy rows (state null) fall back to the single tick.
class _DeliveryTicks extends StatelessWidget {
  const _DeliveryTicks({required this.message});

  final MessageModel message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (IconData icon, Color color, String label) =
        switch (message.delivery) {
      MessageModel.deliveryDelivered => (
          Icons.done_all,
          const Color(0xFF9BF0FF),
          l10n.messageDeliveredLabel,
        ),
      MessageModel.deliveryPending => (
          Icons.schedule,
          Colors.white.withValues(alpha: 0.75),
          l10n.messageQueuedLabel,
        ),
      MessageModel.deliveryFailed => (
          Icons.error_outline,
          const Color(0xFFFFB4AB),
          l10n.messageFailedLabel,
        ),
      _ => (
          Icons.done,
          Colors.white.withValues(alpha: 0.75),
          l10n.messageSentLabel,
        ),
    };
    return Semantics(label: label, child: Icon(icon, size: 14, color: color));
  }
}

/// Small icon button used for ±10 s seek jumps in voice bubbles.
class _AudioSkipButton extends StatelessWidget {
  const _AudioSkipButton({required this.icon, required this.color, required this.onTap});

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}

// ── Input bar ──────────────────────────────────────────────────────────────

/// Glassy composer: image picker, rounded field and gradient send.
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({super.key, required this.state, required this.controller});

  final ChatState state;
  final ChatController controller;

  void _send() {
    final text = controller.textController.text.trim();
    if (state.isConnected && text.isNotEmpty) {
      controller.sendTextMessage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final l10n = AppLocalizations.of(context)!;
    if (!state.isConnected) {
      return _ConnectBar(state: state, controller: controller, palette: p);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.isRecording) _RecordingBanner(state: state, controller: controller, palette: p),
        Container(
          margin: const EdgeInsets.fromLTRB(10, 4, 10, 10),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: p.bar,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              // Tap-to-record voice message button (tap again to stop & send;
              // long-press the recording banner to cancel).
              GestureDetector(
                onTap: state.isRecording ? controller.stopRecordingAndSend : controller.startRecording,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(
                    state.isRecording ? Icons.graphic_eq : Icons.mic_none,
                    color: state.isRecording ? Colors.redAccent : p.accent,
                    size: 24,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.attach_file, color: p.accent),
                tooltip: l10n.attachTooltip,
                onPressed: () => controller.showAttachmentSheet(context),
              ),
              Expanded(
                child: TextField(
                  controller: controller.textController,
                  style: TextStyle(color: p.messageText),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: l10n.typeMessageHint,
                    hintStyle: TextStyle(color: p.muted),
                    isDense: true,
                    filled: true,
                    fillColor: p.surface.withValues(alpha: 0.85),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _SendButton(palette: p, onPressed: _send),
            ],
          ),
        ),
      ],
    );
  }
}

/// Thin strip shown above the composer while a voice recording is active.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.state, required this.controller, required this.palette});

  final ChatState state;
  final ChatController controller;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final seconds = state.recordSeconds;
    final label = l10n.recordingLabel('${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}');
    return GestureDetector(
      // Long-press anywhere on the banner also cancels.
      onLongPress: () => controller.cancelRecording(),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent,
                boxShadow: [BoxShadow(color: Colors.redAccent.withValues(alpha: 0.6), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontSize: 12, color: palette.muted)),
            const Spacer(),
            GestureDetector(
              onTap: () => controller.cancelRecording(),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.close, size: 14, color: palette.muted),
                    const SizedBox(width: 4),
                    Text(
                      l10n.cancel,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: palette.accent),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown instead of the composer when the chat is opened without a live
/// connection: a Connect button that tries to reach the session's device.
class _ConnectBar extends StatelessWidget {
  const _ConnectBar({required this.state, required this.controller, required this.palette});

  final ChatState state;
  final ChatController controller;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: palette.bar,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.notConnectedBar, style: TextStyle(fontSize: 11, color: palette.muted)),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            child: Ink(
              width: double.infinity,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(23),
                gradient: LinearGradient(colors: palette.sentGradient),
                boxShadow: [BoxShadow(color: palette.sentGlow, blurRadius: 8, offset: const Offset(0, 2))],
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(23),
                onTap: state.isConnecting ? null : () => _pickMethod(context),
                child: Center(
                  child: state.isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.link_rounded, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              l10n.connectAction,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens the transport picker and runs the chosen connect flow: the
  /// current transport delegates to the classic session reconnect; another
  /// transport runs ITS session-reconnect flow (discovery + match, with its
  /// own device-picker fallback) behind a cancellable connecting panel and
  /// opens its own chat screen once linked — the session reconciliation
  /// merges both channels into one conversation.
  Future<void> _pickMethod(BuildContext context) async {
    final kind = await showTransportPicker(context);
    if (kind == null) return;
    if (!context.mounted) return;
    await controller.connectViaTransport(kind, context);
  }
}

/// Connection-method picker shown by the chat's Connect button: the peer
/// can be reached over any of the three transports, each with its channel
/// icon, an accent-tinted medallion and a one-line hint. Returns the chosen
/// transport id (`ChatSessionModel.transport*`) or null when dismissed.
Future<String?> showTransportPicker(BuildContext context) {
  final p = ChatPalette.of(context);
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetContext) => Material(
      color: p.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.connectMethodTitle,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.messageText,
              ),
            ),
            const SizedBox(height: 12),
            _TransportOption(
              icon: Icons.bluetooth,
              accent: const Color(0xFF3D8BFF),
              title: l10n.bluetoothTab,
              hint: l10n.btConnectHint,
              palette: p,
              onTap: () => Navigator.of(sheetContext)
                  .pop(ChatSessionModel.transportBluetooth),
            ),
            const SizedBox(height: 10),
            _TransportOption(
              icon: Icons.wifi_tethering,
              accent: const Color(0xFF00B8D9),
              title: l10n.wifiTab,
              hint: l10n.wfdConnectHint,
              palette: p,
              onTap: () => Navigator.of(sheetContext)
                  .pop(ChatSessionModel.transportWifiDirect),
            ),
            const SizedBox(height: 10),
            _TransportOption(
              icon: Icons.sensors,
              accent: const Color(0xFF34A853),
              title: l10n.nearbyTab,
              hint: l10n.nearbyConnectHint,
              palette: p,
              onTap: () => Navigator.of(sheetContext)
                  .pop(ChatSessionModel.transportNearby),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One transport row of [showTransportPicker]: tinted icon medallion,
/// channel name and its one-line hint.
class _TransportOption extends StatelessWidget {
  const _TransportOption({
    required this.icon,
    required this.accent,
    required this.title,
    required this.hint,
    required this.palette,
    required this.onTap,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String hint;
  final ChatPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: palette.bar,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.16),
                    border: Border.all(color: accent.withValues(alpha: 0.45)),
                  ),
                  child: Icon(icon, color: accent, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: palette.messageText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: palette.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Gradient circular send button.
class _SendButton extends StatelessWidget {
  const _SendButton({required this.palette, required this.onPressed});

  final ChatPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: palette.sentGradient),
          boxShadow: [BoxShadow(color: palette.sentGlow, blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: InkWell(
          onTap: onPressed,
          child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

// ── Image preview ──────────────────────────────────────────────────────────

/// Full screen preview with gallery save support.
class ChatImagePreviewScreen extends StatelessWidget {
  const ChatImagePreviewScreen({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: p.canvasTop,
      appBar: AppBar(
        backgroundColor: p.bar,
        systemOverlayStyle: p.barForeground == Colors.white ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.barForeground),
        actions: [
          IconButton(
            icon: Icon(Icons.save_alt, color: p.accent),
            tooltip: l10n.saveToGalleryTooltip,
            onPressed: () => _saveToGallery(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
      ),
    );
  }

  Future<void> _saveToGallery(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // Request runtime permissions before saving. On Android 13+
    // WRITE_EXTERNAL_STORAGE is ignored, so READ_MEDIA_IMAGES
    // (Permission.photos) must be used instead of Permission.storage.
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final status = androidInfo.version.sdkInt >= 33
          ? await Permission.photos.request()
          : await Permission.storage.request();
      if (!status.isGranted) {
        if (context.mounted) {
          ConnectionNotice.show(
            title: l10n.permissionTitle,
            message: l10n.permissionRequiredMessage,
            icon: Icons.lock_outline,
            accent: Colors.amber,
          );
        }
        return;
      }
    } else if (Platform.isIOS) {
      var status = await Permission.photosAddOnly.request();
      if (!status.isGranted) {
        status = await Permission.photos.request();
        if (!status.isGranted) {
          if (context.mounted) {
            ConnectionNotice.show(
              title: l10n.permissionTitle,
              message: l10n.photosPermissionRequiredMessage,
              icon: Icons.lock_outline,
              accent: Colors.amber,
            );
          }
          return;
        }
      }
    }
    final file = File(path);
    final res = await ImageGallerySaverPlus.saveImage(
      file.readAsBytesSync(),
      quality: 95,
      name: 'chatblue_${DateTime.now().millisecondsSinceEpoch}',
    );
    if (context.mounted) {
      final ok = res is Map && (res['isSuccess'] == true || res['filePath'] != null);
      ConnectionNotice.show(
        title: l10n.photoLabel,
        message: ok ? l10n.savedToGallery : l10n.saveFailed,
        icon: ok ? Icons.check_circle : Icons.error_outline,
        accent: ok ? Colors.green : Colors.redAccent,
      );
    }
  }
}
