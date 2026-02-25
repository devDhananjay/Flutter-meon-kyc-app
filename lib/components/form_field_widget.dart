import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:meon_kyc/components/otp_input.dart';
import 'package:meon_kyc/components/popup_modal.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

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

  @override
  void initState() {
    super.initState();
    _initializeControllers();
  }

  void _initializeControllers() {
    final value = widget.value?.toString() ?? '';
    if (widget.type == 'text') {
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
    // Only update controller if value changed externally (not from user typing)
    final newValue = widget.value?.toString() ?? '';
    final oldValue = oldWidget.value?.toString() ?? '';
    
    if (newValue != oldValue) {
      String textValue = newValue;
      if (widget.type == 'text' && _textController != null) {
        if (_isMobileField) {
          final digits = newValue.replaceAll(RegExp(r'\D'), '');
          textValue = digits.length > 10 ? digits.substring(0, 10) : digits;
        }
        if (_textController!.text != textValue) {
          _textController!.text = textValue;
        }
      } else if (widget.type == 'number' && _numberController != null) {
        if (_isMobileField) {
          final digits = newValue.replaceAll(RegExp(r'\D'), '');
          textValue = digits.length > 10 ? digits.substring(0, 10) : digits;
        }
        if (_numberController!.text != textValue) {
          _numberController!.text = textValue;
        }
      } else if (widget.type == 'textarea' && _textareaController != null) {
        if (_textareaController!.text != newValue) {
          _textareaController!.text = newValue;
        }
      } else if (widget.type == 'password' && _passwordController != null) {
        if (_passwordController!.text != newValue) {
          _passwordController!.text = newValue;
        }
      }
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
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                const SizedBox(width: 4),
                Text(
                  widget.errorField!,
                  style: TextStyle(fontSize: 12, color: Colors.red.shade700),
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
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: KycTheme.textPrimary,
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
    // Number fields
    if (type == 'number' || validation == 'number') {
      return const Icon(Icons.numbers_outlined, color: KycTheme.textSecondary);
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

  Widget _buildText() {
    if (_textController == null) {
      String raw = widget.value?.toString() ?? '';
      if (_isMobileField) {
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        raw = digits.length > 10 ? digits.substring(0, 10) : digits;
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
          keyboardType: _isMobileField ? TextInputType.number : TextInputType.text,
          maxLength: _isMobileField ? 10 : null,
          inputFormatters: _isMobileField
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ]
              : null,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: InputDecoration(
            hintText: _isMobileField ? 'Enter Mobile number *' : '${widget.displayName}',
            border: const OutlineInputBorder(),
            prefixIcon: _isMobileField
                ? null
                : _getFieldIcon(),
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
            counterText: _isMobileField ? '' : null,
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
          keyboardType: _isMobileField ? TextInputType.number : TextInputType.number,
          maxLength: _isMobileField ? 10 : null,
          inputFormatters: _isMobileField
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ]
              : null,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: InputDecoration(
            hintText: _isMobileField ? 'Enter Mobile number *' : '${widget.displayName}',
            border: const OutlineInputBorder(),
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
          maxLines: widget.rows ?? 3,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: InputDecoration(
            hintText: '${widget.displayName}',
            border: const OutlineInputBorder(),
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
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: InputDecoration(
            hintText: '${widget.displayName}',
            border: const OutlineInputBorder(),
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
    final options = widget.values ?? [];
    
    // Validate value: only use it if it's not empty AND exists in options
    final currentValue = widget.value?.toString();
    final isValidValue = currentValue != null && 
                         currentValue.isNotEmpty && 
                         options.any((e) => e.toString() == currentValue);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        DropdownButtonFormField<String>(
          value: isValidValue ? currentValue : null, // Only set if valid, else show hint
          decoration: const InputDecoration(border: OutlineInputBorder()),
          hint: Text(widget.displayName),
          isExpanded: true, // Prevents overflow by expanding to available width
          items: options
              .map((e) => DropdownMenuItem(
                    value: e.toString(),
                    child: Text(
                      e.toString(),
                      overflow: TextOverflow.ellipsis, // Truncate long text with ...
                      maxLines: 1,
                    ),
                  ))
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
                  final d = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) {
                    widget.onChange(widget.name, d.toIso8601String().split('T')[0]);
                    widget.onBlur?.call(widget.name);
                  }
                },
          child: InputDecorator(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              prefixIcon: _getFieldIcon(),
            ),
            child: Text(
              widget.value?.toString() ?? 'Select date',
              style: TextStyle(
                color: widget.value != null ? null : Colors.grey,
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabel(widget.displayName),
          OutlinedButton.icon(
            onPressed: () {}, // Google Sign-In requires platform setup
            icon: const Icon(Icons.g_mobiledata),
            label: const Text('Sign In with Google'),
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
