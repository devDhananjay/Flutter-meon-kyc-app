import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/kyc_date_utils.dart';

String? _required(dynamic value, dynamic fieldLabel) {
  if (value == null || value.toString().trim().isEmpty) {
    final label = fieldLabel?.toString().trim();
    if (label != null && label.isNotEmpty) {
      return '$label is required';
    }
    return 'This field is required';
  }
  return null;
}

bool _isMandatoryField(Map<dynamic, dynamic> field) {
  final m = field['mandatory'];
  if (m == true || m == 1) return true;
  final s = m?.toString().trim().toLowerCase();
  return s == 'true' || s == 'yes' || s == '1';
}

// String? _mobile(dynamic value) {
//   if (value == null || value.toString().trim().isEmpty) return null;
//   return RegExp(r'^[6-9]\d{9}$').hasMatch(value.toString().trim())
//       ? null
//       : 'Please enter a valid 10-digit mobile number';
// }

String? _mobile(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  
  String trimmedValue = value.toString().trim();
  
  // Check length first
  if (trimmedValue.length != 10) {
    return 'Please enter a valid 10-digit mobile number';
  }
  
  // Then check pattern
  return RegExp(r'^[6-9]\d{9}$').hasMatch(trimmedValue)
      ? null
      : 'Please enter a valid 10-digit mobile number';
}

String? _email(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.toString().trim())
      ? null
      : 'Please enter a valid email address';
}

/// Indian PAN: exactly 10 characters — 5 letters, 4 digits, 1 letter (e.g. ABCDE1234F).
String? _pan(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  final s = value.toString().trim().toUpperCase();
  if (s.length != 10) {
    return 'PAN must be exactly 10 characters (5 letters + 4 numbers + 1 letter)';
  }
  if (!RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$').hasMatch(s)) {
    return 'Invalid PAN: use 5 letters, then 4 digits, then 1 letter (e.g. ABCDE1234F)';
  }
  return null;
}

String? _ifsc(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(value.toString().trim())
      ? null
      : 'Please enter a valid IFSC';
}

String? _bank(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return RegExp(r'^\d{9,18}$').hasMatch(value.toString().trim())
      ? null
      : 'Please enter a valid 9-18 digit Bank Account Number';
}

String? _aadhaar(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return RegExp(r'^\d{12}$').hasMatch(value.toString().trim())
      ? null
      : 'Please enter a valid 12-digit Aadhaar number';
}

String? _pincode(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return RegExp(r'^\d{6}$').hasMatch(value.toString().trim())
      ? null
      : 'Please enter a valid 6-digit Pincode';
}

String? _number(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return num.tryParse(value.toString()) != null ? null : 'Please enter a valid number';
}

String? _minLength(dynamic value, int min) {
  if (value == null) return null;
  return value.toString().length >= min ? null : 'Minimum length is $min';
}

String? _maxLength(dynamic value, int max) {
  if (value == null) return null;
  return value.toString().length <= max ? null : 'Maximum length is $max';
}

String? _noSpecialCharacter(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  final s = value.toString().trim();
  // Names: letters, spaces, hyphen, apostrophe (e.g. O'Brien, Mary-Jane) — no @#123 etc.
  if (!RegExp(r"^[a-zA-Z\s'\-]+$").hasMatch(s)) {
    return 'Only letters, spaces, hyphen and apostrophe are allowed';
  }
  return null;
}

final Map<String, String? Function(dynamic)> _fieldValidators = {
  'mobile': _mobile,
  'email': _email,
  'pan': _pan,
  'required': (v) => _required(v, ''),
  'ifsc': _ifsc,
  'bank': _bank,
  'aadhaar': _aadhaar,
  'pincode': _pincode,
  'number': _number,
  'nospecialcharacter': _noSpecialCharacter,
};

/// PAN module (`position` / `pageLabel` `pan`): [pan_number] uses `validation: "no"` in API
/// but must still match Indian PAN format; [pan_dob_for_match] must be in API date range.
bool _implicitPanFormatField(Map<String, dynamic> field) {
  final n = (field['name']?.toString() ?? '').toLowerCase();
  final lbl = (field['label']?.toString() ?? '').toLowerCase();
  return n == 'pan_number' ||
      n == 'temp_pan_no' ||
      n == 'pan_no' ||
      lbl == 'pan_number' ||
      lbl == 'temp_pan_no';
}

bool _panModuleStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'pan' || l == 'pan';
}

/// On PAN verify screen, these inputs must be filled even if API `mandatory` is false.
bool _panModuleRequiredField(
  Map<String, dynamic> field,
  String? position,
  String? pageLabel,
) {
  if (!_panModuleStep(position, pageLabel)) return false;
  final n = (field['name']?.toString() ?? '').toLowerCase();
  return n == 'pan_number' || n == 'pan_dob_for_match';
}

List<String> validateFieldWithConditions(
  Map<String, dynamic> field,
  dynamic value,
  Map<String, dynamic> formData,
  List<dynamic>? conditionalFlow, {
  Map<String, bool> fieldRequirements = const {},
  String? position,
  String? pageLabel,
}) {
  final errors = <String>[];
  final displayName =
      field['displayName'] ?? field['name'] ?? 'This field';
  final reqOverride = fieldRequirements[field['name']];
  final isRequired = reqOverride ??
      (_isMandatoryField(field) || _panModuleRequiredField(field, position, pageLabel));

  if (isRequired) {
    final fieldType = field['type']?.toString().toLowerCase();
    if (fieldType == 'checkbox') {
      if (!isCheckboxCheckedValue(value)) {
        errors.add('$displayName is required');
        return errors;
      }
    } else {
      final err = _required(value, displayName);
      if (err != null) {
        errors.add(err);
        return errors;
      }
    }
  }

  // Only require "same as" when the other field has a value; skip when other is empty (avoids error on pre-filled mobile, etc.)
  final validateWithKey = field['validateWith']?.toString()?.trim();
  if (validateWithKey != null && validateWithKey.isNotEmpty) {
    final otherValue = formData[validateWithKey];
    final otherFilled = otherValue != null && otherValue.toString().trim().isNotEmpty;
    if (otherFilled && value != formData[validateWithKey]) {
      // Try to get displayName from field list, fallback to formatted key name
      String label = validateWithKey.replaceAll('_', ' ');
      // Capitalize first letter of each word for better readability
      label = label.split(' ').map((word) => word.isEmpty 
          ? '' 
          : word[0].toUpperCase() + word.substring(1).toLowerCase()).join(' ');
      errors.add('Value should be same as $label');
    }
  }

  if (value == null || value.toString().trim().isEmpty) return errors;

  final validationRaw = field['validation']?.toString().trim() ?? '';
  final validationType = validationRaw.isEmpty ||
          validationRaw.toLowerCase() == 'no'
      ? null
      : validationRaw.toLowerCase();
  if (validationType != null) {
    final fn = _fieldValidators[validationType];
    if (fn != null) {
      final err = fn(value);
      if (err != null) errors.add(err);
    }
  }
  if (validationType != 'pan' && _implicitPanFormatField(field)) {
    final err = _pan(value);
    if (err != null) errors.add(err);
  }

  final fieldType = field['type']?.toString().toLowerCase();
  if (fieldType == 'date') {
    final err = validateDobAgainstFieldBounds(field, value);
    if (err != null) errors.add(err);
  }

  final minLen = field['minLength'];
  if (minLen != null) {
    final err = _minLength(value, minLen is int ? minLen : int.tryParse(minLen.toString()) ?? 0);
    if (err != null) errors.add(err);
  }

  final maxLen = field['maxLength'];
  if (maxLen != null) {
    final err = _maxLength(value, maxLen is int ? maxLen : int.tryParse(maxLen.toString()) ?? 999);
    if (err != null) errors.add(err);
  }

  return errors;
}

// --- Nominee percentage total = 100% (disabled for now; uncomment to re-enable) ---
//
// bool isNomineeKycStep(String? position, String? pageLabel) {
//   final p = (position ?? '').toLowerCase();
//   final l = (pageLabel ?? '').toLowerCase();
//   return p == 'nominee' || l == 'nominee';
// }
//
// bool _addNomineeSelectedYes(Map<String, dynamic> formData) {
//   final v = formData['add_nominee']?.toString().trim().toLowerCase();
//   return v == 'yes' || v == 'y';
// }
//
// bool _kycFieldVisibleLikeHomePage(
//   Map<dynamic, dynamic> field,
//   Map<String, bool> runtimeFieldVisibility, {
//   String? company,
//   String? position,
//   String? pageLabel,
// }) {
//   final name = field['name']?.toString();
//   final initialShow = kycFieldVisibleForFormStep(
//     field,
//     company: company,
//     position: position,
//     pageLabel: pageLabel,
//   );
//   final dynamicVisibility = runtimeFieldVisibility[name];
//   return dynamicVisibility ?? initialShow;
// }
//
// const Set<String> _nomineePercentageFieldNames = {
//   'nominee_1_percentage',
//   'nominee_2_percentage',
//   'nominee_3_percentage',
// };
//
// /// Sum of visible nominee percentage fields must equal 100 when user adds nominees.
// String? validateNomineePercentageTotal({
//   required List<dynamic>? fields,
//   required Map<String, dynamic> formData,
//   required Map<String, bool> runtimeFieldVisibility,
//   String? company,
//   String? position,
//   String? pageLabel,
// }) {
//   if (!isNomineeKycStep(position, pageLabel)) return null;
//   if (!_addNomineeSelectedYes(formData)) return null;
//   if (fields == null) return null;
//
//   var total = 0.0;
//   var hasVisiblePercentageField = false;
//
//   for (final f in fields) {
//     if (f is! Map) continue;
//     final name = f['name']?.toString();
//     if (name == null || !_nomineePercentageFieldNames.contains(name)) continue;
//
//     if (!_kycFieldVisibleLikeHomePage(
//       f,
//       runtimeFieldVisibility,
//       company: company,
//       position: position,
//       pageLabel: pageLabel,
//     )) {
//       continue;
//     }
//
//     hasVisiblePercentageField = true;
//     final raw = formData[name];
//     if (raw == null || raw.toString().trim().isEmpty) continue;
//     final parsed = double.tryParse(
//       raw.toString().replaceAll(RegExp(r'[^0-9.]'), ''),
//     );
//     if (parsed != null) total += parsed;
//   }
//
//   if (!hasVisiblePercentageField) return null;
//   if ((total - 100).abs() > 0.001) {
//     return 'Total nominee share must equal 100%';
//   }
//   return null;
// }

Map<String, String> validateFormWithConditions(
  List<dynamic>? fields,
  Map<String, dynamic> formData,
  List<dynamic>? conditionalFlow, {
  String? company,
  String? position,
  String? pageLabel,
  Map<String, bool>? runtimeFieldVisibility,
}) {
  final errors = <String, String>{};
  if (fields == null) return errors;

  final visibility = runtimeFieldVisibility ?? const {};
  final flowState = evaluateConditionalFlow(conditionalFlow, formData);
  final mergedVisibility = <String, bool>{
    ...flowState.fieldVisibility,
    ...visibility,
  };

  final visibleFields = getVisibleFields(
    fields,
    mergedVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );

  for (final f in visibleFields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null) continue;
    final fieldErrors = validateFieldWithConditions(
      Map<String, dynamic>.from(f as Map),
      formData[name],
      formData,
      conditionalFlow,
      fieldRequirements: flowState.fieldRequirements,
      position: position,
      pageLabel: pageLabel,
    );
    if (fieldErrors.isNotEmpty) errors[name] = fieldErrors.first;
  }

  return errors;
}
