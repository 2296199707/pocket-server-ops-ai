import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../local/document_export.dart';

class DocumentPreviewPage extends StatefulWidget {
  const DocumentPreviewPage({
    required this.fileName,
    required this.content,
    super.key,
  });

  final String fileName;
  final String content;

  @override
  State<DocumentPreviewPage> createState() => _DocumentPreviewPageState();
}

class _DocumentPreviewPageState extends State<DocumentPreviewPage> {
  late final DocumentSourceFormat _format;
  WebViewController? _webView;
  bool _loadingHtml = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _format = documentSourceFormatFor(widget.fileName);
    if (_format == DocumentSourceFormat.html) {
      _webView = WebViewController();
      unawaited(_loadHtml());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '预览 · ${widget.fileName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: switch (_format) {
        DocumentSourceFormat.markdown => Markdown(
          data: widget.content,
          selectable: true,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
        DocumentSourceFormat.html => _buildHtmlPreview(),
        DocumentSourceFormat.text => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(widget.content),
        ),
      },
    );
  }

  Widget _buildHtmlPreview() {
    final webView = _webView;
    if (webView == null) return const SizedBox.shrink();
    return Stack(
      children: [
        WebViewWidget(controller: webView),
        if (_loadingHtml)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_error != null)
          Align(
            alignment: Alignment.topCenter,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _loadHtml() async {
    final webView = _webView;
    if (webView == null) return;
    try {
      await webView.setJavaScriptMode(JavaScriptMode.disabled);
      await webView.setBackgroundColor(const Color(0xfff7f9f8));
      await webView.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (_) => NavigationDecision.prevent,
          onPageFinished: (_) {
            if (mounted) setState(() => _loadingHtml = false);
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() {
                _loadingHtml = false;
                _error = error.description;
              });
            }
          },
        ),
      );
      await webView.loadHtmlString(_htmlDocument(widget.content));
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingHtml = false;
          _error = '$error';
        });
      }
    }
  }
}

String _htmlDocument(String source) {
  const style = '''
<style>
  :root { color-scheme: light; }
  body { margin: 0; padding: 18px 16px 32px; color: #1c1c1e; background: #f7f9f8; font-family: sans-serif; line-height: 1.6; }
  img { max-width: 100%; height: auto; }
  table { max-width: 100%; border-collapse: collapse; }
  td, th { border: 1px solid #b7c3d0; padding: 6px 8px; }
  pre { white-space: pre-wrap; overflow-wrap: anywhere; background: #eef1f5; padding: 10px; border-radius: 6px; }
</style>
''';
  final head = RegExp(r'<head\b[^>]*>', caseSensitive: false);
  if (head.hasMatch(source)) {
    return source.replaceFirst(
      head,
      '${head.firstMatch(source)!.group(0)}$style',
    );
  }
  return '<!doctype html><html><head><meta charset="utf-8">$style</head><body>$source</body></html>';
}
