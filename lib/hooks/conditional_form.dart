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
    final fieldsChanged = !listEquals(_fields, fields) || !listEquals(_conditionalFlow, conditionalFlow);
    _fields = fields;
    _conditionalFlow = conditionalFlow;
    
    if (fieldsChanged && fields != null) {
      // Set initial field values from API response
      for (final f in fields) {
        if (f is Map && f['name'] != null) {
          final val = f['value'];
          if (val == null) continue;
          final name = f['name'];
          final current = formData[name];
          // User cleared this field to empty — keep it; do not re-apply API `value` on refresh.
          if (formData.containsKey(name) &&
              current is String &&
              current.trim().isEmpty) {
            continue;
          }
          // First paint / missing key: merge dropoff from API.
          final unset = current == null ||
              (current is String && current.trim().isEmpty);
          if (!formData.containsKey(name) || unset) {
            formData[name] = f['type'] == 'checkbox' ? (val == true) : val;
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

  /// Writes [updates] into [formData] as-is (no [_processValue] / length caps) and notifies.
  /// Used for IFSC lookup auto-fill so long bank addresses are not truncated like [handleChange].
  void applyExternalFormValues(Map<String, dynamic> updates) {
    for (final e in updates.entries) {
      formData[e.key] = e.value;
    }
    notifyListeners();
  }

  String _processValue(String name, dynamic value, String type, String? validationType, String? validateWith) {
    // BugFixes: dropdown (select) values must not be truncated like generic text.
    if (type == 'checkbox' || type == 'file' || type == 'select') {
      return value.toString();
    }
    var processed = value.toString();
    final nl = name.toLowerCase();
    final effectiveValidation = () {
      final vt = validationType?.toString().trim();
      if (vt != null && vt.isNotEmpty && vt.toLowerCase() != 'no') {
        return vt.toLowerCase();
      }
      if (nl == 'pan_number' || nl == 'temp_pan_no' || nl == 'pan_no') {
        return 'pan';
      }
      return vt?.toLowerCase();
    }();

    switch (effectiveValidation) {
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
      case 'nospecialcharacter':
        processed =
            processed.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
        break;
      default:
        break;
    }
    final cap = validationMaxLengths[effectiveValidation ?? ''] ?? 35;
    if (processed.length > cap) processed = processed.substring(0, cap);
    return processed;
  }

  void handleChange(String name, dynamic value, {String type = 'text', String? validationType, String? validateWith}) {
    var processedValue = value;
    if (type != 'checkbox' && type != 'file' && value != null) {
      processedValue = _processValue(name, value, type, validationType, validateWith);
    }
    formData[name] = processedValue;
    if (validateWith != null && validateWith.isNotEmpty && value != formData[validateWith]) {
      // Get displayName from the validateWith field if available, otherwise format the key
      String label = validateWith.replaceAll('_', ' ');
      // Try to find the validateWith field in _fields to get its displayName
      final validateWithField = _fields?.cast<Map<String, dynamic>?>().firstWhere(
        (f) => f?['name']?.toString() == validateWith,
        orElse: () => null,
      );
      if (validateWithField != null && validateWithField['displayName'] != null) {
        label = validateWithField['displayName'].toString();
      } else {
        // Capitalize first letter of each word for better readability
        label = label.split(' ').map((word) => word.isEmpty 
            ? '' 
            : word[0].toUpperCase() + word.substring(1).toLowerCase()).join(' ');
      }
      errors[name] = 'Value should be same as $label';
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

  void handleBlur(
    String fieldName, {
    String? position,
    String? pageLabel,
  }) {
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
      position: position,
      pageLabel: pageLabel,
    );
    if (fieldErrors.isNotEmpty) {
      errors[fieldName] = fieldErrors.first;
    } else {
      errors.remove(fieldName);
    }
    notifyListeners();
  }

  bool validate({
    String? company,
    String? position,
    String? pageLabel,
  }) {
    errors = validateFormWithConditions(
      _fields,
      formData,
      _conditionalFlow,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
    notifyListeners();
    return errors.isEmpty;
  }

  List<dynamic> get editableFieldsList => getEditableFields(_fields ?? [], fieldEditable);
}
