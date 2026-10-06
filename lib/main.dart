/// Iron Body Gym — APK offline-first para entrenadores.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth.dart';
import 'config.dart';
import 'sync.dart';
import 'theme.dart';
import 'ui/home.dart';
import 'ui/login.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.anonKey,
  );
  await ThemeController.load();
  runApp(const IronBodyApp());
}

class IronBodyApp extends StatefulWidget {
  const IronBodyApp({super.key});
  @override
  State<IronBodyApp> createState() => _IronBodyAppState();
}

class _IronBodyAppState extends State<IronBodyApp> {
  Timer? _timer;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    // reintento de sincronización cada 60 s mientras la app está abierta
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_auth.loggedIn) SyncEngine.instance.run();
    });
    // primer intento al arrancar (si hay sesión guardada)
    Future.delayed(const Duration(seconds: 2), () {
      if (_auth.loggedIn) SyncEngine.instance.run();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (_, mode, __) => MaterialApp(
        title: 'Iron Body Gym',
        themeMode: mode,
        theme: ThemeData(
          // Colores del logo: naranja sobre grafito.
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFE8821A)),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF232323),
            foregroundColor: Colors.white,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFE8821A),
              brightness: Brightness.dark),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF141414),
            foregroundColor: Colors.white,
          ),
          useMaterial3: true,
        ),
        home: _auth.loggedIn ? const HomeScreen() : const LoginScreen(),
      ),
    );
  }
}
