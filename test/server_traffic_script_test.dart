import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/domain/server_port_traffic.dart';
import 'package:mobile_agent/server_traffic_script.dart';

void main() {
  test('port suggestions use server config, not outgoing UDP sockets', () async {
    final temp = await Directory.systemTemp.createTemp('pso-traffic-hints-');
    Process? server;
    try {
      final config = File('${temp.path}/config.yaml');
      await config.writeAsString('listen: ":443" # server entry\n');
      server = await Process.start('sh', [
        '-c',
        'read -r unused',
        'server',
        '--config',
        config.path,
      ]);
      final scripts = {
        'pgrep': '#!/bin/sh\nprintf "%s\\n" ${server.pid}\n',
        'ss':
            '#!/bin/sh\nprintf "%s\\n" '
            "'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))' "
            "'LISTEN 0 128 [::]:22 [::]:* users:((\"sshd\",pid=1,fd=4))' "
            "'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:((\"sshd\",pid=1,fd=5))' "
            "'UNCONN 0 0 *:443 *:* users:((\"hysteria\",pid=2,fd=3))' "
            "'UNCONN 0 0 *:55584 *:* users:((\"hysteria\",pid=2,fd=4))'\n",
        'nft': '#!/bin/sh\nexit 1\n',
      };
      for (final entry in scripts.entries) {
        final file = File('${temp.path}/${entry.key}');
        await file.writeAsString(entry.value);
        final result = await Process.run('chmod', ['700', file.path]);
        expect(result.exitCode, 0);
      }
      final result = await Process.run(
        'sh',
        ['-c', serverTrafficProbeCommand],
        environment: {'PATH': '${temp.path}:/usr/bin:/bin'},
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout, contains('traffic_ssh_hint=22,2222\n'));
      expect(result.stdout, contains('traffic_hy2_hint=443\n'));
      expect(result.stdout, isNot(contains('55584')));
    } finally {
      server?.kill();
      if (server != null) await server.exitCode;
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isLinux);

  test('port input rejects command injection and invalid ports', () {
    expect(normalizeTrafficPorts('2222, 22,22'), '22,2222');
    for (final value in ['', '0', '65536', '22; reboot', '22,', '-1']) {
      expect(() => normalizeTrafficPorts(value), throwsFormatException);
    }
  });

  test(
    'real nftables counters in isolated network namespaces',
    () async {
      final process = await Process.run(
        'unshare',
        ['--net', 'python3', '-c', _networkCheck],
        environment: {
          'PSO_TRAFFIC_ENABLE': serverTrafficConfigureCommand(
            sshPorts: '24443',
            hy2Ports: '24443',
          ),
          'PSO_TRAFFIC_RECONFIGURE': serverTrafficConfigureCommand(
            sshPorts: '24444',
            hy2Ports: '24443',
          ),
          'PSO_TRAFFIC_DISABLE': serverTrafficDisableCommand,
          'PSO_TRAFFIC_PROBE': serverTrafficProbeCommand,
        },
      );
      expect(
        process.exitCode,
        0,
        reason: '${process.stderr}\n${process.stdout}',
      );
      final values = <String, String>{};
      for (final line in const LineSplitter().convert(
        process.stdout as String,
      )) {
        final split = line.indexOf('=');
        if (split > 0) {
          values[line.substring(0, split)] = line.substring(split + 1);
        }
      }
      final traffic = ServerPortTraffic.fromProbe(values)!;
      expect(traffic.status, 'ready');
      expect(traffic.ssh!.receivedBytes, greaterThan(0));
      expect(traffic.ssh!.transmittedBytes, greaterThan(0));
      expect(traffic.hy2!.receivedBytes, 32);
      expect(traffic.hy2!.transmittedBytes, 32);
      expect(traffic.total!.totalBytes, traffic.ssh!.totalBytes + 64);
    },
    skip: Platform.environment['PSO_TRAFFIC_NETNS_TEST'] != '1'
        ? 'Opt in on Linux with nft/ip/python3 and isolated netns permissions'
        : false,
  );
}

// All interface and ruleset changes happen inside unshare --net. A peer netns
// supplies real non-loopback TCP and UDP traffic to the same numeric port.
const _networkCheck = r'''
import json, os, socket, subprocess, threading, time

def run(args, **kw):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kw).stdout

def script(key):
    return run(["sh", "-c", os.environ[key]])

def counters():
    return json.loads(run(["nft", "-j", "list", "table", "inet", "pocket_server_ops_traffic"]))

def generation():
    return next(x["table"]["comment"] for x in counters()["nftables"] if "table" in x)

run(["nft", "add", "table", "inet", "existing_firewall"])
original = run(["nft", "-s", "list", "table", "inet", "existing_firewall"])
assert "traffic_status=not_enabled" in script("PSO_TRAFFIC_PROBE")
script("PSO_TRAFFIC_ENABLE")
first_generation = generation()
script("PSO_TRAFFIC_ENABLE")
assert generation() == first_generation

peer = subprocess.Popen(["unshare", "--net", "sleep", "25"])
try:
    for _ in range(100):
        if os.readlink("/proc/%d/ns/net" % peer.pid) != os.readlink("/proc/self/ns/net"):
            break
        time.sleep(0.01)
    else:
        raise RuntimeError("peer network namespace did not start")
    run(["ip", "link", "add", "pso-server", "type", "veth", "peer", "name", "pso-client"])
    run(["ip", "link", "set", "pso-client", "netns", str(peer.pid)])
    run(["ip", "addr", "add", "192.0.2.1/24", "dev", "pso-server"])
    run(["ip", "link", "set", "pso-server", "up"])
    ns = ["nsenter", "-t", str(peer.pid), "-n"]
    run(ns + ["ip", "addr", "add", "192.0.2.2/24", "dev", "pso-client"])
    run(ns + ["ip", "link", "set", "pso-client", "up"])
    tcp = socket.socket()
    tcp.settimeout(5)
    tcp.bind(("192.0.2.1", 24443))
    tcp.listen()
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.settimeout(5)
    udp.bind(("192.0.2.1", 24443))
    errors = []
    def echo():
        try:
            conn, _ = tcp.accept()
            with conn:
                conn.settimeout(5)
                conn.sendall(conn.recv(1024))
            data, address = udp.recvfrom(1024)
            udp.sendto(data, address)
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=echo)
    thread.start()
    run(ns + ["python3", "-c", """
import socket
with socket.create_connection(("192.0.2.1",24443), 5) as s:
    s.sendall(b"test")
    assert s.recv(4) == b"test"
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
    s.settimeout(5)
    s.sendto(b"test",("192.0.2.1",24443))
    assert s.recv(4) == b"test"
"""])
    thread.join(6)
    assert not thread.is_alive() and not errors, errors
    tcp.close()
    udp.close()
    probe = script("PSO_TRAFFIC_PROBE")
    before_repeat = counters()
    script("PSO_TRAFFIC_ENABLE")
    assert counters() == before_repeat, "unchanged config reset counters"
    script("PSO_TRAFFIC_RECONFIGURE")
    assert generation() != first_generation
    assert all(x["counter"]["bytes"] == 0 for x in counters()["nftables"] if "counter" in x)
    script("PSO_TRAFFIC_DISABLE")
    assert "traffic_status=not_enabled" in script("PSO_TRAFFIC_PROBE")
    assert run(["nft", "-s", "list", "table", "inet", "existing_firewall"]) == original
    run(["nft", "add", "table", "inet", "pocket_server_ops_traffic"])
    foreign = counters()
    for key in ["PSO_TRAFFIC_ENABLE", "PSO_TRAFFIC_DISABLE"]:
        result = subprocess.run(["sh", "-c", os.environ[key]], capture_output=True)
        assert result.returncode != 0
        assert counters() == foreign
    print(probe)
finally:
    peer.terminate()
    peer.wait(timeout=3)
''';
