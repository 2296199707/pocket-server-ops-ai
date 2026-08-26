import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../local/local_preview.dart';

class LocalPreviewPage extends StatefulWidget {
  const LocalPreviewPage({
    required this.controller,
    required this.project,
    super.key,
  });

  final AppController controller;
  final Project project;

  @override
  State<LocalPreviewPage> createState() => _LocalPreviewPageState();
}

class _LocalPreviewPageState extends State<LocalPreviewPage> {
  late final WebViewController _webView;
  Timer? _statusTimer;
  LocalPreviewStatus? _status;
  bool _starting = true;
  bool _loadingPage = false;
  String? _error;
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _webView = WebViewController();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _pollStatus(),
    );
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _webView.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _webView.setBackgroundColor(const Color(0xfff7f9f8));
      await _webView.setOnConsoleMessage(_onConsoleMessage);
      await _webView.addJavaScriptChannel(
        'PocketPreview',
        onMessageReceived: _onJavaScriptMessage,
      );
      await _webView.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: (url) {
            if (mounted) setState(() => _loadingPage = true);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _loadingPage = false);
            unawaited(_installErrorHooks());
          },
          onWebResourceError: _onWebResourceError,
          onHttpError: _onHttpError,
        ),
      );
      final status = await widget.controller.startLocalPreview(widget.project);
      if (!mounted) return;
      setState(() {
        _status = status;
        _reloadToken = status.reloadToken;
        _starting = false;
        _error = null;
      });
      await _webView.loadRequest(Uri.parse(status.url!));
    } catch (error) {
      if (mounted) {
        setState(() {
          _starting = false;
          _loadingPage = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _pollStatus() async {
    final status = widget.controller.localPreviewStatus(widget.project);
    if (!mounted) return;
    if (_status?.running == true &&
        status.running &&
        status.reloadToken != _reloadToken) {
      _reloadToken = status.reloadToken;
      try {
        await _webView.reload();
      } catch (_) {}
    }
    if (_status?.requestCount != status.requestCount ||
        _status?.logSequence != status.logSequence ||
        _status?.running != status.running) {
      setState(() => _status = status);
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final statusUri = Uri.tryParse(_status?.url ?? '');
    final requestUri = Uri.tryParse(request.url);
    if (statusUri == null || requestUri == null) {
      return NavigationDecision.prevent;
    }
    final isLocal =
        requestUri.scheme == statusUri.scheme &&
        requestUri.host == statusUri.host &&
        requestUri.port == statusUri.port;
    return isLocal ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  void _onConsoleMessage(JavaScriptConsoleMessage message) {
    widget.controller.recordLocalPreviewLog(
      widget.project,
      level: _levelForConsole(message.level),
      source: 'console',
      message: message.message,
    );
  }

  void _onJavaScriptMessage(JavaScriptMessage message) {
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map) {
        final level = decoded['level'];
        final text = decoded['message'];
        if (text is String) {
          widget.controller.recordLocalPreviewLog(
            widget.project,
            level: level is String ? level : 'error',
            source: decoded['source'] is String
                ? decoded['source'] as String
                : 'javascript',
            message: text,
            url: decoded['url'] is String ? decoded['url'] as String : null,
          );
          return;
        }
      }
    } on Object {
      // Fall through and keep the raw message.
    }
    widget.controller.recordLocalPreviewLog(
      widget.project,
      level: 'error',
      source: 'javascript',
      message: message.message,
    );
  }

  void _onWebResourceError(WebResourceError error) {
    final url = error.url;
    widget.controller.recordLocalPreviewLog(
      widget.project,
      level: 'error',
      source: error.isForMainFrame == false ? 'resource' : 'page',
      message: '${error.description} (${error.errorCode})',
      url: url,
    );
    if (error.isForMainFrame != false && mounted) {
      setState(() {
        _loadingPage = false;
        _error = error.description;
      });
    }
  }

  void _onHttpError(HttpResponseError error) {
    final response = error.response;
    final request = error.request;
    final statusCode = response?.statusCode;
    widget.controller.recordLocalPreviewLog(
      widget.project,
      level: 'error',
      source: 'http',
      message: 'HTTP 错误${statusCode == null ? '' : ' $statusCode'}',
      url: (response?.uri ?? request?.uri)?.toString(),
    );
  }

  Future<void> _installErrorHooks() async {
    try {
      await _webView.runJavaScript(localPreviewErrorHookScript);
    } catch (_) {
      // Some WebView versions do not allow script injection before a page is
      // fully ready; the console callback still remains available.
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loadingPage = true;
      _error = null;
    });
    try {
      await _webView.reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _stop() async {
    await widget.controller.stopLocalPreview(widget.project);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _showLogs() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PreviewLogsSheet(
        controller: widget.controller,
        project: widget.project,
      ),
    );
  }

  Future<void> _runTest() async {
    try {
      final result = await widget.controller.testLocalWeb(widget.project);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _WebTestSheet(result: result),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('网页检查失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.project.name} · 预览',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '检查网页资源',
            onPressed: _starting ? null : _runTest,
            icon: const Icon(Icons.rule_outlined),
          ),
          IconButton(
            tooltip: '控制台日志',
            onPressed: _showLogs,
            icon: const Icon(Icons.subject_outlined),
          ),
          IconButton(
            tooltip: '刷新预览',
            onPressed: _starting ? null : _reload,
            icon: _loadingPage
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '停止预览',
            onPressed: status?.running == true ? _stop : null,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_error!)),
                        ],
                      ),
                    ),
                  ),
                if (status?.url != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                    child: Row(
                      children: [
                        Icon(
                          status!.running
                              ? Icons.circle
                              : Icons.circle_outlined,
                          size: 8,
                          color: status.running
                              ? Colors.green
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${status.url} · 请求 ${status.requestCount} · 日志 ${status.logSequence}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 1),
                Expanded(child: WebViewWidget(controller: _webView)),
              ],
            ),
    );
  }
}

String _levelForConsole(JavaScriptLogLevel level) {
  switch (level) {
    case JavaScriptLogLevel.error:
      return 'error';
    case JavaScriptLogLevel.warning:
      return 'warning';
    case JavaScriptLogLevel.debug:
      return 'debug';
    case JavaScriptLogLevel.info:
      return 'info';
    case JavaScriptLogLevel.log:
      return 'info';
  }
}

class _PreviewLogsSheet extends StatefulWidget {
  const _PreviewLogsSheet({required this.controller, required this.project});

  final AppController controller;
  final Project project;

  @override
  State<_PreviewLogsSheet> createState() => _PreviewLogsSheetState();
}

class _PreviewLogsSheetState extends State<_PreviewLogsSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = widget.controller.localPreviewLogs(widget.project, limit: 200);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: [
            ListTile(
              title: const Text('预览日志'),
              subtitle: Text('${logs.length} 条，包含控制台、页面错误和资源请求'),
              trailing: IconButton(
                tooltip: '清空日志',
                onPressed: logs.isEmpty
                    ? null
                    : () {
                        widget.controller.clearLocalPreviewLogs(widget.project);
                        setState(() {});
                      },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: logs.isEmpty
                  ? const Center(child: Text('暂无日志，请先打开或刷新预览页面'))
                  : ListView.separated(
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: logs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final log = logs[logs.length - 1 - index];
                        return _PreviewLogTile(log: log);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewLogTile extends StatelessWidget {
  const _PreviewLogTile({required this.log});

  final LocalPreviewLog log;

  @override
  Widget build(BuildContext context) {
    final color = switch (log.level) {
      'error' => Theme.of(context).colorScheme.error,
      'warning' => Colors.orange.shade800,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText.rich(
        TextSpan(
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
          children: [
            TextSpan(
              text: '#${log.sequence} ${log.source}/${log.level}\n',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            TextSpan(text: log.message),
            if (log.url != null)
              TextSpan(
                text: '\n${log.url}',
                style: TextStyle(color: color.withValues(alpha: 0.8)),
              ),
          ],
        ),
      ),
    );
  }
}

class _WebTestSheet extends StatelessWidget {
  const _WebTestSheet({required this.result});

  final LocalWebTestResult result;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                result.ok ? Icons.check_circle_outline : Icons.error_outline,
                color: result.ok
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
              title: Text(result.ok ? '网页资源检查通过' : '发现网页资源问题'),
              subtitle: Text(
                '${result.entrypoint} · 检查 ${result.checkedFiles.length} 个文件 · ${result.issues.length} 个问题',
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: result.issues.isEmpty
                  ? const Center(child: Text('未发现缺失的本地资源'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: result.issues.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final issue = result.issues[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            issue.level == 'error'
                                ? Icons.error_outline
                                : Icons.warning_amber_outlined,
                            color: issue.level == 'error'
                                ? Theme.of(context).colorScheme.error
                                : Colors.orange.shade800,
                          ),
                          title: Text(issue.message),
                          subtitle: Text(issue.source),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
