import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/config/env_config.dart';

/// Meon LeadSquared proxy — called before SSO on app load.
class LeadSquaredAPI {
  static const int _requestTimeoutSeconds = 120;

  static List<Map<String, String>> _buildPayloadAttributes({
    required String mobileNumber,
    required String email,
    String firstName = '',
    String ageGroup = '',
    String utmSource = '',
    String sourceMedium = '',
    String sourceCampaign = '',
    String adGroup = '',
    String commSource = '',
    String sourceContent = '',
  }) {
    return [
      {'Attribute': 'SearchBy', 'Value': 'Phone'},
      {'Attribute': 'FirstName', 'Value': firstName},
      {'Attribute': 'Phone', 'Value': mobileNumber},
      {'Attribute': 'EmailAddress', 'Value': email},
      {'Attribute': 'mx_Lead_Age_Group', 'Value': ageGroup},
      {'Attribute': 'Source', 'Value': utmSource},
      {'Attribute': 'mx_UTMSource', 'Value': utmSource},
      {'Attribute': 'SourceMedium', 'Value': sourceMedium},
      {'Attribute': 'SourceCampaign', 'Value': sourceCampaign},
      {'Attribute': 'mx_Ad_Group', 'Value': adGroup},
      {'Attribute': 'mx_CommSource', 'Value': commSource},
      {'Attribute': 'SourceContent', 'Value': sourceContent},
    ];
  }

  static String? _extractLeadId(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final message = data['Message'];
      if (message is! Map) return null;
      final id = message['Id']?.toString().trim();
      return id == null || id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  static bool _isSuccessResponse(int statusCode, String body) {
    if (statusCode < 200 || statusCode >= 300) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return true;
      if (decoded['success'] == true) return true;
      final data = decoded['data'];
      if (data is Map && data['Status']?.toString().toLowerCase() == 'success') {
        return true;
      }
      if (decoded['status_code'] == 200) return true;
    } catch (_) {
      return true;
    }
    return false;
  }

  /// Captures lead and returns `data.Message.Id` for SSO `additional_info.kyc_lead`.
  static Future<String?> captureLead({
    required String mobileNumber,
    required String email,
    String firstName = '',
    String ageGroup = '',
    String utmSource = '',
    String sourceMedium = '',
    String sourceCampaign = '',
    String adGroup = '',
    String commSource = '',
    String sourceContent = '',
  }) async {
    final url = EnvConfig.leadSquaredCaptureUrl;
    final body = <String, dynamic>{
      'payload': _buildPayloadAttributes(
        mobileNumber: mobileNumber,
        email: email,
        firstName: firstName,
        ageGroup: ageGroup,
        utmSource: utmSource,
        sourceMedium: sourceMedium,
        sourceCampaign: sourceCampaign,
        adGroup: adGroup,
        commSource: commSource,
        sourceContent: sourceContent,
      ),
      'timeout': _requestTimeoutSeconds,
    };

    debugPrint('[LeadSquared] POST $url phone=$mobileNumber email=$email');

    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: _requestTimeoutSeconds));

      debugPrint('[LeadSquared] response status=${res.statusCode}');

      if (!_isSuccessResponse(res.statusCode, res.body)) {
        debugPrint(
          '[LeadSquared] failed: ${res.body.length > 400 ? '${res.body.substring(0, 400)}...' : res.body}',
        );
        return null;
      }

      final leadId = _extractLeadId(res.body);
      debugPrint('[LeadSquared] lead captured id=$leadId');
      return leadId;
    } catch (e, st) {
      debugPrint('[LeadSquared] exception: $e\n$st');
      return null;
    }
  }
}
