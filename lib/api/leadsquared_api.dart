import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/base_api.dart';
import 'package:meon_kyc/config/env_config.dart';

/// LeadSquared `Lead.Capture` — called after SSO success.
class LeadSquaredAPI {
  static Uri _captureUri() {
    return Uri.parse(EnvConfig.leadSquaredCaptureUrl).replace(
      queryParameters: {
        'accesskey': EnvConfig.leadSquaredAccessKey,
        'secretKey': EnvConfig.leadSquaredSecretKey,
      },
    );
  }

  static List<Map<String, String>> _buildBody({
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

  /// Returns `true` when LeadSquared accepts the lead (HTTP 2xx).
  static Future<bool> captureLead({
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
    final body = _buildBody(
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
    );

    debugPrint('[LeadSquared] Lead.Capture for phone=$mobileNumber email=$email');

    try {
      final res = await http
          .post(
            _captureUri(),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(BaseAPI.requestTimeout);

      debugPrint('[LeadSquared] response status=${res.statusCode}');

      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint(
          '[LeadSquared] failed: ${res.body.length > 400 ? res.body.substring(0, 400) + "..." : res.body}',
        );
        return false;
      }

      debugPrint('[LeadSquared] lead captured successfully');
      return true;
    } catch (e, st) {
      debugPrint('[LeadSquared] exception: $e\n$st');
      return false;
    }
  }
}
