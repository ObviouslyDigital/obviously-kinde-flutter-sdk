import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:kinde_flutter_sdk/kinde_flutter_sdk.dart';

const _authDomain = String.fromEnvironment('KINDE_DOMAIN',
    defaultValue: 'https://localhost:47443');

/// Exposes the SDK to Playwright as `window.kinde*` functions returning JSON.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final origin = Uri.base.origin;
  final sdk = await KindeFlutterSDK.initializeSDK(
    authDomain: _authDomain,
    authClientId: 'browser-test-client',
    loginRedirectUri: '$origin/',
    logoutRedirectUri: '$origin/',
  );

  final history = globalContext['history'] as JSObject;
  history.callMethod('replaceState'.toJS, {'kindeTestMarker': true}.jsify(),
      ''.toJS, Uri.base.toString().toJS);

  String? callbackError;
  try {
    await sdk.completePendingLoginIfNeeded();
  } on KindeError catch (error) {
    callbackError = error.code;
  }

  Map<String, Object?> state() {
    final authState = sdk.authState;
    return {
      'signedIn': authState?.accessToken != null,
      'org': authState == null ? null : sdk.getOrganization().orgCode,
      'refreshToken': authState?.refreshToken,
      'url': Uri.base.toString(),
      'historyState': history['state'].dartify(),
    };
  }

  JSPromise<JSString> run(Future<Map<String, Object?>> Function() action) =>
      () async {
        try {
          return jsonEncode({...await action(), ...state()});
        } on KindeError catch (error) {
          return jsonEncode({'error': error.code, ...state()});
        }
      }()
          .then((json) => json.toJS)
          .toJS;

  globalContext['kindeState'] = (() => jsonEncode(state()).toJS).toJS;
  globalContext['kindeGetToken'] = ((JSBoolean forceRefresh) => run(() async =>
      {'token': await sdk.getToken(forceRefresh: forceRefresh.toDart)})).toJS;
  globalContext['kindeLogin'] = ((JSString orgCode) => run(() async {
        await sdk.login(
            additionalParams: AdditionalParameters(
                orgCode: orgCode.toDart, prompt: KindePrompt.useSession));
        return {};
      })).toJS;
  globalContext['kindeLogout'] = (() => run(() async {
        await sdk.logout();
        return {};
      })).toJS;
  globalContext['kindeCallbackError'] = callbackError?.toJS;
  globalContext['kindeCompiler'] =
      (const bool.fromEnvironment('dart.tool.dart2wasm') ? 'dart2wasm' : 'dart2js')
          .toJS;
  globalContext['kindeReady'] = true.toJS;
}
