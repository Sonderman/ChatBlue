// Cancellable bottom panel shown while an outgoing connection attempt is in
// flight — replaces the old full-screen spinner dialog.
//
// Closed BY ROUTE REFERENCE (never a blind pop): on success the notifier
// pushes the chat screen while this panel is still up; a blind pop would
// close the fresh chat instead (same class as the old scan-dialog race).
import 'dart:async';

import 'package:chatblue/l10n/app_localizations.dart';
import 'package:flutter/material.dart';

/// How the connecting panel closed.
enum ConnectingOutcome { done, cancelled }

/// Pushes the connecting panel and drives [connect] to completion.
///
/// The panel closes as `done` when [connect] resolves (its own timing —
/// timeout paths included) and as `cancelled` when the user taps İptal;
/// [onCancel] then runs to abort the attempt (best effort).
///
/// [qualityLabel] is an optional caller-supplied line (e.g. the BT scan
/// RSSI): Nearby's API exposes no signal metric, so it is null there.
Future<ConnectingOutcome> showConnectingPanel({
  required BuildContext context,
  required Future<void> Function() connect,
  required Future<void> Function() onCancel,
  String? deviceName,
  String? qualityLabel,
}) {
  final nav = Navigator.of(context, rootNavigator: true);
  final completer = Completer<ConnectingOutcome>();
  late final ModalBottomSheetRoute<ConnectingOutcome> route;
  route = ModalBottomSheetRoute<ConnectingOutcome>(
    isScrollControlled: false,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => _ConnectingSheet(
      deviceName: deviceName,
      qualityLabel: qualityLabel,
      connect: connect,
      onCancel: onCancel,
      finish: (outcome) {
        if (!completer.isCompleted) completer.complete(outcome);
        if (route.isActive) nav.removeRoute(route);
      },
    ),
  );
  nav.push(route);
  return completer.future;
}

class _ConnectingSheet extends StatefulWidget {
  const _ConnectingSheet({
    required this.connect,
    required this.onCancel,
    required this.finish,
    this.deviceName,
    this.qualityLabel,
  });

  final Future<void> Function() connect;
  final Future<void> Function() onCancel;
  final void Function(ConnectingOutcome outcome) finish;
  final String? deviceName;
  final String? qualityLabel;

  @override
  State<_ConnectingSheet> createState() => _ConnectingSheetState();
}

class _ConnectingSheetState extends State<_ConnectingSheet> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.connect();
    } catch (_) {
      // The screen's logic judges outcomes from state; never leave the
      // panel hanging on an unexpected throw.
    }
    _close(ConnectingOutcome.done);
  }

  void _close(ConnectingOutcome outcome) {
    if (_closed) return;
    _closed = true;
    widget.finish(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final name = widget.deviceName?.trim() ?? '';
    return Material(
      color: theme.cardColor,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (name.isNotEmpty)
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    l10n.connectingTitle,
                    style: TextStyle(fontSize: 12.5, color: theme.hintColor),
                  ),
                  if (widget.qualityLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.signal_cellular_alt,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.qualityLabel!,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () {
                if (_closed) return;
                // Close first, then abort: the wait resolves as cancelled
                // and the scan screen skips the failure snackbar.
                _close(ConnectingOutcome.cancelled);
                unawaited(widget.onCancel());
              },
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
  }
}
