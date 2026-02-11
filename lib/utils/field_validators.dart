import 'package:meon_kyc/utils/conditional_flow.dart';

String? _required(dynamic value, String fieldName) {
  if (value == null || value.toString().trim().isEmpty) {
    return '$fieldName is required';
  }
  return null;
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

String? _pan(dynamic value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  return RegExp(r'^[A-Za-z]{5}[0-9]{4}[A-Za-z]{1}$')
          .hasMatch(value.toString().trim().toUpperCase())
      ? null
      : 'Please enter a valid PAN number';
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
};

List<String> validateFieldWithConditions(
  Map<String, dynamic> field,
  dynamic value,
  Map<String, dynamic> formData,
  List<dynamic>? conditionalFlow, {
  Map<String, bool> fieldRequirements = const {},
}) {
  final errors = <String>[];
  final isRequired = fieldRequirements[field['name']] ?? field['mandatory'] == true;

  if (isRequired) {
    final err = _required(value, field['displayName'] ?? field['name'] ?? 'Field');
    if (err != null) {
      errors.add(err);
      return errors;
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

  final validationType = field['validation'];
  if (validationType != null && validationType != 'no') {
    final fn = _fieldValidators[validationType];
    if (fn != null) {
      final err = fn(value);
      if (err != null) errors.add(err);
    }
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

Map<String, String> validateFormWithConditions(
  List<dynamic>? fields,
  Map<String, dynamic> formData,
  List<dynamic>? conditionalFlow,
) {
  final errors = <String, String>{};
  if (fields == null) return errors;

  final flowState = evaluateConditionalFlow(conditionalFlow, formData);
  final visibleFields = getVisibleFields(fields, flowState.fieldVisibility);

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
    );
    if (fieldErrors.isNotEmpty) errors[name] = fieldErrors.first;
  }

  return errors;
}
