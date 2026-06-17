/// Environment configuration for API URLs and default workflow
class EnvConfig {
  static const String apiUrlLocal = 'https://ekyc.stoxbox.in';
  static const String apiUrl = 'https://ekyc.stoxbox.in';
  static const String ssoSecretKey = 'IBZmvgxvGUHgxNVpoXoK1c3fFVL76P0j';

  /// LeadSquared — post-SSO lead capture.
  static const String leadSquaredCaptureUrl =
      'https://api-in21.leadsquared.com/v2/LeadManagement.svc/Lead.Capture';
  static const String leadSquaredAccessKey =
      'u\$r5e49670778798d286f3fcb356cca1703';
  static const String leadSquaredSecretKey =
      'd1262f92326a1086ee63314b4e81fc1eede4c084';

  /// Default company and workflow (static for now)
  static const String companyName = 'bpwealth'; //'bpwealth'; mandotsecurities
  static const String workflowName = 'individual'; //'bp_flow'; individual ind_bp


  static String get baseUrl {
    // In Flutter you can use kDebugMode or Platform to detect environment
    return apiUrl;
  }
}