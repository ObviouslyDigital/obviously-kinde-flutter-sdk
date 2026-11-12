import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kinde_flutter_sdk/src/keys/keys.dart';
import 'package:kinde_flutter_sdk/src/token/auth_state.dart';
import 'package:kinde_flutter_sdk/src/utils/kinde_debug_print.dart';

class Store {
  static const String _authStateKey = 'kinde_auth_state';
  static const String _keysKey = 'kinde_keys';

  static Store? _instance;

  late final FlutterSecureStorage _storage;

  Store._internal();

  static Store get instance {
    return _instance ??= Store._internal();
  }

  static Future<void> init() async {
    _instance = Store._internal();
    _instance!._storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
      ),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
      ),
      webOptions: WebOptions(
        dbName: 'kinde_secure_storage',
        publicKey: 'kinde_public_key',
      ),
    );
  }

  AuthState? get authState {
    // This is now async, but we'll handle it synchronously by caching
    // The actual async read happens in _readAuthState
    return _cachedAuthState;
  }

  /// Moves on every auth state replacement, marking older reads as stale.
  int get authStateGeneration => _authStateGeneration;
  int _authStateGeneration = 0;

  set authState(AuthState? value) {
    _authStateGeneration++;
    _cachedAuthState = value;
    _writes = _writes.then((_) => _writeAuthState(value));
  }

  Keys? get keys {
    // This is now async, but we'll handle it synchronously by caching
    return _cachedKeys;
  }

  set keys(Keys? value) {
    _cachedKeys = value;
    _writes = _writes.then((_) => _writeKeys(value));
  }

  // Cache to support synchronous getters
  AuthState? _cachedAuthState;
  Future<void> _writes = Future.value();
  Keys? _cachedKeys;

  // Load cached values from storage
  Future<void> loadFromStorage() async {
    _cachedAuthState = await _readAuthState();
    await _readKeys();
  }

  /// Waits for this instance's pending writes, so a reload never reads the
  /// value from before them.
  Future<void> reloadAuthState() async {
    await _writes;
    final generation = _authStateGeneration;
    final stored = await _readAuthState();
    if (generation != _authStateGeneration) return;

    if (!_isSameAuthState(stored, _cachedAuthState)) _authStateGeneration++;
    _cachedAuthState = stored;
  }

  static bool _isSameAuthState(AuthState? a, AuthState? b) =>
      jsonEncode(a?.toJson()) == jsonEncode(b?.toJson());

  Future<AuthState?> _readAuthState() async {
    try {
      final currentData = await _storage.read(key: _authStateKey);
      if (currentData == null || currentData.toLowerCase() == "null") {
        return null;
      }
      return AuthState.fromJson(
        jsonDecode(currentData) as Map<String, dynamic>,
      );
    } catch (e) {
      kindeDebugPrint(
        methodName: "Store._readAuthState",
        message: "Error reading auth state: $e",
      );
      return null;
    }
  }

  Future<void> _writeAuthState(AuthState? value) async {
    try {
      final json = jsonEncode(value?.toJson());
      await _storage.write(key: _authStateKey, value: json);
    } catch (e) {
      kindeDebugPrint(
        methodName: "Store._writeAuthState",
        message: "Error writing auth state: $e",
      );
    }
  }

  Future<void> _readKeys() async {
    try {
      final currentData = await _storage.read(key: _keysKey);
      if (currentData == null || currentData.toLowerCase() == "null") {
        _cachedKeys = null;
      } else {
        _cachedKeys = Keys.fromJson(jsonDecode(currentData) as Map<String, dynamic>);
      }
    } catch (e) {
      kindeDebugPrint(
        methodName: "Store._readKeys",
        message: "Error reading keys: $e",
      );
      _cachedKeys = null;
    }
  }

  Future<void> _writeKeys(Keys? value) async {
    try {
      final json = jsonEncode(value?.toJson());
      await _storage.write(key: _keysKey, value: json);
    } catch (e) {
      kindeDebugPrint(
        methodName: "Store._writeKeys",
        message: "Error writing keys: $e",
      );
    }
  }

  /// Clears memory at once; deletes run after all pending writes.
  Future<void> clear() async {
    _authStateGeneration++;
    _cachedAuthState = null;
    _cachedKeys = null;
    final deletes = _writes.then((_) async {
      await _storage.delete(key: _authStateKey);
      await _storage.delete(key: _keysKey);
    });
    _writes = deletes.catchError((_) {});
    try {
      await deletes;
    } catch (e) {
      kindeDebugPrint(
        methodName: "Store.clear",
        message: "Error clearing store: $e",
      );
    }
  }
}
