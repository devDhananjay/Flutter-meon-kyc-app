import 'dart:convert';

import 'package:http/http.dart' as http;

class WorkflowListItem {
  final String workflowKey;
  final String workflowName;
  final String workflowType;
  final String status;

  const WorkflowListItem({
    required this.workflowKey,
    required this.workflowName,
    required this.workflowType,
    required this.status,
  });

  factory WorkflowListItem.fromJson(Map<String, dynamic> json) {
    return WorkflowListItem(
      workflowKey: json['work_flow_key']?.toString() ?? '',
      workflowName: json['workflowName']?.toString() ?? '',
      workflowType: json['workflow_type']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
    );
  }
}

class WorkflowLookupResult {
  final String company;
  final String secretKey;
  final List<WorkflowListItem> workflows;

  /// Display name from API (e.g. `full_company_name`).
  final String? fullCompanyName;

  /// Optional logo URL if backend sends any of the supported keys.
  final String? logoUrl;

  /// ARGB color from hex (e.g. `#2E5BFF`) if backend sends branding fields.
  final int? brandPrimaryArgb;

  const WorkflowLookupResult({
    required this.company,
    required this.secretKey,
    required this.workflows,
    this.fullCompanyName,
    this.logoUrl,
    this.brandPrimaryArgb,
  });
}

class WorkflowLookupApi {
  static const String _url =
      'https://live.meon.co.in/useradmin/email_as_input_and_return_workflow';
  static const String _headerSecret = 'dasdcvmonytfs@aq234niy434dssasf';

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  /// Parses `#RGB`, `#RRGGBB`, `#AARRGGBB` or without `#`. Returns full ARGB.
  static int? _parseHexArgb(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    var s = raw.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 3) {
      final r = s[0], g = s[1], b = s[2];
      s = '$r$r$g$g$b$b';
    }
    try {
      if (s.length == 6) {
        return int.parse(s, radix: 16) | 0xFF000000;
      }
      if (s.length == 8) {
        return int.parse(s, radix: 16);
      }
    } catch (_) {}
    return null;
  }

  static Future<WorkflowLookupResult> fetchByEmail(String email) async {
    final response = await http.post(
      Uri.parse(_url),
      headers: const {
        'Content-Type': 'application/json',
        'Secret-Key': _headerSecret,
      },
      body: jsonEncode({'email': email.trim()}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Workflow API failed with status ${response.statusCode}');
    }

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw Exception('Unexpected workflow API response');
    }

    final success = body['success'] == true;
    if (!success) {
      final msg = body['msg']?.toString() ?? 'Unable to fetch workflows';
      throw Exception(msg);
    }

    final companyMap = body['company'];
    if (companyMap is! Map<String, dynamic>) {
      throw Exception('Company details missing in workflow API response');
    }

    final company = companyMap['company']?.toString() ?? '';
    final secretKey = companyMap['secret_key']?.toString() ?? '';
    if (company.isEmpty || secretKey.isEmpty) {
      throw Exception('Company or secret key missing in workflow API response');
    }

    final fullCompanyName = _firstString(companyMap, [
      'full_company_name',
      'fullCompanyName',
      'company_display_name',
      'display_name',
    ]);
    final logoUrl = _firstString(companyMap, [
      'logo_url',
      'logoUrl',
      'company_logo',
      'company_logo_url',
      'logo',
      'brand_logo',
      'image_url',
    ]);
    final brandArgb = _parseHexArgb(
      _firstString(companyMap, [
        'brand_color',
        'primary_color',
        'theme_color',
        'accent_color',
        'brand_primary',
        'color',
      ]),
    );

    final rawList = body['workflow_list'];
    final workflows = rawList is List
        ? rawList
            .whereType<Map<String, dynamic>>()
            .map(WorkflowListItem.fromJson)
            .where((e) => e.workflowName.isNotEmpty)
            .toList()
        : <WorkflowListItem>[];

    if (workflows.isEmpty) {
      throw Exception('No workflows found for this email');
    }

    return WorkflowLookupResult(
      company: company,
      secretKey: secretKey,
      workflows: workflows,
      fullCompanyName: fullCompanyName,
      logoUrl: logoUrl,
      brandPrimaryArgb: brandArgb,
    );
  }
}
