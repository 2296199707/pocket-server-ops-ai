import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import 'profile_sheets.dart';

class ProvidersPage extends StatelessWidget {
  const ProvidersPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('供应商设置')),
        body: controller.isLoading
            ? const Center(child: CircularProgressIndicator())
            : controller.providers.isEmpty
            ? const Center(child: Text('还没有 AI 供应商'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                itemCount: controller.providers.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _ImageProviderTile(controller: controller);
                  }
                  final provider = controller.providers[index - 1];
                  return ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.smart_toy_outlined),
                    ),
                    title: Text(provider.name),
                    subtitle: Text(
                      '${provider.model} · ${wireApiLabel(provider.wireApi)} · '
                      '推理${reasoningEffortLabel(provider.reasoningEffort)}',
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: '供应商操作',
                      onSelected: (value) {
                        if (value == 'edit') {
                          showProviderEditor(context, controller, provider);
                        } else if (value == 'test') {
                          _testProvider(context, provider);
                        } else {
                          _deleteProvider(context, provider);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'test', child: Text('测试连接')),
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  );
                },
              ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => showProviderEditor(context, controller),
          tooltip: '添加 AI 供应商',
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Future<void> _testProvider(
    BuildContext context,
    ProviderProfile provider,
  ) async {
    try {
      await controller.testProvider(provider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('连接成功')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('连接失败：$error')));
      }
    }
  }

  Future<void> _deleteProvider(
    BuildContext context,
    ProviderProfile provider,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除供应商？'),
        content: Text(provider.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.deleteProvider(provider);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }
}

class _ImageProviderTile extends StatelessWidget {
  const _ImageProviderTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final selected = controller.imageProviderId ?? 'follow-default';
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.image_outlined)),
      title: const Text('生图供应商'),
      subtitle: const Text('Agent 调用 image.generate 时使用，可跟随默认供应商'),
      trailing: DropdownButton<String>(
        value: selected,
        underline: const SizedBox.shrink(),
        items: [
          const DropdownMenuItem(value: 'follow-default', child: Text('跟随默认')),
          for (final provider in controller.providers)
            DropdownMenuItem(value: provider.id, child: Text(provider.name)),
        ],
        onChanged: (value) {
          if (value == null) return;
          unawaited(
            controller.setImageProviderId(
              value == 'follow-default' ? null : value,
            ),
          );
        },
      ),
    );
  }
}
