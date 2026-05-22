import 'package:flutter/foundation.dart';

int _calculateAge(DateTime dob) {
  final today = DateTime.now();
  var age = today.year - dob.year;
  final m = today.month - dob.month;
  if (m < 0 || (m == 0 && today.day < dob.day)) age--;
  return age;
}

bool _parseDate(dynamic v) {
  if (v == null) return false;
  final d = DateTime.tryParse(v.toString());
  return d != null;
}

int? _tryAge(dynamic fieldValue) {
  if (fieldValue == null) return null;
  final d = DateTime.tryParse(fieldValue.toString());
  if (d == null) return null;
  return _calculateAge(d);
}

final Map<String, bool Function(dynamic, dynamic)> _conditionOperators = {
  'equals': (a, b) {
    // Case-insensitive comparison for Yes/No values (nominee conditions)
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr == bStr;
  },
  'contains': (a, b) {
    if (a is List) return a.contains(b);
    // Handle checkbox boolean values (true/false) matching against string 'true'/'false'
    if (a is bool) {
      final bStr = b.toString().trim().toLowerCase();
      return (a && bStr == 'true') || (!a && bStr == 'false');
    }
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr.contains(bStr);
  },
  'notEquals': (a, b) {
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr != bStr;
  },
  'notequals': (a, b) {
    // Alias for notEquals (JSON uses lowercase variant)
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr != bStr;
  },
  'greaterthan': (a, b) {
    if (b == null || b.toString().isEmpty) return false;
    final age = _tryAge(a);
    if (age != null) return age >= (int.tryParse(b.toString()) ?? 0);
    return (double.tryParse(a?.toString() ?? '') ?? 0) >
        (double.tryParse(b.toString()) ?? 0);
  },
  'lessthan': (a, b) {
    if (b == null || b.toString().isEmpty) return false;
    final age = _tryAge(a);
    if (age != null) return age < (int.tryParse(b.toString()) ?? 0);
    return (double.tryParse(a?.toString() ?? '') ?? 0) <
        (double.tryParse(b.toString()) ?? 0);
  },
  'in': (a, b) {
    final list = b is List ? b : b.toString().split(',');
    return list.map((e) => e.toString()).contains(a.toString());
  },
};

typedef FieldVisibility = Map<String, bool>;
typedef FieldEditable = Map<String, bool>;
typedef FormDataMap = Map<String, dynamic>;

class ConditionalFlowState {
  final FieldVisibility fieldVisibility = {};
  final FormDataMap formData;
  final Map<String, String> fieldErrors = {};
  final Map<String, bool> fieldRequirements = {};
  final FieldEditable fieldEditable = {};

  ConditionalFlowState({FormDataMap? formData})
      : formData = Map<String, dynamic>.from(formData ?? {});
}

List<Map<String, dynamic>> getConditionsForField(
  List<dynamic>? conditionalFlow,
  String fieldName,
) {
  if (conditionalFlow == null) return [];
  return conditionalFlow
      .where((c) => c is Map && (c['field'] ?? '') == fieldName)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}

/// Nominee address fields controlled by each "same as my address" checkbox.
const Map<String, List<String>> kNomineeSameAsAddressGroups = {
  'nominee1_same_as_my_address': [
    'nominee1_add1',
    'nominee1_add2',
    'nominee_1_city',
    'nominee1_state',
    'nominee1_country',
    'nominee1_pincode',
  ],
  'nominee2_same_as_my_address': [
    'nominee2_add1',
    'nominee2_add2',
    'nominee_2_city',
    'nominee2_state',
    'nominee2_country',
    'nominee2_pincode',
  ],
  'nominee3_same_as_my_address': [
    'nominee3_add1',
    'nominee3_add2',
    'nominee3_city',
    'nominee3_state',
    'nominee3_country',
    'nominee3_pincode',
  ],
};

bool isNomineeSameAsMyAddressCheckbox(String? fieldName) {
  return fieldName != null && fieldName.contains('same_as_my_address');
}

bool isNomineeAddressTargetField(String? fieldName) {
  if (fieldName == null) return false;
  for (final targets in kNomineeSameAsAddressGroups.values) {
    if (targets.contains(fieldName)) return true;
  }
  return false;
}

bool isCheckboxCheckedValue(dynamic value) {
  if (value == true) return true;
  final s = value?.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

Map<String, String> _emptyUserAddressMap() => {
      'add1': '',
      'add2': '',
      'city': '',
      'state': '',
      'country': '',
      'pincode': '',
    };

Map<String, String> _cachedUserAddress = {};

/// API pre-fills these nominee fields with the applicant address (old on-load behaviour).
const Map<String, String> kNomineePrefillToAddressComponent = {
  'nominee1_add1': 'add1',
  'nominee1_add2': 'add2',
  'nominee_1_city': 'city',
  'nominee1_state': 'state',
  'nominee1_country': 'country',
  'nominee1_pincode': 'pincode',
};

const Map<String, List<String>> _userAddressAliases = {
  'add1': [
    'add1',
    'address_line1',
    'address_line_1',
    'address1',
    'addr_line1',
    'correspondence_add1',
    'corr_add1',
    'perm_add1',
    'permanent_add1',
    'current_add1',
    'communication_add1',
    'residence_add1',
    'residential_address',
    'address',
    'user_address',
    'permanent_address',
    'correspondence_address',
  ],
  'add2': [
    'add2',
    'address_line2',
    'address_line_2',
    'address2',
    'addr_line2',
    'correspondence_add2',
    'corr_add2',
    'perm_add2',
    'permanent_add2',
    'current_add2',
  ],
  'city': [
    'city',
    'aadhar_dist',
    'aadhar_city',
    'user_city',
    'perm_city',
    'permanent_city',
    'correspondence_city',
    'corr_city',
    'current_city',
    'residence_city',
  ],
  'state': [
    'state',
    'user_state',
    'perm_state',
    'permanent_state',
    'correspondence_state',
    'current_state',
  ],
  'country': [
    'country',
    'aadhar_country',
    'user_country',
    'perm_country',
    'permanent_country',
    'correspondence_country',
  ],
  'pincode': [
    'pincode',
    'pin_code',
    'zip',
    'zipcode',
    'postal_code',
    'perm_pincode',
    'permanent_pincode',
    'correspondence_pincode',
  ],
};

Map<String, String> _mergeAddressMaps(
  Map<String, String> base,
  Map<String, String> overlay,
) {
  final out = Map<String, String>.from(base);
  for (final e in overlay.entries) {
    if (e.value.trim().isNotEmpty) out[e.key] = e.value.trim();
  }
  return out;
}

bool _isExcludedAddressSourceKey(String key) {
  final k = key.toLowerCase();
  if (k.contains('nominee') || k.contains('guardian')) return true;
  if (k.contains('bank_') || k.startsWith('bank')) return true;
  if (k.contains('otp') || k.contains('stamp') || k.contains('proof')) {
    return true;
  }
  return false;
}

void _assignAddressComponent(
  Map<String, String> result,
  String fieldName,
  String value,
) {
  if (value.trim().isEmpty || _isExcludedAddressSourceKey(fieldName)) return;
  final k = fieldName.toLowerCase();

  if (result['add1']!.isEmpty &&
      (k == 'add1' ||
          k.endsWith('_add1') ||
          k.contains('address_line_1') ||
          k.contains('address_line1') ||
          (k.contains('address') &&
              !k.contains('2') &&
              !k.contains('email')))) {
    result['add1'] = value.trim();
    return;
  }
  if (result['add2']!.isEmpty &&
      (k == 'add2' ||
          k.endsWith('_add2') ||
          k.contains('address_line_2') ||
          k.contains('address_line2'))) {
    result['add2'] = value.trim();
    return;
  }
  if (result['city']!.isEmpty &&
      (k == 'city' || (k.endsWith('_city') && !k.contains('nominee')))) {
    result['city'] = value.trim();
    return;
  }
  if (result['state']!.isEmpty &&
      (k == 'state' || (k.endsWith('_state') && !k.contains('nominee')))) {
    result['state'] = value.trim();
    return;
  }
  if (result['country']!.isEmpty &&
      (k == 'country' || (k.endsWith('_country') && !k.contains('nominee')))) {
    result['country'] = value.trim();
    return;
  }
  if (result['pincode']!.isEmpty &&
      (k == 'pincode' ||
          k.contains('pincode') ||
          k.contains('pin_code') ||
          k.contains('zipcode') ||
          k.contains('postal'))) {
    result['pincode'] = value.trim();
  }
}

/// Reads the same address the API used to pre-fill nominee1 fields on page load.
Map<String, String> extractUserAddressFromNomineePrefill({
  required Map<String, dynamic> formData,
  List<dynamic>? stepFields,
}) {
  final result = _emptyUserAddressMap();
  for (final entry in kNomineePrefillToAddressComponent.entries) {
    final fromForm = formData[entry.key]?.toString().trim();
    if (fromForm != null && fromForm.isNotEmpty) {
      result[entry.value] = fromForm;
    }
  }
  if (stepFields != null) {
    for (final f in stepFields) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      final component = name != null ? kNomineePrefillToAddressComponent[name] : null;
      if (component == null) continue;
      final val = f['value']?.toString().trim();
      if (val != null && val.isNotEmpty) {
        result[component] = val;
      }
    }
  }
  return result;
}

Map<String, String> resolveUserAddressFromFormData(Map<String, dynamic> formData) {
  var result = _emptyUserAddressMap();
  for (final component in _userAddressAliases.keys) {
    for (final alias in _userAddressAliases[component]!) {
      if (_isExcludedAddressSourceKey(alias)) continue;
      final v = formData[alias];
      if (v != null && v.toString().trim().isNotEmpty) {
        result[component] = v.toString().trim();
        break;
      }
    }
  }
  for (final e in formData.entries) {
    _assignAddressComponent(result, e.key.toString(), e.value?.toString() ?? '');
  }
  return result;
}

Map<String, String> resolveAddressFromFieldDefinitions(List<dynamic> fields) {
  final result = _emptyUserAddressMap();
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString() ?? '';
    final val = f['value']?.toString().trim() ?? '';
    if (val.isEmpty) continue;
    final nomineeComponent = kNomineePrefillToAddressComponent[name];
    if (nomineeComponent != null) {
      result[nomineeComponent] = val;
    } else {
      _assignAddressComponent(result, name, val);
    }
  }
  return result;
}

void _deepScanAddressInto(Map<String, String> result, dynamic node, [int depth = 0]) {
  if (depth > 15 || node == null) return;
  if (node is Map) {
    for (final e in node.entries) {
      final key = e.key.toString();
      final val = e.value;
      if (val is! Map && val is! List) {
        final str = val?.toString() ?? '';
        final nomineeComponent = kNomineePrefillToAddressComponent[key];
        if (nomineeComponent != null && str.trim().isNotEmpty) {
          if (result[nomineeComponent]!.isEmpty) {
            result[nomineeComponent] = str.trim();
          }
        } else {
          _assignAddressComponent(result, key, str);
        }
      } else {
        _deepScanAddressInto(result, val, depth + 1);
      }
    }
  } else if (node is List) {
    for (final item in node) {
      _deepScanAddressInto(result, item, depth + 1);
    }
  }
}

/// Cache applicant address from form + get-context for nominee copy.
void refreshUserAddressCache({
  required Map<String, dynamic> formData,
  dynamic fieldsWithAuth,
  List<dynamic>? stepFields,
}) {
  // Priority 1: nominee1 API prefill (same source as old on-load address display).
  var merged = extractUserAddressFromNomineePrefill(
    formData: formData,
    stepFields: stepFields,
  );
  merged = _mergeAddressMaps(merged, resolveUserAddressFromFormData(formData));
  if (stepFields != null) {
    merged = _mergeAddressMaps(
      merged,
      resolveAddressFromFieldDefinitions(stepFields),
    );
  }
  if (fieldsWithAuth != null) {
    final scanned = _emptyUserAddressMap();
    _deepScanAddressInto(scanned, fieldsWithAuth);
    merged = _mergeAddressMaps(merged, scanned);
  }
  if (merged.values.any((v) => v.isNotEmpty)) {
    _cachedUserAddress = merged;
    debugPrint('[ConditionalForm] User address cache updated: $_cachedUserAddress');
  }
}

void clearUserAddressCache() => _cachedUserAddress = _emptyUserAddressMap();

Map<String, String> getUserAddressForNomineeCopy(Map<String, dynamic> formData) {
  if (_cachedUserAddress.values.any((v) => v.isNotEmpty)) {
    return Map<String, String>.from(_cachedUserAddress);
  }
  return resolveUserAddressFromFormData(formData);
}

String _stripFieldKeyPrefix(String key) =>
    key.trim().replaceFirst(RegExp(r'^\$'), '');

/// True when [s] looks like a field key (e.g. aadhar_address), not real address text.
/// Single-word values like "Pilibhit" or "India" are real city/country names, not keys.
bool looksLikeAddressFieldKey(String s) {
  final t = _stripFieldKeyPrefix(s);
  if (t.isEmpty) return true;
  if (t.contains(' ')) return false;
  final lower = t.toLowerCase();
  const bareComponentKeys = {
    'add1',
    'add2',
    'city',
    'state',
    'country',
    'pincode',
    'address',
    'dist',
    'district',
  };
  if (bareComponentKeys.contains(lower)) return true;
  if (t.contains('_')) return true;
  if (lower.startsWith('aadhar') ||
      lower.startsWith('nominee') ||
      lower.startsWith('guardian') ||
      lower.startsWith('perm_') ||
      lower.startsWith('corr_')) {
    return true;
  }
  return false;
}

/// Parses API `prepopulateValue` → source field name (e.g. aadhar_address).
String? parsePrepopulateSourceFieldName(dynamic prepopulateValue) {
  if (prepopulateValue == null) return null;
  if (prepopulateValue is String) {
    final s = prepopulateValue.trim();
    if (s.isEmpty || s.toLowerCase() == 'select') return null;
    return _stripFieldKeyPrefix(s);
  }
  if (prepopulateValue is List && prepopulateValue.isNotEmpty) {
    final first = prepopulateValue.first;
    if (first is Map) {
      final v = first['value']?.toString() ?? first['label']?.toString();
      if (v != null && v.trim().isNotEmpty) {
        return _stripFieldKeyPrefix(v);
      }
    }
  }
  return null;
}

/// Index field name → value from formData, step fields, and full get-context payload.
Map<String, String> buildFieldValueIndex({
  required Map<String, dynamic> formData,
  List<dynamic>? stepFields,
  dynamic fieldsWithAuth,
}) {
  final index = <String, String>{};

  void put(String? name, dynamic value) {
    if (name == null) return;
    final v = value?.toString().trim() ?? '';
    if (v.isEmpty || looksLikeAddressFieldKey(v)) return;
    index[name] = v;
  }

  for (final e in formData.entries) {
    put(e.key.toString(), e.value);
  }

  if (stepFields != null) {
    for (final f in stepFields) {
      if (f is! Map) continue;
      put(f['name']?.toString(), f['value']);
    }
  }

  void walk(dynamic node, [int depth = 0]) {
    if (depth > 20 || node == null) return;
    if (node is Map) {
      if (node.containsKey('name') && node.containsKey('value')) {
        put(node['name']?.toString(), node['value']);
      }
      for (final v in node.values) {
        walk(v, depth + 1);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item, depth + 1);
      }
    }
  }

  walk(fieldsWithAuth);
  return index;
}

/// Resolves one nominee field using API `value` then `prepopulateValue` source lookup.
String resolveNomineeTargetAddressValue({
  required String targetFieldName,
  required Map<String, dynamic> formData,
  List<dynamic>? stepFields,
  dynamic fieldsWithAuth,
}) {
  Map<dynamic, dynamic>? fieldDef;
  if (stepFields != null) {
    for (final f in stepFields) {
      if (f is Map && f['name']?.toString() == targetFieldName) {
        fieldDef = f;
        break;
      }
    }
  }

  final index = buildFieldValueIndex(
    formData: formData,
    stepFields: stepFields,
    fieldsWithAuth: fieldsWithAuth,
  );

  if (fieldDef != null) {
    final ownValue = fieldDef['value']?.toString().trim() ?? '';
    if (ownValue.isNotEmpty && !looksLikeAddressFieldKey(ownValue)) {
      return ownValue;
    }

    final sourceKey = parsePrepopulateSourceFieldName(fieldDef['prepopulateValue']);
    if (sourceKey != null) {
      final resolved = index[sourceKey] ??
          index['\$$sourceKey'] ??
          formData[sourceKey]?.toString().trim();
      if (resolved != null &&
          resolved.isNotEmpty &&
          !looksLikeAddressFieldKey(resolved)) {
        return resolved;
      }
    }
  }

  return '';
}

/// Fill or clear nominee address using each field's API prepopulateValue mapping.
void syncNomineeAddressFromSameAsCheckbox(
  Map<String, dynamic> formData,
  String checkboxName,
  dynamic checkboxValue, {
  List<dynamic>? stepFields,
  dynamic fieldsWithAuth,
}) {
  final targets = kNomineeSameAsAddressGroups[checkboxName];
  if (targets == null) return;

  if (isCheckboxCheckedValue(checkboxValue)) {
    for (final target in targets) {
      final val = resolveNomineeTargetAddressValue(
        targetFieldName: target,
        formData: formData,
        stepFields: stepFields,
        fieldsWithAuth: fieldsWithAuth,
      );
      formData[target] = val;
      debugPrint('[ConditionalForm] Same-as fill $target <- "$val"');
    }
  } else {
    for (final target in targets) {
      formData[target] = '';
    }
  }
}

/// On load: keep nominee address only when that nominee's checkbox is checked.
void clearNomineeAddressesWhenUnchecked(Map<String, dynamic> formData) {
  for (final entry in kNomineeSameAsAddressGroups.entries) {
    if (!isCheckboxCheckedValue(formData[entry.key])) {
      for (final field in entry.value) {
        formData[field] = '';
      }
    }
  }
}

/// Maps nominee address fields to user's address fields for prePopulate
String? _getNomineeAddressSourceField(String nomineeField) {
  // Map nominee1_add1 -> add1, address_line1, current_add1, etc.
  if (nomineeField.endsWith('_add1')) return 'add1';
  if (nomineeField.endsWith('_add2')) return 'add2';
  if (nomineeField.endsWith('_city') || nomineeField == 'nominee_1_city' || 
      nomineeField == 'nominee_2_city') {
    return 'city';
  }
  if (nomineeField.endsWith('_state')) return 'state';
  if (nomineeField.endsWith('_country')) return 'country';
  if (nomineeField.endsWith('_pincode')) return 'pincode';
  return null;
}

/// Gets address value from formData, trying multiple field name variants
String _getAddressValue(Map<String, dynamic> formData, String baseField) {
  // Try exact match first
  if (formData[baseField] != null && formData[baseField].toString().trim().isNotEmpty) {
    return formData[baseField].toString();
  }
  // Try common variants
  final variants = [
    baseField,
    'current_$baseField',
    'permanent_$baseField',
    '${baseField}_line1', // for add1
    'address_$baseField',
  ];
  for (final variant in variants) {
    final val = formData[variant];
    if (val != null && val.toString().trim().isNotEmpty) {
      return val.toString();
    }
  }
  return '';
}

ConditionalFlowState evaluateConditionalFlowForField(
  List<dynamic>? conditionalFlow,
  Map<String, dynamic> formData,
  String changedFieldName,
) {
  final state = ConditionalFlowState(
    formData: Map.from(formData),
  );

  final conditions = getConditionsForField(conditionalFlow, changedFieldName);

  for (final condition in conditions) {
    final fieldValue = formData[condition['field']];
    var inputValue = condition['inputValue'];
    final operator = condition['operator'] ?? 'equals';
    
    // For age-based conditions (DOB fields), use dateValue ONLY if inputValue is empty
    final dateType = condition['dateType'];
    final dateValue = condition['dateValue'];
    if (dateType != null && dateValue != null && 
        (inputValue == null || inputValue.toString().trim().isEmpty)) {
      inputValue = dateValue;
      debugPrint('[ConditionalForm] Age condition: field=${condition['field']}, operator=$operator, dateValue=$dateValue');
    }
    
    final opFn = _conditionOperators[operator];
    if (opFn == null) continue;
    
    final matches = opFn(fieldValue, inputValue);
    if (!matches) continue;
    
    debugPrint('[ConditionalForm] ✅ Condition matched: ${condition['field']} $operator $inputValue');

    final thenList = condition['then'];
    if (thenList is! List) continue;

    for (final action in thenList) {
      if (action is! Map) continue;
      final actionType = action['action']?.toString();
      final selected = action['selectedoption']?.toString();
      if (selected == null || selected.isEmpty) continue;

      switch (actionType) {
        case 'hide':
          state.fieldVisibility[selected] = false;
          debugPrint('[ConditionalForm] 🔒 Hide: $selected');
          break;
        case 'show':
          state.fieldVisibility[selected] = true;
          debugPrint('[ConditionalForm] 👁️ Show: $selected');
          break;
        case 'empty':
          state.formData[selected] = '';
          break;
        case 'prePopulate':
          var prePopValue = action['value']?.toString() ?? '';
          final triggerField = condition['field']?.toString() ?? '';
          // Copy user address only for "same as my address" checkbox rules.
          if (prePopValue.isEmpty &&
              triggerField.contains('same_as_my_address')) {
            final sourceField = _getNomineeAddressSourceField(selected);
            if (sourceField != null) {
              prePopValue = _getAddressValue(formData, sourceField);
            }
          }
          state.formData[selected] = prePopValue;
          break;
        case 'true':
          state.formData[selected] = true;
          break;
        case 'false':
          state.formData[selected] = false;
          break;
        case 'enable':
          final enableVal = action['enable'];
          state.fieldEditable[selected] = enableVal == true || enableVal == 1;
          break;
        case 'disable':
          state.fieldEditable[selected] = true;
          break;
      }
    }
  }

  return state;
}

List<String> getWatchedFields(List<dynamic>? conditionalFlow) {
  if (conditionalFlow == null) return [];
  final set = <String>{};
  for (final c in conditionalFlow) {
    if (c is Map && c['field'] != null) set.add(c['field'].toString());
  }
  return set.toList();
}

bool _jsonTruthy(dynamic v) {
  if (v == true) return true;
  if (v == false || v == null) return false;
  if (v is num) return v != 0;
  final s = v.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

/// Whether get-context / workflow lists this field for the end-user form.
///
/// Uses [adminFieldShow]: when true, the field is treated as visible even if
/// `fieldShow` is false. **Only use this on BP Wealth `personal_details`** (see
/// [kycFieldVisibleForFormStep]); on all other steps use [kycApiFieldVisibleStrictFieldShow]
/// so `fieldShow: false` stays hidden (old app behaviour).
bool kycApiFieldInitiallyVisible(Map<dynamic, dynamic> f) {
  if (_jsonTruthy(f['adminFieldShow'])) return true;
  final fs = f['fieldShow'];
  if (fs == null) return true;
  return _jsonTruthy(fs);
}

/// Visibility from `fieldShow` only — same as legacy `getVisibleFields` (`fieldShow ?? true`).
/// Does **not** look at `adminFieldShow` (admin-only fields must not appear on nominee etc.).
bool kycApiFieldVisibleStrictFieldShow(Map<dynamic, dynamic> f) {
  final fs = f['fieldShow'];
  if (fs == null) return true;
  return _jsonTruthy(fs);
}

/// BP Wealth `personal_details` only: standing-instruction style questions that the
/// web UI shows even when `fieldShow` is false (expandable on web). Do not use globally.
const Set<String> kBpWealthPersonalDetailsStandingFieldNames = {
  'electronic_transaction',
  'annual_report',
  'receive_contract',
  'directly_bank_account',
  'credit_account',
  'rta',
  'dp_accept',
  'sebi_3years',
  'debitbalance',
  // Web "Standing Instructions" accordion — common API name variants
  'holding_cum_transaction_statement',
  'holding_transaction_statement',
  'transaction_statement_frequency',
  'cum_holding_statement',
  'holding_statement_frequency',
  'statement_frequency',
  'cum_transaction_statement',
  'dis_booklet',
  'dis_book',
  'dis',
  'delivery_instruction_slip',
  'dis_slip',
};

/// BP Wealth personal_details — fields in the **main** block (web 2nd screenshot only).
const Set<String> kBpWealthPersonalDetailsMainScreenFieldNames = {
  'fathers_name',
  'father_name',
  'father',
  'fathername',
  'mothers_name',
  'mother_name',
  'mother',
  'mothername',
  'gender',
  'marital_status',
  'maritalstatus',
  'education',
  'annual_income',
  'income',
  'gross_annual_income',
  'annualincome',
  'trading_experience',
  'tradingexperience',
  'politically_exposed',
  'pep',
  'political_exposed',
  'occupation',
  'citizen_of_india',
  'citizen',
  'indian_citizen',
  'citizenindia',
  'ddpi',
  'execute_ddpi',
  'demat_debit_pledge',
  'tax_residency',
  'tax_residency_outside_india',
  'taxresidency',
  'penny_drop_condition',
};

/// DP / tariff consent checkbox — **outside** Standing Instructions accordion (web design).
bool bpWealthPersonalDetailsTariffConsentCheckboxField(Map<dynamic, dynamic> f) {
  if ((f['type']?.toString() ?? '').toLowerCase() != 'checkbox') return false;
  final dn = (f['displayName']?.toString() ?? '').toLowerCase();
  return dn.contains('standing instruction') || dn.contains('tariff structure');
}

/// Combined user-facing copy (API sometimes uses [label] / [title] instead of [displayName]).
String bpWealthFieldUserFacingTextLower(Map<dynamic, dynamic> f) {
  final buf = StringBuffer();
  for (final k in ['displayName', 'label', 'title', 'placeholder', 'question']) {
    final s = f[k]?.toString().trim();
    if (s == null || s.isEmpty) continue;
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(s);
  }
  return buf.toString().toLowerCase();
}

/// DDPI (Demat Debit Pledge Instructions) — field [name] varies across workflows.
bool isDdpiFormField(Map<dynamic, dynamic> f) {
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl == 'ddpi' ||
      nl == 'execute_ddpi' ||
      nl == 'demat_debit_pledge' ||
      nl.contains('ddpi') ||
      nl.contains('demat_debit')) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(f);
  return dn.contains('ddpi') ||
      (dn.contains('demat') && dn.contains('debit') && dn.contains('pledge'));
}

/// User selected Yes / affirmative for DDPI (radio, select, or checkbox).
bool isDdpiAffirmativeValue(dynamic value) {
  if (value == null) return false;
  if (value is bool) return value;
  final s = value.toString().trim().toLowerCase();
  if (s.isEmpty) return false;
  return s == 'yes' || s == 'y' || s == 'true' || s == '1' || s.startsWith('yes');
}

/// KRA review step — fetched KRA data is display-only (live web parity).
bool isKraDetailsStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'kradetails' || l == 'kradetails';
}

/// "Do You Want to continue with KRA details?" — user must be able to select Yes/No.
bool kraDetailsContinueWithKraChoiceField(Map<dynamic, dynamic> field) {
  final nl = (field['name']?.toString() ?? '').toLowerCase();
  if (nl == 'kradetail' ||
      nl == 'kra_detail' ||
      nl == 'continue_with_kra' ||
      (nl.contains('kra') && nl.contains('continue'))) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(field);
  return dn.contains('continue') && dn.contains('kra');
}

/// On [isKraDetailsStep], fetched KRA inputs are read-only; [kraDetailsContinueWithKraChoiceField] stays editable.
bool kraDetailsFormFieldReadOnly(Map<dynamic, dynamic> field) {
  if (kraDetailsContinueWithKraChoiceField(field)) return false;
  final type = (field['type']?.toString() ?? '').toLowerCase();
  return type != 'button' && type != 'hidden';
}

/// DigiLocker review step — Aadhaar/PAN data fetched from DigiLocker is display-only.
bool isDigilockerStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'digilocker' || l == 'digilocker';
}

/// On [isDigilockerStep], all visible inputs (name, DOB, address, photo, etc.) are read-only.
bool digilockerFormFieldReadOnly(Map<dynamic, dynamic> field) {
  final type = (field['type']?.toString() ?? '').toLowerCase();
  return type != 'button' && type != 'hidden';
}

bool isAadharImageFieldName(String? name) {
  final n = (name ?? '').toLowerCase();
  return n == 'aadhar_image' || n == 'aadhaar_image';
}

/// Reads `user-details` payload (`{ data: { ... } }` or flat map).
Map<String, dynamic>? userDetailsDataMap(dynamic userDetails) {
  if (userDetails is! Map) return null;
  final data = userDetails['data'];
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  return Map<String, dynamic>.from(userDetails);
}

/// Best Aadhaar photo for DigiLocker card: user-details → get-context `value` → formData.
/// `adharimg` is legacy fallback when `aadhar_image` is empty.
String? resolveDigilockerAadharImageRaw({
  dynamic userDetails,
  dynamic fieldValue,
  dynamic formValue,
}) {
  String? pick(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  final ud = userDetailsDataMap(userDetails);
  final fromUser =
      pick(ud?['aadhar_image']) ?? pick(ud?['adharimg']) ?? pick(ud?['aadhaar_image']);

  return fromUser ?? pick(fieldValue) ?? pick(formValue);
}

/// Cache-bust version for remote bucket URLs (e.g. after new DigiLocker fetch).
String? digilockerAadharImageCacheBustVersion(dynamic userDetails) {
  final ud = userDetailsDataMap(userDetails);
  if (ud == null) return null;
  for (final key in [
    'digilocker_timestamp',
    'detailspan_timestamp',
    'digitrans',
  ]) {
    final v = ud[key]?.toString().trim();
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

/// Appends `v=` query param so [Image.network] reloads after DigiLocker refresh.
String cacheBustDocumentUrl(String url, {String? version}) {
  if (version == null || version.trim().isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  final q = Map<String, String>.from(uri.queryParameters);
  q['v'] = version.trim();
  return uri.replace(queryParameters: q).toString();
}

/// Fetched-data review steps where most fields must not be edited (KRA, DigiLocker).
bool fetchedDataReviewFieldReadOnly(
  String? position,
  String? pageLabel,
  Map<dynamic, dynamic> field,
) {
  if (isKraDetailsStep(position, pageLabel)) {
    return kraDetailsFormFieldReadOnly(field);
  }
  if (isDigilockerStep(position, pageLabel)) {
    return digilockerFormFieldReadOnly(field);
  }
  return false;
}

/// "How frequently do you want to receive your holding cum Transaction statement?" —
/// backend [name] varies; match by user-facing text and common [name] substrings.
bool bpWealthPersonalDetailsHoldingStatementFrequencyField(
  Map<dynamic, dynamic> f,
) {
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl.contains('holding') &&
      nl.contains('statement') &&
      (nl.contains('transaction') ||
          nl.contains('cum') ||
          nl.contains('freq') ||
          nl.contains('stmt'))) {
    return true;
  }

  final dn = bpWealthFieldUserFacingTextLower(f);
  if (dn.isEmpty) return false;

  final hasHolding = dn.contains('holding');
  final hasStatement = dn.contains('statement');
  final hasTransaction = dn.contains('transaction');
  final hasCum = dn.contains('cum');
  final hasFreq = dn.contains('frequen') || dn.contains('how often');

  if (hasHolding &&
      hasStatement &&
      (hasTransaction || hasCum || hasFreq || dn.contains('receive'))) {
    return true;
  }
  if (hasStatement &&
      hasFreq &&
      (hasTransaction || hasCum || hasHolding || dn.contains('sebi'))) {
    return true;
  }
  return false;
}

/// Fields rendered **inside** the Standing Instructions expandable only (not tariff consent).
bool bpWealthPersonalDetailsStandingSectionField(Map<dynamic, dynamic> f) {
  final name = f['name']?.toString();
  if (name != null &&
      kBpWealthPersonalDetailsStandingFieldNames.contains(name)) {
    return true;
  }
  return bpWealthPersonalDetailsHoldingStatementFrequencyField(f);
}

bool bpWealthPersonalDetailsHideDobField(
  String? company,
  String? position,
  String? pageLabel,
  String? name,
) {
  if (!bpWealthPersonalDetailsStep(company, position, pageLabel)) return false;
  if (name == null) return false;
  final n = name.toLowerCase();
  if (n == 'dob') return true;
  if (n.contains('date_of_birth')) return true;
  if (n.contains('birth_date')) return true;
  if (n.contains('dob')) return true;
  return false;
}

bool bpWealthPersonalDetailsStep(
  String? company,
  String? position,
  String? pageLabel,
) {
  if (company == null) return false;
  if (company.toLowerCase().trim() != 'bpwealth') return false;
  final pos = position?.toLowerCase() ?? '';
  final label = pageLabel?.toLowerCase() ?? '';
  return pos == 'personal_details' || label == 'personal_details';
}

bool bpWealthPersonalDetailsForceShowStandingField(
  String? company,
  String? position,
  String? pageLabel,
  String? fieldName,
) {
  if (fieldName == null) return false;
  if (!bpWealthPersonalDetailsStep(company, position, pageLabel)) return false;
  return kBpWealthPersonalDetailsStandingFieldNames.contains(fieldName);
}

/// Same as [bpWealthPersonalDetailsForceShowStandingField] but includes holding/statement frequency by display text.
bool bpWealthPersonalDetailsForceShowStandingMap(
  String? company,
  String? position,
  String? pageLabel,
  Map<dynamic, dynamic> f,
) {
  if (!bpWealthPersonalDetailsStep(company, position, pageLabel)) return false;
  final name = f['name']?.toString();
  if (name != null &&
      kBpWealthPersonalDetailsStandingFieldNames.contains(name)) {
    return true;
  }
  return bpWealthPersonalDetailsHoldingStatementFrequencyField(f);
}

/// API visibility plus BP Wealth personal-details standing override (fieldShow false).
bool kycFieldVisibleForFormStep(
  Map<dynamic, dynamic> f, {
  String? company,
  String? position,
  String? pageLabel,
}) {
  final name = f['name']?.toString();
  if (bpWealthPersonalDetailsHideDobField(company, position, pageLabel, name)) {
    return false;
  }
  if (bpWealthPersonalDetailsStep(company, position, pageLabel)) {
    if (bpWealthPersonalDetailsTariffConsentCheckboxField(f)) {
      return true;
    }
    if (bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) {
      return kycApiFieldInitiallyVisible(f) ||
          bpWealthPersonalDetailsForceShowStandingMap(
            company,
            position,
            pageLabel,
            f,
          );
    }
    if (name == null) return false;
    if (kBpWealthPersonalDetailsMainScreenFieldNames.contains(name)) {
      // Web main grid only — show even if API hid the field.
      return true;
    }
    if (kBpWealthPersonalDetailsStandingFieldNames.contains(name)) {
      return kycApiFieldInitiallyVisible(f) ||
          bpWealthPersonalDetailsForceShowStandingField(
            company,
            position,
            pageLabel,
            name,
          );
    }
    return false;
  }
  // Non–personal_details: never honour adminFieldShow for UI (avoids extra fields on nominee etc.).
  return kycApiFieldVisibleStrictFieldShow(f);
}

/// `kyc-post-v2` body: only fields visible on the current step (web parity).
/// Drops stale keys from other steps (e.g. empty nominee_* on `pan10`).
Map<String, dynamic> filterKycPostV2BodyForStep({
  required Map<String, dynamic> data,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
  bool omitEmptyStrings = true,
}) {
  if (fields == null || fields.isEmpty) return data;

  final visible = getVisibleFields(
    fields,
    runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );

  final allowed = <String>{};
  for (final f in visible) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null || name.isEmpty) continue;
    final type = (f['type']?.toString() ?? '').toLowerCase();
    if (type == 'button' || type == 'hidden') continue;
    allowed.add(name);
  }

  if (allowed.isEmpty) return data;

  final out = <String, dynamic>{};
  for (final name in allowed) {
    if (!data.containsKey(name)) continue;
    final v = data[name];
    if (v == null) continue;
    if (omitEmptyStrings && v is String && v.trim().isEmpty) continue;
    out[name] = v;
  }
  return out;
}

List<dynamic> getVisibleFields(
  List<dynamic> fields,
  Map<String, bool> fieldVisibility, {
  String? company,
  String? position,
  String? pageLabel,
}) {
  return fields.where((f) {
    if (f is! Map) return false;
    final name = f['name']?.toString();
    final show = kycFieldVisibleForFormStep(
      f,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
    if (name == null) {
      if (!bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) return false;
      return show;
    }
    // Match home_page: conditional flow override wins over fieldShow.
    final dynamicVisibility = fieldVisibility[name];
    return dynamicVisibility ?? show;
  }).toList();
}

List<dynamic> getEditableFields(
  List<dynamic> fields,
  Map<String, bool>? fieldEditable,
) {
  if (fieldEditable == null) return [];
  return fields.where((f) {
    if (f is! Map) return false;
    final name = f['name']?.toString();
    if (name == null) return false;
    return fieldEditable[name] == true;
  }).toList();
}

ConditionalFlowState evaluateConditionalFlow(
  List<dynamic>? conditionalFlow,
  Map<String, dynamic> formData,
) {
  final state = ConditionalFlowState(formData: formData);
  if (conditionalFlow == null) return state;

  for (final condition in conditionalFlow) {
    if (condition is! Map) continue;
    final fieldValue = formData[condition['field']];
    var inputValue = condition['inputValue'];
    final operator = condition['operator'] ?? 'equals';
    
    // For age-based conditions (DOB fields), use dateValue ONLY if inputValue is empty
    final dateType = condition['dateType'];
    final dateValue = condition['dateValue'];
    if (dateType != null && dateValue != null && 
        (inputValue == null || inputValue.toString().trim().isEmpty)) {
      inputValue = dateValue;
    }
    
    final opFn = _conditionOperators[operator];
    if (opFn == null || !opFn(fieldValue, inputValue)) continue;

    final thenList = condition['then'];
    if (thenList is! List) continue;

    for (final action in thenList) {
      if (action is! Map) continue;
      final actionType = action['action']?.toString();
      final selected = action['selectedoption']?.toString();
      if (selected == null || selected.isEmpty) continue;

      switch (actionType) {
        case 'hide':
          state.fieldVisibility[selected] = false;
          debugPrint('[ConditionalForm] 🔒 Hide: $selected');
          break;
        case 'show':
          state.fieldVisibility[selected] = true;
          debugPrint('[ConditionalForm] 👁️ Show: $selected');
          break;
        case 'empty':
          state.formData[selected] = '';
          break;
        case 'prePopulate':
          var prePopValue = action['value']?.toString() ?? '';
          final triggerField = condition['field']?.toString() ?? '';
          if (prePopValue.isEmpty &&
              triggerField.contains('same_as_my_address')) {
            final sourceField = _getNomineeAddressSourceField(selected);
            if (sourceField != null) {
              prePopValue = _getAddressValue(formData, sourceField);
            }
          }
          state.formData[selected] = prePopValue;
          break;
        case 'true':
          state.formData[selected] = true;
          break;
        case 'false':
          state.formData[selected] = false;
          break;
        case 'enable':
          final enableVal = action['enable'];
          state.fieldEditable[selected] = enableVal == true || enableVal == 1;
          break;
        case 'disable':
          state.fieldEditable[selected] = true;
          break;
      }
    }
  }

  return state;
}
