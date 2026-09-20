import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as path;

import '../domain/models.dart';
import '../local/local_file_access.dart';
import '../local/local_preview.dart';
import '../local/project_files.dart';
import 'agent_tools.dart';
import 'ai_protocol.dart';

typedef PersistToolImage = Future<AiAttachment> Function(
  String name,
  String mimeType,
  Uint8List bytes,
);
typedef CapturePreviewImage = Future<Uint8List> Function(
  String url,
  int width,
  int height,
);

class PhoneImageTools {
  PhoneImageTools({
    required this.persist,
    required this.readAttachment,
    required this.preview,
    required this.capture,
    this.project,
    this.access,
    this.files = const ProjectFileStore(),
    this.allowLocalFiles = true,
    this.supportsImages = true,
  });

  final PersistToolImage persist;
  final Future<AiAttachment> Function(String id) readAttachment;
  final LocalPreviewServer preview;
  final CapturePreviewImage capture;
  final Project? project;
  final LocalFileAccessStore? access;
  final ProjectFileStore files;
  final bool allowLocalFiles;
  final bool supportsImages;

  List<AgentTool> get tools => [
    AgentTool(
      definition: const AiToolDefinition(
        name: 'image.view',
        description:
            'View actual pixels of one image. source=project uses a '
            'project-relative path; source=local uses an authorized absolute '
            'phone path; source=attachment uses an attachment_id as path. '
            'Supports PNG/JPEG/WebP and the first GIF frame. Use this to inspect '
            'existing assets or revisit generated images; text file.read does '
            'not show pixels.',
        parameters: {
          'type': 'object',
          'required': ['source', 'path'],
          'properties': {
            'source': {
              'type': 'string',
              'enum': ['project', 'local', 'attachment'],
            },
            'path': {'type': 'string'},
          },
        },
      ),
      call: view,
      requiresConfirmation: false,
      canRunConcurrently: true,
    ),
    if (allowLocalFiles && project != null)
      AgentTool(
        definition: const AiToolDefinition(
          name: 'preview.screenshot',
          description:
              'Render a fresh viewport of a project web page on the '
              'phone and return a PNG image for visual inspection. This is a '
              'separate render, not the user current interactive browser state. '
              'Use preview.logs and local.test_web as well; a screenshot alone '
              'does not prove there are no runtime errors.',
          parameters: {
            'type': 'object',
            'properties': {
              'entrypoint': {
                'type': 'string',
                'description': 'Project HTML path; defaults to current preview or index.html',
              },
              'width': {'type': 'integer', 'minimum': 1, 'maximum': 2048},
              'height': {'type': 'integer', 'minimum': 1, 'maximum': 2048},
            },
          },
        ),
        call: screenshot,
        requiresConfirmation: false,
      ),
  ];

  void _requireVision() {
    if (!supportsImages) {
      throw StateError('当前对话模型明确不支持图片输入，请切换视觉模型后查看图片');
    }
  }

  Future<Object?> view(Map<String, Object?> arguments) async {
    _requireVision();
    final source = arguments['source'];
    final target = arguments['path'];
    if (target is! String || target.trim().isEmpty) {
      throw ArgumentError('path is required');
    }
    if (source == 'attachment') {
      final attachment = await readAttachment(target);
      if (!attachment.isImage) throw ArgumentError('所选附件不是图片');
      return AiToolResult(
        result: {'viewed': true, ...attachment.toJson()},
        attachments: [attachment],
      );
    }
    if (!allowLocalFiles) throw StateError('当前工作模式未启用手机本地文件工具');
    String resolved;
    final bound = project;
    if (source == 'project') {
      if (bound == null) throw StateError('当前对话没有绑定手机项目');
      resolved = await files.resolveForIo(bound, target);
    } else if (source == 'local') {
      if (!path.isAbsolute(target)) {
        throw ArgumentError('local path must be absolute');
      }
      final projectPath = bound == null
          ? null
          : await files.resolveAbsoluteForIo(bound, target);
      if (projectPath != null) {
        resolved = projectPath;
      } else {
        if (access == null) throw StateError('本地文件没有访问授权');
        resolved = await access!.resolve(target);
      }
    } else {
      throw ArgumentError('source must be project, local or attachment');
    }
    final bytes = await File(resolved).readAsBytes();
    return persistToolImageResult(path.basename(target), bytes, {
      'source': source,
      'path': target,
    }, persist: persist);
  }

  Future<Object?> screenshot(Map<String, Object?> arguments) async {
    _requireVision();
    final bound = project;
    if (!allowLocalFiles || bound == null) throw StateError('截图需要绑定手机项目');
    int dimension(String name, int fallback) {
      final value = arguments[name] ?? fallback;
      if (value is! int || value < 1 || value > 2048) {
        throw ArgumentError('$name must be between 1 and 2048');
      }
      return value;
    }

    final width = dimension('width', 1024);
    final height = dimension('height', 768);
    final current = preview.status(bound);
    final entrypoint = arguments['entrypoint'] ?? current.entrypoint;
    if (entrypoint is! String || entrypoint.isEmpty) {
      throw ArgumentError('entrypoint must be a project HTML path');
    }
    // Resolve before starting the renderer, preserving project/symlink bounds.
    if (!await files.exists(bound, entrypoint)) {
      throw StateError('预览文件不存在：$entrypoint');
    }
    final status = await preview.start(bound, entrypoint: entrypoint);
    final bytes = await capture(status.url!, width, height);
    return persistToolImageResult('preview.png', bytes, {
      'entrypoint': entrypoint,
      'capture': 'fresh_viewport',
      'requested_width': width,
      'requested_height': height,
    }, persist: persist);
  }
}

Future<AiToolResult> persistToolImageResult(
  String name,
  Uint8List bytes,
  Map<String, Object?> metadata, {
  required PersistToolImage persist,
}) async {
  final image = await inspectToolImage(bytes);
  if (image.firstFrame) name = '${path.basenameWithoutExtension(name)}.png';
  final attachment = await persist(name, image.mimeType, image.bytes);
  return AiToolResult(
    result: {
      'viewed': true,
      ...metadata,
      ...attachment.toJson(),
      'width': image.width,
      'height': image.height,
      if (image.firstFrame) 'frame': 0,
    },
    attachments: [
      AiAttachment(
        id: attachment.id,
        name: attachment.name,
        mimeType: image.mimeType,
        byteLength: image.bytes.length,
        base64Data: base64Encode(image.bytes),
      ),
    ],
  );
}

class ToolImage {
  const ToolImage(
    this.bytes,
    this.mimeType,
    this.width,
    this.height,
    this.firstFrame,
  );
  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;
  final bool firstFrame;
}

Future<ToolImage> inspectToolImage(Uint8List bytes) async {
  bool prefix(List<int> value) =>
      bytes.length >= value.length &&
      List.generate(value.length, (i) => bytes[i] == value[i]).every((x) => x);
  final gif = prefix(ascii.encode('GIF87a')) || prefix(ascii.encode('GIF89a'));
  final mime = prefix([137, 80, 78, 71, 13, 10, 26, 10])
      ? 'image/png'
      : prefix([255, 216, 255])
      ? 'image/jpeg'
      : prefix(ascii.encode('RIFF')) &&
            bytes.length >= 12 &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP'
      ? 'image/webp'
      : gif
      ? 'image/gif'
      : null;
  if (mime == null) {
    throw const FormatException('请提供 PNG、JPEG、WebP 或 GIF 图片；SVG/HEIC 等格式需先转换');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (!gif) {
      return ToolImage(bytes, mime, descriptor.width, descriptor.height, false);
    }
    final codec = await descriptor.instantiateCodec();
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) throw const FormatException('GIF 首帧转换失败');
        return ToolImage(
          png.buffer.asUint8List(),
          'image/png',
          descriptor.width,
          descriptor.height,
          true,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}
