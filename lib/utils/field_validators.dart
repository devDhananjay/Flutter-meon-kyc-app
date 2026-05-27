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

bool isNomineeKycStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'nominee' || l == 'nominee';
}

/// `additional_nominee` / `additional_nominee_second` workflow steps.
bool isAdditionalNomineeKycStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p.contains('additional_nominee') || l.contains('additional_nominee');
}

bool isNomineeExtendedUiStep(String? position, String? pageLabel) {
  return isNomineeKycStep(position, pageLabel) ||
      isAdditionalNomineeKycStep(position, pageLabel);
}

bool _addNomineeSelectedYes(Map<String, dynamic> formData) {
  return _isKycYesNoValue(formData['add_nominee']);
}

/// Checkbox — adds nominee 2 block.
const String kAddSecondNomineeField = 'add_2_nominee';

/// Checkbox — adds nominee 3 block (web `AddNominee.jsx`).
const String kAddThirdNomineeField = 'add_3_nominee';

/// API field: select "Do you want to add more nominee" (`fieldShow: false`, conditional).
const String kExtraNomineeField = 'extra_nominee';

/// Main nominee step (`nominee12`): hidden total of slot 1–3 percentages.
const String kTotalNomineePercentageField = 'total_nominee_percentage';

/// Additional nominee step (`additional_nominee13`): carries forward prior total.
const String kRemainNomineePercentField = 'remain_nominee_percent';

const Map<String, int> _kNomineeWordSlotNumbers = {
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
};

/// Frozen on step load — prior % from earlier steps only (not this step's typing).
double? _lockedPriorNomineeAllocatedPercent;

void lockPriorNomineeAllocatedPercentForStep(List<dynamic>? fields) {
  _lockedPriorNomineeAllocatedPercent =
      readPriorNomineeAllocatedPercentFromApi(fields);
}

void clearLockedPriorNomineeAllocatedPercent() {
  _lockedPriorNomineeAllocatedPercent = null;
}

/// Legacy alias; prefer [kExtraNomineeField].
const List<String> kAddMoreNomineeDropdownCandidates = [
  kExtraNomineeField,
  'add_3_nominee',
];

const List<String> _kDefaultNomineePercentageFieldNames = [
  'nominee_1_percentage',
  'nominee_2_percentage',
  'nominee3_percentage',
  'nominee_3_percentage',
  // Additional nominees (when present) may use different slot names.
  // We keep only common variants here; when `fields` is non-null, resolver
  // will discover the exact names from API.
  'nominee_4_percentage',
  'nominee_5_percentage',
  'nominee6_percentage',
];

/// Slot number from API name (`nominee_1_percentage`, `nominee3_percentage`,
/// `nominee_4_percentage`, `nominee6_percentage`, etc.).
int? nomineePercentageSlotIndex(String fieldName) {
  final compact = fieldName.toLowerCase().replaceAll('_', '');
  // Examples after compaction:
  // - nominee_4_percentage -> nominee4percentage
  // - nominee6_percentage  -> nominee6percentage
  final m = RegExp(r'nominee(\d+)percentage').firstMatch(compact);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  if (n == null) return null;
  return n;
}

bool isNomineePercentageFieldName(String name) {
  return nomineePercentageSlotIndex(name) != null;
}

/// Percentage fields from get-context (API uses `nominee3_percentage`, not `nominee_3_percentage`).
List<String> resolveNomineePercentageFieldNames(List<dynamic>? fields) {
  if (fields == null) return List<String>.from(_kDefaultNomineePercentageFieldNames);
  final bySlot = <int, String>{};
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString() ?? '';
    final slot = nomineePercentageSlotIndex(name);
    if (slot == null) continue;
    bySlot[slot] = name;
  }
  if (bySlot.isEmpty) {
    return ['nominee_1_percentage', 'nominee_2_percentage', 'nominee3_percentage'];
  }
  final keys = bySlot.keys.toList()..sort();
  return keys.map((k) => bySlot[k]!).toList();
}

bool _isKycYesNoValue(dynamic value) {
  if (value == true) return true;
  final v = value?.toString().trim().toLowerCase();
  return v == 'yes' || v == 'y' || v == 'true' || v == '1';
}

bool _isKycNoValue(dynamic value) {
  if (value == false) return true;
  final v = value?.toString().trim().toLowerCase();
  return v == 'no' || v == 'n' || v == 'false' || v == '0';
}

bool isNomineeAddMoreDropdownField(String name) {
  return kAddMoreNomineeDropdownCandidates.contains(name);
}

String? resolveAddMoreNomineeDropdownFieldName(List<dynamic>? fields) {
  if (fields == null) return null;
  for (final candidate in kAddMoreNomineeDropdownCandidates) {
    for (final f in fields) {
      if (f is Map && f['name']?.toString() == candidate) return candidate;
    }
  }
  for (final f in fields) {
    if (f is! Map) continue;
    if (f['type']?.toString().toLowerCase() != 'select') continue;
    final label = (f['displayName'] ?? f['name'] ?? '').toString().toLowerCase();
    if (label.contains('add more') && label.contains('nominee')) {
      return f['name']?.toString();
    }
  }
  return null;
}

List<String> resolveAddMoreNomineeDropdownFieldNames(List<dynamic>? fields) {
  final names = <String>[];
  for (final candidate in kAddMoreNomineeDropdownCandidates) {
    if (fields == null) continue;
    for (final f in fields) {
      if (f is Map && f['name']?.toString() == candidate) {
        names.add(candidate);
        break;
      }
    }
  }
  final resolved = resolveAddMoreNomineeDropdownFieldName(fields);
  if (resolved != null && !names.contains(resolved)) names.add(resolved);
  return names;
}

/// Re-run all nominee % rules on these field changes.
bool shouldSyncNomineePercentageField(String name) {
  return isNomineePercentageFieldName(name) ||
      name == kAddSecondNomineeField ||
      name == kAddThirdNomineeField ||
      name == kExtraNomineeField ||
      isAdditionalNomineeAddCheckbox(name) ||
      name == 'add_nominee';
}

/// Any nominee field that should trigger a full UI rules pass.
bool shouldRunNomineeRealtimeUiSync(String name) {
  if (shouldSyncNomineePercentageField(name)) return true;
  final n = name.toLowerCase();
  if (n.contains('proof_type') && (n.contains('nominee') || n.contains('guardian'))) {
    return true;
  }
  if (n.contains('nominee') && n.contains('dob')) return true;
  if (n.contains('guardian') && n.contains('dob')) return true;
  if (isGuardian1Field(name) ||
      isGuardian2Field(name) ||
      isGuardian3Field(name) ||
      guardianSlotFromFieldName(name) != null ||
      name.startsWith('guardian_same_as_address')) {
    return true;
  }
  if (isNomineeSameAsMyAddressCheckbox(name)) return true;
  return false;
}

/// Values owned by [syncNomineePercentageSideEffects] — not conditional `false`/`empty`.
bool isNomineeSyncProtectedFormField(String name) {
  return name == kAddSecondNomineeField ||
      name == kAddThirdNomineeField ||
      name == kRemainNomineePercentField ||
      isAdditionalNomineeAddCheckbox(name) ||
      isNomineePercentageFieldName(name);
}

void clearNomineeSyncProtectedEditableOverrides({
  required Map<String, bool> fieldEditable,
  required List<dynamic>? fields,
}) {
  for (final n in resolveNomineePercentageFieldNames(fields)) {
    fieldEditable.remove(n);
  }
  fieldEditable.remove(kAddSecondNomineeField);
  fieldEditable.remove(kAddThirdNomineeField);
}

bool isNomineePercentageFieldActive(
  String fieldName,
  List<dynamic>? fields,
  Map<String, bool> runtimeFieldVisibility, {
  Map<String, dynamic>? formData,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (fields == null || !isNomineePercentageFieldName(fieldName)) {
    return false;
  }

  final slot = nomineePercentageSlotIndex(fieldName);
  if (formData != null && slot != null) {
    if (slot == 1 && _addNomineeSelectedYes(formData)) return true;
    if (slot == 2 && isCheckboxCheckedValue(formData[kAddSecondNomineeField])) {
      return true;
    }
    if (slot == 3) {
      if (_nomineeTier3Blocked(formData, fields)) return false;
      if (isCheckboxCheckedValue(formData[kAddThirdNomineeField])) return true;
    }
  }

  final def = _findFieldDefByName(fields, fieldName);
  if (def == null) return false;
  final show = kycFieldVisibleForFormStep(
    def,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );
  final dynamicVisibility = runtimeFieldVisibility[fieldName];
  return dynamicVisibility ?? show;
}

/// Sum % only for nominees the user has on screen (1, 2, or 3 — not hidden slots).
double sumActiveNomineePercentages({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  final pctFields = resolveNomineePercentageFieldNames(fields);
  var total = 0.0;
  for (final name in pctFields) {
    if (!isNomineePercentageFieldActive(
      name,
      fields,
      runtimeFieldVisibility,
      formData: formData,
      company: company,
      position: position,
      pageLabel: pageLabel,
    )) {
      continue;
    }
    total += _parseNomineePercentageValue(formData[name]) ?? 0;
  }
  return total;
}

/// Step total of nominee percentages based on step field visibility (works for slot 4+ too).
double sumVisibleNomineePercentagesForStep({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (fields == null) return 0.0;
  var total = 0.0;
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null || name.isEmpty) continue;
    if (!isNomineePercentageFieldName(name)) continue;
    final show = kycFieldVisibleForFormStep(
      f,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
    final visible = runtimeFieldVisibility[name] ?? show;
    if (!visible) continue;
    total += _parseNomineePercentageValue(formData[name]) ?? 0;
  }
  return total;
}

/// Payload ke andar jo nominee percentage keys present hain (active/visible ke alawa bhi)
/// unka sum. This is robust for steps where `fieldShow: false` makes
/// runtime visibility unreliable.
double sumNomineePercentagesFromPayload(Map<String, dynamic> formData) {
  double total = 0.0;
  for (final entry in formData.entries) {
    final k = entry.key;
    if (!isNomineePercentageFieldName(k)) continue;
    total += _parseNomineePercentageValue(entry.value) ?? 0.0;
  }
  return total;
}

/// Sum only percentage fields defined on the current step (avoids stale keys from other steps).
double sumNomineePercentagesForStepFields({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
}) {
  if (fields == null || fields.isEmpty) {
    return sumNomineePercentagesFromPayload(formData);
  }
  var total = 0.0;
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null || name.isEmpty) continue;
    if (!isNomineePercentageFieldName(name)) continue;
    total += _parseNomineePercentageValue(formData[name]) ?? 0.0;
  }
  return total;
}

dynamic _formatNomineePercentTotalForApi(double total) {
  if ((total - total.roundToDouble()).abs() < 0.0001) {
    return total.round();
  }
  return double.parse(total.toStringAsFixed(2));
}

/// Prior % from get-context field `value` only (not live formData).
double readPriorNomineeAllocatedPercentFromApi(List<dynamic>? fields) {
  final remain =
      _findFieldDefByName(fields, kRemainNomineePercentField)?['value'];
  final total =
      _findFieldDefByName(fields, kTotalNomineePercentageField)?['value'];
  return _parseNomineePercentageValue(remain) ??
      _parseNomineePercentageValue(total) ??
      0.0;
}

/// Already-allocated nominee % from earlier steps (frozen at additional-nominee step load).
double readPriorNomineeAllocatedPercent({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
}) {
  if (_lockedPriorNomineeAllocatedPercent != null) {
    return _lockedPriorNomineeAllocatedPercent!;
  }
  final fromApi = readPriorNomineeAllocatedPercentFromApi(fields);
  if (fromApi > 0) return fromApi;
  return _parseNomineePercentageValue(
        formData[kTotalNomineePercentageField],
      ) ??
      0.0;
}

/// How much % the user may still assign on this additional-nominee step.
double nomineeRemainingBudgetOnAdditionalStep({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
}) {
  final prior = readPriorNomineeAllocatedPercent(
    formData: formData,
    fields: fields,
  );
  return (100.0 - prior).clamp(0.0, 100.0);
}

bool isAdditionalNomineeAddCheckbox(String name) {
  return RegExp(r'^add_\d+_nominee$').hasMatch(name);
}

/// `add_5_nominee` → slot 5, sorted by slot.
List<MapEntry<int, String>> resolveAdditionalAddNomineeCheckboxes(
  List<dynamic>? fields,
) {
  final out = <MapEntry<int, String>>[];
  if (fields == null) return out;
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString() ?? '';
    final m = RegExp(r'^add_(\d+)_nominee$').firstMatch(name);
    if (m == null) continue;
    final slot = int.tryParse(m.group(1)!);
    if (slot == null) continue;
    out.add(MapEntry(slot, name));
  }
  out.sort((a, b) => a.key.compareTo(b.key));
  return out;
}

List<int> listNomineePercentageSlotsOnStep(List<dynamic>? fields) {
  final slots = <int>{};
  if (fields == null) return [];
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null) continue;
    final slot = nomineePercentageSlotIndex(name);
    if (slot != null) slots.add(slot);
  }
  final list = slots.toList()..sort();
  return list;
}

bool isNomineeSlotActiveOnAdditionalStep({
  required int slot,
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required int baseSlot,
  List<MapEntry<int, String>>? addCheckboxes,
}) {
  if (slot == baseSlot) return true;
  final adds =
      addCheckboxes ?? resolveAdditionalAddNomineeCheckboxes(fields);
  for (final e in adds) {
    if (e.key == slot) {
      return isCheckboxCheckedValue(formData[e.value]);
    }
  }
  return false;
}

double sumActiveAdditionalNomineeStepPercentages({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  final fieldList = fields;
  if (fieldList == null) return 0.0;
  final slots = listNomineePercentageSlotsOnStep(fieldList);
  if (slots.isEmpty) return 0.0;
  final baseSlot = slots.first;
  final adds = resolveAdditionalAddNomineeCheckboxes(fieldList);
  var total = 0.0;
  for (final slot in slots) {
    if (!isNomineeSlotActiveOnAdditionalStep(
      slot: slot,
      formData: formData,
      fields: fieldList,
      baseSlot: baseSlot,
      addCheckboxes: adds,
    )) {
      continue;
    }
    final name = _nomineePercentageFieldForSlot(fieldList, slot);
    if (name == null) continue;
    if (!isNomineePercentageFieldActive(
      name,
      fieldList,
      runtimeFieldVisibility,
      formData: formData,
      company: company,
      position: position,
      pageLabel: pageLabel,
    )) {
      continue;
    }
    total += _parseNomineePercentageValue(formData[name]) ?? 0.0;
  }
  return total;
}

double _cumulativeNomineePercentBeforeSlot({
  required double priorAllocated,
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required List<int> pctSlots,
  required int beforeSlot,
  required int baseSlot,
}) {
  final adds = resolveAdditionalAddNomineeCheckboxes(fields);
  var sum = priorAllocated;
  for (final slot in pctSlots) {
    if (slot >= beforeSlot) break;
    if (!isNomineeSlotActiveOnAdditionalStep(
      slot: slot,
      formData: formData,
      fields: fields,
      baseSlot: baseSlot,
      addCheckboxes: adds,
    )) {
      continue;
    }
    final name = _nomineePercentageFieldForSlot(fields, slot);
    if (name == null) continue;
    sum += _parseNomineePercentageValue(formData[name]) ?? 0.0;
  }
  return sum;
}

void _hideAllNomineeSlotFields(
  List<dynamic>? fields,
  Map<String, bool> runtimeFieldVisibility,
  int slot,
) {
  if (fields == null) return;
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null) continue;
    if (nomineeSlotFromFieldName(name) != slot) continue;
    if (isAdditionalNomineeAddCheckbox(name) ||
        isNomineeBackendOnlyField(name) ||
        name == kRemainNomineePercentField) {
      continue;
    }
    runtimeFieldVisibility[name] = false;
  }
}

void _applyAdditionalNomineeAddButtonsVisibility({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
}) {
  if (fields == null) return;
  final prior = readPriorNomineeAllocatedPercent(
    formData: formData,
    fields: fields,
  );
  final pctSlots = listNomineePercentageSlotsOnStep(fields);
  if (pctSlots.isEmpty) return;
  final baseSlot = pctSlots.first;
  final addChecks = resolveAdditionalAddNomineeCheckboxes(fields);

  runtimeFieldVisibility[kRemainNomineePercentField] = false;

  if (_nomineeShareSumAtLeast100(prior)) {
    for (final e in addChecks) {
      runtimeFieldVisibility[e.value] = false;
    }
    return;
  }

  for (final entry in addChecks) {
    final targetSlot = entry.key;
    final checkbox = entry.value;
    final prevSlot = targetSlot - 1;
    final prevEntered =
        _nomineeSlotPercentageEntered(formData, fields, prevSlot);
    final prevCheckbox = 'add_${prevSlot}_nominee';
    final prevAddOk = prevSlot == baseSlot ||
        isCheckboxCheckedValue(formData[prevCheckbox]);
    final sumBefore = _cumulativeNomineePercentBeforeSlot(
      priorAllocated: prior,
      formData: formData,
      fields: fields,
      pctSlots: pctSlots,
      beforeSlot: targetSlot,
      baseSlot: baseSlot,
    );
    final showAdd =
        prevEntered && prevAddOk && !_nomineeShareSumAtLeast100(sumBefore);

    if (_findFieldDefByName(fields, checkbox) == null) continue;
    runtimeFieldVisibility[checkbox] = showAdd;

    final checked = isCheckboxCheckedValue(formData[checkbox]);
    if (!checked) {
      _hideAllNomineeSlotFields(fields, runtimeFieldVisibility, targetSlot);
      final pct = _nomineePercentageFieldForSlot(fields, targetSlot);
      if (pct != null) formData.remove(pct);
      continue;
    }
    // Checked: API conditional flow controls show/hide — do not override visibility.
  }
}

/// Sets `total_nominee_percentage` (main nominee) or cumulative `remain_nominee_percent`
/// (prior allocated + this step) before kyc-post-v2.
void syncNomineeStepPercentTotalsSubmitPayload({
  required Map<String, dynamic> data,
  required List<dynamic>? fields,
  String? position,
  String? pageLabel,
}) {
  if (!isNomineeExtendedUiStep(position, pageLabel)) return;

  if (isNomineeKycStep(position, pageLabel)) {
    final total = sumNomineePercentagesForStepFields(
      formData: data,
      fields: fields,
    );
    data[kTotalNomineePercentageField] =
        _formatNomineePercentTotalForApi(total);
    return;
  }

  if (isAdditionalNomineeKycStep(position, pageLabel) &&
      _findFieldDefByName(fields, kRemainNomineePercentField) != null) {
    final prior = readPriorNomineeAllocatedPercent(
      formData: data,
      fields: fields,
    );
    final stepSum = sumNomineePercentagesForStepFields(
      formData: data,
      fields: fields,
    );
    data[kRemainNomineePercentField] = _formatNomineePercentTotalForApi(
      prior + stepSum,
    );
  }
}

/// Caps input: max 100 per field; total of **active** nominee slots cannot exceed 100.
String? clampNomineePercentageValue({
  required String fieldName,
  required dynamic rawValue,
  required Map<String, dynamic> formData,
  List<dynamic>? fields,
  Map<String, bool>? runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (!isNomineePercentageFieldName(fieldName)) return null;
  if (nomineePercentageSlotIndex(fieldName) == 3 &&
      fields != null &&
      _nomineeTier3Blocked(formData, fields)) {
    return '0';
  }
  final parsed = _parseNomineePercentageValue(rawValue);
  if (parsed == null) return null;

  final onAdditional = isAdditionalNomineeKycStep(position, pageLabel);
  final priorAllocated = onAdditional
      ? readPriorNomineeAllocatedPercent(formData: formData, fields: fields)
      : 0.0;

  final pctFields = resolveNomineePercentageFieldNames(fields);
  var others = 0.0;
  if (fields != null && runtimeFieldVisibility != null) {
    for (final n in pctFields) {
      if (n == fieldName) continue;
      if (!isNomineePercentageFieldActive(
        n,
        fields,
        runtimeFieldVisibility,
        formData: formData,
        company: company,
        position: position,
        pageLabel: pageLabel,
      )) {
        continue;
      }
      others += _parseNomineePercentageValue(formData[n]) ?? 0;
    }
  } else {
    for (final n in pctFields) {
      if (n == fieldName) continue;
      others += _parseNomineePercentageValue(formData[n]) ?? 0;
    }
  }

  final maxForSlot =
      (100.0 - priorAllocated - others).clamp(0.0, 100.0);
  final capped = parsed.clamp(0.0, maxForSlot);

  if (capped == capped.roundToDouble()) {
    return capped.round().toString();
  }
  return capped.toStringAsFixed(2);
}

Map<dynamic, dynamic>? _findFieldDefByName(
  List<dynamic>? fields,
  String name,
) {
  if (fields == null) return null;
  for (final f in fields) {
    if (f is Map && f['name']?.toString() == name) return f;
  }
  return null;
}

double? _parseNomineePercentageValue(dynamic raw) {
  if (raw == null || raw.toString().trim().isEmpty) return null;
  return double.tryParse(raw.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
}

bool _nomineeShareSumAtLeast100(double sum) => sum >= 99.999;

/// Allows 33.33 + 33.33 + 33.34 style splits (floating-point safe).
bool _nomineeShareEquals100(double sum) => (sum - 100).abs() <= 0.05;

String? _nomineePercentageFieldForSlot(List<dynamic>? fields, int slot) {
  for (final name in resolveNomineePercentageFieldNames(fields)) {
    if (nomineePercentageSlotIndex(name) == slot) return name;
  }
  return null;
}

/// Nominee 1 + 2 share (slot 2 only when `add_2_nominee` is checked).
double _nomineeSumSlots1And2(
  Map<String, dynamic> formData,
  List<dynamic>? fields,
) {
  var sum = 0.0;
  final n1 = _nomineePercentageFieldForSlot(fields, 1);
  if (n1 != null) sum += _parseNomineePercentageValue(formData[n1]) ?? 0;
  if (isCheckboxCheckedValue(formData[kAddSecondNomineeField])) {
    final n2 = _nomineePercentageFieldForSlot(fields, 2);
    if (n2 != null) sum += _parseNomineePercentageValue(formData[n2]) ?? 0;
  }
  return sum;
}

bool _nomineeTier3Blocked(Map<String, dynamic> formData, List<dynamic>? fields) {
  return _nomineeShareSumAtLeast100(_nomineeSumSlots1And2(formData, fields));
}

bool _nomineeSlotPercentageEntered(
  Map<String, dynamic> formData,
  List<dynamic>? fields,
  int slot,
) {
  final name = _nomineePercentageFieldForSlot(fields, slot);
  if (name == null) return false;
  final v = _parseNomineePercentageValue(formData[name]);
  return v != null && v > 0;
}

bool _nominee1PercentageEntered(
  Map<String, dynamic> formData,
  List<dynamic>? fields,
) =>
    _nomineeSlotPercentageEntered(formData, fields, 1);

/// Admin / OTP / reject-reason keys — never show on the nominee form UI.
bool isNomineeBackendOnlyField(String name) {
  final n = name.toLowerCase();
  if (n.startsWith('reject_reason_')) return true;
  if (n.startsWith('nominee_otp_') || n.startsWith('nominee_opt_')) {
    return true;
  }
  if (n == 'optoutname' ||
      n == 'optinname' ||
      n == 'optincheckbox' ||
      n == 'optoutcheckbox' ||
      n == 'nominee_yes_val' ||
      n == 'nominee_no_val') {
    return true;
  }
  return false;
}

bool isNomineeTier2DataField(String name) {
  if (name == kAddSecondNomineeField ||
      name == kAddThirdNomineeField ||
      name == kExtraNomineeField ||
      isNomineeBackendOnlyField(name)) {
    return false;
  }
  final n = name.toLowerCase();
  if (n.contains('guardian') ||
      n.contains('additional_nominee') ||
      n.contains('nominee_mobile') ||
      n.contains('mobile_otp') ||
      n == 'opt_out_terms' ||
      n.contains('nominee1') ||
      n.contains('nominee_1') ||
      n.contains('nominee_one')) {
    return false;
  }
  if (n.contains('nominee3') || n.contains('nominee_3') || n.contains('nominee_three')) {
    return false;
  }
  if (n.contains('pan') || n.contains('aadhar') || n.contains('aadhaar')) {
    return false;
  }
  return n.startsWith('nominee2_') ||
      n.startsWith('nominee_2') ||
      n.startsWith('nominee_two_');
}

bool isNomineeTier3DataField(String name) {
  if (name == kAddSecondNomineeField ||
      name == kAddThirdNomineeField ||
      name == kExtraNomineeField ||
      isNomineeBackendOnlyField(name)) {
    return false;
  }
  if (isNomineeAddMoreDropdownField(name)) return false;
  final n = name.toLowerCase();
  if (n.contains('guardian') ||
      n.contains('additional_nominee') ||
      n.contains('nominee_mobile') ||
      n.contains('mobile_otp') ||
      n == 'opt_out_terms' ||
      n.contains('nominee1') ||
      n.contains('nominee_1') ||
      n.contains('nominee_one') ||
      n.contains('nominee2') ||
      n.contains('nominee_2') ||
      n.contains('nominee_two')) {
    return false;
  }
  if (n.contains('pan') || n.contains('aadhar') || n.contains('aadhaar')) {
    return false;
  }
  return n.startsWith('nominee3_') ||
      n.startsWith('nominee_3') ||
      n.startsWith('nominee_three_');
}

bool isNomineePanOrAadharField(String name) {
  final n = name.toLowerCase();
  if (n.contains('guardian')) {
    return n.contains('pan') || n.contains('aadhar') || n.contains('aadhaar');
  }
  if (!n.contains('nominee')) return false;
  return n.contains('pan') || n.contains('aadhar') || n.contains('aadhaar');
}

int? nomineeSlotFromFieldName(String name) {
  if (isNomineeBackendOnlyField(name)) return null;
  final lower = name.toLowerCase();
  if (lower.contains('additional_nominee')) return null;
  final compact = lower.replaceAll('_', '');
  final m = RegExp(r'nominee(\d+)').firstMatch(compact);
  if (m != null) {
    return int.tryParse(m.group(1)!);
  }
  for (final e in _kNomineeWordSlotNumbers.entries) {
    if (compact.contains('nominee${e.key}')) return e.value;
  }
  return null;
}

int? _nomineeSlotFromPanAadharField(String name) =>
    nomineeSlotFromFieldName(name);

int? guardianSlotFromFieldName(String name) {
  final m = RegExp(r'guardian_?(\d+)').firstMatch(name.toLowerCase());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

String? _nomineeDobFieldForSlot(int slot) {
  // Backend conditional rules for additional nominee steps use:
  //   nominee{N}_dob < 18  => show guardian{N}_*
  // This matches JSON in your provided files (additional_nominee*).
  return 'nominee${slot}_dob';
}

String? _nomineeProofTypeFieldForSlot(int slot) {
  switch (slot) {
    case 1:
      return 'nominee_one_proof_type';
    case 2:
      return 'nominee_two_proof_type';
    case 3:
      return 'nominee_three_proof_type';
    case 4:
      return 'nominee_four_proof_type';
    case 5:
      return 'nominee_five_proof_type';
    case 6:
      return 'nominee_six_proof_type';
    default:
      return null;
  }
}

bool _nomineePanAadharFieldVisible({
  required String name,
  required Map<String, dynamic> formData,
}) {
  final n = name.toLowerCase();
  final isPan = n.contains('pan');

  if (n.contains('guardian1')) {
    return _proofTypeIncludes(
      formData['guardian1_proof_type'],
      isPan ? 'PAN' : 'AADHA',
    );
  }
  if (n.contains('guardian2')) {
    if (!isCheckboxCheckedValue(formData[kAddSecondNomineeField])) {
      return false;
    }
    return _proofTypeIncludes(
      formData['guardian2_proof_type'],
      isPan ? 'PAN' : 'AADHA',
    );
  }
  if (n.contains('guardian3')) {
    if (!isCheckboxCheckedValue(formData[kAddThirdNomineeField])) {
      return false;
    }
    return _proofTypeIncludes(
      formData['guardian3_proof_type'],
      isPan ? 'PAN' : 'AADHA',
    );
  }

  final guardianSlot = guardianSlotFromFieldName(name);
  if (guardianSlot != null && guardianSlot >= 4) {
    final dobField = _nomineeDobFieldForSlot(guardianSlot);
    if (dobField == null) return false;
    if (!_isNomineeMinor(formData, dobField)) return false;
    return _proofTypeIncludes(
      formData['guardian${guardianSlot}_proof_type'],
      isPan ? 'PAN' : 'AADHA',
    );
  }

  final slot = _nomineeSlotFromPanAadharField(name);
  if (slot == null) return false;
  if (slot == 2 && !isCheckboxCheckedValue(formData[kAddSecondNomineeField])) {
    return false;
  }
  if (slot == 3 && !isCheckboxCheckedValue(formData[kAddThirdNomineeField])) {
    return false;
  }
  final addKey = 'add_${slot}_nominee';
  if (formData.containsKey(addKey) &&
      !isCheckboxCheckedValue(formData[addKey])) {
    return false;
  }

  final proofKey = _nomineeProofTypeFieldForSlot(slot);
  if (proofKey == null) return false;
  return _proofTypeIncludes(formData[proofKey], isPan ? 'PAN' : 'AADHA');
}

void _setNomineeTier2FieldsVisible(
  List<dynamic>? fields,
  Map<String, bool> runtimeFieldVisibility,
  bool visible,
) {
  if (fields == null) return;
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null) continue;
    if (isNomineeTier2DataField(name)) {
      runtimeFieldVisibility[name] = visible;
    }
  }
}

/// Hide internal / blank nominee inputs that slipped through visibility map.
bool shouldHideNomineeGhostInputField({
  required Map<dynamic, dynamic> field,
  required Map<String, dynamic> formData,
}) {
  final name = field['name']?.toString() ?? '';
  if (isNomineeBackendOnlyField(name)) return true;
  if (isNomineePanOrAadharField(name)) {
    return !_nomineePanAadharFieldVisible(name: name, formData: formData);
  }
  final displayName = field['displayName']?.toString().trim() ?? '';
  if (displayName.isEmpty) {
    final type = field['type']?.toString().toLowerCase() ?? '';
    if (type == 'text' || type == 'number' || type == 'email') return true;
  }
  return false;
}

bool isGuardian1Field(String name) {
  final n = name.toLowerCase();
  return n.contains('guardian1') || n == 'guardian_same_as_address1';
}

bool isGuardian2Field(String name) {
  final n = name.toLowerCase();
  return n.contains('guardian2') || n == 'guardian_same_as_address2';
}

bool isGuardian3Field(String name) {
  final n = name.toLowerCase();
  return n.contains('guardian3') || n == 'guardian_same_as_address3';
}

bool isAdditionalNomineeField(String name) {
  final n = name.toLowerCase();
  return n.contains('additional_nominee');
}

bool isNomineeStepAuxiliaryField(String name) {
  final n = name.toLowerCase();
  return n.contains('nominee_mobile') ||
      n.contains('mobile_otp') ||
      n == 'opt_out_terms';
}

int? _nomineeAgeFromDob(dynamic raw) {
  if (raw == null || raw.toString().trim().isEmpty) return null;
  final d = parseKycDateValue(raw) ?? DateTime.tryParse(raw.toString());
  if (d == null) return null;
  final today = DateTime.now();
  var age = today.year - d.year;
  final m = today.month - d.month;
  if (m < 0 || (m == 0 && today.day < d.day)) age--;
  return age;
}

bool _isNomineeMinor(Map<String, dynamic> formData, String dobField) {
  final age = _nomineeAgeFromDob(formData[dobField]);
  return age != null && age < 18;
}

bool _proofTypeIncludes(dynamic raw, String token) {
  return raw?.toString().toUpperCase().contains(token) ?? false;
}

/// Guardian, additional nominee blocks, PAN/Aadhaar toggles — aligned with web AddNominee.
void _applyNomineeSupplementaryFieldsVisibility({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? position,
  String? pageLabel,
}) {
  if (fields == null) return;

  final onMainNominee = isNomineeKycStep(position, pageLabel);
  final add2 = isCheckboxCheckedValue(formData[kAddSecondNomineeField]);
  final add3 = isCheckboxCheckedValue(formData[kAddThirdNomineeField]);
  final minor1 = _isNomineeMinor(formData, 'nominee1_dob');
  final minor2 = _isNomineeMinor(formData, 'nominee2_dob');
  final minor3 = _isNomineeMinor(formData, 'nominee3_dob');
  final extraYes = _isKycYesNoValue(formData[kExtraNomineeField]);

  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null) continue;

    if (isNomineeBackendOnlyField(name)) {
      runtimeFieldVisibility[name] = false;
    } else if (isGuardian1Field(name)) {
      runtimeFieldVisibility[name] = minor1;
    } else if (isGuardian2Field(name)) {
      runtimeFieldVisibility[name] = add2 && minor2;
    } else if (isGuardian3Field(name)) {
      runtimeFieldVisibility[name] = add3 && minor3;
    } else {
      final gSlot = guardianSlotFromFieldName(name);
      if (gSlot != null && gSlot >= 4) {
        // Additional nominee JSON rules are based on nominee{N}_dob < 18.
        final dobField = _nomineeDobFieldForSlot(gSlot);
        runtimeFieldVisibility[name] =
            dobField != null && _isNomineeMinor(formData, dobField);
      } else if (isAdditionalNomineeField(name) && onMainNominee) {
        runtimeFieldVisibility[name] = extraYes;
      } else if (isNomineeStepAuxiliaryField(name)) {
        runtimeFieldVisibility[name] = false;
      } else if (isNomineePanOrAadharField(name)) {
        runtimeFieldVisibility[name] =
            _nomineePanAadharFieldVisible(name: name, formData: formData);
      }
    }
  }
}

/// Additional nominee steps: prior % budget, add_N checkboxes, guardian, PAN/Aadhaar.
void syncAdditionalNomineeStepSideEffects({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? position,
  String? pageLabel,
}) {
  if (!isAdditionalNomineeKycStep(position, pageLabel)) return;
  _applyAdditionalNomineeAddButtonsVisibility(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
  );
  _applyNomineeSupplementaryFieldsVisibility(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    position: position,
    pageLabel: pageLabel,
  );
}

void _setNomineeTier3FieldsVisible(
  List<dynamic>? fields,
  Map<String, bool> runtimeFieldVisibility,
  bool visible,
) {
  if (fields == null) return;
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null) continue;
    if (isNomineeTier3DataField(name)) {
      runtimeFieldVisibility[name] = visible;
    }
  }
}

void _applyNominee3BlockWhenShareFull({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
}) {
  final block = _nomineeTier3Blocked(formData, fields);
  if (!block) return;
  if (_findFieldDefByName(fields, kAddThirdNomineeField) != null) {
    runtimeFieldVisibility[kAddThirdNomineeField] = false;
    formData[kAddThirdNomineeField] = false;
  }
  _setNomineeTier3FieldsVisible(fields, runtimeFieldVisibility, false);
  final n3 = _nomineePercentageFieldForSlot(fields, 3);
  if (n3 != null) formData.remove(n3);
}

/// `add_2` / `add_3` checkboxes only after nominee 1 % entered; tier 3 off when 1+2 = 100%.
void _applyNomineeAddButtonsVisibility({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
}) {
  final n1Entered = _nominee1PercentageEntered(formData, fields);
  final n1Name = _nomineePercentageFieldForSlot(fields, 1);
  final n1 = n1Name != null
      ? (_parseNomineePercentageValue(formData[n1Name]) ?? 0)
      : 0.0;
  final sum12 = _nomineeSumSlots1And2(formData, fields);
  final add2Checked = isCheckboxCheckedValue(formData[kAddSecondNomineeField]);

  final n2Entered = _nomineeSlotPercentageEntered(formData, fields, 2);
  final showAdd2 = n1Entered && !_nomineeShareSumAtLeast100(n1);
  final showAdd3 = n1Entered &&
      add2Checked &&
      n2Entered &&
      !_nomineeShareSumAtLeast100(sum12);
  final add3Checked = isCheckboxCheckedValue(formData[kAddThirdNomineeField]);

  if (_findFieldDefByName(fields, kAddSecondNomineeField) != null) {
    runtimeFieldVisibility[kAddSecondNomineeField] = showAdd2;
    if (!showAdd2) {
      formData[kAddSecondNomineeField] = false;
      _setNomineeTier2FieldsVisible(fields, runtimeFieldVisibility, false);
    } else {
      _setNomineeTier2FieldsVisible(
        fields,
        runtimeFieldVisibility,
        add2Checked,
      );
    }
  }

  if (_findFieldDefByName(fields, kAddThirdNomineeField) != null) {
    runtimeFieldVisibility[kAddThirdNomineeField] = showAdd3;
    if (!showAdd3) {
      formData[kAddThirdNomineeField] = false;
      _applyNominee3BlockWhenShareFull(
        formData: formData,
        fields: fields,
        runtimeFieldVisibility: runtimeFieldVisibility,
      );
    } else if (_nomineeTier3Blocked(formData, fields)) {
      _applyNominee3BlockWhenShareFull(
        formData: formData,
        fields: fields,
        runtimeFieldVisibility: runtimeFieldVisibility,
      );
    } else {
      _setNomineeTier3FieldsVisible(
        fields,
        runtimeFieldVisibility,
        add3Checked,
      );
    }
  } else if (_nomineeTier3Blocked(formData, fields)) {
    _applyNominee3BlockWhenShareFull(
      formData: formData,
      fields: fields,
      runtimeFieldVisibility: runtimeFieldVisibility,
    );
  }
}

/// "Do you want to add more nominee" visible only after nominee 3 % and total &lt; 100%.
bool isExtraNomineeDropdownVisible({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (_findFieldDefByName(fields, kExtraNomineeField) == null) return false;

  final total = sumActiveNomineePercentages(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );
  if (_nomineeShareSumAtLeast100(total)) return false;

  final add3Checked = isCheckboxCheckedValue(formData[kAddThirdNomineeField]);
  final n3Entered = _nomineeSlotPercentageEntered(formData, fields, 3);
  return add3Checked && n3Entered;
}

void applyExtraNomineeFieldState({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  required Map<String, bool> fieldEditable,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (_findFieldDefByName(fields, kExtraNomineeField) == null) return;

  final show = isExtraNomineeDropdownVisible(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );

  if (!show) {
    runtimeFieldVisibility[kExtraNomineeField] = false;
    formData[kExtraNomineeField] = '';
    fieldEditable[kExtraNomineeField] = true;
  } else {
    runtimeFieldVisibility[kExtraNomineeField] = true;
    fieldEditable.remove(kExtraNomineeField);
  }
}

/// Active nominee slots sum to 100% (e.g. single nominee at 100%).
bool isNomineeActiveShareFull({
  required Map<String, dynamic> formData,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (!isNomineeKycStep(position, pageLabel) || !_addNomineeSelectedYes(formData)) {
    return false;
  }
  final total = sumActiveNomineePercentages(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );
  return _nomineeShareSumAtLeast100(total);
}

/// Submit: `extra_nominee` blank until the dropdown is shown; then keep user Yes/No.
void syncExtraNomineeSubmitPayload({
  required Map<String, dynamic> data,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (!isNomineeKycStep(position, pageLabel) || !_addNomineeSelectedYes(data)) {
    return;
  }
  if (_findFieldDefByName(fields, kExtraNomineeField) == null) return;
  if (isExtraNomineeDropdownVisible(
    formData: data,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  )) {
    return;
  }
  data[kExtraNomineeField] = '';
}

/// Runs on every nominee % change — updates visibility from live form values (call last).
void syncNomineePercentageSideEffects({
  required Map<String, dynamic> formData,
  required Map<String, bool> fieldEditable,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (!isNomineeKycStep(position, pageLabel) || !_addNomineeSelectedYes(formData)) {
    runtimeFieldVisibility.remove(kExtraNomineeField);
    fieldEditable.remove(kExtraNomineeField);
    return;
  }

  _applyNomineeAddButtonsVisibility(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
  );

  applyExtraNomineeFieldState(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    fieldEditable: fieldEditable,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );

  _applyNomineeSupplementaryFieldsVisibility(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    position: position,
    pageLabel: pageLabel,
  );
}

void applyNomineeStepSubmitPayload({
  required Map<String, dynamic> data,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  final onMainNomineeStep = isNomineeKycStep(position, pageLabel);
  final onNomineeLikeStep = isNomineeExtendedUiStep(position, pageLabel);

  if (onMainNomineeStep) {
    syncNomineePercentageSideEffects(
      formData: data,
      fieldEditable: {},
      fields: fields,
      runtimeFieldVisibility: runtimeFieldVisibility,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
  }

  if (onNomineeLikeStep) {
    runtimeFieldVisibility[kTotalNomineePercentageField] = true;
    runtimeFieldVisibility[kRemainNomineePercentField] = true;
    syncNomineeStepPercentTotalsSubmitPayload(
      data: data,
      fields: fields,
      position: position,
      pageLabel: pageLabel,
    );
  }

  if (onMainNomineeStep) {
    syncExtraNomineeSubmitPayload(
      data: data,
      fields: fields,
      runtimeFieldVisibility: runtimeFieldVisibility,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
  }
}

/// Additional nominee: prior % + this step cannot exceed 100%.
String? validateAdditionalNomineePercentageTotal({
  required List<dynamic>? fields,
  required Map<String, dynamic> formData,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (!isAdditionalNomineeKycStep(position, pageLabel)) return null;
  if (fields == null) return null;

  final prior = readPriorNomineeAllocatedPercent(
    formData: formData,
    fields: fields,
  );
  final stepSum = sumActiveAdditionalNomineeStepPercentages(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );
  if (prior + stepSum > 100.001) {
    final remaining = nomineeRemainingBudgetOnAdditionalStep(
      formData: formData,
      fields: fields,
    );
    if (remaining <= 0.001) {
      return 'You have already allocated 100% nominee share on previous steps';
    }
    return 'Nominee share on this step cannot exceed ${remaining == remaining.roundToDouble() ? remaining.round() : remaining.toStringAsFixed(2)}%';
  }
  return null;
}

/// Submit: active nominee % total = 100%, unless `extra_nominee` is Yes (below 100% OK).
String? validateNomineePercentageTotal({
  required List<dynamic>? fields,
  required Map<String, dynamic> formData,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
}) {
  if (!isNomineeKycStep(position, pageLabel)) return null;
  if (!_addNomineeSelectedYes(formData)) return null;
  if (fields == null) return null;

  final pctFields = resolveNomineePercentageFieldNames(fields);
  var hasActivePct = false;
  for (final name in pctFields) {
    if (isNomineePercentageFieldActive(
      name,
      fields,
      runtimeFieldVisibility,
      formData: formData,
      company: company,
      position: position,
      pageLabel: pageLabel,
    )) {
      hasActivePct = true;
      break;
    }
  }
  if (!hasActivePct) return null;

  final total = sumActiveNomineePercentages(
    formData: formData,
    fields: fields,
    runtimeFieldVisibility: runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );
  if (total > 100.001) {
    return 'Total nominee share cannot exceed 100%';
  }
  if (!_nomineeShareEquals100(total)) {
    // "Do you want to add more nominee" = Yes (only when dropdown is visible).
    if (isExtraNomineeDropdownVisible(
          formData: formData,
          fields: fields,
          runtimeFieldVisibility: runtimeFieldVisibility,
          company: company,
          position: position,
          pageLabel: pageLabel,
        ) &&
        _isKycYesNoValue(formData[kExtraNomineeField])) {
      return null;
    }
    return 'Total nominee share must equal 100%';
  }
  return null;
}

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
