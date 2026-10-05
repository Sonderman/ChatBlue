// Shared modern chat UI kit for the Bluetooth and Wi‑Fi Direct chat screens.
//
// Design language: navy/cyan identity with theme-aware palettes — dark mode
// keeps the deep navy canvas, light mode uses a bright variant. Both chat
// screens (B/W) build from these widgets so the two transports share one
// visual identity.

import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/screens/chat_screen_controller_base.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
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

  static ChatPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
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
  const ChatAppBar({super.key, required this.controller});

  final ChatScreenControllerBase controller;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    return AppBar(
      // Status bar icons follow the chat palette, not the app theme: the
      // chat bar stays dark navy on the light theme too.
      systemOverlayStyle: p.barForeground == Colors.white
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      backgroundColor: p.bar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: p.barForeground),
      toolbarHeight: 64,
      titleSpacing: 4,
      title: Obx(() {
        // The observable must be read UNCONDITIONALLY: GetX throws at
        // runtime when a build registers no Rx dependency — the old
        // short-circuit below skipped peerName whenever the transport
        // name was already set (BT always, WFD after READY).
        final peerName = controller.peerName.value;
        final name = controller.transport.connectedDeviceName ??
            (peerName.isNotEmpty ? peerName : controller.chatSession.name);
        return Row(
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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: p.barForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Obx(
                  () => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StatusDot(connected: controller.isConnected.value, palette: p),
                      const SizedBox(width: 6),
                      Text(
                        controller.isConnected.value
                            ? 'connectedStatus'.tr
                            : 'notConnectedStatus'.tr,
                        style: TextStyle(
                          fontSize: 11,
                          color: controller.isConnected.value
                              ? p.accent
                              : Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        );
      }),
      actions: [
        IconButton(
          icon: Icon(Icons.delete_sweep_outlined, color: p.muted),
          tooltip: 'clearChatTooltip'.tr,
          onPressed: () => showChatClearDialog(controller),
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.sentGradient,
        ),
        border: Border.all(color: palette.accent.withValues(alpha: 0.55), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: palette.accent.withValues(alpha: 0.25),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
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
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6),
        ],
      ),
    );
  }
}

/// Palette for GetX dialogs, which have no local BuildContext.
ChatPalette _dialogPalette() => ChatPalette.of(Get.context!);

/// Theme-aware confirmation dialog for clearing the conversation.
Future<void> showChatClearDialog(ChatScreenControllerBase controller) async {
  final p = _dialogPalette();
  final clear = await Get.dialog<bool>(
    AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      title: Text('clearConversationTitle'.tr, style: TextStyle(color: p.messageText)),
      content: Text(
        'clearConversationMessage'.tr,
        style: TextStyle(color: p.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: Text('cancel'.tr, style: TextStyle(color: p.muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFC62828),
            foregroundColor: Colors.white,
          ),
          onPressed: () => Get.back(result: true),
          child: Text('clearAction'.tr),
        ),
      ],
    ),
  );
  if (clear == true) {
    controller.messages.clear();
    controller.saveChatSession();
  }
}

/// Theme-aware confirmation dialog for removing one of the user's own
/// messages (local only — the peer's copy is untouched).
Future<void> showDeleteMessageDialog(
  ChatScreenControllerBase controller,
  MessageModel message,
) async {
  final p = _dialogPalette();
  final delete = await Get.dialog<bool>(
    AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      title: Text('deleteMessageTitle'.tr, style: TextStyle(color: p.messageText)),
      content: Text(
        'deleteMessageBody'.tr,
        style: TextStyle(color: p.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: Text('cancel'.tr, style: TextStyle(color: p.muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFC62828),
            foregroundColor: Colors.white,
          ),
          onPressed: () => Get.back(result: true),
          child: Text('delete'.tr),
        ),
      ],
    ),
  );
  if (delete == true) {
    controller.deleteMessage(message.id);
  }
}

/// Theme-aware dialog shown before leaving mid-transfer.
Future<bool?> showChatTransferDialog() {
  final p = _dialogPalette();
  return Get.dialog<bool>(
    AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      title: Text('transferInProgressTitle'.tr, style: TextStyle(color: p.messageText)),
      content: Text(
        'transferInProgressMessage'.tr,
        style: TextStyle(color: p.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: Text('stayAction'.tr, style: TextStyle(color: p.accent)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: p.accentDeep,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Get.back(result: true),
          child: Text('leaveAction'.tr),
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
  const ChatSyncBanner({super.key, required this.controller});

  final ChatScreenControllerBase controller;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    return Obx(() {
      if (!controller.isSyncing.value) return const SizedBox.shrink();
      // The app bar floats above the canvas (extendBodyBehindAppBar). The
      // body sits inside a SafeArea that already consumes the status bar
      // inset, so the banner only needs the app bar's 64 px toolbar height
      // to sit flush against its bottom edge.
      return Container(
        margin: const EdgeInsets.only(top: 66, left: 10, right: 10),
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
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: p.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'syncingHistory'.tr,
                  style: TextStyle(fontSize: 11, color: p.muted),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: controller.syncProgress.value,
                minHeight: 2,
                backgroundColor: p.progressTrack,
                valueColor: AlwaysStoppedAnimation<Color>(p.accent),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// Reverse chronological message list driving the shared controller state.
class ChatMessageList extends StatelessWidget {
  const ChatMessageList({super.key, required this.controller});

  final ChatScreenControllerBase controller;

  @override
  Widget build(BuildContext context) {
    // The app bar floats above the canvas (extendBodyBehindAppBar). The
    // body sits inside a SafeArea that already consumes the status bar
    // inset, so the list only needs the app bar's 64 px toolbar height plus
    // a small breathing gap to start below it.
    const topInset = 72.0;
    return Obx(
      () => ListView.builder(
        reverse: true,
        padding: EdgeInsets.fromLTRB(10, topInset, 10, 8),
        itemCount: controller.messages.length,
        itemBuilder: (context, index) =>
            ChatMessageBubble(message: controller.messages[index], controller: controller),
      ),
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
  final ChatScreenControllerBase? controller;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    final bool mine = message.isSentByMe;
    final bool showProgress =
        message.isTransferring && message.transferKind == 'bytes';
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 4),
      bottomRight: Radius.circular(mine ? 4 : 18),
    );

    final Widget content;
    if (message.hasRemoteMedia) {
      // Deferred media from the history sync: the file still lives on the
      // peer — offer a download placeholder instead of the media.
      content = _downloadBubble(p, mine);
    } else if (message.isAudio && message.imagePath != null) {
      content = _audioBubble(p, mine);
    } else if (message.imagePath != null) {
      content = _imageBubble(p, mine, showProgress);
    } else if (showProgress) {
      content = _progressBubble(p, mine);
    } else {
      content = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            message.text,
            // Long-press opens the text selection toolbar: Copy is always
            // offered (without requiring a selection it copies the whole
            // message); own messages additionally get a Delete action that
            // routes through the themed confirmation dialog.
            contextMenuBuilder: (context, editableTextState) {
              final items = editableTextState.contextMenuButtonItems;
              items.add(
                ContextMenuButtonItem(
                  label: 'copyAction'.tr,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    editableTextState.hideToolbar();
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(''),
                        duration: Duration(milliseconds: 800),
                      ),
                    );
                  },
                ),
              );
              if (mine && controller != null) {
                items.add(
                  ContextMenuButtonItem(
                    label: 'delete'.tr,
                    onPressed: () {
                      editableTextState.hideToolbar();
                      showDeleteMessageDialog(controller!, message);
                    },
                  ),
                );
              }
              return AdaptiveTextSelectionToolbar.buttonItems(
                buttonItems: items,
                anchors: editableTextState.contextMenuAnchors,
              );
            },
            style: TextStyle(
              height: 1.25,
              fontSize: 15,
              color: mine ? Colors.white : p.messageText,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            formatChatTimestamp(message.timestamp),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: mine ? Colors.white.withValues(alpha: 0.75) : p.muted,
            ),
          ),
        ],
      );
    }

    // Long-press on any (non-text) own bubble asks before deleting; text
    // bubbles are handled via their selection toolbar above. Transfers in
    // flight are excluded — mid-transfer deletions would corrupt the
    // progress-bubble bookkeeping.
    return GestureDetector(
      onLongPress:
          (mine && !message.isTransferring && controller != null)
          ? () => showDeleteMessageDialog(controller!, message)
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
            boxShadow: mine
                ? [
                    BoxShadow(
                      color: p.sentGlow,
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: content,
        ),
      ),
    );
  }

  /// Placeholder bubble for media that was NOT auto-downloaded during the
  /// history sync (large files live on the peer): shows the kind and size,
  /// fetches the file on tap and spins while the fetch is in flight.
  Widget _downloadBubble(ChatPalette p, bool mine) {
    final bool audio = message.isAudio;
    final bool busy = message.isTransferring;
    final int size = message.remoteMediaSize ?? 0;
    final Color iconColor = mine ? Colors.white : p.accent;
    return GestureDetector(
      onTap: busy ? null : () => controller?.downloadMedia(message),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                audio ? Icons.mic_none : Icons.image_outlined,
                size: 20,
                color: iconColor,
              ),
              const SizedBox(width: 8),
              Text(
                audio ? 'audioLabel'.tr : 'photoLabel'.tr,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: mine ? Colors.white : p.messageText,
                ),
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
                busy
                    ? 'downloadingLabel'.tr
                    : '${_formatMediaSize(size)} • ${'downloadMediaHint'.tr}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color:
                      mine ? Colors.white.withValues(alpha: 0.85) : p.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            formatChatTimestamp(message.timestamp),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: mine ? Colors.white.withValues(alpha: 0.75) : p.muted,
            ),
          ),
        ],
      ),
    );
  }

  /// Compact human size for the download placeholder ("2.4 MB").
  String _formatMediaSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '$bytes B';
  }

  /// Image thumbnail bubble with progress bar while transferring.
  Widget _imageBubble(ChatPalette p, bool mine, bool showProgress) {
    return GestureDetector(
      onTap: showProgress
          ? null
          : () => Get.to(() => ChatImagePreviewScreen(path: message.imagePath!)),
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
              value: ((message.transferCurrent ?? 0) / (message.transferTotal ?? 1))
                  .clamp(0, 1)
                  .toDouble(),
            ),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 4),
          Text(
            formatChatTimestamp(message.timestamp),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: mine ? Colors.white.withValues(alpha: 0.75) : p.muted,
            ),
          ),
        ],
      ),
    );
  }

  /// Voice-note bubble: play/pause button, duration caption and a thin
  /// playback progress line. The file path lives in `imagePath` (see base).
  Widget _audioBubble(ChatPalette p, bool mine) {
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Obx(() {
              final isThis = controller?.playingAudioId.value == message.id;
              final playing = isThis && (controller?.isAudioPlaying.value ?? false);
              return GestureDetector(
                onTap: controller == null
                    ? null
                    : () => controller!.toggleAudio(message),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: p.sentGradient),
                    border: Border.all(
                      color: mine
                          ? Colors.white.withValues(alpha: 0.45)
                          : p.border,
                    ),
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              );
            }),
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
                        onTap: () => controller!.skipAudio(
                          const Duration(seconds: -10),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _AudioSkipButton(
                        icon: Icons.forward_10,
                        color: mine ? Colors.white : p.accent,
                        onTap: () => controller!.skipAudio(
                          const Duration(seconds: 10),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                // Draggable seek bar (thin slider).
                SizedBox(
                  width: 170,
                  child: Obx(() {
                    final isThis =
                        controller?.playingAudioId.value == message.id;
                    final durationMs = controller?.audioDurationMs ?? 0;
                    final value = isThis
                        ? (controller!.audioProgress.value * durationMs)
                        : 0.0;
                    return SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: mine ? Colors.white : p.accent,
                        inactiveTrackColor: mine
                            ? Colors.white.withValues(alpha: 0.3)
                            : p.progressTrack,
                        thumbColor: mine ? Colors.white : p.accent,
                        overlayColor: (mine ? Colors.white : p.accent)
                            .withValues(alpha: 0.15),
                      ),
                      child: Slider(
                        value: value.clamp(0.0, durationMs),
                        max: durationMs > 0 ? durationMs : 1,
                        onChanged: controller == null
                            ? null
                            : (v) => controller!.seekAudio(message, v),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          formatChatTimestamp(message.timestamp),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: mine ? Colors.white.withValues(alpha: 0.75) : p.muted,
          ),
        ),
      ],
    );
  }

  /// Bare transfer progress bubble (bubble without a thumbnail yet).
  Widget _progressBubble(ChatPalette p, bool mine) {
    final current = message.transferCurrent ?? 0;
    final total = message.transferTotal ?? 0;
    final pct = total == 0 ? 0 : (current / total * 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _chatProgressBar(
          p,
          value: (current / (total == 0 ? 1 : total)).clamp(0, 1).toDouble(),
        ),
        const SizedBox(height: 6),
        Text(
          '${mine ? 'sendingLabel'.tr : 'receivingLabel'.tr} '
          '$current/$total bytes ($pct%)',
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 11,
            color: mine ? Colors.white.withValues(alpha: 0.75) : p.muted,
          ),
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

/// Small icon button used for ±10 s seek jumps in voice bubbles.
class _AudioSkipButton extends StatelessWidget {
  const _AudioSkipButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

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
  const ChatInputBar({super.key, required this.controller});

  final ChatScreenControllerBase controller;

  void _send() {
    final text = controller.textController.text.trim();
    if (controller.isConnected.value && text.isNotEmpty) {
      controller.sendTextMessage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette.of(context);
    return Obx(() {
      if (!controller.isConnected.value) {
        return _ConnectBar(controller: controller, palette: p);
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controller.isRecording.value)
            _RecordingBanner(controller: controller, palette: p),
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
                  onTap: controller.isRecording.value
                      ? controller.stopRecordingAndSend
                      : controller.startRecording,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      controller.isRecording.value
                          ? Icons.graphic_eq
                          : Icons.mic_none,
                      color: controller.isRecording.value
                          ? Colors.redAccent
                          : p.accent,
                      size: 24,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.image_outlined, color: p.accent),
                  tooltip: 'sendImageTooltip'.tr,
                  onPressed: () => controller.showImageSourceSheet(),
                ),
            Expanded(
              child: TextField(
                controller: controller.textController,
                style: TextStyle(color: p.messageText),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'typeMessageHint'.tr,
                  hintStyle: TextStyle(color: p.muted),
                  isDense: true,
                  filled: true,
                  fillColor: p.surface.withValues(alpha: 0.85),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
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
    });
  }
}

/// Thin strip shown above the composer while a voice recording is active.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.controller, required this.palette});

  final ChatScreenControllerBase controller;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
    // Own Obx: reads must happen inside it for the seconds counter to
    // rebuild the banner (the parent chair's Obx only tracks isRecording).
    return Obx(() {
      final seconds = controller.recordSeconds.value;
      final label =
          'recordingLabel'.trParams({
            'time':
                '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
          });
    return GestureDetector(
      // Long-press anywhere on the banner also cancels.
      onLongPress: controller.cancelRecording,
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
              boxShadow: [
                BoxShadow(
                  color: Colors.redAccent.withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12, color: palette.muted)),
          const Spacer(),
          GestureDetector(
            onTap: controller.cancelRecording,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close, size: 14, color: palette.muted),
                  const SizedBox(width: 4),
                  Text(
                    'cancel'.tr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
    });
  }
}

/// Shown instead of the composer when the chat is opened without a live
/// connection: a Connect button that tries to reach the session's device.
class _ConnectBar extends StatelessWidget {
  const _ConnectBar({required this.controller, required this.palette});

  final ChatScreenControllerBase controller;
  final ChatPalette palette;

  @override
  Widget build(BuildContext context) {
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
          Text(
            'notConnectedBar'.tr,
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            child: Ink(
              width: double.infinity,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(23),
                gradient: LinearGradient(colors: palette.sentGradient),
                boxShadow: [
                  BoxShadow(
                    color: palette.sentGlow,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(23),
                onTap: controller.isConnecting.value
                    ? null
                    : controller.connectToCurrentSession,
                child: Obx(
                  () => Center(
                    child: controller.isConnecting.value
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Colors.white,
                            ),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.link_rounded, color: Colors.white, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'connectAction'.tr,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
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
          boxShadow: [
            BoxShadow(
              color: palette.sentGlow,
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
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
    return Scaffold(
      backgroundColor: p.canvasTop,
      appBar: AppBar(
        backgroundColor: p.bar,
        systemOverlayStyle: p.barForeground == Colors.white
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.barForeground),
        actions: [
          IconButton(
            icon: Icon(Icons.save_alt, color: p.accent),
            tooltip: 'saveToGalleryTooltip'.tr,
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
    // Request runtime permissions before saving. On Android 13+
    // WRITE_EXTERNAL_STORAGE is ignored, so READ_MEDIA_IMAGES
    // (Permission.photos) must be used instead of Permission.storage.
    if (GetPlatform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final status = androidInfo.version.sdkInt >= 33
          ? await Permission.photos.request()
          : await Permission.storage.request();
      if (!status.isGranted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('permissionRequiredMessage'.tr)),
          );
        }
        return;
      }
    } else if (GetPlatform.isIOS) {
      var status = await Permission.photosAddOnly.request();
      if (!status.isGranted) {
        status = await Permission.photos.request();
        if (!status.isGranted) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('photosPermissionRequiredMessage'.tr)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'savedToGallery'.tr : 'saveFailed'.tr)),
      );
    }
  }
}