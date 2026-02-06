import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Stepper as per design: 1. Mobile Verify, 2. Email Verify, 3. Pan Details, etc.
/// - Completed: purple circle with white checkmark inside
/// - Active: purple circle with step number inside, bold label below
/// - Inactive: grey circle with number, grey label below
/// - Arrows: purple for completed segment, grey for next
class KycStepperBar extends StatelessWidget {
  final List<String> steps;
  final int currentIndex;

  const KycStepperBar({
    super.key,
    required this.steps,
    this.currentIndex = 0,
  });

  /// Default 5-step labels from Figma
  static const List<String> defaultSteps = [
    'Mobile Verify',
    'Email Verify',
    'Pan Details',
    'Personal Details',
    'Add Nominee',
  ];

  @override
  Widget build(BuildContext context) {
    final list = steps.isEmpty ? defaultSteps : steps;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(list.length * 2 - 1, (i) {
          if (i.isOdd) {
            final prevIdx = (i - 1) ~/ 2;
            final isSegmentDone = currentIndex > prevIdx;
            return Padding(
              padding: const EdgeInsets.only(top: 14, left: 2, right: 2),
              child: Icon(
                Icons.arrow_forward_ios,
                size: 12,
                color: isSegmentDone ? KycTheme.primary : KycTheme.textSecondary,
              ),
            );
          }
          final idx = i ~/ 2;
          final isActive = idx == currentIndex;
          final isPast = idx < currentIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              // Circle: completed = purple + check inside, active = purple + number, inactive = grey + number
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isPast
                      ? KycTheme.primary
                      : isActive
                          ? KycTheme.primary
                          : KycTheme.border,
                ),
                child: Center(
                  child: isPast
                      ? const Icon(Icons.check, size: 18, color: Colors.white)
                      : Text(
                          '${idx + 1}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isActive || isPast
                                ? Colors.white
                                : KycTheme.textSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              // Label below
              Text(
                list[idx],
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  color: isActive || isPast
                      ? KycTheme.textPrimary
                      : KycTheme.textSecondary,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            ),
          );
        }),
      ),
    );
  }
}
