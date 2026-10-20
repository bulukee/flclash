import 'dart:async';

import 'package:fl_clash/services/salmon_delay_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finishes each visible node before starting the next', () async {
    final queue = SalmonDelayQueue();
    final first = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final pending = queue.run(
      ['first', 'second', 'third'],
      test: (node) async {
        calls.add(node);
        if (node == 'first') {
          started.complete();
          await first.future;
        }
      },
      shouldContinue: () => true,
    );
    await started.future;
    expect(calls, ['first']);
    first.complete();
    await pending;
    expect(calls, ['first', 'second', 'third']);
  });

  test('a second surface waits for the first surface to finish', () async {
    final queue = SalmonDelayQueue();
    final gate = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final first = queue.run(
      ['page-first', 'page-second'],
      test: (node) async {
        calls.add(node);
        if (node == 'page-first') {
          started.complete();
          await gate.future;
        }
      },
      shouldContinue: () => true,
    );
    await started.future;
    final second = queue.run(
      ['home-first', 'home-second'],
      test: (node) async => calls.add(node),
      shouldContinue: () => true,
    );
    expect(calls, ['page-first']);
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, ['page-first', 'page-second', 'home-first', 'home-second']);
  });

  test('logout or closing the page stops remaining nodes', () async {
    final queue = SalmonDelayQueue();
    var active = true;
    final calls = <int>[];
    await queue.run(
      [1, 2, 3],
      test: (node) async {
        calls.add(node);
        active = false;
      },
      shouldContinue: () => active,
    );
    expect(calls, [1]);
  });

  test('an obsolete queued request never starts', () async {
    final queue = SalmonDelayQueue();
    var calls = 0;
    await queue.run(
      [1, 2],
      test: (_) async => calls++,
      shouldContinue: () => false,
    );
    expect(calls, 0);
  });

  test('a failed run releases the queue for the next run', () async {
    final queue = SalmonDelayQueue();
    await expectLater(
      queue.run(
        [1],
        test: (_) async => throw StateError('disconnected'),
        shouldContinue: () => true,
      ),
      throwsStateError,
    );
    final calls = <int>[];
    await queue.run(
      [2, 3],
      test: (node) async => calls.add(node),
      shouldContinue: () => true,
    );
    expect(calls, [2, 3]);
  });
}
