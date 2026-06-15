import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:meon_kyc/api/base_api.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/services/storage_service.dart';

class ApiInterceptor {
  static bool _isRefreshing = false;
  static final List<void Function()> _onRefreshComplete = [];

  static Future<http.Response> request(Future<http.Response> Function() fn) async {
    var response = await fn();
    debugPrint('[ApiInterceptor] Response status: ${response.statusCode}');
    if (response.statusCode == 401 || response.statusCode == 422) {
      debugPrint('[ApiInterceptor] 401/422 - token expired or invalid, attempting refresh');
      if (_isRefreshing) {
        debugPrint('[ApiInterceptor] Refresh already in progress - waiting then retrying');
        await _waitForRefresh();
        return fn();
      }
      _isRefreshing = true;
      try {
        final refreshed = await _refreshToken();
        if (refreshed) {
          debugPrint('[ApiInterceptor] Refresh success - retrying original request with new token');
          response = await fn();
          debugPrint('[ApiInterceptor] Retry response status: ${response.statusCode}');
        } else {
          debugPrint('[ApiInterceptor] Refresh failed - clearing session');
          await StorageService.clearAll();
          Fluttertoast.showToast(
            msg: 'Session expired. Please sign in again.',
            gravity: ToastGravity.TOP,
          );
        }
      } catch (e, st) {
        debugPrint('[ApiInterceptor] Refresh exception: $e\n$st');
        await StorageService.clearAll();
        Fluttertoast.showToast(
          msg: 'Session expired. Please sign in again.',
          gravity: ToastGravity.TOP,
        );
        rethrow;
      } finally {
        _isRefreshing = false;
        for (final cb in _onRefreshComplete) cb();
        _onRefreshComplete.clear();
      }
    }
    return response;
  }

  static Future<void> _waitForRefresh() async {
    final c = Completer<void>();
    _onRefreshComplete.add(() => c.complete());
    return c.future;
  }

  static Future<bool> _refreshToken() async {
    final refreshToken = await StorageService.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('[ApiInterceptor] No refresh token in storage - cannot refresh');
      return false;
    }

    final url = '${EnvConfig.baseUrl}/api/user/refresh';
    debugPrint('[ApiInterceptor] Calling refresh API: $url');
    final res = await http
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $refreshToken',
          },
        )
        .timeout(BaseAPI.requestTimeout);

    debugPrint('[ApiInterceptor] Refresh API response: ${res.statusCode}');
    if (res.statusCode != 200 && res.statusCode != 201) {
      debugPrint('[ApiInterceptor] Refresh failed: ${res.body.length > 200 ? res.body.substring(0, 200) + '...' : res.body}');
      return false;
    }

    Map<String, dynamic>? data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[ApiInterceptor] Refresh response parse error: $e');
      return false;
    }

    // Support both "access_token" and "token" keys
    final accessToken = data?['access_token'] as String? ?? data?['token'] as String?;
    final newRefresh = data?['refresh_token'] as String? ?? data?['refresh'] as String?;

    if (accessToken != null && accessToken.isNotEmpty) {
      await StorageService.setAccessToken(accessToken);
      if (newRefresh != null && newRefresh.isNotEmpty) {
        await StorageService.setRefreshToken(newRefresh);
      }
      debugPrint('[ApiInterceptor] New access token stored successfully');
      return true;
    }
    debugPrint('[ApiInterceptor] Refresh response missing access_token/token');
    return false;
  }
}
