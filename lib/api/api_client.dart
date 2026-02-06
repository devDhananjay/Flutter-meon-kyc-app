import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/base_api.dart';
import 'package:meon_kyc/api/interceptor.dart';
import 'package:meon_kyc/services/storage_service.dart';

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  final _base = BaseAPI();

  ApiClient._internal();

  Future<http.Response> get(String path) async {
    return ApiInterceptor.request(() => _base.get(path));
  }

  Future<http.Response> post(
    String path, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    return ApiInterceptor.request(() => _base.post(path, body: body, headers: headers));
  }

  Future<http.Response> postMultipart(http.MultipartRequest request) async {
    final url = request.url.toString();
    debugPrint('[API MULTIPART] Request: $url');
    debugPrint('[API MULTIPART] fields: ${request.fields}');
    final token = await StorageService.getAccessToken();
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    try {
      final stream = await request.send();
      final res = await http.Response.fromStream(stream);
      final bodyPreview = res.body.length > 600 ? '${res.body.substring(0, 600)}...' : res.body;
      debugPrint('[API MULTIPART] Response ${res.statusCode}: $url\n$bodyPreview');
      return res;
    } catch (e, st) {
      debugPrint('[API MULTIPART] Error: $url\n$e\n$st');
      rethrow;
    }
  }
}
