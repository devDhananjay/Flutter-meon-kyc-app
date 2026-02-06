import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/documents_handy_section.dart';
import 'package:meon_kyc/components/kyc_stepper_bar.dart';

/// KYC screen layout from Figma: logo, optional stepper, content, documents section
class KycLayout extends StatelessWidget {
  final Widget child;
  final String? title;
  final List<String>? stepperSteps;
  final int? stepperIndex;
  final Widget? leading;
  final Widget? trailing;
  final bool showDocumentsSection;

  const KycLayout({
    super.key,
    required this.child,
    this.title,
    this.stepperSteps,
    this.stepperIndex,
    this.leading,
    this.trailing,
    this.showDocumentsSection = true,
  });

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: KycTheme.statusBar,
      child: Scaffold(
        backgroundColor: KycTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              // Top bar: logo (STOXBOX)
              _buildTopBar(context),
              // Stepper (Figma: Mobile Verify, Email Verify, Pan Details, etc.)
              KycStepperBar(
                steps: stepperSteps ?? KycStepperBar.defaultSteps,
                currentIndex: stepperIndex ?? 0,
              ),
              // Main content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (title != null) ...[
                          Text(
                            title!,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: KycTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        child,
                        if (showDocumentsSection) ...[
                          const SizedBox(height: 24),
                          const DocumentsHandySection(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          if (leading != null) leading!,
          Expanded(
            child: Text(
              'STOXBOX',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: KycTheme.primary,
                letterSpacing: 1.2,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
