import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Temporary manual mobile/email for [SsoAPI.getSsoRouteTokens].
///
/// **Later (dynamic / remove UI):** set [kSsoUseTempCredentialDialog] to `false`
/// and either update [kSsoStaticFallbackCredentials] or change
/// [resolveSsoCredentialsForSsoApi] to return values from your source.
/// You can delete this file once wired and remove the import + call from
/// `home_page.dart` `_trySsoLoginIfNeeded`.
const bool kSsoUseTempCredentialDialog = true;

/// Used when [kSsoUseTempCredentialDialog] is `false` (no dialog).
const SsoCredentials kSsoStaticFallbackCredentials = SsoCredentials(
  mobileNumber: '9411441937',
  email: 'dhananjay@meon.co.in',
);

class SsoCredentials {
  final String mobileNumber;
  final String email;

  const SsoCredentials({
    required this.mobileNumber,
    required this.email,
  });
}

/// Returns credentials for SSO API, or `null` if the user dismisses the temp dialog.
Future<SsoCredentials?> resolveSsoCredentialsForSsoApi(
  BuildContext context,
) async {
  if (!kSsoUseTempCredentialDialog) {
    return kSsoStaticFallbackCredentials;
  }
  if (!context.mounted) return null;
  return showSsoTempCredentialDialog(context);
}

Future<SsoCredentials?> showSsoTempCredentialDialog(BuildContext context) {
  return showDialog<SsoCredentials>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    builder: (ctx) => const _SsoTempCredentialDialog(),
  );
}

class _SsoTempCredentialDialog extends StatefulWidget {
  const _SsoTempCredentialDialog();

  @override
  State<_SsoTempCredentialDialog> createState() =>
      _SsoTempCredentialDialogState();
}

class _SsoTempCredentialDialogState extends State<_SsoTempCredentialDialog> {
  late final TextEditingController _mobileCtrl;
  late final TextEditingController _emailCtrl;

  @override
  void initState() {
    super.initState();
    _mobileCtrl = TextEditingController();
    _emailCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _mobileCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final mobile = _mobileCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    if (mobile.isEmpty || email.isEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Please enter both mobile and email'),
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(
      SsoCredentials(mobileNumber: mobile, email: email),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('SSO (temporary)'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Enter mobile and email for get_sso_route. Remove this dialog later via lib/sso/sso_temp_credentials_gate.dart.',
              style: TextStyle(
                fontSize: KycTheme.fontSizeCaption,
                color: KycTheme.textSecondary,
              ),
            ),
            const SizedBox(height: KycTheme.spacingLg),
            TextField(
              controller: _mobileCtrl,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: KycTheme.spacingMd),
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
