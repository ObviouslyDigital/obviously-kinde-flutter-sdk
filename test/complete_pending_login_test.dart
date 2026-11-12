import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:kinde_flutter_sdk/kinde_flutter_sdk.dart';
import 'package:kinde_flutter_sdk/src/additional_params.dart';
import 'package:kinde_flutter_sdk/src/kinde_flutter_sdk.dart';
import 'package:kinde_flutter_sdk/src/kinde_secure_storage/kinde_secure_storage.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/kinde_web.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/pending_logins.dart';
import 'package:kinde_flutter_sdk/src/store/store.dart';
import 'package:kinde_flutter_sdk/src/token/auth_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mock_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const appUrl = 'https://pooled-eu.example.com/';
  const authStateKey = 'kinde_auth_state';
  const legacyCodeVerifierKey = 'codeVerifier';
  const switchedAccessToken = 'switchedOrganisationAccessToken';
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const appAuthChannel = MethodChannel('crossingthestreams.io/flutter_appauth');
  final pendingLoginPrefix = PendingLogins.storageKey('');
  final secureStorage = <String, String>{};
  final codeExchanges = <http.Request>[];
  final exchangedAccessTokens = <String, String>{};
  final replacedUrls = <String>[];
  final heldGates = <Completer<void>>[];
  final bearerTokens = <String?>[];
  var failAuthStateReads = false;
  final dio = Dio();
  late DioAdapter dioAdapter;
  late SharedPreferences preferences;
  var refreshRequests = 0;
  Completer<void>? refreshGate;
  Completer<void>? authStateReadGate;
  Completer<void>? authStateReadStarted;
  Completer<void>? authStateWriteGate;
  Completer<void>? authStateDeleteGate;
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
          if (key == authStateKey) await authStateWriteGate?.future;
          secureStorage[key!] = arguments['value'] as String;
          return null;
        case 'read':
          if (key == authStateKey && failAuthStateReads) {
            throw PlatformException(code: 'decrypt', message: 'cannot decrypt');
          }
          final value = secureStorage[key];
          final gate = authStateReadGate;
          if (key == authStateKey && gate != null) {
            authStateReadStarted?.complete();
            await gate.future;
          }
          return value;
        case 'delete':
          if (key == authStateKey) await authStateDeleteGate?.future;
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
      if (options.path == '/oauth2/token') {
        refreshRequests++;
        await refreshGate?.future;
      }
      handler.next(options);
    }));

    await initializeKindeFlutterSdkForTest(
        authDomain: 'auth.example.com',
        authClientId: 'authClientId',
        loginRedirectUri: appUrl,
        logoutRedirectUri: appUrl,
        dio: dio,
        currentUrl: () => currentUrl,
        replaceUrl: replacedUrls.add);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/oauth2/v2/user_profile') {
        bearerTokens.add(options.headers['Authorization'] as String?);
      }
      handler.next(options);
    }));
    dioAdapter.onGet('/oauth2/v2/user_profile', (server) => server.reply(200, {}));
    preferences = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    for (final gate in heldGates) {
      if (!gate.isCompleted) gate.complete();
    }
    heldGates.clear();
    failAuthStateReads = false;
    await Store.instance.flushWrites();
  });

  setUp(() async {
    codeExchanges.clear();
    exchangedAccessTokens.clear();
    replacedUrls.clear();
    bearerTokens.clear();
    secureStorage.clear();
    await preferences.clear();
    refreshRequests = 0;
    refreshGate = null;
    authStateReadGate = null;
    authStateReadStarted = null;
    authStateWriteGate = null;
    authStateDeleteGate = null;
    currentUrl = appUrl;
    await KindeWeb.initialize(
        appBaseUrl: appUrl, secureStorage: KindeSecureStorage());
    await sdk().login();
    await Store.instance.flushWrites();
  });

  Completer<void> hold() {
    final gate = Completer<void>();
    heldGates.add(gate);
    return gate;
  }

  String unsignedJwt(
      {Duration expiresIn = const Duration(hours: 1), String? orgCode}) {
    String encode(Map<String, Object> part) =>
        base64Url.encode(utf8.encode(jsonEncode(part))).replaceAll('=', '');
    final exp =
        DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
    final claims = {'exp': exp, if (orgCode != null) 'org_code': orgCode};
    return '${encode({'alg': 'none'})}.${encode(claims)}.signature';
  }

  Future<Set<String>> pendingStates() async {
    await preferences.reload();
    return {
      for (final key in preferences.getKeys())
        if (key.startsWith(pendingLoginPrefix))
          key.substring(pendingLoginPrefix.length),
    };
  }

  String pendingCodeVerifier(String state) => (jsonDecode(
          preferences.getString(PendingLogins.storageKey(state))!)
      as Map<String, dynamic>)['codeVerifier'] as String;

  Future<void> ageLogin(String state, Duration age) => preferences.setString(
      PendingLogins.storageKey(state),
      jsonEncode({
        'codeVerifier': pendingCodeVerifier(state),
        'createdAt': DateTime.now().subtract(age).millisecondsSinceEpoch,
      }));

  /// Starts a web login as a newly opened tab would and returns its `state`.
  Future<void> startLoginInThisTab({String? orgCode}) =>
      KindeWeb.instance.startLoginFlow(
        AuthorizationRequest('authClientId', appUrl,
            serviceConfiguration: const AuthorizationServiceConfiguration(
                authorizationEndpoint: 'https://auth.example.com/oauth2/auth',
                tokenEndpoint: 'https://auth.example.com/oauth2/token')),
        additionalParameters: InternalAdditionalParameters(orgCode: orgCode),
      );

  /// Starts a web login as a newly opened tab would and returns its `state`.
  Future<String> startLoginInNewTab({String? orgCode}) async {
    await KindeWeb.initialize(
        appBaseUrl: appUrl, secureStorage: KindeSecureStorage());
    final before = await pendingStates();
    await startLoginInThisTab(orgCode: orgCode);
    return (await pendingStates()).difference(before).single;
  }

  Future<T> withTokenEndpoint<T>(Future<T> Function() body) =>
      http.runWithClient(
        body,
        () => MockClient((request) async {
          codeExchanges.add(request);
          final code = request.bodyFields['code'];
          return http.Response(
            jsonEncode({
              'access_token': exchangedAccessTokens[code] ?? switchedAccessToken,
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

  void replyToRefresh(int status, Map<String, dynamic> body) =>
      dioAdapter.onPost(
        '/oauth2/token',
        (server) => server.reply(status, body),
        data: Matchers.any,
      );

  void replyToRefreshWithPreviousTokens() => replyToRefresh(200, {
        'access_token': 'previousOrganisationAccessToken',
        'refresh_token': 'previousOrganisationRefreshToken',
        'expires_in': 3600,
      });

  Future<void> storeTokensFromAnotherTab(
      {required String accessToken, required String refreshToken}) async {
    await Store.instance.flushWrites();
    secureStorage[authStateKey] = jsonEncode(AuthState(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpirationDateTime:
          DateTime.now().add(const Duration(hours: 1)),
    ).toJson());
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
      'exchanges a code whose state matches a login in progress while tokens '
      'are stored, replacing them', () async {
    final state = await startLoginInNewTab();
    final codeVerifier = pendingCodeVerifier(state);
    expect(sdk().authState?.accessToken, 'accessToken');

    final completed =
        await completePendingLoginAt('$appUrl?code=switchCode&state=$state');

    expect(completed, isTrue);
    expect(codeExchanges, hasLength(1));
    expect(codeExchanges.single.url.toString(),
        'https://auth.example.com/oauth2/token');
    expect(codeExchanges.single.bodyFields,
        allOf(containsPair('code', 'switchCode'),
            containsPair('code_verifier', codeVerifier)));
    expect(sdk().authState?.accessToken, switchedAccessToken);
    expect(sdk().authState?.refreshToken, 'switchedOrganisationRefreshToken');
    expect(sdk().authState?.idToken, 'switchedOrganisationIdToken');
    expect(await pendingStates(), isEmpty);
  });

  test('logins started in two tabs each complete with their own verifier',
      () async {
    final firstTab = await startLoginInNewTab();
    final secondTab = await startLoginInNewTab();
    final firstVerifier = pendingCodeVerifier(firstTab);
    final secondVerifier = pendingCodeVerifier(secondTab);

    final secondCompleted =
        await completePendingLoginAt('$appUrl?code=second&state=$secondTab');
    final firstCompleted =
        await completePendingLoginAt('$appUrl?code=first&state=$firstTab');

    expect([secondCompleted, firstCompleted], [isTrue, isTrue]);
    expect(codeExchanges.map((request) => request.bodyFields['code_verifier']),
        [secondVerifier, firstVerifier]);
    expect(await pendingStates(), isEmpty);
  });

  test('concurrent completions redeem the code once', () async {
    final state = await startLoginInNewTab();
    currentUrl = '$appUrl?code=switchCode&state=$state';

    final completions = await withTokenEndpoint(() => Future.wait([
          sdk().completePendingLoginIfNeeded(),
          sdk().completePendingLoginIfNeeded(),
        ]));

    expect(completions, [isTrue, isTrue]);
    expect(codeExchanges, hasLength(1));
    expect(sdk().authState?.accessToken, switchedAccessToken);
  });

  test(
      'ignores a code whose state is not a login in progress, leaving the '
      'logins in progress', () async {
    final state = await startLoginInNewTab();

    final completed = await completePendingLoginAt(
        '$appUrl?code=foreignCode&state=someOtherState');

    expect(completed, isFalse);
    expect(codeExchanges, isEmpty);
    expect(sdk().authState?.accessToken, 'accessToken');
    expect(await pendingStates(), {state});
  });

  test('ignores a code when no login is in progress', () async {
    final completed =
        await completePendingLoginAt('$appUrl?code=usedCode&state=anyState');

    expect(completed, isFalse);
    expect(codeExchanges, isEmpty);
    expect(sdk().authState?.accessToken, 'accessToken');
  });

  test('ignores a URL without a state and either a code or an error',
      () async {
    final state = await startLoginInNewTab();
    for (final url in [
      appUrl,
      '$appUrl?code=onlyCode',
      '$appUrl?error=login_required',
      '$appUrl?state=$state',
    ]) {
      expect(await completePendingLoginAt(url), isFalse, reason: url);
    }

    expect(codeExchanges, isEmpty);
    expect(await pendingStates(), {state});
  });

  test('a login completing after 11 minutes still exchanges its code',
      () async {
    final state = await startLoginInNewTab();
    await ageLogin(state, const Duration(minutes: 11));

    final completed =
        await completePendingLoginAt('$appUrl?code=slowCode&state=$state');

    expect(completed, isTrue);
    expect(codeExchanges, hasLength(1));
    expect(sdk().authState?.accessToken, switchedAccessToken);
  });

  test('prunes other logins started more than a day ago on completion',
      () async {
    final abandoned = await startLoginInNewTab();
    final recent = await startLoginInNewTab();
    final current = await startLoginInNewTab();
    await ageLogin(abandoned, const Duration(hours: 25));

    await completePendingLoginAt('$appUrl?code=switchCode&state=$current');

    expect(await pendingStates(), {recent});
  });

  test('completes a login started before per-state logins once', () async {
    secureStorage[SecureStorageKey.authRequestState] = 'legacyState';
    await preferences.setString(legacyCodeVerifierKey, 'legacyCodeVerifier');
    const url = '$appUrl?code=legacyCode&state=legacyState';

    expect(await completePendingLoginAt(url), isTrue);
    expect(await completePendingLoginAt(url), isFalse);

    expect(codeExchanges, hasLength(1));
    expect(codeExchanges.single.bodyFields,
        containsPair('code_verifier', 'legacyCodeVerifier'));
    expect(secureStorage[SecureStorageKey.authRequestState], isNull);
    expect(preferences.getString(legacyCodeVerifierKey), isNull);
  });

  test(
      'throws once for a login in progress whose code verifier is lost, then '
      'ignores the URL', () async {
    secureStorage[SecureStorageKey.authRequestState] = 'legacyState';
    const url = '$appUrl?code=legacyCode&state=legacyState';

    await expectLater(
      completePendingLoginAt(url),
      throwsA(isA<KindeError>().having(
          (error) => error.code, 'code', KindeErrorCode.noCodeVerifier.code)),
    );
    expect(await completePendingLoginAt(url), isFalse);

    expect(codeExchanges, isEmpty);
  });

  test(
      'throws the error of a response to a login in progress and ends that '
      'login', () async {
    final state = await startLoginInNewTab();

    await expectLater(
      completePendingLoginAt(
          '$appUrl?error=login_required&error_description=Sign+in&state=$state'),
      throwsA(isA<KindeError>()
          .having((error) => error.code, 'code', 'login_required')),
    );

    expect(codeExchanges, isEmpty);
    expect(await pendingStates(), isEmpty);
    expect(sdk().authState?.accessToken, 'accessToken');
  });

  test('ignores an error whose state is not a login in progress', () async {
    final state = await startLoginInNewTab();

    final completed = await completePendingLoginAt(
        '$appUrl?error=login_required&state=someOtherState');

    expect(completed, isFalse);
    expect(await pendingStates(), {state});
  });

  test(
      'a refresh of the previous tokens that lands after the code exchange '
      'keeps the exchanged tokens', () async {
    final state = await startLoginInNewTab();
    refreshGate = hold();
    replyToRefreshWithPreviousTokens();
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await completePendingLoginAt('$appUrl?code=switchCode&state=$state');
    refreshGate!.complete();

    expect(await lateRefresh, switchedAccessToken);
    expect(sdk().authState?.accessToken, switchedAccessToken);
    expect(sdk().authState?.refreshToken, 'switchedOrganisationRefreshToken');
  });

  test(
      'a rejected refresh after another tab rotated the tokens returns the '
      'new tokens', () async {
    refreshGate = hold();
    replyToRefresh(400, {'error': 'invalid_grant'});
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await storeTokensFromAnotherTab(
        accessToken: 'otherTabAccessToken', refreshToken: 'rotatedRefreshToken');
    refreshGate!.complete();

    expect(await lateRefresh, 'otherTabAccessToken');
    expect(sdk().authState?.refreshToken, 'rotatedRefreshToken');
  });

  test(
      'a rejected refresh token surfaces while the stored tokens still carry '
      'it', () async {
    refreshGate = hold();
    replyToRefresh(400, {'error': 'invalid_grant'});
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await storeTokensFromAnotherTab(
        accessToken: 'otherTabAccessToken', refreshToken: 'refreshToken');
    refreshGate!.complete();

    await expectLater(
      lateRefresh,
      throwsA(isA<KindeError>().having((error) => error.code, 'code',
          KindeErrorCode.refreshTokenExpired.code)),
    );
  });

  test(
      'a stored-state reload that resolves after the code exchange keeps the '
      'exchanged tokens', () async {
    final state = await startLoginInNewTab();
    final readGate = authStateReadGate = hold();
    final readStarted = authStateReadStarted = Completer<void>();
    final reload = Store.instance.reloadAuthState();
    await readStarted.future;
    authStateReadGate = null;

    final completing =
        completePendingLoginAt('$appUrl?code=switchCode&state=$state');
    await pumpEventQueue();
    readGate.complete();
    await Future.wait([reload, completing]);

    expect(sdk().authState?.accessToken, switchedAccessToken);
  });

  test('a reload waiting on a write keeps a sign-in queued behind it',
      () async {
    final writeGate = authStateWriteGate = hold();
    Store.instance.authState = const AuthState(accessToken: 'firstSignIn');
    final reload = Store.instance.reloadAuthState();
    Store.instance.authState = const AuthState(accessToken: 'secondSignIn');
    writeGate.complete();
    await reload;

    expect(sdk().authState?.accessToken, 'secondSignIn');
  });

  test('a clear while a reload waits on a write stays signed out', () async {
    final writeGate = authStateWriteGate = hold();
    final deleteGate = authStateDeleteGate = hold();
    Store.instance.authState = const AuthState(accessToken: 'signedIn');
    final reload = Store.instance.reloadAuthState();
    final clearing = Store.instance.clear();
    writeGate.complete();
    await reload;

    expect(sdk().authState, isNull);
    deleteGate.complete();
    await clearing;
    expect(sdk().authState, isNull);
  });

  test(
      'tokens another tab stored during a refresh make that refresh stale',
      () async {
    refreshGate = hold();
    replyToRefreshWithPreviousTokens();
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await storeTokensFromAnotherTab(
        accessToken: 'otherTabAccessToken', refreshToken: 'otherTabRefreshToken');
    refreshGate!.complete();

    expect(await lateRefresh, 'otherTabAccessToken');
    expect(sdk().authState?.refreshToken, 'otherTabRefreshToken');
  });

  test('a refresh superseded by logout throws a signed-out error', () async {
    refreshGate = hold();
    replyToRefreshWithPreviousTokens();
    final lateRefresh = sdk().getToken(forceRefresh: true);
    await pumpEventQueue();

    await sdk().logout(dio: dio);
    refreshGate!.complete();

    await expectLater(
      lateRefresh,
      throwsA(isA<KindeError>().having((error) => error.code, 'code',
          KindeErrorCode.sessionExpiredOrInvalid.code)),
    );
    expect(sdk().authState, isNull);
    await Store.instance.reloadAuthState();
    expect(sdk().authState, isNull);
  });

  test(
      'throws and keeps the stored session when the token is for another '
      'organisation than the one requested', () async {
    final state = await startLoginInNewTab(orgCode: 'org_meridian');
    exchangedAccessTokens['wrongOrg'] = unsignedJwt(orgCode: 'org_pool');

    await expectLater(
      completePendingLoginAt('$appUrl?code=wrongOrg&state=$state'),
      throwsA(isA<KindeError>().having((error) => error.code, 'code',
          KindeErrorCode.organizationMismatch.code)),
    );

    expect(sdk().authState?.accessToken, 'accessToken');
    expect(await pendingStates(), isEmpty);
  });

  test('stores the token of the organisation that was requested', () async {
    final state = await startLoginInNewTab(orgCode: 'org_meridian');
    final meridianToken = unsignedJwt(orgCode: 'org_meridian');
    exchangedAccessTokens['meridian'] = meridianToken;

    expect(
        await completePendingLoginAt('$appUrl?code=meridian&state=$state'),
        isTrue);

    expect(sdk().authState?.accessToken, meridianToken);
  });

  test(
      'removes the authorisation response from the browser URL whenever one '
      'is present, keeping other parameters', () async {
    final completedState = await startLoginInNewTab();
    final failedState = await startLoginInNewTab();

    await completePendingLoginAt('$appUrl?code=switchCode&state=$completedState'
        '&iss=https%3A%2F%2Fauth.example.com&tab=1#/home');
    await expectLater(
      completePendingLoginAt('$appUrl?error=login_required'
          '&error_description=x&error_uri=y&state=$failedState'),
      throwsA(isA<KindeError>()),
    );
    await completePendingLoginAt(
        '$appUrl?code=foreign&state=unknownState&session_state=s');
    await completePendingLoginAt('$appUrl?tab=1');

    expect(replacedUrls, ['$appUrl?tab=1#/home', appUrl, appUrl]);
  });

  test(
      'keeps repeated and encoded parameters when removing the authorisation '
      'response', () async {
    await completePendingLoginAt(
        '$appUrl?tab=1&code=c&tab=2&q=a%20b%26c&state=unknownState');

    expect(Uri.parse(replacedUrls.single).queryParametersAll, {
      'tab': ['1', '2'],
      'q': ['a b&c'],
    });
  });

  test('completing a login waits until the new tokens are in storage',
      () async {
    final state = await startLoginInNewTab();
    final writeGate = authStateWriteGate = hold();
    var completed = false;

    final completing =
        completePendingLoginAt('$appUrl?code=switchCode&state=$state')
            .whenComplete(() => completed = true);
    await pumpEventQueue();
    expect(completed, isFalse);
    writeGate.complete();

    expect(await completing, isTrue);
    expect(secureStorage[authStateKey], contains(switchedAccessToken));
  });

  test("a reload that adopts another tab's tokens sends them as the bearer",
      () async {
    await storeTokensFromAnotherTab(
        accessToken: unsignedJwt(), refreshToken: 'otherTabRefreshToken');

    final token = await sdk().getToken();
    try {
      await sdk().getUserProfileV2();
    } catch (_) {}

    expect(bearerTokens, ['Bearer $token']);
  });

  test('a second login in a tab that is already leaving for Kinde is refused',
      () async {
    await startLoginInNewTab();

    await expectLater(
      startLoginInThisTab(),
      throwsA(isA<KindeError>().having(
          (error) => error.code, 'code', KindeErrorCode.loginInProcess.code)),
    );
  });

  test(
      'a tab restored from the back/forward cache can sign in again and keeps its earlier login',
      () async {
    late void Function() restorePage;
    await KindeWeb.initialize(
        appBaseUrl: appUrl,
        secureStorage: KindeSecureStorage(),
        listenForPageRestore: (onRestore) => restorePage = onRestore);
    final before = await pendingStates();
    await startLoginInThisTab();
    final abandoned = (await pendingStates()).difference(before).single;

    restorePage();
    await startLoginInThisTab();

    final started = (await pendingStates()).difference(before);
    expect(started, hasLength(2));
    expect(
        await completePendingLoginAt('$appUrl?code=late&state=$abandoned'),
        isTrue);
  });

  test(
      'a stored session that cannot be read after an upgrade starts signed '
      'out and can sign in again', () async {
    failAuthStateReads = true;

    await Store.instance.loadFromStorage();
    expect(sdk().authState, isNull);
    await expectLater(
      sdk().getToken(),
      throwsA(isA<KindeError>().having((error) => error.code, 'code',
          KindeErrorCode.sessionExpiredOrInvalid.code)),
    );

    failAuthStateReads = false;
    await sdk().login();
    expect(sdk().authState?.accessToken, 'accessToken');
  });

  test('a storage read that fails keeps the session', () async {
    failAuthStateReads = true;

    await Store.instance.reloadAuthState();

    expect(sdk().authState?.accessToken, 'accessToken');
  });

  test('removes a login left in the single slot after one unmatched look',
      () async {
    secureStorage[SecureStorageKey.authRequestState] = 'legacyState';
    await preferences.setString(legacyCodeVerifierKey, 'legacyCodeVerifier');

    expect(
        await completePendingLoginAt('$appUrl?code=other&state=otherState'),
        isFalse);

    expect(secureStorage[SecureStorageKey.authRequestState], isNull);
    expect(preferences.getString(legacyCodeVerifierKey), isNull);
    expect(
        await completePendingLoginAt(
            '$appUrl?code=legacyCode&state=legacyState'),
        isFalse);
    expect(codeExchanges, isEmpty);
  });

  test(
      'a background refresh rejected after another tab rotated the tokens '
      'still schedules the next one', () async {
    final state = await startLoginInNewTab();
    exchangedAccessTokens['shortLived'] =
        unsignedJwt(expiresIn: const Duration(seconds: 11));
    final gate = refreshGate = hold();
    replyToRefresh(400, {'error': 'invalid_grant'});

    await completePendingLoginAt('$appUrl?code=shortLived&state=$state');
    await waitFor(() => refreshRequests == 1);
    expect(refreshRequests, 1, reason: 'the first background refresh');

    await storeTokensFromAnotherTab(
        accessToken: unsignedJwt(expiresIn: const Duration(seconds: 11)),
        refreshToken: 'rotatedRefreshToken');
    gate.complete();
    await waitFor(() => refreshRequests == 2);

    expect(refreshRequests, 2, reason: 'the next background refresh');
    expect(sdk().authState?.refreshToken, 'rotatedRefreshToken');
    await sdk().logout(dio: dio);
  });

  test('a superseded background refresh still schedules the next one',
      () async {
    final state = await startLoginInNewTab();
    exchangedAccessTokens['shortLived'] =
        unsignedJwt(expiresIn: const Duration(seconds: 11));
    final gate = refreshGate = hold();
    replyToRefreshWithPreviousTokens();

    await completePendingLoginAt('$appUrl?code=shortLived&state=$state');
    await waitFor(() => refreshRequests == 1);
    expect(refreshRequests, 1, reason: 'the first background refresh');

    await storeTokensFromAnotherTab(
        accessToken: unsignedJwt(expiresIn: const Duration(seconds: 11)),
        refreshToken: 'otherTabRefreshToken');
    gate.complete();
    await waitFor(() => refreshRequests == 2);

    expect(refreshRequests, 2, reason: 'the next background refresh');
    await sdk().logout(dio: dio);
  });

  test('a background refresh that fails with a server error retries later',
      () async {
    final state = await startLoginInNewTab();
    exchangedAccessTokens['shortLived'] =
        unsignedJwt(expiresIn: const Duration(seconds: 11));
    replyToRefresh(503, {'error': 'unavailable'});

    await completePendingLoginAt('$appUrl?code=shortLived&state=$state');
    await waitFor(() => refreshRequests == 1);
    expect(refreshRequests, 1, reason: 'the first background refresh');
    await waitFor(() => refreshRequests == 2);

    expect(refreshRequests, 2, reason: 'the retry after the backoff');
    await sdk().logout(dio: dio);
  });

  test(
      "adopting another tab's nearly expired tokens waits before refreshing "
      'again', () async {
    final state = await startLoginInNewTab();
    exchangedAccessTokens['shortLived'] =
        unsignedJwt(expiresIn: const Duration(seconds: 11));
    final gate = refreshGate = hold();
    replyToRefreshWithPreviousTokens();

    await completePendingLoginAt('$appUrl?code=shortLived&state=$state');
    await waitFor(() => refreshRequests == 1);
    await storeTokensFromAnotherTab(
        accessToken: unsignedJwt(expiresIn: const Duration(seconds: 2)),
        refreshToken: 'otherTabRefreshToken');
    final adoptedAt = DateTime.now();
    gate.complete();
    await waitFor(() => refreshRequests == 2);

    expect(refreshRequests, 2);
    expect(DateTime.now().difference(adoptedAt),
        greaterThanOrEqualTo(const Duration(seconds: 4)));
    await sdk().logout(dio: dio);
  });
}
