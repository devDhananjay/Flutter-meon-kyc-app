import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:meon_kyc/api/api_client.dart';

class AppStore extends ChangeNotifier {
  // Params
  String? _company;
  String? _workflowName;
  String? get company => _company;
  String? get workflowName => _workflowName;
  void setParams({String? company, String? workflowName}) {
    _company = company ?? _company;
    _workflowName = workflowName ?? _workflowName;
    notifyListeners();
  }

  // Workflow (unauthenticated)
  dynamic _fields;
  bool _loading = false;
  String? _error;
  dynamic get fields => _fields;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> fetchWorkflowFields(String urlCompany, String urlWorkflowName) async {
    debugPrint('[AppStore] fetchWorkflowFields START: $urlCompany / $urlWorkflowName');
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final client = ApiClient();
      final res = await client.post('/api/get-workflow-details/$urlCompany/$urlWorkflowName', body: {});
      debugPrint('[AppStore] fetchWorkflowFields Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        _fields = data?['workflow'];
        debugPrint('[AppStore] fetchWorkflowFields OK, workflow keys: ${_fields is Map ? (_fields as Map).keys.toList() : 'n/a'}');
      } else {
        _error = res.body;
        debugPrint('[AppStore] fetchWorkflowFields ERROR: ${res.body}');
      }
    } catch (e, st) {
      _error = e.toString();
      debugPrint('[AppStore] fetchWorkflowFields Exception: $e\n$st');
    } finally {
      _loading = false;
      notifyListeners();
      debugPrint('[AppStore] fetchWorkflowFields DONE');
    }
  }

  // Workflow with auth
  dynamic _fieldsWithAuth;
  bool _loadingWithAuth = false;
  String? _errorWithAuth;
  dynamic get fieldsWithAuth => _fieldsWithAuth;
  bool get loadingWithAuth => _loadingWithAuth;
  String? get errorWithAuth => _errorWithAuth;

  Future<void> fetchWorkflowFieldsWithAuth(
    String urlCompany,
    String urlWorkflowName,
    String fullQueryString,
  ) async {
    // Normalize query string: remove any leading '?' and rebuild path correctly
    final cleanQuery = fullQueryString.startsWith('?') 
        ? fullQueryString.substring(1) 
        : fullQueryString;
    
    final fullPath = cleanQuery.isEmpty
        ? '/api/get-context/$urlCompany/$urlWorkflowName'
        : '/api/get-context/$urlCompany/$urlWorkflowName?$cleanQuery';
    
    debugPrint('[AppStore] fetchWorkflowFieldsWithAuth START: $fullPath');
    _loadingWithAuth = true;
    _errorWithAuth = null;
    notifyListeners();
    try {
      final client = ApiClient();
      final res = await client.post(fullPath, body: {});
      debugPrint('[AppStore] fetchWorkflowFieldsWithAuth Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        final success = data is Map && data['success'] == true;
        if (success) {
          _fieldsWithAuth = data;
          debugPrint('[AppStore] fetchWorkflowFieldsWithAuth OK');
        } else {
          _errorWithAuth = (data is Map ? data['msg']?.toString() : null) ?? res.body;
          debugPrint('[AppStore] fetchWorkflowFieldsWithAuth ERROR (success: false): $_errorWithAuth');
        }
      } else {
        _errorWithAuth = res.body;
        debugPrint('[AppStore] fetchWorkflowFieldsWithAuth ERROR: ${res.body}');
      }
    } catch (e, st) {
      _errorWithAuth = e.toString();
      debugPrint('[AppStore] fetchWorkflowFieldsWithAuth Exception: $e\n$st');
    } finally {
      _loadingWithAuth = false;
      notifyListeners();
      debugPrint('[AppStore] fetchWorkflowFieldsWithAuth DONE');
    }
  }

  // User details (for KYC Completed page)
  dynamic _userDetails;
  bool _loadingUserDetails = false;
  String? _errorUserDetails;
  dynamic get userDetails => _userDetails;
  bool get loadingUserDetails => _loadingUserDetails;
  String? get errorUserDetails => _errorUserDetails;

  Future<void> fetchUserDetails() async {
    debugPrint('[AppStore] fetchUserDetails START');
    _loadingUserDetails = true;
    _errorUserDetails = null;
    notifyListeners();
    try {
      final client = ApiClient();
      final res = await client.post('/api/user-details', body: {});
      debugPrint('[AppStore] fetchUserDetails Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        _userDetails = data;
        debugPrint('[AppStore] fetchUserDetails OK');
      } else {
        _errorUserDetails = res.body;
        debugPrint('[AppStore] fetchUserDetails ERROR: ${res.body}');
      }
    } catch (e, st) {
      _errorUserDetails = e.toString();
      debugPrint('[AppStore] fetchUserDetails Exception: $e\n$st');
    } finally {
      _loadingUserDetails = false;
      notifyListeners();
      debugPrint('[AppStore] fetchUserDetails DONE');
    }
  }

  dynamic _parseJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
