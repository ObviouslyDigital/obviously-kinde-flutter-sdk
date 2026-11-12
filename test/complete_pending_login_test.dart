import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:kinde_flutter_sdk/kinde_flutter_sdk.dart';
import 'package:kinde_flutter_sdk/src/kinde_flutter_sdk.dart';
import 'package:kinde_flutter_sdk/src/kinde_secure_storage/kinde_secure_storage.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/kinde_web.dart';
import 'package:kinde_flutter_sdk/src/store/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mock_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const appUrl = 'https://pooled-eu.example.com/';
  const loginState = 'state-of-the-login-in-progress';
  const authStateKey = 'kinde_auth_state';
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const appAuthChannel = MethodChannel('crossingthestreams.io/flutter_appauth');
  final secureStorage = <String, String>{};
  final codeExchanges = <http.Request>[];
  final dio = Dio();
  late DioAdapter dioAdapter;
  Completer<void>? refreshGate;
  Completer<void>? authStateReadGate;
  Completer<void>? authStateReadStarted;
  var currentUrl = appUrl;

  KindeFlutterSDK sdk() => KindeFlutterSDK.instance;

  setUpAll(() async {
    mockChannels.setupMockChannel();
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'write':
          secureStorage[key!] = arguments['value'] as String;
          return null;
        case 'read':
          final value = secureStorage[key];
          final gate = authStateReadGate;
          if (key == authStateKey && gate != null) {
            authStateReadStarted?.complete();
            await gate.future;
          }
          return value;
        case 'delete':
          secureStorage.remove(key);
          return null;
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'containsKey':
          return secureStorage.containsKey(key);
        case 'readAll':
          return secureStorage;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(appAuthChannel, (call) async {
      return switch (call.method) {
        'authorizeAndExchangeCode' || 'token' => tokenResponseMap,
        'authorize' => authorizeResponse,
        'endSession' => <String, Object?>{'state': null},
        _ => null,
      };
    });

    dioAdapter = DioAdapter(dio: dio)
      ..onGet('/.well-known/jwks.json',
          (server) => server.reply(200, {'keys': []}))
      ..onGet('https://auth.example.com/logout',
          (server) => server.reply(200, null));
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path == '/oauth2/token') await refreshGate?.future;
      handler.next(options);
    }));

    await initializeKindeFlutterSdkForTest(
        authDomain: 'auth.example.com',
        authClientId: 'authClientId',
        loginRedirectUri: appUrl,
        logoutRedirectUri: appUrl,
        dio: dio,
        currentUrl: () => currentUrl);
    await KindeWeb.initialize(
        appBaseUrl: appUrl, secureStorage: KindeSecureStorage());
  });

  setUp(() async {
    codeExchanges.clear();
    secureStorage.clear();
    refreshGate = null;
    authStateReadGate = null;
    authStateReadStarted = null;
    currentUrl = appUrl;
    await sdk().login();
    secureStorage[SecureStorageKey.authRequestState] = loginState;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('codeVerifier', 'codeVerifierOfTheLogin');
  });

  Future<T> withTokenEndpoint<T>(Future<T> Function() body) =>
      http.runWithClient(
        body,
        () => MockClient((request) async {
          codeExchanges.add(request);
          return http.Response(
            jsonEncode({
              'access_token': 'switchedOrganisationAccessToken',
              'refresh_token': 'switchedOrganisationRefreshToken',
              'id_token': 'switchedOrganisationIdToken',
              'token_type': 'bearer',
              'expires_in': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  Future<bool> completePendingLoginAt(String url) {
    currentUrl = url;
    return withTokenEndpoint(sdk().completePendingLoginIfNeeded);
  }

  void replyToRefreshWithPreviousTokens() => dioAdapter.onPost(
        '/oauth2/token',
        (server) => server.reply(200, {
          'access_token': 'previousOrganisationAccessToken',
          'refresh_token': 'previousOrganisationRefreshToken',
          'expires_in': 3600,
        }),
        data: Matchers.any,
      );

  test(
      'exchanges a code whose state matches the login in progress while '
      'tokens are stored, replacing them', () async {
    expect(sdk().authState?.accessToken, 'accessToken');

    final completed =
        await completePendingLoginAt('$appUrl?code=switchCode&state=$loginState');

    expect(completed, isTrue);
    expect(codeExchanges, hasLength(1));
    expect(codeExchanges.single.url.toString(),
        'https://auth.example.com/oauth2/token');
    expect(codeExchanges.single.bodyFields, containsPair('code', 'switchCode'));
    expect(sdk().authState?.accessToken, 'switchedOrganisationAccessToken');
    expect(sdk().authState?.refreshToken, 'switchedOrganisationRefreshToken');
    expect(sdk().authState?.idToken, 'switchedOrganisationIdToken');
    expect(secureStorage[SecureStorageKey.authRequestState], isNull);
  });

  test('concurrent completions redeem the code once', () async {
    currentUrl = '$appUrl?code=switchCode&state=$loginState';

    final completions = await withTokenEndpoint(() => Future.wait([
          sdk().completePendingLoginIfNeeded(),
          sdk().completePendingLoginIfNeeded(),
        ]));

    expect(completions, [isTrue, isTrue]);
    expect(codeExchanges, hasLength(1));
    expect(sdk().authState?.accessToken, 'switchedOrganisationAccessToken');
  });

  test(
      'ignores a code whose state is not the login in progress, leaving that '
      'login in progress', () async {
    final completed = await completePendingLoginAt(
        '$appUrl?code=foreignCode&state=someOtherState');

    expect(completed, isFalse);
    expect(codeExchanges, isEmpty);
    expect(sdk().authState?.accessToken, 'accessToken');
    expect(secureStorage[SecureStorageKey.authRequestState], loginState);
  });

  test('ignores a code when no login is in progress', () async {
    secureStorage.remove(SecureStorageKey.authRequestState);

    final completed =
        await completePendingLoginAt('$appUrl?code=usedCode&state=$loginState');

    expect(completed, isFalse);
    expect(codeExchanges, isEmpty);
    expect(sdk().authState?.accessToken, 'accessToken');
  });

  test('ignores a URL without a state and either a code or an error',
      () async {
    for (final url in [
      appUrl,
      '$appUrl?code=onlyCode',
      '$appUrl?error=login_required',
      '$appUrl?state=$loginState',
    ]) {
      expect(await completePendingLoginAt(url), isFalse, reason: url);
    }

    expect(codeExchanges, isEmpty);
    expect(secureStorage[SecureStorageKey.authRequestState], loginState);
  });

  test(
      'throws the error of a response to the login in progress and ends that '
      'login', () async {
    await expectLater(
      completePendingLoginAt(
          '$appUrl?error=login_required&error_description=Sign+in&state=$loginState'),
      throwsA(isA<KindeError>()
          .having((error) => error.code, 'code', 'login_required')),
    );

    expect(codeExchanges, isEmpty);
    expect(secureStorage[SecureStorageKey.authRequestState], isNull);
    expect(sdk().authState?.accessToken, 'accessToken');
  });

  test('ignores an error whose state is not the login in progress', () async {
    final completed = await completePendingLoginAt(
        '$appUrl?error=login_required&state=someOtherState');

    expect(completed, isFalse);
    expect(secureStorage[SecureStorageKey.authRequestState], loginState);
  });

  test(
      'a refresh of the previous tokens that lands after the code exchange '
      'keeps the exchanged tokens', () async {
    refreshGate = Completer<void>();
    replyToRefreshWithPreviousTokens();
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await completePendingLoginAt('$appUrl?code=switchCode&state=$loginState');
    refreshGate!.complete();

    expect(await lateRefresh, 'switchedOrganisationAccessToken');
    expect(sdk().authState?.accessToken, 'switchedOrganisationAccessToken');
    expect(sdk().authState?.refreshToken, 'switchedOrganisationRefreshToken');
  });

  test(
      'a stored-state reload that resolves after the code exchange keeps the '
      'exchanged tokens', () async {
    final readGate = authStateReadGate = Completer<void>();
    final readStarted = authStateReadStarted = Completer<void>();
    final reload = Store.instance.reloadAuthState();
    await readStarted.future;
    authStateReadGate = null;

    await completePendingLoginAt('$appUrl?code=switchCode&state=$loginState');
    readGate.complete();
    await reload;

    expect(sdk().authState?.accessToken, 'switchedOrganisationAccessToken');
  });

  test('a refresh in flight during logout does not restore the session',
      () async {
    refreshGate = Completer<void>();
    replyToRefreshWithPreviousTokens();
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await sdk().logout(dio: dio);
    refreshGate!.complete();

    expect(await lateRefresh, isNull);
    expect(sdk().authState, isNull);
    await Store.instance.reloadAuthState();
    expect(sdk().authState, isNull);
  });
}
