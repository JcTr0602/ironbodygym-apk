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
import 'invitados.dart';
import 'localdb.dart';
import 'sync.dart';
import 'fotos_foreground.dart';
import 'theme.dart';
import 'ui/diseno.dart';
import 'ui/home.dart';
import 'ui/login.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// v1.5.0 (Bloque G): gancho de fin de sync — tras cada push/pull
/// exitoso se verifican las conversiones de invitados cuya op
/// `inscribir` ya subió, para confirmarlas en Supabase SIN
/// esperar a que alguien abra la bandeja. La verificación es
/// barata: sin conversiones en curso no llama a la red.
Future<void> _verificarConversionesInvitados() async {
  try {
    await InvitadosService().verificarConversiones();
  } catch (_) {}
}

/// v1.7.0 (panel): tras cada sync exitosa se reintenta la
/// republicación de la información pública pendiente (p. ej.
/// el precio del App Plus guardado sin red). Barata: sin
/// pendientes marcados en meta no llama a la red.
Future<void> _republicarInfoPublicaPendiente() async {
  try {
    await InvitadosService().republicarInfoPublicaPendiente();
  } catch (_) {}
}

/// Gancho de fin de sync registrado en [SyncEngine]: las
/// verificaciones posteriores a un ciclo exitoso, en orden.
/// Cada una va con su propio try/catch y ninguna bloquea al
/// motor ni a la otra.
Future<void> _trasSyncExitosa() async {
  await _verificarConversionesInvitados();
  await _republicarInfoPublicaPendiente();
}

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
      SyncEngine.instance.onSyncExitoso = _trasSyncExitosa;
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
  // Sesión vencida -> volver al login con aviso. v1.4.4: la raíz
  // (RaizSesion) ya vuelve a Login sola al desaparecer la sesión;
  // aquí solo se repliegan las pantallas apiladas y se avisa.
  SyncEngine.instance.onSessionExpired = () {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
          content: Text('Tu sesión venció. Entra de nuevo.')));
    }
  };
  // v1.5.0 (Bloque G): confirmación automática de conversiones
  // de invitados tras cada sync exitosa (ver SyncEngine).
  // v1.7.0: el mismo gancho reintenta la republicación de la
  // información pública pendiente.
  SyncEngine.instance.onSyncExitoso = _trasSyncExitosa;
  // v1.3.1 (B4): inicializar servicio foreground de fotos.
  initForegroundFotos();
  // v1.3.4 (item 3): poda diaria de ops aplicadas viejas en
  // background, guardada por fecha (meta 'ultima_poda_ops');
  // no bloquea el arranque.
  unawaited(LocalDb.instance.podaOpsDiariaSiToca());
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
      // v1.5.0 (Bloque G): al volver a primer plano se verifican
      // las conversiones pendientes aunque el ciclo de sync aún
      // no haya corrido (barato: sin conversiones en curso no
      // toca la red).
      if (_auth.loggedIn) {
        unawaited(_verificarConversionesInvitados());
      }
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
            title: 'Iron Body Gestión',
            themeMode: mode,
            // v1.2.4: tema unificado (lib/ui/diseno.dart → AppTema).
            theme: AppTema.claro(),
            darkTheme: AppTema.oscuro(),
            // v1.2.5 (3.4): alto contraste (WCAG AA).
            highContrastTheme:
                hc ? AppTema.claroAltoContraste() : null,
            highContrastDarkTheme:
                hc ? AppTema.oscuroAltoContraste() : null,
            home: const RaizSesion(),
          ),
        ),
      ),
    );
  }
}

/// v1.4.4: raíz reactiva a la sesión. Antes la raíz decidía
/// Inicio/Login UNA sola vez (un FutureBuilder al arrancar): cerrar
/// sesión mataba la sesión en el servidor, pero la app seguía
/// abierta y usable en local hasta reiniciarla — una suspensión
/// real no expulsaba a nadie y el diálogo de suspendido lo
/// comprobó Jc en campo. Ahora la raíz escucha los cambios de
/// sesión: si la sesión desaparece (cierre manual, suspensión o
/// vencimiento), vuelve a Login al momento; si aparece, entra a
/// Inicio. Los refrescos de token NO reconstruyen nada (la sesión
/// sigue existiendo: solo se reacciona al cambio de presencia).
class RaizSesion extends StatefulWidget {
  const RaizSesion({super.key});

  @override
  State<RaizSesion> createState() => _RaizSesionState();
}

class _RaizSesionState extends State<RaizSesion> {
  bool _logueado = AuthService().loggedIn;
  StreamSubscription<AuthState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      final hay = s.session != null;
      if (hay != _logueado && mounted) {
        setState(() => _logueado = hay);
        // Panel v1.4.4: al PERDER la sesión hay que replegar la
        // pila entera hasta la raíz. Cambiar solo el contenido de
        // la ruta raíz dejaba vivas las pantallas apiladas encima
        // (una ficha, un pago) sobre el Login.
        if (!hay) {
          navigatorKey.currentState?.popUntil((r) => r.isFirst);
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _logueado ? const HomeScreen() : const LoginScreen();
}
