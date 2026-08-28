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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final colorScheme =
            ColorScheme.fromSeed(
              seedColor: const Color(0xFF007AFF),
              brightness: Brightness.light,
            ).copyWith(
              primary: const Color(0xFF007AFF),
              onPrimary: Colors.white,
              primaryContainer: const Color(0xFFDCEBFF),
              onPrimaryContainer: const Color(0xFF00234D),
              secondary: const Color(0xFF5856D6),
              onSecondary: Colors.white,
              tertiary: const Color(0xFFFF9500),
              onTertiary: Colors.white,
              error: const Color(0xFFFF3B30),
              surface: const Color(0xFFF2F2F7),
              surfaceContainerLowest: const Color(0xFFF2F2F7),
              surfaceContainerLow: Colors.white,
              surfaceContainer: const Color(0xFFF7F7F9),
              surfaceContainerHigh: const Color(0xFFEFEFF3),
              surfaceContainerHighest: const Color(0xFFE5E5EA),
              outline: const Color(0xFFC7C7CC),
              outlineVariant: const Color(0xFFD1D1D6),
            );
        final baseTheme = ThemeData(
          useMaterial3: true,
          fontFamily: 'NotoSansSC',
          colorScheme: colorScheme,
          scaffoldBackgroundColor: colorScheme.surface,
          appBarTheme: AppBarTheme(
            backgroundColor: colorScheme.surface,
            foregroundColor: colorScheme.onSurface,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            titleSpacing: 16,
            titleTextStyle: TextStyle(
              fontFamily: 'NotoSansSC',
              color: colorScheme.onSurface,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          dividerTheme: DividerThemeData(
            color: colorScheme.outlineVariant.withValues(alpha: 0.55),
            thickness: 0.6,
            space: 1,
          ),
          cardTheme: CardThemeData(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: colorScheme.surfaceContainerHighest,
            selectedColor: colorScheme.primaryContainer,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            labelStyle: const TextStyle(fontSize: 13),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          listTileTheme: ListTileThemeData(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            iconColor: colorScheme.onSurfaceVariant,
            selectedColor: colorScheme.primary,
            selectedTileColor: colorScheme.primary.withValues(alpha: 0.1),
          ),
          drawerTheme: DrawerThemeData(
            backgroundColor: colorScheme.surface,
            surfaceTintColor: Colors.transparent,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
            ),
          ),
          bottomSheetTheme: BottomSheetThemeData(
            backgroundColor: Colors.white,
            modalBackgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            showDragHandle: true,
            dragHandleColor: colorScheme.outline,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          popupMenuTheme: PopupMenuThemeData(
            color: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
        return MaterialApp(
          title: 'PocketServerOps AI',
          debugShowCheckedModeBanner: false,
          theme: baseTheme.copyWith(
            textTheme: baseTheme.textTheme.apply(
              fontSizeFactor: _controller.fontScale,
            ),
          ),
          home: HomeShell(controller: _controller),
        );
      },
    );
  }
}
