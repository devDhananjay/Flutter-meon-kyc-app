import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:meon_kyc/firebase_options.dart';
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/api/kyc_api.dart';
import 'package:meon_kyc/api/sso_api.dart';
import 'package:meon_kyc/components/form_field_widget.dart';
import 'package:meon_kyc/components/kyc_layout.dart';
import 'package:meon_kyc/components/kyc_stepper_bar.dart';
import 'package:meon_kyc/components/kyc_note_box.dart';
import 'package:meon_kyc/components/loader.dart';
import 'package:meon_kyc/components/otp_verify_section.dart';
import 'package:meon_kyc/components/segments_selection.dart';
import 'package:meon_kyc/components/brokerage_plan_dialog.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/hooks/conditional_form.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:flutter/gestures.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:url_launcher/url_launcher.dart';

class HomePage extends StatefulWidget {
  final String company;
  final String workflowName;
  final Map<String, String> queryParams;
  final String? prefillMobile;
  final String? prefillEmail;
  final String? ssoSecretKey;

  const HomePage({
    super.key,
    required this.company,
    required this.workflowName,
    this.queryParams = const {},
    this.prefillMobile,
    this.prefillEmail,
    this.ssoSecretKey,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ConditionalFormNotifier _formNotifier;
  bool _submitLoading = false;
  bool _webViewTransitionActive = false;
  bool _logoutLoading = false;
  // Non-null when an API call fails while we're returning from WebView.
  // Triggers the retry UI instead of the old step's form UI.
  String? _webViewReturnError;
  // True while _loadWorkflow() is actively running — prevents concurrent calls.
  bool _loadWorkflowActive = false;
  // Message shown in the partial loader during WebView return flow.
  String _returnFlowMessage = 'Loading your next step...';
  // One-shot timers: 5 s → slow-network message, 12 s → show retry UI.
  Timer? _returnFlowWatchdogTimer;
  // 5 s periodic: auto-retries _loadWorkflow() if stuck with no active call.
  Timer? _returnFlowPollingTimer;
  bool _refreshLoading = false;
  bool _backLoading = false;
  String _submitError = '';
  String _submitSuccess = '';
  bool _termsAccepted = false; // Terms & Conditions checkbox (mobile step)
  bool _showTermsError = false; // Show validation message under T&C checkbox
  bool _showMobileError =
      false; // Show error below mobile input when invalid on submit
  bool _googleSignInLoading = false;

  // One-shot guard: if we already attempted SSO for this widget instance,
  // don't retry on rebuild.
  bool _ssoAttempted = false;
  bool _ssoInProgress = false;

  /// Kept across `_formNotifier.resetForm()` inside `_handleSubmitResponse` so `mobile_otp`
  /// resend + header text still know the number (get-context fields often omit it).
  String? _persistedMobileDigitsForOtp;
  String? _persistedEmailForOtp;

  @override
  void initState() {
    super.initState();
    _formNotifier = ConditionalFormNotifier(fields: [], conditionalFlow: []);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWorkflow());
  }

  @override
  void dispose() {
    _returnFlowWatchdogTimer?.cancel();
    _returnFlowPollingTimer?.cancel();
    super.dispose();
  }

  // ---------- Return-flow timer helpers ----------

  /// Starts a two-stage watchdog (5 s → slow-network msg, 12 s → retry UI)
  /// and a background 5-second polling timer that auto-retries when not active.
  void _startReturnFlowTimers() {
    _returnFlowWatchdogTimer?.cancel();
    _returnFlowPollingTimer?.cancel();

    // Stage 1 – 5 seconds: update loading message
    _returnFlowWatchdogTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _returnFlowMessage =
          'This is taking longer than usual, please wait...');
      debugPrint('[HomePage] Return-flow: slow-network message shown');

      // Stage 2 – 7 more seconds (12 s total): show retry UI
      _returnFlowWatchdogTimer = Timer(const Duration(seconds: 7), () {
        if (!mounted) return;
        final store = context.read<AppStore>();
        if (store.isReturningFromWebView && _webViewReturnError == null) {
          debugPrint(
              '[HomePage] Return-flow watchdog fired — showing retry UI');
          setState(() {
            _webViewReturnError =
                'Connection is taking too long. Please check your network and try again.';
            _returnFlowMessage = 'Loading your next step...';
          });
        }
      });
    });

    // Background poll every 5 seconds: auto-retry if no active call and still stuck
    _returnFlowPollingTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final store = context.read<AppStore>();
      if (!store.isReturningFromWebView) {
        timer.cancel();
        _returnFlowPollingTimer = null;
        return;
      }
      if (!_loadWorkflowActive) {
        debugPrint(
            '[HomePage] Return-flow polling: auto-retrying (no active call, still returning)');
        store.clearAuthError();
        if (_webViewReturnError != null) {
          setState(() {
            _webViewReturnError = null;
            _returnFlowMessage = 'Loading your next step...';
          });
        }
        _loadWorkflow();
      }
    });
  }

  void _stopReturnFlowTimers() {
    _returnFlowWatchdogTimer?.cancel();
    _returnFlowWatchdogTimer = null;
    _returnFlowPollingTimer?.cancel();
    _returnFlowPollingTimer = null;
  }

  // ------------------------------------------------
  Future<bool> _trySsoLoginIfNeeded(AppStore store) async {
    if (_ssoAttempted || _ssoInProgress) return _ssoAttempted;

    _ssoInProgress = true;
    try {
      final mobileNumber =
          (widget.prefillMobile ?? '').replaceAll(RegExp(r'\D'), '');
      final email = (widget.prefillEmail ?? '').trim();
      if (mobileNumber.length != 10 || !email.contains('@')) {
        debugPrint(
            '[HomePage] SSO skipped: invalid prefill values (mobileLen=${mobileNumber.length}, email=$email)');
        return false;
      }

      debugPrint('[HomePage] No access token - attempting SSO login...');
      final tokens = await SsoAPI.getSsoRouteTokens(
        company: widget.company,
        workflowName: widget.workflowName,
        mobileNumber: mobileNumber,
        email: email,
        secretKey: widget.ssoSecretKey,
      );

      if (tokens == null) {
        debugPrint('[HomePage] SSO token fetch failed - fallback to OTP flow');
        return false;
      }

      await StorageService.setAccessToken(tokens.accessToken);
      await StorageService.setRefreshToken(tokens.refreshToken);
      await StorageService.setAuthSuccess('true');

      // Safety fallback in case backend still returns an OTP step.
      _persistedMobileDigitsForOtp = mobileNumber;
      _persistedEmailForOtp = email;

      store.clearAuthError();
      debugPrint('[HomePage] SSO tokens stored successfully');
      // Give backend a moment to persist session before first get-context (avoids intermittent 500).
      await Future.delayed(const Duration(milliseconds: 600));
      return true;
    } catch (e, st) {
      debugPrint('[HomePage] SSO login exception: $e\n$st');
      return false;
    } finally {
      _ssoInProgress = false;
      _ssoAttempted = true;
    }
  }

  Future<void> _loadWorkflow() async {
    // Prevent concurrent calls — a second call while one is in flight is a no-op.
    if (_loadWorkflowActive) {
      debugPrint(
          '[HomePage] _loadWorkflow already running, skipping duplicate call');
      return;
    }
    if (!mounted) return;
    setState(() => _loadWorkflowActive = true);

    debugPrint(
        '[HomePage] _loadWorkflow START: ${widget.company} / ${widget.workflowName}');
    debugPrint('[HomePage] _loadWorkflow queryParams: ${widget.queryParams}');
    final store = context.read<AppStore>();
    // Tracks whether we navigated away inside this call so the finally block
    // knows not to prematurely clear isReturningFromWebView.
    bool navigatingAway = false;

    // Start watchdog + polling timers only when in the WebView return flow.
    if (store.isReturningFromWebView) _startReturnFlowTimers();

    try {
      store.setParams(
          company: widget.company, workflowName: widget.workflowName);
      bool hasToken = await StorageService.hasAccessToken();
      debugPrint('[HomePage] _loadWorkflow hasToken=$hasToken');

      // Auto-SSO on fresh HomePage load when enabled (e.g. after Start KYC with prefill).
      // Skip when returning from WebView (keep current token).
      final shouldTrySso = !_ssoAttempted &&
          StorageService.ssoAutoLoginEnabled &&
          !store.isReturningFromWebView;
      if (shouldTrySso) {
        debugPrint(
            '[HomePage] First-load: forcing SSO attempt (hasToken=$hasToken)');
        if (mounted) setState(() => _submitLoading = true);
        final ssoOk = await _trySsoLoginIfNeeded(store);
        if (mounted) setState(() => _submitLoading = false);
        hasToken = hasToken || ssoOk;
      } else if (!_ssoAttempted) {
        debugPrint(
            '[HomePage] Skipping auto-SSO (returnFromWebView=${store.isReturningFromWebView}, ssoAutoEnabled=${StorageService.ssoAutoLoginEnabled})');
        _ssoAttempted = true;
      }

      if (hasToken) {
        // Build query string from redirect params (state, client_token, auto)
        final queryString = widget.queryParams.isEmpty
            ? ''
            : '?${widget.queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';

        await store.fetchWorkflowFieldsWithAuth(
          widget.company,
          widget.workflowName,
          queryString,
        );

        // Extract workflowId from design_template (format: "company-workflowId-number")
        // Example: "mandotsecurities-2321998632-76" -> workflowId = "2321998632"
        String? workflowId;
        final response = store.fieldsWithAuth;
        if (response is Map) {
          final context = response['context'] as Map<String, dynamic>?;
          final designTemplate = context?['design_template']?.toString();
          if (designTemplate != null && designTemplate.contains('-')) {
            final parts = designTemplate.split('-');
            if (parts.length >= 2) {
              workflowId = parts[1]; // Second part is workflowId
              debugPrint(
                  '[HomePage] Extracted workflowId from design_template: $workflowId');
            }
          }

          // Also try extracting from user details if available
          if (workflowId == null || workflowId.isEmpty) {
            // Will be fetched later if needed
          }
        }

        // Fetch stepper workflow if we have workflowId
        if (workflowId != null && workflowId.isNotEmpty) {
          debugPrint(
              '[HomePage] Fetching stepper workflow: ${widget.workflowName} / $workflowId');
          // Backend route: /kycadmin_getWorkflow/{workflowName}/{workflowId}
          await store.fetchStepperWorkflow(widget.workflowName, workflowId);
        }

        // Check if KYC is completed (is_admin: true)
        if (response is Map && response['is_admin'] == true) {
          debugPrint(
              '[HomePage] KYC completed (is_admin: true) - fetching user details');
          await store.fetchUserDetails();
          if (mounted && store.userDetails != null) {
            // Stepper workflow already fetched above (if workflowId was available)
            // Navigate to KYC Completed page
            navigatingAway = true;
            context.go('/${widget.company}/${widget.workflowName}/completed');
            return;
          } else if (mounted && store.errorUserDetails != null) {
            debugPrint(
                '[HomePage] Error fetching user details: ${store.errorUserDetails}');
            Fluttertoast.showToast(
                msg: 'Error loading completion details',
                gravity: ToastGravity.TOP);
          }
        }

        // Check for redirect after get-context
        // Skip redirect if step completion params present (IPV, RPD, eSign, DigiLocker, etc.)
        // Prevents infinite loop when backend returns redirect despite completed step
        final hasCompletionParams = widget.queryParams['success'] == 'yes' ||
            widget.queryParams['verifyCompleted'] == 'true' ||
            widget.queryParams['esign'] == 'yes' ||
            widget.queryParams.containsKey('transaction_id') ||
            widget.queryParams.containsKey('reversepennydrop') ||
            widget.queryParams.containsKey('reverse_pennydrop') ||
            widget.queryParams.containsKey('account_aggregator');
        if (mounted && !hasCompletionParams) {
          await _checkAndHandleRedirect(store);
          // If _checkAndHandleRedirect navigated to WebView, mounted will be false
          if (!mounted) navigatingAway = true;
        } else if (hasCompletionParams) {
          debugPrint(
              '[HomePage] Step completed (success/transaction_id/esign) - refreshing context to get updated state');

          // Refresh context without completion params to get updated state and check for redirects
          // This ensures user moves to next step after IPV/RPD/eSign completion
          await store.fetchWorkflowFieldsWithAuth(
            widget.company,
            widget.workflowName,
            '', // Call without completion params to get fresh state
          );

          // Some flows can trigger multiple get-context calls back-to-back (WebView close + route rebuild).
          // Avoid blocking progress just because `errorWithAuth` was set by an earlier call while the latest
          // `fieldsWithAuth` succeeded.
          var refreshed = store.fieldsWithAuth;
          if (mounted && refreshed is! Map) {
            final err = (store.errorWithAuth ?? '').toString();
            final shouldRetryMultipleTabs =
                err.toLowerCase().contains('multiple tabs');

            if (shouldRetryMultipleTabs) {
              debugPrint(
                  '[HomePage] get-context failed due to multiple tabs - retrying once...');
              await Future.delayed(const Duration(milliseconds: 800));
              await store.fetchWorkflowFieldsWithAuth(
                widget.company,
                widget.workflowName,
                '', // Retry without completion params
              );
              refreshed = store.fieldsWithAuth;
            }

            if (mounted && refreshed is! Map) {
              debugPrint(
                  '[HomePage] Error refreshing context after step completion: ${store.errorWithAuth ?? "fieldsWithAuth not a Map"}');
              if (store.isReturningFromWebView) {
                // Show retry UI — never fall back to the old step's form
                setState(() => _webViewReturnError = store.errorWithAuth ??
                    'Something went wrong, please try again.');
              } else {
                Fluttertoast.showToast(
                  msg: store.errorWithAuth ?? 'Error refreshing page',
                  gravity: ToastGravity.TOP,
                );
              }
              return;
            }
          }

          // Check if KYC is completed (is_admin: true)
          if (refreshed is Map && refreshed['is_admin'] == true) {
            debugPrint(
                '[HomePage] KYC completed (is_admin: true) - fetching user details');
            await store.fetchUserDetails();
            if (mounted && store.userDetails != null) {
              navigatingAway = true;
              context.go('/${widget.company}/${widget.workflowName}/completed');
              return;
            } else if (mounted && store.errorUserDetails != null) {
              debugPrint(
                  '[HomePage] Error fetching user details: ${store.errorUserDetails}');
              if (store.isReturningFromWebView) {
                setState(() => _webViewReturnError =
                    'Error loading completion details. Please try again.');
              } else {
                Fluttertoast.showToast(
                    msg: 'Error loading completion details',
                    gravity: ToastGravity.TOP);
              }
              return;
            }
          }

          // After refreshing context, check for redirects (backend may redirect to next step)
          if (mounted) {
            await _checkAndHandleRedirect(store);
            if (!mounted) navigatingAway = true;
            // If no redirect, navigate to refresh the page with updated data
            if (mounted) {
              final response = store.fieldsWithAuth;
              if (response is! Map || response['redirect'] != true) {
                debugPrint(
                    '[HomePage] Navigating to refresh page after step completion');
                navigatingAway = true;
                context.go('/${widget.company}/${widget.workflowName}');
              }
            }
          }
        }
      } else {
        await store.fetchWorkflowFields(widget.company, widget.workflowName);
      }
      debugPrint('[HomePage] _loadWorkflow DONE, store.error=${store.error}');
    } finally {
      // Cancel the one-shot watchdog (polling timer keeps running until the flag clears).
      _returnFlowWatchdogTimer?.cancel();
      _returnFlowWatchdogTimer = null;

      if (mounted) setState(() => _loadWorkflowActive = false);

      // Clear isReturningFromWebView only when we stayed on this page (no route
      // change happened) and there is no pending retry error to display.
      if (mounted &&
          !navigatingAway &&
          store.isReturningFromWebView &&
          _webViewReturnError == null) {
        store.setReturningFromWebView(false);
        _stopReturnFlowTimers();
      }
    }
  }

  Future<void> _checkAndHandleRedirect(AppStore store) async {
    final response = store.fieldsWithAuth;
    if (response is Map) {
      final shouldRedirect = response['redirect'] == true;
      final redirectUrl = response['url']?.toString();
      final msg = response['msg']?.toString() ?? '';

      // Check if already processed
      final alreadyHasVerifyParam = widget.queryParams.containsKey('verify') ||
          widget.queryParams.containsKey('verifyCompleted');

      if (shouldRedirect && redirectUrl != null && redirectUrl.isNotEmpty) {
        // SPECIAL CASE: "redirect on verify is true" - call get-context API (no WebView)
        if (msg == 'redirect on verify is true') {
          if (alreadyHasVerifyParam) {
            debugPrint(
                '[HomePage] Skipping verify API redirect - already processed');
            return;
          }

          // Extract query params from URL (e.g., verify=digilocker)
          final uri = Uri.tryParse(redirectUrl);
          if (uri != null) {
            // Build query string with verify param
            final queryString = uri.query; // This is "verify=digilocker"
            final lowerHost = uri.host.toLowerCase();
            final lowerPath = uri.path.toLowerCase();
            final isIpvOrFace = lowerHost.contains('ipv') ||
                lowerPath.contains('/ipv/') ||
                lowerPath.contains('face') ||
                lowerPath.contains('facefinder') ||
                lowerHost.contains('face');

            debugPrint(
                '[HomePage] Special case: "redirect on verify is true" - calling get-context API');
            debugPrint('[HomePage] Extracted query from URL: $queryString');

            // Call get-context API with verify param
            setState(() => _submitLoading = true);
            await store.fetchWorkflowFieldsWithAuth(
              widget.company,
              widget.workflowName,
              queryString.isEmpty ? '' : '?$queryString',
            );
            setState(() => _submitLoading = false);

            // Check for errors
            if (store.errorWithAuth != null) {
              debugPrint(
                  '[HomePage] Error after verify get-context: ${store.errorWithAuth}');
              Fluttertoast.showToast(
                  msg: store.errorWithAuth ?? 'Error',
                  gravity: ToastGravity.TOP);
            } else {
              debugPrint(
                  '[HomePage] Verify get-context completed successfully - data loaded in app');
            }

            // IPV/Face KYC case:
            // Backend provides a direct return URL (often with EMPTY query params).
            // In that scenario, we must open WebView automatically; otherwise user gets stuck on the non-IPV screen.
            if (isIpvOrFace && queryString.isEmpty && mounted) {
              final ensuredRedirectUrl = _forceHttpsForRpd(redirectUrl);
              final friendlyTitle =
                  _deriveWebViewTitle(msg, ensuredRedirectUrl);
              debugPrint(
                  '[HomePage] Auto-opening WebView for IPV/Face after verify reload: $redirectUrl');
              await _openWebViewWithTransitionLoader(
                  ensuredRedirectUrl, friendlyTitle);
              return;
            }

            // If backend after verify-reload asks to redirect to some external page (often IPV),
            // handle it now. Otherwise user gets stuck until manual reload.
            final refreshed = store.fieldsWithAuth;
            if (refreshed is Map &&
                refreshed['redirect'] == true &&
                (refreshed['url']?.toString().isNotEmpty ?? false)) {
              final refreshedRedirectUrl = refreshed['url']!.toString();
              final refreshedMsg = refreshed['msg']?.toString() ?? msg;

              String refreshedFinalUrl;
              if (refreshedRedirectUrl.startsWith('http://') ||
                  refreshedRedirectUrl.startsWith('https://')) {
                refreshedFinalUrl = refreshedRedirectUrl;
              } else {
                // Relative URL - prepend baseUrl and preserve query params
                var relativeUrl = refreshedRedirectUrl.startsWith('/')
                    ? refreshedRedirectUrl
                    : '/$refreshedRedirectUrl';

                if (widget.queryParams.isNotEmpty &&
                    !relativeUrl.contains('state')) {
                  final separator = relativeUrl.contains('?') ? '&' : '?';
                  final preservedParams = widget.queryParams.entries
                      .where((e) => e.key != 'verifyCompleted')
                      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                      .join('&');
                  if (preservedParams.isNotEmpty) {
                    relativeUrl = '$relativeUrl$separator$preservedParams';
                  }
                }

                refreshedFinalUrl = '${EnvConfig.baseUrl}$relativeUrl';
              }

              refreshedFinalUrl = _forceHttpsForRpd(refreshedFinalUrl);
              final friendlyTitle =
                  _deriveWebViewTitle(refreshedMsg, refreshedFinalUrl);
              debugPrint(
                  '[HomePage] Opening WebView after verify reload (refreshed redirect): $refreshedFinalUrl');
              await _openWebViewWithTransitionLoader(
                  refreshedFinalUrl, friendlyTitle);
              return;
            }

            return; // Don't open WebView for other verify modes (e.g. digilocker handled by backend via fields)
          }
        }

        // For all OTHER redirects - open WebView (like DigiLocker)
        // But if backend returns internal workflow path first (e.g. /bpwealth/individual),
        // do not open that URL in WebView. Refresh context once and open only external URL.
        final lowerRedirect = redirectUrl.toLowerCase();
        final internalWorkflowPath =
            '/${widget.company.toLowerCase()}/${widget.workflowName.toLowerCase()}';
        final looksInternalWorkflowRedirect =
            lowerRedirect == internalWorkflowPath ||
                lowerRedirect == '${internalWorkflowPath}/' ||
                lowerRedirect.startsWith('$internalWorkflowPath?');
        if (looksInternalWorkflowRedirect) {
          debugPrint(
              '[HomePage] Internal workflow redirect received - refreshing context once instead of opening WebView: $redirectUrl');
          await store.fetchWorkflowFieldsWithAuth(
              widget.company, widget.workflowName, '');
          final refreshed = store.fieldsWithAuth;
          if (refreshed is Map &&
              refreshed['redirect'] == true &&
              (refreshed['url']?.toString().isNotEmpty ?? false)) {
            final nextRedirectUrl = refreshed['url']!.toString();
            final refreshedMsg = refreshed['msg']?.toString() ?? msg;
            final nextLower = nextRedirectUrl.toLowerCase();
            final stillInternal = nextLower == internalWorkflowPath ||
                nextLower == '${internalWorkflowPath}/' ||
                nextLower.startsWith('$internalWorkflowPath?');
            if (stillInternal) {
              debugPrint(
                  '[HomePage] Refreshed redirect is still internal workflow URL - staying in app flow');
              return;
            }

            String refreshedFinalUrl;
            if (nextRedirectUrl.startsWith('http://') ||
                nextRedirectUrl.startsWith('https://')) {
              refreshedFinalUrl = nextRedirectUrl;
            } else {
              var relativeUrl = nextRedirectUrl.startsWith('/')
                  ? nextRedirectUrl
                  : '/$nextRedirectUrl';
              if (widget.queryParams.isNotEmpty &&
                  !relativeUrl.contains('state')) {
                final separator = relativeUrl.contains('?') ? '&' : '?';
                final preservedParams = widget.queryParams.entries
                    .where((e) => e.key != 'verifyCompleted')
                    .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                    .join('&');
                if (preservedParams.isNotEmpty) {
                  relativeUrl = '$relativeUrl$separator$preservedParams';
                }
              }
              refreshedFinalUrl = '${EnvConfig.baseUrl}$relativeUrl';
            }

            refreshedFinalUrl = _forceHttpsForRpd(refreshedFinalUrl);
            final friendlyTitle =
                _deriveWebViewTitle(refreshedMsg, refreshedFinalUrl);
            debugPrint(
                '[HomePage] Opening WebView after internal-redirect refresh: $refreshedFinalUrl');
            await _openWebViewWithTransitionLoader(
                refreshedFinalUrl, friendlyTitle);
          }
          return;
        }

        String finalUrl;
        if (redirectUrl.startsWith('http://') ||
            redirectUrl.startsWith('https://')) {
          finalUrl = redirectUrl;
        } else {
          // Relative URL - prepend baseUrl and preserve query params
          var relativeUrl =
              redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl';

          // Append existing query params if not already present
          if (widget.queryParams.isNotEmpty && !relativeUrl.contains('state')) {
            final separator = relativeUrl.contains('?') ? '&' : '?';
            final preservedParams = widget.queryParams.entries
                .where((e) => e.key != 'verifyCompleted')
                .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                .join('&');
            if (preservedParams.isNotEmpty) {
              relativeUrl = '$relativeUrl$separator$preservedParams';
            }
          }

          finalUrl = '${EnvConfig.baseUrl}$relativeUrl';
        }

        finalUrl = _forceHttpsForRpd(finalUrl);
        final friendlyTitle = _deriveWebViewTitle(msg, finalUrl);
        debugPrint(
            '[HomePage] Opening WebView for redirect (msg: $msg, title: $friendlyTitle): $finalUrl');
        await _openWebViewWithTransitionLoader(finalUrl, friendlyTitle);
      }
    }
  }

  /// RPD/reverse_pennydrop sometimes returns `http://...` URLs.
  /// Force `https://...` before opening the WebView.
  String _forceHttpsForRpd(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      final lower = url.toLowerCase();
      final isRpd = lower.contains('reverse_pennydrop') ||
          lower.contains('reversepennydrop');
      if (isRpd && lower.startsWith('http://')) {
        return 'https://${url.substring('http://'.length)}';
      }
      return url;
    }

    final pathLower = uri.path.toLowerCase();
    final queryLower = uri.query.toLowerCase();
    final isRpd = pathLower.contains('reverse_pennydrop') ||
        pathLower.contains('reversepennydrop') ||
        queryLower.contains('reverse_pennydrop') ||
        queryLower.contains('reversepennydrop');

    if (isRpd && uri.scheme.toLowerCase() == 'http') {
      return uri.replace(scheme: 'https').toString();
    }

    return url;
  }

  /// Prevents "previous step/login screen" flash between redirect API completion
  /// and the actual WebView route rendering.
  Future<void> _openWebViewWithTransitionLoader(
      String finalUrl, String friendlyTitle) async {
    if (!mounted) return;

    // Show a fully opaque white overlay so no home-page UI is visible during
    // the route transition. This pairs with the FadeTransition on the webview
    // route so the user sees white → white → WebView content with no flash.
    setState(() => _webViewTransitionActive = true);
    // Ensure the white overlay is painted before navigating.
    await WidgetsBinding.instance.endOfFrame;

    final encodedUrl = Uri.encodeComponent(finalUrl);
    final title = Uri.encodeComponent(friendlyTitle);
    context.go(
        '/${widget.company}/${widget.workflowName}/webview?url=$encodedUrl&title=$title');

    // If this widget remains mounted (rare edge-case), clear the overlay so a
    // back-navigation doesn't leave the screen blank.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() => _webViewTransitionActive = false);
    });
  }

  /// Derives a user-friendly WebView title based on redirect message and URL.
  /// Avoids showing internal messages like "redirect on render diverge" to the user.
  String _deriveWebViewTitle(String msg, String url) {
    String? module;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final host = uri.host.toLowerCase();
      final path = uri.path.toLowerCase();
      final query = uri.query.toLowerCase();

      if (path.contains('esign') || query.contains('esign')) {
        module = 'Proceed to eSign';
      } else if (host.contains('digilocker') ||
          path.contains('digilocker') ||
          query.contains('digilocker')) {
        module = 'Digilocker';
      } else if (path.contains('reverse_pennydrop') ||
          path.contains('reversepennydrop') ||
          query.contains('reverse_pennydrop')) {
        module = 'Bank Verification';
      } else if (path.contains('account_aggregator') ||
          query.contains('account_aggregator')) {
        module = 'Account Aggregator';
      } else if (host.contains('standardjourney.camsfinserv.com')) {
        module = 'Account Aggregator';
      } else if (host.contains('ipv') ||
          path.contains('ipv') ||
          path.contains('face')) {
        module = 'Face Verification';
      }
    }

    if (module != null) return module;

    final lowerMsg = msg.toLowerCase();
    if (lowerMsg.isNotEmpty && !lowerMsg.startsWith('redirect on ')) {
      return msg;
    }

    return 'Verification';
  }

  int _getStepperIndex(AppStore store, bool isAuth) {
    if (!isAuth) return 0;

    String normalize(String s) => s.toLowerCase().trim().replaceAll(' ', '_');

    // Use dynamic position-based index from AppStore
    final currentIndex = store.getCurrentStepIndex();
    if (currentIndex != null) {
      debugPrint('[HomePage] Stepper index from position: $currentIndex');
      return currentIndex;
    }

    final displayedSteps = _getStepperSteps(store);

    // Fallback 1 (legacy): backend index/step value.
    // Backend commonly sends one-based index (e.g., "16" for the second mobile_otp step).
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    if (ctx is Map) {
      // Try 'index' first (from get-context response), then 'step'
      final indexStr = ctx['index']?.toString() ?? ctx['step']?.toString();
      if (indexStr != null) {
        final idx = int.tryParse(indexStr);
        if (idx != null) {
          final steps = displayedSteps;
          final maxIndex = steps.isNotEmpty ? steps.length - 1 : 4;
          // Prefer one-based interpretation when possible.
          if (idx >= 1 && idx <= steps.length) {
            return (idx - 1).clamp(0, maxIndex);
          }
          // Fallback: already zero-based.
          if (idx >= 0) {
            return idx.clamp(0, maxIndex);
          }
        }
      }
    }

    // Fallback 2: derive from current position against the same step list that UI shows
    // (works even when stepper metadata API is unavailable).
    final position = (store.currentPosition ?? '').toLowerCase().trim();
    if (position.isNotEmpty && displayedSteps.isNotEmpty) {
      final normalizedPosition = normalize(position);
      var byPosition = displayedSteps.indexWhere(
        (step) => normalize(step) == normalizedPosition,
      );
      if (byPosition == -1) {
        byPosition = displayedSteps.indexWhere((step) {
          final n = normalize(step);
          return n.startsWith(normalizedPosition) ||
              normalizedPosition.startsWith(n);
        });
      }
      if (byPosition != -1) {
        debugPrint(
            '[HomePage] Stepper index from fallback position "$position": $byPosition');
        return byPosition;
      }
    }
    return 0;
  }

  List<String> _getStepperSteps(AppStore store) {
    // Get dynamic steps from stepper workflow API
    final steps = store.getStepperSteps();
    if (steps.isNotEmpty) {
      // debugPrint('[HomePage] Using dynamic stepper steps: $steps');
      return steps;
    }
    // Fallback to default steps
    return KycStepperBar.defaultSteps;
  }

  dynamic _getActiveFields(AppStore store) {
    final withAuth = store.fieldsWithAuth;
    if (withAuth != null &&
        withAuth is Map &&
        withAuth['context'] != null &&
        (withAuth['context']['page']?['fields'] as List?)?.isNotEmpty == true) {
      return withAuth['context']['page'];
    }
    return store.fields;
  }

  Future<Map<String, dynamic>> _prepareFormData(bool skipValidation) async {
    final data = Map<String, dynamic>.from(_formNotifier.formData);
    // Do not send `save` in kyc-post-v2 body (backend expectation).

    // Add brokerage_plan for segments screen
    final store = context.read<AppStore>();
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    final position = ctx?['position']?.toString()?.toLowerCase();
    if (position == 'segments') {
      data['brokerage_plan'] = 'Brokerage Plan';
      // UI no longer exposes MTF / currency; keep payload aligned with backend.
      data['mtf'] = false;
      data['nse_currency'] = false;
      data['bse_currency'] = false;
    }
    final fields = _getActiveFields(context.read<AppStore>());
    if (fields == null) return data;
    final fieldList = fields['fields'] as List?;
    if (fieldList == null) return data;
    final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file');
    if (!hasFile) return data;

    final req = http.MultipartRequest(
      'POST',
      Uri.parse(
          '${EnvConfig.baseUrl}/api/get-user/${widget.company}/${widget.workflowName}'),
    );
    for (final e in data.entries) {
      final v = e.value;
      if (v is File) {
        req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
      } else if (v is bool) {
        req.fields[e.key] = v.toString();
      } else if (v != null) {
        req.fields[e.key] = v.toString();
      }
    }
    return data; // Caller uses multipart separately
  }

  Future<void> _handleSubmit(bool skipValidation) async {
    _submitError = '';
    _submitSuccess = '';
    final store = context.read<AppStore>();

    // Enforce Terms & Conditions on mobile login step
    if (!skipValidation) {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;

      String position = ctx?['position']?.toString().toLowerCase() ?? '';
      String label =
          ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';

      if (position.isEmpty || label.isEmpty) {
        final workflow = store.fields as Map?;
        position =
            (workflow?['position']?.toString() ?? position).toLowerCase();
        label =
            (workflow?['data']?['label']?.toString() ?? label).toLowerCase();
      }

      debugPrint('[HomePage] _handleSubmit position=$position label=$label');

      final isMobileScreen = position == 'mobile' && label == 'mobile';
      if (isMobileScreen) {
        if (!_termsAccepted) {
          setState(() {
            _showTermsError = true;
            _showMobileError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please accept the Terms & Conditions to continue',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
        final mobile = _formNotifier.formData['mobile'] ??
            _formNotifier.formData['phone'] ??
            _formNotifier.formData['mobile_number'] ??
            '';
        final digits = mobile.toString().replaceAll(RegExp(r'\D'), '');
        if (digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits)) {
          setState(() {
            _showMobileError = true;
            _showTermsError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please enter a valid 10-digit mobile number',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
      }
    }

    if (!skipValidation) {
      final isValid = _formNotifier.validate();
      if (!isValid) {
        debugPrint('[HomePage] Send OTP / Submit: validation failed');
        final errors = _formNotifier.errors;
        debugPrint('[HomePage] Validation errors: $errors');

        // Show toast with first validation error
        if (errors.isNotEmpty) {
          final firstError = errors.values.first;
          if (firstError != null && firstError.toString().isNotEmpty) {
            Fluttertoast.showToast(
              msg: firstError.toString(),
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.TOP,
              backgroundColor: Colors.red.shade700,
              textColor: Colors.white,
            );
          } else {
            Fluttertoast.showToast(
              msg: 'Please fill all required fields correctly',
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.TOP,
              backgroundColor: Colors.red.shade700,
              textColor: Colors.white,
            );
          }
        }
        return;
      }
    }
    FocusScope.of(context).unfocus();
    debugPrint('[HomePage] Send OTP / Submit START');
    setState(() => _submitLoading = true);

    try {
      final data = await _prepareFormData(skipValidation);
      debugPrint('[HomePage] Form data (Send OTP): $data');
      final activeFields = _getActiveFields(store);
      final fieldList = (activeFields?['fields'] as List?) ?? [];
      final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file') ||
          data.values.any((v) => v is File);

      // Check saveFilesAPI flag from context.page (check both fieldsWithAuth and fields)
      final withAuth = store.fieldsWithAuth as Map?;
      final workflow = store.fields as Map?;
      final ctx = (withAuth?['context'] ?? workflow?['context']) as Map?;
      final page = ctx?['page'] as Map?;
      final saveFilesAPI = page?['saveFilesAPI'] == true;
      debugPrint('[HomePage] _handleSubmit saveFilesAPI flag: $saveFilesAPI');

      final endpoint = '/api/get-user/${widget.company}/${widget.workflowName}';
      final fullUrl = '${EnvConfig.baseUrl}$endpoint';
      debugPrint('[HomePage] _handleSubmit hasFile=$hasFile');
      debugPrint('[HomePage] _handleSubmit FULL URL: $fullUrl');
      debugPrint('[HomePage] _handleSubmit ENDPOINT: $endpoint');

      // If saveFilesAPI is true, upload files separately first
      if (hasFile && saveFilesAPI) {
        debugPrint(
            '[HomePage] _handleSubmit saveFilesAPI=true: Uploading files separately to /api/upload_files_new');
        final filesToUpload = <String, File>{};

        // Extract files from data
        for (final e in data.entries) {
          if (e.value is File) {
            filesToUpload[e.key] = e.value as File;
          }
        }

        // Upload each file separately to /api/upload_files_new
        for (final entry in filesToUpload.entries) {
          final fileKey = entry.key; // e.g., signature_upload, pan_upload, etc.
          final file = entry.value;

          try {
            debugPrint(
                '[HomePage] _handleSubmit Uploading file: $fileKey = ${file.path}');
            final client = ApiClient();
            final uploadRes = await client.postMultipart(
              () async {
                final uploadReq = http.MultipartRequest(
                  'POST',
                  Uri.parse('${EnvConfig.baseUrl}/api/upload_files_new'),
                );
                uploadReq.headers['accept'] = '*/*';
                uploadReq.files
                    .add(await http.MultipartFile.fromPath(fileKey, file.path));
                return uploadReq;
              },
              skipRefreshOn401: true,
            );
            debugPrint(
                '[HomePage] _handleSubmit File upload response for $fileKey: ${uploadRes.statusCode}');

            if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
              debugPrint(
                  '[HomePage] _handleSubmit File upload failed for $fileKey: ${uploadRes.body}');
              Fluttertoast.showToast(
                msg: 'Failed to upload $fileKey',
                gravity: ToastGravity.TOP,
              );
              if (mounted) setState(() => _submitLoading = false);
              return;
            }
          } catch (e) {
            debugPrint(
                '[HomePage] _handleSubmit Error uploading file $fileKey: $e');
            Fluttertoast.showToast(
              msg: 'Error uploading file: $e',
              gravity: ToastGravity.TOP,
            );
            if (mounted) setState(() => _submitLoading = false);
            return;
          }
        }

        // Remove files from data after successful upload
        for (final key in filesToUpload.keys) {
          data.remove(key);
        }
        debugPrint(
            '[HomePage] _handleSubmit Files uploaded successfully, continuing with form submission');
      }

      if (hasFile && !saveFilesAPI) {
        // Use multipart/form-data for file uploads (existing flow when saveFilesAPI=false)
        final client = ApiClient();
        final res = await client.postMultipart(() async {
          final req = http.MultipartRequest('POST', Uri.parse(fullUrl));
          for (final e in data.entries) {
            final v = e.value;
            if (v is File) {
              req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
            } else if (v is bool) {
              req.fields[e.key] = v.toString();
            } else if (v != null) {
              req.fields[e.key] = v.toString();
            }
          }
          return req;
        });
        await _handleSubmitResponse(res, store);
      } else {
        // Use JSON for non-file submissions (or after files uploaded separately)
        final headers = {'Content-Type': 'application/json'};
        final res = await KycAPI.submitKyc(
          widget.company,
          widget.workflowName,
          data,
          headers,
        );
        await _handleSubmitResponse(res, store);
      }
    } catch (e, st) {
      debugPrint('[HomePage] Send OTP / Submit Exception: $e\n$st');
      Fluttertoast.showToast(msg: e.toString(), gravity: ToastGravity.TOP);
    } finally {
      if (mounted) setState(() => _submitLoading = false);
      debugPrint('[HomePage] Send OTP / Submit DONE');
    }
  }

  Future<void> _handleSubmitResponse(http.Response res, AppStore store) async {
    debugPrint(
        '[HomePage] _handleSubmitResponse status=${res.statusCode} body=${res.body.length > 300 ? res.body.substring(0, 300) + "..." : res.body}');
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      body = null;
    }
    try {
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          body?['success'] == true) {
        final token = body?['access_token'] as String?;
        final refresh = body?['refresh_token'] as String?;
        if (token != null) StorageService.setAccessToken(token);
        if (refresh != null) StorageService.setRefreshToken(refresh);
        StorageService.setAuthSuccess('true');
        StorageService.setMessage(body?['msg']?.toString() ?? '');
        StorageService.setUserStep(body?['position']?.toString() ?? '');
        final formSnapshot = Map<String, dynamic>.from(_formNotifier.formData);
        final digitsBeforeReset = _digitsFromFormMapOnly(formSnapshot);
        if (digitsBeforeReset.length == 10) {
          _persistedMobileDigitsForOtp = digitsBeforeReset;
        }
        final emailBeforeReset = _resolveEmailForOtpUi(formSnapshot);
        if (emailBeforeReset.contains('@')) {
          _persistedEmailForOtp = emailBeforeReset;
        }
        _formNotifier.resetForm();
        // Keep loading indicator visible during get-context call for smooth transition
        await store.fetchWorkflowFieldsWithAuth(
            widget.company, widget.workflowName, '');
        if (mounted && store.errorWithAuth != null) {
          if (_isHtmlOrInfraErrorBody(store.errorWithAuth)) {
            debugPrint(
                '[HomePage] get-context failed with server/HTML response — keeping session (not clearing storage)');
            Fluttertoast.showToast(
              msg: 'Could not refresh your progress. Please try again.',
              gravity: ToastGravity.TOP,
            );
            return;
          }
          await _clearCookiesAndRefresh();
          Fluttertoast.showToast(
              msg: store.errorWithAuth ?? 'Session updated. Please continue.',
              gravity: ToastGravity.TOP);
          return;
        }
        if (mounted) {
          final authResponse = store.fieldsWithAuth;
          if (authResponse is Map && authResponse['is_admin'] == true) {
            debugPrint(
                '[HomePage] Submit response indicates completion (is_admin=true) - navigating to completed');
            await store.fetchUserDetails();
            if (!mounted) return;
            if (store.userDetails != null) {
              context.go('/${widget.company}/${widget.workflowName}/completed');
              return;
            }
          }
        }
        if (mounted) {
          final ctx = store.fieldsWithAuth as Map?;
          final pos =
              ctx?['context']?['position']?.toString().toLowerCase() ?? '';
          if (pos == 'mobile_otp') {
            _applyPersistedMobileToForm();
            _persistedEmailForOtp = null;
          } else if (pos == 'email_otp') {
            _persistedMobileDigitsForOtp = null;
            _applyPersistedEmailToForm();
          } else {
            _persistedMobileDigitsForOtp = null;
            _persistedEmailForOtp = null;
          }
        }
        // Small delay for smooth UI transition
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 300));
          // Check for redirect before navigating
          await _checkAndHandleRedirect(store);
          if (!mounted) return;
          // Only navigate if not redirected
          final response = store.fieldsWithAuth;
          if (response is! Map || response['redirect'] != true) {
            context.go('/${widget.company}/${widget.workflowName}');
          }
        }
      } else {
        final errMsg = _errorMessageFromResponse(res.statusCode, res.body);
        Fluttertoast.showToast(msg: errMsg, gravity: ToastGravity.TOP);
      }
    } catch (_) {
      Fluttertoast.showToast(
          msg: 'Submission failed', gravity: ToastGravity.TOP);
    }
  }

  /// Extract user-facing error message from API response body.
  /// Supports common keys: msg, message, error, detail (string or list).
  static String _errorMessageFromResponse(int statusCode, String bodyStr) {
    if (bodyStr.trim().isEmpty) {
      return statusCode >= 400
          ? 'Request failed. Please try again.'
          : 'Submission failed';
    }
    try {
      final body = jsonDecode(bodyStr) as Map<String, dynamic>?;
      if (body == null)
        return bodyStr.length <= 200 ? bodyStr : 'Submission failed';
      final msg = body['msg'] ?? body['message'] ?? body['error'];
      if (msg != null) {
        if (msg is String) return msg;
        if (msg is List && msg.isNotEmpty) return msg.first.toString();
      }
      final detail = body['detail'];
      if (detail is String) return detail;
      if (detail is List && detail.isNotEmpty) return detail.first.toString();
    } catch (_) {
      // Non-JSON body (e.g. plain text error)
      if (bodyStr.length <= 200) return bodyStr.trim();
    }
    return statusCode >= 400
        ? 'Request failed. Please try again.'
        : 'Submission failed';
  }

  /// Builds kyc-post-v2 path segment from get-context page: page.name + page.id (e.g. mobile_otp2, email3).
  String _getKycPostPathSegment(Map? ctx) {
    final page = ctx?['page'] as Map?;
    if (page != null) {
      final name = page['name']?.toString() ?? '';
      final id = page['id']?.toString() ?? '';
      if (name.isNotEmpty || id.isNotEmpty) return '$name$id';
    }
    final pos = ctx?['position']?.toString() ?? '';
    final idx = ctx?['index']?.toString() ?? '';
    return pos.isNotEmpty || idx.isNotEmpty ? '$pos$idx' : '';
  }

  Future<void> _handleCommonSubmit(bool skipValidation) async {
    debugPrint(
        '[HomePage] _handleCommonSubmit CALLED - skipValidation=$skipValidation');
    final store = context.read<AppStore>();

    // Enforce Terms & Conditions on mobile step for authenticated flows
    if (!skipValidation) {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;

      String position = ctx?['position']?.toString().toLowerCase() ?? '';
      String label =
          ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';

      if (position.isEmpty || label.isEmpty) {
        final workflow = store.fields as Map?;
        position =
            (workflow?['position']?.toString() ?? position).toLowerCase();
        label =
            (workflow?['data']?['label']?.toString() ?? label).toLowerCase();
      }

      debugPrint(
          '[HomePage] _handleCommonSubmit position=$position label=$label');

      final isMobileScreen = position == 'mobile' && label == 'mobile';
      if (isMobileScreen) {
        if (!_termsAccepted) {
          setState(() {
            _showTermsError = true;
            _showMobileError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please accept the Terms & Conditions to continue',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
        final mobile = _formNotifier.formData['mobile'] ??
            _formNotifier.formData['phone'] ??
            _formNotifier.formData['mobile_number'] ??
            '';
        final digits = mobile.toString().replaceAll(RegExp(r'\D'), '');
        if (digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits)) {
          setState(() {
            _showMobileError = true;
            _showTermsError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please enter a valid 10-digit mobile number',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
      }
    }

    if (!skipValidation) {
      final isValid = _formNotifier.validate();
      debugPrint('[HomePage] Form validation result: $isValid');
      if (!isValid) {
        debugPrint('[HomePage] Validation failed, returning early');
        final errors = _formNotifier.errors;
        debugPrint('[HomePage] Validation errors: $errors');

        // Show toast with first validation error
        if (errors.isNotEmpty) {
          final firstError = errors.values.first;
          if (firstError != null && firstError.toString().isNotEmpty) {
            Fluttertoast.showToast(
              msg: firstError.toString(),
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.TOP,
              backgroundColor: Colors.red.shade700,
              textColor: Colors.white,
            );
          } else {
            Fluttertoast.showToast(
              msg: 'Please fill all required fields correctly',
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.TOP,
              backgroundColor: Colors.red.shade700,
              textColor: Colors.white,
            );
          }
        }
        return;
      }
    }
    FocusScope.of(context).unfocus();
    debugPrint('[HomePage] _handleCommonSubmit START');
    setState(() => _submitLoading = true);
    try {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;
      final pathSegment = _getKycPostPathSegment(ctx);
      if (pathSegment.isEmpty) {
        Fluttertoast.showToast(
            msg: 'Invalid step. Please refresh.', gravity: ToastGravity.TOP);
        if (mounted) setState(() => _submitLoading = false);
        return;
      }

      final data = await _prepareFormData(skipValidation);
      data.remove('save');

      // Initial email capture step: backend expects a trimmed body (email + a few fields).
      // Must NOT run on `email_otp` — pathSegment e.g. `email_otp4` still starts with `email`,
      // and clearing here would drop the OTP field and break verify_otp on the server.
      final currentPosition =
          (ctx?['position']?.toString().toLowerCase() ?? '').trim();
      final lowerPath = pathSegment.toLowerCase();
      final isEmailOtpStep =
          currentPosition == 'email_otp' || lowerPath.startsWith('email_otp');
      final isEmailOnlySubmitStep = !isEmailOtpStep &&
          (currentPosition == 'email' ||
              (lowerPath.startsWith('email') &&
                  !lowerPath.startsWith('email_otp')));
      if (isEmailOnlySubmitStep) {
        final resolvedEmail =
            (data['email'] ?? data['email_id'] ?? data['emailId'])
                    ?.toString()
                    .trim() ??
                '';
        final selectDependency =
            (data['select__dependency'] ?? 'Self').toString().trim();
        final branchReferenceCode =
            (data['branch_reference_code'] ?? '').toString();
        final panNumber1 = (data['pan_number1'] ?? '').toString();
        data
          ..clear()
          ..['email'] = resolvedEmail
          ..['select__dependency'] =
              selectDependency.isEmpty ? 'Self' : selectDependency
          ..['branch_reference_code'] = branchReferenceCode
          ..['pan_number1'] = panNumber1;
      }

      // DigiLocker: backend expects `save: true` on kyc-post-v2 (e.g. `/digilocker9`).
      // Do not require `?verify=digilocker` on the app route — that flag is often only sent to
      // get-context, so `widget.queryParams` is empty here even after a successful verify flow.
      final onDigilockerStep =
          currentPosition == 'digilocker' || lowerPath.startsWith('digilocker');
      if (onDigilockerStep) {
        data['save'] = true;
        debugPrint('[HomePage] DigiLocker step: save=true on kyc-post-v2');
      }

      debugPrint(
          '[HomePage] _handleCommonSubmit data: $data pathSegment: $pathSegment');

      // Check saveFilesAPI flag from context.page
      final page = ctx?['page'] as Map?;
      final saveFilesAPI = page?['saveFilesAPI'] == true;
      debugPrint('[HomePage] saveFilesAPI flag: $saveFilesAPI');

      // Check if form has file fields - if yes, use multipart/form-data
      final activeFields = _getActiveFields(store);
      final fieldList = (activeFields?['fields'] as List?) ?? [];
      final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file') ||
          data.values.any((v) => v is File);

      final client = ApiClient();
      final endpoint =
          '/api/kyc-post-v2/${widget.company}/${widget.workflowName}/$pathSegment';
      final fullUrl = '${EnvConfig.baseUrl}$endpoint';
      debugPrint('[HomePage] _handleCommonSubmit hasFile=$hasFile');
      debugPrint('[HomePage] _handleCommonSubmit FULL URL: $fullUrl');
      debugPrint('[HomePage] _handleCommonSubmit ENDPOINT: $endpoint');

      // If saveFilesAPI is true, upload files separately first
      if (hasFile && saveFilesAPI) {
        debugPrint(
            '[HomePage] saveFilesAPI=true: Uploading files separately to /api/upload_files_new');
        final filesToUpload = <String, File>{};

        // Extract files from data
        for (final e in data.entries) {
          if (e.value is File) {
            filesToUpload[e.key] = e.value as File;
          }
        }

        // Upload each file separately to /api/upload_files_new (token set in ApiClient; 401 triggers refresh + retry)
        for (final entry in filesToUpload.entries) {
          final fileKey = entry.key; // e.g., signature_upload, pan_upload, etc.
          final file = entry.value;

          try {
            debugPrint('[HomePage] Uploading file: $fileKey = ${file.path}');
            final uploadRes = await client.postMultipart(
              () async {
                final uploadReq = http.MultipartRequest(
                  'POST',
                  Uri.parse('${EnvConfig.baseUrl}/api/upload_files_new'),
                );
                uploadReq.headers['accept'] = '*/*';
                uploadReq.files
                    .add(await http.MultipartFile.fromPath(fileKey, file.path));
                return uploadReq;
              },
              skipRefreshOn401: true,
            );
            debugPrint(
                '[HomePage] File upload response for $fileKey: ${uploadRes.statusCode}');

            if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
              debugPrint(
                  '[HomePage] File upload failed for $fileKey: ${uploadRes.body}');
              Fluttertoast.showToast(
                msg: 'Failed to upload $fileKey',
                gravity: ToastGravity.TOP,
              );
              if (mounted) setState(() => _submitLoading = false);
              return;
            }
          } catch (e) {
            debugPrint('[HomePage] Error uploading file $fileKey: $e');
            Fluttertoast.showToast(
              msg: 'Error uploading file: $e',
              gravity: ToastGravity.TOP,
            );
            if (mounted) setState(() => _submitLoading = false);
            return;
          }
        }

        // Remove files from data after successful upload
        for (final key in filesToUpload.keys) {
          data.remove(key);
        }
        debugPrint(
            '[HomePage] Files uploaded successfully, continuing with form submission');
      }

      final http.Response res;
      if (hasFile && !saveFilesAPI) {
        // Use multipart/form-data for file uploads (existing flow when saveFilesAPI=false)
        debugPrint(
            '[HomePage] Using multipart/form-data (file upload detected, saveFilesAPI=false)');
        res = await client.postMultipart(() async {
          final req = http.MultipartRequest('POST', Uri.parse(fullUrl));
          for (final e in data.entries) {
            final v = e.value;
            if (v is File) {
              req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
              debugPrint('[HomePage] Added file: ${e.key} = ${v.path}');
            } else if (v is bool) {
              req.fields[e.key] = v.toString();
            } else if (v != null && v.toString().isNotEmpty) {
              req.fields[e.key] = v.toString();
            }
          }
          return req;
        });
      } else {
        // Use JSON for non-file submissions (or after files uploaded separately)
        debugPrint(
            '[HomePage] Using application/json (no files or files already uploaded)');
        res = await client.post(
          endpoint,
          body: data,
          headers: {'Content-Type': 'application/json'},
        );
      }
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (_) {
        body = null;
      }
      final isSuccess = res.statusCode >= 200 &&
          res.statusCode < 300 &&
          body?['success'] == true;
      if (isSuccess) {
        StorageService.setUserStep(body?['step']?.toString() ?? '');
        // Email step → email_otp: resetForm() clears email; persist from payload before reset.
        final formSnapshot = Map<String, dynamic>.from(_formNotifier.formData);
        final emailFromPayload =
            (data['email'] ?? data['email_id'] ?? data['emailId'])
                    ?.toString()
                    .trim() ??
                '';
        if (emailFromPayload.contains('@')) {
          _persistedEmailForOtp = emailFromPayload;
        } else {
          final resolved = _resolveEmailForOtpUi(formSnapshot);
          if (resolved.contains('@')) _persistedEmailForOtp = resolved;
        }
        _formNotifier.resetForm();
        // Keep loading indicator visible during get-context call for smooth transition
        await store.fetchWorkflowFieldsWithAuth(
            widget.company, widget.workflowName, '');
        if (mounted && store.errorWithAuth != null) {
          if (_isHtmlOrInfraErrorBody(store.errorWithAuth)) {
            debugPrint(
                '[HomePage] get-context failed with server/HTML response — keeping session (not clearing storage)');
            Fluttertoast.showToast(
              msg: 'Could not refresh your progress. Please try again.',
              gravity: ToastGravity.TOP,
            );
            if (mounted) setState(() => _submitLoading = false);
            return;
          }
          await _clearCookiesAndRefresh();
          Fluttertoast.showToast(
              msg: store.errorWithAuth ?? 'Session updated. Please continue.',
              gravity: ToastGravity.TOP);
          if (mounted) setState(() => _submitLoading = false);
          return;
        }
        if (mounted) {
          final authResponse = store.fieldsWithAuth;
          if (authResponse is Map && authResponse['is_admin'] == true) {
            debugPrint(
                '[HomePage] Common submit indicates completion (is_admin=true) - navigating to completed');
            await store.fetchUserDetails();
            if (!mounted) return;
            if (store.userDetails != null) {
              setState(() => _submitLoading = false);
              context.go('/${widget.company}/${widget.workflowName}/completed');
              return;
            }
          }
        }
        if (mounted) {
          final ctx = store.fieldsWithAuth as Map?;
          final pos =
              ctx?['context']?['position']?.toString().toLowerCase() ?? '';
          if (pos == 'email_otp') {
            _applyPersistedEmailToForm();
            debugPrint(
                '[HomePage] email_otp: applied persisted email for UI: $_persistedEmailForOtp');
          }
        }
        // Small delay for smooth UI transition
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 300));
          setState(() => _submitLoading = false);
          // Check for redirect before navigating
          await _checkAndHandleRedirect(store);
          if (!mounted) return;
          // Only navigate if not redirected
          final response = store.fieldsWithAuth;
          if (response is! Map || response['redirect'] != true) {
            context.go('/${widget.company}/${widget.workflowName}');
          }
        }
      } else {
        final errMsg = _errorMessageFromResponse(res.statusCode, res.body);
        Fluttertoast.showToast(msg: errMsg, gravity: ToastGravity.TOP);
        if (mounted) setState(() => _submitLoading = false);
      }
    } catch (e) {
      Fluttertoast.showToast(
          msg: 'Something went wrong. Please try again.',
          gravity: ToastGravity.TOP);
      if (mounted) setState(() => _submitLoading = false);
    }
  }

  /// When [AppStore.errorWithAuth] is set to an HTML/5xx page, the session is usually still valid;
  /// wiping storage only forces an unauthenticated workflow load (`hasToken=false`).
  static bool _isHtmlOrInfraErrorBody(String? err) {
    if (err == null || err.isEmpty) return false;
    final t = err.trim().toLowerCase();
    return t.startsWith('<!doctype') ||
        t.contains('<html') ||
        t.contains('internal server error') ||
        t.contains('502 bad gateway') ||
        t.contains('503 service unavailable') ||
        t.contains('504 gateway');
  }

  Future<void> _clearCookiesAndRefresh() async {
    await StorageService.clearAll();
    if (mounted) _loadWorkflow();
  }

  /// Fetch bank details by IFSC code and auto-fill bank fields
  Future<void> _fetchBankDetailsByIfsc(String ifsc) async {
    if (ifsc.length != 11) {
      debugPrint('[HomePage] IFSC invalid length: ${ifsc.length}');
      return;
    }

    try {
      debugPrint('[HomePage] Fetching bank details for IFSC: $ifsc');
      final client = ApiClient();
      final res = await client.post(
        '/get_bank_address_by_ifsc',
        body: {'ifsc': ifsc},
        headers: {'Content-Type': 'application/json'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        debugPrint('[HomePage] Bank details response: $data');

        if (data != null && mounted) {
          // Ensure we are on a bank / bank_details screen before auto-fill
          final store = context.read<AppStore>();
          final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
          final position = ctx?['position']?.toString()?.toLowerCase();
          final label =
              ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
          final isBankScreen = position == 'bank' ||
              position == 'bank_details' ||
              label == 'bank';
          if (!isBankScreen) {
            debugPrint(
                '[HomePage] IFSC response received but not on bank screen (position=$position, label=$label)');
            return;
          }

          // Build list of current field names (for this workflow / company)
          final activeFields = _getActiveFields(store);
          final fieldList = (activeFields?['fields'] as List?) ?? [];
          final fieldNames = <String>{};
          for (final f in fieldList) {
            if (f is Map && f['name'] != null) {
              fieldNames.add(f['name'].toString());
            }
          }

          // Map API response fields to actual field names present in current screen
          final updates = <String, dynamic>{};

          // bank_name → bank_name / bankName
          if (data['bank_name'] != null) {
            final v = data['bank_name'];
            if (fieldNames.contains('bank_name')) updates['bank_name'] = v;
            if (fieldNames.contains('bankName')) updates['bankName'] = v;
          }

          // BRANCH → branch_name / branchName
          if (data['BRANCH'] != null) {
            final v = data['BRANCH'];
            if (fieldNames.contains('branch_name')) updates['branch_name'] = v;
            if (fieldNames.contains('branchName')) updates['branchName'] = v;
          }

          // address → bank_address / bankAddress
          if (data['address'] != null) {
            final v = data['address'];
            if (fieldNames.contains('bank_address'))
              updates['bank_address'] = v;
            if (fieldNames.contains('bankAddress')) updates['bankAddress'] = v;
          }

          // city → bank_city
          if (data['city'] != null && fieldNames.contains('bank_city')) {
            updates['bank_city'] = data['city'];
          }

          // district → bank_district
          if (data['district'] != null &&
              fieldNames.contains('bank_district')) {
            updates['bank_district'] = data['district'];
          }

          // state → bank_state
          if (data['state'] != null && fieldNames.contains('bank_state')) {
            updates['bank_state'] = data['state'];
          }

          // micr → micr / micr1
          if (data['micr'] != null) {
            final v = data['micr'];
            if (fieldNames.contains('micr')) updates['micr'] = v;
            if (fieldNames.contains('micr1')) updates['micr1'] = v;
          }

          // pincode → bank_pincode
          if (data['pincode'] != null && fieldNames.contains('bank_pincode')) {
            updates['bank_pincode'] = data['pincode'];
          }

          debugPrint(
              '[HomePage] Bank fields to update (after position & field filter): $updates');

          if (updates.isEmpty) {
            debugPrint(
                '[HomePage] No matching bank fields found to update for this screen.');
          } else {
            // Batch update formData and trigger UI rebuild
            setState(() {
              for (final e in updates.entries) {
                debugPrint('[HomePage] Updating field: ${e.key} = ${e.value}');
                _formNotifier.formData[e.key] = e.value;
              }
            });

            // Notify listeners to rebuild UI
            _formNotifier.notifyListeners();

            Fluttertoast.showToast(
                msg: 'Bank details fetched successfully',
                gravity: ToastGravity.TOP);
            debugPrint(
                '[HomePage] Auto-filled ${updates.length} bank fields - UI should update now');
          }
        }
      } else {
        debugPrint('[HomePage] IFSC lookup failed: ${res.statusCode}');
        Fluttertoast.showToast(
            msg: 'Invalid IFSC code', gravity: ToastGravity.TOP);
      }
    } catch (e) {
      debugPrint('[HomePage] IFSC lookup error: $e');
      Fluttertoast.showToast(
          msg: 'Failed to fetch bank details', gravity: ToastGravity.TOP);
    }
  }

  Future<void> _handleLogout() async {
    final token = await StorageService.getAccessToken();
    setState(() => _logoutLoading = true);
    try {
      // Step 1: Call logout API
      if (token != null) {
        try {
          final client = ApiClient();
          await client.post('/api/user/logout',
              headers: {'Authorization': 'Bearer $token'});
          debugPrint('[HomePage] Logout API called successfully');
        } catch (e) {
          debugPrint('[HomePage] Logout API error (continuing anyway): $e');
        }
      }

      // Step 2: Clear all auth tokens and data
      await StorageService.clearAll();
      debugPrint('[HomePage] Tokens cleared');
      // Next session starts from Start KYC; allow SSO again when user re-enters via entry page.
      StorageService.setSsoAutoLoginEnabled(true);

      if (!mounted) return;

      // Step 3: Reset form state
      _formNotifier.resetForm();

      // Step 4: Reset AppStore state
      final store = context.read<AppStore>();
      store.resetState();

      // Step 5: Back to Start KYC (workflow entry)
      if (mounted) {
        context.go('/');
        Fluttertoast.showToast(
            msg: 'Logged out successfully', gravity: ToastGravity.TOP);
      }
    } catch (e) {
      debugPrint('[HomePage] Logout error: $e');
      Fluttertoast.showToast(
          msg: 'Error during logout', gravity: ToastGravity.TOP);
    } finally {
      if (mounted) setState(() => _logoutLoading = false);
    }
  }

  // ---------- WebView-return partial-loader helpers ----------

  Widget _buildWebViewReturnLoaderContent() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
              color: KycTheme.primary, strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            _returnFlowMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebViewReturnRetryContent(AppStore store) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 64, color: Colors.orange.shade400),
            const SizedBox(height: 16),
            Text(
              _webViewReturnError!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade700,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text(
                'Try Again',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: KycTheme.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              onPressed: () {
                store.clearAuthError();
                setState(() {
                  _webViewReturnError = null;
                  _returnFlowMessage = 'Loading your next step...';
                });
                _loadWorkflow();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _headerWorkflowName() {
    final raw = widget.workflowName.trim();
    if (raw.isEmpty) return 'Workflow';
    return raw
        .split('_')
        .where((e) => e.isNotEmpty)
        .map((part) =>
            part[0].toUpperCase() + (part.length > 1 ? part.substring(1) : ''))
        .join(' ');
  }

  Widget _buildTopActionHeader({required Widget actions}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                _headerWorkflowName(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: KycTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          actions,
        ],
      ),
    );
  }

  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _formNotifier,
      child: Consumer2<AppStore, ConditionalFormNotifier>(
        builder: (context, store, form, _) {
          final activeFields = _getActiveFields(store);
          final fieldList = (activeFields?['fields'] as List?) ?? [];
          final conditionalFlow = activeFields?['conditionalFlow'] as List?;
          final submitButton = activeFields?['submitButton'] as Map?;

          return FutureBuilder<bool>(
            future: StorageService.hasAccessToken(),
            builder: (context, snapshot) {
              final isAuthenticated = snapshot.data ?? false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _formNotifier.updateFields(fieldList, conditionalFlow);
                // Must run in same callback *after* updateFields so API `value` is in formData first.
                _runPersonalDetailsBpWealthPipeline(store, fieldList);
              });

              // Get stepper data
              final stepperIndex = _getStepperIndex(store, isAuthenticated);
              final stepperSteps = _getStepperSteps(store);
              // Stepper visible only from 2nd step (mobile_otp) onwards; hidden on first step (mobile number entry)
              final ctxForStepper =
                  (store.fieldsWithAuth as Map?)?['context'] as Map?;
              final currentPosition =
                  (ctxForStepper?['position']?.toString() ?? '').toLowerCase();
              final showStepper =
                  currentPosition.isNotEmpty && currentPosition != 'mobile';

              // Build stepper widget with fixed height container (visible only from step 2 onwards)
              final stepperWidget = Container(
                height:
                    100, // Fixed height for stepper (circle + label + padding)
                color: Colors.white, // Ensure background color
                child: KycStepperBar(
                  steps: stepperSteps,
                  currentIndex: stepperIndex,
                ),
              );

              // Partial loader / retry while returning from WebView.
              // Checked before anything else so the old step's form UI is NEVER
              // rendered between WebView exit and both API calls completing.
              // Refresh and Logout buttons remain visible so the user always
              // has an escape hatch — only the content area shows the loader.
              if (store.isReturningFromWebView) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Refresh + Logout row — always accessible
                        if (isAuthenticated)
                          _buildTopActionHeader(
                            actions: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed:
                                      (_loadWorkflowActive || _logoutLoading)
                                          ? null
                                          : () {
                                              store.clearAuthError();
                                              setState(() {
                                                _webViewReturnError = null;
                                                _returnFlowMessage =
                                                    'Loading your next step...';
                                              });
                                              _loadWorkflow();
                                            },
                                  icon: _loadWorkflowActive
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: KycTheme.primary),
                                        )
                                      : const Icon(Icons.refresh,
                                          color: KycTheme.textPrimary),
                                ),
                                IconButton(
                                  onPressed:
                                      _logoutLoading ? null : _handleLogout,
                                  icon: _logoutLoading
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: KycTheme.primary),
                                        )
                                      : const Icon(Icons.logout,
                                          color: KycTheme.textPrimary),
                                ),
                              ],
                            ),
                          ),
                        // Stepper stays visible throughout
                        if (showStepper) stepperWidget,
                        // Content area: spinner or retry
                        Expanded(
                          child: _webViewReturnError != null
                              ? _buildWebViewReturnRetryContent(store)
                              : _buildWebViewReturnLoaderContent(),
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Opaque white screen shown just before navigating to WebView.
              // Paired with the FadeTransition on the webview route to guarantee
              // zero flash of home-page UI during the transition.
              if (_webViewTransitionActive) {
                return const Scaffold(
                  backgroundColor: Colors.white,
                  body: SizedBox.expand(
                    child: ColoredBox(color: Colors.white),
                  ),
                );
              }

              // Handle loading states - full screen when no stepper, else loader below stepper
              // Full-screen loader during submit so users don't see the old/login screen
              // while API response is pending (especially during redirect flows like RPD).
              if (_submitLoading) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              const Expanded(
                                  child: Loader(message: 'Loading...')),
                            ],
                          )
                        : SizedBox.expand(
                            child: const Loader(message: 'Loading...')),
                  ),
                );
              }

              if (store.loading) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              const Expanded(
                                  child: Loader(message: 'Loading...')),
                            ],
                          )
                        : const Loader(message: 'Loading...'),
                  ),
                );
              }

              if (store.error != null) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              Expanded(
                                child: KycLayout(
                                  title: 'Error',
                                  stepperSteps: null,
                                  stepperIndex: null,
                                  skipScaffold: true,
                                  child: Center(
                                    child: Text(
                                      store.error!,
                                      style: const TextStyle(color: Colors.red),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : KycLayout(
                            title: 'Error',
                            stepperSteps: null,
                            stepperIndex: null,
                            skipScaffold: true,
                            child: Center(
                              child: Text(
                                store.error!,
                                style: const TextStyle(color: Colors.red),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                  ),
                );
              }

              // Show loader BELOW stepper when fetching get-context (full screen when first step)
              if (store.loadingWithAuth) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              const Expanded(
                                  child: Loader(message: 'Loading...')),
                            ],
                          )
                        : const Loader(message: 'Loading...'),
                  ),
                );
              }

              // Show error if get-context API failed
              if (store.errorWithAuth != null) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              Expanded(
                                child: KycLayout(
                                  title: 'Error',
                                  stepperSteps: null,
                                  stepperIndex: null,
                                  skipScaffold: true,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Text(
                                        store.errorWithAuth!,
                                        style: const TextStyle(
                                            color: Colors.red, fontSize: 16),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : KycLayout(
                            title: 'Error',
                            stepperSteps: null,
                            stepperIndex: null,
                            skipScaffold: true,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  store.errorWithAuth!,
                                  style: const TextStyle(
                                      color: Colors.red, fontSize: 16),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                  ),
                );
              }

              // Get page title from context.page.data.label or context.page.name, fallback to title/pageTitle
              final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
              final page = ctx?['page'] as Map?;
              final pageData = page?['data'] as Map?;
              final rawPageLabel = pageData?['label']?.toString();
              final pageName = page?['name']?.toString();
              final rawPosition = ctx?['position']?.toString();

              String? pageTitle;

              if (ctx == null) {
                // No context yet (first unauthenticated screen) – show hero title.
                pageTitle = 'Start your KYC or pickup where you left off';
              } else {
                // Prefer human-friendly titles from context / activeFields.
                String? pageLabel = rawPageLabel;

                // If backend label is same as technical position (e.g. "personal_details"),
                // don't show it as a title – stepper already shows the step name.
                if (rawPageLabel != null &&
                    rawPosition != null &&
                    rawPageLabel.toLowerCase().trim() ==
                        rawPosition.toLowerCase().trim()) {
                  pageLabel = null;
                }

                pageTitle = pageLabel ??
                    pageName ??
                    (activeFields is Map
                            ? activeFields['title'] ?? activeFields['pageTitle']
                            : null)
                        ?.toString();

                // If title still looks like a technical key (all lowercase/underscores),
                // hide it and rely on the stepper only.
                if (pageTitle != null) {
                  final simple = pageTitle.trim();
                  final isCodeStyle = RegExp(r'^[a-z0-9_]+$').hasMatch(simple);
                  if (isCodeStyle) {
                    pageTitle = null;
                  }
                }
              }

              // Show \"Documents to keep Handy\" only on first 4 steps of the stepper
              // (Enter Mobile, Mobile OTP, Email, Email OTP)
              final showDocumentsSection = stepperIndex <= 3;

              return Scaffold(
                backgroundColor: KycTheme.background,
                body: SafeArea(
                  child: showStepper
                      ? Column(
                          children: [
                            // Refresh + Logout row above stepper (when authenticated)
                            if (isAuthenticated)
                              _buildTopActionHeader(
                                actions: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: _refreshLoading
                                          ? null
                                          : () async {
                                              setState(
                                                  () => _refreshLoading = true);
                                              try {
                                                await _loadWorkflow();
                                              } finally {
                                                if (mounted) {
                                                  setState(() =>
                                                      _refreshLoading = false);
                                                }
                                              }
                                            },
                                      icon: _refreshLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.refresh,
                                              color: KycTheme.textPrimary),
                                    ),
                                    IconButton(
                                      onPressed:
                                          _logoutLoading ? null : _handleLogout,
                                      icon: _logoutLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.logout,
                                              color: KycTheme.textPrimary),
                                    ),
                                  ],
                                ),
                              ),
                            stepperWidget,
                            Expanded(
                              child: KycLayout(
                                title: pageTitle,
                                stepperSteps: null,
                                stepperIndex: null,
                                skipScaffold: true,
                                showDocumentsSection: showDocumentsSection,
                                leading: (isAuthenticated &&
                                        (submitButton?['backShowButton'] ??
                                            false))
                                    ? IconButton(
                                        onPressed: _backLoading
                                            ? null
                                            : () => Navigator.of(context)
                                                .maybePop(),
                                        icon: _backLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color:
                                                            KycTheme.primary),
                                              )
                                            : const Icon(Icons.arrow_back,
                                                color: KycTheme.textPrimary),
                                      )
                                    : null,
                                trailing: null,
                                child: _buildForm(
                                  fieldList,
                                  activeFields,
                                  submitButton,
                                  store,
                                  isAuthenticated,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            if (isAuthenticated)
                              _buildTopActionHeader(
                                actions: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: _refreshLoading
                                          ? null
                                          : () async {
                                              setState(
                                                  () => _refreshLoading = true);
                                              try {
                                                await _loadWorkflow();
                                              } finally {
                                                if (mounted) {
                                                  setState(() =>
                                                      _refreshLoading = false);
                                                }
                                              }
                                            },
                                      icon: _refreshLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.refresh,
                                              color: KycTheme.textPrimary),
                                    ),
                                    IconButton(
                                      onPressed:
                                          _logoutLoading ? null : _handleLogout,
                                      icon: _logoutLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.logout,
                                              color: KycTheme.textPrimary),
                                    ),
                                  ],
                                ),
                              ),
                            Expanded(
                              child: KycLayout(
                                title: pageTitle,
                                stepperSteps: null,
                                stepperIndex: null,
                                skipScaffold: true,
                                leading: (isAuthenticated &&
                                        (submitButton?['backShowButton'] ??
                                            false))
                                    ? IconButton(
                                        onPressed: _backLoading
                                            ? null
                                            : () => Navigator.of(context)
                                                .maybePop(),
                                        icon: _backLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color:
                                                            KycTheme.primary),
                                              )
                                            : const Icon(Icons.arrow_back,
                                                color: KycTheme.textPrimary),
                                      )
                                    : null,
                                trailing: null,
                                showDocumentsSection: showDocumentsSection,
                                child: _buildForm(
                                  fieldList,
                                  activeFields,
                                  submitButton,
                                  store,
                                  isAuthenticated,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  // --- BP Wealth bugfixes (BugFixes → segmentBugResolved) ---
  // Personal-details step: merge get-context `field.value` (dropoff) into formData,
  // normalize radio/select option strings, apply PEP/citizen/tax/tariff defaults.
  // Segments step: `_prepareFormData` forces mtf / NSE-BSE currency off when UI hides them.
  // ---------------------------------------------------------------------------

  /// Matches workflow option labels (radio or **select** dropdown). Exact match first, then Yes/No prefix.
  String? _matchRadioOption(List<dynamic>? values, String desired) {
    if (values == null || values.isEmpty) return null;
    final want = desired.toLowerCase().trim();
    for (final o in values) {
      final s = o.toString();
      if (s.toLowerCase().trim() == want) return s;
    }
    if (want == 'yes') {
      for (final o in values) {
        final sl = o.toString().toLowerCase().trim();
        if (sl.startsWith('y')) return o.toString();
      }
    }
    if (want == 'no') {
      for (final o in values) {
        final sl = o.toString().toLowerCase().trim();
        if (sl.startsWith('n')) return o.toString();
      }
    }
    return null;
  }

  /// Map API/dropoff value to the exact option string (radio or **select**).
  String _normalizeRadioToOptions(dynamic raw, List<dynamic>? options) {
    if (raw == null || options == null || options.isEmpty) {
      return raw?.toString() ?? '';
    }
    final want = raw.toString().trim().toLowerCase();
    for (final o in options) {
      final s = o.toString();
      if (s.toLowerCase().trim() == want) return s;
    }
    if (want == 'yes' || want == 'y') {
      final m = _matchRadioOption(options, 'Yes');
      if (m != null) return m;
    }
    if (want == 'no' || want == 'n') {
      final m = _matchRadioOption(options, 'No');
      if (m != null) return m;
    }
    if (want.startsWith('y')) {
      final m = _matchRadioOption(options, 'Yes');
      if (m != null) return m;
    }
    if (want.startsWith('n')) {
      final m = _matchRadioOption(options, 'No');
      if (m != null) return m;
    }
    return raw.toString();
  }

  /// Prefer in-memory value; if unset or blank string, use workflow `field['value']` (dropoff).
  dynamic _coalesceFormFieldValue(dynamic formValue, dynamic fieldValue) {
    if (formValue == null) return fieldValue;
    if (formValue is String && formValue.trim().isEmpty) return fieldValue;
    return formValue;
  }

  /// True when [formData] has no meaningful value yet (merge dropoff/API into form).
  bool _shouldMergeFromApi(dynamic existing) {
    if (existing == null) return true;
    if (existing is String && existing.trim().isEmpty) return true;
    return false;
  }

  /// Push `field['value']` from get-context (incl. dropoff) into [formData] so radios/checkboxes
  /// match option strings and submit payload is correct. Skips when user already has a value.
  void _mergePersonalDetailsFromFieldDefinitions(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final existing = _formNotifier.formData[name];
      if (!_shouldMergeFromApi(existing)) continue;

      final apiValue = f['value'];
      if (apiValue == null) continue;

      final type = f['type']?.toString() ?? '';
      final validation = f['validation']?.toString();
      final values = f['values'] as List?;

      if (type == 'radio' || type == 'select') {
        final normalized = _normalizeRadioToOptions(apiValue, values);
        _formNotifier.handleChange(name, normalized,
            type: type, validationType: validation);
      } else if (type == 'checkbox') {
        final v = apiValue is bool
            ? apiValue
            : apiValue.toString().toLowerCase() == 'true' ||
                apiValue.toString() == '1';
        _formNotifier.handleChange(name, v,
            type: 'checkbox', validationType: validation);
      } else {
        _formNotifier.handleChange(name, apiValue,
            type: type.isEmpty ? 'text' : type, validationType: validation);
      }
    }
  }

  /// Fix casing mismatch for radio and **select** (dropdown) option lists.
  void _normalizePersonalDetailRadios(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final type = f['type']?.toString() ?? '';
      if (type != 'radio' && type != 'select') continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final values = f['values'] as List?;
      final raw = _formNotifier.formData[name];
      if (raw == null) continue;
      final fixed = _normalizeRadioToOptions(raw, values);
      if (fixed != raw.toString()) {
        _formNotifier.handleChange(name, fixed,
            type: type, validationType: f['validation']?.toString());
      }
    }
  }

  bool get _isBpWealthCompany =>
      widget.company.toLowerCase().trim() == 'bpwealth';

  /// BP Wealth only: merge dropoff, normalize radios, then PEP/citizen/tax/tariff defaults.
  void _runPersonalDetailsBpWealthPipeline(
    AppStore store,
    List<dynamic> fieldList,
  ) {
    if (!_isBpWealthCompany) return;
    final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
    var position = ctx?['position']?.toString().toLowerCase() ?? '';
    var pageLabel =
        ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
    if (position.isEmpty || pageLabel.isEmpty) {
      final workflow = store.fields as Map?;
      position = (workflow?['position']?.toString() ?? '').toLowerCase();
      pageLabel = (workflow?['data']?['label']?.toString() ?? '').toLowerCase();
    }
    final isPersonalDetails =
        position == 'personal_details' || pageLabel == 'personal_details';
    if (!isPersonalDetails) return;

    debugPrint(
        '[HomePage] personal_details BP Wealth pipeline: fields=${fieldList.length}');
    _mergePersonalDetailsFromFieldDefinitions(fieldList);
    _normalizePersonalDetailRadios(fieldList); // radio + select (dropdowns)
    _applyPersonalDetailsDefaults(fieldList);
  }

  /// Personal details step: defaults when API/dropoff did not pre-fill.
  void _applyPersonalDetailsDefaults(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      if (!_shouldMergeFromApi(_formNotifier.formData[name])) continue;

      final dn = (f['displayName']?.toString() ?? '').toLowerCase();
      final nl = name.toLowerCase();
      final type = f['type']?.toString() ?? '';
      final values = f['values'] as List?;
      final validation = f['validation']?.toString();

      if (type == 'radio' || type == 'select') {
        final vYes = _matchRadioOption(values, 'Yes');
        final vNo = _matchRadioOption(values, 'No');

        final politicallyExposed = nl.contains('pep') ||
            (dn.contains('political') &&
                (dn.contains('expos') ||
                    dn.contains('pep') ||
                    dn.contains('person'))) ||
            (nl.contains('political') && nl.contains('expos')) ||
            dn.contains('politically');
        if (politicallyExposed && vNo != null) {
          _formNotifier.handleChange(name, vNo,
              type: type, validationType: validation);
          continue;
        }

        final citizenIndia = (dn.contains('citizen') && dn.contains('india')) ||
            (nl.contains('citizen') &&
                (nl.contains('india') || nl.contains('indian')));
        if (citizenIndia && vYes != null) {
          _formNotifier.handleChange(name, vYes,
              type: type, validationType: validation);
          continue;
        }

        final taxResidencyOutside =
            (dn.contains('tax') && dn.contains('residen')) ||
                (nl.contains('tax') && nl.contains('residen')) ||
                (dn.contains('residen') && dn.contains('outside')) ||
                nl.contains('tax_resid') ||
                nl.contains('tax_residency');
        if (taxResidencyOutside && vNo != null) {
          _formNotifier.handleChange(name, vNo,
              type: type, validationType: validation);
          continue;
        }

        // Tariff / "continue your journey" style dropdown — pick default/tariff option if any.
        final journeyTariff = dn.contains('tariff') ||
            nl.contains('tariff') ||
            (dn.contains('journey') && dn.contains('continue')) ||
            (dn.contains('please select') && dn.contains('continue')) ||
            (dn.contains('option') && dn.contains('continue'));
        if (journeyTariff && values != null && values.isNotEmpty) {
          String? pick;
          for (final o in values) {
            final s = o.toString();
            final sl = s.toLowerCase();
            if (sl.contains('default') ||
                sl.contains('tariff') ||
                sl.contains('brokerage') ||
                sl.contains('stoxbox')) {
              pick = s;
              break;
            }
          }
          pick ??= values.first.toString();
          _formNotifier.handleChange(name, pick,
              type: type, validationType: validation);
          continue;
        }
        continue;
      }

      if (type == 'checkbox') {
        final tariff = dn.contains('tariff') || nl.contains('tariff');
        if (tariff) {
          _formNotifier.handleChange(name, true,
              type: 'checkbox', validationType: validation);
        }
      }
    }
  }

  Widget _buildForm(
    List fieldList,
    dynamic activeFields,
    Map? submitButton,
    AppStore store,
    bool isAuth,
  ) {
    // Check if this is segments screen / mobile screen
    final withAuth = store.fieldsWithAuth as Map?;
    final ctx = withAuth?['context'] as Map?;

    String? position = ctx?['position']?.toString()?.toLowerCase();
    String? pageLabel =
        ctx?['page']?['data']?['label']?.toString()?.toLowerCase();

    // Fallback for unauthenticated flow where context may be null:
    // use workflow root from store.fields (get-workflow-details response)
    if (position == null ||
        position.isEmpty ||
        pageLabel == null ||
        pageLabel.isEmpty) {
      final workflow = store.fields as Map?;
      position =
          (workflow?['position']?.toString() ?? position ?? '').toLowerCase();
      pageLabel = (workflow?['data']?['label']?.toString() ?? pageLabel ?? '')
          .toLowerCase();
    }

    debugPrint('[HomePage] _buildForm position=$position pageLabel=$pageLabel');

    final isSegmentsScreen = position == 'segments';

    // BP Wealth requirement: on Segments step, preselect all segment checkboxes
    // by default. We only set keys that are currently unset so user edits are
    // preserved on rebuilds.
    if (isSegmentsScreen && widget.company.toLowerCase() == 'bpwealth') {
      const segmentKeys = <String>[
        'nse_cash',
        'nse_fo',
        'nse_slbm',
        'bse_cash',
        'bse_fo',
        'mf',
      ];
      var didApplyDefaults = false;
      for (final key in segmentKeys) {
        if (_formNotifier.formData[key] == null) {
          _formNotifier.formData[key] = true;
          didApplyDefaults = true;
        }
      }
      if (didApplyDefaults) {
        debugPrint(
            '[HomePage] Applied default segment selections for bpwealth');
      }

      // UI says "Default Brokerage plan applied"; keep validation state aligned
      // so user is not blocked with "Please select brokerage plan".
      final brokerage =
          _formNotifier.formData['brokerage_plan']?.toString().trim() ?? '';
      if (brokerage.isEmpty) {
        _formNotifier.handleChange('brokerage_plan', 'Brokerage Plan');
        debugPrint('[HomePage] Applied default brokerage_plan for segments');
      }
    }

    // Show segments selection UI for segments screen
    if (isSegmentsScreen) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        padding: const EdgeInsets.fromLTRB(
          KycTheme.spacing3xl,
          KycTheme.spacing2xl,
          KycTheme.spacing3xl,
          KycTheme.spacing2xl,
        ),
        decoration: BoxDecoration(
          color: KycTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KycTheme.border),
          boxShadow: KycTheme.cardShadow,
        ),
        child: SegmentsSelection(
          formData: _formNotifier.formData,
          onChange: (name, value) {
            _formNotifier.handleChange(name, value);
          },
          onViewBrokeragePlan: () {
            BrokeragePlanDialog.show(
              context,
              () {
                // Set brokerage_plan in form data when user clicks Done
                _formNotifier.handleChange('brokerage_plan', 'Brokerage Plan');
                Fluttertoast.showToast(
                    msg: 'Brokerage Plan selected', gravity: ToastGravity.TOP);
              },
            );
          },
          onSubmit: _submitLoading
              ? null
              : () {
                  if (isAuth) {
                    _handleCommonSubmit(false);
                  } else {
                    _handleSubmit(false);
                  }
                },
          submitLoading: _submitLoading,
        ),
      );
    }
    final visibleFields = fieldList.where((f) {
      if (f is! Map) return false;
      final name = f['name']?.toString();
      final initialShow = f['fieldShow'] ?? true;

      // If conditional flow has explicitly set visibility, use that (takes precedence)
      // Otherwise, use initial fieldShow value from API
      final dynamicVisibility = _formNotifier.fieldVisibility[name];
      final show = dynamicVisibility ?? initialShow;

      return show;
    }).toList();

    final otpField = visibleFields.cast<Map?>().where((f) {
      if (f == null) return false;
      final t = f['type']?.toString();
      final n = (f['name']?.toString() ?? '').toLowerCase();
      return t == 'otp' || n == 'otp' || n == 'otp_code';
    }).firstOrNull;
    final otpFieldName = otpField?['name']?.toString();

    // Hide sirf "confirm OTP" / re-enter OTP type field – design: one OTP entry
    // Account number jaise "Confirm Account Number" fields ko HIDE mat karo
    // Filter step-specific fields: no mobile inputs on mobile_otp, no email input on email_otp
    final isMobileOtpScreen = position == 'mobile_otp';
    final isEmailOtpScreen = position == 'email_otp';

    final visibleFieldsForDisplay = visibleFields.where((f) {
      if (f is! Map) return false;

      // On mobile_otp screen: HIDE all mobile/phone input fields
      if (isMobileOtpScreen) {
        final fieldName = (f['name']?.toString() ?? '').toLowerCase();
        if (fieldName == 'mobile' ||
            fieldName == 'phone' ||
            fieldName == 'mobile_number' ||
            fieldName == 'phone_number' ||
            fieldName.contains('mobile') ||
            fieldName.contains('phone')) {
          return false; // Hide mobile input fields
        }
      }

      // On email_otp screen: HIDE email input field (OTP only; no email field below)
      if (isEmailOtpScreen) {
        final fieldName = (f['name']?.toString() ?? '').toLowerCase();
        final type = (f['type']?.toString() ?? '').toLowerCase();
        final isOtpField =
            type == 'otp' || fieldName == 'otp' || fieldName == 'otp_code';
        if (!isOtpField &&
            (fieldName == 'email' ||
                fieldName == 'email_id' ||
                fieldName == 'emailid' ||
                fieldName.contains('email'))) {
          return false; // Hide email input on OTP verify screen
        }
      }

      // Agar OTP field identified hai aur yeh field usi OTP ko validateWith kar rahi hai
      // (confirm OTP / re-enter OTP), tabhi hide karo
      if (otpFieldName != null &&
          (f['validateWith']?.toString() ?? '') == otpFieldName) {
        return false;
      }

      // Baaki sab fields (including reenter_account_number) dikhao
      return true;
    }).toList();

    // Sequence: OTP field pahle dikhao, phir baaki fields
    if (otpField != null) {
      visibleFieldsForDisplay.sort((a, b) {
        final aIsOtp = a['name'] == otpFieldName;
        final bIsOtp = b['name'] == otpFieldName;
        if (aIsOtp && !bIsOtp) return -1;
        if (!aIsOtp && bIsOtp) return 1;
        return 0;
      });
    }

    // Extract Aadhaar image (Digilocker success) from "aadhar_image" field
    Uint8List? aadharImageBytes;
    String? aadharImageUrl;
    bool hasAadharImage = false;

    final bool isDigilockerScreen =
        position == 'digilocker' || pageLabel == 'digilocker';
    if (isDigilockerScreen) {
      final aadharField = visibleFieldsForDisplay.cast<Map?>().firstWhere(
        (f) {
          if (f == null) return false;
          final n = (f['name']?.toString() ?? '').toLowerCase();
          return n == 'aadhar_image' || n == 'aadhaar_image';
        },
        orElse: () => null,
      );

      if (aadharField != null) {
        final aName = aadharField['name']?.toString() ?? '';
        final rawValue = _formNotifier.formData[aName] ?? aadharField['value'];
        final valueStr = rawValue?.toString() ?? '';
        if (valueStr.isNotEmpty) {
          if (valueStr.startsWith('http')) {
            aadharImageUrl = valueStr;
          } else {
            String base64Data = valueStr.trim();
            final match =
                RegExp(r'data:image/[^;]+;base64,', caseSensitive: false)
                    .firstMatch(base64Data);
            if (match != null) {
              base64Data = base64Data.substring(match.end);
            }
            try {
              aadharImageBytes = base64Decode(base64Data);
            } catch (_) {
              aadharImageBytes = null;
            }
          }
        }
        hasAadharImage = aadharImageBytes != null ||
            (aadharImageUrl != null && aadharImageUrl!.isNotEmpty);
      }
    }

    // Generic submit button: sirf tab dikhao jab OTP field nahi hai
    // Agar OTP field hai (chahe kitni bhi aur fields ho), sirf OtpVerifySection ka "Verify OTP" button use hoga
    final showGenericSubmit = otpField == null;
    final isMobileStep = position == 'mobile' || pageLabel == 'mobile';

    return Container(
      // No outer margin so width matches "Documents to keep Handy" card
      padding: EdgeInsets.all(isMobileStep ? 20 : KycTheme.spacing2xl),
      decoration: BoxDecoration(
        color: KycTheme.surface,
        borderRadius: BorderRadius.circular(KycTheme.radiusLg),
        border: Border.all(color: KycTheme.border),
        boxShadow: KycTheme.cardShadow,
      ),
      child: Form(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasAadharImage) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: aadharImageBytes != null
                      ? Image.memory(
                          aadharImageBytes!,
                          fit: BoxFit.cover,
                        )
                      : Image.network(
                          aadharImageUrl!,
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            final expected = loadingProgress.expectedTotalBytes;
                            final value = expected != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                    expected
                                : null;
                            return Center(
                              child: CircularProgressIndicator(
                                value: value,
                                strokeWidth: 2,
                                color: KycTheme.primary,
                              ),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                            color: Colors.grey.shade200,
                            alignment: Alignment.center,
                            child: const Text(
                              'Preview not available',
                              style: TextStyle(
                                fontSize: 12,
                                color: KycTheme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            ...visibleFieldsForDisplay.map((field) {
              if (field is! Map) return const SizedBox.shrink();
              final name = field['name']?.toString() ?? '';
              final type = field['type']?.toString() ?? 'text';
              final lowerName = name.toLowerCase();
              final isAadharImageField =
                  lowerName == 'aadhar_image' || lowerName == 'aadhaar_image';
              if (isAadharImageField && hasAadharImage) {
                // Image already rendered at top of form; hide underlying field
                return const SizedBox.shrink();
              }
              if (otpField != null && name == otpFieldName) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: _buildOtpVerifyCard(otpField, activeFields),
                );
              }

              // Check if this is IFSC field on bank / bank_details screen
              // Use position and ctx already declared at function start
              final label =
                  ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
              final isBankScreen = position == 'bank' ||
                  position == 'bank_details' ||
                  label == 'bank';
              final isIfscField = isBankScreen &&
                  (name == 'ifsc' || name.toLowerCase().contains('ifsc'));

              final editableFields = _formNotifier.editableFieldsList;
              final disable =
                  editableFields.any((e) => e is Map && e['name'] == name);

              // Check if this is email field on email step
              // Support multiple position keys / labels: "email", "email_id", "emailid"
              final isEmailStep = position == 'email' ||
                  position == 'emailid' ||
                  position == 'email_id' ||
                  label == 'email';
              final isEmailField = (name.toLowerCase() == 'email' ||
                      name.toLowerCase() == 'email_id' ||
                      name.toLowerCase() == 'emailid' ||
                      name.toLowerCase().contains('email')) &&
                  type == 'text';

              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FormFieldWidget(
                      name: name,
                      displayName: field['displayName'] ?? name,
                      type: type,
                      fileType: field['fileType'] as List?,
                      size: field['size'],
                      mandatory: field['mandatory'] == true,
                      validation: field['validation'],
                      popupAfterSubmit:
                          activeFields?['popupAfterSubmit'] as List?,
                      value: _coalesceFormFieldValue(
                        _formNotifier.formData[name],
                        field['value'],
                      ),
                      onGoogleSignIn: _handleGoogleSignIn,
                      googleSignInLoading: _googleSignInLoading,
                      onChange: (n, v) {
                        final f = fieldList.cast<Map?>().firstWhere(
                              (x) => x?['name'] == n,
                              orElse: () => null,
                            );
                        _formNotifier.handleChange(
                          n,
                          v,
                          type: f?['type'] ?? 'text',
                          validationType: f?['validation']?.toString(),
                          validateWith: f?['validateWith']?.toString(),
                        );
                        if (pageLabel == 'mobile' &&
                            (n == 'mobile' ||
                                n == 'phone' ||
                                n == 'mobile_number')) {
                          setState(() => _showMobileError = false);
                        }
                      },
                      onBlur: (n) {
                        _formNotifier.handleBlur(n);
                        // Auto-fetch on blur for IFSC field
                        if (isIfscField) {
                          final ifscValue =
                              _formNotifier.formData[n]?.toString() ?? '';
                          if (ifscValue.length == 11) {
                            _fetchBankDetailsByIfsc(ifscValue);
                          }
                        }
                      },
                      values: field['values'] as List?,
                      visible: true,
                      errorField: _formNotifier.errors[name],
                      rows: field['rows'] is int
                          ? field['rows']
                          : int.tryParse(field['rows']?.toString() ?? ''),
                      cols: field['cols'] is int
                          ? field['cols']
                          : int.tryParse(field['cols']?.toString() ?? ''),
                      urlCompany: widget.company,
                      workflowKey: (store.fieldsWithAuth as Map?)?['context']
                              ?['workflow_key']
                          ?.toString(),
                      disable: disable,
                    ),
                    // Add "Sign in with Google" button below email field on email step
                    if (isEmailStep && isEmailField) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed:
                            _googleSignInLoading ? null : _handleGoogleSignIn,
                        icon: const Icon(Icons.g_mobiledata, size: 20),
                        label: Text(_googleSignInLoading
                            ? 'Signing in...'
                            : 'Sign in with Google'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16),
                          side: BorderSide(color: KycTheme.primary),
                          foregroundColor: KycTheme.primary,
                        ),
                      ),
                    ],
                    // Add "Fetch Bank Details" button below IFSC field
                    if (isIfscField) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          final ifscValue =
                              _formNotifier.formData[name]?.toString() ?? '';
                          if (ifscValue.length == 11) {
                            _fetchBankDetailsByIfsc(ifscValue);
                          } else {
                            Fluttertoast.showToast(
                                msg: 'Please enter valid 11-digit IFSC code',
                                gravity: ToastGravity.TOP);
                          }
                        },
                        icon: const Icon(Icons.search, size: 20),
                        label: const Text('Fetch Bank Details'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16),
                          side: BorderSide(color: KycTheme.primary),
                          foregroundColor: KycTheme.primary,
                        ),
                      ),
                    ],
                    // Show error below mobile input when validation fails on Send OTP
                    if (pageLabel == 'mobile' &&
                        (name == 'mobile' ||
                            name == 'phone' ||
                            name == 'mobile_number') &&
                        _showMobileError) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline,
                              size: 16, color: Colors.red.shade700),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Please enter a valid 10-digit mobile number',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.red.shade700),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            }),
            // Terms & Conditions and Aadhaar note (mobile login step only)
            // Show only when API page label AND position both indicate "mobile"
            if (pageLabel == 'mobile') ...[
              const SizedBox(height: 15),
              // Custom checkbox (not default Material) + clickable Terms and Conditions
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => setState(() {
                      _termsAccepted = !_termsAccepted;
                      if (_termsAccepted) _showTermsError = false;
                    }),
                    child: Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: _termsAccepted
                            ? KycTheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: _termsAccepted
                              ? KycTheme.primary
                              : KycTheme.border,
                          width: 2,
                        ),
                      ),
                      child: _termsAccepted
                          ? const Icon(Icons.check,
                              size: 14, color: Colors.white)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                            fontSize: 12,
                            color: KycTheme.textPrimary,
                            height: 1.4),
                        children: [
                          const TextSpan(text: 'Please accept the '),
                          TextSpan(
                            text: 'Terms and Conditions',
                            style: const TextStyle(
                              color: KycTheme.primary,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => _showTermsModal(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (_showTermsError && !_termsAccepted) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 34.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline,
                          size: 16, color: Colors.red.shade700),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Please accept the Terms & Conditions to continue',
                          style: TextStyle(
                              fontSize: 12, color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _buildAadhaarNote(),
              const SizedBox(height: 16),
            ],
            if (showGenericSubmit) const SizedBox(height: 24),
            if (showGenericSubmit)
              ElevatedButton(
                onPressed: _submitLoading || _isSendOtpDisabled(position)
                    ? null
                    : () {
                        debugPrint(
                            '[HomePage] Submit button clicked! isAuth=$isAuth, position=$position');
                        if (isAuth) {
                          _handleCommonSubmit(false);
                        } else {
                          _handleSubmit(false);
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isMobileStep
                      ? (_isSendOtpDisabled(position)
                          ? KycTheme.buttonDisabledPurple
                          : KycTheme.buttonEnabledPurple)
                      : KycTheme.primary,
                  foregroundColor: Colors.white,
                  minimumSize: Size(double.infinity, isMobileStep ? 52 : 48),
                  padding:
                      const EdgeInsets.symmetric(vertical: KycTheme.spacingLg),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                        isMobileStep ? 14 : KycTheme.radiusMd),
                  ),
                ),
                child: _submitLoading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          ),
                          SizedBox(width: 12),
                          Text('Processing...',
                              style: TextStyle(color: Colors.white)),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(isMobileStep
                              ? 'Send OTP'
                              : (submitButton?['buttonName'] ?? 'Submit')),
                          if (!isMobileStep) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.arrow_forward,
                                size: 20, color: Colors.white),
                          ],
                        ],
                      ),
              ),
            if (showGenericSubmit &&
                submitButton?['showSubmitAnywayButton'] == true) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.yellow.shade50,
                  border: Border.all(color: Colors.yellow.shade200),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'You can submit the form without filling field.',
                      style: TextStyle(color: Colors.yellow.shade900),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _submitLoading
                          ? null
                          : () {
                              if (isAuth) {
                                _handleCommonSubmit(true);
                              } else {
                                _handleSubmit(true);
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KycTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(submitButton?['submitAnywayButtonName'] ??
                          'Submit Anyway'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock, size: 16, color: KycTheme.textSecondary),
                const SizedBox(width: 8),
                Text(
                  'Your information is securely encrypted',
                  style: TextStyle(fontSize: 12, color: KycTheme.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Disable Send OTP on mobile step until 10 digits entered AND terms accepted
  bool _isSendOtpDisabled(String? position) {
    if (position != 'mobile') return false;
    if (!_termsAccepted) return true;
    final mobile = _formNotifier.formData['mobile'] ??
        _formNotifier.formData['phone'] ??
        _formNotifier.formData['mobile_number'] ??
        '';
    final digits = mobile.toString().replaceAll(RegExp(r'\D'), '');
    return digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits);
  }

  void _showTermsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Terms & Conditions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'By signing up, You agree that BP Equities Pvt. Ltd. / StoxBox representative may contact you telephonically in connection with the services or your registration on the platform or to introduce new product/ service offerings.',
                style: TextStyle(fontSize: 14, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAadhaarNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KycTheme.spacingLg),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
        border: Border.all(color: KycTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                    fontSize: 13, color: KycTheme.textPrimary, height: 1.4),
                children: [
                  const TextSpan(
                    text:
                        'Note: Online account opening requires your number to be linked with Aadhaar. You can check if your mobile number is linked to Aadhaar ',
                  ),
                  TextSpan(
                    text: 'here',
                    style: const TextStyle(
                      color: KycTheme.primary,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () async {
                        final uri =
                            Uri.parse('https://resident.uidai.gov.in/verify');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                        }
                      },
                  ),
                  const TextSpan(
                    text:
                        '. If your mobile number isn\'t linked to Aadhaar, please open your account offline.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Extract 10-digit Indian mobile from form map only (no persisted fallback).
  String _digitsFromFormMapOnly(Map<String, dynamic> fd) {
    const keys = ['change_mobile', 'mobile_number', 'mobile', 'phone'];
    for (final key in keys) {
      final raw = fd[key];
      if (raw == null) continue;
      final digits = raw.toString().replaceAll(RegExp(r'\D'), '');
      if (digits.length == 10 && RegExp(r'^[6-9]').hasMatch(digits)) {
        return digits;
      }
    }
    for (final key in keys) {
      final raw = fd[key];
      if (raw == null) continue;
      final digits = raw.toString().replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 10) {
        final last10 = digits.substring(digits.length - 10);
        if (RegExp(r'^[6-9]').hasMatch(last10)) return last10;
      }
    }
    return '';
  }

  /// Prefer live form data; fall back to [ _persistedMobileDigitsForOtp ] after get-context reset.
  String _resolveMobileDigitsForOtpUi(Map<String, dynamic> fd) {
    final fromForm = _digitsFromFormMapOnly(fd);
    if (fromForm.length == 10) return fromForm;
    final p = _persistedMobileDigitsForOtp;
    if (p != null && p.length == 10 && RegExp(r'^[6-9]').hasMatch(p)) {
      return p;
    }
    return '';
  }

  void _applyPersistedMobileToForm() {
    final m = _persistedMobileDigitsForOtp;
    if (m == null || m.length != 10) return;
    _formNotifier.handleChange('mobile_number', m, validationType: 'mobile');
    _formNotifier.handleChange('phone', m, validationType: 'mobile');
    _formNotifier.handleChange('mobile', m, validationType: 'mobile');
    _formNotifier.handleChange('change_mobile', m, validationType: 'mobile');
  }

  String _resolveEmailForOtpUi(Map<String, dynamic> fd) {
    const keys = ['email', 'email_id', 'emailId'];
    for (final key in keys) {
      final raw = fd[key]?.toString().trim() ?? '';
      if (raw.contains('@')) return raw;
    }
    final p = _persistedEmailForOtp?.trim() ?? '';
    return p.contains('@') ? p : '';
  }

  void _applyPersistedEmailToForm() {
    final e = _persistedEmailForOtp?.trim() ?? '';
    if (!e.contains('@')) return;
    _formNotifier.handleChange('email', e, validationType: 'email');
    _formNotifier.handleChange('email_id', e, validationType: 'email');
    _formNotifier.handleChange('emailId', e, validationType: 'email');
  }

  Future<void> _handleGoogleSignIn() async {
    if (_googleSignInLoading) return;
    setState(() => _googleSignInLoading = true);
    try {
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        // Android: Web client ID is required so Google returns an ID token for Firebase Auth.
        serverClientId: Platform.isAndroid
            ? DefaultFirebaseOptions.googleOAuthWebClientId
            : null,
      );
      final selectedAccount = await googleSignIn.signIn();
      if (selectedAccount == null) {
        Fluttertoast.showToast(
          msg: 'Sign-in cancelled',
          gravity: ToastGravity.TOP,
        );
        return;
      }

      final authData = await selectedAccount.authentication;
      if (authData.idToken == null || authData.idToken!.isEmpty) {
        debugPrint(
          '[GoogleSignIn] idToken missing; check SHA-1 in Firebase & Web client ID.',
        );
        Fluttertoast.showToast(
          msg:
              'Could not get Google credentials. Check app signing (SHA-1) in Firebase.',
          gravity: ToastGravity.TOP,
        );
        return;
      }
      final credential = GoogleAuthProvider.credential(
        accessToken: authData.accessToken,
        idToken: authData.idToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final email =
          (userCredential.user?.email ?? selectedAccount.email).trim();
      if (email.isEmpty) {
        Fluttertoast.showToast(
          msg: 'Google account email not available',
          gravity: ToastGravity.TOP,
        );
        return;
      }

      _persistedEmailForOtp = email;
      _applyPersistedEmailToForm();
      Fluttertoast.showToast(
        msg: 'Google sign-in successful',
        gravity: ToastGravity.TOP,
      );
    } on FirebaseAuthException catch (e) {
      debugPrint(
          '[GoogleSignIn] FirebaseAuthException: ${e.code} ${e.message}');
      Fluttertoast.showToast(
        msg: e.message ?? 'Google sign-in failed',
        gravity: ToastGravity.TOP,
      );
    } on PlatformException catch (e) {
      debugPrint('[GoogleSignIn] PlatformException: ${e.code} ${e.message}');
      final msg = e.code == 'sign_in_failed' || e.code == '10'
          ? 'Google Sign-In setup error. Add debug SHA-1 in Firebase Console.'
          : (e.message ?? 'Google sign-in failed');
      Fluttertoast.showToast(msg: msg, gravity: ToastGravity.TOP);
    } catch (e, st) {
      debugPrint('[GoogleSignIn] $e\n$st');
      Fluttertoast.showToast(
        msg: 'Unable to sign in with Google. Please try again.',
        gravity: ToastGravity.TOP,
      );
    } finally {
      if (mounted) {
        setState(() => _googleSignInLoading = false);
      }
    }
  }

  /// Edit from OTP screen: `GET /api_review_edit_page/...` — only on success refresh journey via get-context.
  Future<void> _requestReviewEditAndRefreshContext(String currentField) async {
    final store = context.read<AppStore>();
    if (!mounted) return;
    setState(() => _submitLoading = true);
    try {
      debugPrint(
          '[HomePage] review_edit_page: $currentField (${widget.company}/${widget.workflowName})');
      final res = await KycAPI.reviewEditPage(
        widget.company,
        widget.workflowName,
        currentField,
      );
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (_) {
        body = null;
      }
      final success =
          body?['success'] == true || body?['success']?.toString() == 'true';
      if (res.statusCode < 200 || res.statusCode >= 300 || !success) {
        final msg = body?['msg']?.toString() ??
            body?['message']?.toString() ??
            'Could not open edit for this step';
        Fluttertoast.showToast(msg: msg, gravity: ToastGravity.TOP);
        return;
      }
      debugPrint('[HomePage] review_edit_page OK — fetching get-context');
      await store.fetchWorkflowFieldsWithAuth(
          widget.company, widget.workflowName, '');
      if (!mounted) return;
      if (store.errorWithAuth != null) {
        Fluttertoast.showToast(
            msg: store.errorWithAuth!, gravity: ToastGravity.TOP);
        return;
      }
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 200));
        await _checkAndHandleRedirect(store);
        if (!mounted) return;
        final response = store.fieldsWithAuth;
        if (response is! Map || response['redirect'] != true) {
          context.go('/${widget.company}/${widget.workflowName}');
        }
      }
    } catch (e, st) {
      debugPrint('[HomePage] review_edit_page error: $e\n$st');
      Fluttertoast.showToast(
          msg: 'Something went wrong. Please try again.',
          gravity: ToastGravity.TOP);
    } finally {
      if (mounted) setState(() => _submitLoading = false);
    }
  }

  /// OTP verify card: separate UI for email_otp vs mobile_otp (Figma)
  Future<void> _resendOtpByPosition({
    required AppStore store,
    required String positionSegment,
    required Map<String, dynamic> payload,
    required String failureMessage,
  }) async {
    final endpoint = '/api/resend-otp/$positionSegment';
    debugPrint('[HomePage] Resend OTP via $endpoint payload=$payload');
    final client = ApiClient();
    final res = await client.post(endpoint, body: payload);
    debugPrint('[HomePage] Resend OTP response status=${res.statusCode}');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Fluttertoast.showToast(
        msg: _errorMessageFromResponse(res.statusCode, res.body),
        gravity: ToastGravity.TOP,
      );
      return;
    }
    await store.fetchWorkflowFieldsWithAuth(
        widget.company, widget.workflowName, '');
    if (mounted && store.errorWithAuth != null) {
      Fluttertoast.showToast(
        msg: store.errorWithAuth ?? failureMessage,
        gravity: ToastGravity.TOP,
      );
      return;
    }
  }

  String _getResendOtpPositionSegment(Map? ctx, String fallbackPosition) {
    final position = (ctx?['position']?.toString().toLowerCase() ?? '').trim();
    final pageId = (ctx?['page']?['id']?.toString() ?? '').trim();
    final effectivePosition = position.isNotEmpty ? position : fallbackPosition;
    if (pageId.isEmpty) return effectivePosition;
    return '$effectivePosition$pageId';
  }

  Future<void> _resendMobileOtpAfterEdit(String mobileNumber) async {
    _persistedMobileDigitsForOtp = mobileNumber;
    final store = context.read<AppStore>();
    FocusScope.of(context).unfocus();
    if (!mounted) return;
    setState(() => _submitLoading = true);
    try {
      final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
      final resendPositionSegment =
          _getResendOtpPositionSegment(ctx, 'mobile_otp');
      final payload = <String, dynamic>{'mobile_number': mobileNumber};
      await _resendOtpByPosition(
        store: store,
        positionSegment: resendPositionSegment,
        payload: payload,
        failureMessage: 'Failed to refresh OTP step',
      );
    } finally {
      if (mounted) {
        setState(() => _submitLoading = false);
      }
    }
  }

  Future<void> _resendEmailOtpAfterEdit(String email) async {
    final store = context.read<AppStore>();
    final trimmed = email.trim();
    _persistedEmailForOtp = trimmed;
    FocusScope.of(context).unfocus();
    if (!mounted) return;
    setState(() => _submitLoading = true);
    try {
      final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
      final resendPositionSegment =
          _getResendOtpPositionSegment(ctx, 'email_otp');
      final payload = <String, dynamic>{'email': trimmed};
      await _resendOtpByPosition(
        store: store,
        positionSegment: resendPositionSegment,
        payload: payload,
        failureMessage: 'Failed to refresh OTP step',
      );
      if (mounted) {
        _applyPersistedEmailToForm();
      }
    } catch (_) {
      Fluttertoast.showToast(
          msg: 'Failed to resend email OTP', gravity: ToastGravity.TOP);
    } finally {
      if (mounted) {
        setState(() => _submitLoading = false);
      }
    }
  }

  // Previous flow: Edit opened a modal and then called get-user / kyc-post resend.
  // Replaced by `_requestReviewEditAndRefreshContext` → GET `/api_review_edit_page/...` then get-context.

  Widget _buildOtpVerifyCard(Map otpField, dynamic activeFields) {
    final otpName = otpField['name']?.toString() ?? 'otp';
    final formData = _formNotifier.formData;
    final store = context.read<AppStore>();
    final position = (store.fieldsWithAuth as Map?)?['context']?['position']
            ?.toString()
            .toLowerCase() ??
        '';
    final isEmailOtp =
        position == 'email_otp' || position.startsWith('email_otp');
    final isMobileOtp =
        position == 'mobile_otp' || position.startsWith('mobile_otp');

    // Step-specific copy: no mobile/SMS wording on email_otp
    final String sentToText;
    final VoidCallback? onEdit;
    if (isEmailOtp) {
      final displayEmail = _resolveEmailForOtpUi(formData);
      sentToText =
          'We have sent you an OTP on ${displayEmail.isEmpty ? 'your email' : displayEmail}';
      onEdit = () {
        _requestReviewEditAndRefreshContext('change_email');
      };
    } else {
      final displayDigits = _resolveMobileDigitsForOtpUi(formData);
      sentToText =
          'We have sent you an OTP via sms on +91 ${displayDigits.isEmpty ? '' : displayDigits}';
      onEdit = isMobileOtp
          ? () {
              _requestReviewEditAndRefreshContext('change_mobile');
            }
          : null;
    }

    Map<String, dynamic>? otpExpiry;
    if (otpField.containsKey('otpExpiry') && otpField['otpExpiry'] is Map) {
      otpExpiry = Map<String, dynamic>.from(otpField['otpExpiry'] as Map);
      debugPrint('[HomePage] OTP expiry config: $otpExpiry');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OtpVerifySection(
          sentToText: sentToText,
          onEdit: onEdit,
          onVerify: (otp) {
            _formNotifier.handleChange(otpName, otp);
            _handleCommonSubmit(false);
          },
          onResendOtp: () {
            debugPrint('[HomePage] Resend OTP clicked');
            _formNotifier.handleChange(otpName, '');
            if (isMobileOtp) {
              final digits = _resolveMobileDigitsForOtpUi(
                  Map<String, dynamic>.from(_formNotifier.formData));
              debugPrint(
                  '[HomePage] Resend OTP resolved digits len=${digits.length}');
              if (digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits)) {
                Fluttertoast.showToast(
                  msg: 'Please use Edit to enter a valid mobile number',
                  gravity: ToastGravity.TOP,
                );
                return;
              }
              _resendMobileOtpAfterEdit(digits);
            } else {
              final email = _resolveEmailForOtpUi(
                  Map<String, dynamic>.from(_formNotifier.formData));
              if (!email.contains('@')) {
                Fluttertoast.showToast(
                  msg: 'Please use Edit to enter a valid email',
                  gravity: ToastGravity.TOP,
                );
                return;
              }
              _resendEmailOtpAfterEdit(email);
            }
          },
          otpExpiry: otpExpiry,
          verifyLoading: _submitLoading,
          useSixBoxes: false, // Email OTP: single input per Figma (no 6 boxes)
        ),
        const SizedBox(height: 20),
        KycNoteBox(
          text: KycNoteBox.aadhaarNote,
          linkText: 'here',
          onLinkTap: () {
            // Optional: open Aadhaar link
          },
        ),
      ],
    );
  }
}
