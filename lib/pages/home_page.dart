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
import 'package:meon_kyc/sso/sso_temp_credentials_gate.dart';
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
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/api_error_message.dart';
import 'package:meon_kyc/utils/field_validators.dart';
import 'package:meon_kyc/utils/kyc_date_utils.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:flutter/gestures.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

class HomePage extends StatefulWidget {
  final String company;
  final String workflowName;
  final Map<String, String> queryParams;

  const HomePage({
    super.key,
    required this.company,
    required this.workflowName,
    this.queryParams = const {},
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ConditionalFormNotifier _formNotifier;
  bool _submitLoading = false;
  bool _resendOtpLoading = false;
  bool _webViewTransitionActive = false;
  bool _logoutLoading = false;
  // Non-null when an API call fails while we're returning from WebView.
  // Triggers the retry UI instead of the old step's form UI.
  String? _webViewReturnError;
  // True while _loadWorkflow() is actively running — prevents concurrent calls.
  bool _loadWorkflowActive = false;
  // Message shown in the partial loader during WebView return flow.
  String _returnFlowMessage = 'Loading your next step...';
  // One-shot timers: 5 s → slow-network message, 20 s → show retry UI.
  Timer? _returnFlowWatchdogTimer;
  // 5 s periodic: auto-retries _loadWorkflow() if stuck with no active call.
  Timer? _returnFlowPollingTimer;
  bool _refreshLoading = false;
  bool _backLoading = false;
  String _submitError = '';
  String _submitSuccess = '';
  /// PAN step (`pan10`): last `kyc-post-v2` `msg` / `message` from API (shown on form).
  String _panStepApiFeedback = '';
  bool _panStepApiFeedbackIsError = false;
  bool _termsAccepted = false; // Terms & Conditions checkbox (mobile step)
  bool _showTermsError = false; // Show validation message under T&C checkbox
  bool _showMobileError = false; // Show error below mobile input when invalid on submit
  bool _googleSignInLoading = false;
  /// One fetch of `/api/user-details` per DigiLocker step visit (fresh Aadhaar photo URL).
  bool _digilockerUserDetailsFetchStarted = false;

  // One-shot guard: if we already attempted SSO for this widget instance,
  // don't retry on rebuild.
  bool _ssoAttempted = false;
  bool _ssoInProgress = false;

  /// Kept when rehydrating after get-context (see `_handleSubmitResponse`): `mobile_otp`
  /// resend + header text still know the number (get-context fields often omit it).
  String? _persistedMobileDigitsForOtp;
  String? _persistedEmailForOtp;

  /// Segments step only: user must open brokerage dialog and tap Done — never default-apply.
  String? _segmentsBrokerageStepKey;
  bool _segmentsBrokerageUserConfirmed = false;
  String? _segmentsBpDefaultsStepKey;

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

  /// Starts a two-stage watchdog (5 s → slow-network msg, 20 s → retry UI)
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

      // Stage 2 – 15 more seconds (20 s total): show retry UI
      _returnFlowWatchdogTimer = Timer(const Duration(seconds: 15), () {
        if (!mounted) return;
        final store = context.read<AppStore>();
        if (!store.isReturningFromWebView || _webViewReturnError != null) {
          return;
        }
        if (_loadWorkflowActive) {
          debugPrint(
              '[HomePage] Return-flow watchdog: still loading, waiting...');
          return;
        }
        if (_shouldOpenRedirectImmediately(store.fieldsWithAuth)) {
          debugPrint(
              '[HomePage] Return-flow watchdog: redirect ready — opening WebView');
          _loadWorkflow();
          return;
        }
        debugPrint('[HomePage] Return-flow watchdog fired — showing retry UI');
        setState(() {
          _webViewReturnError =
              'Connection is taking too long. Please check your network and try again.';
          _returnFlowMessage = 'Loading your next step...';
        });
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
  Future<bool> _trySsoLoginIfNeeded(
    BuildContext context,
    AppStore store,
  ) async {
    if (_ssoAttempted || _ssoInProgress) return _ssoAttempted;

    _ssoInProgress = true;
    try {
      if (!context.mounted) return false;
      final creds = await resolveSsoCredentialsForSsoApi(context);
      if (!context.mounted) return false;
      if (creds == null) {
        debugPrint('[HomePage] SSO skipped — no credentials (dialog dismissed?)');
        return false;
      }
      final mobileNumber = creds.mobileNumber;
      final email = creds.email;

      debugPrint('[HomePage] No access token - attempting SSO login...');
      final tokens = await SsoAPI.getSsoRouteTokens(
        company: widget.company,
        workflowName: widget.workflowName,
        mobileNumber: mobileNumber,
        email: email,
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
      debugPrint('[HomePage] _loadWorkflow already running, skipping duplicate call');
      return;
    }
    if (!mounted) return;
    setState(() {
      _loadWorkflowActive = true;
      _digilockerUserDetailsFetchStarted = false;
    });

    debugPrint('[HomePage] _loadWorkflow START: ${widget.company} / ${widget.workflowName}');
    debugPrint('[HomePage] _loadWorkflow queryParams: ${widget.queryParams}');
    final store = context.read<AppStore>();
    // Tracks whether we navigated away inside this call so the finally block
    // knows not to prematurely clear isReturningFromWebView.
    bool navigatingAway = false;

    // Start watchdog + polling timers only when in the WebView return flow.
    if (store.isReturningFromWebView) _startReturnFlowTimers();

    try {
      store.setParams(company: widget.company, workflowName: widget.workflowName);
      bool hasToken = await StorageService.hasAccessToken();
      debugPrint('[HomePage] _loadWorkflow hasToken=$hasToken');

      // Auto-SSO only on fresh app journey.
      // Do NOT auto-SSO when returning from WebView (keep current token),
      // and do NOT auto-SSO after explicit logout (user should continue with get-user flow).
      final shouldTrySso = !_ssoAttempted &&
          StorageService.ssoAutoLoginEnabled &&
          !store.isReturningFromWebView;
      if (shouldTrySso) {
        debugPrint('[HomePage] First-load: forcing SSO attempt (hasToken=$hasToken)');
        if (mounted) setState(() => _submitLoading = true);
        final ssoOk = context.mounted
            ? await _trySsoLoginIfNeeded(context, store)
            : false;
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
              debugPrint('[HomePage] Extracted workflowId from design_template: $workflowId');
            }
          }
          
          // Also try extracting from user details if available
          if (workflowId == null || workflowId.isEmpty) {
            // Will be fetched later if needed
          }
        }
        
        // --- Stepper API (hidden temporarily) ---
        // Uncomment to fetch step labels for KycStepperBar when re-enabling the stepper.
        // if (workflowId != null && workflowId.isNotEmpty) {
        //   debugPrint('[HomePage] Fetching stepper workflow: ${widget.workflowName} / $workflowId');
        //   // Backend route: /kycadmin_getWorkflow/{workflowName}/{workflowId}
        //   await store.fetchStepperWorkflow(widget.workflowName, workflowId);
        // }
        
        // Check if KYC is completed (is_admin: true)
        if (response is Map && response['is_admin'] == true) {
          debugPrint('[HomePage] KYC completed (is_admin: true) - fetching user details');
          await store.fetchUserDetails();
          if (mounted && store.userDetails != null) {
            // Stepper workflow already fetched above (if workflowId was available)
            // Navigate to KYC Completed page
            navigatingAway = true;
            context.go('/${widget.company}/${widget.workflowName}/completed');
            return;
          } else if (mounted && store.errorUserDetails != null) {
            debugPrint('[HomePage] Error fetching user details: ${store.errorUserDetails}');
            Fluttertoast.showToast(msg: 'Error loading completion details', gravity: ToastGravity.TOP);
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
              '[HomePage] Step completed (success/transaction_id/esign) - handling redirect');

          // API often returns the next external URL (CAMS, DigiLocker, etc.) on the
          // completion-params call itself — open WebView immediately; do not wait for
          // a second get-context (slow/502) while the return-flow loader spins.
          if (mounted && _shouldOpenRedirectImmediately(store.fieldsWithAuth)) {
            debugPrint(
                '[HomePage] External redirect on completion response — opening WebView now');
            _stopReturnFlowTimers();
            await _checkAndHandleRedirect(store);
            if (!mounted) {
              navigatingAway = true;
              return;
            }
          }

          // Refresh context without completion params to update in-app state.
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
            final shouldRetryMultipleTabs = err.toLowerCase().contains('multiple tabs');

            if (shouldRetryMultipleTabs) {
              debugPrint('[HomePage] get-context failed due to multiple tabs - retrying once...');
              await Future.delayed(const Duration(milliseconds: 800));
              await store.fetchWorkflowFieldsWithAuth(
                widget.company,
                widget.workflowName,
                '', // Retry without completion params
              );
              refreshed = store.fieldsWithAuth;
            }

            if (mounted && refreshed is! Map) {
              debugPrint('[HomePage] Error refreshing context after step completion: ${store.errorWithAuth ?? "fieldsWithAuth not a Map"}');
              if (_shouldOpenRedirectImmediately(store.fieldsWithAuth)) {
                debugPrint(
                    '[HomePage] Refresh failed but redirect still available — opening WebView');
                _stopReturnFlowTimers();
                await _checkAndHandleRedirect(store);
                if (!mounted) {
                  navigatingAway = true;
                  return;
                }
              } else if (store.isReturningFromWebView) {
                // Show retry UI — never fall back to the old step's form
                setState(() => _webViewReturnError = friendlyApiErrorMessage(
                    store.errorWithAuth ??
                        'Something went wrong, please try again.'));
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
            debugPrint('[HomePage] KYC completed (is_admin: true) - fetching user details');
            await store.fetchUserDetails();
            if (mounted && store.userDetails != null) {
              navigatingAway = true;
              context.go('/${widget.company}/${widget.workflowName}/completed');
              return;
            } else if (mounted && store.errorUserDetails != null) {
              debugPrint('[HomePage] Error fetching user details: ${store.errorUserDetails}');
              if (store.isReturningFromWebView) {
                setState(() => _webViewReturnError =
                    'Error loading completion details. Please try again.');
              } else {
                Fluttertoast.showToast(msg: 'Error loading completion details', gravity: ToastGravity.TOP);
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
                debugPrint('[HomePage] Navigating to refresh page after step completion');
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
      if (mounted && !navigatingAway && store.isReturningFromWebView && _webViewReturnError == null) {
        store.setReturningFromWebView(false);
        _stopReturnFlowTimers();
      }
    }
  }

  bool _isInternalWorkflowRedirectUrl(String redirectUrl) {
    final lower = redirectUrl.toLowerCase();
    final internalWorkflowPath =
        '/${widget.company.toLowerCase()}/${widget.workflowName.toLowerCase()}';
    if (lower == internalWorkflowPath ||
        lower == '${internalWorkflowPath}/' ||
        lower.startsWith('$internalWorkflowPath?')) {
      return true;
    }
    final uri = Uri.tryParse(redirectUrl);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return path == internalWorkflowPath ||
        path == '${internalWorkflowPath}/' ||
        path.startsWith('$internalWorkflowPath?');
  }

  /// True when get-context already has a non-internal redirect URL (open WebView now).
  bool _shouldOpenRedirectImmediately(dynamic response) {
    if (response is! Map || response['redirect'] != true) return false;
    final redirectUrl = response['url']?.toString() ?? '';
    if (redirectUrl.isEmpty) return false;
    if (_isInternalWorkflowRedirectUrl(redirectUrl)) return false;
    return redirectUrl.startsWith('http://') ||
        redirectUrl.startsWith('https://') ||
        redirectUrl.startsWith('/');
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
            debugPrint('[HomePage] Skipping verify API redirect - already processed');
            return;
          }
          
          // Extract query params from URL (e.g., verify=digilocker)
          final uri = Uri.tryParse(redirectUrl);
          if (uri != null) {
            // Build query string with verify param
            final queryString = uri.query; // This is "verify=digilocker"
            final lowerHost = uri.host.toLowerCase();
            final lowerPath = uri.path.toLowerCase();
            final isIpvOrFace =
                lowerHost.contains('ipv') ||
                lowerPath.contains('/ipv/') ||
                lowerPath.contains('face') ||
                lowerPath.contains('facefinder') ||
                lowerHost.contains('face');
            
            debugPrint('[HomePage] Special case: "redirect on verify is true" - calling get-context API');
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
              debugPrint('[HomePage] Error after verify get-context: ${store.errorWithAuth}');
              Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Error', gravity: ToastGravity.TOP);
            } else {
              debugPrint('[HomePage] Verify get-context completed successfully - data loaded in app');
            }

            // IPV/Face KYC case:
            // Backend provides a direct return URL (often with EMPTY query params).
            // In that scenario, we must open WebView automatically; otherwise user gets stuck on the non-IPV screen.
            if (isIpvOrFace && queryString.isEmpty && mounted) {
              final ensuredRedirectUrl = _forceHttpsForRpd(redirectUrl);
              final friendlyTitle = _deriveWebViewTitle(msg, ensuredRedirectUrl);
              debugPrint('[HomePage] Auto-opening WebView for IPV/Face after verify reload: $redirectUrl');
              await _openWebViewWithTransitionLoader(ensuredRedirectUrl, friendlyTitle);
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

                refreshedFinalUrl = '${EnvConfig.baseUrl}$relativeUrl';
              }

              refreshedFinalUrl = _forceHttpsForRpd(refreshedFinalUrl);
              final friendlyTitle = _deriveWebViewTitle(refreshedMsg, refreshedFinalUrl);
              debugPrint('[HomePage] Opening WebView after verify reload (refreshed redirect): $refreshedFinalUrl');
              await _openWebViewWithTransitionLoader(refreshedFinalUrl, friendlyTitle);
              return;
            }

            return; // Don't open WebView for other verify modes (e.g. digilocker handled by backend via fields)
          }
        }
        
        // For all OTHER redirects - open WebView (like DigiLocker)
        // But if backend returns internal workflow path first (e.g. /bpwealth/individual),
        // do not open that URL in WebView. Refresh context once and open only external URL.
        if (_isInternalWorkflowRedirectUrl(redirectUrl)) {
          debugPrint(
              '[HomePage] Internal workflow redirect received - refreshing context once instead of opening WebView: $redirectUrl');
          await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
          final refreshed = store.fieldsWithAuth;
          if (refreshed is Map &&
              refreshed['redirect'] == true &&
              (refreshed['url']?.toString().isNotEmpty ?? false)) {
            final nextRedirectUrl = refreshed['url']!.toString();
            final refreshedMsg = refreshed['msg']?.toString() ?? msg;
            if (_isInternalWorkflowRedirectUrl(nextRedirectUrl)) {
              debugPrint(
                  '[HomePage] Refreshed redirect is still internal workflow URL - staying in app flow');
              return;
            }

            String refreshedFinalUrl;
            if (nextRedirectUrl.startsWith('http://') ||
                nextRedirectUrl.startsWith('https://')) {
              refreshedFinalUrl = nextRedirectUrl;
            } else {
              var relativeUrl =
                  nextRedirectUrl.startsWith('/') ? nextRedirectUrl : '/$nextRedirectUrl';
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
              refreshedFinalUrl = '${EnvConfig.baseUrl}$relativeUrl';
            }

            refreshedFinalUrl = _forceHttpsForRpd(refreshedFinalUrl);
            final friendlyTitle = _deriveWebViewTitle(refreshedMsg, refreshedFinalUrl);
            debugPrint(
                '[HomePage] Opening WebView after internal-redirect refresh: $refreshedFinalUrl');
            await _openWebViewWithTransitionLoader(refreshedFinalUrl, friendlyTitle);
          }
          return;
        }

        String finalUrl;
        if (redirectUrl.startsWith('http://') || redirectUrl.startsWith('https://')) {
          finalUrl = redirectUrl;
        } else {
          // Relative URL - prepend baseUrl and preserve query params
          var relativeUrl = redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl';
          
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
        debugPrint('[HomePage] Opening WebView for redirect (msg: $msg, title: $friendlyTitle): $finalUrl');
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
      final isRpd = lower.contains('reverse_pennydrop') || lower.contains('reversepennydrop');
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
  Future<void> _openWebViewWithTransitionLoader(String finalUrl, String friendlyTitle) async {
    if (!mounted) return;

    _stopReturnFlowTimers();
    context.read<AppStore>().setReturningFromWebView(false);

    // Show a fully opaque white overlay so no home-page UI is visible during
    // the route transition. This pairs with the FadeTransition on the webview
    // route so the user sees white → white → WebView content with no flash.
    setState(() {
      _webViewTransitionActive = true;
      _webViewReturnError = null;
    });
    // Ensure the white overlay is painted before navigating.
    await WidgetsBinding.instance.endOfFrame;

    final encodedUrl = Uri.encodeComponent(finalUrl);
    final title = Uri.encodeComponent(friendlyTitle);
    context.go('/${widget.company}/${widget.workflowName}/webview?url=$encodedUrl&title=$title');

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

      if (path.contains('esign') ||
          query.contains('esign')) {
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

  /// Position + page label for form validation (same resolution as [_buildForm]).
  ({String? position, String? pageLabel}) _submitValidationStep(AppStore store) {
    final withAuth = store.fieldsWithAuth as Map?;
    final c = withAuth?['context'] as Map?;
    String? position = c?['position']?.toString().toLowerCase();
    String? pageLabel = c?['page']?['data']?['label']?.toString().toLowerCase();
    if ((position ?? '').isEmpty || (pageLabel ?? '').isEmpty) {
      final workflow = store.fields as Map?;
      position = (workflow?['position']?.toString() ?? '').toLowerCase();
      pageLabel = (workflow?['data']?['label']?.toString() ?? '').toLowerCase();
    }
    return (position: position, pageLabel: pageLabel);
  }

  void _showValidationFailureToast() {
    final formToast = _formNotifier.validationToastMessage;
    if (formToast != null && formToast.trim().isNotEmpty) {
      Fluttertoast.showToast(
        msg: formToast,
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.red.shade700,
        textColor: Colors.white,
      );
      return;
    }
    final errors = _formNotifier.errors;
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
        return;
      }
    }
    Fluttertoast.showToast(
      msg: 'Please fill all required fields correctly',
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor: Colors.red.shade700,
      textColor: Colors.white,
    );
  }

  /// BP Wealth personal-details: UI grouping for standing-instruction fields (collapsed by default).
  bool _bpWealthPersonalDetailsStandingUi(String? position, String? pageLabel) {
    return _isBpWealthCompany &&
        ((position ?? '') == 'personal_details' ||
            (pageLabel ?? '') == 'personal_details');
  }

  bool _isPersonalDetailsStep(String? position, String? pageLabel) {
    return (position ?? '') == 'personal_details' ||
        (pageLabel ?? '') == 'personal_details';
  }

  Future<void> _showDdpiSebiCircularModal() {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        const bodyStyle = TextStyle(
          fontSize: 14,
          color: KycTheme.textPrimary,
          height: 1.45,
        );
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
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
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "As per SEBI circular No's: SEBI/HO/MIRSD/DoP/CIR/2022/44 "
                          'Dated April 04, 2022',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: KycTheme.textPrimary,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'The use of DDPI (Demat Debit & Pledge Instruction) will be '
                          'limited only for below four purposes to authorize BP Equities '
                          'Pvt. Ltd. to access your Demat account only to meet:',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '1. Pay-in obligations for settlement or deliveries of trades '
                          'executed by you.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '2. To pledge/re-pledge securities to avail margin on trades.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '3. Mutual Fund Transactions being executed on Stock Exchanges '
                          'order entry platforms.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '4. Tendering shares in open offers through Stock Exchanges '
                          'platforms.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'In case any changes are required to the above purposes, kindly '
                          'proceed with the offline account opening process.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 12),
                        Text.rich(
                          TextSpan(
                            style: bodyStyle,
                            children: const [
                              TextSpan(
                                text: 'Note: ',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              TextSpan(
                                text: 'One-time charge of ₹100/- (excluding GST) will be '
                                    'debited from your trading ledger account to enable DDPI',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KycTheme.buttonEnabledPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 12,
                      ),
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

  /// PAN capture (`detailspan`) and PAN verify (`pan`): show DOB as **DD/MM/YYYY**.
  bool _useDdMmYyyyPanDateStep(String? position, String? pageLabel) {
    final p = (position ?? '').toLowerCase();
    final l = (pageLabel ?? '').toLowerCase();
    return p == 'pan' || l == 'pan' || p == 'detailspan' || l == 'detailspan';
  }

  /// Primary submit text: strip trailing arrows/chevrons from API `buttonName` (avoids double-arrow UI).
  String _primarySubmitLabel({
    required bool isMobileStep,
    required Map? submitButton,
  }) {
    if (isMobileStep) return 'Send OTP';
    var s = (submitButton?['buttonName'] ?? 'Submit').toString().trim();
    if (s.isEmpty) s = 'Submit';
    while (true) {
      final t = s.replaceFirst(RegExp(r'[\s→➜➤▶›>]+$'), '');
      if (t == s || t.isEmpty) break;
      s = t.trim();
    }
    return s.isEmpty ? 'Submit' : s;
  }

  /// One dynamic form row (shared by main list and Standing Instructions expansion).
  Widget _buildFormFieldRow({
    required Map<dynamic, dynamic> field,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    final name = field['name']?.toString() ?? '';
    final type = field['type']?.toString() ?? 'text';
    final lowerName = name.toLowerCase();
    final isAadharImageField =
        lowerName == 'aadhar_image' || lowerName == 'aadhaar_image';
    if (isAadharImageField && hasAadharImage) {
      return const SizedBox.shrink();
    }
    if (otpField != null && name == otpFieldName) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: _buildOtpVerifyCard(otpField, activeFields),
      );
    }

    final label = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
    final isBankScreen = position == 'bank' ||
        position == 'bank_details' ||
        label == 'bank';
    final isIfscField = isBankScreen &&
        (name == 'ifsc' || name.toLowerCase().contains('ifsc'));

    final editableFields = _formNotifier.editableFieldsList;
    final disableFromConditionalFlow =
        editableFields.any((e) => e is Map && e['name'] == name);
    final disableOnFetchedDataReview = fetchedDataReviewFieldReadOnly(
      position,
      pageLabel,
      field,
    );
    final isKraContinueChoice = isKraDetailsStep(position, pageLabel) &&
        kraDetailsContinueWithKraChoiceField(field);
    final disable = !isKraContinueChoice &&
        (disableFromConditionalFlow || disableOnFetchedDataReview);

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
            key: ValueKey<String>(name),
            name: name,
            displayName: field['displayName'] ?? name,
            type: type,
            fileType: field['fileType'] as List?,
            size: field['size'],
            mandatory: field['mandatory'] == true,
            validation: field['validation'],
            popupAfterSubmit: activeFields?['popupAfterSubmit'] as List?,
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
              final previousValue = _formNotifier.formData[n];
              final changedField = f ?? field;
              final isDdpiYesOnPersonalDetails = _isPersonalDetailsStep(
                    position,
                    pageLabel,
                  ) &&
                  isDdpiFormField(changedField) &&
                  isDdpiAffirmativeValue(v) &&
                  !isDdpiAffirmativeValue(previousValue);
              _formNotifier.handleChange(
                n,
                v,
                type: f?['type'] ?? 'text',
                validationType: f?['validation']?.toString(),
                validateWith: f?['validateWith']?.toString(),
              );
              if (isDdpiYesOnPersonalDetails) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _showDdpiSebiCircularModal();
                });
              }
              if (pageLabel == 'mobile' &&
                  (n == 'mobile' || n == 'phone' || n == 'mobile_number')) {
                setState(() => _showMobileError = false);
              }
            },
            onBlur: (n) {
              _formNotifier.handleBlur(
                n,
                position: position,
                pageLabel: pageLabel,
              );
              if (isIfscField) {
                final ifscValue = _formNotifier.formData[n]?.toString() ?? '';
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
            workflowKey:
                (store.fieldsWithAuth as Map?)?['context']?['workflow_key']?.toString(),
            disable: disable,
            apiFieldMeta: field,
            useDdMmYyyyDateDisplay: _useDdMmYyyyPanDateStep(position, pageLabel),
          ),
          if (isEmailStep && isEmailField) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _googleSignInLoading ? null : _handleGoogleSignIn,
              icon: const Icon(Icons.g_mobiledata, size: 20),
              label: Text(
                  _googleSignInLoading ? 'Signing in...' : 'Sign in with Google'),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                side: BorderSide(color: KycTheme.primary),
                foregroundColor: KycTheme.primary,
              ),
            ),
          ],
          if (isIfscField) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                final ifscValue = _formNotifier.formData[name]?.toString() ?? '';
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
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                side: BorderSide(color: KycTheme.primary),
                foregroundColor: KycTheme.primary,
              ),
            ),
          ],
          if (pageLabel == 'mobile' &&
              (name == 'mobile' || name == 'phone' || name == 'mobile_number') &&
              _showMobileError) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Please enter a valid 10-digit mobile number',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _prepareFormData(bool skipValidation) async {
    final data = Map<String, dynamic>.from(_formNotifier.formData);
    // Do not send `save` in kyc-post-v2 body (backend expectation).

    final store = context.read<AppStore>();
    final activeFields = _getActiveFields(store);
    final fieldList = activeFields?['fields'] as List?;
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    final nomineePos = ctx?['position']?.toString();
    final nomineeLbl = ctx?['page']?['data']?['label']?.toString();
    applyNomineeStepSubmitPayload(
      data: data,
      fields: fieldList,
      runtimeFieldVisibility: _formNotifier.fieldVisibility,
      company: widget.company,
      position: nomineePos,
      pageLabel: nomineeLbl,
    );

    // Add brokerage_plan for segments screen
    var panPos = ctx?['position']?.toString().toLowerCase() ?? '';
    var panLbl = ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
    if (panPos.isEmpty || panLbl.isEmpty) {
      final workflow = store.fields as Map?;
      panPos = (workflow?['position']?.toString() ?? panPos).toLowerCase();
      panLbl = (workflow?['data']?['label']?.toString() ?? panLbl).toLowerCase();
    }
    final pathSegment = _getKycPostPathSegment(ctx);
    if (isPanVerifyKycPostStep(panPos, pathSegment)) {
      final normalized = buildPanVerifyKycPostBody(data);
      data
        ..clear()
        ..addAll(normalized);
      _syncPanVerifyFieldsToForm(normalized);
    } else if (_useDdMmYyyyPanDateStep(panPos, panLbl)) {
      final apiPanDob = tryFormatKycPanDobForMatchApi(data['pan_dob_for_match']);
      if (apiPanDob != null) data['pan_dob_for_match'] = apiPanDob;
      final rawName = data['name']?.toString();
      if (rawName != null && rawName.trim().isNotEmpty) {
        data['name'] = rawName.trim().toUpperCase();
      }
      final rawPan = data['pan_number']?.toString();
      if (rawPan != null && rawPan.trim().isNotEmpty) {
        data['pan_number'] = rawPan.trim().toUpperCase();
      }
    }
    final position = ctx?['position']?.toString()?.toLowerCase();
    if (position == 'segments') {
      // UI no longer exposes MTF / currency; keep payload aligned with backend.
      // `brokerage_plan` is only sent when the user confirms via the dialog (non-empty in form).
      data['mtf'] = false;
      data['nse_currency'] = false;
      data['bse_currency'] = false;
      // Mandatory segments (live parity): always submitted as true.
      data['nse_cash'] = true;
      data['bse_cash'] = true;
      data['mf'] = true;
    }

    // Only send fields for the active step — not entire accumulated formData.
    if (fieldList != null && position != 'segments') {
      final filtered = filterKycPostV2BodyForStep(
        data: data,
        fields: fieldList,
        runtimeFieldVisibility: _formNotifier.fieldVisibility,
        company: widget.company,
        position: nomineePos,
        pageLabel: nomineeLbl,
      );
      data
        ..clear()
        ..addAll(filtered);
      syncExtraNomineeSubmitPayload(
        data: data,
        fields: fieldList,
        runtimeFieldVisibility: _formNotifier.fieldVisibility,
        company: widget.company,
        position: nomineePos,
        pageLabel: nomineeLbl,
      );
    }

    if (activeFields == null) return data;
    if (fieldList == null) return data;
    final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file');
    if (!hasFile) return data;

    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${EnvConfig.baseUrl}/api/get-user/${widget.company}/${widget.workflowName}'),
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
      String label = ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';

      if (position.isEmpty || label.isEmpty) {
        final workflow = store.fields as Map?;
        position = (workflow?['position']?.toString() ?? position).toLowerCase();
        label = (workflow?['data']?['label']?.toString() ?? label).toLowerCase();
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
        final mobile = _formNotifier.formData['mobile'] ?? _formNotifier.formData['phone'] ?? _formNotifier.formData['mobile_number'] ?? '';
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
      final step = _submitValidationStep(store);
      final isValid = _formNotifier.validate(
        company: widget.company,
        position: step.position,
        pageLabel: step.pageLabel,
      );
      if (!isValid) {
        debugPrint('[HomePage] Send OTP / Submit: validation failed');
        debugPrint('[HomePage] Validation errors: ${_formNotifier.errors}');
        _showValidationFailureToast();
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
        debugPrint('[HomePage] _handleSubmit saveFilesAPI=true: Uploading files separately to /api/upload_files_new');
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
            debugPrint('[HomePage] _handleSubmit Uploading file: $fileKey = ${file.path}');
            final client = ApiClient();
            final uploadRes = await client.postMultipart(
              () async {
                final uploadReq = http.MultipartRequest(
                  'POST',
                  Uri.parse('${EnvConfig.baseUrl}/api/upload_files_new'),
                );
                uploadReq.headers['accept'] = '*/*';
                uploadReq.files.add(await http.MultipartFile.fromPath(fileKey, file.path));
                return uploadReq;
              },
              skipRefreshOn401: true,
            );
            debugPrint('[HomePage] _handleSubmit File upload response for $fileKey: ${uploadRes.statusCode}');
            
            if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
              debugPrint('[HomePage] _handleSubmit File upload failed for $fileKey: ${uploadRes.body}');
              Fluttertoast.showToast(
                msg: 'Failed to upload $fileKey',
                gravity: ToastGravity.TOP,
              );
              if (mounted) setState(() => _submitLoading = false);
              return;
            }
          } catch (e) {
            debugPrint('[HomePage] _handleSubmit Error uploading file $fileKey: $e');
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
        debugPrint('[HomePage] _handleSubmit Files uploaded successfully, continuing with form submission');
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
    debugPrint('[HomePage] _handleSubmitResponse status=${res.statusCode} body=${res.body.length > 300 ? res.body.substring(0, 300) + "..." : res.body}');
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      body = null;
    }
    try {
      if (res.statusCode >= 200 && res.statusCode < 300 && body?['success'] == true) {
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
        // Keep filled values visible until get-context returns; then clear and apply new step.
        await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
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
          Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Session updated. Please continue.', gravity: ToastGravity.TOP);
          return;
        }
        _formNotifier.resetForm();
        final activeAfterSubmit = _getActiveFields(store);
        final listAfterSubmit = (activeAfterSubmit?['fields'] as List?) ?? [];
        final flowAfterSubmit = activeAfterSubmit?['conditionalFlow'] as List?;
        _formNotifier.updateFields(
          listAfterSubmit,
          flowAfterSubmit,
          fieldsWithAuth: store.fieldsWithAuth,
        );
        if (mounted) {
          final authResponse = store.fieldsWithAuth;
          if (authResponse is Map && authResponse['is_admin'] == true) {
            debugPrint('[HomePage] Submit response indicates completion (is_admin=true) - navigating to completed');
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
      Fluttertoast.showToast(msg: 'Submission failed', gravity: ToastGravity.TOP);
    }
  }

  bool _isPanKycStep(String? position, String? pageLabel) {
    return _useDdMmYyyyPanDateStep(position, pageLabel);
  }

  /// `kyc-post-v2` body: prefer API `msg` / `message` as returned (e.g. PAN step).
  static String? _kycPostV2UserMessage(Map<String, dynamic>? body) {
    if (body == null) return null;
    for (final key in ['msg', 'message', 'error']) {
      final v = body[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// PAN already saved on this session — refresh workflow and continue (web parity).
  Future<bool> _tryRecoverPanVerifyAlreadyExists(
    AppStore store, {
    required Map<String, dynamic> submissionData,
  }) async {
    await store.fetchUserDetails();
    final ud = userDetailsDataMap(store.userDetails);
    if (!panNumberMatchesUserDetails(submissionData, ud)) {
      debugPrint(
          '[HomePage] PAN already exists but user-details PAN mismatch — not recovering');
      return false;
    }
    debugPrint(
        '[HomePage] PAN already on this journey — refreshing get-context to advance');
    await store.fetchWorkflowFieldsWithAuth(
      widget.company,
      widget.workflowName,
      '',
    );
    return store.errorWithAuth == null;
  }

  void _showPanStepKycPostFeedback(String message, {required bool isError}) {
    if (!mounted) return;
    // API often returns message "working" on success — not user-facing copy.
    if (message.trim().toLowerCase() == 'working') return;
    setState(() {
      _panStepApiFeedback = message;
      _panStepApiFeedbackIsError = isError;
    });
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor:
          isError ? Colors.red.shade700 : Colors.green.shade700,
      textColor: Colors.white,
    );
  }

  /// Extract user-facing error message from API response body.
  /// Supports common keys: msg, message, error, detail (string or list).
  static String _errorMessageFromResponse(int statusCode, String bodyStr) {
    if (bodyStr.trim().isEmpty) {
      return friendlyApiErrorMessage(null, statusCode: statusCode);
    }
    try {
      final body = jsonDecode(bodyStr) as Map<String, dynamic>?;
      if (body == null) {
        return friendlyApiErrorMessage(bodyStr, statusCode: statusCode);
      }
      final msg = body['msg'] ?? body['message'] ?? body['error'];
      if (msg != null) {
        if (msg is String) {
          return friendlyApiErrorMessage(msg, statusCode: statusCode);
        }
        if (msg is List && msg.isNotEmpty) {
          return friendlyApiErrorMessage(msg.first.toString(), statusCode: statusCode);
        }
      }
      final detail = body['detail'];
      if (detail is String) {
        return friendlyApiErrorMessage(detail, statusCode: statusCode);
      }
      if (detail is List && detail.isNotEmpty) {
        return friendlyApiErrorMessage(detail.first.toString(), statusCode: statusCode);
      }
    } catch (_) {
      return friendlyApiErrorMessage(bodyStr, statusCode: statusCode);
    }
    return friendlyApiErrorMessage(bodyStr, statusCode: statusCode);
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

  /// Bank `kyc-post-v2` can return HTTP 200 with `success: false` and either:
  /// - `msg` containing "Penny Drop Verified" (confirm save), or
  /// - eKYC name-mismatch / retry flow with top-level `pennydrop` (e.g. unsuccessful message).
  static bool _isPennyDropVerifiedAwaitingSaveOrRetake(Map? body) {
    if (body == null) return false;
    final msg = body['msg']?.toString().toLowerCase().trim() ?? '';
    if (msg.contains('penny drop verified')) return true;
    final pennydrop = body['pennydrop']?.toString().trim() ?? '';
    if (pennydrop.isNotEmpty) return true;
    return false;
  }

  static String _stripBasicHtmlForDialog(String s) {
    if (s.isEmpty) return '';
    var t = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'<[^>]+>'), '');
    return t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Prefer cleaned `msg`; fall back to `pennydrop` for eKYC mismatch responses.
  static String _pennyDropSaveRetakeDialogTitle(Map body) {
    final rawMsg = body['msg']?.toString().trim() ?? '';
    final fromMsg = _stripBasicHtmlForDialog(rawMsg);
    if (fromMsg.isNotEmpty) return fromMsg;
    final p = body['pennydrop']?.toString().trim() ?? '';
    if (p.isNotEmpty) return p;
    return 'Penny drop';
  }

  Future<String?> _showPennyDropVerifiedSaveRetakeDialog(String title) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: Text(title),
          ),
        ),
        content: const Text(
          'Save these bank details, or retake penny drop verification.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('retake'),
            child: const Text('Retake'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _afterKycPostV2Success(
    AppStore store,
    Map<String, dynamic>? body,
    Map<String, dynamic> submissionData,
  ) async {
    StorageService.setUserStep(body?['step']?.toString() ?? '');
    // Persist email for OTP UI before any reset (payload + snapshot still valid here).
    final formSnapshot = Map<String, dynamic>.from(_formNotifier.formData);
    final emailFromPayload = (submissionData['email'] ??
            submissionData['email_id'] ??
            submissionData['emailId'])
            ?.toString()
            .trim() ??
        '';
    if (emailFromPayload.contains('@')) {
      _persistedEmailForOtp = emailFromPayload;
    } else {
      final resolved = _resolveEmailForOtpUi(formSnapshot);
      if (resolved.contains('@')) _persistedEmailForOtp = resolved;
    }
    // Do not reset the form before get-context: the UI would show empty fields while the
    // request is in flight even though the save succeeded. Clear + rehydrate only after fresh context.
    await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
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
      Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Session updated. Please continue.', gravity: ToastGravity.TOP);
      if (mounted) setState(() => _submitLoading = false);
      return;
    }
    _formNotifier.resetForm();
    final activeAfter = _getActiveFields(store);
    final listAfter = (activeAfter?['fields'] as List?) ?? [];
    final flowAfter = activeAfter?['conditionalFlow'] as List?;
    _formNotifier.updateFields(
      listAfter,
      flowAfter,
      fieldsWithAuth: store.fieldsWithAuth,
    );
    if (mounted) {
      final authResponse = store.fieldsWithAuth;
      if (authResponse is Map && authResponse['is_admin'] == true) {
        debugPrint('[HomePage] Common submit indicates completion (is_admin=true) - navigating to completed');
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
  }

  Future<void> _handleCommonSubmit(bool skipValidation) async {
    debugPrint('[HomePage] _handleCommonSubmit CALLED - skipValidation=$skipValidation');
    final store = context.read<AppStore>();
    _panStepApiFeedback = '';
    _panStepApiFeedbackIsError = false;

    // Enforce Terms & Conditions on mobile step for authenticated flows
    if (!skipValidation) {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;

      String position = ctx?['position']?.toString().toLowerCase() ?? '';
      String label = ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';

      if (position.isEmpty || label.isEmpty) {
        final workflow = store.fields as Map?;
        position = (workflow?['position']?.toString() ?? position).toLowerCase();
        label = (workflow?['data']?['label']?.toString() ?? label).toLowerCase();
      }

      debugPrint('[HomePage] _handleCommonSubmit position=$position label=$label');

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
        final mobile = _formNotifier.formData['mobile'] ?? _formNotifier.formData['phone'] ?? _formNotifier.formData['mobile_number'] ?? '';
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
      final step = _submitValidationStep(store);
      final isValid = _formNotifier.validate(
        company: widget.company,
        position: step.position,
        pageLabel: step.pageLabel,
      );
      debugPrint('[HomePage] Form validation result: $isValid');
      if (!isValid) {
        debugPrint('[HomePage] Validation failed, returning early');
        debugPrint('[HomePage] Validation errors: ${_formNotifier.errors}');
        _showValidationFailureToast();
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
        Fluttertoast.showToast(msg: 'Invalid step. Please refresh.', gravity: ToastGravity.TOP);
        if (mounted) setState(() => _submitLoading = false);
        return;
      }
      
      final currentPosition =
          (ctx?['position']?.toString().toLowerCase() ?? '').trim();
      final lowerPath = pathSegment.toLowerCase();

      final data = await _prepareFormData(skipValidation);
      data.remove('save');

      // PAN verify (`pan10`): curl/web body only — trim name/PAN (trailing space breaks verify).
      if (isPanVerifyKycPostStep(currentPosition, lowerPath)) {
        final normalized = buildPanVerifyKycPostBody(data);
        data
          ..clear()
          ..addAll(normalized);
        debugPrint('[HomePage] PAN verify POST body: $data');
      }

      // Initial email capture step: backend expects a trimmed body (email + a few fields).
      // Must NOT run on `email_otp` — pathSegment e.g. `email_otp4` still starts with `email`,
      // and clearing here would drop the OTP field and break verify_otp on the server.
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
        final selectDependency = (data['select__dependency'] ?? 'Self')
            .toString()
            .trim();
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
      final onDigilockerStep = currentPosition == 'digilocker' ||
          lowerPath.startsWith('digilocker');
      if (onDigilockerStep) {
        data['save'] = true;
        debugPrint('[HomePage] DigiLocker step: save=true on kyc-post-v2');
      }

      debugPrint('[HomePage] _handleCommonSubmit data: $data pathSegment: $pathSegment');
      
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
      final endpoint = '/api/kyc-post-v2/${widget.company}/${widget.workflowName}/$pathSegment';
      final fullUrl = '${EnvConfig.baseUrl}$endpoint';
      debugPrint('[HomePage] _handleCommonSubmit hasFile=$hasFile');
      debugPrint('[HomePage] _handleCommonSubmit FULL URL: $fullUrl');
      debugPrint('[HomePage] _handleCommonSubmit ENDPOINT: $endpoint');
      
      // If saveFilesAPI is true, upload files separately first
      if (hasFile && saveFilesAPI) {
        debugPrint('[HomePage] saveFilesAPI=true: Uploading files separately to /api/upload_files_new');
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
                uploadReq.files.add(await http.MultipartFile.fromPath(fileKey, file.path));
                return uploadReq;
              },
              skipRefreshOn401: true,
            );
            debugPrint('[HomePage] File upload response for $fileKey: ${uploadRes.statusCode}');
            
            if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
              debugPrint('[HomePage] File upload failed for $fileKey: ${uploadRes.body}');
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
        debugPrint('[HomePage] Files uploaded successfully, continuing with form submission');
      }
      
      final http.Response res;
      if (hasFile && !saveFilesAPI) {
        // Use multipart/form-data for file uploads (existing flow when saveFilesAPI=false)
        debugPrint('[HomePage] Using multipart/form-data (file upload detected, saveFilesAPI=false)');
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
        debugPrint('[HomePage] Using application/json (no files or files already uploaded)');
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
      final currentPageLabel =
          ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
      final isPanStep = _isPanKycStep(currentPosition, currentPageLabel) ||
          lowerPath.startsWith('pan');
      final isSuccess = res.statusCode >= 200 && res.statusCode < 300 && body?['success'] == true;
      if (isSuccess) {
        if (isPanStep) {
          final apiMsg = _kycPostV2UserMessage(body);
          if (apiMsg != null && apiMsg.isNotEmpty) {
            _showPanStepKycPostFeedback(apiMsg, isError: false);
          }
        }
        await _afterKycPostV2Success(store, body, data);
      } else if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          _isPennyDropVerifiedAwaitingSaveOrRetake(body)) {
        if (mounted) setState(() => _submitLoading = false);
        final dialogTitle = _pennyDropSaveRetakeDialogTitle(body!);
        final choice = await _showPennyDropVerifiedSaveRetakeDialog(dialogTitle);
        if (!mounted) return;
        if (choice == null) return;
        setState(() => _submitLoading = true);
        final retryPayload = Map<String, dynamic>.from(data);
        retryPayload.remove('save');
        retryPayload.remove('retake');
        if (choice == 'save') {
          retryPayload['save'] = true;
        } else {
          retryPayload['retake'] = true;
        }
        debugPrint(
            '[HomePage] Penny drop follow-up POST ($choice): $endpoint');
        final res2 = await client.post(
          endpoint,
          body: retryPayload,
          headers: {'Content-Type': 'application/json'},
        );
        Map<String, dynamic>? body2;
        try {
          body2 = jsonDecode(res2.body) as Map<String, dynamic>?;
        } catch (_) {
          body2 = null;
        }
        final ok2 = res2.statusCode >= 200 &&
            res2.statusCode < 300 &&
            body2?['success'] == true;
        if (ok2) {
          await _afterKycPostV2Success(store, body2, retryPayload);
        } else {
          final err2 = _errorMessageFromResponse(res2.statusCode, res2.body);
          Fluttertoast.showToast(msg: err2, gravity: ToastGravity.TOP);
          if (mounted) setState(() => _submitLoading = false);
        }
      } else if (isPanStep &&
          isPanNumberAlreadyExistsResponse(body) &&
          await _tryRecoverPanVerifyAlreadyExists(store, submissionData: data)) {
        debugPrint(
            '[HomePage] PAN verify: already exists — treated as success, advancing');
        _showPanStepKycPostFeedback('PAN verified successfully', isError: false);
        await _afterKycPostV2Success(
          store,
          <String, dynamic>{'success': true, 'message': 'working'},
          data,
        );
      } else {
        final errMsg = _kycPostV2UserMessage(body) ??
            _errorMessageFromResponse(res.statusCode, res.body);
        if (isPanStep) {
          _showPanStepKycPostFeedback(errMsg, isError: true);
        } else {
          Fluttertoast.showToast(msg: errMsg, gravity: ToastGravity.TOP);
        }
        if (mounted) setState(() => _submitLoading = false);
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Something went wrong. Please try again.', gravity: ToastGravity.TOP);
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
          final label = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
          final isBankScreen = position == 'bank' ||
              position == 'bank_details' ||
              label == 'bank';
          if (!isBankScreen) {
            debugPrint('[HomePage] IFSC response received but not on bank screen (position=$position, label=$label)');
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

          // address → bank_address / bankAddress / bank_add (payload alias on some workflows)
          if (data['address'] != null) {
            final v = data['address'];
            if (fieldNames.contains('bank_address')) updates['bank_address'] = v;
            if (fieldNames.contains('bankAddress')) updates['bankAddress'] = v;
            if (fieldNames.contains('bank_add')) updates['bank_add'] = v;
          }

          // city → bank_city
          if (data['city'] != null && fieldNames.contains('bank_city')) {
            updates['bank_city'] = data['city'];
          }

          // district → bank_district
          if (data['district'] != null && fieldNames.contains('bank_district')) {
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
          
          debugPrint('[HomePage] Bank fields to update (after position & field filter): $updates');
          
          if (updates.isEmpty) {
            debugPrint('[HomePage] No matching bank fields found to update for this screen.');
          } else {
            for (final e in updates.entries) {
              debugPrint('[HomePage] Updating field: ${e.key} = ${e.value}');
            }
            // Use notifier API (not raw map + notifyListeners) so Provider/Consumer rebuilds;
            // avoid handleChange here — it runs [_processValue] and truncates generic text to 35 chars.
            _formNotifier.applyExternalFormValues(updates);
            if (mounted) setState(() {});
            Fluttertoast.showToast(msg: 'Bank details fetched successfully', gravity: ToastGravity.TOP);
            debugPrint('[HomePage] Auto-filled ${updates.length} bank fields - UI should update now');
          }
        }
      } else {
        debugPrint('[HomePage] IFSC lookup failed: ${res.statusCode}');
        Fluttertoast.showToast(msg: 'Invalid IFSC code', gravity: ToastGravity.TOP);
      }
    } catch (e) {
      debugPrint('[HomePage] IFSC lookup error: $e');
      Fluttertoast.showToast(msg: 'Failed to fetch bank details', gravity: ToastGravity.TOP);
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
          await client.post('/api/user/logout', headers: {'Authorization': 'Bearer $token'});
          debugPrint('[HomePage] Logout API called successfully');
        } catch (e) {
          debugPrint('[HomePage] Logout API error (continuing anyway): $e');
        }
      }
      
      // Step 2: Clear all auth tokens and data
      await StorageService.clearAll();
      debugPrint('[HomePage] Tokens cleared');
      // Keep post-logout flow on get-user token until app restart.
      StorageService.setSsoAutoLoginEnabled(false);
      _ssoAttempted = true;
      
      // Step 3: Reset form state
      _formNotifier.resetForm();
      
      // Step 4: Reset AppStore state
      final store = context.read<AppStore>();
      store.resetState();
      
      // Step 5: Fetch workflow again (without auth) to get first step
      await store.fetchWorkflowFields(widget.company, widget.workflowName);
      debugPrint('[HomePage] Workflow refreshed after logout');
      
      // Step 6: Refresh UI - navigate to same route to trigger rebuild
      if (mounted) {
        context.go('/${widget.company}/${widget.workflowName}');
        Fluttertoast.showToast(msg: 'Logged out successfully', gravity: ToastGravity.TOP);
      }
    } catch (e) {
      debugPrint('[HomePage] Logout error: $e');
      Fluttertoast.showToast(msg: 'Error during logout', gravity: ToastGravity.TOP);
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
          const CircularProgressIndicator(color: KycTheme.primary, strokeWidth: 3),
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

  Widget _buildAuthenticatedHeaderActions(AppStore store) {
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: (_refreshLoading || _loadWorkflowActive || _logoutLoading)
                ? null
                : () async {
                    store.clearAuthError();
                    setState(() {
                      _webViewReturnError = null;
                      _refreshLoading = true;
                    });
                    try {
                      await _loadWorkflow();
                    } finally {
                      if (mounted) setState(() => _refreshLoading = false);
                    }
                  },
            icon: (_refreshLoading || _loadWorkflowActive)
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: KycTheme.primary,
                    ),
                  )
                : const Icon(Icons.refresh, color: KycTheme.textPrimary),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: _logoutLoading ? null : _handleLogout,
            icon: _logoutLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: KycTheme.primary,
                    ),
                  )
                : const Icon(Icons.logout, color: KycTheme.textPrimary),
          ),
        ],
      ),
    );
  }

  Widget _buildApiErrorRetryContent(
    AppStore store, {
    required String message,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 64, color: Colors.orange.shade400),
            const SizedBox(height: 16),
            Text(
              message,
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
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              onPressed: (_refreshLoading || _loadWorkflowActive)
                  ? null
                  : () {
                      store.clearAuthError();
                      setState(() => _webViewReturnError = null);
                      if (onRetry != null) {
                        onRetry();
                      } else {
                        _loadWorkflow();
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApiErrorScaffold({
    required AppStore store,
    required String message,
    required bool isAuthenticated,
    VoidCallback? onRetry,
  }) {
    final friendly = friendlyApiErrorMessage(message);
    return Scaffold(
      backgroundColor: KycTheme.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isAuthenticated) _buildAuthenticatedHeaderActions(store),
            Expanded(
              child: KycLayout(
                title: 'Unable to load',
                stepperSteps: null,
                stepperIndex: null,
                skipScaffold: true,
                showDocumentsSection: false,
                child: _buildApiErrorRetryContent(
                  store,
                  message: friendly,
                  onRetry: onRetry,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebViewReturnRetryContent(AppStore store) {
    return _buildApiErrorRetryContent(
      store,
      message: friendlyApiErrorMessage(_webViewReturnError),
      onRetry: () {
        setState(() => _returnFlowMessage = 'Loading your next step...');
        _loadWorkflow();
      },
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
                _formNotifier.updateFields(
                  fieldList,
                  conditionalFlow,
                  fieldsWithAuth: store.fieldsWithAuth,
                );
                // Must run in same callback *after* updateFields so API `value` is in formData first.
                _runPersonalDetailsBpWealthPipeline(store, fieldList);
                final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
                _syncDigilockerAadharImage(
                  store,
                  fieldList,
                  position: ctx?['position']?.toString(),
                  pageLabel: ctx?['page']?['data']?['label']?.toString(),
                );
              });

              // --- Stepper UI (hidden temporarily) ---
              // Still used for "Documents to keep Handy" on early steps; re-enable
              // showStepper + stepperWidget when bringing the stepper back.
              final stepperIndex = _getStepperIndex(store, isAuthenticated);
              // final stepperSteps = _getStepperSteps(store);
              // Stepper visible only from 2nd step (mobile_otp) onwards; hidden on first step (mobile number entry)
              // final ctxForStepper = (store.fieldsWithAuth as Map?)?['context'] as Map?;
              // final currentPosition = (ctxForStepper?['position']?.toString() ?? '').toLowerCase();
              // final showStepper = currentPosition.isNotEmpty && currentPosition != 'mobile';
              const showStepper = false;

              // final stepperWidget = Container(
              //   height: 100, // Fixed height for stepper (circle + label + padding)
              //   color: Colors.white, // Ensure background color
              //   child: KycStepperBar(
              //     steps: stepperSteps,
              //     currentIndex: stepperIndex,
              //   ),
              // );
              // Placeholder so existing showStepper branches compile while stepper is off.
              final stepperWidget = const SizedBox.shrink();

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
                          Align(
                            alignment: Alignment.centerRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: (_loadWorkflowActive || _logoutLoading)
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
                                  onPressed: _logoutLoading ? null : _handleLogout,
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
                        // Stepper stays visible throughout (hidden — see showStepper above)
                        // if (showStepper) stepperWidget,
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

              // Subtle loader shown just before navigating to WebView.
              // Paired with the FadeTransition on the webview route to guarantee
              // smooth transition without flash of home-page UI.
              if (_webViewTransitionActive) {
                return Scaffold(
                  backgroundColor: Colors.white,
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: KycTheme.primary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Opening verification...',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: KycTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Handle loading states - full screen when no stepper, else loader below stepper
              // Note: _submitLoading no longer blocks the full screen - it only shows inline button loading
              // for better UX (users can still see form data and context while API is processing)

              if (store.loading) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              const Expanded(child: Loader(
                                message: 'Setting up your KYC journey...',
                                minimal: true,
                              )),
                            ],
                          )
                        : const Loader(
                            message: 'Setting up your KYC journey...',
                          ),
                  ),
                );
              }
              
              if (store.error != null) {
                return _buildApiErrorScaffold(
                  store: store,
                  message: store.error!,
                  isAuthenticated: isAuthenticated,
                );
              }
              
              // Show loader BELOW stepper when fetching get-context (full screen when first step)
              // BUT: don't show if we're already in a submit flow (button is showing loader)
              // This prevents the jarring transition from button loader → full screen loader
              if (store.loadingWithAuth && !_submitLoading) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              const Expanded(child: Loader(
                                message: 'Loading your details...',
                                minimal: true,
                              )),
                            ],
                          )
                        : const Loader(
                            message: 'Loading your details...',
                          ),
                  ),
                );
              }

              // Show error if get-context API failed (502, server HTML, technical tokens, etc.)
              if (store.errorWithAuth != null) {
                return _buildApiErrorScaffold(
                  store: store,
                  message: store.errorWithAuth!,
                  isAuthenticated: isAuthenticated,
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
                    rawPageLabel.toLowerCase().trim() == rawPosition.toLowerCase().trim()) {
                  pageLabel = null;
                }

                pageTitle = pageLabel ??
                    pageName ??
                    (activeFields is Map
                        ? activeFields['title'] ?? activeFields['pageTitle']
                        : null)?.toString();

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
                              Align(
                                alignment: Alignment.centerRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: _refreshLoading
                                          ? null
                                          : () async {
                                              setState(() => _refreshLoading = true);
                                              try {
                                                await _loadWorkflow();
                                              } finally {
                                                if (mounted) {
                                                  setState(() => _refreshLoading = false);
                                                }
                                              }
                                            },
                                      icon: _refreshLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2, color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.refresh, color: KycTheme.textPrimary),
                                    ),
                                    IconButton(
                                      onPressed: _logoutLoading ? null : _handleLogout,
                                      icon: _logoutLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2, color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.logout, color: KycTheme.textPrimary),
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
                                leading: (isAuthenticated && (submitButton?['backShowButton'] ?? false))
                                    ? IconButton(
                                        onPressed: _backLoading
                                            ? null
                                            : () => Navigator.of(context).maybePop(),
                                        icon: _backLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2, color: KycTheme.primary),
                                              )
                                            : const Icon(Icons.arrow_back, color: KycTheme.textPrimary),
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
                              Align(
                                alignment: Alignment.centerRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: _refreshLoading
                                          ? null
                                          : () async {
                                              setState(() => _refreshLoading = true);
                                              try {
                                                await _loadWorkflow();
                                              } finally {
                                                if (mounted) {
                                                  setState(() => _refreshLoading = false);
                                                }
                                              }
                                            },
                                      icon: _refreshLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2, color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.refresh, color: KycTheme.textPrimary),
                                    ),
                                    IconButton(
                                      onPressed: _logoutLoading ? null : _handleLogout,
                                      icon: _logoutLoading
                                          ? const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2, color: KycTheme.primary),
                                            )
                                          : const Icon(Icons.logout, color: KycTheme.textPrimary),
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
                                leading: (isAuthenticated && (submitButton?['backShowButton'] ?? false))
                                    ? IconButton(
                                        onPressed: _backLoading
                                            ? null
                                            : () => Navigator.of(context).maybePop(),
                                        icon: _backLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2, color: KycTheme.primary),
                                              )
                                            : const Icon(Icons.arrow_back, color: KycTheme.textPrimary),
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

  Map<dynamic, dynamic>? _findAadharImageFieldDef(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      if (isAadharImageFieldName(f['name']?.toString())) return f;
    }
    return null;
  }

  void _applyDigilockerAadharImageToForm(AppStore store, List<dynamic> fieldList) {
    final aadharField = _findAadharImageFieldDef(fieldList);
    if (aadharField == null) return;
    final name = aadharField['name']?.toString();
    if (name == null || name.isEmpty) return;

    final resolved = resolveDigilockerAadharImageRaw(
      userDetails: store.userDetails,
      fieldValue: aadharField['value'],
      formValue: _formNotifier.formData[name],
    );
    if (resolved == null) return;
    final current = _formNotifier.formData[name]?.toString().trim() ?? '';
    if (resolved.trim() == current) return;

    debugPrint(
        '[HomePage] DigiLocker aadhar_image sync: $current → ${resolved.trim()}');
    _formNotifier.handleChange(
      name,
      resolved,
      type: aadharField['type']?.toString() ?? 'text',
      validationType: aadharField['validation']?.toString(),
    );
  }

  void _syncDigilockerAadharImage(
    AppStore store,
    List<dynamic> fieldList, {
    String? position,
    String? pageLabel,
  }) {
    if (!isDigilockerStep(position, pageLabel)) return;

    _applyDigilockerAadharImageToForm(store, fieldList);

    if (_digilockerUserDetailsFetchStarted) return;
    _digilockerUserDetailsFetchStarted = true;
    store.fetchUserDetails().then((_) {
      if (!mounted) return;
      _applyDigilockerAadharImageToForm(store, fieldList);
      setState(() {});
    });
  }

  void _syncPanVerifyFieldsToForm(Map<String, dynamic> normalized) {
    for (final entry in normalized.entries) {
      final current = _formNotifier.formData[entry.key]?.toString() ?? '';
      final next = entry.value?.toString() ?? '';
      if (current == next) continue;
      _formNotifier.handleChange(entry.key, entry.value, type: 'text');
    }
  }

  /// Prefer in-memory value; if unset (`null` / missing), use workflow `field['value']` (dropoff).
  /// Blank string means the user cleared the field — do **not** substitute API prepopulate again.
  dynamic _coalesceFormFieldValue(dynamic formValue, dynamic fieldValue) {
    if (formValue == null) return fieldValue;
    if (formValue is String && formValue.trim().isEmpty) return formValue;
    return formValue;
  }

  /// True when [formData] has no meaningful value yet (merge dropoff/API into form).
  /// Blank string means the user cleared the field — do not merge API prepopulate again.
  bool _shouldMergeFromApi(dynamic existing) {
    if (existing == null) return true;
    if (existing is String && existing.trim().isEmpty) return false;
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

      dynamic apiValue = f['value'];
      if (apiValue == null || (apiValue is String && apiValue.trim().isEmpty)) {
        final pv = f['prepopulateValue'];
        if (pv != null && pv.toString().trim().isNotEmpty) {
          apiValue = pv;
        }
      }
      if (apiValue == null) continue;
      if (apiValue is String && apiValue.trim().isEmpty) continue;

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
    final isPersonalDetails = position == 'personal_details' ||
        pageLabel == 'personal_details';
    if (!isPersonalDetails) return;

    debugPrint(
        '[HomePage] personal_details BP Wealth pipeline: fields=${fieldList.length}');
    _mergePersonalDetailsFromFieldDefinitions(fieldList);
    _normalizePersonalDetailRadios(fieldList); // radio + select (dropdowns)
    _applyPersonalDetailsDefaults(fieldList);
    _applyBpWealthStandingInstructionScreenshotDefaults(fieldList);
  }

  /// Web standing-instructions accordion defaults (screenshot parity) when value still unset.
  void _applyBpWealthStandingInstructionScreenshotDefaults(
    List<dynamic> fieldList,
  ) {
    if (!_isBpWealthCompany) return;

    String? _pickElectronic(List? values) {
      if (values == null) return null;
      for (final o in values) {
        final s = o.toString();
        if (s.toLowerCase().contains('elect')) return s;
      }
      return null;
    }

    String? _pickSebiRegulations(List? values) {
      if (values == null) return null;
      for (final o in values) {
        final s = o.toString();
        final sl = s.toLowerCase();
        if (sl.contains('sebi') && sl.contains('regul')) return s;
        if (sl.contains('as per')) return s;
      }
      return null;
    }

    void applyYesNo(String fieldName, String yesOrNo) {
      for (final f in fieldList) {
        if (f is! Map) continue;
        if (f['name']?.toString() != fieldName) continue;
        final type = f['type']?.toString() ?? '';
        if (type != 'radio' && type != 'select') return;
        if (!_shouldMergeFromApi(_formNotifier.formData[fieldName])) return;
        final values = f['values'] as List?;
        final pick = _matchRadioOption(values, yesOrNo);
        if (pick != null) {
          _formNotifier.handleChange(
            fieldName,
            pick,
            type: type,
            validationType: f['validation']?.toString(),
          );
        }
        return;
      }
    }

    void applyElectronic(String fieldName) {
      for (final f in fieldList) {
        if (f is! Map) continue;
        if (f['name']?.toString() != fieldName) continue;
        final type = f['type']?.toString() ?? '';
        if (type != 'radio' && type != 'select') return;
        if (!_shouldMergeFromApi(_formNotifier.formData[fieldName])) return;
        final values = f['values'] as List?;
        final raw = _pickElectronic(values);
        if (raw == null) return;
        final normalized = _normalizeRadioToOptions(raw, values);
        _formNotifier.handleChange(
          fieldName,
          normalized,
          type: type,
          validationType: f['validation']?.toString(),
        );
        return;
      }
    }

    void applyStatementFrequencyByDisplayName() {
      for (final f in fieldList) {
        if (f is! Map) continue;
        final name = f['name']?.toString();
        if (name == null) continue;
        if (!bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) continue;
        final type = f['type']?.toString() ?? '';
        if (type != 'radio' && type != 'select') continue;
        if (!_shouldMergeFromApi(_formNotifier.formData[name])) continue;
        final values = f['values'] as List?;
        final raw = _pickSebiRegulations(values);
        if (raw == null) continue;
        final normalized = _normalizeRadioToOptions(raw, values);
        _formNotifier.handleChange(
          name,
          normalized,
          type: type,
          validationType: f['validation']?.toString(),
        );
      }
    }

    applyYesNo('sebi_3years', 'No');
    applyYesNo('directly_bank_account', 'Yes');
    applyYesNo('credit_account', 'Yes');
    applyYesNo('rta', 'Yes');
    applyYesNo('dp_accept', 'No');
    applyYesNo('electronic_transaction', 'Yes');
    applyElectronic('receive_contract');
    applyElectronic('annual_report');
    applyStatementFrequencyByDisplayName();
    applyYesNo('debitbalance', 'Yes');
    applyYesNo('dis_booklet', 'No');
    applyYesNo('dis_book', 'No');
    applyYesNo('dis', 'No');
    applyYesNo('delivery_instruction_slip', 'No');
    applyYesNo('dis_slip', 'No');
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

        final taxResidencyOutside = (dn.contains('tax') && dn.contains('residen')) ||
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

  int _bpWealthPersonalMainSortKey(String? name) {
    if (name == null) return 99999;
    final n = name.toLowerCase();
    const order = <String>[
      'fathers_name',
      'father_name',
      'father',
      'fathername',
      'mothers_name',
      'mother_name',
      'mother',
      'mothername',
      'gender',
      'marital_status',
      'maritalstatus',
      'education',
      'annual_income',
      'income',
      'gross_annual_income',
      'annualincome',
      'trading_experience',
      'tradingexperience',
      'politically_exposed',
      'pep',
      'political_exposed',
      'occupation',
      'citizen_of_india',
      'citizen',
      'indian_citizen',
      'citizenindia',
      'ddpi',
      'execute_ddpi',
      'demat_debit_pledge',
      'tax_residency',
      'tax_residency_outside_india',
      'taxresidency',
      'penny_drop_condition',
    ];
    final i = order.indexOf(n);
    if (i >= 0) return i;
    return 9000 + n.hashCode.remainder(10000);
  }

  int _bpWealthStandingSortKey(Map<dynamic, dynamic> f) {
    if (bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) {
      return 8;
    }
    final name = f['name']?.toString();
    if (name == null) return 99999;
    const order = <String>[
      'sebi_3years',
      'directly_bank_account',
      'credit_account',
      'rta',
      'dp_accept',
      'electronic_transaction',
      'receive_contract',
      'annual_report',
      'holding_cum_transaction_statement',
      'holding_transaction_statement',
      'transaction_statement_frequency',
      'cum_holding_statement',
      'debitbalance',
      'dis_booklet',
      'dis_book',
      'dis',
      'delivery_instruction_slip',
      'dis_slip',
    ];
    final i = order.indexOf(name);
    if (i >= 0) return i;
    return 8000 + name.hashCode.remainder(1000);
  }

  static const String _kBpWealthTariffPdfUrl =
      'https://ekyc.stoxbox.in/static/static_upload_files/bpwealth/organized%20(19).pdf';

  /// Download PDF while user is on personal_details so View opens instantly.
  Future<File>? _bpWealthTariffPdfCacheFuture;
  bool _bpWealthTariffPdfModalOpen = false;

  void _ensureBpWealthTariffPdfCached() {
    _bpWealthTariffPdfCacheFuture ??= _downloadBpWealthTariffPdfToCache();
  }

  Future<void> _openBpWealthTariffPdf() async {
    _showBpWealthTariffPdfModal();
  }

  Future<File> _downloadBpWealthTariffPdfToCache() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/bpwealth_tariff_plan.pdf');
    try {
      if (await file.exists()) {
        final len = await file.length();
        if (len > 0) return file;
      }
    } catch (_) {}
    final res = await http
        .get(Uri.parse(_kBpWealthTariffPdfUrl))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('Tariff PDF download failed (${res.statusCode})');
    }
    await file.writeAsBytes(res.bodyBytes, flush: true);
    return file;
  }

  Future<void> _openBpWealthTariffPdfExternally() async {
    final uri = Uri.parse(_kBpWealthTariffPdfUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showBpWealthTariffPdfModal() {
    if (_bpWealthTariffPdfModalOpen) return;
    _bpWealthTariffPdfModalOpen = true;
    _ensureBpWealthTariffPdfCached();
    final mq = MediaQuery.of(context);
    final h = mq.size.height * 0.85;
    final w = mq.size.width - 24;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _BpWealthTariffPdfDialog(
        pdfUrl: _kBpWealthTariffPdfUrl,
        localPdfFuture: _bpWealthTariffPdfCacheFuture!,
        width: w,
        height: h,
        onOpenExternal: _openBpWealthTariffPdfExternally,
      ),
    ).whenComplete(() {
      _bpWealthTariffPdfModalOpen = false;
    });
  }

  /// BP Wealth personal_details: web-like header, single-column main (2nd screenshot fields only),
  /// Standing accordion, then tariff consent + View (PDF) **below** accordion.
  List<Widget> _buildBpWealthPersonalWebFormLayout({
    required List<dynamic> visibleFieldsForDisplay,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    _ensureBpWealthTariffPdfCached();

    final maps = visibleFieldsForDisplay
        .whereType<Map>()
        .map((e) => Map<dynamic, dynamic>.from(e))
        .toList();

    final main = <Map<dynamic, dynamic>>[];
    final standing = <Map<dynamic, dynamic>>[];
    Map<dynamic, dynamic>? consentField;

    for (final f in maps) {
      if (bpWealthPersonalDetailsTariffConsentCheckboxField(f)) {
        consentField = f;
        continue;
      }
      // Must use [bpWealthPersonalDetailsStandingSectionField] — not only
      // [kBpWealthPersonalDetailsStandingFieldNames], so displayName-based
      // rows (e.g. holding cum transaction statement frequency) land here.
      if (bpWealthPersonalDetailsStandingSectionField(f)) {
        standing.add(f);
      } else {
        final n = f['name']?.toString();
        if (n != null &&
            kBpWealthPersonalDetailsMainScreenFieldNames.contains(n)) {
          main.add(f);
        }
      }
    }

    if (consentField == null) {
      for (final raw in fieldList) {
        if (raw is! Map) continue;
        final f = Map<dynamic, dynamic>.from(raw);
        if (bpWealthPersonalDetailsTariffConsentCheckboxField(f)) {
          consentField = f;
          break;
        }
      }
    }

    main.sort((a, b) => _bpWealthPersonalMainSortKey(a['name']?.toString())
        .compareTo(_bpWealthPersonalMainSortKey(b['name']?.toString())));
    standing.sort((a, b) =>
        _bpWealthStandingSortKey(a).compareTo(_bpWealthStandingSortKey(b)));

    final out = <Widget>[
      const SizedBox(height: 8),
      ...main.map(
        (f) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _buildFormFieldRow(
            field: f,
            otpField: otpField,
            otpFieldName: otpFieldName,
            hasAadharImage: hasAadharImage,
            activeFields: activeFields,
            store: store,
            fieldList: fieldList,
            position: position,
            pageLabel: pageLabel,
            ctx: ctx,
          ),
        ),
      ),
    ];

    if (standing.isNotEmpty) {
      out.add(const SizedBox(height: 8));
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const PageStorageKey<String>('bpwealth_standing_instructions'),
              initiallyExpanded: false,
              tilePadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                side: const BorderSide(color: KycTheme.border),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                side: const BorderSide(color: KycTheme.border),
              ),
              title: const Text(
                'Standing instructions',
                style: TextStyle(
                  fontSize: KycTheme.fontSizeBodyLg,
                  fontWeight: FontWeight.w600,
                  color: KycTheme.textPrimary,
                ),
              ),
              subtitle: const Text(
                'DP preferences & statement options',
                style: TextStyle(
                  fontSize: KycTheme.fontSizeCaption,
                  color: KycTheme.textSecondary,
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: standing
                        .map(
                          (g) => _buildFormFieldRow(
                            field: g,
                            otpField: otpField,
                            otpFieldName: otpFieldName,
                            hasAadharImage: hasAadharImage,
                            activeFields: activeFields,
                            store: store,
                            fieldList: fieldList,
                            position: position,
                            pageLabel: pageLabel,
                            ctx: ctx,
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (consentField != null) {
      out.add(const SizedBox(height: 8));
      out.add(
        _buildFormFieldRow(
          field: consentField,
          otpField: otpField,
          otpFieldName: otpFieldName,
          hasAadharImage: hasAadharImage,
          activeFields: activeFields,
          store: store,
          fieldList: fieldList,
          position: position,
          pageLabel: pageLabel,
          ctx: ctx,
        ),
      );
    } else {
      out.add(const SizedBox(height: 8));
      out.add(
        Text(
          'I have read and understood the contents pertaining to the DP Standing Instructions and Tariff Structure details. I hereby agree and give my consent to the same.',
          style: TextStyle(
            fontSize: KycTheme.fontSizeBody,
            color: KycTheme.textPrimary,
            height: 1.35,
          ),
        ),
      );
    }

    out.add(const SizedBox(height: 12));
    out.add(
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: _openBpWealthTariffPdf,
          style: FilledButton.styleFrom(
            backgroundColor: KycTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('View'),
        ),
      ),
    );

    return out;
  }

  /// Default: sequential rows + BP Wealth standing expansion (non–personal_details).
  List<Widget> _buildSequencedFormRowsWithStandingExpansion({
    required List<dynamic> visibleFieldsForDisplay,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    final rows = <Widget>[];
    var idx = 0;
    while (idx < visibleFieldsForDisplay.length) {
      final raw = visibleFieldsForDisplay[idx];
      if (raw is! Map) {
        idx++;
        continue;
      }
      final fieldMap = Map<dynamic, dynamic>.from(raw);
      if (_bpWealthPersonalDetailsStandingUi(position, pageLabel) &&
          bpWealthPersonalDetailsStandingSectionField(fieldMap)) {
        final group = <Map<dynamic, dynamic>>[];
        while (idx < visibleFieldsForDisplay.length) {
          final r2 = visibleFieldsForDisplay[idx];
          if (r2 is! Map) break;
          final m2 = Map<dynamic, dynamic>.from(r2);
          if (!_bpWealthPersonalDetailsStandingUi(position, pageLabel) ||
              !bpWealthPersonalDetailsStandingSectionField(m2)) {
            break;
          }
          group.add(m2);
          idx++;
        }
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                key: const PageStorageKey<String>('bpwealth_standing_instructions'),
                initiallyExpanded: false,
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                  side: const BorderSide(color: KycTheme.border),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                  side: const BorderSide(color: KycTheme.border),
                ),
                title: const Text(
                  'Standing instructions & declarations',
                  style: TextStyle(
                    fontSize: KycTheme.fontSizeBodyLg,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.textPrimary,
                  ),
                ),
                subtitle: const Text(
                  'Tap to expand (same as website)',
                  style: TextStyle(
                    fontSize: KycTheme.fontSizeCaption,
                    color: KycTheme.textSecondary,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: group
                          .map(
                            (g) => _buildFormFieldRow(
                              field: g,
                              otpField: otpField,
                              otpFieldName: otpFieldName,
                              hasAadharImage: hasAadharImage,
                              activeFields: activeFields,
                              store: store,
                              fieldList: fieldList,
                              position: position,
                              pageLabel: pageLabel,
                              ctx: ctx,
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }
      rows.add(
        _buildFormFieldRow(
          field: fieldMap,
          otpField: otpField,
          otpFieldName: otpFieldName,
          hasAadharImage: hasAadharImage,
          activeFields: activeFields,
          store: store,
          fieldList: fieldList,
          position: position,
          pageLabel: pageLabel,
          ctx: ctx,
        ),
      );
      idx++;
    }
    return rows;
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
    String? pageLabel = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();

    // Fallback for unauthenticated flow where context may be null:
    // use workflow root from store.fields (get-workflow-details response)
    if (position == null || position.isEmpty || pageLabel == null || pageLabel.isEmpty) {
      final workflow = store.fields as Map?;
      position = (workflow?['position']?.toString() ?? position ?? '').toLowerCase();
      pageLabel = (workflow?['data']?['label']?.toString() ?? pageLabel ?? '').toLowerCase();
    }

    debugPrint('[HomePage] _buildForm position=$position pageLabel=$pageLabel');

    final isSegmentsScreen = position == 'segments';

    if (isSegmentsScreen) {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final stepKey = '${position ?? ''}|$pageId';
      if (stepKey != _segmentsBrokerageStepKey) {
        _segmentsBrokerageStepKey = stepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_segmentsBrokerageStepKey != stepKey) return;
          _segmentsBrokerageUserConfirmed = false;
          final bp = _formNotifier.formData['brokerage_plan']?.toString().trim() ?? '';
          if (bp.isNotEmpty) {
            _formNotifier.handleChange('brokerage_plan', '');
          }
          setState(() {});
        });
      }
    } else {
      if (_segmentsBrokerageStepKey != null) {
        _segmentsBrokerageStepKey = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _segmentsBrokerageUserConfirmed = false;
          setState(() {});
        });
      }
    }

    // BP Wealth segment defaults — never call handleChange during build (causes freeze).
    if (isSegmentsScreen && widget.company.toLowerCase() == 'bpwealth') {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final defaultsStepKey = '${position ?? ''}|$pageId';
      if (defaultsStepKey != _segmentsBpDefaultsStepKey) {
        _segmentsBpDefaultsStepKey = defaultsStepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_segmentsBpDefaultsStepKey != defaultsStepKey) return;
          const mandatorySegmentKeys = <String>['nse_cash', 'bse_cash', 'mf'];
          const optionalDefaultKeys = <String>['nse_fo', 'nse_slbm', 'bse_fo'];
          var didApplyDefaults = false;
          for (final key in mandatorySegmentKeys) {
            if (_formNotifier.formData[key] != true) {
              _formNotifier.handleChange(key, true);
              didApplyDefaults = true;
            }
          }
          for (final key in optionalDefaultKeys) {
            if (_formNotifier.formData[key] == null) {
              _formNotifier.handleChange(key, true);
              didApplyDefaults = true;
            }
          }
          if (didApplyDefaults) {
            debugPrint('[HomePage] Applied segment defaults for bpwealth');
          }
        });
      }
    } else if (_segmentsBpDefaultsStepKey != null) {
      _segmentsBpDefaultsStepKey = null;
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
            if (name == 'nse_cash' || name == 'bse_cash' || name == 'mf') {
              if (value != true) return;
            }
            _formNotifier.handleChange(name, value);
          },
          onViewBrokeragePlan: () {
            BrokeragePlanDialog.show(
              context,
              () {
                // Only after user taps Done in the dialog
                _formNotifier.handleChange('brokerage_plan', 'Brokerage Plan');
                setState(() {
                  _segmentsBrokerageUserConfirmed = true;
                });
                Fluttertoast.showToast(
                    msg: 'Brokerage plan applied', gravity: ToastGravity.TOP);
              },
            );
          },
          onSubmit: () {
            if (_submitLoading) return;
            final hasPlan = _segmentsBrokerageUserConfirmed &&
                (_formNotifier.formData['brokerage_plan']?.toString().trim().isNotEmpty ??
                    false);
            if (!hasPlan) {
              Fluttertoast.showToast(
                msg: 'Please select a brokerage plan to continue',
                gravity: ToastGravity.TOP,
                backgroundColor: Colors.orange.shade700,
                textColor: Colors.white,
              );
              return;
            }

            if (isAuth) {
              _handleCommonSubmit(false);
            } else {
              _handleSubmit(false);
            }
          },
          submitLoading: _submitLoading,
          hasBrokeragePlanSelected: _segmentsBrokerageUserConfirmed &&
              (_formNotifier.formData['brokerage_plan']?.toString().trim().isNotEmpty ??
                  false),
        ),
      );
    }
    final visibleFields = fieldList.where((f) {
      if (f is! Map) return false;
      final name = f['name']?.toString();
      final initialShow = kycFieldVisibleForFormStep(
        f,
        company: widget.company,
        position: position,
        pageLabel: pageLabel,
      );

      // If conditional flow has explicitly set visibility, use that (takes precedence)
      // Otherwise, use API visibility (+ BP Wealth personal_details standing override)
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
        final isOtpField = type == 'otp' || fieldName == 'otp' || fieldName == 'otp_code';
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

      // Nominee: hide ghost PAN/Aadhaar boxes (nominee 2 / 3) with no label.
      if (isNomineeKycStep(position, pageLabel) &&
          shouldHideNomineeGhostInputField(
            field: f,
            formData: _formNotifier.formData,
          )) {
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

    final bool isDigilockerScreen = position == 'digilocker' || pageLabel == 'digilocker';
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
        final rawValue = resolveDigilockerAadharImageRaw(
          userDetails: store.userDetails,
          fieldValue: aadharField['value'],
          formValue: _formNotifier.formData[aName],
        );
        final valueStr = rawValue?.toString() ?? '';
        if (valueStr.isNotEmpty) {
          if (valueStr.startsWith('http')) {
            aadharImageUrl = cacheBustDocumentUrl(
              valueStr,
              version: digilockerAadharImageCacheBustVersion(store.userDetails),
            );
          } else {
            String base64Data = valueStr.trim();
            final match = RegExp(r'data:image/[^;]+;base64,', caseSensitive: false).firstMatch(base64Data);
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
        hasAadharImage =
            aadharImageBytes != null || (aadharImageUrl != null && aadharImageUrl!.isNotEmpty);
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
            if (_isPanKycStep(position, pageLabel) &&
                _panStepApiFeedback.trim().isNotEmpty) ...[
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _panStepApiFeedbackIsError
                      ? Colors.red.shade50
                      : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _panStepApiFeedbackIsError
                        ? Colors.red.shade300
                        : Colors.green.shade300,
                  ),
                ),
                child: Text(
                  _panStepApiFeedback,
                  style: TextStyle(
                    color: _panStepApiFeedbackIsError
                        ? Colors.red.shade900
                        : Colors.green.shade900,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
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
                          key: ValueKey<String>(aadharImageUrl!),
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            final expected = loadingProgress.expectedTotalBytes;
                            final value = expected != null
                                ? loadingProgress.cumulativeBytesLoaded / expected
                                : null;
                            return Center(
                              child: CircularProgressIndicator(
                                value: value,
                                strokeWidth: 2,
                                color: KycTheme.primary,
                              ),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) => Container(
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
            ...(_bpWealthPersonalDetailsStandingUi(position, pageLabel)
                ? _buildBpWealthPersonalWebFormLayout(
                    visibleFieldsForDisplay: visibleFieldsForDisplay,
                    otpField: otpField,
                    otpFieldName: otpFieldName,
                    hasAadharImage: hasAadharImage,
                    activeFields: activeFields,
                    store: store,
                    fieldList: fieldList,
                    position: position,
                    pageLabel: pageLabel,
                    ctx: ctx,
                  )
                : _buildSequencedFormRowsWithStandingExpansion(
                    visibleFieldsForDisplay: visibleFieldsForDisplay,
                    otpField: otpField,
                    otpFieldName: otpFieldName,
                    hasAadharImage: hasAadharImage,
                    activeFields: activeFields,
                    store: store,
                    fieldList: fieldList,
                    position: position,
                    pageLabel: pageLabel,
                    ctx: ctx,
                  )),
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
                        color: _termsAccepted ? KycTheme.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: _termsAccepted ? KycTheme.primary : KycTheme.border,
                          width: 2,
                        ),
                      ),
                      child: _termsAccepted
                          ? const Icon(Icons.check, size: 14, color: Colors.white)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(fontSize: 12, color: KycTheme.textPrimary, height: 1.4),
                        children: [
                          const TextSpan(text: 'Please accept the '),
                          TextSpan(
                            text: 'Terms and Conditions',
                            style: const TextStyle(
                              color: KycTheme.primary,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()..onTap = () => _showTermsModal(context),
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
                      Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Please accept the Terms & Conditions to continue',
                          style: TextStyle(fontSize: 12, color: Colors.red.shade700),
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
                      debugPrint('[HomePage] Submit button clicked! isAuth=$isAuth, position=$position');
                      if (isAuth) {
                        _handleCommonSubmit(false);
                      } else {
                        _handleSubmit(false);
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: isMobileStep
                    ? (_isSendOtpDisabled(position) ? KycTheme.buttonDisabledPurple : KycTheme.buttonEnabledPurple)
                    : KycTheme.primary,
                foregroundColor: Colors.white,
                minimumSize: Size(double.infinity, isMobileStep ? 52 : 48),
                padding: const EdgeInsets.symmetric(vertical: KycTheme.spacingLg),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(isMobileStep ? 14 : KycTheme.radiusMd),
                ),
              ),
              child: _submitLoading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                        SizedBox(width: 12),
                        Text('Processing...', style: TextStyle(color: Colors.white)),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _primarySubmitLabel(
                            isMobileStep: isMobileStep,
                            submitButton: submitButton,
                          ),
                        ),
                      ],
                    ),
            ),
            if (showGenericSubmit && submitButton?['showSubmitAnywayButton'] == true) ...[
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
                      child: Text(submitButton?['submitAnywayButtonName'] ?? 'Submit Anyway'),
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
        _formNotifier.formData['mobile_number'] ?? '';
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
                style: TextStyle(fontSize: 13, color: KycTheme.textPrimary, height: 1.4),
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
                        final uri = Uri.parse('https://resident.uidai.gov.in/verify');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    if (p != null &&
        p.length == 10 &&
        RegExp(r'^[6-9]').hasMatch(p)) {
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
          msg: 'Could not get Google credentials. Check app signing (SHA-1) in Firebase.',
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
      final email = (userCredential.user?.email ?? selectedAccount.email).trim();
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
      debugPrint('[GoogleSignIn] FirebaseAuthException: ${e.code} ${e.message}');
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
    await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
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
    setState(() => _resendOtpLoading = true);
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
        setState(() => _resendOtpLoading = false);
      }
    }
  }

  Future<void> _resendEmailOtpAfterEdit(String email) async {
    final store = context.read<AppStore>();
    final trimmed = email.trim();
    _persistedEmailForOtp = trimmed;
    FocusScope.of(context).unfocus();
    if (!mounted) return;
    setState(() => _resendOtpLoading = true);
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
      Fluttertoast.showToast(msg: 'Failed to resend email OTP', gravity: ToastGravity.TOP);
    } finally {
      if (mounted) {
        setState(() => _resendOtpLoading = false);
      }
    }
  }

  // Previous flow: Edit opened a modal and then called get-user / kyc-post resend.
  // Replaced by `_requestReviewEditAndRefreshContext` → GET `/api_review_edit_page/...` then get-context.

  Widget _buildOtpVerifyCard(Map otpField, dynamic activeFields) {
    final otpName = otpField['name']?.toString() ?? 'otp';
    final formData = _formNotifier.formData;
    final store = context.read<AppStore>();
    final position =
        (store.fieldsWithAuth as Map?)?['context']?['position']?.toString().toLowerCase() ?? '';
    final isEmailOtp = position == 'email_otp' || position.startsWith('email_otp');
    final isMobileOtp = position == 'mobile_otp' || position.startsWith('mobile_otp');

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
              debugPrint('[HomePage] Resend OTP resolved digits len=${digits.length}');
              if (digits.length != 10 ||
                  !RegExp(r'^[6-9]').hasMatch(digits)) {
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
          resendLoading: _resendOtpLoading,
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

/// BP Wealth personal details — tariff PDF inside modal (iOS: cached file, Android: Google embed).
class _BpWealthTariffPdfDialog extends StatefulWidget {
  final String pdfUrl;
  final Future<File> localPdfFuture;
  final double width;
  final double height;
  final Future<void> Function() onOpenExternal;

  const _BpWealthTariffPdfDialog({
    required this.pdfUrl,
    required this.localPdfFuture,
    required this.width,
    required this.height,
    required this.onOpenExternal,
  });

  @override
  State<_BpWealthTariffPdfDialog> createState() => _BpWealthTariffPdfDialogState();
}

class _BpWealthTariffPdfDialogState extends State<_BpWealthTariffPdfDialog> {
  WebViewController? _iosWebController;
  bool _loading = true;
  Timer? _maxWait;
  Timer? _hideDebounce;
  int _androidLoadSeq = 0;

  static String _googleViewerEmbedUrl(String pdfUrl) {
    return 'https://docs.google.com/viewer?url=${Uri.encodeComponent(pdfUrl)}&embedded=true';
  }

  @override
  void initState() {
    super.initState();
    _maxWait = Timer(const Duration(seconds: 60), () {
      if (mounted && _loading) setState(() => _loading = false);
    });
    if (Platform.isIOS) {
      _loadIosPdf();
    }
  }

  Future<void> _loadIosPdf() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _scheduleHideLoader(),
          onWebResourceError: (_) => _scheduleHideLoader(),
        ),
      );
    try {
      final file = await widget.localPdfFuture;
      if (!mounted) return;
      if (await file.exists() && await file.length() > 0) {
        await controller.loadFile(file.path);
      } else {
        await controller.loadRequest(Uri.parse(widget.pdfUrl));
      }
    } catch (e) {
      debugPrint('[HomePage] iOS tariff PDF load failed: $e');
      await controller.loadRequest(Uri.parse(widget.pdfUrl));
    }
    if (!mounted) return;
    setState(() => _iosWebController = controller);
  }

  void _scheduleHideLoader() {
    _hideDebounce?.cancel();
    final delay = Platform.isAndroid
        ? const Duration(milliseconds: 1200)
        : const Duration(milliseconds: 300);
    _hideDebounce = Timer(delay, () {
      if (!mounted) return;
      setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _hideDebounce?.cancel();
    _maxWait?.cancel();
    super.dispose();
  }

  Widget _buildAndroidPdfInModal() {
    final viewerUrl = _googleViewerEmbedUrl(widget.pdfUrl);
    return InAppWebView(
      key: const ValueKey('bpwealth_tariff_pdf_android'),
      initialUrlRequest: URLRequest(url: WebUri(viewerUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useOnDownloadStart: false,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        domStorageEnabled: true,
        databaseEnabled: true,
      ),
      onLoadStop: (controller, url) {
        final u = url?.toString() ?? '';
        debugPrint('[HomePage] Android tariff PDF onLoadStop: $u');
        if (!u.contains('docs.google.com/viewer')) return;
        final seq = ++_androidLoadSeq;
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (!mounted || seq != _androidLoadSeq) return;
          _scheduleHideLoader();
        });
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame != true) return;
        debugPrint(
            '[HomePage] Android tariff PDF main error: ${error.description} url=${request.url}');
        _scheduleHideLoader();
      },
      onDownloadStartRequest: (controller, request) {
        debugPrint('[HomePage] Android tariff PDF download blocked (stay in modal)');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: KycTheme.primary,
              child: Row(
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 14, 8, 14),
                      child: Text(
                        'DP Standing Instructions & Tariff',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (Platform.isIOS && _iosWebController != null)
                    WebViewWidget(controller: _iosWebController!)
                  else if (Platform.isAndroid)
                    _buildAndroidPdfInModal(),
                  if (_loading)
                    ColoredBox(
                      color: Colors.white,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: KycTheme.primary,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Loading document…',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: TextButton.icon(
                onPressed: () async {
                  await widget.onOpenExternal();
                },
                icon: const Icon(Icons.open_in_browser, size: 20),
                label: const Text('Open PDF in browser'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}