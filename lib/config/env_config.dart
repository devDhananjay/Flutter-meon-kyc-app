/// Environment configuration for API URLs and default workflow
class EnvConfig {
  static const String apiUrlLocal = 'https://livetest.meon.co.in'; //n 'https://ekyc.stoxbox.in/    https://live.meon.co.in
  static const String apiUrl = 'https://livetest.meon.co.in'; //n 'https://live.meon.co.in
  static const String ssoSecretKey = '1lmJpNlNFdNIhIDp9a1Cf5Joyyt3PhG0';

  /// Default company and workflow (static for now)
  static const String companyName = 'bpwealth'; //'bpwealth'; mandotsecurities
  static const String workflowName = 'individual'; //'bp_flow'; individual ind_bp


  static String get baseUrl {
    // In Flutter you can use kDebugMode or Platform to detect environment
    return apiUrl;
  }
}