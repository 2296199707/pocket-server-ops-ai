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
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _ImageProviderTile(controller: controller);
                  }
                  final provider = controller.providers[index - 1];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      leading: const CircleAvatar(
                        child: Icon(Icons.smart_toy_outlined),
                      ),
                      title: Text(provider.name),
                      subtitle: Text(
                        '${provider.model} · ${wireApiLabel(provider.wireApi)} · '
                        '推理${reasoningEffortLabel(provider.reasoningEffort)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
    final selectedProvider = selected == 'follow-default'
        ? controller.providers
              .where((provider) => provider.isDefault)
              .firstOrNull
        : controller.providers
              .where((provider) => provider.id == selected)
              .firstOrNull;
    final imageModel = selectedProvider == null
        ? ''
        : controller.imageModelFor(selectedProvider.id).trim();
    final modelOptions = selectedProvider == null
        ? const <String>[]
        : _imageModelOptions(controller, selectedProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const CircleAvatar(child: Icon(Icons.image_outlined)),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '生图供应商',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              DropdownButton<String>(
                value: selected,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                    value: 'follow-default',
                    child: Text('跟随默认'),
                  ),
                  for (final provider in controller.providers)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.name),
                    ),
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
            ],
          ),
          const SizedBox(height: 10),
          if (selectedProvider == null)
            const Padding(
              padding: EdgeInsets.only(left: 56),
              child: Text('选择供应商后，在这里选择图片模型；没有生图能力请选择“无”'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: DropdownButtonFormField<String>(
                initialValue: modelOptions.contains(imageModel)
                    ? imageModel
                    : '',
                decoration: const InputDecoration(
                  labelText: '图片模型',
                  helperText: '从该供应商已获取的模型列表中手动选择',
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('无')),
                  for (final model in modelOptions)
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  unawaited(
                    controller.setImageModel(selectedProvider.id, value),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

List<String> _imageModelOptions(
  AppController controller,
  ProviderProfile provider,
) {
  final models = <String>{
    if (provider.model.trim().isNotEmpty) provider.model.trim(),
    for (final key in provider.modelMetadata.keys)
      if (key.trim().isNotEmpty) key.trim(),
    for (final metadata in provider.modelMetadata.values)
      if (metadata.model.trim().isNotEmpty) metadata.model.trim(),
  };
  final selected = controller.imageModelFor(provider.id).trim();
  if (selected.isNotEmpty) models.add(selected);
  return models.toList()..sort();
}
