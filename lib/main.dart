import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'credentials/credential_store.dart';
import 'credentials/secure_credential_store.dart';
import 'storage/app_database.dart';
import 'storage/memory_app_database.dart';
import 'ui/home_shell.dart';

const _previewMode = bool.fromEnvironment('PREVIEW_MODE');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AppController(
      database: _previewMode
          ? MemoryAppDatabase(demoData: true)
          : AppDatabase(),
      credentials: _previewMode
          ? MemoryCredentialStore()
          : SecureCredentialStore(),
      previewMode: _previewMode,
    );
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketServerOps AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoSansSC',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
      ),
      home: HomeShell(controller: _controller),
    );
  }
}
