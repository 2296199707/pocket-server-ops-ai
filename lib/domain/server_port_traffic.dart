import 'dart:convert';

class PortTraffic {
  const PortTraffic({
    required this.receivedBytes,
    required this.transmittedBytes,
    this.receiveBytesPerSecond,
    this.transmitBytesPerSecond,
  });

  final int receivedBytes;
  final int transmittedBytes;
  final double? receiveBytesPerSecond;
  final double? transmitBytesPerSecond;
  int get totalBytes => receivedBytes + transmittedBytes;

  Map<String, Object?> toMap() => {
    'receivedBytes': receivedBytes,
    'transmittedBytes': transmittedBytes,
    'receiveBytesPerSecond': receiveBytesPerSecond,
    'transmitBytesPerSecond': transmitBytesPerSecond,
  };

  static PortTraffic? fromMap(Object? value) {
    if (value is! Map) return null;
    final rx = value['receivedBytes'];
    final tx = value['transmittedBytes'];
    if (rx is! int || tx is! int || rx < 0 || tx < 0) return null;
    return PortTraffic(
      receivedBytes: rx,
      transmittedBytes: tx,
      receiveBytesPerSecond: (value['receiveBytesPerSecond'] as num?)
          ?.toDouble(),
      transmitBytesPerSecond: (value['transmitBytesPerSecond'] as num?)
          ?.toDouble(),
    );
  }
}

class ServerPortTraffic {
  const ServerPortTraffic({
    required this.status,
    this.message,
    this.sshPorts = '',
    this.hy2Ports = '',
    this.ssh,
    this.hy2,
    this.suggestedSshPorts,
    this.suggestedHy2Ports,
  });

  final String status;
  final String? message;
  final String sshPorts;
  final String hy2Ports;
  final PortTraffic? ssh;
  final PortTraffic? hy2;
  final String? suggestedSshPorts;
  final String? suggestedHy2Ports;

  PortTraffic? get total {
    final tcp = ssh;
    final udp = hy2;
    if (tcp == null || udp == null) return null;
    double? sum(double? a, double? b) => a == null || b == null ? null : a + b;
    return PortTraffic(
      receivedBytes: tcp.receivedBytes + udp.receivedBytes,
      transmittedBytes: tcp.transmittedBytes + udp.transmittedBytes,
      receiveBytesPerSecond: sum(
        tcp.receiveBytesPerSecond,
        udp.receiveBytesPerSecond,
      ),
      transmitBytesPerSecond: sum(
        tcp.transmitBytesPerSecond,
        udp.transmitBytesPerSecond,
      ),
    );
  }

  Map<String, Object?> toMap() => {
    'status': status,
    'message': message,
    'sshPorts': sshPorts,
    'hy2Ports': hy2Ports,
    'ssh': ssh?.toMap(),
    'hy2': hy2?.toMap(),
    'suggestedSshPorts': suggestedSshPorts,
    'suggestedHy2Ports': suggestedHy2Ports,
  };

  factory ServerPortTraffic.fromMap(Map<String, Object?> map) =>
      ServerPortTraffic(
        status: map['status'] as String? ?? 'unavailable',
        message: map['message'] as String?,
        sshPorts: map['sshPorts'] as String? ?? '',
        hy2Ports: map['hy2Ports'] as String? ?? '',
        ssh: PortTraffic.fromMap(map['ssh']),
        hy2: PortTraffic.fromMap(map['hy2']),
        suggestedSshPorts: map['suggestedSshPorts'] as String?,
        suggestedHy2Ports: map['suggestedHy2Ports'] as String?,
      );

  static ServerPortTraffic? fromProbe(Map<String, String> values) {
    final status = values['traffic_status'];
    if (status == null) return null;
    ServerPortTraffic unavailable(String state, String message) =>
        ServerPortTraffic(
          status: state,
          message: message,
          suggestedSshPorts: values['traffic_ssh_hint'],
          suggestedHy2Ports: values['traffic_hy2_hint'],
        );
    if (status != 'ready') {
      return unavailable(status, switch (status) {
        'not_enabled' => '端口流量统计未开启',
        'unsupported' => '服务器未安装 nftables，暂不能统计端口流量',
        _ => '无法读取端口计数器，请检查 nftables 权限或规则状态',
      });
    }
    final after = _CounterSample.read(values['traffic_after']);
    if (after == null) return unavailable('unavailable', '端口计数器数据无效');
    final before = _CounterSample.read(values['traffic_before']);
    final seconds =
        (double.tryParse(values['traffic_time_after'] ?? '') ?? 0) -
        (double.tryParse(values['traffic_time_before'] ?? '') ?? 0);
    final comparable =
        before != null &&
        before.generation == after.generation &&
        seconds.isFinite &&
        seconds > 0;
    PortTraffic? service(String name) {
      final rx = after.bytes['${name}_rx'];
      final tx = after.bytes['${name}_tx'];
      if (rx == null || tx == null) return null;
      final oldRx = before?.bytes['${name}_rx'];
      final oldTx = before?.bytes['${name}_tx'];
      final rateAvailable =
          comparable &&
          oldRx != null &&
          oldTx != null &&
          rx >= oldRx &&
          tx >= oldTx;
      return PortTraffic(
        receivedBytes: rx,
        transmittedBytes: tx,
        receiveBytesPerSecond: rateAvailable ? (rx - oldRx) / seconds : null,
        transmitBytesPerSecond: rateAvailable ? (tx - oldTx) / seconds : null,
      );
    }

    final ssh = service('ssh');
    final hy2 = service('hy2');
    return ServerPortTraffic(
      status: ssh != null && hy2 != null ? 'ready' : 'unavailable',
      message: ssh == null || hy2 == null ? '端口计数器不完整，请停用后重新配置统计' : null,
      sshPorts: after.sshPorts,
      hy2Ports: after.hy2Ports,
      ssh: ssh,
      hy2: hy2,
      suggestedSshPorts: values['traffic_ssh_hint'],
      suggestedHy2Ports: values['traffic_hy2_hint'],
    );
  }
}

class _CounterSample {
  _CounterSample(this.generation, this.sshPorts, this.hy2Ports, this.bytes);
  final String generation;
  final String sshPorts;
  final String hy2Ports;
  final Map<String, int> bytes;

  static _CounterSample? read(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['nftables'] is! List) return null;
      String? comment;
      final bytes = <String, int>{};
      for (final item in decoded['nftables'] as List) {
        if (item is! Map) continue;
        final table = item['table'];
        if (table is Map &&
            table['family'] == 'inet' &&
            table['name'] == 'pocket_server_ops_traffic') {
          comment = table['comment'] as String?;
        }
        final counter = item['counter'];
        if (counter is Map &&
            counter['family'] == 'inet' &&
            counter['table'] == 'pocket_server_ops_traffic') {
          final value = counter['bytes'];
          final name = counter['name'];
          if (name is String && value is int && value >= 0) bytes[name] = value;
        }
      }
      final metadata = RegExp(
        r'^pso-traffic-v1\|ssh=([0-9,]+)\|hy2=([0-9,]+)\|id=([a-zA-Z0-9-]+)$',
      ).firstMatch(comment ?? '');
      if (metadata == null) return null;
      return _CounterSample(comment!, metadata[1]!, metadata[2]!, bytes);
    } on FormatException {
      return null;
    }
  }
}
