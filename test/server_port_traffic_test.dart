import 'dart:convert';
import 'dart:io';

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
  Map<String, String> realProbe() => {
    for (final line in File(
      'test/fixtures/nft-1.0.6-traffic-probe.txt',
    ).readAsLinesSync())
      if (line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };

  test(
    'actual nft 1.0.6 JSON without comment reads text metadata and caches',
    () {
      final values = realProbe();
      final legacyValues = Map<String, String>.of(values)
        ..remove('traffic_meta_before')
        ..remove('traffic_meta_after');
      expect(ServerPortTraffic.fromProbe(legacyValues)!.status, 'unavailable');
      final traffic = ServerPortTraffic.fromProbe(values)!;
      expect(traffic.status, 'ready');
      expect(traffic.sshPorts, '2222');
      expect(traffic.suggestedSshPorts, '22,2222');
      expect(traffic.suggestedHy2Ports, '443');
      expect(traffic.hy2Ports, '443,35043,41061,41619,43633,48820,55584');
      expect(traffic.total!.totalBytes, 2096683694);
      expect(traffic.total!.receiveBytesPerSecond, isNotNull);
      final restored = ServerDashboard.fromJson(
        jsonEncode({'portTraffic': traffic.toMap()}),
      );
      expect(restored.portTraffic!.toMap(), traffic.toMap());
    },
  );

  test('separate metadata cannot be paired with another table snapshot', () {
    final values = realProbe();
    values['traffic_meta_after'] = values['traffic_meta_after']!.replaceFirst(
      '5|',
      '6|',
    );
    expect(ServerPortTraffic.fromProbe(values)!.total, isNull);
    values['traffic_meta_after'] = '';
    expect(ServerPortTraffic.fromProbe(values)!.total, isNull);
  });

  test('table replaced between samples retains totals without false rates', () {
    final values = realProbe();
    final before = jsonDecode(values['traffic_before']!) as Map;
    for (final item in before['nftables'] as List) {
      if (item['table'] is Map) item['table']['handle'] = 4;
    }
    values['traffic_before'] = jsonEncode(before);
    values['traffic_meta_before'] = values['traffic_meta_before']!.replaceFirst(
      '5|',
      '4|',
    );
    final traffic = ServerPortTraffic.fromProbe(values)!;
    expect(traffic.status, 'ready');
    expect(traffic.total!.totalBytes, 2096683694);
    expect(traffic.total!.receiveBytesPerSecond, isNull);
  });

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
