import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Trading segments selection UI as per design.
/// BugFixes: grid shows only NSE/BSE cash, FO, SLBM, MF (no MTF / currency columns) —
/// submit payload matches via [HomePage] `_prepareFormData` (mtf/currency false).
class SegmentsSelection extends StatelessWidget {
  final Map<String, dynamic> formData;
  final void Function(String name, dynamic value) onChange;
  final VoidCallback? onViewBrokeragePlan;
  final VoidCallback? onSubmit;
  final bool submitLoading;

  const SegmentsSelection({
    super.key,
    required this.formData,
    required this.onChange,
    this.onViewBrokeragePlan,
    this.onSubmit,
    this.submitLoading = false,
  });

  bool _getValue(String key) {
    final val = formData[key];
    if (val == null) return false;
    if (val is bool) return val;
    final str = val.toString().toLowerCase();
    return str == 'true' || str == '1' || str == 'yes';
  }

  static const _linkBlue = Color(0xFF2563EB);

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
                    onChanged: (v) => onChange(pair[0].key, v),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildCheckbox(
                    label: pair[1].label,
                    value: _getValue(pair[1].key),
                    onChanged: (v) => onChange(pair[1].key, v),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        if (onViewBrokeragePlan != null) ...[
          Center(
            child: TextButton(
              onPressed: onViewBrokeragePlan,
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
          const Center(
            child: Text(
              'Default Brokerage plan applied',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: KycTheme.success,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ] else
          const SizedBox(height: 16),
        
        // Next/Submit button
        if (onSubmit != null)
          ElevatedButton(
            onPressed: submitLoading ? null : onSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: KycTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: submitLoading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Next',
                    style: TextStyle(
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
