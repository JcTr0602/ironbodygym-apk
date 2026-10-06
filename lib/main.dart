/// Iron Body Gym — APK offline-first para entrenadores.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import 'auth.dart';
import 'config.dart';
import 'sync.dart';
import 'theme.dart';
import 'ui/home.dart';
import 'ui/login.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// Tarea en segundo plano (punto 21): sube lo pendiente aunque la app
/// esté cerrada. Todo va en try/catch: si falla, se reintenta luego.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.anonKey,
      );
      final auth = AuthService();
      if (auth.loggedIn) {
        await SyncEngine.instance.push();
      }
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> _programarSubidaFondo() async {
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'ironbody-sync-fondo',
      'subirPendientes',
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  } catch (_) {
    // sin segundo plano no se rompe nada: la app sincroniza al abrirse
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.anonKey,
  );
  await ThemeController.load();
  // Subida en segundo plano (punto 21): aunque cierren la app.
  await _programarSubidaFondo();
  // Sesión vencida -> volver al login con aviso.
  SyncEngine.instance.onSessionExpired = () {
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => const LoginScreen(
              aviso: 'Tu sesión venció. Entra de nuevo.')),
      (_) => false,
    );
  };
  runApp(const IronBodyApp());
}

class IronBodyApp extends StatefulWidget {
  const IronBodyApp({super.key});
  @override
  State<IronBodyApp> createState() => _IronBodyAppState();
}

class _IronBodyAppState extends State<IronBodyApp> {
  Timer? _pullTimer;
  Timer? _pushTimer;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    // Pull frecuente: ver cambios de otros entrenadores (cada 2 min).
    _pullTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_auth.loggedIn) SyncEngine.instance.pull();
    });
    // Push: subir cambios propios cada hora o manual.
    _pushTimer = Timer.periodic(const Duration(minutes: 60), (_) {
      if (_auth.loggedIn) SyncEngine.instance.push();
    });
    // primer intento al arrancar (si hay sesión guardada)
    Future.delayed(const Duration(seconds: 2), () {
      if (_auth.loggedIn) SyncEngine.instance.run();
    });
  }

  @override
  void dispose() {
    _pullTimer?.cancel();
    _pushTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (_, mode, __) => MaterialApp(
        navigatorKey: navigatorKey,
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
