import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/field_validators.dart';

/// Web-parity nominee step chrome: dashed Add/Remove nominee + optional add-more buttons.
class NomineeStepSection {
  NomineeStepSection._();

  static const String _maxNomineesHint = 'You can add maximum of 10 nominees';

  static Widget _dashedActionCard({
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Material(
      color: const Color(0xFFF8F9FB),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: const Color(0xFFB8BEC8),
            radius: KycTheme.radiusMd,
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  static Widget primaryToggle({
    required bool addingNominee,
    required VoidCallback onAdd,
    required VoidCallback onRemove,
  }) {
    return _dashedActionCard(
      onTap: addingNominee ? onRemove : onAdd,
      child: Text(
        addingNominee ? '− Remove Nominee' : '+ Add Nominee (Optional)',
        style: const TextStyle(
          fontSize: KycTheme.fontSizeBodyLg,
          fontWeight: FontWeight.w700,
          color: KycTheme.primary,
        ),
      ),
    );
  }

  static Widget maxNomineesHint() {
    return const Padding(
      padding: EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        _maxNomineesHint,
        style: TextStyle(
          fontSize: KycTheme.fontSizeCaption,
          color: KycTheme.textSecondary,
        ),
      ),
    );
  }

  /// Styled "+ Add Nominee (optional)" for `add_2_nominee` / `add_4_nominee` etc.
  static Widget optionalAddCheckboxButton({
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _dashedActionCard(
        onTap: onTap,
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
              fontSize: KycTheme.fontSizeBodyLg,
              fontWeight: FontWeight.w700,
              color: KycTheme.primary,
            ),
            children: const [
              TextSpan(text: '+ Add Nominee'),
              TextSpan(
                text: ' (optional)',
                style: TextStyle(
                  fontSize: KycTheme.fontSizeCaption,
                  fontWeight: FontWeight.w500,
                  color: KycTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether a field belongs in the nominee block (not toggle / consent / backend).
  static bool isNomineeFormContentField(String name) {
    if (isNomineeAddNomineeDropdownField(name)) return false;
    if (isNomineeOptOutConsentField(name)) return false;
    if (isNomineeBackendOnlyField(name)) return false;
    return true;
  }

  /// Hide styled add checkbox once the user has opened that nominee slot.
  static bool shouldRenderStyledAddCheckbox({
    required String name,
    required Map<String, dynamic> formData,
  }) {
    if (!isNomineeStyledAddCheckboxField(name)) return false;
    return !isCheckboxCheckedValue(formData[name]);
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashWidth = 6.0;
    const dashSpace = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = distance + dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, end.clamp(0.0, metric.length)),
          paint,
        );
        distance = end + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}
