import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/stall_tracer.dart';

void main() {
  test('jobs long enough to matter are kept, with their times', () {
    var clock = 0;
    final t = StallTracer(now: () => clock);
    expect(
      t.time('quick', () {
        clock += 1000; // 1 ms: too short to make a frame late
        return 1;
      }),
      1,
    );
    t.time('save words', () => clock += 30000);
    final jobs = t.during((start: 0, end: 1 << 40));
    expect(jobs.map((j) => j.what), ['save words']);
    expect(jobs.single.end - jobs.single.start, 30000);
  });

  test('a job that throws is still timed', () {
    var clock = 0;
    final t = StallTracer(now: () => clock);
    expect(
      () => t.time<void>('labels', () {
        clock += 5000;
        throw StateError('x');
      }),
      throwsStateError,
    );
    expect(t.during((start: 0, end: 10000)), hasLength(1));
  });

  test('each spike is put down to the job that took most of it', () {
    final t = StallTracer(now: () => 0)
      ..add('labels', 0, 10000)
      ..add('save words', 5000, 60000)
      ..add('save words', 200000, 290000);
    final s = spikeCauses([
      (span: (start: 0, end: 50000), ms: 50),
      (span: (start: 210000, end: 280000), ms: 70),
      (span: (start: 500000, end: 530000), ms: 30),
    ], t);
    expect(s['spikes'], 3);
    expect(s['spikesUnexplained'], 1);
    expect(s['spikesWorstMs'], 70);
    expect(s['spikesCauses'], {
      'save words': {'n': 2, 'worstMs': 90.0},
    });
    expect(spikeCauses(const [], t), isEmpty);
    expect(
      spikeCauses([(span: (start: 0, end: 1), ms: 30)], t, name: 'stalls'),
      contains('stallsCauses'),
    );
  });

  test('stalls between frames are found from late ticks; sleep is not one', () {
    final w = StallWatch();
    w.tick(0);
    w.tick(100000); // on time
    w.tick(200000);
    w.tick(600000); // 400 ms late: busy for 300 ms
    w.tick(20000000); // asleep in the background
    expect(w.stalls, hasLength(1));
    expect(w.stalls.single.ms, closeTo(300, 0.1));
    expect(w.stalls.single.span, (start: 300000, end: 600000));
  });

  test('old jobs are forgotten', () {
    final t = StallTracer(now: () => 0)
      ..add('a', 0, 5000)
      ..add('b', 100000, 110000);
    t.forgetBefore(50000);
    expect(t.during((start: 0, end: 1 << 40)).map((j) => j.what), ['b']);
  });
}
