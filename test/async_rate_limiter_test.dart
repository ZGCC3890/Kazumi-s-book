import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/async_rate_limiter.dart';

void main() {
  group('AsyncRateLimiter', () {
    test('first acquire does not schedule an unnecessary timer', () async {
      final limiter = AsyncRateLimiter(const Duration(milliseconds: 50));
      var scheduledTimers = 0;
      await runZoned(
        limiter.acquire,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            scheduledTimers++;
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );

      expect(scheduledTimers, 0);
    });

    test(
      'sequential calls do not complete before their reserved time slots',
      () async {
        const period = Duration(milliseconds: 40);
        final limiter = AsyncRateLimiter(period);

        final timestamps = <int>[];
        final stopwatch = Stopwatch()..start();

        for (var i = 0; i < 3; i++) {
          await limiter.acquire();
          timestamps.add(stopwatch.elapsedMilliseconds);
        }

        expect(timestamps.length, 3);
        for (var i = 1; i < timestamps.length; i++) {
          // A delayed continuation can shorten the observed gap between completions.
          // Each reserved slot still has to wait until its own earliest deadline.
          expect(
            timestamps[i],
            greaterThanOrEqualTo(period.inMilliseconds * i - 5),
          );
        }
      },
    );

    test(
      'concurrent callers do not complete before their reserved time slots',
      () async {
        const period = Duration(milliseconds: 40);
        final limiter = AsyncRateLimiter(period);

        final completionTimes = <int>[];
        final stopwatch = Stopwatch()..start();

        await Future.wait(
          List.generate(4, (index) async {
            await limiter.acquire();
            completionTimes.add(stopwatch.elapsedMilliseconds);
          }),
        );

        expect(completionTimes.length, 4);
        for (var i = 1; i < completionTimes.length; i++) {
          expect(
            completionTimes[i],
            greaterThanOrEqualTo(period.inMilliseconds * i - 5),
          );
        }
      },
    );

    test(
      'run passes return value and preserves rate limit on failure',
      () async {
        const period = Duration(milliseconds: 40);
        final limiter = AsyncRateLimiter(period);

        final stopwatch = Stopwatch()..start();

        final firstResult = await limiter.run(() async => 'success');
        expect(firstResult, 'success');

        await expectLater(
          limiter.run(() async => throw StateError('action error')),
          throwsStateError,
        );

        final secondResult = await limiter.run(() async => 'recovered');
        expect(secondResult, 'recovered');

        expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(70));
      },
    );
  });
}
