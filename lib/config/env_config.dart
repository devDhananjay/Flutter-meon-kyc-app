/// Environment configuration for API URLs and default workflow
class EnvConfig {
  static const String apiUrlLocal = 'https://ekyc.stoxbox.in';
  static const String apiUrl = 'https://ekyc.stoxbox.in';
  static const String ssoSecretKey = 'IBZmvgxvGUHgxNVpoXoK1c3fFVL76P0j';

  /// Default company and workflow (static for now)
  static const String companyName = 'bpwealth'; //'bpwealth'; mandotsecurities
  static const String workflowName = 'individual'; //'bp_flow'; individual ind_bp


  static String get baseUrl {
    // In Flutter you can use kDebugMode or Platform to detect environment
    return apiUrl;
  }
}