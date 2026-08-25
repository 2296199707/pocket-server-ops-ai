abstract class CredentialStore {
  // This boundary is for SSH and provider configuration layers only.
  Future<String?> read(String ref);

  Future<void> write(String ref, String value);

  Future<void> delete(String ref);
}

// Test-only implementation. Production code should use platform secure storage.
class MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String ref) async => _values[ref];

  @override
  Future<void> write(String ref, String value) async {
    _values[ref] = value;
  }

  @override
  Future<void> delete(String ref) async {
    _values.remove(ref);
  }
}
