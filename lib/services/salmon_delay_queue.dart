import 'dart:async';

/// Shares one queue between full-list tests and individual node tests.
class SalmonDelayQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run<T>(
    List<T> nodes, {
    required Future<void> Function(T node) test,
    required bool Function() shouldContinue,
  }) {
    final ordered = List<T>.of(nodes);
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return () async {
      await previous;
      try {
        for (final node in ordered) {
          if (!shouldContinue()) return;
          await test(node);
        }
      } finally {
        release.complete();
      }
    }();
  }
}
