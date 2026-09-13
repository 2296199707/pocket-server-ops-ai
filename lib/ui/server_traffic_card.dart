import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/server_port_traffic.dart';
import '../server_traffic_script.dart';

class ServerTrafficCard extends StatelessWidget {
  const ServerTrafficCard({
    required this.traffic,
    required this.busy,
    required this.onConfigure,
    required this.onDisable,
    super.key,
  });

  final ServerPortTraffic? traffic;
  final bool busy;
  final Future<void> Function(String sshPorts, String hy2Ports) onConfigure;
  final Future<void> Function() onDisable;

  @override
  Widget build(BuildContext context) {
    final value = traffic;
    final status = value?.status;
    final configured = value != null && value.sshPorts.isNotEmpty;
    final canConfigure = !busy && status != 'unsupported';
    final colors = Theme.of(context).colorScheme;
    final message = value?.message;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.75),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_vert_rounded, size: 21, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'HY2 + SSH 流量',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (value != null) _TrafficStatus(status: status!),
            ],
          ),
          const Divider(height: 22),
          _TrafficDataRow(
            label: '合计',
            ports: null,
            traffic: value?.total,
            emphasized: true,
          ),
          const SizedBox(height: 9),
          _TrafficDataRow(
            label: 'SSH/TCP',
            ports: value == null ? '不可用' : _portsText(value.sshPorts),
            traffic: value?.ssh,
          ),
          const Divider(height: 19),
          _TrafficDataRow(
            label: 'HY2/UDP',
            ports: value == null ? '不可用' : _portsText(value.hy2Ports),
            traffic: value?.hy2,
          ),
          const SizedBox(height: 10),
          Text(
            '服务器端口收发统计；自开启以来累计，重启或修改端口后重新计数。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (message != null && message.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: status == 'unsupported' || status == 'unavailable'
                    ? colors.errorContainer
                    : colors.surfaceContainerHighest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(message),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: canConfigure
                    ? () => unawaited(_configure(context))
                    : null,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.tune_outlined, size: 18),
                label: const Text('配置端口'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              if (configured)
                TextButton.icon(
                  onPressed: busy ? null : () => unawaited(onDisable()),
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  label: const Text('停用统计'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _configure(BuildContext context) async {
    final configuration = await _showConfigureDialog(context, traffic);
    if (configuration == null) return;
    await onConfigure(configuration.sshPorts, configuration.hy2Ports);
  }
}

class _TrafficStatus extends StatelessWidget {
  const _TrafficStatus({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (status) {
      'ready' => Colors.green.shade700,
      'unsupported' || 'unavailable' => colors.error,
      _ => colors.onSurfaceVariant,
    };
    return Text(
      _statusText(status),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
    );
  }
}

class _TrafficDataRow extends StatelessWidget {
  const _TrafficDataRow({
    required this.label,
    required this.ports,
    required this.traffic,
    this.emphasized = false,
  });

  final String label;
  final String? ports;
  final PortTraffic? traffic;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final valueStyle = emphasized ? textTheme.titleSmall : textTheme.bodyMedium;
    final rateText = _rateText(traffic);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: emphasized ? textTheme.titleSmall : null,
                    ),
                    if (ports != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        ports!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 8,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _TrafficMetric(
                      label: '接收',
                      value: _counterText(traffic?.receivedBytes),
                      valueStyle: valueStyle,
                    ),
                  ),
                  Expanded(
                    child: _TrafficMetric(
                      label: '发送',
                      value: _counterText(traffic?.transmittedBytes),
                      valueStyle: valueStyle,
                    ),
                  ),
                  Expanded(
                    child: _TrafficMetric(
                      label: '总计',
                      value: _counterText(traffic?.totalBytes),
                      valueStyle: valueStyle,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (rateText != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              rateText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _TrafficMetric extends StatelessWidget {
  const _TrafficMetric({
    required this.label,
    required this.value,
    required this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: double.infinity,
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: valueStyle,
          ),
        ),
      ],
    );
  }
}

class _TrafficConfiguration {
  const _TrafficConfiguration({required this.sshPorts, required this.hy2Ports});

  final String sshPorts;
  final String hy2Ports;
}

Future<_TrafficConfiguration?> _showConfigureDialog(
  BuildContext context,
  ServerPortTraffic? traffic,
) {
  var sshPorts = traffic?.sshPorts.isNotEmpty == true
      ? traffic!.sshPorts
      : traffic?.suggestedSshPorts ?? '';
  var hy2Ports = traffic?.hy2Ports.isNotEmpty == true
      ? traffic!.hy2Ports
      : traffic?.suggestedHy2Ports ?? '';
  final formKey = GlobalKey<FormState>();

  return showDialog<_TrafficConfiguration>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('配置端口统计'),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '仅创建 nftables 流量计数规则，不会开放端口；需要服务器具备 nftables 权限。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                initialValue: sshPorts,
                onSaved: (value) => sshPorts = value!.trim(),
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'SSH/TCP 端口',
                  hintText: _portHint(
                    traffic?.suggestedSshPorts,
                    '例如 22, 2222',
                  ),
                  helperText: _portSuggestion(traffic?.suggestedSshPorts),
                ),
                validator: (value) => _validatePorts(value, 'SSH/TCP'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                initialValue: hy2Ports,
                onSaved: (value) => hy2Ports = value!.trim(),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'HY2/UDP 端口',
                  hintText: _portHint(traffic?.suggestedHy2Ports, '例如 443'),
                  helperText: _portSuggestion(traffic?.suggestedHy2Ports),
                ),
                validator: (value) => _validatePorts(value, 'HY2/UDP'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            formKey.currentState!.save();
            Navigator.of(dialogContext).pop(
              _TrafficConfiguration(sshPorts: sshPorts, hy2Ports: hy2Ports),
            );
          },
          child: const Text('安装统计规则'),
        ),
      ],
    ),
  );
}

String _statusText(String status) {
  return switch (status) {
    'ready' => '已启用',
    'not_enabled' => '未启用',
    'unavailable' => '不可用',
    'unsupported' => '不支持',
    _ => status,
  };
}

String _portsText(String ports) {
  final value = ports.trim();
  return value.isEmpty ? '未配置' : value;
}

String _counterText(int? value) {
  return value == null ? '不可用' : _formatTrafficBytes(value);
}

String? _validatePorts(String? value, String label) {
  if (value == null || value.trim().isEmpty) return '请输入 $label 端口';
  try {
    normalizeTrafficPorts(value);
  } on FormatException catch (error) {
    return error.message.toString();
  }
  return null;
}

String? _rateText(PortTraffic? traffic) {
  if (traffic == null ||
      (traffic.receiveBytesPerSecond == null &&
          traffic.transmitBytesPerSecond == null)) {
    return null;
  }
  final receive = traffic.receiveBytesPerSecond == null
      ? '不可用'
      : '${_formatTrafficBytes(traffic.receiveBytesPerSecond!)} /s';
  final transmit = traffic.transmitBytesPerSecond == null
      ? '不可用'
      : '${_formatTrafficBytes(traffic.transmitBytesPerSecond!)} /s';
  return '采样速率 ↓ $receive · ↑ $transmit';
}

String _formatTrafficBytes(num value) {
  if (!value.isFinite || value < 0) return '不可用';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var number = value.toDouble();
  var unit = 0;
  while (number >= 1024 && unit < units.length - 1) {
    number /= 1024;
    unit++;
  }
  final digits = number >= 10 || unit == 0 ? 0 : 1;
  return '${number.toStringAsFixed(digits)} ${units[unit]}';
}

String _portHint(String? suggested, String fallback) {
  final value = suggested?.trim();
  return value == null || value.isEmpty ? fallback : value;
}

String? _portSuggestion(String? suggested) {
  final value = suggested?.trim();
  return value == null || value.isEmpty ? '多个端口请用逗号分隔' : '建议：$value';
}
