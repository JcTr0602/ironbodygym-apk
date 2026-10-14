/// Iron Body Gym — APK offline-first para entrenadores.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import 'app_log.dart';
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
  // v1.3.0 (AppLog v2.0, Gemini #3): interceptores globales.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLog.critico('ui', 'flutter_uncaught',
        contexto: {
          'libreria': '${details.library}',
          'resumen': details.summary.toString(),
        },
        stack: details.stack);
  };
  // v1.3.1 (AppLog v3.0): PlatformDispatcher lo maneja AppLog.init().
  // v1.3.1 (AppLog v3.0, Argón Fix A): init DESPUÉS de los handlers
  // de main.dart, para que el encadenamiento de _instalarManejadores()
  // los envuelva en lugar de ser sobrescrito por ellos.
  await AppLog.init();
  // v1.3.0 (Gemini #4): verificar cierre anormal previo.
  await CentinelaApp.verificarArranque();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.anonKey,
  );
  // v1.2.9+46 (AppLog): arranque con versión para forense.
  AppLog.info('app', 'inicio', d: 'IronBody Gym ${AppConfig.appVersion}');
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

class _IronBodyAppState extends State<IronBodyApp>
    with WidgetsBindingObserver {
  Timer? _pullTimer;
  Timer? _pushTimer;
  Timer? _inicioTimer;
  final _auth = AuthService();

  void _iniciarTimers() {
    _pullTimer ??= Timer.periodic(const Duration(minutes: 2), (_) {
      if (_auth.loggedIn) SyncEngine.instance.pull();
    });
    _pushTimer ??= Timer.periodic(const Duration(minutes: 60), (_) {
      if (_auth.loggedIn) SyncEngine.instance.push();
    });
  }

  void _detenerTimers() {
    _pullTimer?.cancel();
    _pullTimer = null;
    _pushTimer?.cancel();
    _pushTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _detenerTimers();
    } else if (state == AppLifecycleState.resumed) {
      _iniciarTimers();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pull frecuente: ver cambios de otros entrenadores (cada 2 min).
    // Push: subir cambios propios cada hora o manual.
    _iniciarTimers();
    // primer intento al arrancar (si hay sesión guardada)
    _inicioTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_auth.loggedIn) SyncEngine.instance.run();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detenerTimers();
    _inicioTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (_, mode, __) => ValueListenableBuilder<double>(
        valueListenable: ThemeController.fontScale,
        builder: (_, escala, __) => ValueListenableBuilder<bool>(
          valueListenable: ThemeController.altoContraste,
          builder: (_, hc, __) => MaterialApp(
            builder: (ctx, child) {
              final mq = MediaQuery.of(ctx);
              // La escala de la app se multiplica por la de accesibilidad
              // del sistema, en vez de reemplazarla.
              final sistema = mq.textScaler.scale(1.0);
              return MediaQuery(
                data: mq.copyWith(
                  textScaler: TextScaler.linear(escala * sistema),
                ),
                child: child!,
              );
            },
            navigatorKey: navigatorKey,
            title: 'Iron Body Gym',
            themeMode: mode,
            // v1.2.4: tema unificado (lib/ui/diseno.dart → AppTema).
            theme: AppTema.claro(),
            darkTheme: AppTema.oscuro(),
            // v1.2.5 (3.4): alto contraste (WCAG AA).
            highContrastTheme:
                hc ? AppTema.claroAltoContraste() : null,
            highContrastDarkTheme:
                hc ? AppTema.oscuroAltoContraste() : null,
            home: FutureBuilder<Widget>(
              future: _auth.loggedIn
                  ? Future.value(const HomeScreen())
                  : Future.value(const LoginScreen()),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Scaffold(
                    body: Center(
                        child: CircularProgressIndicator()),
                  );
                }
                return snap.data!;
              },
            ),
          ),
        ),
      ),
    );
  }
}
