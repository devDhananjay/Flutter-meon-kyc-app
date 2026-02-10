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
          
          // Extract Position from context for stepper
          if (data is Map && data.containsKey('context')) {
            final context = data['context'];
            if (context is Map && context.containsKey('position')) {
              _currentPosition = context['position']?.toString();
              debugPrint('[AppStore] Position extracted: $_currentPosition');
            }
          }
          
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

  // Stepper workflow (dynamic steps from API)
  dynamic _stepperWorkflow;
  bool _loadingStepperWorkflow = false;
  String? _errorStepperWorkflow;
  String? _currentPosition; // Position from get-context API (e.g., "mobile", "mobile_otp")
  
  dynamic get stepperWorkflow => _stepperWorkflow;
  bool get loadingStepperWorkflow => _loadingStepperWorkflow;
  String? get errorStepperWorkflow => _errorStepperWorkflow;
  String? get currentPosition => _currentPosition;

  /// Extract moduleName list from stepper workflow API response
  /// Returns ordered list of moduleName values
  List<String> getStepperSteps() {
    if (_stepperWorkflow is! Map) return [];
    
    // Sort by key to maintain order (keys are like "1", "2", "3", etc.)
    final sortedKeys = _stepperWorkflow.keys.toList()
      ..sort((a, b) {
        final aInt = int.tryParse(a.toString());
        final bInt = int.tryParse(b.toString());
        if (aInt != null && bInt != null) {
          return aInt.compareTo(bInt);
        }
        return a.toString().compareTo(b.toString());
      });
    
    final steps = <String>[];
    for (final key in sortedKeys) {
      final value = _stepperWorkflow[key];
      if (value is Map && value.containsKey('moduleName')) {
        final moduleName = value['moduleName']?.toString();
        if (moduleName != null && moduleName.isNotEmpty) {
          steps.add(moduleName);
        }
      }
    }
    
    return steps;
  }

  /// Get current step index based on Position
  /// Returns index of Position in stepper steps, or null if not found
  /// IMPORTANT: Current step should NOT be marked as completed, only steps BEFORE it
  /// For mobile_otp position: match "mobile_otp" step, NOT "mobile" step
  int? getCurrentStepIndex() {
    if (_currentPosition == null || _currentPosition!.isEmpty) return null;
    
    final steps = getStepperSteps();
    if (steps.isEmpty) return null;
    
    final positionLower = _currentPosition!.toLowerCase().trim();
    
    // Priority 1: Exact match (case-insensitive)
    int index = steps.indexWhere(
      (step) => step.toLowerCase().trim() == positionLower,
    );
    
    // Priority 2: For mobile_otp, also check if step is "mobile_otp" or "mobile"
    // But prefer exact match first
    if (index == -1 && positionLower == 'mobile_otp') {
      // Try to find "mobile_otp" step first
      index = steps.indexWhere(
        (step) => step.toLowerCase().trim() == 'mobile_otp',
      );
      // If not found, try "mobile"
      if (index == -1) {
        index = steps.indexWhere(
          (step) => step.toLowerCase().trim() == 'mobile',
        );
      }
    }
    
    // Priority 3: Step starts with position (e.g., position "mobile" matches step "mobile_otp")
    if (index == -1) {
      index = steps.indexWhere(
        (step) => step.toLowerCase().trim().startsWith(positionLower) ||
                   positionLower.startsWith(step.toLowerCase().trim()),
      );
    }
    
    // Priority 4: Contains match (last resort)
    if (index == -1) {
      index = steps.indexWhere(
        (step) => step.toLowerCase().contains(positionLower) ||
                   positionLower.contains(step.toLowerCase()),
      );
    }
    
    if (index != -1) {
      debugPrint('[AppStore] Position "$_currentPosition" matched step "${steps[index]}" at index: $index');
    } else {
      debugPrint('[AppStore] Position "$_currentPosition" not found in steps: $steps');
    }
    
    return index == -1 ? null : index;
  }

  Future<void> fetchStepperWorkflow(String company, String workflowId) async {
    debugPrint('[AppStore] fetchStepperWorkflow START: $company / $workflowId');
    _loadingStepperWorkflow = true;
    _errorStepperWorkflow = null;
    notifyListeners();
    try {
      final client = ApiClient();
      final res = await client.post('/kycadmin_getWorkflow/$company/$workflowId', body: {});
      debugPrint('[AppStore] fetchStepperWorkflow Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        _stepperWorkflow = data;
        final steps = getStepperSteps();
        debugPrint('[AppStore] fetchStepperWorkflow OK - Found ${steps.length} steps: $steps');
      } else {
        _errorStepperWorkflow = res.body;
        debugPrint('[AppStore] fetchStepperWorkflow ERROR: ${res.body}');
      }
    } catch (e, st) {
      _errorStepperWorkflow = e.toString();
      debugPrint('[AppStore] fetchStepperWorkflow Exception: $e\n$st');
    } finally {
      _loadingStepperWorkflow = false;
      notifyListeners();
      debugPrint('[AppStore] fetchStepperWorkflow DONE');
    }
  }

  /// Reset all state (used after logout)
  void resetState() {
    _fields = null;
    _fieldsWithAuth = null;
    _userDetails = null;
    _stepperWorkflow = null;
    _currentPosition = null;
    _loading = false;
    _loadingWithAuth = false;
    _loadingUserDetails = false;
    _loadingStepperWorkflow = false;
    _error = null;
    _errorWithAuth = null;
    _errorUserDetails = null;
    _errorStepperWorkflow = null;
    notifyListeners();
    debugPrint('[AppStore] State reset');
  }

  dynamic _parseJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
