import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/local/local_file_access.dart';

void main() {
  test('canonical scope checks handle parents, root, and similar prefixes', () {
    expect(
      LocalFileAccessStore.scopesOverlapCanonical(
        '/data/user/0/app',
        '/data/user/0',
      ),
      isTrue,
    );
    expect(
      LocalFileAccessStore.scopesOverlapCanonical('/data/user/0', '/'),
      isTrue,
    );
    expect(
      LocalFileAccessStore.scopesOverlapCanonical(
        '/data/user/0/app2',
        '/data/user/0/app',
      ),
      isFalse,
    );
  });

  test(
    'canonical path checks prevent a symlink from leaving the grant',
    () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final root = Directory('/www/mobile-agent-local-root-$suffix');
      final outside = Directory('/www/mobile-agent-local-outside-$suffix');
      await root.create(recursive: true);
      await outside.create(recursive: true);
      await File('${root.path}/inside.txt').writeAsString('inside');
      await File('${outside.path}/secret.txt').writeAsString('secret');
      await Link('${root.path}/link').create(outside.path);

      try {
        final access = LocalFileAccessStore();
        await access.add(root.path, canWrite: false);

        expect(
          await access.resolve('${root.path}/inside.txt'),
          endsWith('inside.txt'),
        );
        await expectLater(
          access.resolve('${root.path}/link/secret.txt'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          access.resolve(outside.path),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          access.resolve('${root.path}/inside.txt', write: true),
          throwsA(isA<StateError>()),
        );
        await access.add(root.path, canWrite: true);
        expect(
          await access.resolve('${root.path}/inside.txt', write: true),
          endsWith('inside.txt'),
        );
      } finally {
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      }
    },
  );
}
