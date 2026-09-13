import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/domain/server_port_traffic.dart';

String sample(List<int?> counts, {String id = 'one'}) => jsonEncode({
  'nftables': [
    {
      'table': {
        'family': 'inet',
        'name': 'pocket_server_ops_traffic',
        'comment': 'pso-traffic-v1|ssh=22,2222|hy2=443|id=$id',
      },
    },
    for (var i = 0; i < counts.length; i++)
      if (counts[i] != null)
        {
          'counter': {
            'family': 'inet',
            'table': 'pocket_server_ops_traffic',
            'name': ['ssh_rx', 'ssh_tx', 'hy2_rx', 'hy2_tx'][i],
            'bytes': counts[i],
          },
        },
  ],
});

ServerPortTraffic parse(String before, String after) =>
    ServerPortTraffic.fromProbe({
      'traffic_status': 'ready',
      'traffic_before': before,
      'traffic_after': after,
      'traffic_time_before': '100.00',
      'traffic_time_after': '100.25',
    })!;

void main() {
  test('same-basis service totals, rates and dashboard cache round trip', () {
    final traffic = parse(
      sample([100, 200, 300, 400]),
      sample([150, 250, 500, 600]),
    );
    expect(traffic.sshPorts, '22,2222');
    expect(traffic.total!.receivedBytes, 650);
    expect(traffic.total!.transmittedBytes, 850);
    expect(traffic.total!.totalBytes, 1500);
    expect(traffic.total!.receiveBytesPerSecond, 1000);
    expect(traffic.total!.transmitBytesPerSecond, 1000);
    final dashboard = ServerDashboard.fromJson(
      jsonEncode({'portTraffic': traffic.toMap()}),
    );
    final restored = ServerDashboard.fromJson(dashboard.toJson()).portTraffic!;
    expect(restored.toMap(), traffic.toMap());
  });

  test('missing counters never become a zero or partial combined total', () {
    final traffic = parse(sample([0, 0, 0, 0]), sample([1, 2, 3, null]));
    expect(traffic.status, 'unavailable');
    expect(traffic.ssh!.totalBytes, 3);
    expect(traffic.hy2, isNull);
    expect(traffic.total, isNull);
    expect(
      parse(sample([0, 0, 0, 0]), sample([0, 0, 0, 0])).total!.totalBytes,
      0,
    );
    expect(ServerPortTraffic.fromProbe({}), isNull);
    expect(
      ServerPortTraffic.fromProbe({'traffic_status': 'unavailable'})!.total,
      isNull,
    );
    expect(parse('{}', 'bad json').status, 'unavailable');
  });

  test('counter replacement or reset does not produce a rate spike', () {
    final replaced = parse(
      sample([1, 2, 3, 4]),
      sample([10000, 20000, 30000, 40000], id: 'new'),
    );
    expect(replaced.total!.totalBytes, 100000);
    expect(replaced.total!.receiveBytesPerSecond, isNull);
    final reset = parse(sample([100, 200, 300, 400]), sample([1, 2, 3, 4]));
    expect(reset.total!.transmitBytesPerSecond, isNull);
    final unavailableBefore = parse('{}', sample([1, 2, 3, 4]));
    expect(unavailableBefore.total!.totalBytes, 10);
    expect(unavailableBefore.total!.receiveBytesPerSecond, isNull);
  });
}
