import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Stepper as per design: 1. Mobile Verify, 2. Email Verify, 3. Pan Details, etc.
/// - Completed: purple circle with white checkmark inside
/// - Active: purple circle with step number inside, bold label below
/// - Inactive: grey circle with number, grey label below
/// - Active step is kept centered; horizontal scroll to see prev/next
class KycStepperBar extends StatefulWidget {
  final List<String> steps;
  final int currentIndex;

  const KycStepperBar({
    super.key,
    required this.steps,
    this.currentIndex = 0,
  });

  static const List<String> defaultSteps = [
    'mobile',
    'mobile_otp',
    'email',
    'email_otp',
    'segments',
    'detailspan',
    'kradetails',
    'digilocker',
    'personal_details',
    'nominee',
    'reverse_pennydrop',
    'bank_details',
    'account_aggregator',
    'liveimage',
    'bank_upload',
    'pdf',
    'esign',
  ];

  /// Format moduleName to readable step label (e.g., "mobile" -> "Mobile Verify")
  static String formatModuleName(String moduleName) {
    final lower = moduleName.toLowerCase();
    const labelMap = {
      'mobile': 'Mobile Verify',
      'mobile_otp': 'Mobile Verify',
      'email': 'Email Verify',
      'email_otp': 'Email Verify',
      'detailspan': 'Pan Details',
      'pan': 'Pan Details',
      'personal_details': 'Personal Details',
      'nominee': 'Add Nominee',
    };
    if (labelMap.containsKey(lower)) return labelMap[lower]!;
    return moduleName
        .replaceAll('_', ' ')
        .split(' ')
        .map((word) => word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1).toLowerCase())
        .join(' ');
  }

  @override
  State<KycStepperBar> createState() => _KycStepperBarState();
}

class _KycStepperBarState extends State<KycStepperBar> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollContainerKey = GlobalKey();
  static const double _stepWidth = 158.0; // circle + padding + label
  static const double _connectorWidth = 48.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCenterActive() {
    final steps = widget.steps.isEmpty ? KycStepperBar.defaultSteps : widget.steps;
    final idx = widget.currentIndex.clamp(0, steps.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _scrollContainerKey.currentContext?.findRenderObject() as RenderBox?;
      final viewportWidth = box?.size.width ?? 0;
      if (viewportWidth <= 0) return;
      // Center of step at idx: each step is _stepWidth + _connectorWidth (except last has no connector)
      final stepCenter = idx * (_stepWidth + _connectorWidth) + _stepWidth / 2;
      final targetOffset = (stepCenter - viewportWidth / 2).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _scrollToCenterActive();
  }

  @override
  void didUpdateWidget(KycStepperBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _scrollToCenterActive();
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.steps.isEmpty ? KycStepperBar.defaultSteps : widget.steps;
    final currentIndex = widget.currentIndex;
    return Container(
      key: _scrollContainerKey,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      color: Colors.white,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(list.length * 2 - 1, (i) {
            if (i.isOdd) {
              final prevIdx = (i - 1) ~/ 2;
              final isSegmentDone = prevIdx < currentIndex;
              return Container(
                margin: const EdgeInsets.only(top: 16, left: 8, right: 8),
                width: 32,
                height: 2,
                decoration: BoxDecoration(
                  color: isSegmentDone ? KycTheme.primary : KycTheme.border,
                  borderRadius: BorderRadius.circular(1),
                ),
              );
            }
            final idx = i ~/ 2;
            final isPast = idx < currentIndex;
            final isActive = idx == currentIndex;
            final stepLabel = widget.steps.isEmpty
                ? list[idx]
                : KycStepperBar.formatModuleName(list[idx]);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isPast || isActive ? KycTheme.primary : Colors.transparent,
                      border: Border.all(
                        color: isPast || isActive ? KycTheme.primary : KycTheme.border,
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: isPast
                          ? const Icon(Icons.check, size: 20, color: Colors.white)
                          : Text(
                              '${idx + 1}',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: isActive || isPast
                                    ? Colors.white
                                    : KycTheme.textSecondary,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Text(
                        stepLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive || isPast
                              ? KycTheme.textPrimary
                              : KycTheme.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}
