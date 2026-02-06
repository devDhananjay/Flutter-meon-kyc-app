import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// OTP input boxes as per design – sirf user OTP dalega (6 square boxes by default)
class OtpInput extends StatefulWidget {
  final int length;
  final void Function(String value)? onComplete;
  final void Function(String value)? onChanged;

  const OtpInput({
    super.key,
    this.length = 6,
    this.onComplete,
    this.onChanged,
  });

  @override
  State<OtpInput> createState() => _OtpInputState();
}

class _OtpInputState extends State<OtpInput> {
  final List<FocusNode> _focusNodes = [];
  final List<TextEditingController> _controllers = [];

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.length; i++) {
      _focusNodes.add(FocusNode());
      _controllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    for (final n in _focusNodes) n.dispose();
    for (final c in _controllers) c.dispose();
    super.dispose();
  }

  String get _value {
    final s = _controllers.map((c) => c.text).join();
    return s.length > widget.length ? s.substring(0, widget.length) : s;
  }

  void _onChanged(int index, String v) {
    if (v.length > 1) {
      v = v[v.length - 1];
      _controllers[index].text = v;
      _controllers[index].selection =
          TextSelection.collapsed(offset: v.length);
    }
    final full = _value;
    widget.onChanged?.call(full);
    if (full.length == widget.length) {
      widget.onComplete?.call(full);
    }
    if (v.isNotEmpty && index < widget.length - 1) {
      _focusNodes[index + 1].requestFocus();
    }
  }

  void _onKey(int index, RawKeyEvent e) {
    if (e is RawKeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalPadding = 12.0 * (widget.length - 1);
        final availableWidth = constraints.maxWidth > 0 ? constraints.maxWidth - totalPadding : null;
        final boxSize = availableWidth != null && availableWidth > 0
            ? (availableWidth / widget.length).clamp(44.0, 56.0)
            : 48.0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: List.generate(widget.length, (i) {
            return Padding(
              padding: EdgeInsets.only(right: i < widget.length - 1 ? 6 : 0),
              child: SizedBox(
                width: boxSize,
                height: boxSize,
                child: RawKeyboardListener(
              focusNode: FocusNode(),
              onKey: (e) => _onKey(i, e),
              child: TextFormField(
                controller: _controllers[i],
                focusNode: _focusNodes[i],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 1,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onChanged: (v) => _onChanged(i, v),
                decoration: InputDecoration(
                  counterText: '',
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: KycTheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: KycTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                      color: KycTheme.primary,
                      width: 2,
                    ),
                  ),
                ),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      }),
    );
      },
    );
  }
}
