import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:meon_kyc/components/otp_input.dart';
import 'package:meon_kyc/components/popup_modal.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/kyc_date_utils.dart';

// BugFixes: date helpers + select value resolution + date picker use existing API value (dropoff).

class FormFieldWidget extends StatefulWidget {
  final String name;
  final String displayName;
  final String type;
  final List<dynamic>? fileType;
  final dynamic size;
  final bool mandatory;
  final dynamic validation;
  final List<dynamic>? popupAfterSubmit;
  final dynamic value;
  final void Function(String name, dynamic value) onChange;
  final void Function(String name)? onBlur;
  final List<dynamic>? values;
  final bool visible;
  final String? errorField;
  final int? rows;
  final int? cols;
  final String? urlCompany;
  final String? workflowKey;
  final bool disable;
  /// When [validation] is `googleSignIn`, invoked instead of the empty stub.
  final Future<void> Function()? onGoogleSignIn;
  final bool googleSignInLoading;
  /// Full field map from API — used for `date` [minDateType]/[maxDateValue] etc.
  final Map<dynamic, dynamic>? apiFieldMeta;
  /// When true (PAN / detailspan / kradetails steps), date fields show **DD/MM/YYYY** instead of MM/dd/yyyy.
  final bool useDdMmYyyyDateDisplay;

  const FormFieldWidget({
    super.key,
    required this.name,
    required this.displayName,
    required this.type,
    this.fileType,
    this.size,
    this.mandatory = false,
    this.validation,
    this.popupAfterSubmit,
    this.value,
    required this.onChange,
    this.onBlur,
    this.values,
    this.visible = true,
    this.errorField,
    this.rows,
    this.cols,
    this.urlCompany,
    this.workflowKey,
    this.disable = false,
    this.onGoogleSignIn,
    this.googleSignInLoading = false,
    this.apiFieldMeta,
    this.useDdMmYyyyDateDisplay = false,
  });

  @override
  State<FormFieldWidget> createState() => _FormFieldWidgetState();
}

class _FormFieldWidgetState extends State<FormFieldWidget> {
  bool _showPassword = false;
  bool _showPopup = false;
  Map<String, dynamic>? _currentPopup;
  bool _isPdfEncrypted = false;
  String _pdfPassword = '';
  bool _isVerifyingPdf = false;
  String _pdfVerificationError = '';
  File? _encryptedPdfFile;
  String? _fileError;
  String? _previewPath;
  TextEditingController? _textController;
  TextEditingController? _numberController;
  TextEditingController? _textareaController;
  TextEditingController? _passwordController;

  static const Locale _ddMmYyyyPickerLocale = Locale('en', 'IN');

  /// Stored value remains ISO `yyyy-MM-dd`; label uses step-specific pattern.
  String _formatDateFieldDisplay(dynamic value) {
    if (value == null) return 'Select date';
    final s = value.toString().trim();
    if (s.isEmpty) return 'Select date';
    final d = widget.useDdMmYyyyDateDisplay
        ? (parseKycDateValueAsDdMmYyyy(value) ?? parseKycDateValue(value))
        : parseKycDateValue(value);
    if (d == null) return s;
    final pattern =
        widget.useDdMmYyyyDateDisplay ? 'dd/MM/yyyy' : 'MM/dd/yyyy';
    return DateFormat(pattern).format(d);
  }

  @override
  void initState() {
    super.initState();
    _initializeControllers();
  }

  void _initializeControllers() {
    var value = widget.value?.toString() ?? '';
    if (widget.type == 'text') {
      if (_isMobileField) {
        final digits = value.replaceAll(RegExp(r'\D'), '');
        value = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isPanField) {
        value = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (value.length > 10) value = value.substring(0, 10);
      } else if (_isNoSpecialCharacterField) {
        value = value.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
      } else if (_isDobLikeField) {
        value = _formatDdMmYyyyDisplayIfNeeded(value);
      }
      _textController = TextEditingController(text: value);
    } else if (widget.type == 'number') {
      _numberController = TextEditingController(text: value);
    } else if (widget.type == 'textarea') {
      _textareaController = TextEditingController(text: value);
    } else if (widget.type == 'password') {
      _passwordController = TextEditingController(text: value);
    }
  }

  @override
  void didUpdateWidget(FormFieldWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync controllers whenever the coalesced [widget.value] differs from what is shown.
    // IFSC auto-fill updates [formData] programmatically; we must not rely only on
    // `oldWidget.value != widget.value` (e.g. same string identity, or missed rebuild edge cases).
    _syncControllersFromWidgetValue();
  }

  void _syncControllersFromWidgetValue() {
    final newValue = widget.value?.toString() ?? '';
    if (widget.type == 'text' && _textController != null) {
      var textValue = newValue;
      if (_isMobileField) {
        final digits = newValue.replaceAll(RegExp(r'\D'), '');
        textValue = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isPanField) {
        textValue = newValue.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (textValue.length > 10) textValue = textValue.substring(0, 10);
      } else if (_isNoSpecialCharacterField) {
        textValue = newValue.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
      } else if (_isDobLikeField) {
        textValue = _formatDdMmYyyyDisplayIfNeeded(newValue);
      }
      if (_textController!.text != textValue) {
        _setControllerTextAfterBuild(_textController!, textValue);
      }
    } else if (widget.type == 'number' && _numberController != null) {
      var textValue = newValue;
      if (_isMobileField) {
        final digits = newValue.replaceAll(RegExp(r'\D'), '');
        textValue = digits.length > 10 ? digits.substring(0, 10) : digits;
      }
      if (_numberController!.text != textValue) {
        _setControllerTextAfterBuild(_numberController!, textValue);
      }
    } else if (widget.type == 'textarea' && _textareaController != null) {
      if (_textareaController!.text != newValue) {
        _setControllerTextAfterBuild(_textareaController!, newValue);
      }
    } else if (widget.type == 'password' && _passwordController != null) {
      if (_passwordController!.text != newValue) {
        _setControllerTextAfterBuild(_passwordController!, newValue);
      }
    }
  }

  /// Avoid FormFieldState.didChange → setState during an active build.
  void _setControllerTextAfterBuild(TextEditingController controller, String text) {
    void apply() {
      if (!mounted) return;
      if (controller.text != text) {
        controller.text = text;
      }
    }

    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      apply();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  @override
  void dispose() {
    _textController?.dispose();
    _numberController?.dispose();
    _textareaController?.dispose();
    _passwordController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    Widget field;
    switch (widget.type) {
      case 'text':
        field = _buildText();
        break;
      case 'number':
        field = _buildNumber();
        break;
      case 'textarea':
        field = _buildTextArea();
        break;
      case 'password':
        field = _buildPassword();
        break;
      case 'select':
        field = _buildSelect();
        break;
      case 'date':
        field = _buildDate();
        break;
      case 'checkbox':
        field = _buildCheckbox();
        break;
      case 'radio':
        field = _buildRadio();
        break;
      case 'button':
        field = _buildButton();
        break;
      case 'file':
        field = _buildFile();
        break;
      case 'otp':
        field = _buildOtp();
        break;
      default:
        field = _buildText();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        if (widget.errorField != null && widget.errorField!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.errorField!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                    softWrap: true,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: KycTheme.textPrimary,
            height: 1.35,
          ),
          children: [
            TextSpan(text: text),
            if (widget.mandatory)
              TextSpan(
                text: ' *',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget? _getFieldIcon() {
    final name = widget.name.toLowerCase();
    final type = widget.type.toLowerCase();
    final validation = widget.validation?.toString().toLowerCase() ?? '';
    
    // Email fields
    if (name.contains('email') || validation == 'email') {
      return const Icon(Icons.email_outlined, color: KycTheme.textSecondary);
    }
    // Phone/Mobile fields
    if (name.contains('phone') || name.contains('mobile') || validation == 'mobile') {
      return const Icon(Icons.phone_outlined, color: KycTheme.textSecondary);
    }
    // Date fields
    if (type == 'date') {
      return const Icon(Icons.calendar_today_outlined, color: KycTheme.textSecondary);
    }
    // OTP fields
    if (type == 'otp' || name.contains('otp') || validation == 'otp') {
      return const Icon(Icons.lock_outline, color: KycTheme.textSecondary);
    }
    // Password fields
    if (type == 'password') {
      return const Icon(Icons.lock_outline, color: KycTheme.textSecondary);
    }
    // Number fields — `numbers_outlined` renders like "#" on some devices/fonts; no prefix icon.
    if (type == 'number' || validation == 'number') {
      return null;
    }
    // File upload fields
    if (type == 'file') {
      return const Icon(Icons.upload_file_outlined, color: KycTheme.textSecondary);
    }
    return null;
  }

  bool get _isMobileField {
    final name = widget.name.toLowerCase();
    final validation = widget.validation?.toString().toLowerCase() ?? '';
    return validation == 'mobile' ||
        name == 'mobile' ||
        name == 'mobile_number' ||
        name == 'phone';
  }

  bool get _isPanField {
    final v = widget.validation?.toString().toLowerCase() ?? '';
    if (v == 'pan') return true;
    final n = widget.name.toLowerCase();
    return n == 'pan_number' || n == 'temp_pan_no' || n == 'pan_no';
  }

  bool get _isNoSpecialCharacterField {
    final v = widget.validation?.toString().toLowerCase().trim() ?? '';
    return v == 'nospecialcharacter';
  }

  bool get _isDobLikeField {
    final n = widget.name.toLowerCase();
    final dn = widget.displayName.toLowerCase();
    return n.contains('dob') ||
        n.contains('date_of_birth') ||
        n.contains('birth_date') ||
        dn.contains('date of birth') ||
        dn.contains('dob');
  }

  String _formatDdMmYyyyDisplayIfNeeded(String raw) {
    if (!widget.useDdMmYyyyDateDisplay || raw.trim().isEmpty) return raw;
    if (widget.type != 'date' && !_isDobLikeField) return raw;
    final d = parseKycDateValueAsDdMmYyyy(raw) ?? parseKycDateValue(raw);
    if (d == null) return raw;
    return DateFormat('dd/MM/yyyy').format(d);
  }

  static final BorderRadius _fieldBorderRadius =
      BorderRadius.circular(KycTheme.radiusMd);

  OutlineInputBorder _outlineFieldBorder({Color? color, double width = 1}) {
    return OutlineInputBorder(
      borderRadius: _fieldBorderRadius,
      borderSide: BorderSide(color: color ?? KycTheme.border, width: width),
    );
  }

  /// Matches app [InputDecorationTheme] — disabled/read-only fields keep the same
  /// visual styling as editable fields (same fill, border, label colors). Editability
  /// is controlled at the form-control level (`readOnly` / `enabled`), not via colors.
  InputDecoration _fieldInputDecoration({
    String? hintText,
    Widget? prefixIcon,
    Widget? prefix,
    Widget? suffixIcon,
    String? counterText,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      hintText: hintText,
      prefixIcon: prefixIcon,
      prefix: prefix,
      suffixIcon: suffixIcon,
      counterText: counterText,
      alignLabelWithHint: alignLabelWithHint,
      filled: true,
      fillColor: KycTheme.surface,
      border: _outlineFieldBorder(),
      enabledBorder: _outlineFieldBorder(),
      focusedBorder: _outlineFieldBorder(color: KycTheme.primary, width: 2),
      disabledBorder: _outlineFieldBorder(),
      errorBorder: _outlineFieldBorder(color: Colors.red),
      focusedErrorBorder: _outlineFieldBorder(color: Colors.red, width: 2),
    );
  }

  /// Disabled `TextFormField`s lose their text color via the Material theme;
  /// force the regular primary text color so read-only fields look identical
  /// to editable ones (DigiLocker, KRA review, etc.).
  static const TextStyle _kFieldTextStyle = TextStyle(
    fontSize: 16,
    color: KycTheme.textPrimary,
    height: 1.35,
  );

  static const double _kSelectFieldHeight = 52.0;

  /// Label is shown above the field; long copy must not repeat inside the box.
  bool _selectHasLongLabelAbove() => widget.displayName.trim().length > 48;

  /// KRA continue dropdown: full question as label above, `--Select--` inside the box.
  bool _selectUsesPlaceholderInsideBox() {
    if (_selectHasLongLabelAbove()) return true;
    return kraDetailsContinueWithKraChoiceField({
      'name': widget.name,
      'displayName': widget.displayName,
    });
  }

  /// Closed dropdown hint when no value is selected yet (label above stays [displayName]).
  String _selectClosedHint() {
    if (_selectUsesPlaceholderInsideBox()) return '--Select--';
    return widget.displayName;
  }

  int _selectMenuTextMaxLines(String text) {
    final len = text.trim().length;
    if (len <= 48) return 1;
    if (len <= 96) return 2;
    return 3;
  }

  double _selectMenuItemHeight(String text) {
    final lines = _selectMenuTextMaxLines(text);
    if (lines <= 1) return _kSelectFieldHeight;
    return 26.0 * lines + 16.0;
  }

  Widget _selectDropdownText(
    String text, {
    int maxLines = 1,
    Color? color,
  }) {
    return Text(
      text,
      style: _kFieldTextStyle.copyWith(
        color: color ?? KycTheme.textPrimary,
        height: 1.3,
      ),
      maxLines: maxLines,
      softWrap: true,
      overflow: TextOverflow.clip,
      textAlign: TextAlign.start,
    );
  }

  /// Vertically centered closed-state row (hint or selected value).
  Widget _selectClosedFieldChild(
    String text, {
    Color? color,
    int maxLines = 1,
  }) {
    return SizedBox(
      width: double.infinity,
      height: _kSelectFieldHeight,
      child: Center(
        child: Align(
          alignment: Alignment.centerLeft,
          child: _selectDropdownText(
            text,
            maxLines: maxLines,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildText() {
    if (_textController == null) {
      String raw = widget.value?.toString() ?? '';
      if (_isMobileField) {
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        raw = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isPanField) {
        raw = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (raw.length > 10) raw = raw.substring(0, 10);
      } else if (_isNoSpecialCharacterField) {
        raw = raw.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
      } else if (_isDobLikeField) {
        raw = _formatDdMmYyyyDisplayIfNeeded(raw);
      }
      _textController = TextEditingController(text: raw);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _textController,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          scrollPhysics: const NeverScrollableScrollPhysics(),
          style: _kFieldTextStyle,
          keyboardType: _isMobileField ? TextInputType.number : TextInputType.text,
          textCapitalization:
              _isPanField ? TextCapitalization.characters : TextCapitalization.none,
          maxLength: _isMobileField ? 10 : (_isPanField ? 10 : null),
          inputFormatters: _isMobileField
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ]
              : _isPanField
                  ? [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                      LengthLimitingTextInputFormatter(10),
                    ]
                  : _isNoSpecialCharacterField
                      ? [
                          FilteringTextInputFormatter.allow(
                            RegExp(r"[a-zA-Z\s'\-]"),
                          ),
                        ]
                      : null,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: _isMobileField ? 'Enter Mobile number *' : '${widget.displayName}',
            prefixIcon: _isMobileField ? null : _getFieldIcon(),
            prefix: _isMobileField
                ? Padding(
                    padding: const EdgeInsets.only(left: 16, right: 12),
                    child: Text(
                      '+91',
                      style: TextStyle(
                        fontSize: 16,
                        color: KycTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : null,
            counterText:
                (_isMobileField || _isPanField || _isNoSpecialCharacterField)
                    ? ''
                    : null,
          ),
        ),
      ],
    );
  }

  Widget _buildNumber() {
    if (_numberController == null) {
      String raw = widget.value?.toString() ?? '';
      if (_isMobileField) {
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        raw = digits.length > 10 ? digits.substring(0, 10) : digits;
      }
      _numberController = TextEditingController(text: raw);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _numberController,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          style: _kFieldTextStyle,
          keyboardType: _isMobileField ? TextInputType.number : TextInputType.number,
          maxLength: _isMobileField ? 10 : null,
          inputFormatters: _isMobileField
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ]
              : null,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: _isMobileField ? 'Enter Mobile number *' : '${widget.displayName}',
            prefixIcon: _getFieldIcon(),
            counterText: _isMobileField ? '' : null,
          ),
        ),
      ],
    );
  }

  Widget _buildTextArea() {
    if (_textareaController == null) {
      _textareaController = TextEditingController(text: widget.value?.toString() ?? '');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _textareaController,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          style: _kFieldTextStyle,
          maxLines: widget.rows ?? 3,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: '${widget.displayName}',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  Widget _buildPassword() {
    if (_passwordController == null) {
      _passwordController = TextEditingController(text: widget.value?.toString() ?? '');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _passwordController,
          obscureText: !_showPassword,
          style: _kFieldTextStyle,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: '${widget.displayName}',
            prefixIcon: _getFieldIcon(),
            suffixIcon: IconButton(
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelect() {
    final rawOptions = widget.values ?? [];

    /// API may send plain strings or `{label, value}` maps. Dropdown values must be unique.
    List<MapEntry<String, String>> _normalizedSelectEntries(List<dynamic> opts) {
      final seenLower = <String>{};
      final out = <MapEntry<String, String>>[];
      for (final e in opts) {
        String value;
        String label;
        if (e is Map) {
          final m = Map<String, dynamic>.from(e as Map);
          label = (m['label'] ??
                  m['displayName'] ??
                  m['text'] ??
                  m['value'] ??
                  '')
              .toString()
              .trim();
          value = (m['value'] ?? m['label'] ?? label).toString().trim();
          if (value.isEmpty && label.isNotEmpty) value = label;
          if (label.isEmpty) label = value;
        } else {
          final s = e.toString().trim();
          value = s;
          label = s;
        }
        if (value.isEmpty) continue;
        final dedupeKey = value.toLowerCase();
        if (seenLower.contains(dedupeKey)) continue;
        seenLower.add(dedupeKey);
        out.add(MapEntry(value, label));
      }
      return out;
    }

    /// Match stored form / API value to exactly one option [MapEntry.key] (dropdown value).
    String? _resolveSelectValue(String? raw, List<MapEntry<String, String>> entries) {
      if (raw == null || raw.trim().isEmpty) return null;
      final t = raw.trim();
      for (final e in entries) {
        if (e.key == t || e.value == t) return e.key;
      }
      final tl = t.toLowerCase();
      for (final e in entries) {
        if (e.key.toLowerCase() == tl || e.value.toLowerCase() == tl) return e.key;
      }
      return null;
    }

    final entries = _normalizedSelectEntries(rawOptions);
    final currentRaw = widget.value?.toString();
    final resolvedValue = _resolveSelectValue(currentRaw, entries);
    final isValidValue = resolvedValue != null;

    final longLabelAbove = _selectHasLongLabelAbove();
    final closedHint = _selectClosedHint();
    var longestMenuLabel = widget.displayName;
    for (final e in entries) {
      if (e.value.length > longestMenuLabel.length) {
        longestMenuLabel = e.value;
      }
    }
    final menuItemHeight = _selectMenuItemHeight(longestMenuLabel);
    final menuMaxLines = _selectMenuTextMaxLines(longestMenuLabel);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        DropdownButtonFormField<String>(
          value: isValidValue ? resolvedValue : null,
          decoration: _fieldInputDecoration().copyWith(
            contentPadding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            constraints: const BoxConstraints(minHeight: _kSelectFieldHeight),
          ),
          hint: _selectClosedFieldChild(
            closedHint,
            color: KycTheme.textSecondary,
            maxLines: _selectMenuTextMaxLines(closedHint),
          ),
          isExpanded: true,
          style: _kFieldTextStyle,
          iconEnabledColor: KycTheme.textSecondary,
          iconDisabledColor: KycTheme.textSecondary,
          itemHeight: menuItemHeight,
          items: entries
              .map(
                (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _selectDropdownText(
                        e.value,
                        maxLines: menuMaxLines,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
          selectedItemBuilder: (ctx) => entries
              .map(
                (e) => _selectClosedFieldChild(
                  e.value,
                  maxLines: _selectMenuTextMaxLines(e.value),
                ),
              )
              .toList(),
          onChanged: widget.disable
              ? null
              : (v) => widget.onChange(widget.name, v ?? ''),
        ),
      ],
    );
  }

  Widget _buildDate() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        InkWell(
          onTap: widget.disable
              ? null
              : () async {
                  final now = DateTime.now();
                  final today = DateTime(now.year, now.month, now.day);
                  final bounds = widget.apiFieldMeta != null
                      ? kycDobPickerBoundsFromField(widget.apiFieldMeta!)
                      : null;
                  final first = bounds?.first ?? DateTime(1900, 1, 1);
                  final last = bounds?.last ?? today;
                  final existing = parseKycDateValue(widget.value);
                  var initial = existing ?? last;
                  if (initial.isAfter(last)) initial = last;
                  if (initial.isBefore(first)) initial = first;
                  final ddMmLocale = widget.useDdMmYyyyDateDisplay
                      ? _ddMmYyyyPickerLocale
                      : null;
                  final d = await showDatePicker(
                    context: context,
                    initialDate: initial,
                    firstDate: first,
                    lastDate: last,
                    locale: ddMmLocale,
                    builder: ddMmLocale == null
                        ? null
                        : (context, child) => Localizations.override(
                              context: context,
                              locale: ddMmLocale,
                              child: child!,
                            ),
                  );
                  if (d != null) {
                    // API payload stays `yyyy-MM-dd`; only UI shows dd/MM/yyyy.
                    widget.onChange(widget.name, d.toIso8601String().split('T')[0]);
                    widget.onBlur?.call(widget.name);
                  }
                },
          child: InputDecorator(
            decoration: _fieldInputDecoration(prefixIcon: _getFieldIcon()),
            child: Text(
              _formatDateFieldDisplay(widget.value),
              style: TextStyle(
                color: widget.value != null &&
                        widget.value.toString().trim().isNotEmpty
                    ? KycTheme.textPrimary
                    : Colors.grey,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckbox() {
    return Row(
      children: [
        Checkbox(
          value: widget.value == true,
          onChanged: widget.disable
              ? null
              : (v) => widget.onChange(widget.name, v ?? false),
        ),
        Expanded(
          child: GestureDetector(
            onTap: widget.disable ? null : () => widget.onChange(widget.name, widget.value != true),
            child: _buildLabel(widget.displayName),
          ),
        ),
      ],
    );
  }

  Widget _buildRadio() {
    final options = widget.values ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        ...options.map((opt) => RadioListTile<String>(
              title: Text(opt.toString()),
              value: opt.toString(),
              groupValue: widget.value?.toString(),
              onChanged: widget.disable ? null : (v) => widget.onChange(widget.name, v ?? ''),
            )),
      ],
    );
  }

  Widget _buildButton() {
    if (widget.validation == 'googleSignIn') {
      final loading = widget.googleSignInLoading;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabel(widget.displayName),
          OutlinedButton.icon(
            onPressed: widget.disable || loading
                ? null
                : () async {
                    if (widget.onGoogleSignIn != null) {
                      await widget.onGoogleSignIn!();
                    }
                  },
            icon: const Icon(Icons.g_mobiledata),
            label: Text(loading ? 'Signing in...' : 'Sign In with Google'),
          ),
        ],
      );
    }
    return TextButton(
      onPressed: () {
        final popups = widget.popupAfterSubmit ?? [];
        if (popups.isNotEmpty) {
          final popup = popups.cast<dynamic>().firstWhere(
            (p) => p is Map && p['fieldName'] == widget.name,
            orElse: () => popups.first,
          );
          final popupData = popup is Map ? Map<String, dynamic>.from(popup as Map) : <String, dynamic>{};
          showGeneralDialog(
            context: context,
            barrierDismissible: true,
            barrierLabel: '',
            barrierColor: Colors.black54,
            pageBuilder: (ctx, _, __) => PopupModal(
              popupData: popupData,
              onClose: () => Navigator.of(ctx).pop(),
              onSelect: (v) {
                widget.onChange(widget.name, v);
                Navigator.of(ctx).pop();
              },
              fieldName: widget.name,
            ),
          );
        }
      },
      child: Text('${widget.displayName}${widget.mandatory ? ' *' : ''}'),
    );
  }

  String _getAcceptedTypes() {
    if (widget.fileType == null || widget.fileType!.isEmpty) return '*';
    return widget.fileType!
        .map((ft) => ft is Map ? '.${ft['value'] ?? ''}' : '.$ft')
        .join(',');
  }

  Future<void> _handleFileSelection(File file) async {
    final maxBytes = (int.tryParse(widget.size?.toString() ?? '10') ?? 10) * 1024 * 1024;
    if (await file.length() > maxBytes) {
      setState(() => _fileError = 'File size must be less than ${widget.size}MB');
      return;
    }
    if (widget.fileType != null && widget.fileType!.isNotEmpty) {
      final ext = file.path.split('.').last.toLowerCase();
      final allowed = widget.fileType!
          .map((ft) => (ft is Map ? ft['value'] : ft).toString().toLowerCase())
          .toList();
      if (!allowed.contains(ext)) {
        setState(() => _fileError = 'Invalid file type. Allowed: ${allowed.join(", ")}');
        return;
      }
    }
    setState(() => _fileError = null);
    widget.onChange(widget.name, file);
  }

  bool get _isSignatureField {
    final n = widget.name.toLowerCase();
    final d = widget.displayName.toLowerCase();
    return n.contains('signature') || d.contains('signature');
  }

  Future<File?> _showDigitalSignatureDialog() async {
    final points = <Offset?>[];
    bool submitting = false;
    String? localError;
    const canvasSize = Size(860, 360);
    Size drawAreaSize = const Size(860, 360);

    Future<File?> buildSignatureFile() async {
      if (!points.any((p) => p != null)) return null;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final bgPaint = Paint()..color = Colors.white;
      canvas.drawRect(Offset.zero & canvasSize, bgPaint);

      final strokePaint = Paint()
        ..color = Colors.black
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      for (var i = 0; i < points.length - 1; i++) {
        final p1 = points[i];
        final p2 = points[i + 1];
        if (p1 != null && p2 != null) {
          final safeWidth = drawAreaSize.width <= 0 ? canvasSize.width : drawAreaSize.width;
          final safeHeight = drawAreaSize.height <= 0 ? canvasSize.height : drawAreaSize.height;
          final scaleX = canvasSize.width / safeWidth;
          final scaleY = canvasSize.height / safeHeight;
          final sp1 = Offset(p1.dx * scaleX, p1.dy * scaleY);
          final sp2 = Offset(p2.dx * scaleX, p2.dy * scaleY);
          canvas.drawLine(sp1, sp2, strokePaint);
        }
      }

      final picture = recorder.endRecording();
      final image = await picture.toImage(
        canvasSize.width.toInt(),
        canvasSize.height.toInt(),
      );
      final pngBytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (pngBytes == null) return null;

      final file = File(
        '${Directory.systemTemp.path}/digital_signature_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(pngBytes.buffer.asUint8List(), flush: true);
      return file;
    }

    return showDialog<File?>(
      context: context,
      barrierDismissible: !submitting,
      builder: (dialogCtx) {
        final media = MediaQuery.of(dialogCtx);
        final isMobile = media.size.width < 600;
        final horizontalPadding = isMobile ? 12.0 : 24.0;
        final dialogMaxWidth = isMobile ? media.size.width - 24 : 760.0;
        final pad = isMobile ? 12.0 : 20.0;
        final canvasHeight = isMobile ? 220.0 : 360.0;

        return StatefulBuilder(
          builder: (dialogCtx, setLocalState) {
            return Dialog(
              insetPadding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: isMobile ? 18 : 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: dialogMaxWidth),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.all(pad),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              onPressed: submitting
                                  ? null
                                  : () => Navigator.of(dialogCtx).pop(),
                              icon: const Icon(Icons.close, size: 28),
                            ),
                          ],
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F7FB),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFD8E1EA)),
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 12 : 18,
                            vertical: isMobile ? 10 : 14,
                          ),
                          child: const Text(
                            'Digital Signature',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF09184A),
                            ),
                          ),
                        ),
                        Container(
                          height: 3,
                          color: const Color(0xFF1DB7B9),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Please sign on screen, this will be captured as your authorized signature',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: isMobile ? 13 : 16,
                            color: const Color(0xFF1F1F1F),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          height: canvasHeight,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFC9CDD3)),
                          ),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              drawAreaSize = Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              );
                              return GestureDetector(
                                onPanStart: (details) {
                                  final p = details.localPosition;
                                  setLocalState(() => points.add(p));
                                },
                                onPanUpdate: (details) {
                                  final p = details.localPosition;
                                  setLocalState(() => points.add(p));
                                },
                                onPanEnd: (_) {
                                  setLocalState(() => points.add(null));
                                },
                                child: CustomPaint(
                                  painter: _SignaturePainter(points: points),
                                  size: Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (localError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            localError!,
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: submitting
                                    ? null
                                    : () {
                                        setLocalState(() {
                                          points.clear();
                                          localError = null;
                                        });
                                      },
                                style: OutlinedButton.styleFrom(
                                  minimumSize: Size(0, isMobile ? 48 : 52),
                                  side: const BorderSide(
                                    color: Color(0xFF6A5ACD),
                                  ),
                                  foregroundColor: const Color(0xFF6A5ACD),
                                  textStyle: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                child: const Text('Clear'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: submitting
                                    ? null
                                    : () async {
                                        if (!points.any((p) => p != null)) {
                                          setLocalState(() {
                                            localError =
                                                'Please draw your signature first.';
                                          });
                                          return;
                                        }
                                        setLocalState(() {
                                          submitting = true;
                                          localError = null;
                                        });
                                        final file = await buildSignatureFile();
                                        if (!dialogCtx.mounted) return;
                                        if (file == null) {
                                          setLocalState(() {
                                            submitting = false;
                                            localError =
                                                'Unable to capture signature. Please try again.';
                                          });
                                          return;
                                        }
                                        Navigator.of(dialogCtx).pop(file);
                                      },
                                style: ElevatedButton.styleFrom(
                                  minimumSize: Size(0, isMobile ? 48 : 52),
                                  backgroundColor: const Color(0xFF6A5ACD),
                                  foregroundColor: Colors.white,
                                  textStyle: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                child: submitting
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('Confirm'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFile() {
    final hasFile = widget.value != null && widget.value is File;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        if (widget.fileType != null || widget.size != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${widget.fileType != null ? "Allowed: ${(widget.fileType!).map((ft) => ft is Map ? ft['label'] : ft).join(', ')}" : ''}${widget.size != null ? ' • Max: ${widget.size}MB' : ''}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        InkWell(
          onTap: widget.disable ? null : () async {
              final result = await FilePicker.platform.pickFiles(type: FileType.any);
              if (result != null && result.files.single.path != null) {
                await _handleFileSelection(File(result.files.single.path!));
              }
            },
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              border: Border.all(
                color: _fileError != null ? Colors.red : Colors.grey.shade400,
                width: 2,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
              borderRadius: BorderRadius.circular(12),
              color: Colors.grey.shade50,
            ),
            child: hasFile
                ? Column(
                    children: [
                      Icon(Icons.insert_drive_file, size: 48, color: Colors.blue.shade600),
                      const SizedBox(height: 8),
                      Text(
                        (widget.value as File).path.split('/').last,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                      TextButton(
                        onPressed: () => widget.onChange(widget.name, null),
                        child: const Text('Remove'),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Icon(Icons.cloud_upload, size: 48, color: Colors.grey.shade600),
                      const SizedBox(height: 8),
                      const Text('Tap to browse or drop file'),
                    ],
                  ),
          ),
        ),
        if (_fileError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_fileError!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
          ),
        if (_isSignatureField) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: widget.disable
                  ? null
                  : () async {
                      final generatedFile = await _showDigitalSignatureDialog();
                      if (generatedFile == null) return;
                      await _handleFileSelection(generatedFile);
                    },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: const BorderSide(color: KycTheme.primary),
                foregroundColor: KycTheme.primary,
              ),
              child: const Text('Digital Signature'),
            ),
          ),
        ],
      ],
    );
  }

  /// OTP field – design: 6 square boxes, sirf user OTP dalega
  Widget _buildOtp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        const SizedBox(height: 12),
        OtpInput(
          length: 6,
          onChanged: (v) => widget.onChange(widget.name, v),
          onComplete: (v) => widget.onChange(widget.name, v),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset?> points;

  const _SignaturePainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      if (p1 != null && p2 != null) {
        canvas.drawLine(p1, p2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) =>
      oldDelegate.points != points;
}
