import 'dart:async';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:kinde_flutter_sdk/kinde_api.dart';
import 'package:kinde_flutter_sdk/src/additional_params.dart';
import 'package:kinde_flutter_sdk/src/kinde_secure_storage/kinde_secure_storage_i.dart';
import 'package:kinde_flutter_sdk/src/utils/helpers.dart';
import 'package:kinde_flutter_sdk/src/utils/kinde_debug_print.dart';
import 'package:kinde_flutter_sdk/src/kinde_secure_storage/kinde_secure_storage.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/base/web_oauth_flow.dart';

import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/code_verifier_generator.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/code_verifier_storage.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/cross_platform_support.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/pending_logins.dart';
import 'package:oauth2/oauth2.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KindeWeb {
  /// Creates a KindeWeb instance using hash URL strategy.
  ///
  /// [appBaseUrl] is the base URL of the application. If not provided,
  /// it will be extracted from the current URL, removing any hash fragments
  /// and trailing slashes.
  KindeWeb._();

  static KindeWeb? _instance;

  static KindeWeb get instance {
    if (_instance == null) {
      throw Exception("Did you forget to call the initialize() method?");
    }
    return _instance!;
  }

  late final PendingLogins _pendingLogins;

  static Future<void> initialize(
      {String? appBaseUrl,
      required KindeSecureStorageInterface secureStorage}) async {
    try {
      String? tempAppBaseUrl = appBaseUrl;

      if (urlStrategy?.runtimeType is HashUrlStrategy) {
        tempAppBaseUrl ??= Uri.base.toString().trim();
      } else {
        // Log when using fallback strategy
        if (urlStrategy == null) {
          kindeDebugPrint(
              methodName: 'KindeWeb.initialize',
              message:
                  '[Kinde] No urlStrategy detected. Defaulting to path strategy.');
        } else {
          kindeDebugPrint(
              methodName: 'KindeWeb.initialize',
              message:
                  '[Kinde] Using custom urlStrategy: ${urlStrategy.runtimeType}');
        }

        tempAppBaseUrl ??= Uri.base.origin;
      }

      // Check validity
      final isBaseUrlValid = isSafeWebUrl(tempAppBaseUrl);
      if (!isBaseUrlValid) {
        throw ArgumentError(
            'Invalid appBaseUrl: must be a valid HTTP/HTTPS URL');
      }

      kindeDebugPrint(
          methodName: 'KindeWeb.initialize',
          message: 'Successfully validated base URL: $tempAppBaseUrl');

      // Proceed
      _instance = KindeWeb._();
      _instance?._pendingLogins = PendingLogins(
          await SharedPreferences.getInstance(),
          legacyState: secureStorage,
          legacyCodeVerifier: await CodeVerifierStorage.initialize());
    } catch (e, st) {
      throw KindeError(
        code: KindeErrorCode.initializingFailed.code,
        message: e.toString(),
        stackTrace: st,
      );
    }
  }

  /// Logs the user out by clearing local session data and navigating to the provided logout URL.
  ///
  /// Throws:
  /// - [KindeError] with [KindeErrorCode.loginInProcess] if a login flow is currently in progress.
  /// - [KindeError] with [KindeErrorCode.invalidRedirect] if the provided logout URL is unsafe or untrusted.
  ///
  /// Parameters:
  /// - [logoutUrl]: The URL to navigate to after clearing session data. Must be a safe and trusted web URL.
  Future<void> logout(String logoutUrl) async {
    if (_loginInProgress) {
      throw KindeError(code: KindeErrorCode.loginInProcess.code);
    }
    if (!isSafeWebUrl(logoutUrl)) {
      throw KindeError(
          code: KindeErrorCode.invalidRedirect.code,
          message: 'Unsafe or untrusted logout URL detected');
    }
    WebUtils.replacePage(logoutUrl);
  }

  bool _loginInProgress = false;

  ///Starts the OAuth login flow. Only one login can be in progress at a time.
  ///Throws [KindeError] with [KindeErrorCode.loginInProcess] if a login is already in progress.
  Future<void> startLoginFlow(AuthorizationRequest configuration,
      {required InternalAdditionalParameters additionalParameters}) async {
    if (_loginInProgress) {
      throw KindeError(code: KindeErrorCode.loginInProcess.code);
    }
    _loginInProgress = true;
    final String codeVerifier = generateCodeVerifier();
    final String authState = generateAuthState();
    try {
      await _pendingLogins.add(authState, codeVerifier,
          orgCode: additionalParameters.orgCode);
      additionalParameters.state = authState;
      await WebOAuthFlow.login(
          configuration: configuration,
          additionalParameters: additionalParameters,
          codeVerifier: codeVerifier);
    } catch (e, st) {
      _loginInProgress = false;
      await _pendingLogins.remove(authState);
      throw e is KindeError ? e : KindeError.fromError(e, st);
    }
  }

  /// Returns null when [responseState] is not a login this browser started.
  Future<({Credentials credentials, String? orgCode})?> finishLoginFlow(
      {required String redirectUrl,
      required String responseUrl,
      required String responseState,
      required String clientId,
      required String authorizationEndpoint,
      required String tokenEndpoint,
      required List<String> scopes}) async {
    final pendingLogin = await _pendingLogins.take(responseState);
    if (pendingLogin == null) return null;

    final codeVerifier = pendingLogin.codeVerifier;
    if (codeVerifier == null) {
      throw KindeError(
          code: KindeErrorCode.noCodeVerifier.code,
          message: "No code verifier in storage.");
    }

    final authorizationCodeGrant = AuthorizationCodeGrant(
      clientId,
      Uri.parse(authorizationEndpoint),
      Uri.parse(tokenEndpoint),
      codeVerifier: codeVerifier,
      basicAuth: true,
    );

    try {
      final credentials = await WebOAuthFlow.finishLogin(
          authRequestState: responseState,
          responseUrl: responseUrl,
          authorizationCodeGrant: authorizationCodeGrant,
          redirectUrl: redirectUrl,
          scopes: scopes);
      if (credentials == null) return null;

      return (credentials: credentials, orgCode: pendingLogin.orgCode);
    } catch (e, st) {
      throw KindeError.fromError(e, st);
    }
  }
}
