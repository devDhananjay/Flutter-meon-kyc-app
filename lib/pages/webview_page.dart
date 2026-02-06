import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fluttertoast/fluttertoast.dart';

/// WebView page for external redirects (like DigiLocker)
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
  late final WebViewController _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  String? _preservedState;
  String? _preservedClientToken;
  String? _preservedAuto;
  bool _hasSeenCleanUrl = false; // Track if verify page has redirected to clean URL once
  bool _permissionsRequested = false; // Track if permissions have been requested
  bool _hasReloadedAfterPermissions = false; // Track if we've already reloaded after permissions

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    
    // Extract and preserve params from initial URL
    final initialUri = Uri.tryParse(widget.url);
    if (initialUri != null) {
      _preservedState = initialUri.queryParameters['state'];
      _preservedClientToken = initialUri.queryParameters['client_token'];
      _preservedAuto = initialUri.queryParameters['auto'];
      debugPrint('[WebView] Initial params from URL: state=$_preservedState, client_token=$_preservedClientToken, auto=$_preservedAuto');
    }
    
    // Request permissions if IPV/Face Finder URL
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isIpvOrFaceFinderUrl(widget.url)) {
        _requestPermissionsAndReload();
      }
    });
    
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              _currentUrl = url;
            });
            debugPrint('[WebView] Page started: $url');
            
            // Request permissions if IPV/Face Finder URL and not already requested
            if (_isIpvOrFaceFinderUrl(url) && !_permissionsRequested) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _requestPermissionsAndReload();
              });
            }
          },
          onPageFinished: (url) {
            setState(() {
              _isLoading = false;
              _currentUrl = url;
            });
            debugPrint('[WebView] Page finished: $url');
            
            // If IPV/Face Finder URL and permissions were just granted, reload once
            if (_isIpvOrFaceFinderUrl(url) && _permissionsRequested && !_hasReloadedAfterPermissions) {
              // Small delay to ensure page is fully loaded before reload
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted && _currentUrl == url && !_hasReloadedAfterPermissions) {
                  _hasReloadedAfterPermissions = true;
                  debugPrint('[WebView] Reloading IPV page after permission grant');
                  _controller.reload();
                }
              });
            }
            
            // Check if we're back to frontend domain (redirect completed)
            final uri = Uri.tryParse(url);
            if (uri != null) {
              final host = uri.host.toLowerCase();
              final path = uri.path.toLowerCase();
              
              // Preserve state & client_token when first seen (from DigiLocker callback)
              if (uri.queryParameters.containsKey('state')) {
                _preservedState = uri.queryParameters['state'];
              }
              if (uri.queryParameters.containsKey('client_token')) {
                _preservedClientToken = uri.queryParameters['client_token'];
              }
              if (uri.queryParameters.containsKey('auto')) {
                _preservedAuto = uri.queryParameters['auto'];
              }
              
              // DigiLocker flow complete: Final redirect is to frontend (ekyc.stoxbox.in, newkyctest.meon.co.in)
              final isFrontendUrl = host.contains('stoxbox.in') || 
                                   (host.contains('meon.co.in') && 
                                    !host.contains('digilocker.meon.co.in') && 
                                    !host.contains('api.') &&
                                    !host.contains('accounts.')) ||
                                   host.contains('localhost');
              final isWorkflowPath = path.contains('/${widget.company}/${widget.workflowName}');
              
              // Check if current page has verify param
              final hasVerifyParam = uri.queryParameters.containsKey('verify');
              
              // Check if initial URL was a FRONTEND verify page (not DigiLocker)
              final initialUri = Uri.tryParse(widget.url);
              final initialHost = initialUri?.host.toLowerCase() ?? '';
              final initialWasVerifyPage = (initialHost.contains('stoxbox.in') || 
                                           (initialHost.contains('meon.co.in') && 
                                            !initialHost.contains('digilocker') &&
                                            !initialHost.contains('ext-'))) &&
                                          initialUri?.queryParameters.containsKey('verify') == true;
              
              // If we're still ON a verify URL, keep WebView open
              if (hasVerifyParam) {
                debugPrint('[WebView] Currently on verify page (has verify param) - staying open');
                return;
              }
              
              // Check if this is a clean workflow URL
              final isCleanWorkflowUrl = isFrontendUrl && isWorkflowPath && !hasVerifyParam;
              
              if (isCleanWorkflowUrl && initialWasVerifyPage) {
                // Verify page: clean URL might be where form is shown (after auto-redirect)
                // Don't close on FIRST redirect to clean URL - that's just the page loading
                // Only close on SECOND redirect (after user submits form)
                if (!_hasSeenCleanUrl) {
                  _hasSeenCleanUrl = true;
                  debugPrint('[WebView] Verify page auto-redirected to clean URL - staying open for user to interact with form');
                  return; // Stay open - this is where the form is shown
                } else {
                  // Second time we see clean URL - user must have submitted form
                  debugPrint('[WebView] Verify form submitted (second clean URL redirect) - closing WebView');
                  
                  final state = uri.queryParameters['state'] ?? _preservedState;
                  final clientToken = uri.queryParameters['client_token'] ?? _preservedClientToken;
                  final autoParam = uri.queryParameters['auto'] ?? _preservedAuto;
                  
                  debugPrint('[WebView] Initial URL: ${widget.url}, Final URL: $url');
                  debugPrint('[WebView] Returning to app with: state=$state, client_token=$clientToken, auto=$autoParam, verifyCompleted=true');
                  _handleRedirectComplete(
                    state: state,
                    clientToken: clientToken,
                    auto: autoParam,
                    verifyCompleted: true, // Verify page completed
                  );
                }
              } else if (isCleanWorkflowUrl && !initialWasVerifyPage) {
                // Non-verify page (like DigiLocker) - close immediately on clean URL
                final state = uri.queryParameters['state'] ?? _preservedState;
                final clientToken = uri.queryParameters['client_token'] ?? _preservedClientToken;
                final autoParam = uri.queryParameters['auto'] ?? _preservedAuto;
                
                debugPrint('[WebView] External flow completed! Initial URL: ${widget.url}, Final URL: $url');
                debugPrint('[WebView] Returning to app with: state=$state, client_token=$clientToken, auto=$autoParam, verifyCompleted=false');
                _handleRedirectComplete(
                  state: state,
                  clientToken: clientToken,
                  auto: autoParam,
                  verifyCompleted: false, // Not a verify page
                );
              }
            }
          },
          onNavigationRequest: (request) {
            debugPrint('[WebView] Navigation request: ${request.url}');
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            debugPrint('[WebView] Error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  /// Check if URL is IPV or Face Finder URL
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

  /// Request camera, microphone, and location permissions for IPV/Face Finder
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
      status == PermissionStatus.granted || status == PermissionStatus.limited
    );

    if (allGranted) {
      debugPrint('[WebView] All permissions granted, reloading WebView');
      Fluttertoast.showToast(
        msg: 'Permissions granted. Reloading...',
        toastLength: Toast.LENGTH_SHORT,
      );
      // Reload after a short delay to ensure permissions are applied
      if (!_hasReloadedAfterPermissions) {
        _hasReloadedAfterPermissions = true;
        Future.delayed(const Duration(milliseconds: 500), () {
          _reloadWebView();
        });
      }
    } else {
      debugPrint('[WebView] Some permissions denied');
      Fluttertoast.showToast(
        msg: 'Some permissions are required for verification',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.orange,
      );
    }
  }

  /// Reload the WebView
  Future<void> _reloadWebView() async {
    try {
      debugPrint('[WebView] Reloading WebView: $_currentUrl');
      await _controller.reload();
      Fluttertoast.showToast(
        msg: 'Page reloaded',
        toastLength: Toast.LENGTH_SHORT,
      );
    } catch (e) {
      debugPrint('[WebView] Error reloading: $e');
    }
  }

  void _handleRedirectComplete({String? state, String? clientToken, String? auto, bool verifyCompleted = false}) {
    // Go back to KYC flow after external verification completes
    if (mounted) {
      // Build query string with params from redirect URL
      final queryParams = <String, String>{};
      if (state != null) queryParams['state'] = state;
      if (clientToken != null) queryParams['client_token'] = clientToken;
      if (auto != null) queryParams['auto'] = auto;
      // Add flag to indicate verify step is done, prevent re-redirect
      if (verifyCompleted) queryParams['verifyCompleted'] = 'true';
      
      final query = queryParams.isEmpty 
          ? '' 
          : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
      
      debugPrint('[WebView] Going back to: /${widget.company}/${widget.workflowName}$query (verifyCompleted=$verifyCompleted)');
      context.go('/${widget.company}/${widget.workflowName}$query');
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
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh, color: KycTheme.textPrimary),
            onPressed: _isLoading ? null : () {
              _reloadWebView();
            },
            tooltip: 'Reload',
          ),
          // Request permissions button (for IPV/Face Finder)
          if (_isIpvOrFaceFinderUrl(_currentUrl))
            IconButton(
              icon: const Icon(Icons.camera_alt, color: KycTheme.textPrimary),
              onPressed: () {
                _permissionsRequested = false; // Reset to allow re-request
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
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
