import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ApiService {
  static Future<Map<String, dynamic>> changePassword({
    required String currentPassword,
    required String newPassword,
    String? accessToken,
  }) async {
    final payload = {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
      'oldPassword': currentPassword,
      'password': newPassword,
      'confirmPassword': newPassword,
    };

    final endpoints = [
      '/auth/change-password',
      '/users/change-password',
      '/user/change-password',
      '/auth/update-password',
    ];

    for (final endpoint in endpoints) {
      try {
        final response = await http.post(
          Uri.parse('$baseUrl$endpoint'),
          headers: _jsonHeaders(accessToken: accessToken),
          body: jsonEncode(payload),
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) {
            return {
              'success': true,
              'message': 'Password updated successfully.',
            };
          }

          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            return {
              'success': true,
              ...data,
            };
          }

          return {
            'success': true,
            'message': 'Password updated successfully.',
          };
        }

        // Try the next endpoint if this one does not exist.
        if (response.statusCode == 404) {
          continue;
        }

        String message = 'Failed to change password.';
        if (response.body.isNotEmpty) {
          try {
            final error = jsonDecode(response.body);
            if (error is Map<String, dynamic>) {
              message =
                  (error['message'] ?? error['error'] ?? message).toString();
            }
          } catch (_) {}
        }

        return {
          'success': false,
          'message': message,
          'statusCode': response.statusCode,
        };
      } catch (_) {
        // Network or parsing issue on this endpoint; try the next one.
      }
    }

    return {
      'success': false,
      'message': 'Change password endpoint not available or request failed.',
    };
  }

  static const String _prodUrl = 'https://www.tax.garowecity.pl.so/api';
  // ASP.NET local API default.
  static const String _devUrl = 'http://localhost:5099/api';
  static const bool _useProduction = true;
  static const String _overrideBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: '');
  static const int _loginMaxAttempts = 2;
  static const Duration _loginRetryDelay = Duration(milliseconds: 700);

  static final String baseUrl = _overrideBaseUrl.isNotEmpty
      ? _overrideBaseUrl
      : (_useProduction ? _prodUrl : _devUrl);

  static bool _isTransientStatus(int statusCode) {
    return statusCode == 429 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  static Map<String, String> _jsonHeaders({String? accessToken}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (accessToken != null && accessToken.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }

    return headers;
  }

  static Map<String, String> _acceptHeaders({String? accessToken}) {
    final headers = <String, String>{'Accept': 'application/json'};

    if (accessToken != null && accessToken.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }

    return headers;
  }

  static Map<String, dynamic> _normalizeLoginResponse(
      Map<String, dynamic> raw) {
    final nestedUser = raw['user'];

    if (nestedUser is Map<String, dynamic>) {
      return {
        'id': nestedUser['id'],
        'username': nestedUser['username'],
        'role': nestedUser['role'],
        'permissions': raw['permissions'] ?? <String>[],
        'accessToken': raw['accessToken'] ??
            raw['token'] ??
            raw['access_token'] ??
            nestedUser['accessToken'] ??
            nestedUser['token'],
        'expiresIn': raw['expiresIn'] ?? raw['expires_in'],
      };
    }

    return {
      'id': raw['id'],
      'username': raw['username'],
      'role': raw['role'],
      'permissions': raw['permissions'] ?? <String>[],
      'accessToken': raw['accessToken'] ?? raw['token'] ?? raw['access_token'],
      'expiresIn': raw['expiresIn'] ?? raw['expires_in'],
    };
  }

  // LOGIN
  static Future<Map<String, dynamic>> login(
      String username, String password) async {
    for (var attempt = 1; attempt <= _loginMaxAttempts; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse('$baseUrl/auth/login'),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({
                "username": username,
                "password": password,
              }),
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) {
            throw Exception('Unexpected login response format.');
          }

          return _normalizeLoginResponse(decoded);
        }

        if (_isTransientStatus(response.statusCode) &&
            attempt < _loginMaxAttempts) {
          await Future.delayed(_loginRetryDelay);
          continue;
        }

        String? backendMessage;
        if (response.body.isNotEmpty) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map<String, dynamic>) {
              backendMessage = decoded['message']?.toString();
            }
          } catch (_) {
            // Ignore invalid JSON and fall back to status-based message.
          }
        }

        if (response.statusCode == 401 || response.statusCode == 403) {
          throw Exception(
            backendMessage?.isNotEmpty == true
                ? backendMessage
                : 'Invalid username or password.',
          );
        }

        if (response.statusCode >= 500) {
          throw Exception(
            'Server is temporarily unavailable. Please try again in a moment.',
          );
        }

        throw Exception(
          backendMessage?.isNotEmpty == true
              ? backendMessage
              : 'Login failed. Please check your details and try again.',
        );
      } on TimeoutException {
        if (attempt < _loginMaxAttempts) {
          await Future.delayed(_loginRetryDelay);
          continue;
        }

        throw Exception(
          'Server timeout at $baseUrl. Backend may be down; try again shortly.',
        );
      } on SocketException {
        if (attempt < _loginMaxAttempts) {
          await Future.delayed(_loginRetryDelay);
          continue;
        }

        throw Exception(
          'Cannot reach server ($baseUrl). Ensure backend is running or switch API URL.',
        );
      } on http.ClientException {
        if (attempt < _loginMaxAttempts) {
          await Future.delayed(_loginRetryDelay);
          continue;
        }

        throw Exception('Network/client error while connecting to $baseUrl.');
      }
    }

    throw Exception('Login failed. Please try again.');
  }

  // GET VEHICLE BY PLATE
  static Future<Map<String, dynamic>?> getVehicle(String plate,
      {String? accessToken}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/vehicles/by-plate/$plate'),
      headers: _acceptHeaders(accessToken: accessToken),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }

    return null;
  }

  // GET TAX AMOUNT
  static Future<double> getTaxAmount(int carTypeId, String movement,
      {String? accessToken}) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/tax/amount?carTypeId=$carTypeId&movement=$movement',
      ),
      headers: _acceptHeaders(accessToken: accessToken),
    );

    if (response.statusCode == 200) {
      return (jsonDecode(response.body)['amount'] as num).toDouble();
    }

    return 0.0;
  }

  static Future<double?> getTaxAmountByMovement(
    int carTypeId,
    int movementId, {
    String? accessToken,
  }) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/tax/amount-by-movement?carTypeId=$carTypeId&movementId=$movementId',
      ),
      headers: _acceptHeaders(accessToken: accessToken),
    );

    if (response.statusCode == 200) {
      return (jsonDecode(response.body)['amount'] as num).toDouble();
    }

    return null;
  }

  static Future<List<Map<String, dynamic>>> getMovementsByCarType(
    int carTypeId, {
    String? accessToken,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/movements/by-car-type/$carTypeId'),
      headers: _acceptHeaders(accessToken: accessToken),
    );

    if (response.statusCode != 200) {
      return const <Map<String, dynamic>>[];
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      final items = decoded['items'];
      if (items is List) {
        return items.whereType<Map<String, dynamic>>().toList();
      }
    }

    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList();
    }

    return const <Map<String, dynamic>>[];
  }

  // PAY
  // returns:
  //   null -> success
  //   Map  -> backend error
  static Future<http.Response> _postPayment(
      String path, Map<String, dynamic> data,
      {String? accessToken}) {
    return http.post(
      Uri.parse('$baseUrl$path'),
      headers: _jsonHeaders(accessToken: accessToken),
      body: jsonEncode(data),
    );
  }

  static Map<String, dynamic> normalizePaymentResponse(
    dynamic body, {
    int? statusCode,
  }) {
    if (body is Map) {
      final decoded = Map<String, dynamic>.from(body);
      final receipt = decoded['receipt'];
      final receiptMap = receipt is Map ? Map<String, dynamic>.from(receipt) : null;

      final merged = <String, dynamic>{...decoded};
      if (receiptMap != null) {
        for (final entry in receiptMap.entries) {
          final key = entry.key.toString();
          if (!merged.containsKey(key)) {
            merged[key] = entry.value;
          }
        }
      }

      final isSuccess = merged['status'] == 'success' ||
          (merged['message']?.toString().toLowerCase() ?? '').contains('success') ||
          merged['paymentId'] != null ||
          merged['invoiceId'] != null;

      final normalized = <String, dynamic>{'success': isSuccess, ...merged};

      if (merged['status'] == 'error' || statusCode != null && statusCode >= 400) {
        normalized['success'] = false;
      }

      return normalized;
    }

    if (body is String && body.trim().isNotEmpty) {
      return {'success': false, 'message': body.trim()};
    }

    return {'success': false, 'message': 'Payment failed. Please try again.'};
  }

  static Map<String, dynamic> normalizeReceiptResponse(dynamic body) {
    if (body is! Map) {
      return <String, dynamic>{};
    }

    final topLevel = Map<String, dynamic>.from(body);
    final normalized = <String, dynamic>{...topLevel};

    final data = topLevel['data'];
    final dataMap = data is Map ? Map<String, dynamic>.from(data) : null;
    final receipt = dataMap?['receipt'] ?? topLevel['receipt'];
    final payment = dataMap?['payment'] ?? topLevel['payment'];

    final sources = <Map<String, dynamic>>[];
    if (dataMap != null) sources.add(dataMap);
    if (receipt is Map) sources.add(Map<String, dynamic>.from(receipt));
    if (payment is Map) sources.add(Map<String, dynamic>.from(payment));

    for (final source in sources) {
      for (final entry in source.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        final hasTopLevel = normalized.containsKey(key) &&
            normalized[key] != null &&
            normalized[key].toString().trim().isNotEmpty;
        if (!hasTopLevel) {
          normalized[key] = value;
        }
      }
    }

    return normalized;
  }

  static Future<dynamic> pay(Map<String, dynamic> data,
      {String? accessToken}) async {
    try {
      var response = await _postPayment('/payments/collect', data,
              accessToken: accessToken)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 202 &&
          response.statusCode != 204) {
        response =
            await _postPayment('/payments', data, accessToken: accessToken)
                .timeout(const Duration(seconds: 20));
      }

      dynamic body;
      if (response.body.isNotEmpty) {
        try {
          body = jsonDecode(response.body);
        } catch (_) {
          body = response.body;
        }
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        return normalizePaymentResponse(body, statusCode: response.statusCode);
      }

      if (body is Map<String, dynamic>) {
        return normalizePaymentResponse(body, statusCode: response.statusCode);
      }

      if (body is String && body.trim().isNotEmpty) {
        return {
          'success': false,
          'message': body.trim(),
        };
      }

      if (response.statusCode >= 500) {
        return {
          'success': false,
          'message': 'Server error while saving payment.',
        };
      }

      return {
        'success': false,
        'message': 'Payment failed. Please try again.',
      };
    } on TimeoutException {
      return {
        'success': false,
        'message':
            'Request timed out. Please check your internet and try again.',
      };
    } on SocketException {
      return {
        'success': false,
        'message': 'No internet connection. Please check your network.',
      };
    } on http.ClientException {
      return {
        'success': false,
        'message': 'Network error while connecting to server.',
      };
    }
  }

  static Future<dynamic> collectGeneratedInvoice(
    int paymentId,
    Map<String, dynamic> data, {
    String? accessToken,
  }) async {
    try {
      final response = await _postPayment(
        '/payments/$paymentId/collect',
        data,
        accessToken: accessToken,
      ).timeout(const Duration(seconds: 20));

      dynamic body;
      if (response.body.isNotEmpty) {
        try {
          body = jsonDecode(response.body);
        } catch (_) {
          body = response.body;
        }
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        return normalizePaymentResponse(body, statusCode: response.statusCode);
      }

      if (body is Map<String, dynamic>) {
        return normalizePaymentResponse(body, statusCode: response.statusCode);
      }

      if (body is String && body.trim().isNotEmpty) {
        return {
          'success': false,
          'message': body.trim(),
        };
      }

      if (response.statusCode >= 500) {
        return {
          'success': false,
          'message': 'Server error while collecting generated invoice.',
        };
      }

      return {
        'success': false,
        'message': 'Failed to collect generated invoice.',
      };
    } on TimeoutException {
      return {
        'success': false,
        'message':
            'Request timed out. Please check your internet and try again.',
      };
    } on SocketException {
      return {
        'success': false,
        'message': 'No internet connection. Please check your network.',
      };
    } on http.ClientException {
      return {
        'success': false,
        'message': 'Network error while connecting to server.',
      };
    }
  }

  static Future<Map<String, dynamic>?> createPaymentPreview(
    Map<String, dynamic> data, {
    String? accessToken,
  }) async {
    try {
      final response = await _postPayment('/payments/preview', data,
              accessToken: accessToken)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      if (response.body.isEmpty) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final receipt = decoded['receipt'];
      if (receipt is Map<String, dynamic>) {
        return receipt;
      }

      return decoded;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on http.ClientException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getPaymentReceipt(int paymentId,
      {String? accessToken}) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/payments/$paymentId/receipt'),
            headers: _acceptHeaders(accessToken: accessToken),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      if (response.body.isEmpty) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }

      return null;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on http.ClientException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
