import 'package:flutter/material.dart';

/// Settings: "Show descriptions" - every explanatory line in the panels
/// (the small grey text under a switch or a control) can be switched off.
final ValueNotifier<bool> descriptionsVisible = ValueNotifier(true);

/// A description line: small grey text, gone while descriptions are off.
class Hint extends StatelessWidget {
  final String text;
  final double fontSize;
  const Hint(this.text, {super.key, this.fontSize = 11});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: descriptionsVisible,
        builder: (context, on, _) =>
            on ? Text(text, style: TextStyle(fontSize: fontSize, color: Colors.grey)) : const SizedBox.shrink(),
      );
}

/// For a ListTile's `subtitle`: the description, or nothing at all (so
/// the tile shrinks to one line) while descriptions are off.
Widget? hint(String text) => descriptionsVisible.value ? Hint(text) : null;
