import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Trading segments selection UI as per design.
/// BugFixes: grid shows only NSE/BSE cash, FO, SLBM, MF (no MTF / currency columns) —
/// submit payload matches via [HomePage] `_prepareFormData` (mtf/currency false).
///
/// UX: when user toggles NSE FO / BSE FO from OFF -> ON, show a one-time
/// reminder modal listing the financial documents required to enable FO.
///
/// Brokerage Plan: User must view/select a brokerage plan before proceeding.
/// Shows "Please select brokerage plan" until user clicks "View Brokerage Plan".
/// After viewing, shows "Brokerage plan selected" confirmation.
class SegmentsSelection extends StatefulWidget {
  final Map<String, dynamic> formData;
  final void Function(String name, dynamic value) onChange;
  final VoidCallback? onViewBrokeragePlan;
  final VoidCallback? onSubmit;
  final bool submitLoading;
  /// Whether the user has viewed/selected the brokerage plan
  final bool hasBrokeragePlanSelected;

  const SegmentsSelection({
    super.key,
    required this.formData,
    required this.onChange,
    this.onViewBrokeragePlan,
    this.onSubmit,
    this.submitLoading = false,
    this.hasBrokeragePlanSelected = false,
  });

  @override
  State<SegmentsSelection> createState() => _SegmentsSelectionState();
}

class _SegmentsSelectionState extends State<SegmentsSelection> {
  static const Set<String> _foKeys = {'nse_fo', 'bse_fo'};
  static const _linkBlue = Color(0xFF2563EB);

  bool _getValue(String key) {
    final val = widget.formData[key];
    if (val == null) return false;
    if (val is bool) return val;
    final str = val.toString().toLowerCase();
    return str == 'true' || str == '1' || str == 'yes';
  }

  bool _coerceBool(dynamic value) {
    if (value is bool) return value;
    if (value == null) return false;
    final str = value.toString().toLowerCase();
    return str == 'true' || str == '1' || str == 'yes';
  }

  void _handleSegmentChange(String name, dynamic value) {
    final wasEnabled = _getValue(name);
    final willEnable = _coerceBool(value);

    widget.onChange(name, value);

    // OFF -> ON transition on NSE FO / BSE FO: show financial documents reminder.
    if (_foKeys.contains(name) && !wasEnabled && willEnable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showFoFinancialDocsModal();
      });
    }
  }

  Future<void> _showFoFinancialDocsModal() {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Please upload any one of the following financial '
                  'documents (required only if selected):',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.textPrimary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                const _FoDocBullet(text: 'Last 6 months bank statement'),
                const _FoDocBullet(
                    text: 'Latest Income Tax Return (ITR) acknowledgement'),
                const _FoDocBullet(
                    text: 'Form 16 or salary slips for the last 3 months'),
                const _FoDocBullet(text: 'CA-certified Net Worth Certificate'),
                const _FoDocBullet(text: 'Latest Demat Holding Statement'),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KycTheme.buttonEnabledPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'OK',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const segmentRows = <List<_CheckboxItem>>[
      [
        _CheckboxItem(label: 'NSE CASH', key: 'nse_cash'),
        _CheckboxItem(label: 'BSE CASH', key: 'bse_cash'),
      ],
      [
        _CheckboxItem(label: 'NSE FO', key: 'nse_fo'),
        _CheckboxItem(label: 'BSE FO', key: 'bse_fo'),
      ],
      [
        _CheckboxItem(label: 'NSE SLBM', key: 'nse_slbm'),
        _CheckboxItem(label: 'MF', key: 'mf'),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: Text(
            'Select Your Preferred\nSegments',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: KycTheme.textPrimary,
              height: 1.25,
            ),
          ),
        ),
        const SizedBox(height: 24),
        ...segmentRows.map((pair) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildCheckbox(
                    label: pair[0].label,
                    value: _getValue(pair[0].key),
                    onChanged: (v) => _handleSegmentChange(pair[0].key, v),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildCheckbox(
                    label: pair[1].label,
                    value: _getValue(pair[1].key),
                    onChanged: (v) => _handleSegmentChange(pair[1].key, v),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        if (widget.onViewBrokeragePlan != null) ...[
          Center(
            child: TextButton(
              onPressed: widget.onViewBrokeragePlan,
              style: TextButton.styleFrom(
                foregroundColor: _linkBlue,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'View Brokerage Plan',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: _linkBlue,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              widget.hasBrokeragePlanSelected
                  ? 'Brokerage plan applied'
                  : 'Please select brokerage plan',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: widget.hasBrokeragePlanSelected 
                    ? KycTheme.success 
                    : const Color(0xFFDC2626), // Red color for warning
              ),
            ),
          ),
          const SizedBox(height: 24),
        ] else
          const SizedBox(height: 16),

        if (widget.onSubmit != null)
          ElevatedButton(
            onPressed: (widget.submitLoading || 
                       (widget.onViewBrokeragePlan != null && !widget.hasBrokeragePlanSelected))
                ? null 
                : widget.onSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: KycTheme.primary,
              disabledBackgroundColor: KycTheme.primary.withValues(alpha: 0.5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: widget.submitLoading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    widget.hasBrokeragePlanSelected || widget.onViewBrokeragePlan == null
                        ? 'Next'
                        : 'Select Plan to Continue',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
      ],
    );
  }

  Widget _buildCheckbox({
    required String label,
    required bool value,
    required void Function(bool) onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: value ? KycTheme.buttonEnabledPurple : Colors.transparent,
              border: Border.all(
                color: KycTheme.buttonEnabledPurple,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: value
                ? const Icon(
                    Icons.check,
                    size: 12,
                    color: Colors.white,
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: KycTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckboxItem {
  final String label;
  final String key;

  const _CheckboxItem({required this.label, required this.key});
}

class _FoDocBullet extends StatelessWidget {
  final String text;
  const _FoDocBullet({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: 10, left: 4),
            child: SizedBox(
              width: 5,
              height: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: KycTheme.textPrimary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: KycTheme.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
