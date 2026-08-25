import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String ref) => _storage.read(key: ref);

  @override
  Future<void> write(String ref, String value) {
    return _storage.write(key: ref, value: value);
  }

  @override
  Future<void> delete(String ref) => _storage.delete(key: ref);
}
