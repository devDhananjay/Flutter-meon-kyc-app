import 'dart:async';
import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/otp_input.dart';

/// OTP verify block: instruction + Edit, single OTP input, Resend countdown, Verify button
/// OTP expiry comes from API: fields[].otpExpiry
class OtpVerifySection extends StatefulWidget {
  /// e.g. "We have sent you an OTP via sms on +91 9291929192" or "We have sent you an OTP on abc@gmail.com"
  final String sentToText;
  final VoidCallback? onEdit;
  final void Function(String otp) onVerify;
  final VoidCallback? onResendOtp;
  /// OTP expiry config from API: {expiryTime, isExpiryEnabled, time}
  final Map<String, dynamic>? otpExpiry;
  final bool verifyLoading;
  /// OTP length (default: 6)
  final int otpLength;
  /// When true, show 6 separate OTP boxes (email_otp); when false, single field (mobile_otp)
  final bool useSixBoxes;

  const OtpVerifySection({
    super.key,
    required this.sentToText,
    this.onEdit,
    required this.onVerify,
    this.onResendOtp,
    this.otpExpiry,
    this.verifyLoading = false,
    this.otpLength = 6,
    this.useSixBoxes = false,
  });

  @override
  State<OtpVerifySection> createState() => _OtpVerifySectionState();
}

class _OtpVerifySectionState extends State<OtpVerifySection> {
  String _otp = '';
  int _remainingSeconds = 0;
  Timer? _timer;
  bool _isExpired = false;

  @override
  void initState() {
    super.initState();
    _initializeTimer();
  }

  void _initializeTimer() {
    // Get expiry config from API
    final expiry = widget.otpExpiry;
    if (expiry != null && expiry['isExpiryEnabled'] == true) {
      final timeSeconds = int.tryParse(expiry['time']?.toString() ?? '0') ?? 0;
      if (timeSeconds > 0) {
        _remainingSeconds = timeSeconds;
        _isExpired = false;
        _startTimer();
        return;
      }
    }
    // Fallback: no expiry or invalid config
    _remainingSeconds = 0;
    _isExpired = false;
  }

  void _startTimer() {
    _timer?.cancel();
    if (_remainingSeconds <= 0) {
      _isExpired = true;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_remainingSeconds <= 1) {
          _remainingSeconds = 0;
          _isExpired = true;
          _timer?.cancel();
        } else {
          _remainingSeconds--;
        }
      });
    });
  }

  @override
  void didUpdateWidget(OtpVerifySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update timer if expiry config changed
    if (oldWidget.otpExpiry != widget.otpExpiry) {
      _timer?.cancel();
      _initializeTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timerText {
    final m = _remainingSeconds ~/ 60;
    final s = _remainingSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}min';
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _remainingSeconds == 0 && widget.onResendOtp != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Instruction: "We have sent you an OTP via sms on +91 XXXXX" Edit
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                widget.sentToText,
                style: TextStyle(
                  fontSize: 14,
                  color: KycTheme.textPrimary,
                ),
              ),
            ),
            if (widget.onEdit != null)
              GestureDetector(
                onTap: widget.onEdit,
                child: Text(
                  'Edit',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        // OTP input: 6 boxes for email_otp, single field for mobile_otp
        if (widget.useSixBoxes)
          OtpInputSixBoxes(
            length: widget.otpLength,
            onChanged: (v) => setState(() => _otp = v),
            onComplete: (v) => setState(() => _otp = v),
          )
        else
          OtpInput(
            length: widget.otpLength,
            onChanged: (v) => setState(() => _otp = v),
            onComplete: (v) => setState(() => _otp = v),
          ),
        const SizedBox(height: 16),
        // Didn't receive OTP? Resend OTP in MM:SS
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            Text(
              "Didn't receive OTP? ",
              style: TextStyle(
                fontSize: 13,
                color: KycTheme.textSecondary,
              ),
            ),
            if (_remainingSeconds == 0 && !_isExpired && widget.onResendOtp != null)
              GestureDetector(
                onTap: () {
                  widget.onResendOtp?.call();
                  _initializeTimer(); // Reset timer on resend
                },
                child: Text(
                  'Resend OTP',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              )
            else if (_remainingSeconds > 0)
              Text(
                'Resend OTP in $_timerText',
                style: TextStyle(
                  fontSize: 13,
                  color: KycTheme.textSecondary,
                ),
              )
            else if (_isExpired && widget.onResendOtp != null)
              GestureDetector(
                onTap: () {
                  widget.onResendOtp?.call();
                  _initializeTimer(); // Reset timer on resend
                },
                child: Text(
                  'Resend OTP',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        // Verify button - disabled if expired or incomplete
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: (widget.verifyLoading || _otp.length != widget.otpLength || _isExpired)
                ? null
                : () => widget.onVerify(_otp),
            style: ElevatedButton.styleFrom(
              backgroundColor: KycTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: widget.verifyLoading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Verify'),
          ),
        ),
      ],
    );
  }
}
