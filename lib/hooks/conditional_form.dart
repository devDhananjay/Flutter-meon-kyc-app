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
  /// Form-level message for toast only (not shown under any field).
  String? validationToastMessage;
  Map<String, bool> fieldVisibility = {};
  Map<String, bool> fieldEditable = {};
  List<dynamic>? _fields;
  List<dynamic>? _conditionalFlow;
  dynamic _fieldsWithAuthSnapshot;
  List<dynamic>? get fields => _fields;
  List<dynamic>? get conditionalFlow => _conditionalFlow;

  ConditionalFormNotifier({List<dynamic>? fields, List<dynamic>? conditionalFlow})
      : _fields = fields,
        _conditionalFlow = conditionalFlow;

  void updateFields(
    List<dynamic>? fields,
    List<dynamic>? conditionalFlow, {
    dynamic fieldsWithAuth,
  }) {
    final fieldsChanged = !listEquals(_fields, fields) || !listEquals(_conditionalFlow, conditionalFlow);
    _fields = fields;
    _conditionalFlow = conditionalFlow;
    if (fieldsWithAuth != null) _fieldsWithAuthSnapshot = fieldsWithAuth;
    
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
            final type = f['type']?.toString().toLowerCase();
            formData[name] = type == 'checkbox'
                ? isCheckboxCheckedValue(val)
                : val;
          } else if (isAadharImageFieldName(name?.toString())) {
            // DigiLocker photo URL must track latest get-context / user-details.
            final incoming = val?.toString().trim() ?? '';
            if (incoming.startsWith('http')) {
              final current = formData[name]?.toString().trim() ?? '';
              if (incoming != current) formData[name] = val;
            }
          }
        }
      }

      refreshUserAddressCache(
        formData: formData,
        fieldsWithAuth: _fieldsWithAuthSnapshot ?? fieldsWithAuth,
        stepFields: fields,
      );

      // Nominee address: only keep values when "same as my address" is checked.
      clearNomineeAddressesWhenUnchecked(formData);
      
      // Apply initial conditional flow for all fields with values
      // This ensures correct initial visibility based on pre-filled data
      debugPrint('[ConditionalForm] Applying initial conditional flow for ${watchedFields.length} watched fields');
      for (final watchedField in watchedFields) {
        if (isNomineeSameAsMyAddressCheckbox(watchedField)) continue;
        final fieldValue = formData[watchedField];
        // Evaluate if field has a truthy value OR if it's explicitly false/empty (for checkbox "No" cases)
        if (formData.containsKey(watchedField) && 
            (fieldValue != null || fieldValue == false || fieldValue == '')) {
          debugPrint('[ConditionalForm] Evaluating initial state for: $watchedField = ${formData[watchedField]}');
          _applyConditionalLogic(watchedField);
        }
      }

      for (final entry in kNomineeSameAsAddressGroups.entries) {
        if (isCheckboxCheckedValue(formData[entry.key])) {
          syncNomineeAddressFromSameAsCheckbox(
            formData,
            entry.key,
            formData[entry.key],
            stepFields: fields,
            fieldsWithAuth: _fieldsWithAuthSnapshot ?? fieldsWithAuth,
          );
        }
      }

      final ctx = (_fieldsWithAuthSnapshot as Map?)?['context'];
      final stepPos = ctx?['position']?.toString();
      final stepLbl = ctx?['page']?['data']?['label']?.toString();
      if (isNomineeKycStep(stepPos, stepLbl)) {
        _runNomineeRealtimeUiSync(
          position: stepPos,
          pageLabel: stepLbl,
        );
      } else {
        _syncNomineePercentageFromContext(
          position: stepPos,
          pageLabel: stepLbl,
        );
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
    validationToastMessage = null;
    fieldVisibility = {};
    fieldEditable = {};
    clearUserAddressCache();
    _fieldsWithAuthSnapshot = null;
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
    if (type == 'checkbox') {
      processedValue = isCheckboxCheckedValue(processedValue);
    }

    final ctx = (_fieldsWithAuthSnapshot as Map?)?['context'];
    final stepPos = ctx?['position']?.toString();
    final stepLbl = ctx?['page']?['data']?['label']?.toString();
    if (isNomineeKycStep(stepPos, stepLbl)) {
      final clamped = clampNomineePercentageValue(
        fieldName: name,
        rawValue: processedValue,
        formData: formData,
        fields: _fields,
        runtimeFieldVisibility: fieldVisibility,
        position: stepPos,
        pageLabel: stepLbl,
      );
      if (clamped != null) processedValue = clamped;
    }

    formData[name] = processedValue;

    refreshUserAddressCache(
      formData: formData,
      fieldsWithAuth: _fieldsWithAuthSnapshot,
      stepFields: _fields,
    );

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

    // Run after conditional flow so empty/prePopulate rules cannot wipe the copy.
    if (isNomineeSameAsMyAddressCheckbox(name)) {
      syncNomineeAddressFromSameAsCheckbox(
        formData,
        name,
        formData[name],
        stepFields: _fields,
        fieldsWithAuth: _fieldsWithAuthSnapshot,
      );
    }

    if (isNomineeKycStep(stepPos, stepLbl) &&
        shouldRunNomineeRealtimeUiSync(name)) {
      _runNomineeRealtimeUiSync(
        position: stepPos,
        pageLabel: stepLbl,
        changedFieldName: name,
      );
    }

    notifyListeners();
  }

  void _runNomineeRealtimeUiSync({
    String? position,
    String? pageLabel,
    String? changedFieldName,
  }) {
    _syncNomineePercentageFromContext(
      position: position,
      pageLabel: pageLabel,
    );
    _clearNomineeProtectedEditableOverrides();

    // Percentage typing: sync only — re-running `add_nominee` was resetting add_2 / % input.
    final reapplyConditional = changedFieldName == kAddSecondNomineeField ||
        changedFieldName == kAddThirdNomineeField ||
        changedFieldName == kExtraNomineeField;
    if (reapplyConditional &&
        changedFieldName != null &&
        watchedFields.contains(changedFieldName)) {
      _applyConditionalLogic(changedFieldName);
      _syncNomineePercentageFromContext(
        position: position,
        pageLabel: pageLabel,
      );
      _clearNomineeProtectedEditableOverrides();
    }
  }

  void _clearNomineeProtectedEditableOverrides() {
    final ctx = (_fieldsWithAuthSnapshot as Map?)?['context'];
    final stepPos = ctx?['position']?.toString();
    final stepLbl = ctx?['page']?['data']?['label']?.toString();
    if (!isNomineeKycStep(stepPos, stepLbl)) return;
    clearNomineeSyncProtectedEditableOverrides(
      fieldEditable: fieldEditable,
      fields: _fields,
    );
  }

  void _syncNomineePercentageFromContext({
    String? company,
    String? position,
    String? pageLabel,
  }) {
    final ctx = (_fieldsWithAuthSnapshot as Map?)?['context'];
    syncNomineePercentageSideEffects(
      formData: formData,
      fieldEditable: fieldEditable,
      fields: _fields,
      runtimeFieldVisibility: fieldVisibility,
      company: company,
      position: position ?? ctx?['position']?.toString(),
      pageLabel: pageLabel ??
          ctx?['page']?['data']?['label']?.toString(),
    );
  }

  void _applyConditionalLogic(String fieldName) {
    if (!watchedFields.contains(fieldName)) return;

    final ctx = (_fieldsWithAuthSnapshot as Map?)?['context'];
    final stepPos = ctx?['position']?.toString();
    final stepLbl = ctx?['page']?['data']?['label']?.toString();
    final onNominee = isNomineeKycStep(stepPos, stepLbl);
    
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
        if (onNominee && isNomineeSyncProtectedFormField(e.key)) continue;
        fieldEditable[e.key] = e.value;
      }
    }
    
    // Update form data (empty, prePopulate, true, false actions)
    for (final e in state.formData.entries) {
      if (e.key == fieldName || formData[e.key] == e.value) continue;
      // Nominee address copy/clear is handled only via same-as checkbox sync.
      if (isNomineeAddressTargetField(e.key)) continue;
      if (onNominee && isNomineeSyncProtectedFormField(e.key)) continue;
      debugPrint('[ConditionalForm] Action updated field: ${e.key} = ${e.value}');
      formData[e.key] = e.value;
    }

    if (onNominee) _clearNomineeProtectedEditableOverrides();
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

    if (isNomineePercentageFieldName(fieldName) &&
        isNomineeKycStep(position, pageLabel)) {
      _runNomineeRealtimeUiSync(
        position: position,
        pageLabel: pageLabel,
        changedFieldName: fieldName,
      );
    }

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
    validationToastMessage = null;
    errors = validateFormWithConditions(
      _fields,
      formData,
      _conditionalFlow,
      company: company,
      position: position,
      pageLabel: pageLabel,
      runtimeFieldVisibility: fieldVisibility,
    );

    _syncNomineePercentageFromContext(
      company: company,
      position: position,
      pageLabel: pageLabel,
    );

    final nomineePctError = validateNomineePercentageTotal(
      fields: _fields,
      formData: formData,
      runtimeFieldVisibility: fieldVisibility,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
    if (nomineePctError != null) {
      validationToastMessage = nomineePctError;
      notifyListeners();
      return false;
    }

    notifyListeners();
    return errors.isEmpty;
  }

  List<dynamic> get editableFieldsList => getEditableFields(_fields ?? [], fieldEditable);
}
