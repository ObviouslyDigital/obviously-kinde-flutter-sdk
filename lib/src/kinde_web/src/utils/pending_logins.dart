import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:kinde_flutter_sdk/src/kinde_secure_storage/kinde_secure_storage_i.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/code_verifier_storage.dart';
import 'package:kinde_flutter_sdk/src/kinde_web/src/utils/cross_tab_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef PendingLogin = ({String? codeVerifier, String? orgCode});

/// Web logins started in this browser and not yet completed, keyed by `state`.
class PendingLogins {
  PendingLogins(this._preferences,
      {required KindeSecureStorageInterface legacyState,
      required CodeVerifierStorage legacyCodeVerifier})
      : _legacyState = legacyState,
        _legacyCodeVerifier = legacyCodeVerifier;

  static const lifetime = Duration(hours: 24);
  static const _lockTimeout = Duration(seconds: 5);
  static const _keyPrefix = 'kinde_pending_login.';
  static const _codeVerifierField = 'codeVerifier';
  static const _orgCodeField = 'orgCode';
  static const _createdAtField = 'createdAt';

  final SharedPreferences _preferences;
  final KindeSecureStorageInterface _legacyState;
  final CodeVerifierStorage _legacyCodeVerifier;

  @visibleForTesting
  static String storageKey(String state) => '$_keyPrefix$state';

  Future<void> add(String state, String codeVerifier, {String? orgCode}) async {
    await _preferences.reload();
    await _pruneExpired();
    await _preferences.setString(
        storageKey(state),
        jsonEncode({
          _codeVerifierField: codeVerifier,
          if (orgCode != null) _orgCodeField: orgCode,
          _createdAtField: DateTime.now().millisecondsSinceEpoch,
        }));
  }

  Future<void> remove(String state) => _preferences.remove(storageKey(state));

  /// Removes and returns the login started with [state] at any age, or null.
  Future<PendingLogin?> take(String state) => runWithCrossTabLock(
      'kinde-login:$state',
      timeout: _lockTimeout,
      task: (_) => _take(state));

  Future<PendingLogin?> _take(String state) async {
    await _preferences.reload();
    final key = storageKey(state);
    final entry = _preferences.getString(key);
    if (entry != null) await _preferences.remove(key);
    await _pruneExpired();

    if (entry == null) return _takeLegacy(state);

    return (
      codeVerifier: _nonEmptyString(_field(entry, _codeVerifierField)),
      orgCode: _nonEmptyString(_field(entry, _orgCodeField)),
    );
  }

  Future<PendingLogin?> _takeLegacy(String state) async {
    final legacyState = await _legacyState.getAuthRequestState();
    if (legacyState == null) return null;

    final codeVerifier = _legacyCodeVerifier.restore();
    await _legacyState.removeAuthRequestState();
    await _legacyCodeVerifier.clear();
    if (legacyState != state) return null;

    return (codeVerifier: codeVerifier, orgCode: null);
  }

  Future<void> _pruneExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final key in _preferences.getKeys()) {
      if (!key.startsWith(_keyPrefix)) continue;

      final entry = _preferences.getString(key);
      final createdAt = entry == null ? null : _field(entry, _createdAtField);
      final expired =
          createdAt is! int || now - createdAt > lifetime.inMilliseconds;
      if (expired) await _preferences.remove(key);
    }
  }

  static String? _nonEmptyString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static Object? _field(String entry, String name) {
    try {
      final decoded = jsonDecode(entry);
      return decoded is Map ? decoded[name] : null;
    } on FormatException {
      return null;
    }
  }
}
