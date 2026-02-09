/// Environment configuration for API URLs and default workflow
class EnvConfig {
  static const String apiUrlLocal = 'https://livetest.meon.co.in';
  static const String apiUrl = 'https://livetest.meon.co.in';

  /// Default company and workflow (static for now)
  static const String companyName = 'mandotsecurities'; //'bpwealth';
  static const String workflowName = 'bp_flow'; //'individual';


  static String get baseUrl {
    // In Flutter you can use kDebugMode or Platform to detect environment
    return apiUrl;
  }
}
