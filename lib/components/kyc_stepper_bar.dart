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
  'kra_fetch_new',
  'kradetails',
  'digilocker',
  'pan',
  'personal_details',
  'nominee',
  'additional_nominee',
  'additional_nominee_second',
  'nominee_mobile',
  'mobile_otp',
  'reverse_pennydrop',
  'bank',
  'bank_details',
  'account_aggregator',
  'liveimage',
  'pan_upload',
  'sign_upload',
  'income_proof',
  'bank_upload',
  'pdf',
  'esign',
  'complete',
];

  /// Format label to readable step label (capitalize first letter of each word)
  static String formatLabel(String label) {
    return label
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
  // Keep a key per step so we can measure its position and center it
  final List<GlobalKey> _stepKeys = [];

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
      if (idx < 0 || idx >= _stepKeys.length) return;

      final containerBox =
          _scrollContainerKey.currentContext?.findRenderObject() as RenderBox?;
      final stepBox = _stepKeys[idx].currentContext?.findRenderObject() as RenderBox?;

      if (containerBox == null || stepBox == null) return;

      final viewportWidth = containerBox.size.width;
      if (viewportWidth <= 0) return;

      // Center of the active step in global coordinates
      final stepCenterGlobal =
          stepBox.localToGlobal(Offset(stepBox.size.width / 2, 0)).dx;
      final containerLeftGlobal =
          containerBox.localToGlobal(Offset.zero).dx;
      final stepCenterInViewport = stepCenterGlobal - containerLeftGlobal;

      // How much we need to scroll so that step center aligns with viewport center
      final delta = stepCenterInViewport - viewportWidth / 2;
      final targetOffset =
          (_scrollController.offset + delta)
              .clamp(0.0, _scrollController.position.maxScrollExtent);

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
    _stepKeys.clear();
    final steps = widget.steps.isEmpty ? KycStepperBar.defaultSteps : widget.steps;
    _stepKeys.addAll(List.generate(steps.length, (_) => GlobalKey()));
    _scrollToCenterActive();
  }

  @override
  void didUpdateWidget(KycStepperBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.steps.length != widget.steps.length) {
      _stepKeys
        ..clear()
        ..addAll(List.generate(
            (widget.steps.isEmpty
                    ? KycStepperBar.defaultSteps
                    : widget.steps)
                .length,
            (_) => GlobalKey()));
    }
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
            // Show real label from API (data.label) with basic formatting (capitalize words)
            final stepLabel = widget.steps.isEmpty
                ? KycStepperBar.formatLabel(list[idx])
                : KycStepperBar.formatLabel(list[idx]);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                key: _stepKeys.length > idx ? _stepKeys[idx] : null,
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
                          ? const Icon(Icons.check, size: 15, color: Colors.white)
                          : Text(
                              '${idx + 1}',
                              style: TextStyle(
                                fontSize: 12,
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
                          fontSize: 8,
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
