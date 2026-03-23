/// Environment configuration for API URLs and default workflow
class EnvConfig {
  static const String apiUrlLocal = 'https://live.meon.co.in';
  static const String apiUrl = 'https://live.meon.co.in';

  /// Default company and workflow (static for now)
  static const String companyName = 'bpwealth'; //'bpwealth'; mandotsecurities
  static const String workflowName = 'individual'; //'bp_flow'; individual


  static String get baseUrl {
    // In Flutter you can use kDebugMode or Platform to detect environment
    return apiUrl;
  }
}