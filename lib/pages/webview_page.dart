import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/services/storage_service.dart';

/// WebView page for external redirects (DigiLocker, IPV/Face Finder)
/// Uses InAppWebView for camera/microphone (getUserMedia) support
class WebViewPage extends StatefulWidget {
  final String url;
  final String title;
  final String company;
  final String workflowName;

  const WebViewPage({
    super.key,
    required this.url,
    this.title = 'External Verification',
    required this.company,
    required this.workflowName,
  });

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  String _currentUrl = '';
  String? _preservedState;
  String? _preservedClientToken;
  String? _preservedAuto;
  bool _hasSeenCleanUrl = false;
  bool _permissionsRequested = false;
  bool _hasReloadedAfterPermissions = false;
  bool _redirectHandled = false;
  /// Params captured from completion/success URLs (e.g. success=yes, transaction_id=...)
  /// Passed to get-context API so backend marks step as complete
  final Map<String, String> _completionParams = {};
  // Popup window (Digio etc.) for reverse_pennydrop
  int? _popupWindowId;
  // Track if a UPI app was opened so we can auto-refresh on return
  bool _upiAppLaunched = false;
  // Track if any payment app was launched (for iOS auto-reload)
  bool _paymentAppLaunched = false;
  // Periodic polling timer to auto-refresh Reverse Penny Drop page after UPI payment
  Timer? _reversePennyPollTimer;
  // Avoid repeating special scroll adjustment for eSign (clouDesign) pages
  bool _esignScrollAdjusted = false;
  // Track if we already handled RPD success (to avoid double-close)
  bool _rpdSuccessHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUrl = widget.url;

    final initialUri = Uri.tryParse(widget.url);
    if (initialUri != null) {
      _preservedState = initialUri.queryParameters['state'];
      _preservedClientToken = initialUri.queryParameters['client_token'];
      _preservedAuto = initialUri.queryParameters['auto'];
      debugPrint('[WebView] Initial params from URL: state=$_preservedState, client_token=$_preservedClientToken, auto=$_preservedAuto');
    }

    // For Android: Request permissions BEFORE loading IPV page to ensure camera/mic work
    // For iOS: Permissions can be requested after load (works fine)
    if (_isIpvOrFaceFinderUrl(widget.url)) {
      if (Platform.isAndroid) {
        // Request permissions immediately on Android before WebView loads
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _requestPermissionsBeforeLoad();
        });
      } else {
        // iOS: Request after load (existing behavior)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _requestPermissionsAndReload();
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reversePennyPollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When returning from a payment app, auto-reload the WebView
    if (state == AppLifecycleState.resumed) {
      if (_isReversePennyDropFlow && _upiAppLaunched) {
        _upiAppLaunched = false;
        _reloadWebView();
        _startReversePennyPolling();
      } else if (_paymentAppLaunched) {
        // For iOS: auto-reload when returning from any payment app
        _paymentAppLaunched = false;
        debugPrint('[WebView] App resumed after payment - reloading WebView');
        Future.delayed(const Duration(milliseconds: 500), () {
          _reloadWebView();
        });
      }
    }
  }

  bool _isIpvOrFaceFinderUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return host.contains('ipv.meon.co.in') ||
        host.contains('ipv') ||
        path.contains('ipv') ||
        path.contains('face') ||
        path.contains('facefinder');
  }

  bool _isReversePennyDropUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return host.contains('meon.co.in') && path.contains('/reverse_pennydrop/');
  }

  bool get _isReversePennyDropFlow =>
      _isReversePennyDropUrl(widget.url) || _isReversePennyDropUrl(_currentUrl);

  /// Digio eSign flow – hosted on our domain under /digio/cloud-esign/...
  bool _isDigioEsignUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
        path.contains('/digio/cloud-esign/');
  }

  bool get _isDigioEsignFlow =>
      _isDigioEsignUrl(widget.url) || _isDigioEsignUrl(_currentUrl);

  /// Flows that need JS window.open popups (Digio bank selection etc.)
  bool get _supportsPopupWindows => _isReversePennyDropFlow || _isDigioEsignFlow;

  void _startReversePennyPolling() {
    if (_reversePennyPollTimer != null) return;
    // Poll every 5 seconds to let the page re-evaluate payment status and redirect when ready
    _reversePennyPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isReversePennyDropFlow || _redirectHandled || !mounted) {
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
        return;
      }
      // Only reload while we're on the reverse_pennydrop page; once we leave it, stop polling.
      if (_isReversePennyDropUrl(_currentUrl)) {
        debugPrint('[WebView] Reverse Penny Drop polling reload: $_currentUrl');
        _reloadWebView();
      } else {
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
      }
    });
  }

  /// Request permissions BEFORE loading WebView (Android-specific)
  Future<void> _requestPermissionsBeforeLoad() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;

    debugPrint('[WebView] Requesting permissions BEFORE load (Android) for IPV/Face Finder');

    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];

    final results = await Future.wait(
      permissions.map((p) => p.request()),
    );

    bool allGranted = results.every((status) =>
        status == PermissionStatus.granted || status == PermissionStatus.limited);

    if (allGranted) {
      debugPrint('[WebView] All permissions granted before load - WebView will load with camera access');
      // On Android, reload WebView after permissions granted to ensure camera/mic initialize properly
      if (_webViewController != null && !_hasReloadedAfterPermissions) {
        _hasReloadedAfterPermissions = true;
        Future.delayed(const Duration(milliseconds: 300), () {
          debugPrint('[WebView] Reloading WebView after Android permissions granted');
          _webViewController?.reload();
        });
      }
    } else {
      debugPrint('[WebView] Some permissions denied before load');
      Fluttertoast.showToast(
        msg: 'Camera, microphone & location required for face verification',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.orange,
        gravity: ToastGravity.TOP,
      );
    }
  }

  /// Request permissions AFTER WebView loads (iOS or fallback)
  Future<void> _requestPermissionsAndReload() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;

    debugPrint('[WebView] Requesting permissions for IPV/Face Finder');

    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];

    final results = await Future.wait(
      permissions.map((p) => p.request()),
    );

    bool allGranted = results.every((status) =>
        status == PermissionStatus.granted || status == PermissionStatus.limited);

    if (allGranted) {
      debugPrint('[WebView] All permissions granted, reloading WebView');
      Fluttertoast.showToast(
        msg: 'Permissions granted. Reloading...',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.TOP,
      );
      if (!_hasReloadedAfterPermissions && _webViewController != null) {
        _hasReloadedAfterPermissions = true;
        Future.delayed(const Duration(milliseconds: 500), () {
          _webViewController?.reload();
        });
      }
    } else {
      debugPrint('[WebView] Some permissions denied');
      Fluttertoast.showToast(
        msg: 'Camera, microphone & location required for face verification',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.orange,
        gravity: ToastGravity.TOP,
      );
    }
  }

  Future<void> _reloadWebView() async {
    try {
      debugPrint('[WebView] Reloading WebView: $_currentUrl');
      await _webViewController?.reload();
      Fluttertoast.showToast(
        msg: 'Page reloaded',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.TOP,
      );
    } catch (e) {
      debugPrint('[WebView] Error reloading: $e');
    }
  }

  /// Captures query params from completion/success URLs (e.g. RPD: ?success=yes&transaction_id=..., eSign: ?esign=yes)
  /// so they can be passed to get-context API. Works for any segment with different params.
  void _captureCompletionParamsIfApplicable(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters.isEmpty) return;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isWorkflowPath = path.contains('/${widget.company}/${widget.workflowName}');
    final isOurDomain = host.contains('meon.co.in') &&
        !host.contains('api.') &&
        !host.contains('accounts.');

    // Known completion params that indicate step completion or carry
    // important status for external flows (eSign, RPD, Reverse Penny Drop, AA CAMS, etc.)
    final completionParamKeys = [
      'esign',
      'success',
      'transaction_id',
      'verifycompleted',
      'reversepennydrop',
      'account_aggregator',
      'ecres',
      'resdate',
      'fi',
    ];
    final hasCompletionParams = uri.queryParameters.keys.any((key) => 
        completionParamKeys.contains(key.toLowerCase()));

    // Capture from completion URLs: our domain, has params
    // If workflow path, only capture if it has completion params (e.g. ?esign=yes)
    if (isOurDomain) {
      if (!isWorkflowPath || hasCompletionParams) {
        for (final e in uri.queryParameters.entries) {
          final keyLower = e.key.toLowerCase();
          // Never override routing params (state, client_token, auto) from intermediate domains
          // These should always come from the final workflow URL (bp_flow, etc.)
          if (e.value.isNotEmpty &&
              keyLower != 'state' &&
              keyLower != 'client_token' &&
              keyLower != 'auto') {
            _completionParams[e.key] = e.value;
          }
        }
        if (_completionParams.isNotEmpty) {
          debugPrint('[WebView] Captured completion params: $_completionParams');
        }
      }
    }
  }

  /// Returns true if the URL should be opened outside the WebView (UPI apps, wallets, tel:, mailto:, etc.)
  bool _shouldHandleExternally(String url) {
    const externalSchemes = [
      'upi://',
      'paytmmp://',
      'paytm://',
      // Digio sometimes uses custom "ppe://" scheme for PhonePe.
      // Treat it as external so we can remap to "phonepe://" later.
      'ppe://',
      'phonepe://',
      'gpay://',
      'tez://',
      'google.payments://',
      'googlepay://',
      'bhim://',
      'tel:',
      'mailto:',
      'whatsapp://',
      'intent://',
    ];

    return externalSchemes.any((scheme) => url.toLowerCase().startsWith(scheme));
  }

  /// Opens supported payment / deep-link URLs in external apps using url_launcher.
  Future<bool> _handleExternalUrl(String url) async {
    try {
      String finalUrl = url;
      bool isIntentUrl = false;
      
      // Handle Android intent: URLs - extract the actual UPI URL
      // Format: intent:upi://pay?...#Intent;scheme=upi;package=...;end
      // Or: intent:upi://pay?...
      if (Platform.isAndroid && url.toLowerCase().startsWith('intent:')) {
        isIntentUrl = true;
        debugPrint('[WebView] Android intent URL detected: $url');
        // Extract the part after "intent:" and before "#Intent" (if present)
        String intentContent = url.substring('intent:'.length);
        int intentIndex = intentContent.indexOf('#Intent');
        if (intentIndex != -1) {
          intentContent = intentContent.substring(0, intentIndex);
        }
        // Remove any trailing semicolons
        intentContent = intentContent.replaceAll(RegExp(r';+$'), '');
        finalUrl = intentContent.trim();
        debugPrint('[WebView] Extracted UPI URL from intent: $finalUrl');
      }
      
      // Map Digio's custom PhonePe scheme "ppe://" to the real "phonepe://"
      if (finalUrl.toLowerCase().startsWith('ppe://')) {
        finalUrl = 'phonepe://' + finalUrl.substring('ppe://'.length);
      }

      debugPrint('[WebView] Opening external URL: $finalUrl');

      // For UPI/payment URLs, try launching directly without canLaunchUrl check
      // (canLaunchUrl is unreliable for UPI schemes)
      final lowerUrl = finalUrl.toLowerCase();
      final isPaymentUrl = lowerUrl.startsWith('upi://') ||
          lowerUrl.startsWith('phonepe://') ||
          lowerUrl.startsWith('paytmmp://') ||
          lowerUrl.startsWith('paytm://') ||
          lowerUrl.startsWith('gpay://') ||
          lowerUrl.startsWith('tez://') ||
          lowerUrl.startsWith('bhim://') ||
          lowerUrl.startsWith('googlepay://');

      if (isPaymentUrl || isIntentUrl) {
        try {
          final uri = Uri.parse(finalUrl);
          debugPrint('[WebView] Attempting to launch payment URL: $finalUrl');
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
          _markPaymentAppLaunched(finalUrl);
          debugPrint('[WebView] Successfully launched payment URL');
          return true;
        } catch (e) {
          debugPrint('[WebView] Error launching payment URL directly: $e');
          // Fallback: try with canLaunchUrl check
          try {
            final uri = Uri.parse(finalUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              _markPaymentAppLaunched(finalUrl);
              return true;
            }
          } catch (_) {
            debugPrint('[WebView] Fallback launch also failed');
          }
        }
      }

      // Google Pay special handling: try multiple possible schemes
      if (finalUrl.contains('gpay') || finalUrl.contains('tez') || finalUrl.contains('google.payments')) {
        final gpaySchemes = [
          finalUrl,
          finalUrl.replaceAll('gpay://', 'tez://'),
          finalUrl.replaceAll('tez://', 'gpay://'),
          finalUrl.replaceAll('google.payments://', 'gpay://'),
        ];

        for (final scheme in gpaySchemes) {
          try {
            final uri = Uri.parse(scheme);
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            _markPaymentAppLaunched(finalUrl);
            return true;
          } catch (_) {
            // Try next scheme
          }
        }
      }

      // For other URLs, use canLaunchUrl check
      final uri = Uri.parse(finalUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        _markPaymentAppLaunched(finalUrl);
        return true;
      }

      debugPrint('[WebView] Could not launch URL: $finalUrl');
      return false;
    } catch (e, stackTrace) {
      debugPrint('[WebView] Error opening external URL: $e');
      debugPrint('[WebView] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Marks that a payment app was launched (for auto-reload on return)
  void _markPaymentAppLaunched(String url) {
    final lower = url.toLowerCase();
    final isPaymentUrl = lower.startsWith('upi://') ||
        lower.startsWith('phonepe://') ||
        lower.startsWith('paytmmp://') ||
        lower.startsWith('paytm://') ||
        lower.startsWith('gpay://') ||
        lower.startsWith('tez://') ||
        lower.startsWith('bhim://') ||
        lower.startsWith('googlepay://');
    
    if (isPaymentUrl) {
      if (_isReversePennyDropFlow) {
        _upiAppLaunched = true;
      } else {
        // For iOS: mark any payment app launch so we can reload on return
        if (Platform.isIOS) {
          _paymentAppLaunched = true;
        }
      }
    }
  }

  Future<void> _handleRedirectComplete({String? state, String? clientToken, String? auto, bool verifyCompleted = false}) async {
    if (_redirectHandled || !mounted) return;
    _redirectHandled = true;
    if (!mounted) return;
    
    // When verifyCompleted=true (IPV success), call get-context API directly
    // Don't navigate to route - let API call handle the data loading
    if (verifyCompleted) {
      final queryParams = <String, String>{};
      if (state != null) queryParams['state'] = state;
      queryParams['success'] = 'yes';
      
      final queryString = queryParams.isEmpty
          ? ''
          : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
      
      debugPrint('[WebView] IPV success - calling get-context API directly: /api/get-context/${widget.company}/${widget.workflowName}$queryString');
      
      try {
        final store = context.read<AppStore>();
        final hasToken = await StorageService.hasAccessToken();
        
        if (hasToken) {
          store.setParams(company: widget.company, workflowName: widget.workflowName);
          await store.fetchWorkflowFieldsWithAuth(
            widget.company,
            widget.workflowName,
            queryString,
          );
          
          if (mounted) {
            if (store.errorWithAuth != null) {
              debugPrint('[WebView] Error after get-context API: ${store.errorWithAuth}');
              Fluttertoast.showToast(
                msg: store.errorWithAuth ?? 'Error loading data',
                gravity: ToastGravity.TOP,
              );
            } else {
              debugPrint('[WebView] get-context API completed successfully - navigating back');
            }
            // Navigate back to home page (without query params since API already called)
            context.go('/${widget.company}/${widget.workflowName}');
          }
        } else {
          debugPrint('[WebView] No auth token - navigating with params');
          final query = queryParams.isEmpty
              ? ''
              : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
          if (mounted) context.go('/${widget.company}/${widget.workflowName}$query');
        }
      } catch (e) {
        debugPrint('[WebView] Exception calling get-context API: $e');
        if (mounted) {
          Fluttertoast.showToast(
            msg: 'Error: ${e.toString()}',
            gravity: ToastGravity.TOP,
          );
          // Fallback: navigate with params
          final query = queryParams.isEmpty
              ? ''
              : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
          context.go('/${widget.company}/${widget.workflowName}$query');
        }
      }
    } else {
      // For other redirects (DigiLocker, ReversePennyDrop, etc.), navigate with all params
      final queryParams = <String, String>{};
      if (state != null) queryParams['state'] = state;
      if (clientToken != null) queryParams['client_token'] = clientToken;
      if (auto != null) queryParams['auto'] = auto;

      // Add completion params (success=yes, transaction_id=..., etc.) from any segment
      // so get-context API knows step is complete and next step can proceed
      queryParams.addAll(_completionParams);

      final query = queryParams.isEmpty
          ? ''
          : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';

      debugPrint('[WebView] Going back to: /${widget.company}/${widget.workflowName}$query');
      if (mounted) context.go('/${widget.company}/${widget.workflowName}$query');
    }
  }

  Future<void> _onPageFinished(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();

    // Also capture completion params from onLoadStop (in case shouldOverride wasn't called)
    _captureCompletionParamsIfApplicable(url);

    // Only update preserved routing params from our main frontend domains
    final isMainFrontendHost = (host.contains('meon.co.in') &&
            !host.contains('digilocker.') &&
            !host.contains('api.') &&
            !host.contains('accounts.')) ||
        host.contains('stoxbox.in') ||
        host.contains('localhost');

    if (isMainFrontendHost) {
      if (uri.queryParameters.containsKey('state')) {
        _preservedState = uri.queryParameters['state'];
      }
      if (uri.queryParameters.containsKey('client_token')) {
        _preservedClientToken = uri.queryParameters['client_token'];
      }
      if (uri.queryParameters.containsKey('auto')) {
        _preservedAuto = uri.queryParameters['auto'];
      }
    }

    final isFrontendUrl = host.contains('stoxbox.in') ||
        (host.contains('meon.co.in') &&
            !host.contains('digilocker.meon.co.in') &&
            !host.contains('api.') &&
            !host.contains('accounts.')) ||
        host.contains('localhost');
    final isWorkflowPath = path.contains('/${widget.company}/${widget.workflowName}');
    final isReversePennyRoute = path.contains('/reverse_pennydrop/');
    final hasVerifyParam = uri.queryParameters.containsKey('verify');

    final initialUri = Uri.tryParse(widget.url);
    final initialHost = initialUri?.host.toLowerCase() ?? '';
    final initialWasVerifyPage = (initialHost.contains('stoxbox.in') ||
            (initialHost.contains('meon.co.in') &&
                !initialHost.contains('digilocker') &&
                !initialHost.contains('ext-'))) &&
        initialUri?.queryParameters.containsKey('verify') == true;

    if (hasVerifyParam) {
      debugPrint('[WebView] Currently on verify page - staying open');
      return;
    }

    // For Reverse Penny Drop, we must keep the WebView open on
    // /reverse_pennydrop/... so the Digio popup can complete.
    // Treat only the plain workflow URL (/company/workflowName) as "clean".
    final isCleanWorkflowUrl =
        isFrontendUrl && isWorkflowPath && !hasVerifyParam && !isReversePennyRoute;

    if (isCleanWorkflowUrl && initialWasVerifyPage) {
      if (!_hasSeenCleanUrl) {
        _hasSeenCleanUrl = true;
        debugPrint('[WebView] Verify page auto-redirected - staying open');
        return;
      } else {
        debugPrint('[WebView] Verify form submitted - closing WebView');
        await _handleRedirectComplete(
          state: uri.queryParameters['state'] ?? _preservedState,
          clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
          auto: uri.queryParameters['auto'] ?? _preservedAuto,
          verifyCompleted: true,
        );
      }
    } else if (isCleanWorkflowUrl && !initialWasVerifyPage) {
      debugPrint('[WebView] External flow completed - closing WebView');
      await _handleRedirectComplete(
        state: uri.queryParameters['state'] ?? _preservedState,
        clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
        auto: uri.queryParameters['auto'] ?? _preservedAuto,
        verifyCompleted: false,
      );
    }
  }


  /// Injects JavaScript to prevent automatic scroll jumps on input focus.
  /// This keeps the WebView from auto-scrolling when the keyboard opens;
  /// users can still scroll manually.
  Future<void> _injectNoAutoScrollJs(InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          window.addEventListener("focusin", function(e) {
            try {
              if (!e || !e.target) return;
              var el = e.target;
              el.scrollIntoView = function() {};
            } catch (_) {}
          }, true);
        } catch (e) {}
      })();
    ''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting no-auto-scroll JS: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: KycTheme.textPrimary),
          onPressed: () {
            if (mounted) {
              context.go('/${widget.company}/${widget.workflowName}');
            }
          },
        ),
        title: Text(
          widget.title,
          style: const TextStyle(
            color: KycTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: KycTheme.textPrimary),
            onPressed: _isLoading ? null : _reloadWebView,
            tooltip: 'Reload',
          ),
          if (_isIpvOrFaceFinderUrl(_currentUrl))
            IconButton(
              icon: const Icon(Icons.camera_alt, color: KycTheme.textPrimary),
              onPressed: () {
                _permissionsRequested = false;
                _requestPermissionsAndReload();
              },
              tooltip: 'Request Permissions',
            ),
        ],
        bottom: _isLoading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(
                  color: KycTheme.primary,
                  backgroundColor: KycTheme.border,
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Main WebView
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                // Allow JS popups / window.open only for special flows (Reverse Penny Drop, Digio eSign, etc.)
                javaScriptCanOpenWindowsAutomatically: _supportsPopupWindows,
                supportMultipleWindows: _supportsPopupWindows,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                useHybridComposition: true,
                // Disable pinch-zoom to keep layout stable
                supportZoom: false,
                // Android-specific: Enable camera/microphone/location access in WebView
                allowFileAccess: true,
                allowFileAccessFromFileURLs: true,
                allowUniversalAccessFromFileURLs: true,
                thirdPartyCookiesEnabled: true,
                // Enable geolocation for IPV/Face Finder (required for location-based verification)
                geolocationEnabled: true,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
              },
              // Handle popup windows (window.open) – important for Reverse Penny Drop / Digio eSign bank flows
              onCreateWindow: (controller, createWindowAction) async {
                final popupUri = createWindowAction.request.url;
                final popupUrl = popupUri?.toString() ?? '';
                debugPrint('[WebView] onCreateWindow: $popupUrl');

                if (!_supportsPopupWindows) {
                  return false;
                }

                // Digio often calls window.open('') / about:blank first.
                // When a windowId is provided, create an overlay WebView bound to it.
                if (createWindowAction.windowId != null) {
                  setState(() {
                    _popupWindowId = createWindowAction.windowId;
                  });
                  return true; // popup handled by overlay InAppWebView with windowId
                }

                // If there's a real URL but no windowId (rare), open inside same WebView.
                if (popupUri != null &&
                    popupUrl.isNotEmpty &&
                    popupUrl != 'about:blank') {
                  await _webViewController?.loadUrl(
                    urlRequest: URLRequest(url: popupUri),
                  );
                  return true;
                }

                return false;
              },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri == null) return NavigationActionPolicy.ALLOW;

            final url = uri.toString();
            debugPrint('[WebView] Navigation request: $url');

            // Always cancel intent: URLs on Android to prevent ERR_UNKNOWN_URL_SCHEME error
            if (Platform.isAndroid && url.toLowerCase().startsWith('intent:')) {
              debugPrint('[WebView] Intent URL detected - handling externally');
              await _handleExternalUrl(url);
              return NavigationActionPolicy.CANCEL;
            }

            if (_shouldHandleExternally(url)) {
              final handled = await _handleExternalUrl(url);
              if (handled) {
                debugPrint('[WebView] External URL handled by app, cancelling WebView navigation');
                return NavigationActionPolicy.CANCEL;
              }
            }

            // Capture completion params from success/return URLs (e.g. ?success=yes&transaction_id=...)
            // Works for RPD, DigiLocker, and other segments - any URL with params before final workflow URL
            _captureCompletionParamsIfApplicable(url);

            // Reverse Penny Drop: if completion params appear in URL, close WebView immediately (no timer needed)
            if (_isReversePennyDropUrl(url) && !_redirectHandled && !_rpdSuccessHandled) {
              final uri = Uri.tryParse(url);
              if (uri != null && uri.queryParameters.isNotEmpty) {
                final completionParamKeys = [
                  'success',
                  'transaction_id',
                  'reversepennydrop',
                  'esign',
                ];
                final hasCompletionParams = uri.queryParameters.keys.any((key) => 
                    completionParamKeys.contains(key.toLowerCase()));
                if (hasCompletionParams) {
                  debugPrint('[WebView] RPD completion params detected in URL - closing WebView');
                  _rpdSuccessHandled = true;
                  _completionParams.addAll(uri.queryParameters);
                  if (!_completionParams.containsKey('success')) {
                    _completionParams['success'] = 'yes';
                  }
                  await _handleRedirectComplete(
                    state: uri.queryParameters['state'] ?? _preservedState,
                    clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
                    auto: uri.queryParameters['auto'] ?? _preservedAuto,
                    verifyCompleted: false,
                  );
                  return NavigationActionPolicy.CANCEL;
                }
              }
            }

            return NavigationActionPolicy.ALLOW;
          },
              onCloseWindow: (controller) {
                // Popup window closed – hide overlay
                if (_popupWindowId != null) {
                  setState(() {
                    _popupWindowId = null;
                  });
                  // For flows that rely on Digio-style popups (Reverse Penny Drop, Digio eSign),
                  // after the popup closes, reload main page so it can fetch updated success state / params.
                  if ((_isReversePennyDropFlow || _isDigioEsignFlow) &&
                      _webViewController != null &&
                      !_redirectHandled &&
                      !_rpdSuccessHandled) {
                    Future.delayed(const Duration(milliseconds: 500), () async {
                      if (!mounted || _redirectHandled || _rpdSuccessHandled) return;
                      debugPrint('[WebView] Popup closed - reloading main page to fetch success state with params');
                      await _webViewController?.reload();
                    });
                  }
                }
              },
              onLoadStart: (controller, url) async {
            if (url != null && !_redirectHandled) {
              setState(() {
                _isLoading = true;
                _currentUrl = url.toString();
              });
              debugPrint('[WebView] Page started: $url');

              // IPV/Face Finder success: redirect to live.meon.co.in/.../individual?state=...&success=yes
              // Close WebView immediately on success redirect (don't wait for page load)
              final uri = Uri.tryParse(url.toString());
              if (uri != null) {
                final host = uri.host.toLowerCase();
                final path = uri.path.toLowerCase();
                final hasSuccess = uri.queryParameters['success']?.toLowerCase() == 'yes';
                final hasState = uri.queryParameters.containsKey('state');
                final isWorkflowPath = path.contains('/${widget.company}/${widget.workflowName}');
                final isMeonRedirect = host.contains('meon.co.in') &&
                    !host.contains('ipv.') &&
                    !host.contains('api.') &&
                    !host.contains('digilocker.');

                if (isMeonRedirect && isWorkflowPath && (hasSuccess || hasState)) {
                  debugPrint('[WebView] IPV success redirect detected - closing WebView immediately');
                  await _handleRedirectComplete(
                    state: uri.queryParameters['state'] ?? _preservedState,
                    clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
                    auto: uri.queryParameters['auto'] ?? _preservedAuto,
                    verifyCompleted: hasSuccess,
                  );
                  return;
                }
              }

              // Request permissions on load (iOS or if Android permissions weren't requested before)
              if (_isIpvOrFaceFinderUrl(url.toString()) && !_permissionsRequested) {
                if (Platform.isAndroid) {
                  // Android: Request if not already done (should have been done in initState)
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _requestPermissionsBeforeLoad();
                  });
                } else {
                  // iOS: Request after load (works fine)
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _requestPermissionsAndReload();
                  });
                }
              }
            }
          },
              onLoadError: (controller, url, code, message) {
            debugPrint('[WebView] Load error ($code): $message, url=$url');
            // Ignore unknown URL scheme errors which are expected for external payment intents
            if (code == -10 && message.contains('net::ERR_UNKNOWN_URL_SCHEME')) {
              return;
            }
          },
              onLoadStop: (controller, url) async {
            if (url != null) {
              setState(() {
                _isLoading = false;
                _currentUrl = url.toString();
              });
              debugPrint('[WebView] Page finished: $url');

              // For eSign pages, nudge initial scroll slightly so
              // important inputs are not hidden under the keyboard.
              try {
                final uri = Uri.tryParse(url.toString());
                if (uri != null) {
                  final host = uri.host.toLowerCase();
                  final isCloudesign = host.contains('cloudesign');
                  final isNsdlEsign = host.contains('esign.egov.proteantech.in') ||
                      host.startsWith('esign.');
                  if (!_esignScrollAdjusted && (isCloudesign || isNsdlEsign)) {
                    _esignScrollAdjusted = true;
                    // Use native scrollTo first (more reliable), then JS fallback
                    await controller.scrollTo(x: 0, y: 260);
                    await controller.evaluateJavascript(
                      source: 'try { window.scrollTo(0, 260); } catch(e) {}',
                    );
                  }
                }
              } catch (e) {
                debugPrint('[WebView] Error adjusting scroll for eSign: $e');
              }

              if (_isIpvOrFaceFinderUrl(url.toString()) &&
                  _permissionsRequested &&
                  !_hasReloadedAfterPermissions) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (mounted && _currentUrl == url.toString() && !_hasReloadedAfterPermissions) {
                    _hasReloadedAfterPermissions = true;
                    debugPrint('[WebView] Reloading IPV page after permission grant');
                    controller.reload();
                  }
                });
              }

              await _onPageFinished(url.toString());
              await _injectNoAutoScrollJs(controller);

              // Reverse Penny Drop: check if completion params appeared in URL (params = completion indicator)
              if (_isReversePennyDropUrl(url.toString()) && !_redirectHandled && !_rpdSuccessHandled) {
                final uri = Uri.tryParse(url.toString());
                if (uri != null && uri.queryParameters.isNotEmpty) {
                  final completionParamKeys = [
                    'success',
                    'transaction_id',
                    'reversepennydrop',
                    'esign',
                  ];
                  final hasCompletionParams = uri.queryParameters.keys.any((key) => 
                      completionParamKeys.contains(key.toLowerCase()));
                  if (hasCompletionParams) {
                    debugPrint('[WebView] RPD completion params detected in URL onLoadStop - closing WebView');
                    _rpdSuccessHandled = true;
                    _completionParams.addAll(uri.queryParameters);
                    if (!_completionParams.containsKey('success')) {
                      _completionParams['success'] = 'yes';
                    }
                    await _handleRedirectComplete(
                      state: uri.queryParameters['state'] ?? _preservedState,
                      clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
                      auto: uri.queryParameters['auto'] ?? _preservedAuto,
                      verifyCompleted: false,
                    );
                  }
                }
              }
            }
          },
              onPermissionRequest: (controller, request) async {
            debugPrint('[WebView] Permission requested (camera/mic): ${request.resources}');
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },
              // Handle geolocation permission requests (required for IPV on Android)
              onGeolocationPermissionsShowPrompt: (controller, origin) async {
                debugPrint('[WebView] Geolocation permission requested for: $origin');
                // Check if location permission is already granted
                final locationStatus = await Permission.location.status;
                if (locationStatus.isGranted || locationStatus.isLimited) {
                  debugPrint('[WebView] Location permission already granted - allowing geolocation');
                  return GeolocationPermissionShowPromptResponse(
                    origin: origin,
                    allow: true,
                    retain: true,
                  );
                } else {
                  debugPrint('[WebView] Location permission not granted - requesting...');
                  final result = await Permission.location.request();
                  if (result.isGranted || result.isLimited) {
                    debugPrint('[WebView] Location permission granted - allowing geolocation');
                    return GeolocationPermissionShowPromptResponse(
                      origin: origin,
                      allow: true,
                      retain: true,
                    );
                  } else {
                    debugPrint('[WebView] Location permission denied - denying geolocation');
                    return GeolocationPermissionShowPromptResponse(
                      origin: origin,
                      allow: false,
                      retain: false,
                    );
                  }
                }
              },
            ),

            // Popup overlay WebView for reverse_pennydrop (Digio window.open)
            if (_popupWindowId != null)
              Positioned.fill(
                child: Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.95,
                    heightFactor: 0.9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: InAppWebView(
                        windowId: _popupWindowId,
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          mediaPlaybackRequiresUserGesture: false,
                          allowsInlineMediaPlayback: true,
                          useHybridComposition: true,
                          supportZoom: false,
                          // Enable geolocation for popup WebView as well
                          geolocationEnabled: true,
                        ),
                        shouldOverrideUrlLoading:
                            (controller, navigationAction) async {
                          final uri = navigationAction.request.url;
                          if (uri == null) {
                            return NavigationActionPolicy.ALLOW;
                          }
                          final url = uri.toString();
                          debugPrint(
                              '[WebView][Popup] Navigation request: $url');
                          
                          // Always cancel intent: URLs on Android to prevent ERR_UNKNOWN_URL_SCHEME error
                          if (Platform.isAndroid && url.toLowerCase().startsWith('intent:')) {
                            debugPrint('[WebView][Popup] Intent URL detected - handling externally');
                            await _handleExternalUrl(url);
                            return NavigationActionPolicy.CANCEL;
                          }
                          
                          if (_shouldHandleExternally(url)) {
                            final handled = await _handleExternalUrl(url);
                            if (handled) {
                              debugPrint(
                                  '[WebView][Popup] External URL handled by app, cancelling WebView navigation');
                              return NavigationActionPolicy.CANCEL;
                            }
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                        onLoadError: (controller, url, code, message) {
                          debugPrint('[WebView][Popup] Load error ($code): $message, url=$url');
                          // Ignore unknown URL scheme errors for intent URLs (expected on Android)
                          if (code == -10 && message.contains('net::ERR_UNKNOWN_URL_SCHEME')) {
                            debugPrint('[WebView][Popup] Ignoring ERR_UNKNOWN_URL_SCHEME (intent URL handled externally)');
                            return;
                          }
                        },
                        onLoadStop: (controller, url) async {
                          if (url != null) {
                            await _injectNoAutoScrollJs(controller);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),

            // Fullscreen loader overlay while the page is loading
            if (_isLoading)
              Positioned.fill(
                child: Container(
                  color: Colors.white,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: KycTheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
