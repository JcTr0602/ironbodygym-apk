/// Iron Body Gym — APK offline-first para entrenadores.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import 'acceso_bloqueo.dart';
import 'app_log.dart';
import 'auth.dart';
import 'aviso_pendientes.dart';
import 'config.dart';
import 'fotos_cola.dart';
import 'invitados.dart';
import 'localdb.dart';
import 'notificaciones_recordatorios.dart';
import 'recordatorios.dart';
import 'sync.dart';
import 'tarifa_especial.dart';
import 'fotos_foreground.dart';
import 'theme.dart';
import 'ui/capa_candado.dart';
import 'ui/componentes.dart';
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

/// v1.7.0 (panel): tras cada sync exitosa se reconcilia la
/// información pública contra el ajuste local y se reintenta
/// la republicación de lo pendiente (p. ej. el precio del App
/// Plus guardado sin red). Barata: sin pendientes marcados ni
/// ajuste local que reconciliar no llama a la red.
Future<void> _republicarInfoPublicaPendiente() async {
  try {
    await InvitadosService().republicarYReconciliarInfoPublica();
  } catch (_) {}
}

/// Gancho de fin de sync registrado en [SyncEngine]: las
/// verificaciones posteriores a un ciclo exitoso, en orden.
/// Cada una va con su propio try/catch y ninguna bloquea al
/// motor ni a la otra.
Future<void> _trasSyncExitosa() async {
  await _verificarConversionesInvitados();
  await _republicarInfoPublicaPendiente();
  // Q2 (1.20): siembra local de tarifas legacy con el espejo
  // fresco (nunca lanza; la canónica nace en el servidor y
  // baja por el espejo, esto cubre el hueco entre tanto).
  await sembrarTarifasLegacy();
  // 23/25: reprogramar avisos de recordatorios con la lista fresca
  // (nunca lanza; en el isolate de fondo el canal no existe y se
  // ignora en silencio).
  await AvisosRecordatorios.sincronizar();
}

/// Tarea en segundo plano (punto 21): sube lo pendiente aunque la app
/// esté cerrada. Todo va en try/catch: si falla, se reintenta luego.
/// 1.23 (sello de Argón): el resultado es HONESTO — si el ciclo no
/// corrió o quedaron pendientes propios, devuelve false y
/// WorkManager reintenta la tarea, en vez del «true» de siempre
/// que enterraba los fallos. Y el push ESPERA las fotos de
/// incidencias: en este isolate, el disparo sin esperar moría al
/// retornar el callback.
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
      if (!auth.loggedIn) return true;
      final res = await SyncEngine.instance
          .push(esperarIncidencias: true);
      if (!res.corrio || res.porSubir > 0 || res.conError > 0) {
        return false;
      }
      // Delta del panel: el éxito también exige las OTRAS
      // colas vacías — SyncResultado solo refleja ops_queue y
      // un fallo de fotos/comprobantes tolerado por _doPush no
      // debe disfrazarse de éxito ante WorkManager.
      final fotos = await FotosColaService.instance
          .contarPendientesReclamables();
      if (fotos > 0) return false;
      if (await LocalDb.instance.contarComprobantesPendientes() >
          0) {
        return false;
      }
      if (await LocalDb.instance
              .contarFotosIncidenciasPendientes() >
          0) {
        return false;
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
      // 1.23 (sello de Argón): update, no keep — con keep, un
      // cambio futuro de frecuencia/restricciones jamás se
      // aplicaría a la tarea ya registrada.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  } catch (_) {
    // sin segundo plano no se rompe nada: la app sincroniza al abrirse
  }
}

/// 1.23: tarea ÚNICA de subida en segundo plano. Se encola al
/// pasar la app a segundo plano con trabajo reclamable: si el
/// usuario cierra la app justo tras cobrar sin cobertura, el
/// sistema la corre en cuanto haya red, sin esperar a la
/// periódica de 1 h. appendOrReplace (sello de Argón): encolar
/// otra no duplica ni descarta la anterior a la fuerza.
Future<void> programarOneOffSyncSiPendientes() async {
  try {
    String? uid;
    try {
      uid = AuthService().userId;
    } catch (_) {}
    final conteo =
        await LocalDb.instance.conteoPendientesSync(uid);
    final ops = conteo.porSubir + conteo.conError;
    final fotos =
        await FotosColaService.instance.contarPendientesReclamables();
    if (ops == 0 && fotos == 0) return;
    await Workmanager().registerOneOffTask(
      'ironbody-sync-oneoff',
      'subirPendientes',
      constraints: Constraints(networkType: NetworkType.connected),
      // El sello dice appendOrReplace (no replace): en la API
      // Dart de workmanager 0.10 ese valor se llama `update`
      // (su doc: «maps to appendOrReplace in the native
      // implementation»).
      existingWorkPolicy: ExistingWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
    );
  } catch (_) {
    // Sin segundo plano no se rompe nada: la app sincroniza al
    // abrirse y el FGS cubre el primer plano.
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
      // B6/H-04: helper único sobre el messenger capturado de
      // la raíz (limpia la cola y aplica la gramática).
      final messenger = ScaffoldMessenger.of(ctx);
      mostrarSnack(ctx, 'Tu sesión venció. Entra de nuevo.',
          significado: SignificadoChip.alerta,
          messengerState: messenger);
    }
  };
  // v1.5.0 (Bloque G): confirmación automática de conversiones
  // de invitados tras cada sync exitosa (ver SyncEngine).
  // v1.7.0: el mismo gancho reintenta la republicación de la
  // información pública pendiente.
  SyncEngine.instance.onSyncExitoso = _trasSyncExitosa;
  // v1.3.1 (B4): inicializar servicio foreground de fotos.
  initForegroundFotos();
  // 1.23 (sync en 2º plano): el motor arranca el FGS por este
  // gancho al inicio de cada push() (sello de Argón).
  SyncEngine.instance.onArrancarSegundoPlano =
      iniciarSubidaFotosForeground;
  // v1.3.4 (item 3): poda diaria de ops aplicadas viejas en
  // background, guardada por fecha (meta 'ultima_poda_ops');
  // no bloquea el arranque.
  unawaited(LocalDb.instance.podaOpsDiariaSiToca());
  // Q2 (1.20): siembra local de tarifas legacy desde el espejo
  // ya guardado, para que un cobro offline justo tras
  // actualizar la app ya vea las filas seed_legacy_<id>
  // (nunca lanza; también corre tras cada sync exitosa).
  unawaited(sembrarTarifasLegacy());
  // 1.22 R-7: las mutaciones de recordatorios (crear, pausar,
  // eliminar, disparar) re-sincronizan los avisos al momento
  // vía este gancho (sin él, pausar a las 07:50 no cancelaba
  // la alarma de las 08:00 hasta el próximo sync o reinicio).
  ganchoSincronizarAvisos = AvisosRecordatorios.sincronizar;
  // 23/25: programar avisos de recordatorios de hoy (sin sesión
  // no hace nada; tras cada sync se reprograma con lista fresca).
  unawaited(AvisosRecordatorios.sincronizar());
  // 1.21: candado de acceso — evalúa el espejo al arrancar y lo
  // reevalúa tras cada sync y cada cambio de sesión.
  AccesoBloqueoService.instance.iniciar();
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
      // 1.23: al salir, si queda trabajo reclamable, se deja
      // encolada la tarea única de WorkManager (la red la
      // dispara en cuanto vuelve, sin esperar a la periódica).
      if (_auth.loggedIn) {
        unawaited(programarOneOffSyncSiPendientes());
      }
    } else if (state == AppLifecycleState.resumed) {
      _iniciarTimers();
      // v1.5.0 (Bloque G): al volver a primer plano se verifican
      // las conversiones pendientes aunque el ciclo de sync aún
      // no haya corrido (barato: sin conversiones en curso no
      // toca la red).
      if (_auth.loggedIn) {
        unawaited(_verificarConversionesInvitados());
        // 1.23 (pieza que faltaba, sello de Argón): push
        // INMEDIATO al volver si hay reclamables — antes solo
        // se rearmaban los timers y lo pendiente podía esperar
        // hasta 60 min con la app abierta.
        unawaited(_pushSiReclamablesAlVolver());
        // 1.23: el aviso de pendientes que el cortacircuitos
        // del FGS hubiera dejado marcado se muestra ahora.
        unawaited(AvisoPendientesSync.mostrarSiPendiente());
      }
    }
  }

  /// Push inmediato al volver a primer plano cuando hay
  /// trabajo reclamable (ops por subir o fotos reclamables).
  /// Sin reclamables no toca la red: el pull de 2 min y el
  /// push horario cubren el resto.
  Future<void> _pushSiReclamablesAlVolver() async {
    try {
      String? uid;
      try {
        uid = _auth.userId;
      } catch (_) {}
      final conteo =
          await LocalDb.instance.conteoPendientesSync(uid);
      final ops = conteo.porSubir + conteo.conError;
      final fotos = await FotosColaService.instance
          .contarPendientesReclamables();
      if (ops == 0 && fotos == 0) return;
      await SyncEngine.instance.push();
    } catch (_) {}
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
              final app = MediaQuery(
                data: mq.copyWith(
                  textScaler: TextScaler.linear(escala * sistema),
                ),
                child: child!,
              );
              // 1.21: la capa del candado va sobre el Navigator
              // entero (cubre también diálogos y pantallas
              // apiladas) sin tocar la sesión ni la cola.
              return ValueListenableBuilder<BloqueoVigente?>(
                valueListenable: AccesoBloqueoService.instance.vigente,
                builder: (_, bloqueo, __) {
                  if (bloqueo == null) return app;
                  return Stack(
                    children: [
                      app,
                      Positioned.fill(child: CapaCandado(bloqueo: bloqueo)),
                    ],
                  );
                },
              );
            },
            navigatorKey: navigatorKey,
            // 1.23 T8: scroll con inercia natural y rebote
            // suave en toda la app (ver componentes.dart).
            scrollBehavior: const ComportamientoScrollSuave(),
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
