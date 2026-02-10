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

class _WebViewPageState extends State<WebViewPage> {
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

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;

    final initialUri = Uri.tryParse(widget.url);
    if (initialUri != null) {
      _preservedState = initialUri.queryParameters['state'];
      _preservedClientToken = initialUri.queryParameters['client_token'];
      _preservedAuto = initialUri.queryParameters['auto'];
      debugPrint('[WebView] Initial params from URL: state=$_preservedState, client_token=$_preservedClientToken, auto=$_preservedAuto');
    }

    if (_isIpvOrFaceFinderUrl(widget.url)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _requestPermissionsAndReload();
      });
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
        msg: 'Camera & microphone required for face verification',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.orange,
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

    // Known completion params that indicate step completion (eSign, RPD, etc.)
    final completionParamKeys = ['esign', 'success', 'transaction_id', 'verifyCompleted'];
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
      debugPrint('[WebView] Opening external URL: $url');

      // Google Pay special handling: try multiple possible schemes
      if (url.contains('gpay') || url.contains('tez') || url.contains('google.payments')) {
        final gpaySchemes = [
          url,
          url.replaceAll('gpay://', 'tez://'),
          url.replaceAll('tez://', 'gpay://'),
          url.replaceAll('google.payments://', 'gpay://'),
        ];

        for (final scheme in gpaySchemes) {
          try {
            final uri = Uri.parse(scheme);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return true;
            }
          } catch (_) {
            // Try next scheme
          }
        }
      }

      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[WebView] Error opening external URL: $e');
      return false;
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
              Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Error loading data');
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
          Fluttertoast.showToast(msg: 'Error: ${e.toString()}');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
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
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            useHybridComposition: true,
          ),
          onWebViewCreated: (controller) {
            _webViewController = controller;
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri == null) return NavigationActionPolicy.ALLOW;

            final url = uri.toString();
            debugPrint('[WebView] Navigation request: $url');

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

            return NavigationActionPolicy.ALLOW;
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

              if (_isIpvOrFaceFinderUrl(url.toString()) && !_permissionsRequested) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _requestPermissionsAndReload();
                });
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
            }
          },
          onPermissionRequest: (controller, request) async {
            debugPrint('[WebView] Permission requested (camera/mic): ${request.resources}');
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          },
        ),
      ),
    );
  }
}
