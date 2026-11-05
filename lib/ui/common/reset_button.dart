import 'package:flutter/material.dart';

/// Small "reset to default" icon placed next to a parameter's control every
/// parameter gets one). For animated parameters the caller resets the value at
/// the current frame, using the same keyframe rule as any other edit
/// (track_edit.dart).
class ResetIconButton extends StatelessWidget {
  final VoidCallback onPressed;
  const ResetIconButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.restart_alt, size: 16),
      tooltip: 'reset to default',
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}
