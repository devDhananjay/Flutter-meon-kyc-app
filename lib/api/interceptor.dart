import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/services/storage_service.dart';

class ApiInterceptor {
  static bool _isRefreshing = false;
  static final List<void Function()> _onRefreshComplete = [];

  static Future<http.Response> request(Future<http.Response> Function() fn) async {
    var response = await fn();
    debugPrint('[ApiInterceptor] Response status: ${response.statusCode}');
    if (response.statusCode == 401 || response.statusCode == 422) {
      debugPrint('[ApiInterceptor] 401/422 - attempting refresh');
      if (_isRefreshing) {
        await _waitForRefresh();
        return fn();
      }
      _isRefreshing = true;
      try {
        final refreshed = await _refreshToken();
        if (refreshed) {
          response = await fn();
        } else {
          await StorageService.clearAll();
          Fluttertoast.showToast(msg: 'Token is Expired');
        }
      } catch (e) {
        await StorageService.clearAll();
        Fluttertoast.showToast(msg: 'Token is Expired');
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
    if (refreshToken == null || refreshToken.isEmpty) return false;

    final res = await http.post(
      Uri.parse('${EnvConfig.baseUrl}/api/user/refresh'),
      headers: {'Authorization': 'Bearer $refreshToken'},
    );

    if (res.statusCode == 401 || res.statusCode == 422) return false;

    final data = jsonDecode(res.body) as Map<String, dynamic>?;
    final accessToken = data?['access_token'] as String?;
    final newRefresh = data?['refresh_token'] as String?;

    if (accessToken != null) {
      await StorageService.setAccessToken(accessToken);
      if (newRefresh != null) await StorageService.setRefreshToken(newRefresh);
      return true;
    }
    return false;
  }
}
