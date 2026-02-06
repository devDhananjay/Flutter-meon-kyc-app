import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// "Documents to keep Handy" section from Figma (bottom of KYC screens)
class DocumentsHandySection extends StatelessWidget {
  const DocumentsHandySection({super.key});

  static const List<({String label, IconData icon})> _items = [
    (label: 'PAN Card', icon: Icons.badge_outlined),
    (label: 'Bank Proof', icon: Icons.account_balance_outlined),
    (label: 'Income Proof', icon: Icons.receipt_long_outlined),
    (label: 'Signature', icon: Icons.draw_outlined),
    (label: 'Nominee Proof', icon: Icons.people_outline),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: KycTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KycTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Documents to keep Handy',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: KycTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: _items.map((e) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 18,
                    color: KycTheme.success,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    e.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: KycTheme.textSecondary,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
