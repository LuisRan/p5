import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const apiBaseOverride = String.fromEnvironment('API_BASE_URL');
const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

class AuthSession {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'access_token';
  static const _emailKey = 'account_email';
  static const _nameKey = 'account_name';
  static const _roleKey = 'account_role';

  static Future<String?> token() => _storage.read(key: _tokenKey);

  static Future<Map<String, String>?> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_emailKey);
    if (email == null) return null;
    return {
      'email': email,
      'name': prefs.getString(_nameKey) ?? email,
      'role': prefs.getString(_roleKey) ?? 'user',
    };
  }

  static Future<void> save(Map<String, dynamic> response) async {
    final user = Map<String, dynamic>.from(response['user'] as Map);
    await _storage.write(key: _tokenKey, value: response['token'] as String);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, user['email'] as String);
    await prefs.setString(_nameKey, user['name'] as String);
    await prefs.setString(_roleKey, user['role'] as String);
    await prefs.setString('user', user['email'] as String);
  }

  static Future<void> clear() async {
    if (BackendApi.googleConfigured) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        /* allow local logout even when Google is unavailable */
      }
    }
    await _storage.delete(key: _tokenKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_emailKey);
    await prefs.remove(_nameKey);
    await prefs.remove(_roleKey);
    await prefs.setString('user', 'invitado');
  }

  static Future<void> selfCheck() async {
    const key = '_storage_diagnostic';
    await _storage.write(key: key, value: 'ok');
    final value = await _storage.read(key: key);
    await _storage.delete(key: key);
    if (value != 'ok') {
      throw StateError('El almacenamiento seguro no respondió');
    }
  }
}

class BackendApi {
  static String get baseUrl {
    if (apiBaseOverride.isNotEmpty) {
      return apiBaseOverride.replaceFirst(RegExp(r'/$'), '');
    }
    if (Platform.isAndroid) return 'http://10.0.2.2:8000';
    return 'http://127.0.0.1:8000';
  }

  static final _client = http.Client();
  static Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    bool auth = false,
    String? sessionToken,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (auth) {
      final token = sessionToken ?? await AuthSession.token();
      if (token == null) throw StateError('Inicia sesión para sincronizar');
      headers['Authorization'] = 'Bearer $token';
    }
    final uri = Uri.parse('$baseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    final response = switch (method) {
      'GET' =>
        await _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 8)),
      'POST' =>
        await _client
            .post(uri, headers: headers, body: encoded)
            .timeout(const Duration(seconds: 8)),
      'PUT' =>
        await _client
            .put(uri, headers: headers, body: encoded)
            .timeout(const Duration(seconds: 8)),
      'DELETE' =>
        await _client
            .delete(uri, headers: headers, body: encoded)
            .timeout(const Duration(seconds: 8)),
      _ => throw ArgumentError('Método HTTP no soportado'),
    };
    if (response.statusCode == 204 || response.body.isEmpty) return {};
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const FormatException('La API devolvió JSON inválido');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error'] : null;
      throw BackendException(
        response.statusCode,
        message?.toString() ?? 'Error del servidor',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Respuesta de API inesperada');
    }
    return decoded;
  }

  static Future<Map<String, dynamic>> health() async =>
      _request('GET', '/health');

  static Future<Map<String, dynamic>> register(
    String email,
    String password,
    String name,
  ) => _request(
    'POST',
    '/auth/register',
    body: {'email': email, 'password': password, 'name': name},
  );

  static Future<Map<String, dynamic>> login(String email, String password) =>
      _request(
        'POST',
        '/auth/login',
        body: {'email': email, 'password': password},
      );

  static Future<Map<String, dynamic>> googleLogin(String idToken) =>
      _request('POST', '/auth/google', body: {'id_token': idToken});

  static Future<Map<String, dynamic>> sync(
    List<Map<String, dynamic>> operations, {
    required String sessionToken,
  }) => _request(
    'POST',
    '/sync',
    auth: true,
    sessionToken: sessionToken,
    body: {'operations': operations},
  );

  static Future<List<Map<String, dynamic>>> serverBooks() async =>
      List<Map<String, dynamic>>.from(
        (await _request('GET', '/books', auth: true))['items'] as List,
      );

  static Future<void> createBook(String key, Map<String, dynamic> data) async {
    await _request(
      'POST',
      '/books',
      auth: true,
      body: {'key': key, 'data': data},
    );
  }

  static Future<void> updateBook(int id, Map<String, dynamic> data) async {
    await _request('PUT', '/books/$id', auth: true, body: {'data': data});
  }

  static Future<void> deleteBook(int id) async {
    await _request('DELETE', '/books/$id', auth: true);
  }

  static Future<List<Map<String, dynamic>>> adminActivity() async =>
      List<Map<String, dynamic>>.from(
        (await _request('GET', '/admin/activity', auth: true))['users'] as List,
      );

  static Future<void> initializeGoogle() async {
    if (googleWebClientId.isEmpty && googleIosClientId.isEmpty) return;
    await GoogleSignIn.instance.initialize(
      clientId: Platform.isIOS && googleIosClientId.isNotEmpty
          ? googleIosClientId
          : null,
      serverClientId: googleWebClientId.isNotEmpty ? googleWebClientId : null,
    );
  }

  static bool get googleConfigured =>
      googleWebClientId.isNotEmpty &&
      (!Platform.isIOS || googleIosClientId.isNotEmpty);

  static Future<Map<String, dynamic>> signInWithGoogle() async {
    if (googleWebClientId.isEmpty && googleIosClientId.isEmpty) {
      throw StateError(
        'Configura GOOGLE_WEB_CLIENT_ID y GOOGLE_IOS_CLIENT_ID para activar Google Sign-In',
      );
    }
    final signIn = GoogleSignIn.instance;
    if (!signIn.supportsAuthenticate()) {
      throw StateError('Google Sign-In no está disponible en esta plataforma');
    }
    final account = await signIn.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw StateError(
        'Google no entregó un ID token. Revisa la configuración OAuth.',
      );
    }
    return googleLogin(idToken);
  }
}

class BackendException implements Exception {
  const BackendException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
}
