import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:kinde_flutter_sdk/src/additional_params.dart';
import 'package:kinde_flutter_sdk/src/utils/helpers.dart';
import 'package:kinde_flutter_sdk/src/utils/kinde_custom_types.dart';
import 'package:kinde_flutter_sdk/src/utils/kinde_debug_print.dart';
import 'package:kinde_flutter_sdk/src/utils/single_flight.dart';
import 'package:kinde_flutter_sdk/src/kinde_secure_storage/kinde_secure_storage.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/kinde_web.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/cross_platform_support.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/cross_tab_lock.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import 'package:kinde_flutter_sdk/kinde_flutter_sdk.dart';
import 'package:kinde_flutter_sdk/src/keys/keys_api.dart';
import 'package:kinde_flutter_sdk/src/store/store.dart';
import 'package:kinde_flutter_sdk/src/token/auth_state.dart';
import 'package:kinde_flutter_sdk/src/token/refresh_token_interceptor.dart';
import 'package:kinde_flutter_sdk/src/token/token_api.dart';
import 'package:kinde_flutter_sdk/src/token/token_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

class KindeFlutterSDK with TokenUtils {
  static const _registrationPageParamValue = 'registration';
  static const _authPath = '/oauth2/auth';
  static const _tokenPath = '/oauth2/token';
  static const _logoutPath = '/logout';
  static const _defaultScopes = ['openid', 'profile', 'email', 'offline'];
  static const _bearerAuth = 'kindeBearerAuth';
  static const _clientIdParamName = 'client_id';
  static const _refreshLockTimeout = Duration(seconds: 5);
  static const _authorisationResponseParameters = {
    'code',
    'state',
    'error',
    'error_description',
    'error_uri',
    'iss',
    'session_state',
  };

  // Background token refresh timer (matches Kinde js-utils pattern)
  Timer? _refreshTimer;

  // Timer constants matching js-utils SDK
  // Reference: js-utils/lib/utils/refreshTimer.ts (10s buffer, 24h max)
  static const Duration _refreshBufferDuration = Duration(seconds: 10);
  static const Duration _maxRefreshInterval = Duration(hours: 24);
  static const Duration _minRefreshInterval = Duration(seconds: 5);
  static const Duration _firstRetryDelay = Duration(seconds: 5);
  static const Duration _maxRetryDelay = Duration(minutes: 5);

  // Singleton
  static KindeFlutterSDK? _instance;

  @override
  AuthState? get authState => _store.authState;

  static AuthConfig? _config;
  late KindeApi _kindeApi;
  late KeysApi _keysApi;
  late TokenApi _tokenApi;
  final _tokenRefresh = SingleFlight<String?>();
  final _loginCompletion = SingleFlight<bool>();
  late final String? Function() _currentUrl;
  late final void Function(String url) _replaceUrl;
  Duration _retryDelay = _firstRetryDelay;
  late AuthorizationServiceConfiguration _serviceConfiguration;

  static KindeFlutterSDK get instance {
    return _instance ??= KindeFlutterSDK._internal();
  }

  KindeFlutterSDK._internal(
      {Dio? dio,
      String? Function()? currentUrl,
      void Function(String url)? replaceUrl}) {
    _currentUrl =
        currentUrl ?? () => kIsWeb ? WebUtils.getCurrentUrl : null;
    _replaceUrl = replaceUrl ?? WebUtils.replaceCurrentUrl;
    if (_config == null) {
      throw KindeError(
        code: KindeErrorCode.missingConfig.code,
        message: 'KindeFlutterSDK has not been configured',
      );
    }

    var domainUrl = "";
    if (_config!.authDomain.startsWith('https')) {
      domainUrl = _config!.authDomain;
    } else if (_config!.authDomain.startsWith('http')) {
      domainUrl = _config!.authDomain.replaceFirst('http', "https");
    } else {
      domainUrl = 'https://${_config!.authDomain}';
    }

    _serviceConfiguration = AuthorizationServiceConfiguration(
        authorizationEndpoint: '$domainUrl$_authPath',
        tokenEndpoint: '$domainUrl$_tokenPath',
        endSessionEndpoint: '$domainUrl$_logoutPath');
    dio ??= Dio(BaseOptions(
      baseUrl: domainUrl,
    ));

    _kindeApi = KindeApi(dio: dio, interceptors: [
      BearerAuthInterceptor(),
      RefreshTokenInterceptor(
        dio: dio,
        refreshToken: getToken,
      ),
    ]);
    _keysApi = KeysApi(_kindeApi.dio);
    _tokenApi = TokenApi(_kindeApi.dio);

    if (_store.keys == null) {
      _keysApi.getKeys().then((value) {
        _store.keys = value;
      });
    }

    var token = authState?.accessToken;
    if (token != null) {
      _kindeApi.setBearerAuth(_bearerAuth, token);
    }
  }

  Store get _store => Store.instance;

  static Future<KindeFlutterSDK> initializeSDK({
    required String authDomain,
    required String authClientId,
    required String loginRedirectUri,
    required String logoutRedirectUri,
    List<String> scopes = _defaultScopes,
    String? audience,
  }) async {
    return _initializeSDK(
        authDomain: authDomain,
        authClientId: authClientId,
        loginRedirectUri: loginRedirectUri,
        logoutRedirectUri: logoutRedirectUri,
        scopes: scopes,
        audience: audience);
  }

  static Future<KindeFlutterSDK> _initializeSDK(
      {required String authDomain,
      required String authClientId,
      required String loginRedirectUri,
      required String logoutRedirectUri,
      required List<String> scopes,
      String? audience,
      Dio? dio,
      String? Function()? currentUrl,
      void Function(String url)? replaceUrl}) async {
    String step = 'initializing';
    void updateStep(String newStep) {
      step = newStep;
    }

    try {
      step = 'config setup';
      _config = AuthConfig(
        authDomain: authDomain,
        authClientId: authClientId,
        loginRedirectUri: loginRedirectUri,
        logoutRedirectUri: logoutRedirectUri,
        scopes: scopes,
        audience: audience,
      );

      final kindeSecureStorage = KindeSecureStorage();

      await _initializeStore(kindeSecureStorage, stepUpdater: updateStep);

      await _initializeWebLayerIfNeeded(kindeSecureStorage,
          stepUpdater: updateStep);

      updateStep('finalization');

      return _instance = KindeFlutterSDK._internal(
          dio: dio, currentUrl: currentUrl, replaceUrl: replaceUrl);
    } catch (e, st) {
      _config = null;
      kindeDebugPrint(
          methodName: "KindeFlutterSDK.initializeSDK",
          message: 'SDK initialization failed at step: $step');
      if (e is KindeError) rethrow;

      throw KindeError(
        code: KindeErrorCode.initializingFailed.code,
        message: 'Error during "$step": ${e.toString()}',
        stackTrace: st,
      );
    }
  }

  static Future<void> _initializeStore(KindeSecureStorage kindeSecureStorage,
      {required InitializationStepUpdater stepUpdater}) async {
    stepUpdater('secure storage initialization');
    await Store.init();

    stepUpdater('loading cached data');
    await Store.instance.loadFromStorage();
  }

  static Future<void> _initializeWebLayerIfNeeded(
      KindeSecureStorage kindeSecureStorage,
      {required InitializationStepUpdater stepUpdater}) async {
    if (kIsWeb) {
      stepUpdater('web layer initialization');
      await KindeWeb.initialize(secureStorage: kindeSecureStorage);
    }
  }

  static Future<String> getTemporaryDirectoryPath() async {
    Directory? path;
    if (!kIsWeb) {
      path = await getTemporaryDirectory();
      return path.path;
    } else {
      return WebUtils.temporaryDirectory;
    }
  }

  /// Logs out the user from the Kinde session.
  ///
  /// For web platforms, this redirects to [logoutRedirectUri].
  /// For mobile/desktop, uses FlutterAppAuth.endSession() with proper redirect handling.
  ///
  /// Parameters:
  /// - [dio] - Optional Dio client for direct HTTP logout fallback (macOS only)
  /// - [macosLogoutWithoutRedirection] - On macOS, use direct HTTP logout without browser redirect (default: true)
  /// - [timeout] - Timeout duration for logout request (default: 30 seconds)
  /// - [endSessionOnWeb] - On web, end the Kinde session through the logout
  ///   endpoint before returning to [logoutRedirectUri], so the next login
  ///   cannot reuse it (default: false)
  Future<void> logout({
    Dio? dio,
    bool macosLogoutWithoutRedirection = true,
    Duration timeout = const Duration(seconds: 30),
    bool endSessionOnWeb = false,
  }) async {
    if (authState == null) {
      kindeDebugPrint(methodName: "logout", message: "AuthState is null.");
      return;
    }
    if (kIsWeb) {
      // The page navigates away, so local cleanup must finish first.
      await _commonLogoutCleanup();
      await _handleWebLogout(endSession: endSessionOnWeb);
      return;
    }
    await _handleNonWebLogout(
        dio: dio,
        macosLogoutWithoutRedirection: macosLogoutWithoutRedirection,
        timeout: timeout);

    await _commonLogoutCleanup();
  }

  Future<void> _handleNonWebLogout({
    Dio? dio,
    required bool macosLogoutWithoutRedirection,
    required Duration timeout,
  }) async {
    if (Platform.operatingSystem == "macos" && macosLogoutWithoutRedirection) {
      return _logoutWithoutRedirection(dio: dio);
    }

    try {
      const appAuth = FlutterAppAuth();
      // EndSessionRequest parameters:
      // - externalUserAgent: Uses ASWebAuthenticationSession (iOS) / Custom Tabs (Android)
      //   for secure browser-based logout flow
      // - idTokenHint: Required for org-specific logout in multi-org scenarios (OIDC recommended)
      // - postLogoutRedirectUrl: Where to redirect user after logout (OIDC post_logout_redirect_uri)
      // - serviceConfiguration: Contains the logout endpoint URL
      //
      // NOTE: Removed redundant additionalParameters["redirect"] - postLogoutRedirectUrl
      // already handles the redirect via standard OIDC post_logout_redirect_uri parameter.
      // This reduces URL length and follows OIDC spec more closely.
      final endSessionRequest = EndSessionRequest(
          externalUserAgent:
              ExternalUserAgent.ephemeralAsWebAuthenticationSession,
          idTokenHint: authState!.idToken,
          postLogoutRedirectUrl: _config!.logoutRedirectUri,
          serviceConfiguration: _serviceConfiguration);

      await appAuth.endSession(endSessionRequest).timeout(timeout,
          onTimeout: () {
        throw KindeError(
            code: KindeErrorCode.requestTimedOut.code,
            message: 'Logout request timed out');
      });
    } catch (e, st) {
      kindeDebugPrint(methodName: "Logout", message: e.toString());
      throw KindeError.fromError(e, st);
    }
  }

  Future<void> _handleWebLogout({required bool endSession}) async {
    if (_config?.logoutRedirectUri != null &&
        _config!.logoutRedirectUri.isNotEmpty) {
      KindeWeb.instance.logout(webLogoutUrl(
        endSessionEndpoint: _serviceConfiguration.endSessionEndpoint!,
        logoutRedirectUri: _config!.logoutRedirectUri,
        endSession: endSession,
      ));
    }
  }

  Future<void> _commonLogoutCleanup() async {
    // Clear refresh timer on logout (matches js-utils pattern)
    _clearRefreshTimer();
    _tokenRefresh.detach();

    _kindeApi.setBearerAuth(_bearerAuth, '');
    await _withRefreshLock(Store.instance.clear);
  }

  Future<T> _withRefreshLock<T>(Future<T> Function() task) =>
      runWithCrossTabLock(
        'kinde-refresh:${_config!.authClientId}',
        timeout: _refreshLockTimeout,
        task: (_) => task(),
      );

  /// Logs out the user without redirection using a direct HTTP GET request.
  ///
  /// This method performs a simple logout by calling the logout endpoint
  /// without any additional parameters. It does NOT redirect the user after logout.
  ///
  /// Use this only when:
  /// - Running on macOS with macosLogoutWithoutRedirection=true
  /// - You need to avoid the 414 error and don't need redirect functionality
  ///
  /// Note: This approach does not include the id_token_hint, which may be
  /// required for org-specific logout in multi-organization scenarios.
  Future<void> _logoutWithoutRedirection({Dio? dio}) async {
    try {
      var dioClient = dio ?? Dio();
      final response =
          await dioClient.get(_serviceConfiguration.endSessionEndpoint!);

      await _commonLogoutCleanup();

      if (response.statusCode != null && response.statusCode! >= 400) {
        final errorMessage = response.data is Map
            ? response.data['error_description'] ??
                response.data['error'] ??
                "Unknown error"
            : "Logout failed with status: ${response.statusCode}";
        throw KindeError(
            code: KindeErrorCode.logoutRequestFailed.code, message: errorMessage);
      }
    } catch (error, st) {
      throw KindeError.fromError(error, st);
    }
  }

  /// for web it returns null, and invokes loginRedirectUri
  Future<String?> login({
    AuthFlowType? type,
    AdditionalParameters additionalParams = const AdditionalParameters(),
  }) async {
    final internalAdditionalParams =
        _prepareInternalAdditionalParameters(additionalParams);
    return _redirectToKinde(
      type: type,
      internalAdditionalParameters: internalAdditionalParams,
    );
  }

  InternalAdditionalParameters _prepareInternalAdditionalParameters(
      AdditionalParameters additionalParams) {
    final internalAdditionalParams =
        InternalAdditionalParameters.fromUserAdditionalParams(additionalParams);
    internalAdditionalParams.audience = _config!.audience;
    internalAdditionalParams.scopes = _config!.scopes;
    return internalAdditionalParams;
  }

  /// for web it returns null, and invokes loginRedirectUri
  Future<String?> _redirectToKinde({
    AuthFlowType? type,
    required InternalAdditionalParameters internalAdditionalParameters,
  }) async {
    if (kIsWeb) {
      await _handleWebLogin(internalAdditionalParameters);
    } else {
      return _handleOtherLogin(type, internalAdditionalParameters);
    }
    return null;
  }

  //MacOs, Android, IOS
  Future<String?> _handleOtherLogin(
      AuthFlowType? type, InternalAdditionalParameters params) async {
    const appAuth = FlutterAppAuth();
    TokenResponse tokenResponse;
    try {
      if (type == AuthFlowType.pkce) {
        final authorizationRequest = _createAuthorizationRequest(params);
        final AuthorizationResponse result =
            await appAuth.authorize(authorizationRequest);
        final tokenRequest = _createTokenRequest(
            authorizationResponse: result,
            scopes: params.scopes,
            additionalParameters: authorizationRequest.additionalParameters);
        tokenResponse = await appAuth.token(tokenRequest);
      } else {
        final authorizationTokenRequest =
            _createAuthorizationTokenRequest(params);
        tokenResponse =
            await appAuth.authorizeAndExchangeCode(authorizationTokenRequest);
      }

      if (params.orgName != null) {
        return params.orgName;
      }

      _saveState(tokenResponse);
      return tokenResponse.accessToken;
    } catch (e, st) {
      throw KindeError.fromError(e, st);
    }
  }

  TokenRequest _createTokenRequest(
          {required AuthorizationResponse authorizationResponse,
          List<String>? scopes,
          Map<String, String>? additionalParameters}) =>
      TokenRequest(
        _config!.authClientId,
        _config!.loginRedirectUri,
        codeVerifier: authorizationResponse.codeVerifier,
        authorizationCode: authorizationResponse.authorizationCode,
        serviceConfiguration: _serviceConfiguration,
        nonce: authorizationResponse.nonce,
        scopes: scopes,
        additionalParameters: additionalParameters,
      );

  AuthorizationRequest _createAuthorizationRequest(
      InternalAdditionalParameters additionalParameters) {
    final authorizationRequestParams =
        additionalParameters.toAuthorizationRequestParams();
    final authorizationRequest = AuthorizationRequest(
        _config!.authClientId, _config!.loginRedirectUri,
        serviceConfiguration: _serviceConfiguration,
        externalUserAgent:
            ExternalUserAgent.ephemeralAsWebAuthenticationSession,
        additionalParameters: authorizationRequestParams,
        scopes: additionalParameters.scopes,
        promptValues: additionalParameters.promptValues);
    return authorizationRequest;
  }

  AuthorizationTokenRequest _createAuthorizationTokenRequest(
      InternalAdditionalParameters additionalParameters) {
    final authorizationRequestParams =
        additionalParameters.toAuthorizationRequestParams();
    final authorizationTokenRequest = AuthorizationTokenRequest(
        _config!.authClientId, _config!.loginRedirectUri,
        serviceConfiguration: _serviceConfiguration,
        externalUserAgent:
            ExternalUserAgent.ephemeralAsWebAuthenticationSession,
        additionalParameters: authorizationRequestParams,
        scopes: additionalParameters.scopes,
        promptValues: additionalParameters.promptValues);
    return authorizationTokenRequest;
  }

  Future<void> _handleWebLogin(
    InternalAdditionalParameters params,
  ) {
    return KindeWeb.instance.startLoginFlow(
        AuthorizationRequest(
          _config!.authClientId,
          _config!.loginRedirectUri,
          serviceConfiguration: _serviceConfiguration,
          externalUserAgent:
              ExternalUserAgent.ephemeralAsWebAuthenticationSession,
        ),
        additionalParameters: params);
  }

  Future<bool> _finishWebLogin(String responseUrl, String responseState) async {
    final login = await KindeWeb.instance.finishLoginFlow(
        scopes: _config!.scopes,
        redirectUrl: _config!.loginRedirectUri,
        responseUrl: responseUrl,
        responseState: responseState,
        clientId: _config!.authClientId,
        authorizationEndpoint: _serviceConfiguration.authorizationEndpoint,
        tokenEndpoint: _serviceConfiguration.tokenEndpoint);

    if (login == null) {
      kindeDebugPrint(
          methodName: "finishWebLogin",
          message:
              "No credentials returned from finishLoginFlow. Login may have been canceled or failed.");
      return false;
    }
    final credentials = login.credentials;
    final requestedOrgCode = login.orgCode;
    final grantedOrgCode = orgCodeOf(credentials.accessToken);
    if (requestedOrgCode != null && grantedOrgCode != requestedOrgCode) {
      throw KindeError(
          code: KindeErrorCode.organizationMismatch.code,
          message:
              'Requested organization $requestedOrgCode but the token is for $grantedOrgCode.');
    }
    await _withRefreshLock(() async {
      await _store.reloadAuthState();
      _saveState(TokenResponse(
        credentials.accessToken,
        credentials.refreshToken,
        credentials.expiration,
        credentials.idToken,
        null,
        credentials.scopes,
        null,
      ));
      await _store.flushWrites();
    });

    return true;
  }

  /// for web it returns null, and invokes loginRedirectUri
  Future<String?> register({
    AuthFlowType? type,
    AdditionalParameters additionalParams = const AdditionalParameters(),
  }) async {
    final internalAdditionalParams =
        _prepareInternalAdditionalParameters(additionalParams);
    internalAdditionalParams.registrationPage = _registrationPageParamValue;

    return _redirectToKinde(
        type: type, internalAdditionalParameters: internalAdditionalParams);
  }

  Future<UserProfileV2?> getUserProfileV2() async {
    return _kindeApi.getOAuthApi().getUserProfileV2().then((value) {
      return value.data;
    }).catchError((error, st) {
      throw KindeError.fromError(error, st);
    });
  }

  Future<UserProfile?> getUser() async {
    return _kindeApi.getOAuthApi().getUser().then((value) {
      return value.data;
    }).catchError((error, st) {
      throw KindeError.fromError(error, st);
    });
  }

  Future<void> createOrg({
    required String orgName,
    AuthFlowType? type,
    String? planInterest,
    String? pricingTableKey,
  }) async {
    final params = _prepareInternalAdditionalParameters(AdditionalParameters(
      planInterest: planInterest,
      pricingTableKey: pricingTableKey,
    ));
    params.registrationPage = _registrationPageParamValue;
    params.createOrg = true;
    params.orgName = orgName;

    await _redirectToKinde(type: type, internalAdditionalParameters: params);
  }

  Future<String?> getToken({bool forceRefresh = false}) async {
    // Another tab may have refreshed since this one loaded its tokens.
    await _reloadAndAdopt();

    // Return existing token if authenticated and not forcing refresh
    if (!forceRefresh && await isAuthenticated()) {
      return _store.authState?.accessToken;
    }

    return _tokenRefresh.run(_refreshToken);
  }

  /// Exchanges the refresh token for new tokens. Callers share one request,
  /// so a timer and a manual refresh never send the same refresh token twice.
  Future<String?> _refreshToken() {
    final heldRefreshToken = authState?.refreshToken;
    return runWithCrossTabLock(
      'kinde-refresh:${_config!.authClientId}',
      timeout: _refreshLockTimeout,
      task: (_) => _refreshUnlessAlreadyRotated(heldRefreshToken),
    );
  }

  Future<String?> _refreshUnlessAlreadyRotated(String? heldRefreshToken) async {
    await _reloadAndAdopt();
    final refreshToken = authState?.refreshToken;
    if (refreshToken == null) {
      throw KindeError(code: KindeErrorCode.sessionExpiredOrInvalid.code);
    }
    if (refreshToken != heldRefreshToken) return _currentAccessToken();

    final version = await _getVersion();
    final versionParam = 'Flutter/$version';
    final generation = _store.authStateGeneration;

    final Map<String, dynamic> tokens;
    try {
      tokens = Map<String, dynamic>.from(await _tokenApi.retrieveToken(
          versionParam,
          _store.authState!.createRequestTokenParam()
            ..putIfAbsent(_clientIdParamName, () => _config!.authClientId)));
    } catch (e, st) {
      final error = KindeError.fromError(e, st);
      await _reloadAndAdopt();
      if (generation == _store.authStateGeneration) throw error;

      final rejectedTokensStillStored =
          error.code == KindeErrorCode.refreshTokenExpired.code &&
              _store.authState?.refreshToken == refreshToken;
      if (rejectedTokensStillStored) throw error;
      return _currentAccessToken();
    }

    await _reloadAndAdopt();
    if (generation != _store.authStateGeneration) return _currentAccessToken();

    try {
      // RFC 6749 section 6: a response without a refresh token keeps the old one.
      tokens['refresh_token'] ??= refreshToken;
      _store.authState = AuthState.fromJson(tokens);
      _kindeApi.setBearerAuth(_bearerAuth, _store.authState?.accessToken ?? '');
      // Other tabs waiting on the lock read storage, so the write must land first.
      await _store.flushWrites();
      return _store.authState?.accessToken;
    } catch (e, st) {
      throw KindeError.fromError(e, st);
    }
  }

  Future<void> _reloadAndAdopt() async {
    await _store.reloadAuthState();
    _kindeApi.setBearerAuth(_bearerAuth, _store.authState?.accessToken ?? '');
  }

  String? _currentAccessToken() {
    final current = _store.authState;
    if (current == null) {
      throw KindeError(
        code: KindeErrorCode.sessionExpiredOrInvalid.code,
        message: 'Signed out while the token refresh was in flight.',
      );
    }
    return current.accessToken;
  }

  /// Checks if the user is authenticated with a valid, non-expired token.
  ///
  /// This method performs a simple expiry check on the access token, matching
  /// the pattern used in Kinde's js-utils SDK and other Kinde SDKs.
  ///
  /// This method does **not** perform any login completion or mutate state.
  ///
  /// Returns `true` if:
  /// - Auth state exists
  /// - Access token exists and is not empty
  /// - Token has not expired
  ///
  /// Returns `false` otherwise.
  ///
  /// ⚠️ **Note:** If your app supports web-based login flows,
  /// make sure to call [completePendingLoginIfNeeded] first
  /// to finalize any in-progress authentication before calling this.
  ///
  /// Example:
  /// ```dart
  /// if (await sdk.isAuthenticated()) {
  ///   // User is authenticated
  /// } else {
  ///   // Redirect to login
  /// }
  /// ```
  Future<bool> isAuthenticated() async {
    final state = authState;
    if (state == null || state.isExpired()) {
      return false;
    }

    final token = state.accessToken;
    if (token == null || token.isEmpty) {
      return false;
    }

    return true;
  }

  /// Attempts to complete a pending web login flow if auth parameters
  /// are present in the current URL.
  ///
  /// This method performs a side-effect and may modify auth state
  /// and secure storage.
  ///
  /// Call this **before** checking authentication status.
  ///
  /// Only a response to a login this browser started is completed, once.
  Future<bool> completePendingLoginIfNeeded() =>
      _loginCompletion.run(_completePendingLogin);

  Future<bool> _completePendingLogin() async {
    final currentUrl = _currentUrl();
    final responseState = _authorisationResponseState(currentUrl);
    if (responseState == null) return false;

    try {
      return await _finishWebLogin(currentUrl!, responseState);
    } finally {
      _replaceUrl(_withoutAuthorisationResponse(currentUrl!));
    }
  }

  static String _withoutAuthorisationResponse(String url) {
    final uri = Uri.parse(url);
    final kept = {
      for (final MapEntry(:key, :value) in uri.queryParametersAll.entries)
        if (!_authorisationResponseParameters.contains(key)) key: value,
    };
    if (kept.isNotEmpty) return uri.replace(queryParameters: kept).toString();

    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }



  /// The `state` of [url] when it carries a `code` or an `error`, else null.
  static String? _authorisationResponseState(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;

    final parameters = uri.queryParameters;
    bool has(String name) => parameters[name]?.isNotEmpty ?? false;
    if (!has('state') || !(has('code') || has('error'))) return null;

    return parameters['state'];
  }

  _saveState(TokenResponse? tokenResponse) {
    _tokenRefresh.detach();
    _clearRefreshTimer();
    _store.authState = AuthState(
        accessToken: tokenResponse?.accessToken,
        idToken: tokenResponse?.idToken,
        accessTokenExpirationDateTime:
            tokenResponse?.accessTokenExpirationDateTime,
        refreshToken: tokenResponse?.refreshToken,
        scope: tokenResponse?.scopes?.join(' '));
    _kindeApi.setBearerAuth(_bearerAuth, tokenResponse?.accessToken ?? '');

    // Schedule next refresh after saving new token (matches js-utils pattern)
    _scheduleNextRefresh();
  }

  /// Sets a refresh timer with automatic cleanup and safety constraints.
  ///
  /// Matches the pattern from Kinde's js-utils SDK (refreshTimer.ts) where
  /// timers are always cleared before setting, and durations are constrained
  /// to prevent extremely long or short timers.
  ///
  /// The timer duration is automatically adjusted to be 10 seconds less than
  /// the requested duration (refresh buffer) and capped at 24 hours for safety.
  ///
  /// Reference: js-utils/lib/utils/refreshTimer.ts lines 40-52
  void _setRefreshTimer(Duration duration, VoidCallback callback) {
    _clearRefreshTimer(); // Always clear first (js-utils pattern)

    if (duration.inSeconds <= 0) {
      throw KindeError(
        code: KindeErrorCode.unknown.code,
        message: 'Timer duration must be positive',
      );
    }

    // Apply 10-second buffer and 24-hour cap (matching js-utils logic)
    // Math.min(timer * 1000 - 10000, 86400000)
    final adjustedDuration = Duration(
      milliseconds: min(
        duration.inMilliseconds - _refreshBufferDuration.inMilliseconds,
        _maxRefreshInterval.inMilliseconds,
      ),
    );

    // Ensure the minimum delay
    final safeDuration = adjustedDuration < _minRefreshInterval
        ? _minRefreshInterval
        : adjustedDuration;

    _refreshTimer = Timer(safeDuration, callback);
  }

  /// Clears the current refresh timer if one exists.
  ///
  /// Safe to call even if no timer is currently active.
  /// Matches js-utils clearRefreshTimer() pattern.
  ///
  /// Reference: js-utils/lib/utils/refreshTimer.ts lines 72-79
  void _clearRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Schedules the next background token refresh based on token expiry.
  ///
  /// Matches the pattern from Kinde's js-utils SDK where after every
  /// successful token refresh, the next refresh is automatically scheduled
  /// using the JWT 'exp' claim.
  ///
  /// Reference: js-utils/lib/utils/token/refreshToken.ts lines 144-156
  void _scheduleNextRefresh() {
    try {
      // Get expiry from access token's 'exp' claim using public API
      final expClaim = getClaim(claim: 'exp');
      final exp = expClaim.value as int?;

      if (exp == null) {
        // No exp claim, cannot schedule refresh
        return;
      }

      // Calculate seconds until expiry (matching js-utils pattern)
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final secsToExpiry = max(exp - nowSec, 1); // Minimum 1 second

      // Schedule refresh (will fire 10 seconds before actual expiry due to buffer)
      _setRefreshTimer(Duration(seconds: secsToExpiry), () async {
        await _performBackgroundRefresh();
      });
    } catch (e) {
      // If token parsing fails (e.g., in tests with mock tokens), silently skip
      // scheduling. This is safe as the timer simply won't be set.
      kindeDebugPrint(
        methodName: '_scheduleNextRefresh',
        message: 'Could not schedule refresh: $e',
      );
    }
  }

  /// Performs a background token refresh and schedules the next one.
  ///
  /// This method is called by the refresh timer 10 seconds before token expiry.
  /// Forces a token refresh even if the current token is still technically valid,
  /// ensuring seamless token renewal before expiration.
  ///
  /// Uses [forceRefresh] parameter to bypass the isAuthenticated() check,
  /// allowing refresh to occur before the token actually expires.
  Future<void> _performBackgroundRefresh() async {
    final triedRefreshToken = authState?.refreshToken;
    try {
      // Force refresh even if token is still valid (that's the point!)
      await getToken(forceRefresh: true);
    } catch (e) {
      kindeDebugPrint(
        methodName: '_performBackgroundRefresh',
        message: 'Background refresh failed: $e',
      );
      await _reloadAndAdopt();
      final storedRefreshToken = authState?.refreshToken;
      final sessionEnded = storedRefreshToken == null ||
          (e is KindeError &&
              e.code == KindeErrorCode.refreshTokenExpired.code &&
              storedRefreshToken == triedRefreshToken);
      if (sessionEnded) {
        _clearRefreshTimer();
        return;
      }
      if (storedRefreshToken == triedRefreshToken) {
        _scheduleRetry();
        return;
      }
    }

    _retryDelay = _firstRetryDelay;
    _scheduleNextRefresh();
  }

  void _scheduleRetry() {
    _clearRefreshTimer();
    _refreshTimer = Timer(_retryDelay, _performBackgroundRefresh);
    final doubled = _retryDelay * 2;
    _retryDelay = doubled > _maxRetryDelay ? _maxRetryDelay : doubled;
  }




  Future<String> _getVersion() async {
    try {
      final fileContent = await rootBundle.loadString(
        "packages/kinde_flutter_sdk/pubspec.yaml",
      );
      final pubspec = Pubspec.parse(fileContent);
      return pubspec.version?.canonicalizedVersion ?? '';
    } catch (exception) {
      return '';
    }
  }

  /// Returns a link to the self-serve portal for the authenticated user. The user can use this link to manage their account, update their profile, and view their entitlements.
  ///
  /// Throws [KindeError] if the request fails.
  ///
  /// Optional Parameters:
  ///
  /// [subnav] - The area of the portal you want the user to land on
  /// [returnUrl] - The URL to redirect the user to after they have completed their actions in the portal.
  /// [cancelToken] - A [CancelToken] that can be used to cancel the operation
  /// [headers] - Can be used to add additional headers to the request
  /// [extra] - Can be used to add flags to the request
  /// [validateStatus] - A [ValidateStatus] callback that can be used to determine request success based on the HTTP status of the response
  /// [onSendProgress] - A [ProgressCallback] that can be used to get the send progress
  /// [onReceiveProgress] - A [ProgressCallback] that can be used to get the receive progress
  Future<String> generatePortalUrl({
    PortalUrlSubnav? subnav,
    String? returnUrl,
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? extra,
    ValidateStatus? validateStatus,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    try {
      final selfServePortalApi = _kindeApi.getSelfServePortalApi();

      final response = await selfServePortalApi.generatePortalUrl(
        subnav: subnav?.value,
        returnUrl: returnUrl,
        cancelToken: cancelToken,
        headers: headers,
        extra: extra,
        validateStatus: validateStatus,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );

      final portalLink = response.data;

      final portalLinkUrl = portalLink?.url;

      if (portalLinkUrl == null) {
        throw KindeError(
          code: KindeErrorCode.portalLinkUrlIsNull.code,
          message: "Portal link URL is null",
        );
      }

      return portalLinkUrl;
    } catch (e, st) {
      throw KindeError.fromError(e, st);
    }
  }
}

@visibleForTesting
Future<KindeFlutterSDK> initializeKindeFlutterSdkForTest(
    {required String authDomain,
    required String authClientId,
    required String loginRedirectUri,
    required String logoutRedirectUri,
    List<String> scopes = KindeFlutterSDK._defaultScopes,
    String? audience,
    Dio? dio,
    String? Function()? currentUrl,
    void Function(String url)? replaceUrl}) async {
  return KindeFlutterSDK._initializeSDK(
      authDomain: authDomain,
      authClientId: authClientId,
      loginRedirectUri: loginRedirectUri,
      logoutRedirectUri: logoutRedirectUri,
      scopes: scopes,
      audience: audience,
      dio: dio,
      currentUrl: currentUrl,
      replaceUrl: replaceUrl);
}
