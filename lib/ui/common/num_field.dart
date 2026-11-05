import 'package:flutter/material.dart';

/// A numeric text field bound to a mutable external value, sharing this
/// app's persistent-controller pattern across every params-style panel
/// (params_panel_view.dart, effects_view.dart, graph_editor_view.dart's
/// own coordinate fields).
///
/// Real device bug this fixes (originally discovered in
/// params_panel_view.dart): building a bare TextField with a
/// TextEditingController created INLINE, fresh, on every rebuild loses
/// focus the instant an ancestor rebuilds mid-edit (e.g. the real
/// keyboard opening resizes the Scaffold body, cascading a rebuild down
/// through every plain widget in between). Fixed by owning the
/// controller/FocusNode for this widget's own lifetime, independent of
/// how many times its description (constructor args) changes underneath
/// it - only resyncing the displayed text from the external `value` when
/// the field isn't currently focused.
class NumField extends StatefulWidget {
  final double value;
  final ValueChanged<double> onCommit;
  final double width;

  /// Whole numbers shown as "42", not "42.0" (frame counts).
  final bool integer;
  final TextAlign textAlign;
  const NumField(
      {super.key,
      required this.value,
      required this.onCommit,
      this.width = 60,
      this.integer = false,
      this.textAlign = TextAlign.start});

  @override
  State<NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<NumField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  static String _formatValue(double value) => (value * 1000).round() / 1000 == value ? value.toString() : value.toStringAsFixed(3);

  String _format(double value) => widget.integer ? value.round().toString() : _formatValue(value);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  // a tension edit "set the value but didn't apply to the screen/playback" -
  // traced to some on-device numeric keypads showing no visible "done"/submit
  // key at all, so `onSubmitted` (which only fires on that explicit IME
  // action) never ran; tapping elsewhere to dismiss the keyboard was the only
  // way those keyboards let a user finish typing, and that path never
  // committed anything. Committing on focus loss too closes that gap for every
  // field built from this widget, not just the one that happened to get
  // reported.
  void _handleFocusChange() {
    if (_focusNode.hasFocus) return;
    final v = double.tryParse(_controller.text);
    if (v != null) widget.onCommit(v);
  }

  @override
  void didUpdateWidget(covariant NumField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && oldWidget.value != widget.value) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        textAlign: widget.textAlign,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4)),
        onSubmitted: (text) {
          final v = double.tryParse(text);
          if (v != null) widget.onCommit(v);
        },
      ),
    );
  }
}
