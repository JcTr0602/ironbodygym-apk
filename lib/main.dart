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
import 'ui/diseno.dart';
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
        publishableKey: AppConfig.anonKey,
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
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {
    // sin segundo plano no se rompe nada: la app sincroniza al abrirse
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.anonKey,
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
      builder: (_, mode, __) =>
          ValueListenableBuilder<double>(
        valueListenable: ThemeController.fontScale,
        builder: (_, escala, __) => MaterialApp(
          builder: (ctx, child) {
            final mq = MediaQuery.of(ctx);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(escala),
              ),
              child: child!,
            );
          },
        navigatorKey: navigatorKey,
        title: 'Iron Body Gym',
        themeMode: mode,
        theme: ThemeData(
          // v1.1: sistema de diseño centralizado (lib/ui/diseno.dart).
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColores.naranja,
            surface: AppColores.superficieClaro,
          ),
          scaffoldBackgroundColor: AppColores.fondoClaro,
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColores.carbon,
            foregroundColor: Colors.white,
          ),
          cardTheme: CardThemeData(
            color: AppColores.superficieClaro,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.lg),
              side: const BorderSide(
                  color: AppColores.bordeClaro),
            ),
            elevation: 2,
          ),
          dialogTheme: DialogThemeData(
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.xl),
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.lg),
              ),
              textStyle: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColores.naranja,
              side: const BorderSide(
                  color: AppColores.naranja, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.lg),
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
              borderSide: const BorderSide(
                  color: AppColores.naranja, width: 2),
            ),
          ),
          textTheme: const TextTheme(
            displayLarge: AppTexto.display,
            displayMedium: AppTexto.displayPequeno,
            titleLarge: AppTexto.titulo,
            titleMedium: AppTexto.subtitulo,
            bodyLarge: AppTexto.cuerpo,
            bodyMedium: AppTexto.secundario,
            labelLarge: AppTexto.etiqueta,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColores.naranja,
            brightness: Brightness.dark,
            surface: AppColores.superficieOscuro,
          ),
          scaffoldBackgroundColor: AppColores.fondoOscuro,
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColores.carbonProfundo,
            foregroundColor: Colors.white,
          ),
          cardTheme: CardThemeData(
            color: AppColores.superficieOscuro,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.lg),
              side: const BorderSide(
                  color: AppColores.bordeOscuro),
            ),
            elevation: 2,
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: AppColores.superficieOscuro,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.xl),
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.lg),
              ),
              textStyle: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColores.naranja,
              side: const BorderSide(
                  color: AppColores.naranja, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.lg),
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
              borderSide: const BorderSide(
                  color: AppColores.naranja, width: 2),
            ),
          ),
          textTheme: const TextTheme(
            displayLarge: AppTexto.display,
            displayMedium: AppTexto.displayPequeno,
            titleLarge: AppTexto.titulo,
            titleMedium: AppTexto.subtitulo,
            bodyLarge: AppTexto.cuerpo,
            bodyMedium: AppTexto.secundario,
            labelLarge: AppTexto.etiqueta,
          ),
          useMaterial3: true,
        ),
        home: FutureBuilder<Widget>(
          future: _auth.loggedIn
              ? Future.value(const HomeScreen())
              : Future.value(const LoginScreen()),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return snap.data!;
          },
        ),
        ),
      ),
    );
  }
}
