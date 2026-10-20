import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/salmon_dns.dart';
import 'package:fl_clash/services/salmon_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const salmonConfigUrl =
    'https://raw.gitcode.com/lao147/swyflclash/raw/main/config.json';
const salmonConfigUrls = <String>[salmonConfigUrl];
const salmonProfileLabel = '三文鱼订阅';
const _retiredApiHost = '1111.swyyy.com';
const salmonWebsiteUrl = 'https://swywl.com';
const salmonSupportUrl =
    'https://chat.swywl.com/widget?website_token=8SpSTtNMSfp64U8wevUS7wZ7#/';
const salmonDefaultInvitationUrl =
    'https://swy1.sanweny.com/register?code=NoEYnmwU';

Map<String, dynamic>? salmonAccountCache;
List<Map<String, dynamic>>? salmonNoticeCache;
List<Map<String, dynamic>>? salmonPlansCache;
List<Map<String, dynamic>>? salmonPaymentsCache;
DateTime? salmonAccountCacheAt;
DateTime? salmonStoreCacheAt;
DateTime? salmonNoticeCacheAt;
bool salmonNodesUpdatedThisSession = false;

String salmonFriendlyError(Object error, {String fallback = '操作失败，请稍后重试'}) {
  final localizations = AppLocalizations();
  if (error is SalmonSessionExpiredException) {
    return localizations.salmonSessionExpired;
  }
  final cause = error is DioException ? error.error : error;
  if ((error is DioException &&
          error.type == DioExceptionType.badCertificate) ||
      cause is TlsException ||
      error.toString().toLowerCase().contains('handshakeexception') ||
      error.toString().toLowerCase().contains('certificate_verify_failed')) {
    return localizations.salmonSecureConnectionFailed;
  }
  final raw = error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('DioException ', '')
      .trim();
  final lower = raw.toLowerCase();
  if (lower.contains('401') || lower.contains('session expired')) {
    return localizations.salmonSessionExpired;
  }
  if (lower.contains('failed host lookup') ||
      lower.contains('socketexception') ||
      lower.contains('connection error')) {
    return localizations.salmonConnectionFailed;
  }
  if (cause is TimeoutException || lower.contains('timeout')) {
    return localizations.salmonRequestTimeout;
  }
  if (lower.contains('422') || lower.contains('given data was invalid')) {
    return '提交的信息不完整，请检查后重试';
  }
  if (lower.contains('500') || lower.contains('502') || lower.contains('503')) {
    return '服务器暂时繁忙，请稍后重试';
  }
  if (raw.isEmpty ||
      raw.length > 90 ||
      lower.contains('requestoptions') ||
      !RegExp(r'[\u3400-\u9fff]').hasMatch(raw)) {
    return fallback;
  }
  return raw;
}

class SalmonSessionExpiredException extends StateError {
  SalmonSessionExpiredException() : super('Session expired');
}

class _SalmonRequestResult {
  final dynamic data;

  const _SalmonRequestResult(this.data);
}

class SalmonRemoteConfig {
  final List<String> urls;
  final String? customerServiceUrl;
  final String? invitationUrl;
  final SalmonAnalyticsConfig? analytics;

  const SalmonRemoteConfig({
    required this.urls,
    this.customerServiceUrl,
    this.invitationUrl,
    this.analytics,
  });

  factory SalmonRemoteConfig.parse(String source) {
    final json = decodeSalmonConfigSource(source);
    final urls = <String>[];
    final plainUrls = json['urls'];
    if (plainUrls is List) {
      urls.addAll(plainUrls.whereType<String>());
    }
    final encodedUrls = json['urlsBase64'];
    if (encodedUrls is List) {
      for (final encodedUrl in encodedUrls.whereType<String>()) {
        urls.add(utf8.decode(base64Decode(base64.normalize(encodedUrl))));
      }
    }
    final normalizedUrls = urls
        .map((url) => url.trim().replaceFirst(RegExp(r'/+$'), ''))
        .where((url) {
          final uri = Uri.tryParse(url);
          return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
        })
        .toSet()
        .toList();
    if (normalizedUrls.isEmpty) {
      throw const FormatException('No valid HTTPS URL');
    }
    final customerService = json['customerService'];
    final invitation = json['invitation'];
    return SalmonRemoteConfig(
      analytics: SalmonAnalyticsConfig.fromJson(json['analytics']),
      urls: normalizedUrls,
      customerServiceUrl: customerService is Map
          ? _validatedSupportUrl(customerService['url'])
          : null,
      invitationUrl: _validatedInvitationUrl(
        invitation is Map
            ? invitation['url']
            : json['invitationUrl'] ?? json['inviteUrl'],
      ),
    );
  }
}

String? _validatedSupportUrl(dynamic value) {
  if (value is! String) return null;
  final url = value.trim();
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return url;
}

String? _validatedInvitationUrl(dynamic value) {
  if (value is! String) return null;
  final url = value.trim();
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return url;
}

String? salmonInvitationCodeFromUrl(String url) {
  final uri = Uri.tryParse(url);
  final code = uri?.queryParameters['code']?.trim();
  return code == null || code.isEmpty ? null : code;
}

String buildSalmonInvitationUrl(String baseUrl, String code) {
  final uri = Uri.parse(baseUrl);
  return uri
      .replace(queryParameters: {...uri.queryParameters, 'code': code})
      .toString();
}

Map<String, dynamic> decodeSalmonConfigSource(String source) {
  dynamic decoded;
  final normalizedSource = source.trim().replaceFirst('\ufeff', '');
  try {
    decoded = jsonDecode(normalizedSource);
  } on FormatException {
    final jsonSource = utf8.decode(
      base64Decode(base64.normalize(normalizedSource)),
    );
    decoded = jsonDecode(jsonSource);
  }
  if (decoded is String) {
    final jsonSource = utf8.decode(
      base64Decode(base64.normalize(decoded.trim())),
    );
    decoded = jsonDecode(jsonSource);
  }
  if (decoded is Map && decoded['dataBase64'] is String) {
    final jsonSource = utf8.decode(
      base64Decode(base64.normalize('${decoded['dataBase64']}'.trim())),
    );
    decoded = jsonDecode(jsonSource);
  }
  if (decoded is! Map) {
    throw const FormatException('Invalid remote configuration');
  }
  return Map<String, dynamic>.from(decoded);
}

class SalmonSession {
  final String baseUrl;
  final String authData;
  final String subscribeUrl;
  final int generation;

  const SalmonSession({
    required this.baseUrl,
    required this.authData,
    required this.subscribeUrl,
    this.generation = 0,
  });
}

class SalmonService {
  static const _baseUrlKey = 'salmon_base_url';
  static const _authDataKey = 'salmon_auth_data';
  static const _subscribeUrlKey = 'salmon_subscribe_url';
  static const _baseUrlsCacheKey = 'salmon_base_urls_cache';
  static const _baseUrlsCacheAtKey = 'salmon_base_urls_cache_at';
  static const _baseUrlsCacheSourceKey = 'salmon_base_urls_cache_source';
  static const _customerServiceUrlKey = 'salmon_customer_service_url';
  static const _invitationUrlKey = 'salmon_invitation_url';
  static const _plansDataCacheKey = 'salmon_plans_data_cache';
  static const _userDataCacheKey = 'salmon_user_data_cache';
  static const _subscribeDataCacheKey = 'salmon_subscribe_data_cache';
  static const _paymentsDataCacheKey = 'salmon_payments_data_cache';
  static const _noticesDataCacheKey = 'salmon_notices_data_cache';
  static const _invitesDataCacheKey = 'salmon_invites_data_cache';
  static const _commissionDataCacheKey = 'salmon_commission_data_cache';
  static const _ordersDataCacheKey = 'salmon_orders_data_cache';
  static const _ticketsDataCacheKey = 'salmon_tickets_data_cache';
  static const _trafficDataCacheKey = 'salmon_traffic_data_cache';
  static const _chatContactKey = 'salmon_chatwoot_contact';
  static const _chatConversationKey = 'salmon_chatwoot_conversation';
  static const _chatEmailKey = 'salmon_chatwoot_email';
  static const _chatScopeKey = 'salmon_chatwoot_scope';
  static int _sessionGeneration = 0;

  final Dio _dio;
  final SalmonAnalytics _analytics;
  Future<List<String>>? _baseUrlsInFlight;
  bool _baseUrlsForceRefresh = false;
  final Duration _orderRequestTimeout;
  static Future<void> _sessionMutation = Future<void>.value();
  String _supportUrl = salmonSupportUrl;
  String _invitationUrl = salmonDefaultInvitationUrl;
  String _chatSessionUrl = salmonSupportUrl;
  final ValueNotifier<int> sessionRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> membershipRevision = ValueNotifier<int>(0);

  int get sessionGeneration => _sessionGeneration;

  SalmonService({
    Dio? dio,
    SalmonAnalytics? analytics,
    Duration orderRequestTimeout = const Duration(seconds: 10),
  }) : _analytics = analytics ?? salmonAnalytics,
       _orderRequestTimeout = orderRequestTimeout,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 25),
               sendTimeout: const Duration(seconds: 20),
               headers: const {'Accept': 'application/json'},
             ),
           ) {
    if (dio == null) installSalmonDnsFallback(_dio);
  }

  Future<List<String>> fetchBaseUrls({bool forceRefresh = false}) async {
    final inFlight = _baseUrlsInFlight;
    if (inFlight != null) {
      if (!forceRefresh || _baseUrlsForceRefresh) return inFlight;
      await inFlight;
      return fetchBaseUrls(forceRefresh: true);
    }
    _baseUrlsForceRefresh = forceRefresh;
    final future = _fetchBaseUrls(forceRefresh: forceRefresh);
    _baseUrlsInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_baseUrlsInFlight, future)) _baseUrlsInFlight = null;
    }
  }

  Future<List<String>> _fetchBaseUrls({required bool forceRefresh}) async {
    final preferences = await SharedPreferences.getInstance();
    _supportUrl =
        _validatedSupportUrl(preferences.getString(_customerServiceUrlKey)) ??
        salmonSupportUrl;
    _invitationUrl =
        _validatedInvitationUrl(preferences.getString(_invitationUrlKey)) ??
        salmonDefaultInvitationUrl;
    final cached = _cachedBaseUrls(preferences);
    final cachedAt = preferences.getInt(_baseUrlsCacheAtKey);
    if (!forceRefresh &&
        cached.isNotEmpty &&
        cachedAt != null &&
        DateTime.now().millisecondsSinceEpoch - cachedAt <
            const Duration(minutes: 5).inMilliseconds) {
      return cached;
    }
    for (final configUrl in [...salmonConfigUrls, ...salmonConfigUrls]) {
      final cancelToken = CancelToken();
      try {
        final response = await _dio
            .get<String>(
              configUrl,
              cancelToken: cancelToken,
              queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
              options: Options(
                responseType: ResponseType.plain,
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 5),
                headers: const {'Cache-Control': 'no-cache'},
              ),
            )
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                cancelToken.cancel('Configuration deadline exceeded');
                throw TimeoutException('Configuration deadline exceeded');
              },
            );
        final config = SalmonRemoteConfig.parse(response.data ?? '');
        _analytics.configure(config.analytics);
        if (config.customerServiceUrl case final supportUrl?) {
          await preferences.setString(_customerServiceUrlKey, supportUrl);
          _supportUrl = supportUrl;
        }
        if (config.invitationUrl case final invitationUrl?) {
          await preferences.setString(_invitationUrlKey, invitationUrl);
          _invitationUrl = invitationUrl;
        }
        await preferences.setString(_baseUrlsCacheKey, jsonEncode(config.urls));
        await preferences.setString(_baseUrlsCacheSourceKey, configUrl);
        await preferences.setInt(
          _baseUrlsCacheAtKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        return config.urls;
      } catch (_) {
        // Try the next remote configuration source.
      }
    }
    return cached;
  }

  Future<String> fetchSupportUrl({bool forceRefresh = false}) async {
    await fetchBaseUrls(forceRefresh: forceRefresh);
    return _supportUrl;
  }

  Future<String> fetchInvitationUrl({bool forceRefresh = false}) async {
    await fetchBaseUrls(forceRefresh: forceRefresh);
    return _invitationUrl;
  }

  Future<void> sendEmailCode(String email) async {
    await _passportRequest(
      'passport/comm/sendEmailVerify',
      {'email': email.trim()},
      notFoundMessage: '邮箱验证码接口不存在，请检查 V2Board 邮件配置',
    );
  }

  Future<SalmonSession?> register({
    required String email,
    required String password,
    required String emailCode,
    String? inviteCode,
  }) async {
    final result = await _passportRequest('passport/auth/register', {
      'email': email.trim(),
      'password': password,
      'password_confirmation': password,
      'email_code': emailCode.trim(),
      if (inviteCode != null && inviteCode.trim().isNotEmpty)
        'invite_code': inviteCode.trim(),
    }, notFoundMessage: '注册接口不存在，请检查 V2Board 是否已开启用户注册');
    dynamic payload = result.$1;
    if (payload is Map && payload['data'] != null) payload = payload['data'];
    if (payload is! Map) return null;
    final authData = (payload['auth_data'] ?? payload['token'])?.toString();
    if (authData == null || authData.isEmpty) return null;
    final session = SalmonSession(
      baseUrl: result.$2,
      authData: authData,
      subscribeUrl: '',
    );
    final generation = await _save(session);
    return SalmonSession(
      baseUrl: session.baseUrl,
      authData: session.authData,
      subscribeUrl: session.subscribeUrl,
      generation: generation,
    );
  }

  Future<void> resetPassword({
    required String email,
    required String password,
    required String emailCode,
  }) async {
    await _passportRequest('passport/auth/forget', {
      'email': email.trim(),
      'password': password,
      'password_confirmation': password,
      'email_code': emailCode.trim(),
    }, notFoundMessage: '找回密码接口不存在，请检查 V2Board 后台配置');
  }

  Future<(dynamic, String)> _passportRequest(
    String path,
    Map<String, dynamic> data, {
    required String notFoundMessage,
  }) async {
    final candidates = await _apiCandidates(forceRefresh: true);
    Object? lastError;
    var allNotFound = true;
    for (final baseUrl in candidates) {
      try {
        debugPrint('Salmon API candidate: $baseUrl');
        final response = await _dio.post<dynamic>(
          '$baseUrl/api/v1/$path',
          data: data,
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
        final body = response.data;
        if (body is Map && body['data'] == false) {
          throw StateError(_responseMessage(body));
        }
        return (body, baseUrl);
      } on DioException catch (error) {
        debugPrint('Salmon API request failed');
        lastError = error;
        final status = error.response?.statusCode ?? 0;
        if (status == 404) {
          // A stale cached domain may still serve the login API but not the
          // current registration routes. Continue with configured domains.
          continue;
        }
        allNotFound = false;
        if (status >= 400 && status < 500) {
          throw StateError(_dioMessage(error, fallback: '提交的信息有误'));
        }
      } catch (error) {
        lastError = error;
        allNotFound = false;
        if (error is StateError) rethrow;
      }
    }
    if (allNotFound && lastError is DioException) {
      throw StateError(notFoundMessage);
    }
    throw StateError(
      salmonFriendlyError(lastError ?? '', fallback: '服务器暂时无法连接'),
    );
  }

  Future<SalmonSession?> restore() async {
    final generation = _sessionGeneration;
    final preferences = await SharedPreferences.getInstance();
    final authData = preferences.getString(_authDataKey);
    if (authData == null || authData.isEmpty) return null;
    final cachedBaseUrl = preferences.getString(_baseUrlKey);
    final cachedSubscribeUrl = preferences.getString(_subscribeUrlKey);

    if (cachedBaseUrl != null &&
        _supportedApiCandidates([cachedBaseUrl]).isNotEmpty &&
        await _isCurrentSession(authData, generation)) {
      return SalmonSession(
        baseUrl: cachedBaseUrl,
        authData: authData,
        subscribeUrl: cachedSubscribeUrl ?? '',
        generation: generation,
      );
    }

    return refreshSession(
      expectedAuthData: authData,
      expectedGeneration: generation,
    );
  }

  Future<SalmonSession?> refreshSession({
    String? expectedAuthData,
    int? expectedGeneration,
  }) async {
    final generation = _sessionGeneration;
    if (expectedGeneration != null && expectedGeneration != generation) {
      return null;
    }
    final preferences = await SharedPreferences.getInstance();
    final authData = preferences.getString(_authDataKey);
    if (authData == null ||
        authData.isEmpty ||
        (expectedAuthData != null && authData != expectedAuthData)) {
      return null;
    }
    final cachedBaseUrl = preferences.getString(_baseUrlKey);
    final cachedSubscribeUrl = preferences.getString(_subscribeUrlKey);
    final candidates = await _cachedLoginCandidates();
    final attempted = <String>{};
    var credentialFailures = 0;
    var networkFailures = 0;
    var otherFailures = 0;

    Future<SalmonSession?> tryCandidate(String baseUrl) async {
      attempted.add(baseUrl);
      if (!await _isCurrentSession(authData, generation)) return null;
      try {
        final subscribeUrl = await _getSubscribeUrl(baseUrl, authData);
        final session = SalmonSession(
          baseUrl: baseUrl,
          authData: authData,
          subscribeUrl: subscribeUrl,
          generation: generation,
        );
        return await _saveIfCurrent(session, authData, generation)
            ? session
            : null;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (_isSessionExpiredStatus(status)) {
          credentialFailures++;
        } else if (_isTransientStatus(status) || status == null) {
          networkFailures++;
        } else {
          otherFailures++;
        }
      } catch (_) {
        otherFailures++;
      }
      return null;
    }

    for (final baseUrl in candidates) {
      final session = await tryCandidate(baseUrl);
      if (session != null) return session;
    }

    // Only pay the remote-config timeout after all locally known endpoints
    // have failed. This keeps app entry responsive during a config outage.
    if (candidates.isEmpty || networkFailures > 0 || otherFailures > 0) {
      final refreshed = await _apiCandidates(forceRefresh: true);
      for (final baseUrl in refreshed) {
        if (attempted.contains(baseUrl)) continue;
        final session = await tryCandidate(baseUrl);
        if (session != null) return session;
      }
    }
    if (credentialFailures > 0 && networkFailures == 0 && otherFailures == 0) {
      await clear(expectedAuthData: authData, expectedGeneration: generation);
      return null;
    }
    // Network failures must not log the user out. Keep the last successful
    // subscription and session until the user explicitly chooses to sign out.
    if (cachedBaseUrl != null &&
        cachedBaseUrl.isNotEmpty &&
        await _isCurrentSession(authData, generation)) {
      return SalmonSession(
        baseUrl: cachedBaseUrl,
        authData: authData,
        subscribeUrl: cachedSubscribeUrl ?? '',
        generation: generation,
      );
    }
    return null;
  }

  Future<SalmonSession> login({
    required String account,
    required String password,
  }) async {
    Object? lastNetworkError;
    Object? credentialError;
    final candidates = await _apiCandidates(forceRefresh: true);
    final retryCandidates = <String>[];

    Future<SalmonSession?> tryCandidate(String baseUrl) async {
      try {
        debugPrint('Salmon login attempt: $baseUrl');
        final authData = await _login(baseUrl, account, password);
        var subscribeUrl = '';
        try {
          subscribeUrl = await _getSubscribeUrl(baseUrl, authData);
        } catch (_) {
          // A newly registered user may not have a plan or subscription yet.
          // Authentication is still successful and the user must enter the app.
        }
        final session = SalmonSession(
          baseUrl: baseUrl,
          authData: authData,
          subscribeUrl: subscribeUrl,
        );
        final generation = await _save(session);
        return SalmonSession(
          baseUrl: session.baseUrl,
          authData: session.authData,
          subscribeUrl: session.subscribeUrl,
          generation: generation,
        );
      } on DioException catch (error) {
        debugPrint('Salmon login request failed');
        final status = error.response?.statusCode ?? 0;
        // 400/404 can be returned by a stale domain, proxy or an incompatible
        // V2Board route. Continue with the next configured domain.
        // A blocked domain may return 403. It must not be reported as an
        // incorrect password when no configured endpoint can be reached.
        if ({401, 422}.contains(status)) {
          credentialError = error;
        } else {
          lastNetworkError = error;
          if (_isTransientLoginError(error) &&
              !retryCandidates.contains(baseUrl)) {
            retryCandidates.add(baseUrl);
          }
        }
      } catch (error) {
        lastNetworkError = error;
      }
      return null;
    }

    for (final baseUrl in candidates) {
      final session = await tryCandidate(baseUrl);
      if (session != null) return session;
    }
    // Retry transient failures once within the same button press, after all
    // configured domains have had a chance. Never retry a credential rejection.
    for (final baseUrl in List<String>.of(retryCandidates)) {
      final session = await tryCandidate(baseUrl);
      if (session != null) return session;
    }

    debugPrint('Salmon login failed after exhausting API candidates');
    if (credentialError != null && lastNetworkError == null) {
      throw StateError('账号或密码错误');
    }
    throw StateError(
      salmonFriendlyError(
        lastNetworkError ?? '',
        fallback: '服务器暂时无法连接，请检查网络后重试',
      ),
    );
  }

  Future<List<String>> _cachedLoginCandidates() async {
    final preferences = await SharedPreferences.getInstance();
    return _prioritizeSavedBaseUrl(preferences, _cachedBaseUrls(preferences));
  }

  List<String> _cachedBaseUrls(SharedPreferences preferences) {
    // Older clients also cached GitHub domains. Only reuse a list whose
    // provenance is GitCode; never infer it from the saved session endpoint.
    if (preferences.getString(_baseUrlsCacheSourceKey) != salmonConfigUrl) {
      return const [];
    }
    final cachedRaw = preferences.getString(_baseUrlsCacheKey);
    if (cachedRaw != null) {
      try {
        return _supportedApiCandidates(
          (jsonDecode(cachedRaw) as List).whereType<String>(),
        );
      } catch (_) {
        // A corrupt cache must be replaced by a GitCode configuration fetch.
      }
    }
    return const [];
  }

  List<String> _prioritizeSavedBaseUrl(
    SharedPreferences preferences,
    List<String> configured,
  ) {
    final saved = preferences.getString(_baseUrlKey);
    return _supportedApiCandidates([
      if (saved != null && configured.contains(saved)) saved,
      ...configured,
    ]);
  }

  Future<String?> savedBaseUrl() async {
    return (await SharedPreferences.getInstance()).getString(_baseUrlKey);
  }

  Future<List<String>> _apiCandidates({bool forceRefresh = false}) async {
    final configured = _supportedApiCandidates(
      await fetchBaseUrls(forceRefresh: forceRefresh),
    );
    return _prioritizeSavedBaseUrl(
      await SharedPreferences.getInstance(),
      configured,
    );
  }

  List<String> _supportedApiCandidates(Iterable<String> urls) {
    return urls
        .map((url) => url.trim().replaceFirst(RegExp(r'/+$'), ''))
        .where((url) {
          final uri = Uri.tryParse(url);
          return uri != null &&
              uri.scheme == 'https' &&
              uri.host.isNotEmpty &&
              uri.host != _retiredApiHost;
        })
        .toSet()
        .toList();
  }

  void _checkGeneration(int generation) {
    if (generation != _sessionGeneration) {
      throw SalmonSessionExpiredException();
    }
  }

  Future<void> _writeDataCache(String key, dynamic value, int generation) {
    return _withSessionMutation(() async {
      final preferences = await SharedPreferences.getInstance();
      _checkGeneration(generation);
      await preferences.setString(key, jsonEncode(value));
      await preferences.setInt(
        '$key.at',
        DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  Future<dynamic> _readDataCache(String key, int generation) async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    _checkGeneration(generation);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _readFreshDataCache(
    String key,
    Duration maxAge,
    int generation,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    _checkGeneration(generation);
    final cachedAt = preferences.getInt('$key.at');
    if (cachedAt == null ||
        DateTime.now().millisecondsSinceEpoch - cachedAt >
            maxAge.inMilliseconds) {
      return null;
    }
    return _readDataCache(key, generation);
  }

  Future<void> _removeDataCache(String key) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
    await preferences.remove('$key.at');
  }

  Future<void> _clearAccountDataCaches() async {
    for (final key in [
      _plansDataCacheKey,
      _userDataCacheKey,
      _subscribeDataCacheKey,
      _paymentsDataCacheKey,
      _noticesDataCacheKey,
      _invitesDataCacheKey,
      _commissionDataCacheKey,
      _ordersDataCacheKey,
      _ticketsDataCacheKey,
      _trafficDataCacheKey,
    ]) {
      await _removeDataCache(key);
    }
  }

  Future<List<Map<String, dynamic>>> fetchPlans({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _plansDataCacheKey,
        const Duration(minutes: 30),
        generation,
      );
      if (!forceRefresh && cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    try {
      dynamic data = await _authenticatedRequest('user/plan/fetch');
      if (data is Map && data['data'] is List) data = data['data'];
      if (data is! List) return const [];
      final value = data
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      await _writeDataCache(_plansDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_plansDataCacheKey, generation);
      if (_canUseStaleCache(error) && cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> fetchUserInfo({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _userDataCacheKey,
        const Duration(minutes: 5),
        generation,
      );
      if (!forceRefresh && cached is Map)
        return Map<String, dynamic>.from(cached);
    }
    try {
      final data = await _authenticatedRequest('user/info');
      if (data is! Map) throw const FormatException('Invalid account response');
      final value = Map<String, dynamic>.from(data);
      await _writeDataCache(_userDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_userDataCacheKey, generation);
      if (_canUseStaleCache(error) && cached is Map)
        return Map<String, dynamic>.from(cached);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> fetchSubscribeInfo({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _subscribeDataCacheKey,
        const Duration(minutes: 5),
        generation,
      );
      if (cached is Map) return Map<String, dynamic>.from(cached);
    }
    try {
      final data = await _authenticatedRequest('user/getSubscribe');
      if (data is! Map)
        throw const FormatException('Invalid subscription response');
      final value = Map<String, dynamic>.from(data);
      await _writeDataCache(_subscribeDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_subscribeDataCacheKey, generation);
      if (_canUseStaleCache(error) && cached is Map) {
        return Map<String, dynamic>.from(cached);
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> fetchPaymentMethods({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _paymentsDataCacheKey,
        const Duration(minutes: 30),
        generation,
      );
      if (!forceRefresh && cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    try {
      dynamic data = await _authenticatedRequest('user/order/getPaymentMethod');
      if (data is Map && data['data'] is List) data = data['data'];
      if (data is! List) return const [];
      final value = data
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      await _writeDataCache(_paymentsDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_paymentsDataCacheKey, generation);
      if (cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> fetchOrders({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _ordersDataCacheKey,
        const Duration(minutes: 2),
        generation,
      );
      if (!forceRefresh && cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    try {
      dynamic data = await _authenticatedRequest('user/order/fetch');
      if (data is Map && data['data'] is List) data = data['data'];
      if (data is! List) return const [];
      final value = data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      await _writeDataCache(_ordersDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_ordersDataCacheKey, generation);
      if (cached is List)
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> fetchInvites({bool forceRefresh = false}) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _invitesDataCacheKey,
        const Duration(minutes: 5),
        generation,
      );
      if (cached is Map) return Map<String, dynamic>.from(cached);
    }
    try {
      dynamic data = await _authenticatedRequest('user/invite/fetch');
      if (data is Map && data['data'] is Map) data = data['data'];
      if (data is! Map) return const {};
      final value = Map<String, dynamic>.from(data);
      await _writeDataCache(_invitesDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_invitesDataCacheKey, generation);
      if (cached is Map) return Map<String, dynamic>.from(cached);
      rethrow;
    }
  }

  Future<void> generateInvite() async {
    try {
      // This V2Board deployment exposes invite/save as a GET route.
      await _authenticatedRequest('user/invite/save');
      await _removeDataCache(_invitesDataCacheKey);
    } on DioException catch (error) {
      throw StateError(_dioMessage(error, fallback: '邀请码生成失败'));
    }
  }

  Future<Map<String, dynamic>> fetchCommissionConfig({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _commissionDataCacheKey,
        const Duration(minutes: 5),
        generation,
      );
      if (cached is Map) return Map<String, dynamic>.from(cached);
    }
    final result = <String, dynamic>{};
    for (final path in ['user/comm/config', 'guest/comm/config']) {
      try {
        dynamic data = await _authenticatedRequest(path);
        if (data is Map && data['data'] is Map) data = data['data'];
        if (data is Map) result.addAll(Map<String, dynamic>.from(data));
      } catch (error) {
        if (error is SalmonSessionExpiredException) rethrow;
        // Different V2Board versions expose the commission config differently.
      }
    }
    if (result.isNotEmpty)
      await _writeDataCache(_commissionDataCacheKey, result, generation);
    if (result.isEmpty) {
      final cached = await _readDataCache(_commissionDataCacheKey, generation);
      if (cached is Map) return Map<String, dynamic>.from(cached);
    }
    return result;
  }

  Future<dynamic> redeemGiftCard(String giftcard) {
    return _authenticatedRequest(
      'user/redeemgiftcard',
      method: 'POST',
      body: {'giftcard': giftcard},
    );
  }

  Future<List<Map<String, dynamic>>> fetchTickets({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _ticketsDataCacheKey,
        const Duration(minutes: 2),
        generation,
      );
      if (cached is List)
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    }
    try {
      dynamic data = await _authenticatedRequest('user/ticket/fetch');
      if (data is Map && data['data'] is List) data = data['data'];
      if (data is! List) return const [];
      final value = data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      await _writeDataCache(_ticketsDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_ticketsDataCacheKey, generation);
      if (cached is List)
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      rethrow;
    }
  }

  Future<void> createTicket({
    required String subject,
    required String message,
    int level = 1,
  }) async {
    await _authenticatedRequest(
      'user/ticket/save',
      method: 'POST',
      body: {'subject': subject, 'message': message, 'level': level},
    );
    await _removeDataCache(_ticketsDataCacheKey);
  }

  Future<List<Map<String, dynamic>>> fetchTrafficLog({
    DateTime? startAt,
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _trafficDataCacheKey,
        const Duration(minutes: 2),
        generation,
      );
      if (cached is List)
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    }
    try {
      dynamic data = await _authenticatedRequest(
        'user/stat/getTrafficLog',
        queryParameters: startAt == null
            ? null
            : {
                'start_at': startAt.millisecondsSinceEpoch ~/ 1000,
                'end_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              },
      );
      if (data is Map && data['data'] is List) data = data['data'];
      if (data is! List) return const [];
      final value = data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      await _writeDataCache(_trafficDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_trafficDataCacheKey, generation);
      if (cached is List)
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> fetchNotices({
    bool forceRefresh = false,
  }) async {
    final generation = _sessionGeneration;
    if (!forceRefresh) {
      final cached = await _readFreshDataCache(
        _noticesDataCacheKey,
        const Duration(minutes: 30),
        generation,
      );
      if (cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    try {
      dynamic data = await _authenticatedRequest('user/notice/fetch');
      if (data is Map && data['data'] is List) data = data['data'];
      if (data is! List) return const [];
      final value = data
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      await _writeDataCache(_noticesDataCacheKey, value, generation);
      return value;
    } catch (error) {
      if (error is SalmonSessionExpiredException) rethrow;
      final cached = await _readDataCache(_noticesDataCacheKey, generation);
      if (cached is List) {
        return cached
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> fetchTicketDetail(int id) async {
    final data = await _authenticatedRequest(
      'user/ticket/fetch',
      queryParameters: {'id': id},
    );
    if (data is! Map) return const {};
    return Map<String, dynamic>.from(data);
  }

  Future<void> replyTicket(int id, String message) async {
    try {
      await _authenticatedRequest(
        'user/ticket/reply',
        method: 'POST',
        body: {'id': id, 'message': message},
      );
      await _removeDataCache(_ticketsDataCacheKey);
    } on DioException catch (error) {
      throw StateError(_dioMessage(error));
    }
  }

  Future<void> closeTicket(int id) async {
    await _authenticatedRequest(
      'user/ticket/close',
      method: 'POST',
      body: {'id': id},
    );
    await _removeDataCache(_ticketsDataCacheKey);
  }

  Future<void> cancelOrder(String tradeNo) async {
    await _authenticatedRequest(
      'user/order/cancel',
      method: 'POST',
      body: {'trade_no': tradeNo},
    );
    await _removeDataCache(_ordersDataCacheKey);
  }

  Future<Map<String, dynamic>> prepareChatwoot(String email) async {
    final preferences = await SharedPreferences.getInstance();
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      throw StateError('无法确认当前账号，请重新登录后联系客服');
    }
    _chatSessionUrl = await fetchSupportUrl();
    final scope = '$_chatBaseUrl/$_chatInbox';
    final defaultUri = Uri.parse(salmonSupportUrl);
    final defaultScope =
        '${defaultUri.origin}/${defaultUri.queryParameters['website_token']}';
    final storedEmail = preferences.getString(_chatEmailKey);
    final storedScope = preferences.getString(_chatScopeKey);
    if (storedEmail != normalizedEmail ||
        (storedScope ?? defaultScope) != scope) {
      await clearChatwootSession();
    }
    await preferences.setString(_chatScopeKey, scope);
    var sourceId = preferences.getString(_chatContactKey);
    var conversationId = preferences.getInt(_chatConversationKey);
    if (sourceId != null && sourceId.isNotEmpty && conversationId != null) {
      await preferences.setString(_chatEmailKey, normalizedEmail);
      return {'source_id': sourceId, 'conversation_id': conversationId};
    }
    if (sourceId == null || sourceId.isEmpty) {
      final response = await _dio.post<dynamic>(
        '$_chatBaseUrl/public/api/v1/inboxes/$_chatInbox/contacts',
        options: Options(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
        ),
        data: {
          'email': email,
          'name': email.split('@').first,
          'custom_attributes': {'client': '三文鱼 Android'},
        },
      );
      dynamic contact = response.data;
      if (contact is Map && contact['payload'] is Map) {
        contact = contact['payload'];
      }
      final contactInbox = contact is Map && contact['contact_inbox'] is Map
          ? contact['contact_inbox'] as Map
          : const <dynamic, dynamic>{};
      final nestedContact = contact is Map && contact['contact'] is Map
          ? contact['contact'] as Map
          : const <dynamic, dynamic>{};
      final createdSourceId = contact is Map
          ? '${contact['source_id'] ?? contactInbox['source_id'] ?? nestedContact['source_id'] ?? ''}'
          : '';
      if (createdSourceId.isEmpty) {
        throw StateError('在线客服联系人创建失败');
      }
      sourceId = createdSourceId;
      await preferences.setString(_chatContactKey, sourceId);
    }
    final conversationsUrl =
        '$_chatBaseUrl/public/api/v1/inboxes/$_chatInbox/contacts/$sourceId/conversations';
    final created = await _dio.post<dynamic>(
      conversationsUrl,
      options: Options(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
      ),
      data: {
        'custom_attributes': {'client': '三文鱼 Android'},
      },
    );
    dynamic conversation = created.data;
    if (conversation is Map && conversation['payload'] is Map) {
      conversation = conversation['payload'];
    }
    if (conversation is! Map) throw StateError('在线客服会话创建失败');
    conversationId = int.tryParse('${conversation['id']}');
    if (conversationId == null) throw StateError('在线客服会话无效');
    await preferences.setInt(_chatConversationKey, conversationId);
    await preferences.setString(_chatEmailKey, normalizedEmail);
    return {'source_id': sourceId, 'conversation_id': conversationId};
  }

  Future<void> clearChatwootSession() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_chatContactKey);
    await preferences.remove(_chatConversationKey);
    await preferences.remove(_chatEmailKey);
    await preferences.remove(_chatScopeKey);
  }

  String get _chatBaseUrl => Uri.parse(_chatSessionUrl).origin;

  String get _chatInbox {
    final token = Uri.parse(_chatSessionUrl).queryParameters['website_token'];
    if (token == null || token.trim().isEmpty) {
      throw StateError('当前客服地址不支持 Chatwoot 会话接口，请打开客服页面');
    }
    return Uri.encodeComponent(token);
  }

  String _chatMessagesUrl(String sourceId, int conversationId) =>
      '$_chatBaseUrl/public/api/v1/inboxes/$_chatInbox/contacts/$sourceId/conversations/$conversationId/messages';

  Future<List<Map<String, dynamic>>> fetchChatwootMessages(
    String sourceId,
    int conversationId,
  ) async {
    final response = await _dio.get<dynamic>(
      _chatMessagesUrl(sourceId, conversationId),
      options: Options(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    dynamic data = response.data;
    if (data is Map && data.containsKey('payload')) data = data['payload'];
    if (data is Map && data['data'] is Map) data = data['data'];
    if (data is Map) data = data['messages'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> sendChatwootMessage(
    String sourceId,
    int conversationId,
    String content,
  ) async {
    await _dio.post<dynamic>(
      _chatMessagesUrl(sourceId, conversationId),
      options: Options(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
      ),
      data: {
        'content': content,
        'echo_id': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );
  }

  Future<void> sendChatwootAttachment(
    String sourceId,
    int conversationId,
    String path,
    String fileName,
  ) async {
    final data = FormData()
      ..files.add(
        MapEntry(
          'attachments[]',
          await MultipartFile.fromFile(path, filename: fileName),
        ),
      );
    await _dio.post<dynamic>(
      _chatMessagesUrl(sourceId, conversationId),
      options: Options(
        connectTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 60),
      ),
      data: data,
    );
  }

  Future<String> _prepareOrderDomain() async {
    final preferences = await SharedPreferences.getInstance();
    final authData = preferences.getString(_authDataKey);
    final baseUrl = preferences.getString(_baseUrlKey);
    if (authData == null || baseUrl == null) {
      throw SalmonSessionExpiredException();
    }
    final generation = _sessionGeneration;
    final configured = await _cachedLoginCandidates();
    final candidates = configured.isEmpty ? [baseUrl] : configured;
    final selected = Completer<String>();
    final tokens = <CancelToken>[];
    var remaining = candidates.length;
    Object? lastError;
    for (final candidate in candidates) {
      final token = CancelToken();
      tokens.add(token);
      unawaited(() async {
        try {
          // Only these read-only probes run concurrently. The order POST is
          // sent once, pinned to the first domain that answers successfully.
          final root = await _requestOrder(
            'user/info',
            timeout: const Duration(seconds: 6),
            baseUrlOverride: candidate,
            cancellation: token,
          );
          if (root is! Map || !root.containsKey('data')) {
            throw StateError(AppLocalizations().salmonConnectionFailed);
          }
          if (!selected.isCompleted) selected.complete(candidate);
        } catch (error) {
          lastError = error;
        } finally {
          remaining--;
          if (remaining == 0 && !selected.isCompleted) {
            selected.completeError(
              lastError ??
                  StateError(AppLocalizations().salmonConnectionFailed),
            );
          }
        }
      }());
    }
    try {
      final candidate = await selected.future;
      await _promoteBaseUrl(candidate, authData, generation);
      if (!await _isCurrentSession(authData, generation)) {
        throw SalmonSessionExpiredException();
      }
      return candidate;
    } finally {
      for (final token in tokens) {
        if (!token.isCancelled) token.cancel('Domain selection finished');
      }
    }
  }

  Future<String> createOrder({
    required int planId,
    required String cycle,
    String? couponCode,
  }) async {
    final baseUrl = await _prepareOrderDomain();
    dynamic data;
    final normalizedCoupon = couponCode?.trim() ?? '';
    final body = <String, dynamic>{
      'plan_id': planId,
      'cycle': cycle,
      'period': cycle,
      if (normalizedCoupon.isNotEmpty) 'coupon_code': normalizedCoupon,
    };
    try {
      final root = await _requestOrder(
        'user/order/save',
        method: 'POST',
        body: body,
        baseUrlOverride: baseUrl,
      );
      data = root is Map ? root['data'] : null;
    } on DioException catch (error) {
      final connectionFailed =
          error.error is TlsException ||
          error.type == DioExceptionType.badCertificate ||
          error.type == DioExceptionType.connectionTimeout;
      final pending = normalizedCoupon.isEmpty && !connectionFailed
          ? await _matchingPendingOrder(planId, cycle)
          : null;
      if (pending != null) return pending;
      throw StateError(_dioMessage(error));
    }
    final tradeNo = data is String ? data.trim() : '';
    if (tradeNo.isEmpty) {
      throw StateError(AppLocalizations().salmonOrderInvalid);
    }
    await _removeDataCache(_ordersDataCacheKey);
    return tradeNo;
  }

  Future<Map<String, dynamic>> checkCoupon({
    required int planId,
    required String code,
  }) async {
    final normalized = code.trim();
    if (normalized.isEmpty) throw StateError('请输入优惠码');
    final data = await _authenticatedRequest(
      'user/coupon/check',
      method: 'POST',
      body: {'plan_id': planId, 'code': normalized},
    );
    if (data is bool) {
      if (!data) throw StateError('优惠码不可用');
      return <String, dynamic>{'valid': true};
    }
    if (data is! Map) throw StateError('优惠码校验返回异常');
    final result = Map<String, dynamic>.from(data);
    final validity = result['valid'] ?? result['success'] ?? result['status'];
    final invalid = switch (validity) {
      false => true,
      num value => value == 0,
      String value => {
        'false',
        '0',
        'invalid',
        'error',
      }.contains(value.trim().toLowerCase()),
      _ => false,
    };
    if (invalid) {
      final message = result['message'] ?? result['msg'] ?? result['error'];
      throw StateError(
        message?.toString().trim().isNotEmpty == true
            ? message.toString()
            : '优惠码不可用',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> checkoutOrder({
    required String tradeNo,
    required int method,
  }) async {
    dynamic root;
    try {
      root = await _requestOrder(
        'user/order/checkout',
        method: 'POST',
        body: {'trade_no': tradeNo, 'method': method},
      );
    } on DioException catch (error) {
      throw StateError(_dioMessage(error));
    }
    final value = root is Map && root['data'] is Map ? root['data'] : root;
    if (value is! Map) throw StateError(_responseMessage(root));
    final checkout = Map<String, dynamic>.from(value);
    final type = int.tryParse('${checkout['type']}');
    final data = checkout['data'];
    if (type == -1 && data == true) return checkout;
    if ((type != 0 && type != 1) || data is! String || data.trim().isEmpty) {
      throw StateError(_responseMessage(root));
    }
    return checkout;
  }

  Future<dynamic> _requestOrder(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Duration? timeout,
    String? baseUrlOverride,
    CancelToken? cancellation,
  }) async {
    final requestTimeout = timeout != null && timeout < _orderRequestTimeout
        ? timeout
        : _orderRequestTimeout;
    final preferences = await SharedPreferences.getInstance();
    final baseUrl = baseUrlOverride ?? preferences.getString(_baseUrlKey);
    final authData = preferences.getString(_authDataKey);
    if (baseUrl == null || authData == null) {
      throw SalmonSessionExpiredException();
    }
    final generation = _sessionGeneration;
    final cancelToken = cancellation ?? CancelToken();
    // Bound the entire request, including DNS, TLS and interceptors. Mutating
    // payment requests must never be replayed automatically on another domain.
    late final Response<dynamic> response;
    try {
      response = await _dio
          .request<dynamic>(
            '$baseUrl/api/v1/$path',
            data: body,
            cancelToken: cancelToken,
            options: Options(
              method: method,
              headers: {'Authorization': authData},
              contentType: body == null
                  ? null
                  : Headers.formUrlEncodedContentType,
              connectTimeout: requestTimeout,
              sendTimeout: requestTimeout,
              receiveTimeout: requestTimeout,
            ),
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              cancelToken.cancel('Order request timeout');
              throw DioException(
                requestOptions: RequestOptions(path: path),
                type: DioExceptionType.receiveTimeout,
                message: 'Order request timeout',
              );
            },
          );
    } on DioException catch (error) {
      if (!await _isCurrentSession(authData, generation)) {
        throw SalmonSessionExpiredException();
      }
      if (_isSessionExpiredStatus(error.response?.statusCode)) {
        throw SalmonSessionExpiredException();
      }
      rethrow;
    }
    if (!await _isCurrentSession(authData, generation)) {
      throw SalmonSessionExpiredException();
    }
    return response.data;
  }

  /// Wait until V2Board marks an order as completed (status 3).
  Future<bool> waitForOrderCompleted(
    String tradeNo, {
    Duration timeout = const Duration(minutes: 3),
    Duration interval = const Duration(seconds: 3),
    bool Function()? shouldContinue,
  }) async {
    final generation = _sessionGeneration;
    final watch = Stopwatch()..start();
    bool active() =>
        generation == _sessionGeneration &&
        watch.elapsed < timeout &&
        (shouldContinue?.call() ?? true);
    Future<void> pause(Duration duration) async {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) return;
      await Future<void>.delayed(duration < remaining ? duration : remaining);
    }

    while (active()) {
      try {
        final root = await _requestOrder(
          'user/order/fetch',
          timeout: timeout - watch.elapsed,
        );
        if (!active()) return false;
        final orders = root is Map ? root['data'] : null;
        if (orders is! List) throw const FormatException('Invalid order list');
        final matches = orders.where(
          (item) => item is Map && '${item['trade_no'] ?? ''}' == tradeNo,
        );
        if (matches.isNotEmpty) {
          final status = int.tryParse('${matches.first['status']}') ?? -1;
          if (status == 3) {
            // Confirmation is complete. Account/node refresh belongs to the
            // caller and must not keep payment polling alive for three rounds.
            return true;
          }
          if (status == 2) return false;
        }
      } on SalmonSessionExpiredException {
        rethrow;
      } catch (_) {
        // Temporary network failures should not stop payment confirmation.
      }
      if (active()) await pause(interval);
    }
    return false;
  }

  /// Clear stale membership data and immediately fetch the paid plan.
  Future<Map<String, dynamic>> refreshMembershipData() async {
    final generation = _sessionGeneration;
    await _withSessionMutation(() async {
      _checkGeneration(generation);
      await _removeDataCache(_userDataCacheKey);
      await _removeDataCache(_subscribeDataCacheKey);
      await _removeDataCache(_ordersDataCacheKey);
      salmonAccountCache = null;
      salmonAccountCacheAt = null;
    });
    _checkGeneration(generation);
    final values = await Future.wait([
      fetchUserInfo(forceRefresh: true),
      fetchSubscribeInfo(forceRefresh: true),
      fetchOrders(forceRefresh: true),
      fetchPlans(forceRefresh: true),
    ]);
    _checkGeneration(generation);
    final user = Map<String, dynamic>.from(values[0] as Map);
    final subscription = Map<String, dynamic>.from(values[1] as Map);
    final plans = values[3] as List<Map<String, dynamic>>;
    final planId = int.tryParse(
      '${subscription['plan_id'] ?? user['plan_id'] ?? ''}',
    );
    Map<String, dynamic>? currentPlan;
    for (final plan in plans) {
      if (int.tryParse('${plan['id']}') == planId) {
        currentPlan = plan;
        break;
      }
    }
    final userPlan = user['plan'];
    final resolvedPlanName =
        currentPlan?['name']?.toString() ??
        (userPlan is Map ? userPlan['name']?.toString() : null) ??
        user['plan_name']?.toString() ??
        subscription['plan_name']?.toString();
    final hasPlanId = planId != null && planId > 0;
    final result = <String, dynamic>{
      ...user,
      ...subscription,
      'plan_name':
          resolvedPlanName == null ||
              resolvedPlanName.isEmpty ||
              (resolvedPlanName == '暂无套餐' && hasPlanId)
          ? (hasPlanId ? '已有套餐' : '暂无套餐')
          : resolvedPlanName,
      'plan_quota_gb':
          currentPlan?['transfer_enable'] ??
          subscription['transfer_enable'] ??
          user['transfer_enable'],
    };
    for (final key in [
      'reset_at',
      'reset_time',
      'reset_date',
      'reset_day',
      'reset_traffic_method',
    ]) {
      if (result[key] == null && currentPlan?[key] != null) {
        result[key] = currentPlan![key];
      }
    }
    await _withSessionMutation(() async {
      final preferences = await SharedPreferences.getInstance();
      _checkGeneration(generation);
      final subscribeUrl = subscription['subscribe_url']?.toString() ?? '';
      if (subscribeUrl.isNotEmpty) {
        final baseUrl = preferences.getString(_baseUrlKey);
        final resolved = baseUrl == null || Uri.parse(subscribeUrl).hasScheme
            ? subscribeUrl
            : Uri.parse(baseUrl).resolve(subscribeUrl).toString();
        await preferences.setString(_subscribeUrlKey, resolved);
      }
      salmonAccountCache = result;
      salmonAccountCacheAt = DateTime.now();
    });
    _checkGeneration(generation);
    membershipRevision.value++;
    return result;
  }

  Future<dynamic> _authenticatedRequest(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? queryParameters,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final baseUrl = preferences.getString(_baseUrlKey);
    final authData = preferences.getString(_authDataKey);
    if (baseUrl == null || authData == null) {
      throw SalmonSessionExpiredException();
    }
    final generation = _sessionGeneration;
    final canFailover = method.toUpperCase() == 'GET';
    final attempted = <String>{};
    var credentialFailures = 0;
    var networkFailures = 0;
    var otherFailures = 0;
    Object? lastError;

    Future<_SalmonRequestResult?> requestFrom(String candidate) async {
      attempted.add(candidate);
      if (!await _isCurrentSession(authData, generation)) {
        throw SalmonSessionExpiredException();
      }
      try {
        final response = await _dio.request<dynamic>(
          '$candidate/api/v1/$path',
          data: body,
          queryParameters: queryParameters,
          options: Options(
            method: method,
            contentType: body == null
                ? null
                : Headers.formUrlEncodedContentType,
            headers: {'Authorization': authData},
          ),
        );
        if (!await _isCurrentSession(authData, generation)) {
          throw SalmonSessionExpiredException();
        }
        await _promoteBaseUrl(candidate, authData, generation);
        if (!await _isCurrentSession(authData, generation)) {
          throw SalmonSessionExpiredException();
        }
        if (response.data is Map) {
          return _SalmonRequestResult(response.data['data']);
        }
        throw StateError(_responseMessage(response.data));
      } on SalmonSessionExpiredException {
        rethrow;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (_isSessionExpiredStatus(status)) {
          credentialFailures++;
        } else if (_isTransientStatus(status) || status == null) {
          networkFailures++;
        } else {
          otherFailures++;
        }
        lastError = error;
        if (!canFailover ||
            (!_isSessionExpiredStatus(status) && !_isTransientStatus(status))) {
          rethrow;
        }
      } catch (error) {
        otherFailures++;
        lastError = error;
        if (!canFailover) rethrow;
      }
      return null;
    }

    final candidates = _supportedApiCandidates([
      baseUrl,
      if (canFailover) ...(await _cachedLoginCandidates()),
    ]);
    for (final candidate in candidates) {
      final result = await requestFrom(candidate);
      if (result != null) return result.data;
    }

    if (canFailover) {
      final refreshed = await _apiCandidates(forceRefresh: true);
      for (final candidate in _supportedApiCandidates(refreshed)) {
        if (attempted.contains(candidate)) continue;
        final result = await requestFrom(candidate);
        if (result != null) return result.data;
      }
    }

    if (credentialFailures > 0 && networkFailures == 0 && otherFailures == 0) {
      await clear(expectedAuthData: authData, expectedGeneration: generation);
      throw SalmonSessionExpiredException();
    }
    if (lastError != null) throw lastError!;
    throw StateError('服务器暂时无法连接');
  }

  bool _isSessionExpiredStatus(int? status) => status == 401 || status == 419;

  bool _isTransientStatus(int? status) {
    if (status == null) return true;
    return status == 404 || status == 408 || status == 429 || status >= 500;
  }

  bool _canUseStaleCache(Object error) =>
      error is DioException || error is TimeoutException;

  Future<void> _promoteBaseUrl(
    String baseUrl,
    String expectedAuthData,
    int expectedGeneration,
  ) async {
    await _withSessionMutation(() async {
      final preferences = await SharedPreferences.getInstance();
      if (_sessionGeneration == expectedGeneration &&
          preferences.getString(_authDataKey) == expectedAuthData &&
          preferences.getString(_baseUrlKey) != baseUrl) {
        await preferences.setString(_baseUrlKey, baseUrl);
      }
    });
  }

  Future<String?> _matchingPendingOrder(int planId, String cycle) async {
    try {
      final root = await _requestOrder(
        'user/order/fetch',
        timeout: const Duration(seconds: 3),
      );
      final data = root is Map ? root['data'] : null;
      if (data is! List) return null;
      for (final value in data.whereType<Map>()) {
        final order = Map<String, dynamic>.from(value);
        final status = int.tryParse('${order['status']}');
        final orderPlanId = int.tryParse('${order['plan_id']}');
        if (status == 0 &&
            orderPlanId == planId &&
            (order['period'] ?? order['cycle'])?.toString() == cycle) {
          final tradeNo = order['trade_no']?.toString() ?? '';
          if (tradeNo.isNotEmpty) return tradeNo;
        }
      }
    } on SalmonSessionExpiredException {
      rethrow;
    } catch (_) {
      return null;
    }
    return null;
  }

  String _dioMessage(DioException error, {String fallback = '请求失败'}) {
    final data = error.response?.data;
    if (data is Map) {
      final errors = data['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final details = <String>[];
        for (final entry in errors.entries) {
          final value = entry.value;
          final text = value is List ? value.join('、') : value.toString();
          details.add('${entry.key}：$text');
        }
        if (details.isNotEmpty) return details.join('\n');
      }
      final message = data['message'] ?? data['msg'] ?? data['error'];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString();
      }
    }
    if (error.response == null) {
      return salmonFriendlyError(error, fallback: fallback);
    }
    return '$fallback（${error.response?.statusCode ?? '网络异常'}）';
  }

  Future<String> _login(String baseUrl, String account, String password) async {
    final cancelToken = CancelToken();
    final response = await _dio
        .post<dynamic>(
          '$baseUrl/api/v1/passport/auth/login',
          cancelToken: cancelToken,
          data: {'email': account, 'password': password},
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 5),
            sendTimeout: const Duration(seconds: 5),
          ),
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            cancelToken.cancel('Login deadline exceeded');
            throw DioException(
              requestOptions: RequestOptions(path: baseUrl),
              type: DioExceptionType.connectionTimeout,
            );
          },
        );
    final data = _responseData(response.data);
    final authData = data['auth_data']?.toString();
    if (authData == null || authData.isEmpty) {
      throw StateError(_responseMessage(response.data));
    }
    return authData;
  }

  bool _isTransientLoginError(DioException error) {
    return {
          DioExceptionType.connectionError,
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout,
        }.contains(error.type) ||
        {408, 429, 502, 503, 504}.contains(error.response?.statusCode) ||
        error.error is SocketException ||
        error.error is TimeoutException;
  }

  Future<String> _getSubscribeUrl(String baseUrl, String authData) async {
    final response = await _dio.get<dynamic>(
      '$baseUrl/api/v1/user/getSubscribe',
      options: Options(
        headers: {'Authorization': authData},
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final data = _responseData(response.data);
    final value = data['subscribe_url']?.toString();
    if (value == null || value.isEmpty) {
      throw StateError(_responseMessage(response.data));
    }
    final uri = Uri.parse(value);
    return uri.hasScheme ? value : Uri.parse(baseUrl).resolve(value).toString();
  }

  Map<String, dynamic> _responseData(dynamic response) {
    if (response is Map<String, dynamic>) {
      final data = response['data'];
      if (data is Map<String, dynamic>) return data;
    }
    throw StateError(_responseMessage(response));
  }

  String _responseMessage(dynamic response) {
    if (response is Map<String, dynamic>) {
      return response['message']?.toString() ?? 'Request failed';
    }
    return 'Request failed';
  }

  Future<T> _withSessionMutation<T>(Future<T> Function() action) {
    final previous = _sessionMutation;
    final release = Completer<void>();
    _sessionMutation = release.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        release.complete();
      }
    }();
  }

  Future<bool> _isCurrentSession(String authData, int generation) async {
    final preferences = await SharedPreferences.getInstance();
    return _sessionGeneration == generation &&
        preferences.getString(_authDataKey) == authData;
  }

  Future<bool> _saveIfCurrent(
    SalmonSession session,
    String expectedAuthData,
    int expectedGeneration,
  ) {
    return _withSessionMutation(() async {
      final preferences = await SharedPreferences.getInstance();
      if (_sessionGeneration != expectedGeneration ||
          preferences.getString(_authDataKey) != expectedAuthData) {
        return false;
      }
      await _saveUnsafe(session, preferences);
      return true;
    });
  }

  Future<int> _save(SalmonSession session) {
    return _withSessionMutation(() async {
      final preferences = await SharedPreferences.getInstance();
      return _saveUnsafe(session, preferences, advanceGeneration: true);
    });
  }

  Future<int> _saveUnsafe(
    SalmonSession session,
    SharedPreferences preferences, {
    bool advanceGeneration = false,
  }) async {
    final previousAuthData = preferences.getString(_authDataKey);
    if (previousAuthData != null && previousAuthData != session.authData) {
      await _clearAccountDataCaches();
      _clearMemoryCaches();
    }
    if (advanceGeneration) _sessionGeneration++;
    await preferences.setString(_baseUrlKey, session.baseUrl);
    await preferences.setString(_authDataKey, session.authData);
    await preferences.setString(_subscribeUrlKey, session.subscribeUrl);
    return _sessionGeneration;
  }

  Future<void> clear({String? expectedAuthData, int? expectedGeneration}) {
    return _withSessionMutation(() async {
      final preferences = await SharedPreferences.getInstance();
      if ((expectedGeneration != null &&
              _sessionGeneration != expectedGeneration) ||
          (expectedAuthData != null &&
              preferences.getString(_authDataKey) != expectedAuthData)) {
        return;
      }
      await _clearUnsafe(preferences);
    });
  }

  Future<void> _clearUnsafe(SharedPreferences preferences) async {
    _sessionGeneration++;
    await preferences.remove(_baseUrlKey);
    await preferences.remove(_authDataKey);
    await preferences.remove(_subscribeUrlKey);
    await _clearAccountDataCaches();
    await preferences.remove(_chatContactKey);
    await preferences.remove(_chatConversationKey);
    await preferences.remove(_chatEmailKey);
    await preferences.remove(_chatScopeKey);
    _clearMemoryCaches();
    sessionRevision.value++;
  }

  void _clearMemoryCaches() {
    salmonCurrentNodeName = null;
    salmonAccountCache = null;
    salmonNoticeCache = null;
    salmonPlansCache = null;
    salmonPaymentsCache = null;
    salmonAccountCacheAt = null;
    salmonStoreCacheAt = null;
    salmonNoticeCacheAt = null;
    salmonNodesUpdatedThisSession = false;
  }
}

final salmonService = SalmonService();
String? salmonCurrentNodeName;
