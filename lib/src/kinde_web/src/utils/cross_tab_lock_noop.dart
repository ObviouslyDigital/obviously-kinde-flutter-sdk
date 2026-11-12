/// Runs [task] unlocked: outside a browser there are no tabs to coordinate.
Future<T> runWithCrossTabLock<T>(
  String name, {
  required Duration timeout,
  required Future<T> Function(bool locked) task,
}) =>
    task(false);
