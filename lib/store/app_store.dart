import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/api/kyc_api.dart';

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
          
          // Extract Position and Page ID from context for stepper
          if (data is Map && data.containsKey('context')) {
            final context = data['context'];
            if (context is Map) {
              if (context.containsKey('position')) {
                _currentPosition = context['position']?.toString();
                debugPrint('[AppStore] Position extracted: $_currentPosition');
              }
              // Extract page.id for duplicate position handling
              if (context.containsKey('page')) {
                final page = context['page'];
                if (page is Map && page.containsKey('id')) {
                  _currentPageId = page['id']?.toString();
                  debugPrint('[AppStore] Page ID extracted: $_currentPageId');
                }
              }
            }
          }
          
          debugPrint('[AppStore] fetchWorkflowFieldsWithAuth OK');
        } else {
          // Extract error message from nested error object first, then fallback to top-level msg
          String? errorMsg;
          if (data is Map) {
            // Check for nested error.msg first (e.g., "Missing account details...")
            final errorObj = data['error'];
            if (errorObj is Map && errorObj['msg'] != null) {
              errorMsg = errorObj['msg']?.toString();
            } else {
              // Fallback to top-level msg
              errorMsg = data['msg']?.toString();
            }
          }
          _errorWithAuth = errorMsg ?? res.body;
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
  String? _currentPageId; // Page ID from get-context API (e.g., "16", "17") - corresponds to workflow key
  
  dynamic get stepperWorkflow => _stepperWorkflow;
  bool get loadingStepperWorkflow => _loadingStepperWorkflow;
  String? get errorStepperWorkflow => _errorStepperWorkflow;
  String? get currentPosition => _currentPosition;
  String? get currentPageId => _currentPageId;

  /// Extract data.label list from stepper workflow API response
  /// Returns ordered list of label values from data.label
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
      if (value is Map) {
        // Extract from data.label (new format)
        final data = value['data'] as Map?;
        if (data != null && data.containsKey('label')) {
          final label = data['label']?.toString();
          if (label != null && label.isNotEmpty) {
            steps.add(label);
            continue;
          }
        }
        // Fallback to moduleName (for backward compatibility)
        if (value.containsKey('moduleName')) {
          final moduleName = value['moduleName']?.toString();
          if (moduleName != null && moduleName.isNotEmpty) {
            steps.add(moduleName);
          }
        }
      }
    }
    
    // Filter out backend-only / admin steps that should not appear in user stepper
    const hiddenSteps = <String>{
      'cdsl_upload',
      'nse',
      'bse',
      'kra_new',
      'backoffice',
    };
    
    return steps
        .where((s) => !hiddenSteps.contains(s.toLowerCase().trim()))
        .toList();
  }

  /// Get current step index based on Position and Page ID
  /// Returns index of Position in stepper steps, or null if not found
  /// IMPORTANT: Current step should NOT be marked as completed, only steps BEFORE it
  /// Uses page.id (workflow key) along with position to handle duplicate step names
  int? getCurrentStepIndex() {
    if (_currentPosition == null || _currentPosition!.isEmpty) return null;
    
    final steps = getStepperSteps();
    if (steps.isEmpty) return null;
    
    final positionLower = _currentPosition!.toLowerCase().trim();
    final pageId = _currentPageId?.trim(); // Page ID is the workflow key (e.g., "16", "17")
    
    // Priority 1: Match using page.id (workflow key) - most accurate for duplicate positions
    // Page ID corresponds to the workflow key (e.g., "16" means workflow["16"])
    if (pageId != null && pageId.isNotEmpty && _stepperWorkflow is Map) {
      // Find the index by matching the workflow key
      final sortedKeys = (_stepperWorkflow as Map).keys.toList()
        ..sort((a, b) {
          final aInt = int.tryParse(a.toString());
          final bInt = int.tryParse(b.toString());
          if (aInt != null && bInt != null) {
            return aInt.compareTo(bInt);
          }
          return a.toString().compareTo(b.toString());
        });
      
      // Find the index of the key that matches pageId
      final keyIndex = sortedKeys.indexWhere((key) => key.toString() == pageId);
      if (keyIndex != -1) {
        // Verify that the label at this index matches the position
        final workflowValue = _stepperWorkflow[sortedKeys[keyIndex]];
        if (workflowValue is Map) {
          final data = workflowValue['data'] as Map?;
          final label = data?['label']?.toString()?.toLowerCase().trim();
          if (label == positionLower || label?.startsWith(positionLower) == true) {
            return keyIndex;
          }
        }
      }
    }
    
    // Priority 2: Exact match by position (case-insensitive)
    int index = steps.indexWhere(
      (step) => step.toLowerCase().trim() == positionLower,
    );
    
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
    
    // Index may be -1 if no matching step is found; return null in that case.
    return index == -1 ? null : index;
  }

  /// Fetch stepper workflow metadata.
  /// Backend route is: /kycadmin_getWorkflow/{workflowName}/{workflowId}
  Future<void> fetchStepperWorkflow(String workflowName, String workflowId) async {
    debugPrint('[AppStore] fetchStepperWorkflow START: $workflowName / $workflowId');
    _loadingStepperWorkflow = true;
    _errorStepperWorkflow = null;
    notifyListeners();

    try {
      final res = await KycAPI.getStepperWorkflow(workflowName, workflowId);
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
    _currentPageId = null;
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
