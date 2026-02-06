import 'dart:async';
import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/otp_input.dart';

/// OTP verify block as per design: instruction + Edit, 6 boxes (sirf user OTP dalega), Resend countdown, Verify button
class OtpVerifySection extends StatefulWidget {
  /// e.g. "We have sent you an OTP via sms on +91 9291929192" or "We have sent you an OTP on abc@gmail.com"
  final String sentToText;
  final VoidCallback? onEdit;
  final void Function(String otp) onVerify;
  final VoidCallback? onResendOtp;
  /// Resend cooldown in seconds (e.g. 300 for 05:00)
  final int resendCooldownSeconds;
  final bool verifyLoading;

  const OtpVerifySection({
    super.key,
    required this.sentToText,
    this.onEdit,
    required this.onVerify,
    this.onResendOtp,
    this.resendCooldownSeconds = 300,
    this.verifyLoading = false,
  });

  @override
  State<OtpVerifySection> createState() => _OtpVerifySectionState();
}

class _OtpVerifySectionState extends State<OtpVerifySection> {
  String _otp = '';
  int _remainingSeconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.resendCooldownSeconds;
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_remainingSeconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_remainingSeconds <= 1) {
          _remainingSeconds = 0;
          _timer?.cancel();
        } else {
          _remainingSeconds--;
        }
      });
    });
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
        // 6 OTP boxes – sirf user OTP dalega (design: six distinct square input boxes)
        OtpInput(
          length: 6,
          onChanged: (v) => setState(() => _otp = v),
          onComplete: (v) => setState(() => _otp = v),
        ),
        const SizedBox(height: 16),
        // Didn't receive OTP? Resend OTP in 05:00min
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Didn't receive OTP? ",
              style: TextStyle(
                fontSize: 13,
                color: KycTheme.textSecondary,
              ),
            ),
            if (canResend)
              GestureDetector(
                onTap: () {
                  widget.onResendOtp?.call();
                  setState(() => _remainingSeconds = widget.resendCooldownSeconds);
                  _startTimer();
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
            else
              Text(
                'Resend OTP in $_timerText',
                style: TextStyle(
                  fontSize: 13,
                  color: KycTheme.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        // Verify button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: (widget.verifyLoading || _otp.length != 6)
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
                : const Text('Verify OTP'),
          ),
        ),
      ],
    );
  }
}
