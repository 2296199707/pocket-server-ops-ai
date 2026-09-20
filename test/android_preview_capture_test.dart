import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/platform/android_preview_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preview capture sends the viewport request and returns PNG bytes',
    () async {
      const channel = MethodChannel('mobile_agent/preview_capture');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? received;
      final png = Uint8List.fromList(<int>[137, 80, 78, 71]);

      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return png;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final bytes = await AndroidPreviewCapture(channel: channel).capture(
        url: 'http://127.0.0.1:4321/index.html',
        width: 800,
        height: 600,
      );

      expect(received?.method, 'capture');
      expect(received?.arguments, <String, Object>{
        'url': 'http://127.0.0.1:4321/index.html',
        'width': 800,
        'height': 600,
      });
      expect(bytes, png);
    },
  );
}
