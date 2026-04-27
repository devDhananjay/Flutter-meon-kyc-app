import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:meon_kyc/api/workflow_lookup_api.dart';
import 'package:meon_kyc/services/storage_service.dart';

class WorkflowEntryPage extends StatefulWidget {
  const WorkflowEntryPage({super.key});

  @override
  State<WorkflowEntryPage> createState() => _WorkflowEntryPageState();
}

class _WorkflowEntryPageState extends State<WorkflowEntryPage> {
  static const Color _defaultAccent = Color(0xFF2E5BFF);
  static final RegExp _emailPattern = RegExp(
    r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
  );

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _mobileController = TextEditingController();

  bool _loading = false;
  bool _sessionCheckInProgress = true;
  WorkflowLookupResult? _lookupResult;
  WorkflowListItem? _selectedWorkflow;
  String? _error;

  /// When API omits `brand_color`, derive a stable accent from company slug so partners still feel distinct.
  Color _accentFromCompanySlug(String slug) {
    if (slug.isEmpty) return _defaultAccent;
    final hash = slug.hashCode & 0x7FFFFFFF;
    final hue = (hash % 360).toDouble();
    return HSVColor.fromAHSV(1.0, hue, 0.62, 0.88).toColor();
  }

  Color _resolveBrandPrimary() {
    final r = _lookupResult;
    if (r?.brandPrimaryArgb != null) {
      return Color(r!.brandPrimaryArgb!);
    }
    if (r != null) {
      return _accentFromCompanySlug(r.company);
    }
    return _defaultAccent;
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
    required IconData icon,
    required Color accent,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, color: const Color(0xFF6B7280)),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFDCE3F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFDCE3F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    );
  }

  ButtonStyle _ctaButtonStyle(Color background) => ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: background,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      );

  Widget _headerLogo(String? url) {
    if (url == null || url.isEmpty) {
      return const SizedBox.shrink();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 52,
        width: 52,
        color: Colors.white.withValues(alpha: 0.2),
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.business_rounded,
            color: Colors.white,
            size: 28,
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _restoreLastSessionIfAvailable();
  }

  Future<void> _restoreLastSessionIfAvailable() async {
    try {
      final hasToken = await StorageService.hasAccessToken();
      if (!hasToken) return;
      final route = await StorageService.getLastWorkflowRoute();
      if (!mounted || route == null) return;
      final company = Uri.encodeComponent(route['company']!);
      final workflowName = Uri.encodeComponent(route['workflowName']!);
      context.go('/$company/$workflowName');
    } finally {
      if (mounted) {
        setState(() => _sessionCheckInProgress = false);
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _fetchWorkflows() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
      _lookupResult = null;
      _selectedWorkflow = null;
    });

    try {
      final result =
          await WorkflowLookupApi.fetchByEmail(_emailController.text);
      if (!mounted) return;
      setState(() {
        _lookupResult = result;
        _selectedWorkflow = result.workflows.first;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _continueToKyc() async {
    if (!_formKey.currentState!.validate()) return;

    final result = _lookupResult;
    final selected = _selectedWorkflow;
    if (result == null || selected == null) return;

    final company = Uri.encodeComponent(result.company);
    final workflow = Uri.encodeComponent(selected.workflowName);
    final email = Uri.encodeQueryComponent(_emailController.text.trim());
    final mobile = Uri.encodeQueryComponent(
        _mobileController.text.replaceAll(RegExp(r'\D'), ''));
    final secret = Uri.encodeQueryComponent(result.secretKey);

    await StorageService.setLastWorkflowRoute(
      company: result.company,
      workflowName: selected.workflowName,
    );
    if (!mounted) return;

    context.go(
      '/$company/$workflow'
      '?prefillEmail=$email&prefillMobile=$mobile&ssoSecretKey=$secret',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionCheckInProgress) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final workflows = _lookupResult?.workflows ?? const <WorkflowListItem>[];
    final primary = _resolveBrandPrimary();
    final gradientEnd =
        Color.lerp(primary, Colors.white, 0.38) ?? const Color(0xFF6E8BFF);
    final partnerName = _lookupResult?.fullCompanyName?.trim();
    final hasPartnerName = partnerName != null && partnerName.isNotEmpty;
    final headerTitle = hasPartnerName ? partnerName : 'Start Your KYC';
    final logoUrl = _lookupResult?.logoUrl;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FC),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primary, gradientEnd],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(22),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (logoUrl != null && logoUrl.isNotEmpty) ...[
                          _headerLogo(logoUrl),
                          const SizedBox(width: 14),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                headerTitle,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                hasPartnerName
                                    ? 'Enter your details and pick a workflow to continue.'
                                    : 'Enter your details and choose a workflow to continue.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontSize: 14,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x14000000),
                              blurRadius: 14,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Contact Details',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _mobileController,
                              autofocus: true,
                              keyboardType: TextInputType.number,
                              maxLength: 10,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: _inputDecoration(
                                label: 'Mobile Number',
                                hint: 'Enter 10-digit mobile number',
                                icon: Icons.phone_iphone_rounded,
                                accent: primary,
                              ).copyWith(counterText: ''),
                              validator: (value) {
                                final v = (value ?? '').trim();
                                if (v.length != 10) {
                                  return 'Mobile number must be exactly 10 digits';
                                }
                                if (!RegExp(r'^\d{10}$').hasMatch(v)) {
                                  return 'Mobile number must contain only digits';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              decoration: _inputDecoration(
                                label: 'Email Address',
                                hint: 'Enter your email',
                                icon: Icons.alternate_email_rounded,
                                accent: primary,
                              ),
                              validator: (value) {
                                final email = (value ?? '').trim();
                                if (email.isEmpty) {
                                  return 'Please enter your email';
                                }
                                if (!_emailPattern.hasMatch(email)) {
                                  return 'Please enter a valid email address';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loading ? null : _fetchWorkflows,
                              style: _ctaButtonStyle(primary),
                              child: _loading
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('Get Workflows'),
                            ),
                          ],
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF1F1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFFFD2D2),
                            ),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFB3261E)),
                          ),
                        ),
                      ],
                      if (_lookupResult != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x12000000),
                                blurRadius: 14,
                                offset: Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Select Workflow',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${workflows.length} workflow(s) found',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<WorkflowListItem>(
                                initialValue: _selectedWorkflow,
                                decoration: _inputDecoration(
                                  label: 'Workflow',
                                  hint: 'Choose workflow',
                                  icon: Icons.account_tree_outlined,
                                  accent: primary,
                                ),
                                items: workflows
                                    .map(
                                      (wf) =>
                                          DropdownMenuItem<WorkflowListItem>(
                                        value: wf,
                                        child: Text(
                                          wf.workflowName,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) =>
                                    setState(() => _selectedWorkflow = value),
                              ),
                              const SizedBox(height: 14),
                              ElevatedButton.icon(
                                onPressed: _loading || _selectedWorkflow == null
                                    ? null
                                    : _continueToKyc,
                                style: _ctaButtonStyle(primary),
                                icon: const Icon(Icons.arrow_forward_rounded),
                                label: const Text('Continue'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
