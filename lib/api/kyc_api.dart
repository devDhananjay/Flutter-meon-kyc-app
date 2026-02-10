import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/config/env_config.dart';

class KycAPI {
  static final _client = ApiClient();
  static final _baseUrl = EnvConfig.baseUrl;

  static Future<http.Response> submitKyc(
    String urlCompany,
    String urlWorkflowName,
    dynamic dataToSend,
    Map<String, String> headers,
  ) async {
    return _client.post(
      '/api/get-user/$urlCompany/$urlWorkflowName',
      body: dataToSend is Map ? dataToSend : (dataToSend is String ? jsonDecode(dataToSend) : dataToSend),
      headers: headers,
    );
  }

  static Future<http.Response> submitKycV2(
    String urlCompany,
    String urlWorkflowName,
    String position,
    String index,
    dynamic dataToSend,
    Map<String, String> headers,
  ) async {
    return _client.post(
      '/api/kyc-post-v2/$urlCompany/$urlWorkflowName/$position$index',
      body: dataToSend is Map ? dataToSend : jsonDecode(dataToSend.toString()),
      headers: headers,
    );
  }

  static Future<http.Response> pdfPasswordCheck(
    String urlCompany,
    String workflowKey,
    Map<String, dynamic> dataToSend,
  ) async {
    final uri = Uri.parse('$_baseUrl/pdfPassCheck/$workflowKey');
    final request = http.MultipartRequest('POST', uri);
    if (dataToSend['financial'] != null && dataToSend['financial'] is File) {
      request.files.add(await http.MultipartFile.fromPath(
        'financial',
        (dataToSend['financial'] as File).path,
      ));
    }
    final stream = await request.send();
    return http.Response.fromStream(stream);
  }

  static Future<http.Response> verifyPdfPassword(
    String pdfPassword,
    String workflowKey,
    Map<String, dynamic> dataToSend,
  ) async {
    final uri = Uri.parse('$_baseUrl/verifyPdfPassword/$pdfPassword/$workflowKey');
    final request = http.MultipartRequest('POST', uri);
    if (dataToSend['financial'] != null && dataToSend['financial'] is File) {
      request.files.add(await http.MultipartFile.fromPath(
        'financial',
        (dataToSend['financial'] as File).path,
      ));
    }
    final stream = await request.send();
    return http.Response.fromStream(stream);
  }

  static Future<http.Response> getUserDetails() async {
    return _client.post('/api/user-details', body: {});
  }

  static Future<http.Response> getStepperWorkflow(String company, String workflowId) async {
    return _client.post('/kycadmin_getWorkflow/$company/$workflowId', body: {});
  }
}
