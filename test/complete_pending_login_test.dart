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
import 'package:shared_preferences/shared_preferences.dart';

import 'mock_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const appUrl = 'https://pooled-eu.example.com/';
  const loginState = 'state-of-the-login-in-progress';
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStorage = <String, String>{};
  final codeExchanges = <http.Request>[];
  late DioAdapter refreshAdapter;
  Completer<void>? refreshGate;
  var currentUrl = appUrl;

  KindeFlutterSDK sdk() => KindeFlutterSDK.instance;

  setUpAll(() async {
    mockChannels.setupMockChannel();
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'write':
          secureStorage[key!] = arguments['value'] as String;
          return null;
        case 'read':
          return secureStorage[key];
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

    final dio = Dio();
    refreshAdapter = DioAdapter(dio: dio)
      ..onGet('/.well-known/jwks.json',
          (server) => server.reply(200, {'keys': []}));
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
        dio: dio);
    await KindeWeb.initialize(
        appBaseUrl: appUrl, secureStorage: KindeSecureStorage());
    sdk().currentWebUrlOverride = () => currentUrl;
  });

  setUp(() async {
    codeExchanges.clear();
    secureStorage.clear();
    refreshGate = null;
    currentUrl = appUrl;
    await sdk().login();
    secureStorage[SecureStorageKey.authRequestState] = loginState;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('codeVerifier', 'codeVerifierOfTheLogin');
  });

  Future<bool> completePendingLoginAt(String url) {
    currentUrl = url;
    return http.runWithClient(
      sdk().completePendingLoginIfNeeded,
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
  }

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
    refreshAdapter.onPost(
      '/oauth2/token',
      (server) => server.reply(200, {
        'access_token': 'previousOrganisationAccessToken',
        'refresh_token': 'previousOrganisationRefreshToken',
        'expires_in': 3600,
      }),
      data: Matchers.any,
    );
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await completePendingLoginAt('$appUrl?code=switchCode&state=$loginState');
    refreshGate!.complete();

    expect(await lateRefresh, 'switchedOrganisationAccessToken');
    expect(sdk().authState?.accessToken, 'switchedOrganisationAccessToken');
    expect(sdk().authState?.refreshToken, 'switchedOrganisationRefreshToken');
  });
}
