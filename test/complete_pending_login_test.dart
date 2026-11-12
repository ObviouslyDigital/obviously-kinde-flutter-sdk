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
  final tokenRequests = <http.Request>[];

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
    DioAdapter(dio: dio).onGet(
        '/.well-known/jwks.json', (server) => server.reply(200, {'keys': []}));

    await initializeKindeFlutterSdkForTest(
        authDomain: 'auth.example.com',
        authClientId: 'authClientId',
        loginRedirectUri: appUrl,
        logoutRedirectUri: appUrl,
        dio: dio);
    await KindeWeb.initialize(
        appBaseUrl: appUrl, secureStorage: KindeSecureStorage());
  });

  setUp(() async {
    tokenRequests.clear();
    secureStorage.clear();
    await KindeFlutterSDK.instance.login();
    secureStorage[SecureStorageKey.authRequestState] = loginState;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('codeVerifier', 'codeVerifierOfTheLogin');
  });

  Future<bool> completeLoginFrom(String url) => http.runWithClient(
        () => KindeFlutterSDK.instance.completeLoginFromUrl(url),
        () => MockClient((request) async {
          tokenRequests.add(request);
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

  test(
      'exchanges the code of an organisation switch while tokens are stored, '
      'replacing them', () async {
    expect(KindeFlutterSDK.instance.authState?.accessToken, 'accessToken');

    final completed =
        await completeLoginFrom('$appUrl?code=switchCode&state=$loginState');

    expect(completed, isTrue);
    expect(tokenRequests, hasLength(1));
    expect(tokenRequests.single.url.toString(),
        'https://auth.example.com/oauth2/token');
    expect(tokenRequests.single.bodyFields, containsPair('code', 'switchCode'));
    final authState = KindeFlutterSDK.instance.authState;
    expect(authState?.accessToken, 'switchedOrganisationAccessToken');
    expect(authState?.refreshToken, 'switchedOrganisationRefreshToken');
    expect(authState?.idToken, 'switchedOrganisationIdToken');
    expect(secureStorage[SecureStorageKey.authRequestState], isNull);
  });

  test('never exchanges a code whose state is not the login in progress',
      () async {
    await expectLater(
      completeLoginFrom('$appUrl?code=foreignCode&state=someOtherState'),
      throwsA(isA<KindeError>()),
    );

    expect(tokenRequests, isEmpty);
    expect(KindeFlutterSDK.instance.authState?.accessToken, 'accessToken');
  });

  test('leaves a code from a finished login in the URL alone', () async {
    secureStorage.remove(SecureStorageKey.authRequestState);

    final completed =
        await completeLoginFrom('$appUrl?code=usedCode&state=$loginState');

    expect(completed, isFalse);
    expect(tokenRequests, isEmpty);
    expect(KindeFlutterSDK.instance.authState?.accessToken, 'accessToken');
  });

  test('does nothing without both a code and a state', () async {
    for (final url in [
      appUrl,
      '$appUrl?code=onlyCode',
      '$appUrl?state=$loginState',
    ]) {
      expect(await completeLoginFrom(url), isFalse, reason: url);
    }

    expect(tokenRequests, isEmpty);
  });
}
