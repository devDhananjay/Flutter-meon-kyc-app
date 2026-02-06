import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Trading segments selection UI as per design
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Select your trading preferences.',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: KycTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 24),
        
        // NSE Section
        _buildExchangeSection(
          'NSE',
          [
            _CheckboxItem(label: 'Cash', key: 'nse_cash'),
            _CheckboxItem(label: 'FO', key: 'nse_fo'),
            _CheckboxItem(label: 'Currency', key: 'nse_currency'),
            _CheckboxItem(label: 'SLBM', key: 'nse_slbm'),
          ],
          context,
        ),
        const SizedBox(height: 20),
        
        // BSE Section
        _buildExchangeSection(
          'BSE',
          [
            _CheckboxItem(label: 'Cash', key: 'bse_cash'),
            _CheckboxItem(label: 'FO', key: 'bse_fo'),
            _CheckboxItem(label: 'Currency', key: 'bse_currency'),
            _CheckboxItem(label: 'SLBM', key: 'bse_slbm'),
          ],
          context,
        ),
        const SizedBox(height: 20),
        
        // MF & MTF Row
        Row(
          children: [
            Expanded(
              child: _buildCheckbox(
                label: 'MF',
                value: _getValue('mf'),
                onChanged: (v) => onChange('mf', v),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildCheckbox(
                label: 'MTF',
                value: _getValue('mtf'),
                onChanged: (v) => onChange('mtf', v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        
        // View Brokerage plan button
        if (onViewBrokeragePlan != null)
          OutlinedButton(
            onPressed: onViewBrokeragePlan,
            style: OutlinedButton.styleFrom(
              foregroundColor: KycTheme.primary,
              side: const BorderSide(color: KycTheme.primary, width: 2),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'View Brokerage plan',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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

  Widget _buildExchangeSection(String title, List<_CheckboxItem> items, BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: KycTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: items.map((item) {
            return SizedBox(
              width: (MediaQuery.of(context).size.width - 72) / 2,
              child: _buildCheckbox(
                label: item.label,
                value: _getValue(item.key),
                onChanged: (v) => onChange(item.key, v),
              ),
            );
          }).toList(),
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: value ? KycTheme.primary : KycTheme.border,
            width: value ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          color: value ? KycTheme.primary.withOpacity(0.05) : Colors.transparent,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: value ? KycTheme.primary : Colors.transparent,
                border: Border.all(
                  color: value ? KycTheme.primary : KycTheme.border,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: value
                  ? const Icon(
                      Icons.check,
                      size: 14,
                      color: Colors.white,
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: value ? FontWeight.w600 : FontWeight.w500,
                color: value ? KycTheme.primary : KycTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckboxItem {
  final String label;
  final String key;

  _CheckboxItem({required this.label, required this.key});
}
