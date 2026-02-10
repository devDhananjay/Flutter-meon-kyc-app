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
  final bool skipScaffold; // When true, skip Scaffold/SafeArea (for nested use)

  const KycLayout({
    super.key,
    required this.child,
    this.title,
    this.stepperSteps,
    this.stepperIndex,
    this.leading,
    this.trailing,
    this.showDocumentsSection = true,
    this.skipScaffold = false,
  });

  Widget _buildContent() {
    if (skipScaffold) {
      // When skipping scaffold, return scrollable content directly (no Expanded)
      // This prevents overflow when used inside Expanded widget
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top bar: logo (STOXBOX) - always show (has logo and leading/trailing buttons)
              _buildTopBar(null),
              if (title != null) ...[
                const SizedBox(height: 16),
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
      );
    }
    
    // Default: full layout with Expanded
    return Column(
      children: [
        // Top bar: logo (STOXBOX) - always show (has logo and leading/trailing buttons)
        _buildTopBar(null),
        // Stepper (only show if stepperSteps is provided)
        if (stepperSteps != null)
          KycStepperBar(
            steps: stepperSteps!,
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
                mainAxisSize: MainAxisSize.min,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    
    if (skipScaffold) {
      // When skipping scaffold, just return content (for nested use)
      return content;
    }
    
    // Default: wrap in Scaffold and SafeArea
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: KycTheme.statusBar,
      child: Scaffold(
        backgroundColor: KycTheme.background,
        body: SafeArea(
          child: content,
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext? context) {
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
