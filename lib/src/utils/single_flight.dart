/// Shares one in-flight run of a task between concurrent callers.
class SingleFlight<T> {
  Future<T>? _inFlight;

  Future<T> run(Future<T> Function() task) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    late final Future<T> current;
    current = task().whenComplete(() {
      if (identical(_inFlight, current)) _inFlight = null;
    });
    return _inFlight = current;
  }

  /// Lets the next [run] start afresh while the current one finishes.
  void detach() => _inFlight = null;
}
