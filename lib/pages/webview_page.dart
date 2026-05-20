import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:path_provider/path_provider.dart';
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
  bool _pendingReloadAfterPermissions = false;
  bool _permissionRequestScheduled = false;
  bool _permissionHandlerInFlight = false;
  bool _ipvPermissionGateActive = false;
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

  // --- Loading / error UX state ---
  bool _hasError = false;
  String _errorMessage = 'Something went wrong, please try again.';
  String _loadingMessage = 'Loading...';
  // Set true once the first page finishes loading (controls full-screen cover behaviour)
  bool _initialPageLoaded = false;
  // Timeout timer: fires if the page hasn't loaded within 15 seconds (45 s for eSign/PDF)
  Timer? _loadTimeoutTimer;
  // Slow-network / hint timers — staged messages on heavy document loads
  Timer? _slowNetworkTimer;
  Timer? _loadHintTimer2;
  int _reversePennyPollAttempts = 0;
  static const int _maxReversePennyPollAttempts = 18; // ~90 seconds @ 5s interval
  // Avoid repeating special scroll adjustment for eSign (clouDesign) pages
  bool _esignScrollAdjusted = false;
  // Track if we already handled RPD success (to avoid double-close)
  bool _rpdSuccessHandled = false;

  // Reverse Penny Drop: only reload after we see signing-complete text,
  // to avoid refresh loops while user is entering UPI details.
  bool _rpdSigningCompletedReloadTriggered = false;

  // Reset the sessionStorage flag only once per WebViewPage instance,
  // so a reload caused by the console message doesn't re-clear the guard.
  bool _rpdSigningSessionFlagReset = false;
  // eSign / cloudesign PDF pages may render blank on first load — retry in-app only.
  int _cloudesignAutoReloadAttempts = 0;
  static const int _maxCloudesignAutoReloadAttempts = 6;
  Timer? _cloudesignRecoveryTimer;

  /// True while an eSign PDF save is in flight (ignore duplicate download events).
  bool _esignPdfDownloadInProgress = false;

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// pdf.js can fire several `onDownloadStartRequest` events for one toolbar tap.
  DateTime? _lastEsignPdfDownloadEventAt;

  /// eSign / PDF (pdf.js) pages often need more time than a normal HTML page.
  bool _isEsignPdfHeavyUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('cloudesign') ||
        u.contains('esign.meon') ||
        u.contains('esignservices') ||
        u.contains('/esign/') ||
        u.contains('proteantech') ||
        u.contains('pdf.js') ||
        u.contains('cdnjs.cloudflare.com/ajax/libs/pdf.js');
  }

  bool _isBlobDownloadUrl(String url) =>
      url.toLowerCase().startsWith('blob:');

  bool _isCloudesignDocumentUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
        path.contains('/cloudesign/document-');
  }

  /// eSign HTML app (`esign.meon.co.in/EsignServices/...`) — loads via JS after
  /// `onLoadStop`. Never auto-reload; user interacts on the live page.
  bool _isEsignServiceSpaUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('esign.meon.co.in') &&
        (u.contains('/esignservices/') || u.contains('/esign/'));
  }

  /// In-app auto-retry only for cloudesign **document** PDF pages (blank first paint).
  /// eSign service SPAs and other heavy URLs must not reload after a successful load.
  bool _usesInAppDocumentAutoRetry(String url) {
    if (_isEsignServiceSpaUrl(url)) return false;
    return _isCloudesignDocumentUrl(url);
  }

  void _cancelCloudesignRecovery() {
    _cloudesignRecoveryTimer?.cancel();
    _cloudesignRecoveryTimer = null;
  }

  void _resetDocumentRetryState() {
    _cloudesignAutoReloadAttempts = 0;
    _cancelCloudesignRecovery();
  }

  void _showInAppDocumentRetryAfterFailedRecovery() {
    _cancelCloudesignRecovery();
    if (!mounted || _redirectHandled) return;
    debugPrint(
        '[WebView] Document still not loaded after $_maxCloudesignAutoReloadAttempts in-app retries — showing retry UI');
    setState(() {
      _isLoading = false;
      _hasError = true;
      _errorMessage =
          'We could not load the document after several tries. Please check your connection and tap Try Again to reload inside the app.';
      _loadingMessage = 'Loading...';
    });
  }

  bool _isProceedToEsignFlowContext([String? url]) {
    final sample = (url ?? _currentUrl).toLowerCase();
    if (_isEsignPdfHeavyUrl(sample) || _isCloudesignDocumentUrl(sample)) {
      return true;
    }
    return widget.title.toLowerCase().contains('esign');
  }

  bool _looksLikePdfFileNavigation(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.pdf')) return true;
    if (lower.contains('application/pdf')) return true;
    if (lower.contains('content-disposition=attachment') &&
        lower.contains('pdf')) {
      return true;
    }
    return false;
  }

  Future<void> _resetEsignDownloadUserGesture(
      InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: 'try { window.__meonUserGestureForDownload = false; } catch(e) {}',
      );
    } catch (_) {}
  }

  Future<void> _injectEsignDownloadUserGestureTracker(
      InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          if (window.__meonEsignDownloadHookInstalled) return;
          window.__meonEsignDownloadHookInstalled = true;
          window.__meonUserGestureForDownload = false;
          function arm() { window.__meonUserGestureForDownload = true; }
          ['click', 'touchstart', 'touchend', 'pointerdown', 'pointerup'].forEach(function(evt) {
            document.addEventListener(evt, arm, true);
          });
        } catch (e) {}
      })();
    ''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting eSign download gesture tracker: $e');
    }
  }

  /// Blob navigations and WKWebKit "frame load interrupted" (102) are normal
  /// when pdf.js triggers a download — not a real page failure.
  bool _shouldIgnoreWebViewLoadError(
    String url, {
    int? code,
    String? description,
  }) {
    final u = url.toLowerCase();
    if (u.startsWith('blob:')) return true;
    if (code == 102) return true;
    final d = (description ?? '').toLowerCase();
    if (d.contains('frame load interrupted')) return true;
    return false;
  }

  Future<bool> _hasEsignDownloadUserGesture(
      InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: 'window.__meonUserGestureForDownload === true',
      );
      if (result is bool) return result;
      return result?.toString().toLowerCase() == 'true';
    } catch (e) {
      debugPrint('[WebView] Error reading eSign download gesture flag: $e');
      return false;
    }
  }

  String _sanitizeDownloadFilename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'kyc_esign_document.pdf';
    return trimmed.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  }

  String _filenameFromDownloadUrl(String url) {
    if (url.toLowerCase().startsWith('blob:')) {
      return 'kyc_esign_document.pdf';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'kyc_esign_document.pdf';
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return 'kyc_esign_document.pdf';
    final last = segments.last;
    if (last.toLowerCase().endsWith('.pdf')) {
      return _sanitizeDownloadFilename(last);
    }
    return 'kyc_esign_document.pdf';
  }

  /// pdf.js on eSign uses in-memory `blob:https://...` URLs. Those only exist inside this
  /// WebView — never pass them to Dart [http.get]. Read bytes in-page via [callAsyncJavaScript].
  Future<Uint8List> _readBlobUrlBytesInWebView(
    InAppWebViewController controller,
    String blobUrl,
  ) async {
    final result = await controller.callAsyncJavaScript(
      functionBody: '''
        const response = await fetch(arguments.blobUrl);
        if (!response.ok) {
          throw new Error('fetch failed: ' + response.status);
        }
        const blob = await response.blob();
        const buffer = await blob.arrayBuffer();
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.byteLength; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
      ''',
      arguments: {'blobUrl': blobUrl},
    );

    if (result == null) {
      throw Exception('WebView did not return blob bytes');
    }
    if (result.error != null && result.error!.trim().isNotEmpty) {
      throw Exception(result.error!.trim());
    }
    final value = result.value;
    if (value == null || value.toString().isEmpty) {
      throw Exception('Empty blob bytes from WebView');
    }
    return base64Decode(value.toString());
  }

  void _showEsignDownloadMessage(
    String message, {
    bool isError = false,
    bool clearPrevious = true,
  }) {
    if (!mounted) return;
    final messenger =
        _scaffoldMessengerKey.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      if (clearPrevious) {
        messenger.hideCurrentSnackBar();
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          backgroundColor: isError ? Colors.red.shade700 : KycTheme.primary,
          duration: Duration(seconds: isError ? 4 : 10),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 28),
        ),
      );
    }
    // Short toast as backup (no gravity — avoids Android text-toast issues).
    final summary = message.split('\n').first.trim();
    if (summary.isNotEmpty) {
      Fluttertoast.cancel();
      Fluttertoast.showToast(
        msg: summary,
        toastLength: Toast.LENGTH_LONG,
      );
    }
  }

  Future<void> _handleEsignPdfDownload(
    InAppWebViewController controller, {
    required WebUri downloadUrl,
    String? suggestedFilename,
    String? userAgent,
    String? mimeType,
    bool skipGestureCheck = false,
  }) async {
    if (!mounted) return;
    if (!_isProceedToEsignFlowContext()) {
      debugPrint('[WebView] Ignoring download outside eSign/PDF context');
      return;
    }
    if (_esignPdfDownloadInProgress) return;

    if (!skipGestureCheck) {
      final allowed = await _hasEsignDownloadUserGesture(controller);
      if (!allowed) {
        debugPrint(
            '[WebView] Blocked PDF download without user tap (auto-download prevented)');
        return;
      }
    }

    final now = DateTime.now();
    if (_lastEsignPdfDownloadEventAt != null &&
        now.difference(_lastEsignPdfDownloadEventAt!) <
            const Duration(seconds: 3)) {
      debugPrint('[WebView] Ignoring duplicate PDF download event');
      return;
    }
    _lastEsignPdfDownloadEventAt = now;

    _esignPdfDownloadInProgress = true;
    try {
      var filename = suggestedFilename?.trim();
      if (filename == null || filename.isEmpty) {
        filename = _filenameFromDownloadUrl(downloadUrl.toString());
      }
      filename = _sanitizeDownloadFilename(filename);
      final mime = mimeType?.toLowerCase() ?? '';
      if (!filename.toLowerCase().endsWith('.pdf') && mime.contains('pdf')) {
        filename = '$filename.pdf';
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${docsDir.path}/esign_downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }

      var savePath = '${downloadsDir.path}/$filename';
      if (await File(savePath).exists()) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        savePath = '${downloadsDir.path}/${stamp}_$filename';
      }

      final urlStr = downloadUrl.toString();
      final Uint8List fileBytes;
      if (urlStr.toLowerCase().startsWith('blob:')) {
        debugPrint(
            '[WebView] Saving PDF from in-WebView blob (not an HTTP download URL)');
        fileBytes = await _readBlobUrlBytesInWebView(controller, urlStr);
        if (fileBytes.isEmpty) {
          throw Exception('Downloaded PDF is empty');
        }
      } else {
        final httpUri = Uri.parse(urlStr);
        if (!httpUri.hasScheme || httpUri.host.isEmpty) {
          throw Exception('Invalid download URL');
        }
        final cookieBase = WebUri(_currentUrl);
        final cookies = await CookieManager.instance().getCookies(url: cookieBase);
        final headers = <String, String>{};
        if (userAgent != null && userAgent.trim().isNotEmpty) {
          headers['User-Agent'] = userAgent;
        }
        if (cookies.isNotEmpty) {
          headers['Cookie'] =
              cookies.map((c) => '${c.name}=${c.value}').join('; ');
        }
        final response = await http.get(httpUri, headers: headers);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('HTTP ${response.statusCode}');
        }
        fileBytes = response.bodyBytes;
      }

      await File(savePath).writeAsBytes(fileBytes, flush: true);
      debugPrint('[WebView] eSign PDF saved: $savePath');
      final savedName = savePath.split('/').last;
      _showEsignDownloadMessage(
        'PDF downloaded successfully\n$savedName\n$savePath',
      );
    } catch (e) {
      debugPrint('[WebView] eSign PDF download failed: $e');
      _showEsignDownloadMessage(
        'Download failed. Please try again.',
        isError: true,
      );
    } finally {
      _esignPdfDownloadInProgress = false;
      // Keep the eSign page visible — blob navigation must not leave a loader up.
      if (mounted && _initialPageLoaded && !_redirectHandled) {
        setState(() {
          _isLoading = false;
          _hasError = false;
        });
      }
    }
  }

  /// WebView signals a download (often `blob:https://...` from pdf.js).
  /// Without user tap we ignore it on Android (no auto-save on load).
  /// iOS: explicit blob downloads after page load are handled in-page.
  Future<void> _onDownloadStartRequest(
    InAppWebViewController controller,
    DownloadStartRequest downloadStartRequest,
  ) async {
    final url = downloadStartRequest.url;
    if (url == null) return;
    debugPrint('[WebView] onDownloadStartRequest: $url');
    if (!_isProceedToEsignFlowContext()) return;

    final urlStr = url.toString();
    // Blob save handled in shouldOverrideUrlLoading (navigation cancelled).
    if (_isBlobDownloadUrl(urlStr) && _esignPdfDownloadInProgress) {
      return;
    }
    final isIosBlobDownload = Platform.isIOS &&
        urlStr.toLowerCase().startsWith('blob:') &&
        _initialPageLoaded;

    if (!isIosBlobDownload && !await _hasEsignDownloadUserGesture(controller)) {
      debugPrint('[WebView] Ignoring download start (no user tap yet)');
      return;
    }

    await _handleEsignPdfDownload(
      controller,
      downloadUrl: url,
      suggestedFilename: downloadStartRequest.suggestedFilename,
      userAgent: downloadStartRequest.userAgent,
      mimeType: downloadStartRequest.mimeType,
      skipGestureCheck: isIosBlobDownload,
    );
  }

  /// Visible document text — used to detect transient JSON bridge pages before PDF/eSign is ready.
  Future<String> _readMainFrameBodyText(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: r'''(() => {
          try {
            var b = document.body;
            if (!b) return '';
            return (b.innerText || b.textContent || '').trim();
          } catch (e) { return ''; }
        })()''',
      );
      if (result == null) return '';
      if (result is String) return result.trim();
      return result.toString().trim();
    } catch (e) {
      debugPrint('[WebView] _readMainFrameBodyText error: $e');
      return '';
    }
  }

  /// Cloudesign / eSign sometimes returns a short JSON error (e.g. Invalid Token) or a
  /// Chromium-style "Pretty print" JSON view; auto-reload then loads the real document.
  /// Treat as transient: keep the loader overlay so users never see raw JSON.
  bool _isTransientEsignBridgePayload(String url, String bodyText) {
    if (!_isCloudesignDocumentUrl(url)) return false;
    final t = bodyText.trim().toLowerCase();
    if (t.isEmpty || t.length > 8000) return false;

    final pretty = t.contains('pretty print');
    final hasMsgKey = t.contains('"msg"');
    final statusFalse = t.contains('"status":false') ||
        t.contains('"status": false') ||
        t.contains('"success":false') ||
        t.contains('"success": false');
    final tokenOrPdf = t.contains('invalid token') ||
        t.contains('pdf is not generated') ||
        t.contains('journey status');

    if (statusFalse && hasMsgKey) return true;
    if (pretty && (statusFalse || tokenOrPdf)) return true;
    if (tokenOrPdf && hasMsgKey && t.length < 600) return true;
    return false;
  }

  static const Duration _defaultLoadTimeout = Duration(seconds: 25);
  static const Duration _esignLoadTimeout = Duration(seconds: 45);

  /// Starts hint timers and a timeout. Call on every `onLoadStart`; cancel on `onLoadStop`.
  void _startLoadTimers({String? url, bool resetMessageOnCancel = true}) {
    _cancelLoadTimers(resetLoadingMessage: resetMessageOnCancel);

    final sample = (url ?? _currentUrl).toLowerCase();
    final heavy = _isEsignPdfHeavyUrl(sample);
    final timeout = heavy ? _esignLoadTimeout : _defaultLoadTimeout;

    if (heavy) {
      _slowNetworkTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted || !_isLoading) return;
        setState(() => _loadingMessage = 'Loading document...');
      });
      _loadHintTimer2 = Timer(const Duration(seconds: 10), () {
        if (!mounted || !_isLoading) return;
        setState(() => _loadingMessage = 'Still loading, please wait...');
      });
    } else {
      _slowNetworkTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || !_isLoading) return;
        setState(() => _loadingMessage = 'Loading, please wait...');
      });
    }

    _loadTimeoutTimer = Timer(timeout, () {
      if (!mounted || !_isLoading || _hasError) return;
      debugPrint('[WebView] Load timeout (${timeout.inSeconds}s) — showing retry UI');
      setState(() {
        _isLoading = false;
        _hasError = true;
        _errorMessage =
            'This step is taking longer than usual. Check your network and tap Try Again.';
        _loadingMessage = 'Loading...';
      });
    });
  }

  /// Cancels load timers. Optionally keeps [ _loadingMessage ] (e.g. before "Rendering document...").
  void _cancelLoadTimers({bool resetLoadingMessage = true}) {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = null;
    _slowNetworkTimer?.cancel();
    _slowNetworkTimer = null;
    _loadHintTimer2?.cancel();
    _loadHintTimer2 = null;
    if (resetLoadingMessage &&
        mounted &&
        _loadingMessage != 'Loading...') {
      setState(() => _loadingMessage = 'Loading...');
    }
  }

  Future<void> _maybeReloadAfterRpdSigningCompleted({
    required InAppWebViewController controller,
    required String urlForCheck,
  }) async {
    if (_redirectHandled || _rpdSuccessHandled) return;
    if (_rpdSigningCompletedReloadTriggered) return;

    // Only check text on the reverse_pennydrop page.
    if (!_isReversePennyDropUrl(urlForCheck) && !_isReversePennyDropFlow) {
      return;
    }

    try {
      final result = await controller.evaluateJavascript(
        source:
            'try { var t = (document.body && document.body.innerText) ? document.body.innerText : ""; return t.indexOf("Signing completed successfully.") !== -1; } catch(e) { return false; }',
      );

      final isSignedComplete = (result is bool)
          ? result
          : result?.toString().toLowerCase() == 'true';

      if (!isSignedComplete) return;

      _rpdSigningCompletedReloadTriggered = true;
      debugPrint('[WebView] Detected RPD signing completed text - reloading to proceed');

      // Reload main webview so the URL/params can update and we can close+advance.
      await _webViewController?.reload();
    } catch (e) {
      debugPrint('[WebView] Error checking RPD signing-complete text: $e');
    }
  }

  /// Reverse Penny Drop: status-based reload when Digio prints
  /// "Signing completed successfully." to JS console.
  ///
  /// This avoids reloading while user is typing UPI details, because we only
  /// reload after the exact signing completion console message appears.
  Future<void> _injectRpdConsoleSigningReload(InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          if (window.__meonRpdConsoleHookInstalled) return;
          window.__meonRpdConsoleHookInstalled = true;

          function hook(methodName) {
            var original = console[methodName];
            if (!original) return;
            console[methodName] = function() {
              try {
                var msg = '';
                for (var i = 0; i < arguments.length; i++) {
                  msg += String(arguments[i]) + ' ';
                }
                if (msg.indexOf('Signing completed successfully.') !== -1) {
                  if (sessionStorage.getItem('meon_rpd_signing_reloaded') !== '1') {
                    sessionStorage.setItem('meon_rpd_signing_reloaded', '1');
                    setTimeout(function() {
                      try { location.reload(); } catch(e) {}
                    }, 800);
                  }
                }
              } catch (e) {}
              try { original.apply(console, arguments); } catch (e) {}
            };
          }

          hook('log');
          hook('info');
          hook('warn');
          hook('error');
        } catch (e) {}
      })();
    ''';

    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting RPD console signing reload JS: $e');
    }
  }

  /// Reverse Penny Drop: Digio's timer starts when the transaction is created
  /// server-side, so by the time the WebView (or Digio popup) renders the
  /// timer the displayed countdown is usually 4:40–4:55. We override the
  /// visible timer text with our own 5:00 countdown for a consistent user
  /// experience. Backend expiration is still owned by Digio — this is purely
  /// cosmetic.
  ///
  /// Key behaviours:
  /// • Countdown starts the moment a timer DOM node first becomes visible
  ///   (not when the script loads), so it always begins at 5:00.
  /// • If the timer DOM goes away and reappears (e.g. user submits UPI and
  ///   transitions to a "waiting for payment" screen with its own timer),
  ///   the countdown resets to 5:00 again.
  Future<void> _injectRpdTimerOverride(InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          if (window.__meonRpdTimerOverrideInstalled) return;
          window.__meonRpdTimerOverrideInstalled = true;

          var TOTAL_SECONDS = 5 * 60;
          var startedAt = null;     // null until a timer node is first seen
          var hadTimerLastTick = false;

          function fmt(s) {
            if (s < 0) s = 0;
            var m = Math.floor(s / 60);
            var sec = s % 60;
            return m + ':' + (sec < 10 ? '0' : '') + sec;
          }

          function looksLikeTimerNode(node) {
            try {
              if (!node || node.nodeType !== 1) return false;
              if (node.children && node.children.length > 0) return false;
              var t = (node.textContent || '').trim();
              if (!t || t.length > 6) return false;
              return /^\d{1,2}:\d{2}$/.test(t);
            } catch (e) { return false; }
          }

          function findTimerNodes() {
            var nodes = [];
            try {
              var explicit = document.querySelectorAll(
                '.timer, #timer, [class*="timer" i], [class*="countdown" i], ' +
                '[id*="timer" i], [id*="countdown" i]'
              );
              for (var i = 0; i < explicit.length; i++) {
                if (looksLikeTimerNode(explicit[i])) nodes.push(explicit[i]);
              }
              if (nodes.length > 0) return nodes;

              var all = document.body ? document.body.querySelectorAll('*') : [];
              for (var j = 0; j < all.length; j++) {
                if (looksLikeTimerNode(all[j])) nodes.push(all[j]);
              }
            } catch (e) {}
            return nodes;
          }

          function paint() {
            var nodes = findTimerNodes();
            var hasTimer = nodes.length > 0;

            // (Re)start countdown whenever timer DOM transitions from absent
            // to present. This covers initial render, popup load, AND the
            // "waiting for payment" screen which shows its own timer.
            if (hasTimer && !hadTimerLastTick) {
              startedAt = Date.now();
            }
            hadTimerLastTick = hasTimer;
            if (!hasTimer || startedAt == null) return;

            var elapsed = Math.floor((Date.now() - startedAt) / 1000);
            var remaining = TOTAL_SECONDS - elapsed;
            if (remaining < 0) return; // let Digio's own expired UI show through

            var text = fmt(remaining);
            for (var i = 0; i < nodes.length; i++) {
              try {
                if (nodes[i].textContent !== text) {
                  nodes[i].textContent = text;
                }
              } catch (e) {}
            }
          }

          // Initial paints (catch SPA renders).
          setTimeout(paint, 50);
          setTimeout(paint, 300);
          setTimeout(paint, 800);
          setTimeout(paint, 1500);
          setTimeout(paint, 3000);

          // Repaint frequently — overrides Digio's own updates quickly.
          setInterval(paint, 250);

          // React to dynamic DOM updates immediately.
          try {
            var mo = new MutationObserver(function() { paint(); });
            mo.observe(document.documentElement || document.body, {
              childList: true,
              subtree: true,
              characterData: true,
            });
          } catch (e) {}
        } catch (e) {}
      })();
    ''';

    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting RPD timer override JS: $e');
    }
  }

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
        _ipvPermissionGateActive = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Prevent duplicate scheduling between initState and onLoadStart.
          _permissionRequestScheduled = true;
          // Gate WebView rendering until permissions request completes.
          () async {
            await _requestPermissionsBeforeLoad();
            if (!mounted) return;
            setState(() {
              _ipvPermissionGateActive = false;
            });
          }();
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
    _loadTimeoutTimer?.cancel();
    _slowNetworkTimer?.cancel();
    _loadHintTimer2?.cancel();
    _cancelCloudesignRecovery();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When returning from a payment app, auto-reload the WebView
    if (state == AppLifecycleState.resumed) {
      if (_isReversePennyDropFlow && _upiAppLaunched) {
        _upiAppLaunched = false;
        // Auto-reload/polling disabled temporarily to avoid hard refresh loops
        // while user is still interacting with the RPD flow.
        // Completion handling is handled via query-param capture.
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
        host.contains('ipv.stoxbox.in') ||
        host.contains('ipv') ||
        path.contains('ipv') ||
        path.contains('face') ||
        path.contains('facefinder');
  }

  /// On iOS, disabling `scrollIntoView` breaks OTP and form flows; keep the hook only for
  /// IPV/Face Finder where a stable camera layout is preferred.
  bool _shouldInjectNoAutoScrollJs(String? url) {
    if (url == null || url.isEmpty) return true;
    if (!Platform.isIOS) return true;
    return _isIpvOrFaceFinderUrl(url);
  }

  bool _isReversePennyDropUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
        path.contains('/reverse_pennydrop/');
  }

  /// True for any Digio gateway page that hosts the UPI/RPD UI inside a popup
  /// (e.g. https://app.digio.in/#/gateway/login/...). This is where the visible
  /// 5-minute countdown timer is rendered.
  bool _isDigioGatewayUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (!host.contains('digio.in')) return false;
    final fragment = uri.fragment.toLowerCase();
    final path = uri.path.toLowerCase();
    return path.contains('/gateway/') || fragment.contains('/gateway/');
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

  /// IPV/FaceFinder flow camera/WebRTC ke liye popup/multiple windows off rakhna safe rahega.
  bool get _enablePopupWindows => _supportsPopupWindows && !_isIpvOrFaceFinderUrl(widget.url);

  void _startReversePennyPolling() {
    if (_reversePennyPollTimer != null) return;
    _reversePennyPollAttempts = 0;
    // Poll every 5 seconds to let the page re-evaluate payment status and redirect when ready
    _reversePennyPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isReversePennyDropFlow || _redirectHandled || !mounted) {
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
        return;
      }

      if (_reversePennyPollAttempts >= _maxReversePennyPollAttempts) {
        debugPrint('[WebView] Reverse Penny Drop polling: max attempts reached, stopping');
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
        return;
      }
      // Only reload while we're on the reverse_pennydrop page; once we leave it, stop polling.
      if (_isReversePennyDropUrl(_currentUrl)) {
        _reversePennyPollAttempts++;
        debugPrint('[WebView] Reverse Penny Drop polling reload: $_currentUrl');
        // Keep polling silent to avoid toast spam.
        await _reloadWebViewInternal(showToast: false);
      } else {
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
      }
    });
  }

  /// Request permissions BEFORE loading WebView (Android-specific)
  Future<void> _requestPermissionsBeforeLoad() async {
    if (_permissionsRequested) return;
    if (_permissionRequestScheduled) {
      // Allow the already-scheduled request to proceed.
    }
    _permissionsRequested = true;
    _permissionHandlerInFlight = true;

    debugPrint('[WebView] Requesting permissions BEFORE load (Android) for IPV/Face Finder');

    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];

    // Important: don't fire multiple permission requests in parallel.
    // permission_handler will throw if a request is already running.
    Map<Permission, PermissionStatus> results;
    try {
      results = await permissions.request();
    } catch (e) {
      debugPrint('[WebView] Permission request failed: $e');
      _permissionsRequested = false;
      return;
    } finally {
      _permissionRequestScheduled = false;
      _permissionHandlerInFlight = false;
    }

    bool allGranted = permissions.every((p) {
      final status = results[p];
      return status == PermissionStatus.granted ||
          status == PermissionStatus.limited;
    });

    if (allGranted) {
      debugPrint('[WebView] All permissions granted before load - WebView will load with camera access');
      // On Android, reload WebView after permissions granted to ensure camera/mic initialize properly
      if (_webViewController != null && !_hasReloadedAfterPermissions) {
        _hasReloadedAfterPermissions = true;
        Future.delayed(const Duration(milliseconds: 300), () {
          debugPrint('[WebView] Reloading WebView after Android permissions granted');
          _webViewController?.reload();
        });
      } else if (!_hasReloadedAfterPermissions) {
        // Controller not ready yet; reload as soon as it's created.
        _pendingReloadAfterPermissions = true;
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
    _permissionHandlerInFlight = true;

    debugPrint('[WebView] Requesting permissions for IPV/Face Finder');

    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];

    // Important: don't fire multiple permission requests in parallel.
    // permission_handler will throw if a request is already running.
    Map<Permission, PermissionStatus> results;
    try {
      results = await permissions.request();
    } catch (e) {
      debugPrint('[WebView] Permission request failed: $e');
      _permissionsRequested = false;
      return;
    } finally {
      _permissionRequestScheduled = false;
      _permissionHandlerInFlight = false;
    }

    bool allGranted = permissions.every((p) {
      final status = results[p];
      return status == PermissionStatus.granted ||
          status == PermissionStatus.limited;
    });

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
    return _reloadWebViewInternal(showToast: true);
  }

  /// Same reload as the AppBar refresh — used by the error overlay Try Again button.
  Future<void> _retryFromErrorOverlay() async {
    final controller = _webViewController;
    if (controller == null) {
      debugPrint('[WebView] Try Again: no WebView controller');
      return;
    }
    _resetDocumentRetryState();
    _cancelLoadTimers();
    if (!mounted) return;
    setState(() {
      _hasError = false;
      _isLoading = true;
      _loadingMessage = 'Loading...';
    });
    _startLoadTimers(url: _currentUrl);
    try {
      final target = _currentUrl.trim();
      if (target.isNotEmpty) {
        debugPrint('[WebView] Try Again: loadUrl $target');
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
      } else {
        await _reloadWebViewInternal(showToast: false);
      }
    } catch (e) {
      debugPrint('[WebView] Try Again loadUrl failed: $e — falling back to reload');
      await _reloadWebViewInternal(showToast: false);
    }
  }

  Future<void> _reloadWebViewInternal({required bool showToast}) async {
    try {
      debugPrint('[WebView] Reloading WebView: $_currentUrl');
      await _webViewController?.reload();
      if (showToast) {
        Fluttertoast.showToast(
          msg: 'Page reloaded',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.TOP,
        );
      }
    } catch (e) {
      debugPrint('[WebView] Error reloading: $e');
    }
  }

  void _scheduleCloudesignRecovery(InAppWebViewController controller, String urlStr) {
    if (!_usesInAppDocumentAutoRetry(urlStr)) return;
    _cancelCloudesignRecovery();
    _cloudesignRecoveryTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted || _redirectHandled) {
        t.cancel();
        return;
      }
      if (_currentUrl != urlStr || !_usesInAppDocumentAutoRetry(_currentUrl)) {
        t.cancel();
        return;
      }

      if (_cloudesignAutoReloadAttempts < _maxCloudesignAutoReloadAttempts) {
        _cloudesignAutoReloadAttempts++;
        final attempt = _cloudesignAutoReloadAttempts;
        debugPrint(
            '[WebView] In-app document reload (attempt $attempt/$_maxCloudesignAutoReloadAttempts)');
        if (mounted) {
          setState(() {
            _isLoading = true;
            _hasError = false;
            _loadingMessage =
                'Loading document… (retry $attempt/$_maxCloudesignAutoReloadAttempts)';
          });
        }
        try {
          await controller.evaluateJavascript(
            source: 'try { window.location.reload(true); } catch(e) {}',
          );
        } catch (_) {}
        await _reloadWebViewInternal(showToast: false);
        return;
      }

      t.cancel();
      _showInAppDocumentRetryAfterFailedRecovery();
    });
  }

  /// Captures query params from completion/success URLs (e.g. RPD: ?success=yes&transaction_id=..., eSign: ?esign=yes)
  /// so they can be passed to get-context API. Works for any segment with different params.
  void _captureCompletionParamsIfApplicable(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters.isEmpty) return;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isWorkflowPath = path.contains('/${widget.company}/${widget.workflowName}');
    final isOurDomain = (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
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
      final originalUrl = url;
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
          // For Android intent:// links, `finalUrl` may not start with `upi://`
          // (example: `intent://pay?...#Intent;scheme=upi;...;end`).
          // So mark using the original intent URL to reliably detect scheme=upi.
          _markPaymentAppLaunched(isIntentUrl ? originalUrl : finalUrl);
          debugPrint('[WebView] Successfully launched payment URL');
          return true;
        } catch (e) {
          debugPrint('[WebView] Error launching payment URL directly: $e');
          // Fallback: try with canLaunchUrl check
          try {
            final uri = Uri.parse(finalUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              _markPaymentAppLaunched(isIntentUrl ? originalUrl : finalUrl);
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
    // UPI/payment deep-links can arrive as:
    // - upi://... / phonepe://... / gpay://...
    // - or Android intent://...#Intent;scheme=upi;package=...;end
    final containsUpiScheme = lower.contains('scheme=upi') || lower.startsWith('upi://');
    final containsPhonepeScheme = lower.contains('scheme=phonepe') || lower.startsWith('phonepe://');
    final containsPaytmScheme = lower.contains('scheme=paytm') || lower.startsWith('paytm://');
    final containsPaytmMpScheme = lower.contains('scheme=paytmmp') || lower.startsWith('paytmmp://');
    final containsGpayScheme = lower.contains('scheme=gpay') || lower.startsWith('gpay://') || lower.contains('scheme=tez');
    final containsAnyPaymentScheme = lower.startsWith('upi://') ||
        lower.startsWith('phonepe://') ||
        lower.startsWith('paytmmp://') ||
        lower.startsWith('paytm://') ||
        lower.startsWith('gpay://') ||
        lower.startsWith('tez://') ||
        lower.startsWith('bhim://') ||
        lower.startsWith('googlepay://') ||
        containsUpiScheme ||
        containsPhonepeScheme ||
        containsPaytmScheme ||
        containsPaytmMpScheme ||
        containsGpayScheme ||
        lower.contains('scheme=upi');

    if (!containsAnyPaymentScheme) return;

    if (_isReversePennyDropFlow) {
      _upiAppLaunched = true;
      debugPrint('[WebView] Marked payment app launched (RPD): $url');
    } else {
      // For iOS: mark any payment app launch so we can reload on return
      if (Platform.isIOS) {
        _paymentAppLaunched = true;
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
            // Navigate back to home page (without query params since API already called).
            // Set flag BEFORE navigation so the new HomePage's first build shows a loader,
            // not the old step UI.
            context.read<AppStore>().setReturningFromWebView(true);
            context.go('/${widget.company}/${widget.workflowName}');
          }
        } else {
          debugPrint('[WebView] No auth token - navigating with params');
          final query = queryParams.isEmpty
              ? ''
              : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
          if (mounted) {
            context.read<AppStore>().setReturningFromWebView(true);
            context.go('/${widget.company}/${widget.workflowName}$query');
          }
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
          context.read<AppStore>().setReturningFromWebView(true);
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
      if (mounted) {
        context.read<AppStore>().setReturningFromWebView(true);
        context.go('/${widget.company}/${widget.workflowName}$query');
      }
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
    // iOS: shrink the scaffold when the keyboard opens so WKWebView can reflow (CAMS AA OTP,
    // Digio UPI popup, etc.). Android unchanged. scrollIntoView stays enabled except on IPV/Face.
    return ScaffoldMessenger(
      key: _scaffoldMessengerKey,
      child: Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: Platform.isIOS,
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
            _ipvPermissionGateActive
                ? const Center(child: CircularProgressIndicator())
                : InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      // eSign pdf.js uses blob: URLs — listen here, save in-page (see _onDownloadStartRequest).
                      useOnDownloadStart: true,
                      // Allow JS popups / window.open only for special flows (Reverse Penny Drop, Digio eSign, etc.)
                      javaScriptCanOpenWindowsAutomatically: _enablePopupWindows,
                      supportMultipleWindows: _enablePopupWindows,
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
                    onDownloadStartRequest: _onDownloadStartRequest,
                    onWebViewCreated: (controller) {
                      _webViewController = controller;

                      if (_pendingReloadAfterPermissions &&
                          !_hasReloadedAfterPermissions) {
                        _pendingReloadAfterPermissions = false;
                        _hasReloadedAfterPermissions = true;
                        Future.delayed(const Duration(milliseconds: 300), () {
                          debugPrint(
                              '[WebView] Pending reload after permissions - reloading WebView');
                          _webViewController?.reload();
                        });
                      }
                    },
                    // Handle popup windows (window.open) – important for Reverse Penny Drop / Digio eSign bank flows
                    onCreateWindow: (controller, createWindowAction) async {
                      final popupUri = createWindowAction.request.url;
                      final popupUrl = popupUri?.toString() ?? '';
                      debugPrint('[WebView] onCreateWindow: $popupUrl');

                      if (!_enablePopupWindows) {
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

                      // pdf.js blob: save PDF in-page — do NOT navigate (avoids reload/loader).
                      if (_isProceedToEsignFlowContext() &&
                          _isBlobDownloadUrl(url)) {
                        final shouldPerformDownload =
                            navigationAction.shouldPerformDownload ?? false;
                        final hasGesture =
                            await _hasEsignDownloadUserGesture(controller);
                        if (hasGesture ||
                            (Platform.isIOS &&
                                shouldPerformDownload &&
                                _initialPageLoaded)) {
                          if (!hasGesture) {
                            try {
                              await controller.evaluateJavascript(
                                source:
                                    'window.__meonUserGestureForDownload = true;',
                              );
                            } catch (_) {}
                          }
                          debugPrint(
                              '[WebView] Blob PDF download — in-page save, no navigation');
                          _handleEsignPdfDownload(
                            controller,
                            downloadUrl: uri,
                            skipGestureCheck: true,
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }

                      // Block direct PDF navigations on eSign until user taps download.
                      if (_isProceedToEsignFlowContext() &&
                          _looksLikePdfFileNavigation(url) &&
                          !await _hasEsignDownloadUserGesture(controller)) {
                        debugPrint(
                            '[WebView] Blocked auto PDF navigation: $url');
                        return NavigationActionPolicy.CANCEL;
                      }

                      // Always cancel intent: URLs on Android to prevent ERR_UNKNOWN_URL_SCHEME error
                      if (Platform.isAndroid &&
                          url.toLowerCase().startsWith('intent:')) {
                        debugPrint(
                            '[WebView] Intent URL detected - handling externally');
                        await _handleExternalUrl(url);
                        return NavigationActionPolicy.CANCEL;
                      }

                      if (_shouldHandleExternally(url)) {
                        final handled = await _handleExternalUrl(url);
                        if (handled) {
                          debugPrint(
                              '[WebView] External URL handled by app, cancelling WebView navigation');
                          return NavigationActionPolicy.CANCEL;
                        }
                      }

                      // Capture completion params from success/return URLs (e.g. ?success=yes&transaction_id=...)
                      // Works for RPD, DigiLocker, and other segments - any URL with params before final workflow URL
                      _captureCompletionParamsIfApplicable(url);

                      // Reverse Penny Drop: if completion params appear in URL, close WebView immediately (no timer needed)
                      if (_isReversePennyDropUrl(url) &&
                          !_redirectHandled &&
                          !_rpdSuccessHandled) {
                        final uri = Uri.tryParse(url);
                        if (uri != null && uri.queryParameters.isNotEmpty) {
                          final completionParamKeys = [
                            'success',
                            'transaction_id',
                            'reversepennydrop',
                            'esign',
                          ];
                          final hasCompletionParams = uri
                              .queryParameters.keys
                              .any((key) =>
                                  completionParamKeys.contains(key.toLowerCase()));
                          if (hasCompletionParams) {
                            debugPrint(
                                '[WebView] RPD completion params detected in URL - closing WebView');
                            _rpdSuccessHandled = true;
                            _completionParams.addAll(uri.queryParameters);
                            if (!_completionParams.containsKey('success')) {
                              _completionParams['success'] = 'yes';
                            }
                            await _handleRedirectComplete(
                              state: uri.queryParameters['state'] ??
                                  _preservedState,
                              clientToken: uri.queryParameters['client_token'] ??
                                  _preservedClientToken,
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
                        if (_isDigioEsignFlow &&
                            _webViewController != null &&
                            !_redirectHandled &&
                            !_rpdSuccessHandled) {
                          Future.delayed(const Duration(milliseconds: 500),
                              () async {
                            if (!mounted ||
                                _redirectHandled ||
                                _rpdSuccessHandled) return;
                            debugPrint(
                                '[WebView] Popup closed - reloading main page to fetch success state with params');
                            await _webViewController?.reload();
                          });
                        }
                      }
                    },
                    onLoadStart: (controller, url) async {
                      if (url != null && !_redirectHandled) {
                        final urlStr = url.toString();
                        // Blob URLs are PDF downloads — never treat as a page load.
                        if (_isBlobDownloadUrl(urlStr)) {
                          debugPrint(
                              '[WebView] Ignoring blob onLoadStart (PDF download only)');
                          return;
                        }
                        setState(() {
                          _isLoading = true;
                          _hasError = false;
                          _currentUrl = urlStr;
                        });
                        _startLoadTimers(url: urlStr);
                        debugPrint('[WebView] Page started: $url');

                        if (_isProceedToEsignFlowContext(urlStr)) {
                          await _resetEsignDownloadUserGesture(controller);
                        }
                        if (_usesInAppDocumentAutoRetry(urlStr)) {
                          _resetDocumentRetryState();
                        }

                        // IPV/Face Finder success: redirect to live.meon.co.in/.../individual?state=...&success=yes
                        // Close WebView immediately on success redirect (don't wait for page load)
                        final uri = Uri.tryParse(url.toString());
                        if (uri != null) {
                          final host = uri.host.toLowerCase();
                          final path = uri.path.toLowerCase();
                          final hasSuccess =
                              uri.queryParameters['success']?.toLowerCase() ==
                                  'yes';
                          final hasState = uri.queryParameters.containsKey('state');
                          final isWorkflowPath = path.contains(
                              '/${widget.company}/${widget.workflowName}');
                          final isMeonRedirect = (host.contains('meon.co.in') ||
                                  host.contains('stoxbox.in')) &&
                              !host.contains('ipv.') &&
                              !host.contains('api.') &&
                              !host.contains('digilocker.');

                          if (isMeonRedirect &&
                              isWorkflowPath &&
                              (hasSuccess || hasState)) {
                            debugPrint(
                                '[WebView] IPV success redirect detected - closing WebView immediately');
                            await _handleRedirectComplete(
                              state: uri.queryParameters['state'] ?? _preservedState,
                              clientToken: uri.queryParameters['client_token'] ??
                                  _preservedClientToken,
                              auto: uri.queryParameters['auto'] ?? _preservedAuto,
                              verifyCompleted: hasSuccess,
                            );
                            return;
                          }
                        }

                        // Request permissions on load (iOS or if Android permissions weren't requested before)
                        if (_isIpvOrFaceFinderUrl(url.toString()) &&
                            !_permissionsRequested &&
                            !_permissionRequestScheduled) {
                          if (Platform.isAndroid) {
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              _requestPermissionsBeforeLoad();
                            });
                          } else {
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              _requestPermissionsAndReload();
                            });
                          }
                        }
                      }
                    },
                    onLoadError: (controller, url, code, message) {
                      debugPrint(
                          '[WebView] Load error ($code): $message, url=$url');
                      final errorUrl = url?.toString() ?? '';
                      if (_shouldIgnoreWebViewLoadError(
                        errorUrl,
                        code: code,
                        description: message,
                      )) {
                        debugPrint(
                            '[WebView] Ignoring benign load error: $errorUrl');
                        return;
                      }
                      // Ignore unknown URL scheme errors — these are UPI/intent
                      // deep-links handled externally and are not real page failures.
                      if (code == -10 &&
                          message.contains('net::ERR_UNKNOWN_URL_SCHEME')) {
                        return;
                      }
                      // Only surface errors for the current main-frame URL to
                      // avoid triggering retry UI for sub-resource failures.
                      if (errorUrl.isNotEmpty &&
                          errorUrl != _currentUrl &&
                          !errorUrl.startsWith('http')) {
                        return;
                      }
                      _cancelLoadTimers();
                      if (!mounted) return;
                      setState(() {
                        _isLoading = false;
                        _hasError = true;
                        _errorMessage =
                            'Failed to load page. Please check your connection and try again.';
                      });
                    },
                    onReceivedError: (controller, request, error) {
                      // flutter_inappwebview v6 main-frame error handler.
                      if (request.isForMainFrame != true) return;
                      // Ignore custom-scheme deep-links handled externally.
                      final errUrl = request.url.toString();
                      if (errUrl.startsWith('upi://') ||
                          errUrl.startsWith('intent://') ||
                          errUrl.startsWith('phonepe://') ||
                          errUrl.startsWith('paytm') ||
                          errUrl.startsWith('gpay://') ||
                          errUrl.startsWith('tez://') ||
                          errUrl.startsWith('bhim://')) {
                        return;
                      }
                      debugPrint(
                          '[WebView] onReceivedError: ${error.description}, url=$errUrl');
                      if (_shouldIgnoreWebViewLoadError(
                        errUrl,
                        code: error.type.toNativeValue(),
                        description: error.description,
                      )) {
                        debugPrint(
                            '[WebView] Ignoring benign received error: $errUrl');
                        return;
                      }
                      _cancelLoadTimers();
                      if (!mounted) return;
                      setState(() {
                        _isLoading = false;
                        _hasError = true;
                        _errorMessage =
                            'Failed to load page. Please check your connection and try again.';
                      });
                    },
                    onLoadStop: (controller, url) async {
                      if (url != null) {
                        final urlStr = url.toString();
                        // Stop timeout/hint timers but keep overlay up briefly on eSign/PDF
                        // so pdf.js / canvas can paint (avoids blank flash).
                        _cancelLoadTimers(resetLoadingMessage: false);
                        final heavyDoc = _isEsignPdfHeavyUrl(urlStr);

                        // Hide transient JSON on cloudesign document URLs only (not eSign SPA).
                        if (_isCloudesignDocumentUrl(urlStr)) {
                          final bodyText = await _readMainFrameBodyText(controller);
                          if (_isTransientEsignBridgePayload(urlStr, bodyText)) {
                            debugPrint(
                                '[WebView] Transient eSign/JSON payload detected — keeping loader until retry succeeds');
                            if (!mounted) return;
                            setState(() {
                              _isLoading = true;
                              _hasError = false;
                              _loadingMessage = 'Preparing eSign document...';
                              _currentUrl = urlStr;
                            });
                            _startLoadTimers(url: urlStr, resetMessageOnCancel: false);
                            if (_usesInAppDocumentAutoRetry(urlStr) &&
                                !_redirectHandled) {
                              _scheduleCloudesignRecovery(controller, urlStr);
                            }
                            await _onPageFinished(urlStr);
                            if (_shouldInjectNoAutoScrollJs(urlStr)) {
                              await _injectNoAutoScrollJs(controller);
                            }
                            return;
                          }
                        }

                        if (heavyDoc && mounted) {
                          setState(() => _loadingMessage = 'Rendering document...');
                          await Future.delayed(const Duration(milliseconds: 1400));
                        }
                        if (!mounted) return;
                        setState(() {
                          _isLoading = false;
                          _hasError = false;
                          _initialPageLoaded = true;
                          _currentUrl = urlStr;
                          _loadingMessage = 'Loading...';
                        });
                        debugPrint('[WebView] Page finished: $url');

                        // Successful load — cancel any pending document retry timer.
                        _cancelCloudesignRecovery();
                        _resetDocumentRetryState();

                        if (_isProceedToEsignFlowContext(urlStr)) {
                          await _injectEsignDownloadUserGestureTracker(controller);
                        }

                        // Blank cloudesign PDF only — never retry eSign SPA after load.
                        if (_usesInAppDocumentAutoRetry(urlStr) && !_redirectHandled) {
                          final bodyAfterLoad =
                              await _readMainFrameBodyText(controller);
                          final likelyBlank = bodyAfterLoad.trim().length < 80 &&
                              !_isTransientEsignBridgePayload(
                                  urlStr, bodyAfterLoad);
                          if (likelyBlank) {
                            _scheduleCloudesignRecovery(controller, urlStr);
                          } else {
                            _resetDocumentRetryState();
                          }
                        }

                        // For eSign pages, nudge initial scroll slightly so
                        // important inputs are not hidden under the keyboard.
                        try {
                          final uri = Uri.tryParse(urlStr);
                          if (uri != null) {
                            final host = uri.host.toLowerCase();
                            final isCloudesign = host.contains('cloudesign');
                            final isNsdlEsign = host.contains('esign.egov.proteantech.in') ||
                                host.startsWith('esign.');
                            if (!_esignScrollAdjusted &&
                                (isCloudesign || isNsdlEsign)) {
                              _esignScrollAdjusted = true;
                              await controller.scrollTo(x: 0, y: 260);
                              await controller.evaluateJavascript(
                                source: 'try { window.scrollTo(0, 260); } catch(e) {}',
                              );
                            }
                          }
                        } catch (e) {
                          debugPrint(
                              '[WebView] Error adjusting scroll for eSign: $e');
                        }

                        if (_isIpvOrFaceFinderUrl(urlStr) &&
                            _permissionsRequested &&
                            !_hasReloadedAfterPermissions) {
                          Future.delayed(const Duration(milliseconds: 300),
                              () {
                            if (mounted &&
                                _currentUrl == urlStr &&
                                !_hasReloadedAfterPermissions) {
                              _hasReloadedAfterPermissions = true;
                              debugPrint(
                                  '[WebView] Reloading IPV page after permission grant');
                              controller.reload();
                            }
                          });
                        }

                        await _onPageFinished(urlStr);
                        if (_shouldInjectNoAutoScrollJs(urlStr)) {
                          await _injectNoAutoScrollJs(controller);
                        }
                        if (_isReversePennyDropUrl(urlStr)) {
                          if (!_rpdSigningSessionFlagReset) {
                            try {
                              await controller.evaluateJavascript(
                                source:
                                    'try { sessionStorage.removeItem("meon_rpd_signing_reloaded"); } catch(e) {}',
                              );
                            } catch (_) {}
                            _rpdSigningSessionFlagReset = true;
                          }
                          await _injectRpdConsoleSigningReload(controller);
                          await _injectRpdTimerOverride(controller);
                        }

                        // Reverse Penny Drop: check if completion params appeared in URL (params = completion indicator)
                        if (_isReversePennyDropUrl(urlStr) &&
                            !_redirectHandled &&
                            !_rpdSuccessHandled) {
                          final uri = Uri.tryParse(urlStr);
                          if (uri != null && uri.queryParameters.isNotEmpty) {
                            final completionParamKeys = [
                              'success',
                              'transaction_id',
                              'reversepennydrop',
                              'esign',
                            ];
                            final hasCompletionParams = uri
                                .queryParameters.keys
                                .any((key) =>
                                    completionParamKeys
                                        .contains(key.toLowerCase()));
                            if (hasCompletionParams) {
                              debugPrint(
                                  '[WebView] RPD completion params detected in URL onLoadStop - closing WebView');
                              _rpdSuccessHandled = true;
                              _completionParams.addAll(uri.queryParameters);
                              if (!_completionParams.containsKey('success')) {
                                _completionParams['success'] = 'yes';
                              }
                              await _handleRedirectComplete(
                                state: uri.queryParameters['state'] ?? _preservedState,
                                clientToken: uri.queryParameters['client_token'] ??
                                    _preservedClientToken,
                                auto: uri.queryParameters['auto'] ?? _preservedAuto,
                                verifyCompleted: false,
                              );
                            }
                          }
                        }
                      }
                    },
                    onPermissionRequest: (controller, request) async {
                      debugPrint(
                          '[WebView] Permission requested (camera/mic): ${request.resources}');
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.GRANT,
                      );
                    },
                    onGeolocationPermissionsShowPrompt:
                        (controller, origin) async {
                      debugPrint(
                          '[WebView] Geolocation permission requested for: $origin');
                      if (_permissionsRequested ||
                          _permissionRequestScheduled ||
                          _permissionHandlerInFlight) {
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: true,
                          retain: true,
                        );
                      }

                      final locationStatus = await Permission.location.status;
                      if (locationStatus.isGranted ||
                          locationStatus.isLimited) {
                        debugPrint(
                            '[WebView] Location permission already granted - allowing geolocation');
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: true,
                          retain: true,
                        );
                      }

                      debugPrint(
                          '[WebView] Location permission not granted - requesting...');
                      if (_permissionHandlerInFlight) {
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: true,
                          retain: true,
                        );
                      }

                      _permissionHandlerInFlight = true;
                      try {
                        final result = await Permission.location.request();
                        final granted = result.isGranted || result.isLimited;
                        debugPrint(
                          granted
                              ? '[WebView] Location permission granted - allowing geolocation'
                              : '[WebView] Location permission denied - denying geolocation',
                        );
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: granted,
                          retain: granted,
                        );
                      } catch (e) {
                        debugPrint(
                            '[WebView] Location permission request failed: $e');
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: false,
                          retain: false,
                        );
                      } finally {
                        _permissionHandlerInFlight = false;
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

                          // Digio can navigate/complete by updating query params within the popup.
                          // Capture those completion params and immediately trigger the same backend
                          // completion flow as we do on the main WebView.
                          _captureCompletionParamsIfApplicable(url);
                          final popupUri = Uri.tryParse(url);
                          if (popupUri != null &&
                              popupUri.queryParameters.isNotEmpty &&
                              !_redirectHandled &&
                              !_rpdSuccessHandled) {
                            const completionParamKeys = [
                              'success',
                              'transaction_id',
                              'reversepennydrop',
                              'reverse_pennydrop',
                              'esign',
                            ];
                            final hasCompletionParams = popupUri
                                .queryParameters.keys
                                .any((key) => completionParamKeys.contains(key.toLowerCase()));
                            if (hasCompletionParams) {
                              if (popupUri.queryParameters.containsKey('reversepennydrop') ||
                                  popupUri.queryParameters.containsKey('reverse_pennydrop')) {
                                _rpdSuccessHandled = true;
                              }

                              await _handleRedirectComplete(
                                state: popupUri.queryParameters['state'] ?? _preservedState,
                                clientToken: popupUri.queryParameters['client_token'] ?? _preservedClientToken,
                                auto: popupUri.queryParameters['auto'] ?? _preservedAuto,
                                verifyCompleted: false,
                              );
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
                            final urlStr = url.toString();
                            if (_shouldInjectNoAutoScrollJs(urlStr)) {
                              await _injectNoAutoScrollJs(controller);
                            }

                            if (_isReversePennyDropUrl(urlStr)) {
                              if (!_rpdSigningSessionFlagReset) {
                                try {
                                  await controller.evaluateJavascript(
                                    source:
                                        'try { sessionStorage.removeItem("meon_rpd_signing_reloaded"); } catch(e) {}',
                                  );
                                } catch (_) {}
                                _rpdSigningSessionFlagReset = true;
                              }
                              await _injectRpdConsoleSigningReload(controller);
                              await _injectRpdTimerOverride(controller);
                            }

                            // Digio gateway popup (app.digio.in/#/gateway/...)
                            // hosts the visible 5-min countdown when the user
                            // is entering UPI ID / picking an app, so we need
                            // to inject the override here too.
                            if (_isDigioGatewayUrl(urlStr)) {
                              await _injectRpdTimerOverride(controller);
                            }
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),

            // Full-screen loader overlay — covers WebView until page is ready.
            // AnimatedOpacity fades it out smoothly on first load completion.
            if (_isLoading)
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _isLoading ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            if (_isLoading)
              Positioned.fill(
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
                      const SizedBox(height: 20),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _loadingMessage,
                          key: ValueKey(_loadingMessage),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Error overlay — shown on network failure, resource error, or timeout.
            // Sits above the WebView so no partial content is ever visible.
            // Does NOT navigate back to HomePage; user can retry from here.
            if (_hasError)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.white,
                  child: SafeArea(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.wifi_off_rounded,
                              size: 72,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 20),
                            Text(
                              _errorMessage,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey.shade700,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 28),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text(
                                'Try Again',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: KycTheme.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 32, vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                elevation: 0,
                              ),
                              onPressed:
                                  _isLoading ? null : _retryFromErrorOverlay,
                            ),
                          ],
                        ),
                      ),
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
}
