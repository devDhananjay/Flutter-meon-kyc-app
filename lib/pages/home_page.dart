import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/api/kyc_api.dart';
import 'package:meon_kyc/components/form_field_widget.dart';
import 'package:meon_kyc/components/kyc_layout.dart';
import 'package:meon_kyc/components/kyc_note_box.dart';
import 'package:meon_kyc/components/loader.dart';
import 'package:meon_kyc/components/otp_verify_section.dart';
import 'package:meon_kyc/components/segments_selection.dart';
import 'package:meon_kyc/components/brokerage_plan_dialog.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/hooks/conditional_form.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

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
  bool _logoutLoading = false;
  bool _backLoading = false;
  String _submitError = '';
  String _submitSuccess = '';

  @override
  void initState() {
    super.initState();
    _formNotifier = ConditionalFormNotifier(fields: [], conditionalFlow: []);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWorkflow());
  }

  Future<void> _loadWorkflow() async {
    debugPrint('[HomePage] _loadWorkflow START: ${widget.company} / ${widget.workflowName}');
    debugPrint('[HomePage] _loadWorkflow queryParams: ${widget.queryParams}');
    final store = context.read<AppStore>();
    store.setParams(company: widget.company, workflowName: widget.workflowName);
    final hasToken = await StorageService.hasAccessToken();
    debugPrint('[HomePage] _loadWorkflow hasToken=$hasToken');
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
      
      // Check if KYC is completed (is_admin: true)
      final response = store.fieldsWithAuth;
      if (response is Map && response['is_admin'] == true) {
        debugPrint('[HomePage] KYC completed (is_admin: true) - fetching user details');
        await store.fetchUserDetails();
        if (mounted && store.userDetails != null) {
          // Navigate to KYC Completed page
          context.go('/${widget.company}/${widget.workflowName}/completed');
          return;
        } else if (mounted && store.errorUserDetails != null) {
          debugPrint('[HomePage] Error fetching user details: ${store.errorUserDetails}');
          Fluttertoast.showToast(msg: 'Error loading completion details');
        }
      }
      
      // Check for redirect after get-context
      // Skip redirect if step completion params present (IPV, RPD, eSign, DigiLocker, etc.)
      // Prevents infinite loop when backend returns redirect despite completed step
      final hasCompletionParams = widget.queryParams['success'] == 'yes' ||
          widget.queryParams['verifyCompleted'] == 'true' ||
          widget.queryParams['esign'] == 'yes' ||
          widget.queryParams.containsKey('transaction_id');
      if (mounted && !hasCompletionParams) {
        await _checkAndHandleRedirect(store);
      } else if (hasCompletionParams) {
        debugPrint('[HomePage] Step completed (success/transaction_id/esign) - skipping redirect to prevent loop');
      }
    } else {
      await store.fetchWorkflowFields(widget.company, widget.workflowName);
    }
    debugPrint('[HomePage] _loadWorkflow DONE, store.error=${store.error}');
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
              Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Error');
            } else {
              debugPrint('[HomePage] Verify get-context completed successfully - data loaded in app');
            }
            
            return; // Don't open WebView
          }
        }
        
        // For all OTHER redirects - open WebView (like DigiLocker)
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
        
        debugPrint('[HomePage] Opening WebView for redirect (msg: $msg): $finalUrl');
        final encodedUrl = Uri.encodeComponent(finalUrl);
        final title = Uri.encodeComponent(msg.isNotEmpty ? msg : 'External Verification');
        context.go('/${widget.company}/${widget.workflowName}/webview?url=$encodedUrl&title=$title');
      }
    }
  }

  int _getStepperIndex(AppStore store, bool isAuth) {
    if (!isAuth) return 0;
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    if (ctx is Map) {
      // Try 'index' first (from get-context response), then 'step'
      final indexStr = ctx['index']?.toString() ?? ctx['step']?.toString();
      if (indexStr != null) {
        final idx = int.tryParse(indexStr);
        if (idx != null && idx >= 0) return idx.clamp(0, 4);
      }
    }
    return 0;
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
    if (skipValidation) data['save'] = true;
    
    // Add brokerage_plan for segments screen
    final store = context.read<AppStore>();
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    final position = ctx?['position']?.toString()?.toLowerCase();
    if (position == 'segments') {
      data['brokerage_plan'] = 'Brokerage Plan';
    }
    final fields = _getActiveFields(context.read<AppStore>());
    if (fields == null) return data;
    final fieldList = fields['fields'] as List?;
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
              gravity: ToastGravity.BOTTOM,
              backgroundColor: Colors.red.shade700,
              textColor: Colors.white,
            );
          } else {
            Fluttertoast.showToast(
              msg: 'Please fill all required fields correctly',
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.BOTTOM,
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
      final store = context.read<AppStore>();
      final data = await _prepareFormData(skipValidation);
      debugPrint('[HomePage] Form data (Send OTP): $data');
      final activeFields = _getActiveFields(store);
      final fieldList = (activeFields?['fields'] as List?) ?? [];
      final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file');
      final endpoint = '/api/get-user/${widget.company}/${widget.workflowName}';
      final fullUrl = '${EnvConfig.baseUrl}$endpoint';
      debugPrint('[HomePage] _handleSubmit hasFile=$hasFile');
      debugPrint('[HomePage] _handleSubmit FULL URL: $fullUrl');
      debugPrint('[HomePage] _handleSubmit ENDPOINT: $endpoint');

      if (hasFile) {
        final req = http.MultipartRequest(
          'POST',
          Uri.parse(fullUrl),
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
        final client = ApiClient();
        final res = await client.postMultipart(req);
        await _handleSubmitResponse(res, store);
      } else {
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
      Fluttertoast.showToast(msg: e.toString());
    } finally {
      if (mounted) setState(() => _submitLoading = false);
      debugPrint('[HomePage] Send OTP / Submit DONE');
    }
  }

  Future<void> _handleSubmitResponse(http.Response res, AppStore store) async {
    debugPrint('[HomePage] _handleSubmitResponse status=${res.statusCode} body=${res.body.length > 300 ? res.body.substring(0, 300) + "..." : res.body}');
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>?;
      if (res.statusCode >= 200 && res.statusCode < 300 && body?['success'] == true) {
        final token = body?['access_token'] as String?;
        final refresh = body?['refresh_token'] as String?;
        if (token != null) StorageService.setAccessToken(token);
        if (refresh != null) StorageService.setRefreshToken(refresh);
        StorageService.setAuthSuccess('true');
        StorageService.setMessage(body?['msg']?.toString() ?? '');
        StorageService.setUserStep(body?['position']?.toString() ?? '');
        _formNotifier.resetForm();
        // Keep loading indicator visible during get-context call for smooth transition
        await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
        if (mounted && store.errorWithAuth != null) {
          await _clearCookiesAndRefresh();
          Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Session updated. Please continue.');
          return;
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
        Fluttertoast.showToast(msg: body?['msg']?.toString() ?? 'Submission failed');
      }
    } catch (_) {
      Fluttertoast.showToast(msg: 'Submission failed');
    }
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
    debugPrint('[HomePage] _handleCommonSubmit CALLED - skipValidation=$skipValidation');
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
              gravity: ToastGravity.BOTTOM,
              backgroundColor: Colors.red.shade700,
              textColor: Colors.white,
            );
          } else {
            Fluttertoast.showToast(
              msg: 'Please fill all required fields correctly',
              toastLength: Toast.LENGTH_LONG,
              gravity: ToastGravity.BOTTOM,
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
      final store = context.read<AppStore>();
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;
      final pathSegment = _getKycPostPathSegment(ctx);
      if (pathSegment.isEmpty) {
        Fluttertoast.showToast(msg: 'Invalid step. Please refresh.');
        if (mounted) setState(() => _submitLoading = false);
        return;
      }
      
      final data = await _prepareFormData(skipValidation);
      // Always add "save": true for authenticated submissions (helps backend track saves)
      data['save'] = true;
      debugPrint('[HomePage] _handleCommonSubmit data: $data pathSegment: $pathSegment');
      
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
      
      final http.Response res;
      if (hasFile) {
        // Use multipart/form-data for file uploads
        debugPrint('[HomePage] Using multipart/form-data (file upload detected)');
        final req = http.MultipartRequest('POST', Uri.parse(fullUrl));
        
        // Add Authorization header
        final token = await StorageService.getAccessToken();
        if (token != null) {
          req.headers['Authorization'] = 'Bearer $token';
        }
        
        // Add all fields to multipart request
        for (final e in data.entries) {
          final v = e.value;
          if (v is File) {
            // Add file
            req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
            debugPrint('[HomePage] Added file: ${e.key} = ${v.path}');
          } else if (v is bool) {
            req.fields[e.key] = v.toString();
          } else if (v != null && v.toString().isNotEmpty) {
            req.fields[e.key] = v.toString();
          }
        }
        
        res = await client.postMultipart(req);
      } else {
        // Use JSON for non-file submissions
        debugPrint('[HomePage] Using application/json (no files)');
        res = await client.post(
          endpoint,
          body: data,
          headers: {'Content-Type': 'application/json'},
        );
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>?;
      if (res.statusCode >= 200 && res.statusCode < 300 && body?['success'] == true) {
        StorageService.setUserStep(body?['step']?.toString() ?? '');
        _formNotifier.resetForm();
        // Keep loading indicator visible during get-context call for smooth transition
        await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
        if (mounted && store.errorWithAuth != null) {
          await _clearCookiesAndRefresh();
          Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Session updated. Please continue.');
          if (mounted) setState(() => _submitLoading = false);
          return;
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
        Fluttertoast.showToast(msg: body?['msg']?.toString() ?? 'Submission failed');
        if (mounted) setState(() => _submitLoading = false);
      }
    } catch (e) {
      Fluttertoast.showToast(msg: e.toString());
      if (mounted) setState(() => _submitLoading = false);
    }
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

          // address → bank_address / bankAddress
          if (data['address'] != null) {
            final v = data['address'];
            if (fieldNames.contains('bank_address')) updates['bank_address'] = v;
            if (fieldNames.contains('bankAddress')) updates['bankAddress'] = v;
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
            // Batch update formData and trigger UI rebuild
            setState(() {
              for (final e in updates.entries) {
                debugPrint('[HomePage] Updating field: ${e.key} = ${e.value}');
                _formNotifier.formData[e.key] = e.value;
              }
            });
            
            // Notify listeners to rebuild UI
            _formNotifier.notifyListeners();
            
            Fluttertoast.showToast(msg: 'Bank details fetched successfully');
            debugPrint('[HomePage] Auto-filled ${updates.length} bank fields - UI should update now');
          }
        }
      } else {
        debugPrint('[HomePage] IFSC lookup failed: ${res.statusCode}');
        Fluttertoast.showToast(msg: 'Invalid IFSC code');
      }
    } catch (e) {
      debugPrint('[HomePage] IFSC lookup error: $e');
      Fluttertoast.showToast(msg: 'Failed to fetch bank details');
    }
  }

  Future<void> _handleLogout() async {
    final token = await StorageService.getAccessToken();
    if (token == null) {
      await _clearCookiesAndRefresh();
      return;
    }
    setState(() => _logoutLoading = true);
    try {
      final client = ApiClient();
      await client.post('/api/user/logout', headers: {'Authorization': 'Bearer $token'});
      Fluttertoast.showToast(msg: 'Logged out');
    } catch (_) {
      Fluttertoast.showToast(msg: 'Logged out from local session');
    } finally {
      await _clearCookiesAndRefresh();
      if (mounted) setState(() => _logoutLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _formNotifier,
      child: Consumer2<AppStore, ConditionalFormNotifier>(
        builder: (context, store, form, _) {
          final activeFields = _getActiveFields(store);
          if (store.loading) {
            return const Loader(message: 'Loading...');
          }
          if (store.error != null) {
            return KycLayout(
              title: 'Error',
              child: Center(
                child: Text(
                  store.error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final fieldList = (activeFields?['fields'] as List?) ?? [];
          final conditionalFlow = activeFields?['conditionalFlow'] as List?;
          final submitButton = activeFields?['submitButton'] as Map?;
          
          // Show smooth loading overlay when fetching get-context
          if (store.loadingWithAuth) {
            return const Loader(message: 'Loading...');
          }
          
          return FutureBuilder<bool>(
            future: StorageService.hasAccessToken(),
            builder: (context, snapshot) {
              final isAuthenticated = snapshot.data ?? false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _formNotifier.updateFields(fieldList, conditionalFlow);
              });

              final pageTitle = (activeFields is Map
                      ? activeFields['title'] ?? activeFields['pageTitle']
                      : null)
                  ?.toString() ??
                  'Start your KYC';
              final stepperIndex = _getStepperIndex(store, isAuthenticated);

              return KycLayout(
                title: pageTitle,
                stepperIndex: stepperIndex,
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
                trailing: isAuthenticated
                    ? IconButton(
                        onPressed: _logoutLoading ? null : _handleLogout,
                        icon: _logoutLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: KycTheme.primary),
                              )
                            : const Icon(Icons.logout, color: KycTheme.textPrimary),
                      )
                    : null,
                child: _buildForm(
                  fieldList,
                  activeFields,
                  submitButton,
                  store,
                  isAuthenticated,
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildForm(
    List fieldList,
    dynamic activeFields,
    Map? submitButton,
    AppStore store,
    bool isAuth,
  ) {
    // Check if this is segments screen
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    final position = ctx?['position']?.toString()?.toLowerCase();
    final isSegmentsScreen = position == 'segments';
    
    // Show segments selection UI for segments screen
    if (isSegmentsScreen) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: KycTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KycTheme.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
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
                Fluttertoast.showToast(msg: 'Brokerage Plan selected');
              },
            );
          },
          onSubmit: _submitLoading ? null : () {
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
    final visibleFieldsForDisplay = visibleFields.where((f) {
      if (f is! Map) return false;

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

    // Generic submit button: sirf tab dikhao jab OTP field nahi hai
    // Agar OTP field hai (chahe kitni bhi aur fields ho), sirf OtpVerifySection ka "Verify OTP" button use hoga
    final showGenericSubmit = otpField == null;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: KycTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: KycTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Form(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...visibleFieldsForDisplay.map((field) {
              if (field is! Map) return const SizedBox.shrink();
              final name = field['name']?.toString() ?? '';
              final type = field['type']?.toString() ?? 'text';
              if (otpField != null && name == otpFieldName) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: _buildOtpVerifyCard(otpField, activeFields),
                );
              }
              
              // Check if this is IFSC field on bank / bank_details screen
              // Use position and ctx already declared at function start
              final label = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
              final isBankScreen = position == 'bank' ||
                  position == 'bank_details' ||
                  label == 'bank';
              final isIfscField = isBankScreen &&
                  (name == 'ifsc' || name.toLowerCase().contains('ifsc'));
              
              final editableFields = _formNotifier.editableFieldsList;
              final disable = editableFields.any((e) => e is Map && e['name'] == name);
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FormFieldWidget(
                      name: name,
                      displayName: field['displayName'] ?? name,
                      type: type,
                      fileType: field['fileType'] as List?,
                      size: field['size'],
                      mandatory: field['mandatory'] == true,
                      validation: field['validation'],
                      popupAfterSubmit: activeFields?['popupAfterSubmit'] as List?,
                      value: _formNotifier.formData[name] ?? field['value'],
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
                      },
                      onBlur: (n) {
                        _formNotifier.handleBlur(n);
                        // Auto-fetch on blur for IFSC field
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
                      rows: field['rows'] is int ? field['rows'] : int.tryParse(field['rows']?.toString() ?? ''),
                      cols: field['cols'] is int ? field['cols'] : int.tryParse(field['cols']?.toString() ?? ''),
                      urlCompany: widget.company,
                      workflowKey: (store.fieldsWithAuth as Map?)?['context']?['workflow_key']?.toString(),
                      disable: disable,
                    ),
                    // Add "Fetch Bank Details" button below IFSC field
                    if (isIfscField) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          final ifscValue = _formNotifier.formData[name]?.toString() ?? '';
                          if (ifscValue.length == 11) {
                            _fetchBankDetailsByIfsc(ifscValue);
                          } else {
                            Fluttertoast.showToast(msg: 'Please enter valid 11-digit IFSC code');
                          }
                        },
                        icon: const Icon(Icons.search, size: 20),
                        label: const Text('Fetch Bank Details'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          side: BorderSide(color: KycTheme.primary),
                          foregroundColor: KycTheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
            if (showGenericSubmit) const SizedBox(height: 24),
            if (showGenericSubmit)
            ElevatedButton(
              onPressed: _submitLoading
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
                backgroundColor: KycTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                        Text(submitButton?['buttonName'] ?? 'Submit'),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward, size: 20),
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

  /// OTP verify card as per design: "We have sent you an OTP via sms on +91 XXX Edit", 6 boxes, Resend, Verify, Aadhaar note
  Widget _buildOtpVerifyCard(Map otpField, dynamic activeFields) {
    final otpName = otpField['name']?.toString() ?? 'otp';
    final formData = _formNotifier.formData;
    final mobile = formData['mobile'] ?? formData['phone'] ?? formData['mobile_number'] ?? '';
    final sentToText = (otpField['sentToText']?.toString() ?? '').isNotEmpty
        ? otpField['sentToText'].toString()
        : 'We have sent you an OTP via sms on +91 ${mobile.toString().trim().isEmpty ? 'XXXXX' : mobile}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OtpVerifySection(
          sentToText: sentToText,
          onEdit: () {
            // Optional: go back or clear to edit mobile – can be wired to step back
          },
          onVerify: (otp) {
            _formNotifier.handleChange(otpName, otp);
            _handleCommonSubmit(false);
          },
          onResendOtp: () {
            // Optional: call resend OTP API – can be wired when API supports
          },
          resendCooldownSeconds: 300,
          verifyLoading: _submitLoading,
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