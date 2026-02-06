import 'package:flutter/foundation.dart';
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/field_validators.dart';

const Map<String, int> validationMaxLengths = {
  'ifsc': 11,
  'bank': 18,
  'aadhar': 12,
  'mobile': 10,
  'pan': 10,
  'aadhaar': 12,
  'email': 30,
  'pincode': 6,
  'account_number': 18,
  'username': 20,
};

class ConditionalFormNotifier extends ChangeNotifier {
  Map<String, dynamic> formData = {};
  Map<String, String> errors = {};
  Map<String, bool> fieldVisibility = {};
  Map<String, bool> fieldEditable = {};

  List<dynamic>? _fields;
  List<dynamic>? _conditionalFlow;
  List<dynamic>? get fields => _fields;
  List<dynamic>? get conditionalFlow => _conditionalFlow;

  ConditionalFormNotifier({List<dynamic>? fields, List<dynamic>? conditionalFlow})
      : _fields = fields,
        _conditionalFlow = conditionalFlow;

  void updateFields(List<dynamic>? fields, List<dynamic>? conditionalFlow) {
    final fieldsChanged = _fields != fields || _conditionalFlow != conditionalFlow;
    _fields = fields;
    _conditionalFlow = conditionalFlow;
    
    if (fieldsChanged && fields != null) {
      // Set initial field values from API response
      for (final f in fields) {
        if (f is Map && f['name'] != null) {
          final val = f['value'];
          if (val != null && !formData.containsKey(f['name'])) {
            formData[f['name']] = f['type'] == 'checkbox' ? (val == true) : val;
          }
        }
      }
      
      // Apply initial conditional flow for all fields with values
      // This ensures correct initial visibility based on pre-filled data
      debugPrint('[ConditionalForm] Applying initial conditional flow for ${watchedFields.length} watched fields');
      for (final watchedField in watchedFields) {
        if (formData.containsKey(watchedField) && formData[watchedField] != null) {
          debugPrint('[ConditionalForm] Evaluating initial state for: $watchedField = ${formData[watchedField]}');
          _applyConditionalLogic(watchedField);
        }
      }
      
      // Only notify listeners if fields actually changed
      notifyListeners();
    }
    // If fields didn't change, don't notify listeners to prevent infinite rebuild loops
  }

  List<String> get watchedFields => getWatchedFields(_conditionalFlow);

  void resetForm() {
    formData = {};
    errors = {};
    fieldVisibility = {};
    fieldEditable = {};
    notifyListeners();
  }

  String _processValue(String name, dynamic value, String type, String? validationType, String? validateWith) {
    if (type == 'checkbox' || type == 'file') return value.toString();
    var processed = value.toString();
    final maxLen = validationMaxLengths[validationType ?? ''] ?? 35;
    if (processed.length > maxLen) processed = processed.substring(0, maxLen);

    switch (validationType) {
      case 'mobile':
      case 'aadhaar':
      case 'pincode':
      case 'otp':
        processed = processed.replaceAll(RegExp(r'\D'), '');
        break;
      case 'pan':
      case 'ifsc':
        processed = processed.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        break;
      case 'bank':
        processed = processed.replaceAll(RegExp(r'\D'), '');
        break;
      case 'name':
        processed = processed.replaceAll(RegExp(r'[^a-zA-Z\s]'), '');
        break;
      default:
        if (validationType != 'no' && processed.length > 35) {
          processed = processed.substring(0, 35);
        }
    }
    return processed;
  }

  void handleChange(String name, dynamic value, {String type = 'text', String? validationType, String? validateWith}) {
    var processedValue = value;
    if (type != 'checkbox' && type != 'file' && value != null) {
      processedValue = _processValue(name, value, type, validationType, validateWith);
    }
    formData[name] = processedValue;
    if (validateWith != null && value != formData[validateWith]) {
      errors[name] = 'Value should be same as ${validateWith.replaceAll('_', ' ')}';
    } else {
      errors.remove(name);
    }
    _applyConditionalLogic(name);
    notifyListeners();
  }

  void _applyConditionalLogic(String fieldName) {
    if (!watchedFields.contains(fieldName)) return;
    
    debugPrint('[ConditionalForm] Applying logic for: $fieldName = ${formData[fieldName]}');
    final state = evaluateConditionalFlowForField(_conditionalFlow, formData, fieldName);
    
    // Update field visibility (show/hide actions)
    if (state.fieldVisibility.isNotEmpty) {
      debugPrint('[ConditionalForm] Visibility changes: ${state.fieldVisibility}');
      fieldVisibility.addAll(state.fieldVisibility);
      
      // Debug: Show which fields are now visible
      final visibleCount = fieldVisibility.values.where((v) => v == true).length;
      final hiddenCount = fieldVisibility.values.where((v) => v == false).length;
      debugPrint('[ConditionalForm] After update: $visibleCount visible, $hiddenCount hidden');
    }
    
    // Update field editable state (enable/disable actions)
    if (state.fieldEditable.isNotEmpty) {
      debugPrint('[ConditionalForm] Editable changes: ${state.fieldEditable}');
      for (final e in state.fieldEditable.entries) {
        final key = e.key.replaceAllMapped(RegExp(r'_([a-z])'), (m) => m.group(1)!.toUpperCase());
        fieldEditable[key] = e.value;
      }
    }
    
    // Update form data (empty, prePopulate, true, false actions)
    for (final e in state.formData.entries) {
      // Only update if value has actually changed from actions
      if (e.key != fieldName && formData[e.key] != e.value) {
        debugPrint('[ConditionalForm] Action updated field: ${e.key} = ${e.value}');
        formData[e.key] = e.value;
      }
    }
  }

  void handleBlur(String fieldName) {
    final field = _fields?.cast<Map<String, dynamic>?>().firstWhere(
          (f) => f?['name'] == fieldName,
          orElse: () => null,
        );
    if (field == null) return;
    final fieldErrors = validateFieldWithConditions(
      field,
      formData[fieldName],
      formData,
      _conditionalFlow,
    );
    if (fieldErrors.isNotEmpty) {
      errors[fieldName] = fieldErrors.first;
    }
    notifyListeners();
  }

  bool validate() {
    errors = validateFormWithConditions(_fields, formData, _conditionalFlow);
    notifyListeners();
    return errors.isEmpty;
  }

  List<dynamic> get editableFieldsList => getEditableFields(_fields ?? [], fieldEditable);
}
