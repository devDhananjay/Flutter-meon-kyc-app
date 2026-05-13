import 'dart:math' as math;

/// Stored value is often ISO `yyyy-MM-dd` or `MM/dd/yyyy`-style.
DateTime? parseKycDateValue(dynamic value) {
  if (value == null) return null;
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  final normalized = s.replaceAll('/', '-');
  final d = DateTime.tryParse(normalized);
  if (d != null) return DateTime(d.year, d.month, d.day);
  final m = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(s);
  if (m != null) {
    final month = int.tryParse(m.group(1)!);
    final day = int.tryParse(m.group(2)!);
    final year = int.tryParse(m.group(3)!);
    if (month != null && day != null && year != null) {
      return DateTime(year, month, day);
    }
  }
  return null;
}

/// If [value] parses as a calendar date, returns **`dd/MM/yyyy`** (e.g. for kyc-post JSON).
String? tryFormatKycDateValueAsDdMmYyyy(dynamic value) {
  final d = parseKycDateValue(value);
  if (d == null) return null;
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

DateTime _subtractYearsFromDate(DateTime from, int years) {
  if (years <= 0) return from;
  final targetYear = from.year - years;
  final dim = DateTime(targetYear, from.month + 1, 0).day;
  final day = math.min(from.day, dim);
  return DateTime(targetYear, from.month, day);
}

/// API-driven DOB picker bounds, e.g. `maxDateType: year`, `maxDateValue: -18` (min age 18),
/// `minDateType: year`, `minDateValue: 100` (max age 100).
/// Returns `null` when no usable date constraints are present.
({DateTime first, DateTime last})? kycDobPickerBoundsFromField(
  Map<dynamic, dynamic> field, {
  DateTime? today,
}) {
  final now = today ?? DateTime.now();
  final todayDate = DateTime(now.year, now.month, now.day);

  final minType = field['minDateType']?.toString().toLowerCase().trim();
  final minRaw = field['minDateValue']?.toString().trim();
  final maxType = field['maxDateType']?.toString().toLowerCase().trim();
  final maxRaw = field['maxDateValue']?.toString().trim();

  final hasMin = minType != null &&
      minType.isNotEmpty &&
      minRaw != null &&
      minRaw.isNotEmpty;
  final hasMax = maxType != null &&
      maxType.isNotEmpty &&
      maxRaw != null &&
      maxRaw.isNotEmpty;

  if (!hasMin && !hasMax) return null;

  var first = DateTime(1900, 1, 1);
  var last = todayDate;

  if (hasMin && minType == 'year') {
    final y = int.tryParse(minRaw ?? '');
    if (y != null && y > 0) {
      first = _subtractYearsFromDate(todayDate, y);
    }
  }

  if (hasMax && maxType == 'year') {
    final raw = maxRaw ?? '';
    final y = int.tryParse(raw.replaceAll('+', ''));
    if (y != null && y != 0) {
      final years = y.abs();
      last = _subtractYearsFromDate(todayDate, years);
    }
  }

  if (first.isAfter(last)) {
    final t = first;
    first = last;
    last = t;
  }
  return (first: first, last: last);
}

/// `null` if valid or empty (caller handles required separately).
String? validateDobAgainstFieldBounds(
  Map<dynamic, dynamic> field,
  dynamic value,
) {
  final bounds = kycDobPickerBoundsFromField(field);
  if (bounds == null) return null;

  final d = parseKycDateValue(value);
  if (d == null) return null;

  final dob = DateTime(d.year, d.month, d.day);
  if (dob.isBefore(bounds.first) || dob.isAfter(bounds.last)) {
    return 'Date of birth must be between ${_formatShort(bounds.first)} and '
        '${_formatShort(bounds.last)}.';
  }
  return null;
}

String _formatShort(DateTime d) {
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
