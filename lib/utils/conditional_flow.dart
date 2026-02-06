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

List<dynamic> getVisibleFields(
  List<dynamic> fields,
  Map<String, bool> fieldVisibility,
) {
  return fields.where((f) {
    if (f is! Map) return false;
    final name = f['name']?.toString();
    final show = f['fieldShow'] ?? true;
    if (name == null) return false;
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
