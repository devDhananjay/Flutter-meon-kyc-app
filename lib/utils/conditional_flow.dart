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
  'equals': (a, b) => a.toString() == b.toString(),
  'contains': (a, b) {
    if (a is List) return a.contains(b);
    return a.toString().contains(b.toString());
  },
  'notEquals': (a, b) => a.toString() != b.toString(),
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
    final inputValue = condition['inputValue'];
    final operator = condition['operator'] ?? 'equals';
    final opFn = _conditionOperators[operator];
    if (opFn == null) continue;
    if (!opFn(fieldValue, inputValue)) continue;

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
          break;
        case 'show':
          state.fieldVisibility[selected] = true;
          break;
        case 'empty':
          state.formData[selected] = '';
          break;
        case 'prePopulate':
          state.formData[selected] = action['value']?.toString() ?? '';
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
    final visible = fieldVisibility[name] ?? true;
    return show && visible;
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
    final inputValue = condition['inputValue'];
    final operator = condition['operator'] ?? 'equals';
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
          break;
        case 'show':
          state.fieldVisibility[selected] = true;
          break;
        case 'empty':
          state.formData[selected] = '';
          break;
        case 'prePopulate':
          state.formData[selected] = action['value']?.toString() ?? '';
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
