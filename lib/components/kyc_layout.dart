import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/documents_handy_section.dart';
import 'package:meon_kyc/components/kyc_stepper_bar.dart';
import 'package:meon_kyc/utils/assets.dart';

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

  /// Builds the page title section.
  /// Special handling for the "Start your KYC" hero title from Figma:
  /// first line bold 24, second line subtitle 14.
  Widget _buildTitleSection() {
    if (title == null) return const SizedBox.shrink();

    final rawTitle = title!.trim();
    final lower = rawTitle.toLowerCase();

    final hasStartKyc = lower.contains('start your kyc');
    final hasPickupCopy = lower.contains('pickup where you left off');

    if (hasStartKyc && hasPickupCopy) {
      // Split into two lines: "Start your KYC" + "or pickup where you left off"
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Start your KYC',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: KycTheme.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'or pickup where you left off',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: KycTheme.textSecondary,
            ),
          ),
        ],
      );
    }

    // Default single-line title for all other pages
    return const Text(
      '',
      // This placeholder will be replaced below; kept here to satisfy const usage.
    );
  }

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
                // Custom hero layout for "Start your KYC", default title for others
                if (title != null && title!
                    .toLowerCase()
                    .contains('start your kyc') &&
                    title!
                        .toLowerCase()
                        .contains('pickup where you left off'))
                  _buildTitleSection()
                else
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
                    // Custom hero layout for "Start your KYC", default title for others
                    if (title != null && title!
                        .toLowerCase()
                        .contains('start your kyc') &&
                        title!
                            .toLowerCase()
                            .contains('pickup where you left off'))
                      _buildTitleSection()
                    else
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
    // Reduced vertical padding so the logo + logout bar takes less height
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Row(
      children: [
        if (leading != null) leading!,
        Expanded(
          child: Image.asset(
            AppAssets.stoxboxLogo,
            height: 24, // Slightly smaller logo to match Figma
            fit: BoxFit.contain,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

  // Widget _buildTopBar(BuildContext? context) {
  //   return Padding(
  //     padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
  //     child: Row(
  //       children: [
  //         if (leading != null) leading!,
  //         Expanded(
  //           child: Text(
  //             'STOXBOX',  
  //             // EnvConfig.companyName,
  //             textAlign: TextAlign.center,
  //             style: TextStyle(
  //               fontSize: 20,
  //               fontWeight: FontWeight.w700,
  //               color: KycTheme.primary,
  //               letterSpacing: 1.2,
  //             ),
  //           ),
  //         ),
  //         if (trailing != null) trailing!,
  //       ],
  //     ),
  //   );
  // }

  
}
