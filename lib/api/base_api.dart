import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/services/storage_service.dart';

class BaseAPI {
  static final BaseAPI _instance = BaseAPI._internal();
  factory BaseAPI() => _instance;

  BaseAPI._internal();

  String get _baseUrl => EnvConfig.baseUrl;

  static void _log(String tag, String message, [String? extra]) {
    debugPrint('[API $tag] $message${extra != null ? '\n$extra' : ''}');
  }

  static String _truncate(String s, [int max = 600]) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}... (${s.length} chars)';
  }

  Future<http.Response> get(String path, {Map<String, String>? headers}) async {
    final url = '$_baseUrl$path';
    _log('GET', 'Request: $url');
    final token = await StorageService.getAccessToken();
    final h = {...?headers, 'Content-Type': 'application/json'};
    if (token != null) h['Authorization'] = 'Bearer $token';
    try {
      final res = await http.get(Uri.parse(url), headers: h);
      _log('GET', 'Response ${res.statusCode}: $url', _truncate(res.body));
      return res;
    } catch (e, st) {
      _log('GET', 'Error: $url', '$e\n$st');
      rethrow;
    }
  }

  Future<http.Response> post(
    String path, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    final url = '$_baseUrl$path';
    final bodyStr = body == null
        ? null
        : body is Map || body is List
            ? jsonEncode(body)
            : body.toString();
    _log('POST', 'Request: $url', 'body: ${_truncate(bodyStr ?? '{}')}');
    final token = await StorageService.getAccessToken();
    final h = Map<String, String>.from(headers ?? {});
    if (!h.containsKey('Content-Type')) {
      h['Content-Type'] = 'application/json';
    }
    if (token != null) h['Authorization'] = 'Bearer $token';
    try {
      final res = await http.post(
        Uri.parse(url),
        headers: h,
        body: bodyStr ?? '{}',
      );
      _log('POST', 'Response ${res.statusCode}: $path', _truncate(res.body));
      
      // Extract and print the position (only if response has context)
      if (res.statusCode == 200) {
        try {
          final responseData = json.decode(res.body);
          if (responseData is Map && responseData.containsKey('context')) {
            final context = responseData['context'];
            if (context is Map && context.containsKey('position')) {
              final position = context['position'];
              print('Position: $position');
            }
          }
        } catch (_) {
          // Ignore for responses without context (like IFSC API)
        }
      }

      return res;
    } catch (e, st) {
      _log('POST', 'Error: $url', '$e\n$st');
      rethrow;
    }
  }
}
