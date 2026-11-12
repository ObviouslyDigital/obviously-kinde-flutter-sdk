import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Runs [task] under the exclusive Web Lock [name], or unlocked if none is granted in [timeout].
Future<T> runWithCrossTabLock<T>(
  String name, {
  required Duration timeout,
  required Future<T> Function(bool locked) task,
}) async {
  final navigator = web.window.navigator;
  if (!navigator.has('locks')) return task(false);

  var granted = false;
  late T result;
  Object? failure;
  StackTrace? failureStack;
  try {
    await navigator.locks
        .request(
          name,
          web.LockOptions(
            mode: 'exclusive',
            signal: web.AbortSignal.timeout(timeout.inMilliseconds),
          ),
          ((JSAny? lock) {
            granted = true;
            return () async {
              try {
                result = await task(true);
              } catch (error, stack) {
                failure = error;
                failureStack = stack;
              }
            }()
                .toJS;
          }).toJS,
        )
        .toDart;
  } catch (_) {
    if (granted) rethrow;
    return task(false);
  }

  if (failure case final error?) Error.throwWithStackTrace(error, failureStack!);
  return result;
}
