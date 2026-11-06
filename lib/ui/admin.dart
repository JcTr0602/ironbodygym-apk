/// Administración (solo admin) — Panel del dueño desde v1.6.0.
///
/// Consola del dueño: pendientes con acción, acciones rápidas de caja,
/// resumen del mes y los módulos de siempre (estadísticas, montos,
/// usuarios APK, pendiente a entrega, gastos, cierre de caja, papelera
/// y exportar). Todo funciona offline: los cambios se encolan y suben
/// al sincronizar.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../auth.dart';
import '../config.dart' show AppConfig;
import '../bloque2_resto.dart';
import '../cliente_protegido.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../plus_reportes.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../nomina_foto.dart';
import '../perfil.dart';
import '../permisos_entrenador.dart';
import 'dialogo_gasto.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'config_precios_bancarios.dart';
import 'panel_dueno_swr.dart';
import 'panel_dueno_atencion.dart';
import 'bandeja_whatsapp.dart';
import 'ficha.dart';
import 'panel_buscador.dart';
import 'hub_comunicacion.dart';
import 'centro_control.dart';
import 'actividad.dart';
import 'buscar.dart';
import 'admin_secciones.dart';
import 'cola.dart';
import 'arqueo.dart';
import 'guia.dart';
import 'auditoria.dart';
import 'auditoria_persona.dart';
import 'categorias_suplemento.dart';
import 'cuentas_por_cobrar.dart';
import 'por_cobrar.dart';
import 'historial_ventas.dart';
import 'auditoria_silenciosa.dart';
import 'nomina.dart';
import 'horario_gym.dart';
import 'riesgo.dart';
import 'papelera.dart';
import 'congelados.dart';
import 'control_acceso.dart';
import 'turnos_hub.dart';
import 'comparativa_mensual.dart';
import 'pagaron_mes.dart';
import 'pagos_por_metodo.dart';
import 'incidencias/lista_incidencias.dart';
import 'historial_caja.dart';
import 'app_bar.dart';
import 'invitados.dart';
import 'solicitudes_adelanto.dart';
import 'avisos_entrenador.dart';
import 'editor_avisos_clientes.dart';
import 'editor_rutinas_gym.dart';
import 'bandeja.dart';
import 'exportar_excel.dart';
import 'incidencias_sync.dart';
import 'pago.dart';
import 'reportes_plus.dart';
import 'reservas.dart';
import 'suplementos.dart';
import 'widgets.dart';
import 'mi_dia.dart';
import 'dashboard.dart';
import 'panel_bloque2.dart';
import 'panel_candado.dart';
import 'panel_permisos.dart';
import 'panel_resto_caja.dart';
import 'panel_premios.dart';
import 'panel_comunidad.dart';
import 'panel_premios_hub.dart';
import 'panel_resto_config.dart';
import 'panel_resto_sistema.dart';
import 'recordatorios.dart';
import 'centro_compras.dart';
import 'plantillas_mensaje.dart';
import 'tarifas_especiales.dart';
import 'usuarios.dart';
import 'servicios_admin.dart';
import 'cumpleanos.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  double _ingresos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _gastos = [];
  Map<String, double> _caja = {'efectivo': 0, 'transferencia': 0};
  double _gastosHoy = 0;
  final Map<String, TextEditingController> _montos = {};
  // v1.2.4: datos bancarios (strings, no montos)
  final Map<String, TextEditingController> _bancarios = {};
  bool _cargando = true;
  // Panel delta Luna ALTO: doble toque en «Recogida» abría dos
  // diálogos y podía registrar la misma recogida dos veces.
  bool _recogidaEnCurso = false;
  // Ronda 17 M2-H2: candado contra doble toque en las acciones
  // que encolan operaciones (un segundo toque generaría una
  // segunda op con otro UUID: gasto o entrega duplicados).
  bool _operacionEnCurso = false;
  // Salud del sistema
  SyncDetalle _syncDet = const SyncDetalle();
  int _pendientesSubir = 0;

  // Panel del dueño (v1.6.0): datos de los bloques nuevos.
  int _pagosMes = 0;
  // 1.23 (B3 Paso 3b): neto de nómina del mes (foto compartida
  // con la pantalla de Nómina). null = sin foto: la línea del
  // hub pinta «-- CUP», nunca un 0 inventado (regla de Argón).
  double? _netoNominaMes;
  int _clientesActivos = 0;
  // 1.25 Panel 7: comparación contra el mes pasado y
  // mini-tendencia de 7 días (solo la carga completa los
  // trae; la recarga ligera de contadores no los toca).
  double? _ingresosMesAnt;
  // 1.25 Panel 10: precios C6 sin fijar (badge del módulo
  // de Precios); solo la carga completa lo calcula.
  int _preciosSinFijar = 0;
  int? _pagosMesAnt;
  List<Map<String, dynamic>> _serie7Panel = const [];
  List<Map<String, dynamic>> _reservasSolicitadas = [];
  Map<String, String> _nombreSupl = {};
  List<Map<String, dynamic>> _stockCritico = [];
  List<String> _sinReporteAyer = [];
  List<String> _sinReporteHoy = [];
  int _incidenciasPend = 0;
  // 1.25 T97: nombres de los que vencen hoy (bandeja única).
  List<String> _vencenHoyNombres = [];
  // Solicitudes de inscripción de invitados por atender (del
  // servicio de Invitados). 1.23 (B3): estado SWR — la RPC no
  // bloquea el pintado (panel 1.6.0) y un fallo ya NO vacía la
  // bandeja: se conserva el último payload bueno con su sello
  // (ver panel_dueno_swr.dart).
  final _swrSolicitudes =
      BandejaSwr<invitados_svc.InvitadoResumen>();
  int _solicitudesGen = 0;
  // 1.14 (rediseño): el bloque de atención muestra 5 alertas y
  // despliega el resto (hasta 9) al tocar «Ver más».
  bool _atencionExpandida = false;
  // G2 (v1.7.0): reportes App Plus pendientes (misma pauta de dos
  // fases que las solicitudes: la RPC no bloquea el pintado; si
  // falla, la fila no aparece) y contador de Cuentas a la Casa
  // (consulta local al espejo, en el pase principal).
  final _swrReportes = BandejaSwr<ReportePlus>();
  int _reportesPlusGen = 0;
  int _cuentasCasa = 0;
  final PlusReportesService _plusSvc = PlusReportesService();

  List<TipoPago> _tipos = [];
  // v1.3.1: pago por cliente a entrenadores (movido desde Ajustes, solo dueño).
  int _pagoEntrenador = 150;

  // 1.23 (B3 Paso 3a): las claves de monto viven en
  // config_precios_bancarios.dart (clavesMontoConfig), única
  // definición compartida con la pantalla de ajustes.

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _montos.values) {
      c.dispose();
    }
    for (final c in _bancarios.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 1.24 Bloque 5 (B-01): el pull-to-refresh del Panel corre
  /// un ciclo de sync real y DESPUÉS relee; el aviso es veraz
  /// (si el ciclo no corrió o falló, se dice, no se finge).
  Future<void> _actualizarPanel() async {
    final res = await SyncEngine.instance.run();
    await _cargar();
    if (!mounted) return;
    if (!res.corrio) {
      mostrarSnack(context, res.resumenCorto,
          significado: SignificadoChip.alerta);
    } else if (res.error != null) {
      mostrarSnack(context, 'Sin conexión: mostrando datos locales',
          significado: SignificadoChip.alerta);
    }
  }

  Future<void> _cargar() async {
    // Ronda 17 M2-H1 (defensa en profundidad): sin dueño no
    // se cargan los KPIs financieros aunque se invoque directo.
    if (!AuthService().isOwner) return;
    final ing = await ingresosMes();
    // 1.23 (Delta Argón 4ª#3): derivaciones en memoria en vez
    // de re-escanear espejos enteros por cifra:
    // - inscripcionesMes = suma de inscripcionesPorEntrenador
    //   (ambas cuentan clientes no eliminados con
    //   fecha_inscripcion del mes actual).
    // - morosos y activos salen de resumenActivosMorosos (una
    //   sola lectura del padrón activo).
    final resumenAct = await resumenActivosMorosos();
    final pend = await pendientePorEntrenador();
    // 1.25 T40: inscripciones del mes y morosos ya no se
    // calculan aquí: solo alimentaban el resumen fino que
    // Ingresos dejó de abrir (el Dashboard trae los suyos).
    final gastos = await gastosTodos();
    final caja = await cobradoHoyPorMetodo();
    final hoy = ahoraHabana();
    final hoyIso = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    // - gastosDe(hoy) derivado de la lista ya cargada por
    //   gastosTodos (espejo + pendientes ya fusionados), con
    //   el mismo predicado fila a fila (fechaNegocioHabana).
    final gh = gastos
        .where((g) =>
            '${g['fecha'] ?? ''}'.length >= 10 &&
            fechaNegocioHabana(g['fecha']) == hoyIso)
        .fold<double>(
            0, (s, g) => s + ((g['monto'] as num?)?.toDouble() ?? 0));
    final aj = await LocalDb.instance.getAjustes();
    // 1.25 Panel 10: decisiones pendientes del módulo de
    // Precios = claves C6 sin valor válido.
    final preciosSinFijar = clavesPrecioSinFijar(aj).length;
    final tipos = await getTiposPago(soloActivos: false);
    final pagoEnt = await PerfilService.instance.getPagoEntrenador();
    // Salud del sistema
    final det = await SyncEngine.instance.detalle();
    final pendSubir = await LocalDb.instance.countPendingOps();
    // Panel del dueño (v1.6.0): KPIs del mes y pendientes reales,
    // todos de fuentes existentes (sin cifras inventadas).
    // Panel 1.6.0 (decisión de Jc): el KPI «Pagos este mes» usa la
    // definición del dueño — la MISMA de Home y de la lista
    // (NominaCalc: descuenta a quien vence dentro del propio mes).
    // pagosRealizadosMes() conserva su sentido contable en sus
    // otros usos; aquí no se usa.
    final pagosMes = await NominaCalc.clientesQuePagaronElMes(
        NominaCalc.prefMesActual());
    // 1.25 Panel 7: las cifras de comparación del mes pasado
    // y la serie de 7 días de la mini-tendencia.
    final ingAnt = await ingresosMesAnterior();
    final pagosMesAnt = await NominaCalc.clientesQuePagaronElMes(
        NominaCalc.prefMesAnterior());
    final serie7Panel = await ingresosUltimos7Dias();
    final activos = resumenAct.activos; // 4ª#3: de la lectura única
    final fotoRS = await _fotoReservasStock();
    final solicitadas = fotoRS.solicitadas;
    final nombreSupl = fotoRS.nombreSupl;
    final criticos = fotoRS.criticos;
    final hoyH = ahoraHabana();
    String isoDia(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final sinHoy = await turnosSinReporte(isoDia(hoyH));
    final sinAyer = await turnosSinReporte(
        isoDia(hoyH.subtract(const Duration(days: 1))));
    // 1.25 T97: los que vencen hoy, para la bandeja única.
    final vencen = await vencenHoy();
    final incidencias = await incidenciasSyncPendientes();
    // v1.7.0: contador de Cuentas a la Casa (consulta local).
    final casa = await LocalDb.instance.conteoCuentasCasa();
    // 1.23 (B3 Paso 3b): neto de nómina del mes desde la foto
    // compartida (nomina_foto.dart — la misma que arma la
    // pantalla de Nómina). Si la foto falla o aún no hay
    // entrenadores en usuarios_apk, queda null y la línea del
    // hub pinta «-- CUP» (regla de Argón: nunca un 0 inventado).
    double? netoNomina;
    try {
      final prefNom = NominaCalc.prefMesActual();
      final fotoNom = await fotoNominaMes(prefNom);
      final bonosNom =
          await leerBonosMesConMigracion(prefNom);
      netoNomina = netoTotalDueno(fotoNom,
          clientesPagados: pagosMes, bonos: bonosNom);
    } catch (_) {
      netoNomina = null;
    }
    // Solicitudes de invitados: la bandeja vive en el servidor y
    // su RPC ya NO se espera aquí (panel 1.6.0): con la red
    // colgada, esperar en serie retrasaba TODO el panel aunque
    // los datos locales ya estaban listos. Se pinta primero y la
    // fila se rellena cuando la RPC resuelve (_cargarSolicitudes
    // Invitados); si la RPC falla, la fila no aparece, como antes.
    if (mounted) {
      setState(() {
        _ingresos = ing;
        _pend = pend;
        _gastos = gastos;
        _caja = caja;
        _gastosHoy = gh;
        _syncDet = det;
        _pendientesSubir = pendSubir;
        _pagosMes = pagosMes;
        _ingresosMesAnt = ingAnt;
        _preciosSinFijar = preciosSinFijar;
        _pagosMesAnt = pagosMesAnt;
        _serie7Panel = serie7Panel;
        _netoNominaMes = netoNomina;
        _clientesActivos = activos;
        _reservasSolicitadas = solicitadas;
        _nombreSupl = nombreSupl;
        _stockCritico = criticos;
        _sinReporteAyer = sinAyer;
        _sinReporteHoy = sinHoy;
        _vencenHoyNombres = [
          for (final c in vencen) '${c['nombre'] ?? ''}',
        ];
        _incidenciasPend = incidencias.length;
        // B3 (SWR): las bandejas RPC NO se vacían al recargar —
        // conservan su último payload bueno hasta que el
        // segundo pase lo renueve o falle (y si falla, queda la
        // caché con su nota «Sin red · datos de…»).
        _cuentasCasa = casa;
        _aplicarConfig(aj, tipos, pagoEnt);
        _cargando = false;
      });
    }
    // La fila de solicitudes se rellena en segundo plano, sin
    // bloquear el pintado que acaba de ocurrir.
    unawaited(_cargarSolicitudesInvitados());
    unawaited(_cargarReportesPlus());
  }


  /// Foto local de reservas y stock (B3 Paso 2: extraída de
  /// _cargar para compartirla con la recarga ligera): reservas
  /// solicitadas en orden FIFO, nombres de suplementos y la
  /// lista de stock crítico con el criterio del chip de
  /// Suplementos (activo y 0 < stock <= umbral propio, 3 por
  /// defecto).
  Future<
      ({
        List<Map<String, dynamic>> solicitadas,
        Map<String, String> nombreSupl,
        List<Map<String, dynamic>> criticos
      })> _fotoReservasStock() async {
    final reservas = await LocalDb.instance.allMirror('reservas');
    final solicitadas = [
      for (final r in reservas)
        if (r['estado'] == 'solicitada') r,
    ]..sort((a, b) => '${a['creada_ts']}'.compareTo('${b['creada_ts']}'));
    final supls = await LocalDb.instance.allMirror('suplementos');
    final nombreSupl = {
      for (final s in supls) '${s['id']}': '${s['nombre'] ?? ''}',
    };
    // Stock crítico: mismo criterio que el chip de Suplementos
    // (activo y 0 < stock <= umbral propio, 3 por defecto).
    final criticos = <Map<String, dynamic>>[];
    for (final s in supls) {
      final act = s['activo'];
      final inactivo = act == 0 ||
          act == false ||
          s['eliminado'] == 1 ||
          s['eliminado'] == true;
      if (inactivo) continue;
      final stock = (s['stock'] as num?)?.toInt() ?? 0;
      final umbral = (s['umbral_stock'] as num?)?.toInt() ?? 3;
      if (stock > 0 && stock <= umbral) criticos.add(s);
    }
    criticos.sort((a, b) => ((a['stock'] as num?)?.toInt() ?? 0)
        .compareTo((b['stock'] as num?)?.toInt() ?? 0));
    return (
      solicitadas: solicitadas,
      nombreSupl: nombreSupl,
      criticos: criticos
    );
  }

  /// G2 (v1.7.0): segundo pase — trae los reportes App Plus
  /// pendientes por RPC. 1.23 (B3): pauta SWR — el éxito guarda
  /// payload y sello; el fallo marca error y CONSERVA lo bueno
  /// (antes: catch a lista vacía, un falso «sin reportes»).
  Future<void> _cargarReportesPlus() async {
    final gen = ++_reportesPlusGen;
    try {
      final lista = await _plusSvc.pendientes();
      if (!mounted || gen != _reportesPlusGen) return;
      setState(() => _swrReportes.exito(lista, ahoraHabana()));
    } catch (_) {
      if (!mounted || gen != _reportesPlusGen) return;
      setState(() => _swrReportes.fallo());
    }
  }

  /// Segundo pase de _cargar: resuelve la RPC de solicitudes de
  /// invitados y rellena su fila con un segundo setState. La
  /// generación descarta el resultado si una recarga más nueva
  /// ya pidió el suyo. Pauta SWR como los reportes (B3).
  Future<void> _cargarSolicitudesInvitados() async {
    final gen = ++_solicitudesGen;
    try {
      final lista = await invitados_svc.InvitadosService()
          .solicitudesPendientes();
      if (!mounted || gen != _solicitudesGen) return;
      setState(() => _swrSolicitudes.exito(lista, ahoraHabana()));
    } catch (_) {
      if (!mounted || gen != _solicitudesGen) return;
      setState(() => _swrSolicitudes.fallo());
    }
  }

  /// 1.23 (B3 Paso 2): recarga LIGERA al volver de una
  /// subpantalla ESTRICTAMENTE operativa (hoy: solo
  /// Diagnóstico, vía _irLigera). Refresca lo que el hub y el
  /// bloque de atención muestran (contadores, efectivo por
  /// liquidar, reservas/stock, reportes de turno, incidencias,
  /// salud de sync) y re-dispara los dos pases SWR, SIN repetir
  /// los agregados del mes ni el relleno de configuración del
  /// pase completo.
  ///
  /// CONTRATO (panel B3 Paso 2, NO APTO → corrección): esta
  /// recarga omite ingresos/inscripciones/gastos/cobrado hoy/
  /// tipos/pagoEntrenador, así que SOLO puede usarse tras
  /// destinos que no mutan dinero, inscripciones ni
  /// configuración. Todo lo demás vuelve con _cargar completo:
  /// un KPI de dinero rancio en el panel del dueño es peor que
  /// 19 lecturas locales. Si un destino futuro parece ligero,
  /// la carga de la prueba es demostrar que nada de lo que
  /// muta alimenta un agregado omitido.
  Future<void> _cargarContadores() async {
    if (!AuthService().isOwner) return;
    final pend = await pendientePorEntrenador();
    final det = await SyncEngine.instance.detalle();
    final pendSubir = await LocalDb.instance.countPendingOps();
    final pagosMes = await NominaCalc.clientesQuePagaronElMes(
        NominaCalc.prefMesActual());
    final activos = await activosCount();
    final fotoRS = await _fotoReservasStock();
    final hoyH = ahoraHabana();
    String isoDia(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final sinHoy = await turnosSinReporte(isoDia(hoyH));
    final sinAyer = await turnosSinReporte(
        isoDia(hoyH.subtract(const Duration(days: 1))));
    // 1.25 T97: los que vencen hoy, para la bandeja única.
    final vencen = await vencenHoy();
    final incidencias = await incidenciasSyncPendientes();
    final casa = await LocalDb.instance.conteoCuentasCasa();
    if (!mounted) return;
    setState(() {
      _pend = pend;
      _syncDet = det;
      _pendientesSubir = pendSubir;
      _pagosMes = pagosMes;
      _clientesActivos = activos;
      _reservasSolicitadas = fotoRS.solicitadas;
      _nombreSupl = fotoRS.nombreSupl;
      _stockCritico = fotoRS.criticos;
      _sinReporteAyer = sinAyer;
      _sinReporteHoy = sinHoy;
      _vencenHoyNombres = [
        for (final c in vencen) '${c['nombre'] ?? ''}',
      ];
      _incidenciasPend = incidencias.length;
      _cuentasCasa = casa;
    });
    unawaited(_cargarSolicitudesInvitados());
    unawaited(_cargarReportesPlus());
  }

  void _ir(Widget w) {
    Navigator.of(context)
        .push(RutaIron(builder: (_) => w))
        .then((_) => _cargar());
  }

  /// Navega a un destino estrictamente operativo (sin
  /// mutaciones de dinero/inscripciones/configuración) y al
  /// volver recarga SOLO los contadores. Ver el contrato en
  /// _cargarContadores: ante la duda, usa _ir.
  void _irLigera(Widget w) {
    Navigator.of(context)
        .push(RutaIron(builder: (_) => w))
        .then((_) => _cargarContadores());
  }

  /// Aplica la foto de configuración a los campos y
  /// controladores del Panel. Sin setState propio: la
  /// llaman la carga completa y la recarga de
  /// configuración dentro de sus setState.
  void _aplicarConfig(
      Map<String, dynamic> aj, List<TipoPago> tipos, int pagoEnt) {
    _tipos = tipos;
    _pagoEntrenador = pagoEnt;
    for (final (clave, _) in clavesMontoConfig) {
      final v = aj[clave] as num?;
      _montos
          .putIfAbsent(clave, () => TextEditingController())
          .text = v != null
              ? '$v'
              : (clave == 'precio_app_plus' ? '1000' : '');
    }
    // v1.2.4: datos bancarios (strings) + titular (v0.6.0).
    for (final clave
        in ['tarjeta_bandec', 'tarjeta_bpa', 'movil_confirmacion', 'titular']) {
      _bancarios
          .putIfAbsent(clave, () => TextEditingController())
          .text = '${aj[clave] ?? ''}';
    }
  }

  /// 1.25 B-02: recarga SOLO la configuración al volver de
  /// una pantalla de configuración (precios, tipos,
  /// bancarios, ajustes del gym). Esas pantallas no tocan
  /// dinero, inscripciones ni contadores: repetir las
  /// ~19 lecturas de la carga completa era puro coste.
  Future<void> _cargarConfiguracion() async {
    if (!AuthService().isOwner) return;
    final aj = await LocalDb.instance.getAjustes();
    final preciosSinFijar = clavesPrecioSinFijar(aj).length;
    final tipos = await getTiposPago(soloActivos: false);
    final pagoEnt = await PerfilService.instance.getPagoEntrenador();
    if (!mounted) return;
    setState(() {
      _aplicarConfig(aj, tipos, pagoEnt);
      _preciosSinFijar = preciosSinFijar;
    });
  }

  /// Navega a una pantalla de CONFIGURACIÓN y al volver
  /// recarga solo la configuración (B-02).
  void _irConfig(Widget w) {
    Navigator.of(context)
        .push(RutaIron(builder: (_) => w))
        .then((_) => _cargarConfiguracion());
  }

  /// Navega a un destino de SOLO LECTURA demostrable (sin
  /// ninguna op encolada en su código) y al volver NO
  /// recarga: nada pudo cambiar (B-02). Si un destino
  /// gana una acción que muta, debe volver a _ir.
  void _irSoloLectura(Widget w) {
    Navigator.of(context).push(RutaIron(builder: (_) => w));
  }

  /// Navega a una subpantalla y recarga al volver (para las secciones).
  Future<void> _irYRecargar(Widget w) async {
    await Navigator.of(context)
        .push(RutaIron(builder: (_) => w));
    await _cargar();
  }

  /// 1.23 (B3 Paso 2): resuelve el destino de una fila del
  /// bloque de atención (la fila pura trae el destino; la
  /// navegación y los reintentos viven aquí).
  void _accionAtencion(DestinoAtencion destino) {
    switch (destino) {
      case DestinoAtencion.solicitudes:
        _ir(const InvitadosScreen(filtroInicial: 'solicitudes'));
      case DestinoAtencion.reintentarSolicitudes:
        unawaited(_cargarSolicitudesInvitados());
      case DestinoAtencion.reservas:
        _ir(const ReservasScreen());
      case DestinoAtencion.reportes:
        _ir(const ReportesPlusScreen());
      case DestinoAtencion.reintentarReportes:
        unawaited(_cargarReportesPlus());
      case DestinoAtencion.arqueo:
        _ir(const ArqueoScreen());
      case DestinoAtencion.vencimientos:
        _ir(const BandejaWhatsappScreen());
      case DestinoAtencion.cierre:
        _ir(_pantallaCierre());
      case DestinoAtencion.incidencias:
        _ir(const IncidenciasSyncScreen());
      case DestinoAtencion.diagnostico:
        _irLigera(const SeccionDiagnosticoScreen());
      case DestinoAtencion.suplementos:
        _ir(const SuplementosScreen());
    }
  }

  /// 1.25 T100: extraídos de las tarjetas de Sistema —
  /// el buscador del Panel los reutiliza tal cual.
  Future<void> _exportarExcel() async {
    // Ronda 17 M2-H1: exportar el Excel completo exige la
    // misma guarda de dueño que _exportar().
    if (!AuthService().isOwner) return;
    final ok = await exportarExcel();
    if (mounted) {
      mostrarSnack(context, ok
          ? 'Archivos listos para compartir'
          : 'No se pudo generar el archivo');
    }
  }

  Future<void> _exportarBitacora() async {
    if (!AuthService().isOwner) return;
    try {
      final (path, _) = await AppLog.exportar();
      await Share.shareXFiles([XFile(path)],
          text: 'Bitácora Iron Body Gym');
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo exportar la bitácora',
            significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _abrirBuscadorPanel() async {
    final id = await Navigator.push<String>(
      context,
      RutaIron(builder: (_) => const BuscadorPanelScreen()),
    );
    if (id == null || !mounted) return;
    _abrirFuncionPanel(id);
  }

  /// 1.25 T100: el resolvedor del buscador — los mismos
  /// destinos que abren las tarjetas de los módulos.
  void _abrirFuncionPanel(String id) {
    // 1.25 Panel 11: un resultado de cliente del buscador
    // global abre su ficha directamente.
    if (id.startsWith('cliente:')) {
      final cid = int.tryParse(id.substring(8));
      if (cid != null && cid > 0) _ir(FichaScreen(clienteId: cid));
      return;
    }
    switch (id) {
      case 'centro_control':
        _irSoloLectura(const CentroControlScreen());
      case 'comunicacion':
        _ir(const HubComunicacionScreen());
      case 'arqueo':
        _ir(const ArqueoScreen());
      case 'cierre_caja':
        _ir(_pantallaCierre());
      case 'liquidar':
        _ir(const ArqueoEntregaScreen());
      case 'extracto':
        _ir(const CentroComprasScreen());
      case 'gastos':
        _ir(SeccionGastosScreen(
          getGastos: () => _gastos,
          onAgregarGasto: _agregarGasto,
        ));
      case 'historial_caja':
        _ir(const HistorialCajaScreen());
      case 'pagos_metodo':
        _ir(const PagosPorMetodo());
      case 'comparativa':
        _ir(const ComparativaMensual());
      case 'ingresos_periodo':
        _ir(const IngresosPeriodoScreen());
      case 'nomina':
        _ir(const NominaScreen());
      case 'nomina_precalculada':
        _ir(const NominaPrecalculadaScreen());
      case 'adelantos':
        _ir(const AdelantosListaScreen());
      case 'solicitudes_adelanto':
        _ir(const SolicitudesAdelantoScreen());
      case 'usuarios':
        _ir(const ControlAccesoScreen());
      case 'candado':
        _ir(const PanelCandadoScreen());
      case 'recuperar':
        _ir(const RiesgoScreen());
      case 'congeladas':
        _ir(const CongeladosScreen());
      case 'papelera':
        _ir(const PapeleraScreen());
      case 'cuentas_casa':
        _ir(const CuentasCasaScreen());
      case 'vencimientos':
        _ir(const VencimientosProximosScreen());
      case 'cumpleanos':
        _ir(const CumpleanosScreen());
      case 'solicitudes_invitados':
        _ir(const InvitadosScreen());
      case 'invitados_frecuentes':
        _ir(const InvitadosFrecuentesScreen());
      case 'plantillas':
        _ir(const PlantillasScreen());
      case 'avisos_entrenadores':
        _ir(const AvisosEntrenadorScreen());
      case 'avisos_clientes':
        _ir(const EditorAvisosClientesScreen());
      case 'recordatorios':
        _ir(const RecordatoriosScreen());
      case 'info_publica':
        _ir(const InfoPublicaScreen());
      case 'entrenadores_apk':
        _ir(const UsuariosScreen());
      case 'plan_turnos':
        _ir(const TurnosHubScreen());
      case 'horario_apertura':
        _ir(const HorarioGym());
      case 'permisos':
        _ir(const PanelPermisos());
      case 'permisos_explicados':
        mostrarPermisosExplicados(context);
      case 'suplementos':
        _ir(const SuplementosScreen());
      case 'categorias':
        _ir(const CategoriasSuplementoScreen());
      case 'historial_ventas':
        _ir(const HistorialVentasScreen());
      case 'fiados':
        _ir(const PorCobrarScreen(pestanaInicial: 1));
      case 'sin_foto':
        _ir(const SinFotoPrecioScreen());
      case 'botes':
        _ir(const ServiciosAdminScreen());
      case 'reportes_plus':
        _ir(const ReportesPlusScreen());
      case 'reservas':
        _ir(const ReservasScreen());
      case 'biblioteca':
        _ir(const BibliotecaScreen());
      case 'rutinas_gym':
        _ir(const EditorRutinasGymScreen());
      case 'bandeja_gympedia':
        _ir(const BandejaScreen());
      case 'precios_metodo':
        _irConfig(const PreciosMetodoScreen());
      case 'tipos_pago':
        _irConfig(_pantallaAjustes(seccion: 'tipos'));
      case 'tarifas':
        _ir(const TarifasScreen());
      case 'bancarios':
        _irConfig(_pantallaAjustes(seccion: 'bancarios'));
      case 'pago_base':
        _elegirPagoEntrenador();
      case 'ajustes_gym':
        _irConfig(const AjustesGymScreen());
      case 'registro_mensual':
        _ir(const RegistroMensualScreen());
      case 'estado_sync':
        _irLigera(const SeccionDiagnosticoScreen());
      case 'cola_sync':
        _ir(const ColaScreen());
      case 'historial_sync':
        _irSoloLectura(const HistorialSyncScreen());
      case 'verificacion_espejo':
        _ir(const VerificacionEspejoScreen());
      case 'incidencias':
        _ir(const ListaIncidenciasScreen());
      case 'premios':
        _ir(const PremiosHubScreen());
      case 'errores_sync':
        _ir(const ErroresSyncPanelScreen());
      case 'auditoria':
        _irSoloLectura(const AuditoriaScreen());
      case 'auditoria_persona':
        _irSoloLectura(const AuditoriaPersonaScreen());
      case 'anomalias':
        _irSoloLectura(const AuditoriaSilenciosaScreen());
      case 'mantenimiento':
        _ir(const MantenimientoScreen());
      case 'copia':
        _ir(const CopiaSeguridadScreen());
      case 'exportar_csv':
        _exportar();
      case 'exportar_excel':
        _exportarExcel();
      case 'bitacora':
        _exportarBitacora();
      case 'bajada':
        _ir(const BajadaCompletaScreen());
    }
  }

  // -- montos ----------------------------------------------------------
  // Ronda 17 M2: guarda de dueño + candado anti-doble-toque.
  Future<void> _guardarMontos() async {
    if (!AuthService().isOwner) return;
    if (_operacionEnCurso) return;
    _operacionEnCurso = true;
    try {
      await _guardarMontosImpl();
    } finally {
      _operacionEnCurso = false;
    }
  }

  Future<void> _guardarMontosImpl() async {
    // 1.23 (B3 Paso 3a): parseo puro en config_precios_bancarios
    // (solo finitos y > 0; Infinity se colaba como precio).
    final cambios = parsearCambiosMontos(_montos);
    if (cambios.isEmpty) {
      mostrarSnack(context, 'No hay montos válidos para guardar', significado: SignificadoChip.alerta);
      return;
    }
    final mensaje = [
      for (final e in cambios.entries)
        '• ${etiquetaMonto(e.key)}: ${fmtMonto(e.value)} CUP',
      '',
      'Se aplicará en la próxima sincronización.',
    ].join('\n');
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cambiar precios',
      mensaje: mensaje,
      aceptar: 'Confirmar',
      icono: Icons.price_change_rounded,
    );
    if (ok != true || !mounted) return;
    // Autoauditoría 1.22 #2 (D2-01): ops + espejo en UNA
    // transacción (aplicarCambiosMontos, B3 Paso 3a).
    await aplicarCambiosMontos(cambios);
    if (!mounted) return;
    mostrarSnack(context, 'Precios guardados (se sincronizarán)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
    // v1.7.0 (G2 + panel): el precio del App Plus se REPUBLICA a
    // info_publica al guardar (patrón del horario canónico de la
    // 1.6.0): la cotización de S2 lee el precio de ahí, no del
    // ajuste local. La republicación va con reintento durable:
    // la clave queda marcada como pendiente ANTES del
    // intento (fila en la tabla info_publica_pendiente, v37) y
    // el gancho de fin de sync la republica tras cada
    // sincronización exitosa hasta lograrlo — si el guardado
    // fue sin red, el precio público no queda obsoleto en
    // silencio esperando a que el dueño vuelva a guardar.
    final precioPlus = cambios['precio_app_plus'];
    if (precioPlus != null) {
      final entero = precioPlus.round();
      unawaited(invitados_svc.InvitadosService()
          .guardarInfoPublicaConReintento(
              'precio_app_plus', '$entero'));
    }
  }

  /// v1.2.4: Guardar datos bancarios (strings, no montos).
  // Ronda 17 M2: guarda de dueño + candado anti-doble-toque.
  Future<void> _guardarBancarios() async {
    if (!AuthService().isOwner) return;
    if (_operacionEnCurso) return;
    _operacionEnCurso = true;
    try {
      await _guardarBancariosImpl();
    } finally {
      _operacionEnCurso = false;
    }
  }

  Future<void> _guardarBancariosImpl() async {
    // v1.2.4 (Hark): valida formato y solo envía lo que cambió.
    // 1.23 (B3 Paso 3a): la validación es pura y vive en
    // config_precios_bancarios.dart (validarCambiosBancarios).
    final aj = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    final r = validarCambiosBancarios(_bancarios, aj);
    final cambios = r.cambios;
    final errores = r.errores;
    if (errores.isNotEmpty) {
      mostrarSnack(context, 'Revisa: ${errores.join(' · ')}', significado: SignificadoChip.alerta);
      return;
    }
    if (cambios.isEmpty) {
      mostrarSnack(context, 'No hay cambios en los datos bancarios');
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Guardar datos bancarios',
      mensaje: 'Se actualizarán los datos de transferencia.\n'
          'Se aplicará en la próxima sincronización.',
      aceptar: 'Confirmar',
      icono: Icons.account_balance_rounded,
    );
    if (ok != true || !mounted) return;
    await aplicarCambiosBancarios(cambios, aj);
    if (!mounted) return;
    mostrarSnack(context, 'Datos bancarios guardados (se sincronizarán)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
  }


  // -- tipos de pago dinámicos (v1.0.16) --------------------------------
  static const _tiposFijos = {
    'mensual',
    'menores',
    'semanal',
    'quincenal'
  };
  bool _esTipoFijo(String id) => _tiposFijos.contains(id);

  // Ronda 17 M2: guarda de dueño + candado anti-doble-toque.
  Future<void> _persistirTipos() async {
    if (!AuthService().isOwner) return;
    if (_operacionEnCurso) return;
    _operacionEnCurso = true;
    try {
      await _persistirTiposImpl();
    } finally {
      _operacionEnCurso = false;
    }
  }

  Future<void> _persistirTiposImpl() async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guardar_tipos_pago',
      payload: {
        'tipos': [for (final t in _tipos) t.toJson()],
      },
    );
    // v1.3.1: optimismo local (tipos visibles al instante al cobrar).
    final aj = await LocalDb.instance.getAjustes();
    aj['tipos_pago'] = [for (final t in _tipos) t.toJson()];
    await LocalDb.instance.setAjustes(aj);
    SyncEngine.instance.push();
  }

  Future<void> _toggleTipo(TipoPago t, bool v) async {
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id)
            TipoPago(
                id: x.id,
                nombre: x.nombre,
                monto: x.monto,
                dias: x.dias,
                activo: v,
                soloMenores: x.soloMenores)
          else
            x,
      ];
    });
    await _persistirTipos();
  }

  Future<void> _editarTipo(TipoPago t) async {
    final nombreCtrl = TextEditingController(text: t.nombre);
    final montoCtrl =
        TextEditingController(text: '${t.monto}');
    final diasCtrl =
        TextEditingController(text: '${t.dias}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Editar ${t.nombre}',
        iconoTitulo: Icons.edit_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl, etiqueta: 'Nombre'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado: const TextInputType
                    .numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            CampoTexto(
                controller: diasCtrl,
                etiqueta: 'Días que cubre',
                teclado: TextInputType.number),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Guardar')),
        ],
      ),
    );
    final nombre = nombreCtrl.text.trim();
    final monto = double.tryParse(
        montoCtrl.text.trim().replaceAll(',', '.'));
    final dias = int.tryParse(diasCtrl.text.trim());
    // v1.3.2 (Argón #11): NO hacer dispose tras showDialog; el diálogo
    // sigue animando su cierre y el controller aún está en uso.
    // Los controllers locales los recoge el GC (igual que dialogo_pago).
    if (ok != true || !mounted) return;
    if (nombre.isEmpty || monto == null || !monto.isFinite || monto <= 0) {
      mostrarSnack(context, 'Nombre y monto válido requeridos', significado: SignificadoChip.alerta);
      return;
    }
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id)
            TipoPago(
                id: x.id,
                nombre: nombre,
                monto: monto,
                dias: (dias != null && dias > 0) ? dias : x.dias,
                activo: x.activo,
                soloMenores: x.soloMenores)
          else
            x,
      ];
    });
    await _persistirTipos();
    if (!mounted) return;
    mostrarSnack(context, 'Tipo de pago actualizado (se sincronizará)', significado: SignificadoChip.exito);
  }

  Future<void> _agregarTipo() async {
    final nombreCtrl = TextEditingController();
    final montoCtrl = TextEditingController();
    final diasCtrl = TextEditingController(text: '30');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Nuevo tipo de pago',
        iconoTitulo: Icons.add_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl,
                etiqueta: 'Nombre (ej: Trimestre)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado: const TextInputType
                    .numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            CampoTexto(
                controller: diasCtrl,
                etiqueta: 'Días que cubre',
                teclado: TextInputType.number),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Agregar')),
        ],
      ),
    );
    final nombre = nombreCtrl.text.trim();
    final monto = double.tryParse(
        montoCtrl.text.trim().replaceAll(',', '.'));
    final dias = int.tryParse(diasCtrl.text.trim()) ?? 30;
    // v1.3.2 (Argón #11): sin dispose tras showDialog (ver arriba).
    if (ok != true || !mounted) return;
    if (nombre.isEmpty ||
        monto == null ||
        !monto.isFinite ||
        monto <= 0 ||
        dias <= 0) {
      mostrarSnack(context, 'Nombre, monto y días válidos requeridos', significado: SignificadoChip.alerta);
      return;
    }
    final id = nombre
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (id.isEmpty || _tipos.any((x) => x.id == id)) {
      mostrarSnack(context, 'Ya existe un tipo con ese nombre', significado: SignificadoChip.alerta);
      return;
    }
    setState(() {
      _tipos = [
        ..._tipos,
        TipoPago(
            id: id, nombre: nombre, monto: monto, dias: dias),
      ];
    });
    await _persistirTipos();
    if (!mounted) return;
    mostrarSnack(context, 'Tipo de pago agregado (se sincronizará)', significado: SignificadoChip.exito);
  }

  Future<void> _eliminarTipo(TipoPago t) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Eliminar tipo',
      mensaje: '¿Eliminar "${t.nombre}"? Ya no aparecerá al cobrar.',
      aceptar: 'Eliminar',
      peligro: true,
      icono: Icons.delete_outline_rounded,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _tipos = [for (final x in _tipos) if (x.id != t.id) x];
    });
    await _persistirTipos();
    if (!mounted) return;
    mostrarSnack(context, 'Tipo de pago eliminado (se sincronizará)', significado: SignificadoChip.exito);
  }

  // Ronda 17 M2: guarda de dueño + candado anti-doble-toque
  // (mismo patrón que _guardarMontos: diálogo + op con UUID
  // nuevo; un segundo toque duplicaría la operación).
  Future<void> _guardarTipos() async {
    if (!AuthService().isOwner) return;
    if (_operacionEnCurso) return;
    _operacionEnCurso = true;
    try {
      await _guardarTiposImpl();
    } finally {
      _operacionEnCurso = false;
    }
  }

  Future<void> _guardarTiposImpl() async {
    final mensaje = [
      for (final t in _tipos)
        '• ${t.nombre}: ${fmtMonto(t.monto)} CUP · ${t.dias} días${t.activo ? '' : ' (inactivo)'}',
      '',
      'Se aplicará en la próxima sincronización.',
    ].join('\n');
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Guardar tipos de pago',
      mensaje: mensaje,
      aceptar: 'Confirmar',
      icono: Icons.payments_rounded,
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guardar_tipos_pago',
      payload: {
        'tipos': [for (final t in _tipos) t.toJson()],
      },
    );
    if (!mounted) return;
    mostrarSnack(context, 'Tipos guardados (se sincronizarán)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
  }

  // -- pendiente a entrega ----------------------------------------------
  /// v1.3.1: elegir cuánto se paga por cliente a entrenadores.
  /// Movido desde Ajustes (solo dueño).
  Future<void> _elegirPagoEntrenador() async {
    // Ronda 17 M2-H1: elegir el pago por cliente es solo del dueño.
    if (!AuthService().isOwner) return;
    final ctrl = TextEditingController(text: '$_pagoEntrenador');
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pago a entrenadores'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'CUP por cada cliente que pagó su mensualidad:'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                suffixText: 'CUP',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          BotonPrimario(
            texto: 'Guardar',
            onPressed: () {
                final v = int.tryParse(ctrl.text);
                Navigator.pop(ctx, v != null && v > 0 ? v : null);
              },
            expandido: false,
          ),
        ],
      ),
    );
    // v1.3.1: no hacer dispose aquí — el TextField sigue montado durante
    // la animación de salida del diálogo (error "used after being disposed").
    if (sel != null) {
      await PerfilService.instance.setPagoEntrenador(sel);
      // Argón Acceso #9: sin push, el cambio quedaba retenido
      // en la cola hasta el próximo evento de sync.
      SyncEngine.instance.push();
      if (mounted) {
        setState(() => _pagoEntrenador = sel);
        mostrarSnack(context, 'Pago actualizado: $sel CUP por cliente', significado: SignificadoChip.exito);
      }
    }
  }

  // Ronda 17 M2: guarda de dueño + candado anti-doble-toque.
  Future<void> _confirmarEntrega(
      {int? trainerId, required String nombre}) async {
    if (!AuthService().isOwner) return;
    if (_operacionEnCurso) return;
    _operacionEnCurso = true;
    try {
      await _confirmarEntregaImpl(trainerId: trainerId, nombre: nombre);
    } finally {
      _operacionEnCurso = false;
    }
  }

  Future<void> _confirmarEntregaImpl(
      {int? trainerId, required String nombre}) async {
    final notaCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Confirmar entrega',
        iconoTitulo: Icons.done_all_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '¿Confirmas que recibiste el dinero pendiente de '
                '"$nombre"? Su pendiente se pondrá en cero.',
                style: AppTexto.cuerpo),
            const SizedBox(height: 12),
            CampoTexto(
              controller: notaCtrl,
              etiqueta: 'Nota (opcional)',
              hint: 'Ej: entregó en dos partes',
              maxLineas: 2,
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Confirmar')),
        ],
      ),
    );
    final nota = notaCtrl.text.trim();
    // 1.23 AT-09: sin dispose aquí — el TextField sigue montado
    // durante la animación de salida del diálogo y disponerlo
    // revienta con «used after being disposed» (mismo arreglo
    // v1.3.1 de _editarPagoEntrenador).
    if (ok != true || !mounted) return;
    // 1.15 (Panel A2): confirmar SIEMPRE por listas de ids explícitas
    // (la pantalla empaqueta lo que muestra, nunca una orden ciega
    // por entrenador). Las listas las calcula idsPendientesEntrega
    // (negocio.dart): efectivo + pendiente + Casa fuera +
    // responsable del efectivo, menos lo ya liquidado parcial.
    final ids = await idsPendientesEntrega(trainerId: trainerId);
    final pagoIds = ids.pagos;
    final diarioIds = ids.diarios;
    final suplementoIds = ids.suplementos;
    final servicioIds = ids.servicios;
    await confirmarEntregaPorIds(
      mensualIds: pagoIds,
      diarioIds: diarioIds,
      suplementoIds: suplementoIds,
      servicioIds: servicioIds,
      // Argón Dinero #2: la entrega también salda los
      // adelantos de su gaveta que ya se descontaron del
      // monto esperado (si no, descuentan dos veces).
      adelantoIds: ids.adelantos,
      entrenadorNombre: nombre,
      trainerTelegramId: trainerId,
      nota: nota.isNotEmpty ? nota : null,
    );
    if (!mounted) return;
    mostrarSnack(context, 'Entrega confirmada (se sincronizará)', significado: SignificadoChip.exito);
    await _cargar();
    SyncEngine.instance.push();
  }

  // 1.15 (H4): registrar una recogida (total o parcial) desde el
  // pendiente a recoger, sin pasar por Arqueo. El monto puede superar
  // el pendiente visible: en ese caso se guarda como anticipada (el
  // entrenador aún no sincronizó esos pagos) y el pendiente queda en
  // negativo hasta que suba sus pagos; al llegar, se descuenta solo
  // y queda el resto. Si el entrenador no aparece en la lista (nada
  // sincronizado aún), basta un sync desde su teléfono para que
  // aparezca.
  Future<void> _registrarRecogida(
      {int? trainerId,
      required String nombre,
      required double pendiente}) async {
    // Ronda 17 M2-H1: registrar recogidas es solo del dueño
    // (el candado anti-doble-toque ya existía).
    if (!AuthService().isOwner) return;
    // Panel delta Luna ALTO: doble toque en «Recogida» abría dos
    // diálogos y podía registrar la misma recogida dos veces
    // (_enSerieLiquidacion serializa pero no deduplica).
    if (_recogidaEnCurso) return;
    if (trainerId == null) {
      mostrarSnack(context, 'No se pudo registrar: falta el entrenador', significado: SignificadoChip.error);
      return;
    }
    _recogidaEnCurso = true;
    try {
      await _registrarRecogidaImpl(
          trainerId: trainerId, nombre: nombre, pendiente: pendiente);
    } finally {
      _recogidaEnCurso = false;
    }
  }

  Future<void> _registrarRecogidaImpl(
      {required int trainerId,
      required String nombre,
      required double pendiente}) async {
    final montoCtrl = TextEditingController(
        text: pendiente > 0 ? pendiente.toStringAsFixed(0) : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Registrar recogida',
        iconoTitulo: Icons.handshake_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Entrenador: $nombre', style: AppTexto.cuerpo),
            Text('Pendiente visible: ${fmtMonto(pendiente)} CUP',
                style: AppTexto.cuerpo),
            const SizedBox(height: 12),
            CampoTexto(
              controller: montoCtrl,
              etiqueta: 'Monto recogido (CUP)',
              teclado:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            const Text(
              'Si el monto supera el pendiente visible, se guarda '
              'como recogida anticipada: el pendiente quedará en '
              'negativo hasta que el entrenador sincronice sus pagos.',
              style: AppTexto.metadato,
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Registrar')),
        ],
      ),
    );
    final monto =
        double.tryParse(montoCtrl.text.trim().replaceAll(',', '.'));
    // 1.23 AT-09: sin dispose aquí (animación de salida del
    // diálogo; ver _confirmarEntregaImpl).
    if (ok != true || !mounted) return;
    if (monto == null || !monto.isFinite || monto <= 0) {
      mostrarSnack(context, 'Monto inválido', significado: SignificadoChip.alerta);
      return;
    }
    try {
      await registrarEntregaEfectivo(
        entrenadorTelegramId: trainerId,
        montoEntregado: monto,
        autorDuenoId: AuthService().telegramId ?? 0,
        permitirAnticipada: true,
      );
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo registrar: $e', significado: SignificadoChip.error);
      return;
    }
    if (!mounted) return;
    mostrarSnack(context, 'Recogida registrada (se sincronizará)', significado: SignificadoChip.exito);
    await _cargar();
  }

  // -- gastos ------------------------------------------------------------
  // Ronda 17 M2: guarda de dueño + candado anti-doble-toque.
  // 1.27: la guarda admite TAMBIÉN el permiso
  // can_registrar_gastos (conectado de verdad): el flujo
  // vive en dialogo_gasto.dart, compartido con la
  // pantalla de Gastos del entrenador; el servidor ya
  // verificaba la op 'gasto' contra ese permiso
  // (permisos_ops). AdminScreen sigue sin cargar datos
  // para no-dueños (M2-H1): esta vía es defensa en
  // profundidad, la entrada del entrenador es Home.
  Future<void> _agregarGasto() async {
    if (!AuthService().isOwner &&
        !PermisosEntrenador().canRegistrarGastos) {
      return;
    }
    if (_operacionEnCurso) return;
    _operacionEnCurso = true;
    try {
      if (await agregarGastoFlow(context) && mounted) {
        await _cargar();
      }
    } finally {
      _operacionEnCurso = false;
    }
  }

  // -- exportar ----------------------------------------------------------
  String _csv(List<String> cab, List<List<String>> filas) {
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final sb = StringBuffer();
    sb.writeln(cab.map(esc).join(','));
    for (final f in filas) {
      sb.writeln(f.map(esc).join(','));
    }
    return sb.toString();
  }

  Future<void> _exportar() async {
    // Cliente protegido (2026-10-26, Protegido 2 H8): exportar es
    // solo del dueño; además, ningún protegido viaja en los CSV
    // (ni sus pagos) aunque el llamado llegue por otro camino.
    if (!AuthService().isOwner) {
      if (mounted) {
        mostrarSnack(context, 'Solo el dueño puede exportar datos', significado: SignificadoChip.alerta);
      }
      return;
    }
    final clientes = await LocalDb.instance.allMirror('clientes');
    final protegidos = <int>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null && esVistaProtegida(c)) protegidos.add(id);
    }
    final csvClientes = _csv(
      ['id', 'nombre', 'carnet', 'telefono', 'sexo', 'estado',
       'pagado_hasta', 'fecha_inscripcion'],
      [
        // v1.8.0: sin cáscaras (estado='eliminado') en el listado
        // de personas; sus pagos del mes sí se exportan abajo.
        for (final c in clientes)
          if (!esClienteEliminado(c) && !esVistaProtegida(c))
          [
            '${c['id'] ?? ''}',
            '${c['nombre'] ?? ''}',
            '${c['carnet'] ?? ''}',
            '${c['telefono'] ?? ''}',
            '${c['sexo'] ?? ''}',
            '${c['estado'] ?? ''}',
            '${c['pagado_hasta'] ?? ''}',
            '${c['fecha_inscripcion'] ?? ''}',
          ]
      ],
    );
    final n = ahoraHabana();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    final pagosMes = await LocalDb.instance.pagosDelMes(pref);
    final csvPagos = _csv(
      ['id', 'cliente_id', 'fecha', 'monto', 'metodo', 'periodo'],
      [
        for (final p in pagosMes)
          if (!protegidos.contains((p['cliente_id'] as num?)?.toInt()))
          [
            '${p['id'] ?? ''}',
            '${p['cliente_id'] ?? ''}',
            '${p['fecha'] ?? ''}',
            '${p['monto'] ?? ''}',
            '${p['metodo'] ?? ''}',
            '${p['periodo'] ?? ''}',
          ]
      ],
    );
    final dir = await getTemporaryDirectory();
    final f1 = File('${dir.path}/clientes_ironbody.csv');
    final f2 = File(
        '${dir.path}/pagos_${n.year}-${n.month.toString().padLeft(2, '0')}_ironbody.csv');
    await f1.writeAsString(csvClientes);
    await f2.writeAsString(csvPagos);
    await Share.shareXFiles([XFile(f1.path), XFile(f2.path)],
        text: 'Iron Body Gym — clientes y pagos del mes');
  }

  // -- UI (Panel del dueño, v1.6.0; rediseño 1.14) ---------------------------
  // Rediseño según el mockup v2 aprobado, el consenso del panel de
  // diseño (2026-10-22) y el veredicto de Argón (2026-10-26): la
  // Administración pasa a ser la consola del dueño como estación de
  // trabajo diaria. Orden estricto de bloques: 1) cabecera con
  // píldora de sync tocable, 2) Necesita tu atención (solo
  // decisiones del dueño, con botón; 5 visibles, resto desplegable),
  // 3) Estación diaria 2×2 (Cobrar · Mi Día · Arqueo · Cierre),
  // 4) Pulso del mes (3 KPIs tocables + Cuentas a la Casa tocable),
  // 5) 6 módulos con subsecciones. Las dos listas planas del
  // Bloque 2 (Panel y Resto) desaparecen: cada una de sus filas
  // vive ahora en exactamente un módulo (auditoría 1:1, sin
  // funciones perdidas). Solo UI: ninguna pantalla, permiso,
  // RPC ni lógica cambia; al volver de un módulo se recarga
  // igual que antes (Fix 6, vía _ir).
  @override
  Widget build(BuildContext context) {
    // Ronda 17 M2-H1: el panel es solo del dueño (su propio
    // subtítulo lo declara: "Panel del dueño · Solo tú ves
    // esta sección"). Sin gate, abrirlo por ruta exponía
    // todos los KPIs financieros del mes.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Administración'),
        body: const Center(
            child: Text('Panel del dueño · Solo tú ves esta sección')),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Administración', acciones: [
        // 1.25 T100: el buscador del Panel («¿Qué quieres
        // hacer?»): devuelve el id y aquí se navega.
        IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: 'Buscar una función del Panel',
          onPressed: _abrirBuscadorPanel,
        ),
      ]),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const EstadoCargando(texto: 'Cargando administración…')
                : RefreshIndicator(
                    // 1.24 Bloque 5 (B-01): el gesto de actualizar
                    // del Panel ahora sincroniza DE VERDAD antes
                    // de releer (antes solo releía espejos
                    // locales y no bajaba nada del servidor).
                    onRefresh: _actualizarPanel,
                    child: ListView(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      children: [
                        _cabeceraPanel(),
                        _bloqueAtencion(),
                        _tituloSeccion('ESTACIÓN DIARIA'),
                        _estacionDiaria(),
                        _tituloSeccion('PULSO DEL MES',
                            derecha: _textoActualizado()),
                        _resumenMes(),
                        _lineaCuentasCasa(),
                        _lineaNomina(),
                        _miniTendencia7(),
                        _tituloSeccion('MÓDULOS'),
                        _tarjetasModulos(),
                        // 1.25 T121 (F5-26): fuera la nota
                        // sobre el propio diseño (no ayuda a
                        // operar nada); en su lugar, la versión
                        // instalada, que sí sirve al diagnosticar.
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                          child: Text(
                            'Gestión v${AppConfig.appVersion} · Solo el '
                            'dueño ve este panel.',
                            textAlign: TextAlign.center,
                            style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Cabecera del panel (mockup v2): título con acento naranja,
  /// subtítulo y chip con el estado de sincronización.
  Widget _cabeceraPanel() {
    final Color chipColor;
    final String chipTxt;
    if (_syncDet.error != null && _syncDet.error!.isNotEmpty) {
      chipColor = AppColores.error;
      chipTxt = 'Error de sync';
    } else if (_pendientesSubir > 0) {
      chipColor = AppColores.alerta;
      chipTxt = '$_pendientesSubir por subir';
    } else {
      chipColor = AppColores.exito;
      chipTxt = 'Sincronizado';
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  style: AppTexto.displayPequeno.copyWith(fontWeight: FontWeight.w800),
                  children: const [
                    TextSpan(text: 'Panel '),
                    TextSpan(
                        text: 'del dueño',
                        style: TextStyle(color: AppColores.naranja)),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Iron Body Gym · Solo tú ves esta sección',
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // 1.14 (rediseño): la píldora es tocable — abre el
        // diagnóstico de sync, el mismo destino de la fila
        // «Problema de sincronización» del bloque de atención.
        InkWell(
          borderRadius: BorderRadius.circular(AppRadio.circular),
          onTap: () => _irLigera(const SeccionDiagnosticoScreen()),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppEspacio.md, vertical: AppEspacio.xs),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadio.circular),
              border: Border.all(color: chipColor.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: chipColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(chipTxt,
                    style: AppTexto.metadato.copyWith(color: chipColor, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tituloSeccion(String titulo,
      {bool naranja = false, String? derecha}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          if (naranja) ...[
            const Icon(Icons.warning_amber_rounded,
                size: 15, color: AppColores.naranja),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              titulo,
              style: AppTexto.etiqueta.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
                color: naranja
                    ? AppColores.naranja
                    : AppColores.textoSecundario(context),
              ),
            ),
          ),
          if (derecha != null)
            Text(derecha,
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  /// Bloque 1 · Necesita tu atención: SOLO decisiones del dueño, cada
  /// una con su botón de acción, máx. 5 visibles (consenso del panel
  /// de diseño). Sin pendientes: una línea discreta, no una tarjeta.
  Widget _bloqueAtencion() {
    // 1.23 (B3 Paso 2): la lista se deriva con la función pura
    // pendientesAtencion (panel_dueno_atencion.dart) — orden,
    // textos y «primario» probados sin widgets. Aquí solo se
    // envuelve cada dato en su fila y se resuelve la acción.
    final pendientes = <_PendientePanel>[
      for (final d in pendientesAtencion(FotoAtencion(
        solicitudes: _swrSolicitudes,
        reportes: _swrReportes,
        reservasSolicitadas: _reservasSolicitadas,
        nombreSupl: _nombreSupl,
        pendienteEntrenadores: _pend,
        sinReporteAyer: _sinReporteAyer,
        sinReporteHoy: _sinReporteHoy,
        incidenciasPend: _incidenciasPend,
        syncError: _syncDet.error,
        stockCritico: _stockCritico,
        vencenHoyNombres: _vencenHoyNombres,
      )))
        _PendientePanel(
          icono: d.icono,
          tinte: d.tinte,
          titulo: d.titulo,
          detalle: d.detalle,
          boton: d.boton,
          primario: d.primario,
          gravedad: d.gravedad,
          onTap: () => _accionAtencion(d.destino),
        ),
    ];

    // 1.14 (rediseño): 5 visibles y el resto (hasta 9 en total)
    // desplegable, en vez de quedarse fuera con una nota.
    final visibles =
        _atencionExpandida ? pendientes : pendientes.take(5).toList();
    final ocultos = pendientes.length - visibles.length;
    // 1.25 T35: si entre lo plegado hay bloqueantes (sync),
    // el rótulo del pliegue lo dice y va en rojo: un «+N más»
    // neutro escondía el error que bloquea todo lo demás.
    final ocultosBloqueantes = _atencionExpandida
        ? 0
        : pendientes
            .skip(visibles.length)
            .where((p) => p.gravedad == 0)
            .length;
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tituloSeccion('NECESITA TU ATENCIÓN', naranja: true),
        if (pendientes.isEmpty && !_swrSolicitudes.cargando)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: AppEspacio.lg, vertical: AppEspacio.md),
            decoration: BoxDecoration(
              color: AppColores.superficie(context),
              borderRadius: BorderRadius.circular(AppRadio.lg),
              border: Border.all(color: AppColores.borde(context)),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    size: 20, color: AppColores.exito),
                SizedBox(width: 8),
                Text('Sin pendientes · Todo en orden',
                    style: AppTexto.cuerpo),
              ],
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color:
                  oscuro ? const Color(0xFF1B150B) : const Color(0xFFFFF6E5),
              borderRadius: BorderRadius.circular(AppRadio.lg),
              border: Border.all(
                  color: oscuro
                      ? const Color(0xFF6B4A12)
                      : AppColores.alerta.withValues(alpha: 0.45)),
            ),
            child: Column(
              children: [
                // Panel 1.6.0: mientras la RPC de solicitudes no
                // resuelve, su fila va en estado «cargando» (sin
                // conteo) en vez de bloquear todo el bloque.
                if (_swrSolicitudes.cargando)
                  _filaSolicitudesCargando(
                      ultima: visibles.isEmpty && ocultos == 0),
                for (var i = 0; i < visibles.length; i++)
                  _filaAtencion(visibles[i],
                      ultima: i == visibles.length - 1 && ocultos == 0),
                if (pendientes.length > 5)
                  InkWell(
                    onTap: () => setState(
                        () => _atencionExpandida = !_atencionExpandida),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        _atencionExpandida
                            ? 'Ver menos'
                            : ocultosBloqueantes > 0
                                ? '+$ocultos pendiente(s) más · '
                                    '$ocultosBloqueantes de sync'
                                : '+$ocultos pendiente(s) más',
                        style: AppTexto.metadato.copyWith(
                            color: ocultosBloqueantes > 0
                                ? AppColores.error
                                : AppColores.naranja,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Fila «cargando» de las solicitudes de invitados: mismo cuerpo
  /// visual que _filaAtencion pero sin conteo ni botón, mientras
  /// la RPC no resuelve (panel 1.6.0: el panel pinta primero con
  /// los datos locales; esta fila se sustituye al llegar el dato).
  Widget _filaSolicitudesCargando({required bool ultima}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg, vertical: AppEspacio.md),
      decoration: BoxDecoration(
        border: ultima
            ? null
            : Border(
                bottom: BorderSide(
                    color: AppColores.borde(context)
                        .withValues(alpha: 0.6))),
      ),
      child: Row(
        children: [
          const IconoModuloBadge(
            icono: Icons.mark_email_unread_rounded,
            tinte: AppColores.naranja,
            iconoOscuro: AppColores.naranja,
            iconoClaro: AppColores.naranja,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Solicitudes de inscripción',
                    style: AppTexto.secundario.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 1),
                Text(
                  'Cargando…',
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }

  /// Fila de un pendiente: badge, título, detalle y botón píldora.
  Widget _filaAtencion(_PendientePanel p, {required bool ultima}) {
    return InkWell(
      onTap: p.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg, vertical: AppEspacio.md),
        decoration: BoxDecoration(
          border: ultima
              ? null
              : Border(
                  bottom: BorderSide(
                      color: AppColores.borde(context)
                          .withValues(alpha: 0.6))),
        ),
        child: Row(
          children: [
            IconoModuloBadge(
              icono: p.icono,
              tinte: p.tinte,
              iconoOscuro: p.tinte,
              iconoClaro: p.tinte,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.titulo,
                      style: AppTexto.secundario.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 1),
                  Text(
                    p.detalle,
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadio.circular),
              onTap: p.onTap,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                decoration: BoxDecoration(
                  color: p.primario
                      ? AppColores.naranja
                      : AppColores.superficie(context),
                  borderRadius: BorderRadius.circular(AppRadio.circular),
                  border: p.primario
                      ? null
                      : Border.all(color: AppColores.borde(context)),
                ),
                child: Text(p.boton,
                    style: AppTexto.metadato.copyWith(color: p.primario
                            ? const Color(0xFF171106)
                            : null, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A1: pull/push silencioso en segundo plano. Best-effort: si no
  /// hay red, no se avisa ni se bloquea nada.
  void _syncSilencioso() async {
    try {
      await SyncEngine.instance.push();
      await SyncEngine.instance.pull();
    } catch (_) {}
  }

  /// 1.14 (rediseño) · Estación diaria 2×2: Cobrar · Mi Día ·
  /// Arqueo rápido · Cierre / caja hoy, a un toque a los flujos de
  /// siempre. Mi Día dispara primero el pull/push silencioso, como
  /// hacía la fila del Bloque 2 (A1).
  Widget _estacionDiaria() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _accionRapida(Icons.payments_rounded, 'Cobrar',
                  primario: true, onTap: () => _ir(const PagoScreen())),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _accionRapida(Icons.today_rounded, 'Mi Día',
                  onTap: () {
                _syncSilencioso();
                _ir(const MiDiaScreen());
              }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _accionRapida(
                  Icons.account_balance_wallet_rounded, 'Arqueo rápido',
                  onTap: () => _ir(const ArqueoScreen())),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _accionRapida(
                  Icons.point_of_sale_rounded, 'Cierre / caja hoy',
                  onTap: () => _ir(_pantallaCierre())),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 1.24 Bloque 6 (ítem 8): la actividad reciente vive en
        // la portada del Panel, a un toque (el feed completo,
        // con la atribución por entrenador dentro).
        Row(
          children: [
            Expanded(
              child: _accionRapida(Icons.history_rounded,
                  'Actividad reciente',
                  onTap: () => _ir(ActividadScreen())),
            ),
          ],
        ),
      ],
    );
  }

  Widget _accionRapida(IconData icono, String texto,
      {bool primario = false, required VoidCallback onTap}) {
    final fg = primario ? const Color(0xFF171106) : null;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadio.lg),
      onTap: onTap,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          color: primario
              ? AppColores.naranja
              : AppColores.superficie(context),
          borderRadius: BorderRadius.circular(AppRadio.lg),
          border: primario
              ? null
              : Border.all(color: AppColores.borde(context)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, size: 20, color: fg),
            const SizedBox(width: 8),
            Text(texto,
                style: AppTexto.cuerpo.copyWith(color: fg, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  /// «Actualizado …» del Resumen: última sincronización registrada
  /// (los datos son del espejo local; el panel de diseño pidió que se
  /// vea cuándo se actualizaron).
  String? _textoActualizado() {
    final u = _syncDet.ultimaPull ?? _syncDet.ultimaPush;
    if (u == null) return null;
    return 'Actualizado ${_fechaHora(u)}';
  }

  /// Bloque 3 · Resumen del mes: las 3 cifras del mockup v2
  /// (ingresosMes, NominaCalc — la definición de Home — y
  /// activosCount).
  Widget _resumenMes() {
    const meses = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio',
      'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
    ];
    final mes = meses[ahoraHabana().month - 1];
    // 1.25 Panel 7: comparación contra el mes pasado.
    final mesAnt = meses[(ahoraHabana().month + 10) % 12];
    final varIng = _ingresosMesAnt == null
        ? null
        : textoVariacionPct(_ingresos, _ingresosMesAnt!);
    final varPagos = _pagosMesAnt == null
        ? null
        : textoVariacionPct(_pagosMes, _pagosMesAnt!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1.14 (rediseño): los 3 KPIs son tocables. Clientes
        // activos abre la lista de clientes (Buscar), donde se
        // filtra por estado.
        // 1.25 T40: Ingresos abre el DASHBOARD completo
        // (gráfico, comparativa, desgloses, balance): antes
        // abría un resumen fino de 3 filas congeladas y la
        // analítica rica quedaba en otra pantalla pese a que
        // el Panel se presenta como la consola del dueño.
        Expanded(
            child: _kpi('\$${fmtMonto(_ingresos)}', 'Ingresos de $mes',
                color: AppColores.exito,
                sub: varIng == null ? null : '$varIng vs $mesAnt',
                colorSub: _colorVariacion(_ingresosMesAnt == null
                    ? null
                    : variacionPct(_ingresos, _ingresosMesAnt!)),
                onTap: () => _irSoloLectura(const DashboardScreen()))),
        const SizedBox(width: 8),
        // v1.6.0 (Jc, añadido 7): «Pagos este mes» abre el LISTADO
        // exacto de los que pagaron el mes (PagaronMesScreen, el
        // conjunto de NominaCalc), no la nómina (misma corrección
        // que en la tarjeta de estadísticas de Home).
        Expanded(
            child: _kpi('$_pagosMes', 'Pagos este mes',
                sub: varPagos == null ? null : '$varPagos vs $mesAnt',
                colorSub: _colorVariacion(_pagosMesAnt == null
                    ? null
                    : variacionPct(_pagosMes, _pagosMesAnt!)),
                onTap: () => _ir(const PagaronMesScreen()))),
        const SizedBox(width: 8),
        Expanded(
            child: _kpi('$_clientesActivos', 'Clientes activos',
                onTap: () => _ir(const BuscarScreen()))),
      ],
    );
  }

  /// 1.23 (B3 Paso 3b): línea resumen de la nómina del mes
  /// bajo los KPI — el neto total a pagar a los entrenadores
  /// desde la foto compartida; sin foto, «-- CUP» (nunca 0).
  /// Tocar abre la pantalla de Nómina.
  Widget _lineaNomina() {
    final neto = _netoNominaMes;
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadio.sm),
        onTap: () => _ir(const NominaScreen()),
        child: Row(
          children: [
            const Icon(Icons.payments_rounded,
                size: 16, color: AppColores.naranja),
            const SizedBox(width: 8),
            Text(
              neto == null
                  ? 'Nómina del mes: -- CUP'
                  : 'Nómina del mes: \$${fmtMonto(neto)} CUP a pagar',
              style: AppTexto.etiqueta
                  .copyWith(color: AppColores.textoSecundario(context)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColores.naranja),
          ],
        ),
      ),
    );
  }

  /// v1.7.0: contador de Cuentas a la Casa activas (consulta
  /// local al espejo). Línea discreta bajo el resumen; sin
  /// cuentas, no ocupa espacio.
  Widget _lineaCuentasCasa() {
    if (_cuentasCasa <= 0) return const SizedBox.shrink();
    // 1.14 (rediseño): la línea es tocable — abre la pantalla de
    // Cuentas a la Casa, el mismo destino del módulo 2.
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadio.sm),
        onTap: () => _ir(const CuentasCasaScreen()),
        child: Row(
          children: [
            const Icon(Icons.home_rounded,
                size: 16, color: AppColores.alerta),
            const SizedBox(width: 8),
            Text(
              _cuentasCasa == 1
                  ? 'Cuentas a la Casa activas: 1'
                  : 'Cuentas a la Casa activas: $_cuentasCasa',
              style: AppTexto.etiqueta.copyWith(color: AppColores.alerta),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColores.alerta),
          ],
        ),
      ),
    );
  }

  Widget _kpi(String valor, String etiqueta,
      {Color? color, VoidCallback? onTap, String? sub, Color? colorSub}) {
    return Tarjeta(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.md, vertical: AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(valor,
              style: AppTexto.titulo.copyWith(color: color, fontWeight: FontWeight.w800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(etiqueta,
              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
          // 1.25 Panel 7: línea de comparación («+8 % vs
          // octubre») cuando hay base del mes pasado.
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub,
                style: AppTexto.metadato.copyWith(
                    color: colorSub ??
                        AppColores.textoSecundario(context),
                    fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }

  /// Color de una línea de variación: sube = verde, baja =
  /// rojo, plana o sin base = secundario.
  Color _colorVariacion(double? v) {
    if (v == null || v.round() == 0) {
      return AppColores.textoSecundario(context);
    }
    return v > 0 ? AppColores.exito : AppColores.error;
  }

  /// 1.25 Panel 7: mini-tendencia del cobrado de los últimos
  /// 7 días bajo los KPI del mes (la misma serie de Home).
  /// Tocar abre el Dashboard completo.
  Widget _miniTendencia7() {
    if (_serie7Panel.isEmpty) return const SizedBox.shrink();
    var maxMonto = 0.0;
    for (final f in _serie7Panel) {
      final m = (f['monto'] as num?)?.toDouble() ?? 0;
      if (m > maxMonto) maxMonto = m;
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.md),
      child: Tarjeta(
        onTap: () => _irSoloLectura(const DashboardScreen()),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cobrado · últimos 7 días',
                style: AppTexto.etiqueta.copyWith(
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: AppEspacio.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final f in _serie7Panel)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          height: 34,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: 14,
                              height: 6 +
                                  28 *
                                      (maxMonto <= 0
                                          ? 0
                                          : (((f['monto'] as num?)
                                                      ?.toDouble() ??
                                                  0) /
                                              maxMonto)),
                              decoration: BoxDecoration(
                                color: AppColores.naranja,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('${f['dia'] ?? ''}',
                            style: AppTexto.metadato.copyWith(
                                color:
                                    AppColores.textoSecundario(context))),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 1.14 (rediseño) · Módulos: 6 filas. Cada fila abre un
  /// contenedor con las tarjetas de destino de siempre, agrupadas
  /// en subsecciones. Las filas de las dos listas planas del
  /// Bloque 2 viven ahora aquí (auditoría 1:1: ninguna función
  /// se pierde y ninguna pantalla cambia por dentro).
  Widget _tarjetasModulos() {
    // 1.25 T121 (F5-10): UNA sola semántica para los badges —
    // número de DECISIONES pendientes de ese dominio (sin
    // pendientes, sin badge). Antes solo Clientes (solicitudes
    // de invitados) y Suplementos (reservas) tenían badge, con
    // significados distintos, y la ausencia en Caja o Control
    // se leía como «todo bien» aunque hubiera efectivo por
    // liquidar o incidencias de sync esperando.
    final pendCaja = _pend
        .where((e) => (e['total'] as double? ?? 0) > 0)
        .length;
    final pendClientes = _swrSolicitudes.datos.length +
        _swrReportes.datos.length;
    final modulos =
        <({IconData icono, Color tinte, String titulo, String resumen, int? badge, List<Widget> Function() tarjetas})>[
      (
        icono: Icons.attach_money_rounded,
        tinte: AppColores.exito,
        titulo: 'Caja, Cobros y Nómina',
        resumen: 'Arqueo · Cierre · Nómina · Adelantos',
        badge: pendCaja == 0 ? null : pendCaja,
        tarjetas: _tarjetasModuloCaja,
      ),
      (
        icono: Icons.people_rounded,
        tinte: AppColores.info,
        titulo: 'Clientes, Invitados y Comunicación',
        resumen: 'Clientes · Invitados · Plantillas · Avisos',
        badge: pendClientes == 0 ? null : pendClientes,
        tarjetas: _tarjetasModuloClientes,
      ),
      (
        icono: Icons.groups_rounded,
        tinte: AppColores.naranja,
        titulo: 'Equipo, Turnos y Permisos',
        resumen: 'Entrenadores · Turnos · Permisos',
        // 1.25 Panel 10: los reportes de turno que faltan
        // (hoy + ayer) son las decisiones pendientes de
        // este módulo — el mismo conteo de la bandeja.
        badge: (_sinReporteHoy.length + _sinReporteAyer.length) == 0
            ? null
            : _sinReporteHoy.length + _sinReporteAyer.length,
        tarjetas: _tarjetasModuloEquipo,
      ),
      (
        icono: Icons.inventory_2_rounded,
        tinte: const Color(0xFFA855F7),
        titulo: 'Suplementos, Dosis y App Plus',
        resumen: 'Suplementos · Botes y lotes · Plus · GymPedia',
        badge:
            _reservasSolicitadas.isEmpty ? null : _reservasSolicitadas.length,
        tarjetas: _tarjetasModuloSuplementos,
      ),
      (
        icono: Icons.price_change_rounded,
        tinte: const Color(0xFF9AA3B2),
        titulo: 'Precios, Tarifas y Configuración',
        resumen: 'Precios · Tarifas · Ajustes · Pago base',
        // 1.25 Panel 10: precios sin fijar = decisión
        // pendiente del dueño en este módulo.
        badge: _preciosSinFijar == 0 ? null : _preciosSinFijar,
        tarjetas: _tarjetasModuloPrecios,
      ),
      (
        icono: Icons.bar_chart_rounded,
        tinte: const Color(0xFF14B8A6),
        titulo: 'Control, Auditoría y Sistema',
        resumen: 'Estadísticas · Auditoría · Sync · Sistema',
        badge: _incidenciasPend == 0 ? null : _incidenciasPend,
        tarjetas: _tarjetasModuloControl,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(color: AppColores.borde(context)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < modulos.length; i++) ...[
            if (i > 0)
              Divider(height: 1, color: AppColores.borde(context)),
            InkWell(
              onTap: () => _ir(_ModuloAdminScreen(
                  titulo: modulos[i].titulo,
                  tarjetas: modulos[i].tarjetas())),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: AppEspacio.md),
                child: Row(
                  children: [
                    IconoModuloBadge(
                      icono: modulos[i].icono,
                      tinte: modulos[i].tinte,
                      iconoOscuro: modulos[i].tinte,
                      iconoClaro: modulos[i].tinte,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(modulos[i].titulo,
                              style: AppTexto.subtitulo),
                          const SizedBox(height: 2),
                          Text(
                            modulos[i].resumen,
                            style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (modulos[i].badge != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColores.error,
                          borderRadius: BorderRadius.circular(AppRadio.circular),
                        ),
                        child: Text('${modulos[i].badge}',
                            style: AppTexto.minuscula.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Icon(Icons.chevron_right_rounded,
                        color: AppColores.textoSecundario(context)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Destino «Cierre de caja» de siempre (sección B · Cobros),
  /// reutilizado por la acción rápida, el módulo Caja y los
  /// pendientes de cierre/reporte.
  Widget _pantallaCierre() {
    return SeccionCobrosScreen(
      getCaja: () => _caja,
      getGastosHoy: () => _gastosHoy,
      getPend: () => _pend,
      onConfirmarEntrega: _confirmarEntrega,
      onRegistrarRecogida: _registrarRecogida,
      onIr: _irYRecargar,
    );
  }

  // -- Módulo · Caja y dinero -------------------------------------------------
  /// Subsección dentro de un módulo (versalitas, sin el margen
  /// superior grande del título de bloque principal).
  Widget _subModulo(String titulo) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        titulo,
        style: AppTexto.etiqueta.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 1.6,
          color: AppColores.textoSecundario(context),
        ),
      ),
    );
  }

  // -- Módulo 1 · Caja, Cobros y Nómina --------------------------------------
  List<Widget> _tarjetasModuloCaja() {
    final cajaTotal = (_caja['efectivo'] ?? 0) + (_caja['transferencia'] ?? 0);
    final netoHoy = cajaTotal - _gastosHoy;
    final pendTotal =
        _pend.fold<double>(0, (s, e) => s + (e['total'] as double? ?? 0));
    return [
      _subModulo('COBROS Y CAJA'),
      _tarjetaFlujo(
        Icons.account_balance_wallet_rounded,
        'Arqueo del día',
        pendTotal > 0
            ? '${fmtMonto(pendTotal)} CUP por liquidar'
            : 'Todo cuadrado',
        () => _ir(const ArqueoScreen()),
      ),
      _tarjetaFlujo(
        Icons.point_of_sale_rounded,
        'Cierre de caja',
        'Neto hoy: ${fmtMonto(netoHoy)} CUP',
        () => _ir(_pantallaCierre()),
      ),
      _tarjetaFlujo(
        Icons.handshake_rounded,
        'Liquidar efectivo de entrenadores',
        'Cuadra lo entregado por cada entrenador',
        () => _ir(const ArqueoEntregaScreen()),
      ),
      _tarjetaFlujo(
        Icons.receipt_long_rounded,
        'Centro de Compras y Extracto',
        'Todo | Suplementos | Servicios, con subtotales',
        () => _ir(const CentroComprasScreen()),
      ),
      _tarjetaFlujo(
        Icons.receipt_long_rounded,
        'Últimos gastos',
        'Hoy: ${fmtMonto(_gastosHoy)} CUP',
        () => _ir(SeccionGastosScreen(
          getGastos: () => _gastos,
          onAgregarGasto: _agregarGasto,
        )),
      ),
      _tarjetaFlujo(
        Icons.history_rounded,
        'Historial de caja',
        'Cierres por entrenador y fecha',
        () => _ir(const HistorialCajaScreen()),
      ),
      _tarjetaFlujo(
        Icons.credit_card_rounded,
        'Pagos por método',
        'Efectivo vs transferencia',
        () => _ir(const PagosPorMetodo()),
      ),
      _tarjetaFlujo(
        Icons.compare_arrows_rounded,
        'Comparativa mensual',
        'Este mes vs anterior',
        () => _ir(const ComparativaMensual()),
      ),
      _tarjetaFlujo(
        Icons.bar_chart_rounded,
        'Ingresos por período',
        'Plus como línea propia, sin doble conteo',
        () => _ir(const IngresosPeriodoScreen()),
      ),
      _subModulo('NÓMINA'),
      _tarjetaFlujo(
        Icons.payments_rounded,
        'Nómina del mes',
        // 1.14: el pago base ya es configurable (módulo 5), no 150 fijo.
        'Proyección: clientes pagados × $_pagoEntrenador CUP',
        () => _ir(const NominaScreen()),
      ),
      _tarjetaFlujo(
        Icons.fact_check_rounded,
        'Nómina pre-calculada',
        'Solo lectura, vista previa hasta el 31',
        () => _ir(const NominaPrecalculadaScreen()),
      ),
      _tarjetaFlujo(
        Icons.payments_rounded,
        'Adelantos',
        'Lista con filtro por mes',
        () => _ir(const AdelantosListaScreen()),
      ),
      _tarjetaFlujo(
        Icons.request_page_rounded,
        'Solicitudes de adelanto',
        'Aprobar (Nómina / Pendiente) o rechazar',
        () => _ir(const SolicitudesAdelantoScreen()),
      ),
    ];
  }

  // -- Módulo 2 · Clientes, Invitados y Comunicación --------------------------
  List<Widget> _tarjetasModuloClientes() {
    return [
      _subModulo('CLIENTES'),
      // v1.6.0 (pedido de Jc): Entrenadores, Clientes e Invitados
      // viven en una misma zona «Usuarios» (ControlAccesoScreen con
      // la bandeja de Invitados como tercera pestaña). Ya no hay
      // entrada suelta de Invitados en Administración.
      _tarjetaFlujo(
        Icons.manage_accounts_rounded,
        'Usuarios',
        _swrSolicitudes.datos.isEmpty
            ? 'Entrenadores, clientes e invitados'
            : 'Entrenadores, clientes e invitados · '
                '${_swrSolicitudes.datos.length} solicitud(es) por atender',
        () => _ir(const ControlAccesoScreen()),
      ),
      // 1.21: candado de acceso — pausa temporal de las apps
      // sin cerrar sesiones (op acceso_bloqueo_set, solo dueño).
      _tarjetaFlujo(
        Icons.lock_rounded,
        'Candado de acceso',
        'Pausar Gestión y/o Clientes por alcance, rol o persona',
        () => _ir(const PanelCandadoScreen()),
      ),
      _tarjetaFlujo(
        Icons.warning_amber_rounded,
        'Clientes por recuperar',
        'Inactivos 60+ días, buenos para recuperar',
        () => _ir(const RiesgoScreen()),
      ),
      _tarjetaFlujo(
        Icons.ac_unit_rounded,
        'Membresías congeladas',
        'Membresías pausadas',
        () => _ir(const CongeladosScreen()),
      ),
      _tarjetaFlujo(
        Icons.delete_outline_rounded,
        'Papelera',
        // 1.25 T121 (F5-25): la pantalla trata de INACTIVOS
        // recuperables, no de eliminados: el título lo dice.
        'Inactivos y papelera',
        () => _ir(const PapeleraScreen()),
      ),
      _tarjetaFlujo(
        Icons.home_rounded,
        'Cuentas a la Casa',
        'Precio 0, solo el dueño las otorga',
        () => _ir(const CuentasCasaScreen()),
      ),
      // 1.26 (Premios, Pieza G): vales de logros que los
      // clientes reclaman en su app; el dueño aprueba.
      // 1.27: el hub suma el Catálogo editable (S2/G2).
      _tarjetaFlujo(
        Icons.emoji_events_rounded,
        'Premios',
        'Vales por aprobar y catálogo de premios por logro',
        () => _ir(const PremiosHubScreen()),
      ),
      // 1.27 (Comunidad MVP, Pieza G): los perfiles
      // visibles de la Comunidad y su ocultación.
      _tarjetaFlujo(
        Icons.groups_rounded,
        'Comunidad',
        'Perfiles visibles de los clientes y ocultación',
        () => _ir(const ComunidadPanelScreen()),
      ),
      _tarjetaFlujo(
        Icons.event_rounded,
        'Vencimientos próximos',
        'Vencidos + próximos 7 días, con acción',
        () => _ir(const VencimientosProximosScreen()),
      ),
      // 1.25 T108: Cumpleaños vive en el hub de
      // Comunicación (su tarjeta sale de esta sección).
      _subModulo('INVITADOS'),
      _tarjetaFlujo(
        Icons.group_rounded,
        'Solicitudes de invitados',
        'Por atender',
        () => _ir(const InvitadosScreen()),
      ),
      // 1.23 (W7): candidatos por visitas registradas en la ficha.
      _tarjetaFlujo(
        Icons.how_to_reg_rounded,
        'Invitados frecuentes',
        'Candidatos a cliente por visitas (30 días)',
        () => _ir(const InvitadosFrecuentesScreen()),
      ),
      _subModulo('COMUNICACIÓN'),
      // 1.25 T108: UNA sola entrada «Comunicación» — el
      // hub agrupa bandeja de hoy, cumpleaños, campañas,
      // avisos de las dos apps, plantillas y
      // recordatorios. Las tarjetas sueltas de cada
      // pieza salen del módulo: viven en el hub.
      _tarjetaFlujo(
        Icons.forum_rounded,
        'Comunicación',
        'Bandeja, cumpleaños, campañas, avisos y plantillas en un solo lugar',
        () => _ir(const HubComunicacionScreen()),
      ),
      _tarjetaFlujo(
        Icons.public_rounded,
        'Información pública',
        'Redes, contactos y precios para invitados',
        () => _ir(const InfoPublicaScreen()),
      ),
    ];
  }

  // -- Módulo 3 · Equipo, Turnos y Permisos -----------------------------------
  List<Widget> _tarjetasModuloEquipo() {
    return [
      _subModulo('EQUIPO'),
      _tarjetaFlujo(
        Icons.manage_accounts_rounded,
        'Entrenadores y usuarios APK',
        'Crear entrenador y compartir credenciales',
        () => _ir(const UsuariosScreen()),
      ),
      _subModulo('TURNOS'),
      // v1.6.0 (Jc): UNA sola puerta «Turnos» — el hub agrupa el
      // plan semanal y los ajustes por fecha con la línea de
      // precedencia (antes eran dos entradas sueltas y confusas).
      _tarjetaFlujo(
        Icons.calendar_month_rounded,
        'Plan y ajustes de turnos',
        'Patrón semanal y excepciones por fecha',
        () => _ir(const TurnosHubScreen()),
      ),
      // 1.25 T38: fuera la puerta intermedia «Turnos y
      // horarios» (una pantalla con un solo enlace al editor,
      // al que el hub ya llega directo): quedan DOS destinos
      // nombrados por la tarea — el hub de turnos y el horario
      // del gym.
      _tarjetaFlujo(
        Icons.schedule_rounded,
        'Horario de apertura',
        'Apertura y cierre del gym (mueve las franjas de turno)',
        () => _ir(const HorarioGym()),
      ),
      _subModulo('PERMISOS'),
      // 1.25 T37: la tarjeta PRINCIPAL de permisos: el
      // interruptor real por entrenador. Antes el módulo
      // «Equipo, Turnos y Permisos» solo traía el glosario y
      // el control vivía escondido en otra zona.
      _tarjetaFlujo(
        Icons.admin_panel_settings_rounded,
        'Permisos por entrenador',
        'Qué puede hacer cada entrenador: activar o quitar al momento',
        () => _ir(const PanelPermisos()),
      ),
      _tarjetaFlujo(
        Icons.security_rounded,
        'Permisos explicados',
        'Qué permite cada permiso, en sencillo',
        () => mostrarPermisosExplicados(context),
      ),
    ];
  }

  // -- Módulo 4 · Suplementos, Dosis y App Plus -------------------------------
  List<Widget> _tarjetasModuloSuplementos() {
    return [
      _subModulo('SUPLEMENTOS'),
      // 1.25 T121 (F5-23): fuera la puerta intermedia
      // «Suplementos» (SeccionSuplementosScreen): una pila de
      // botones hacia destinos que ahora son tarjetas directas
      // de este módulo (Categorías, Historial de ventas y
      // Fiados se sumaron aquí; el resto ya estaba).
      _tarjetaFlujo(
        Icons.fitness_center_rounded,
        'Catálogo de suplementos',
        'Con foto, precio y margen',
        () => _ir(const SuplementosScreen()),
      ),
      _tarjetaFlujo(
        Icons.category_rounded,
        'Categorías',
        'Organiza el catálogo por tipo de producto',
        () => _ir(const CategoriasSuplementoScreen()),
      ),
      _tarjetaFlujo(
        Icons.receipt_long_rounded,
        'Historial de ventas',
        'Ventas de suplementos con filtros y totales',
        () => _ir(const HistorialVentasScreen()),
      ),
      _tarjetaFlujo(
        Icons.account_balance_wallet_rounded,
        'Fiados por cobrar',
        'Ventas de suplementos a crédito por cobrar',
        () => _ir(const PorCobrarScreen(pestanaInicial: 1)),
      ),
      _tarjetaFlujo(
        Icons.warning_amber_rounded,
        'Productos sin foto o sin precio',
        'Señalados para completar el catálogo',
        () => _ir(const SinFotoPrecioScreen()),
      ),
      _subModulo('DOSIS'),
      _tarjetaFlujo(
        Icons.inventory_2_rounded,
        'Botes y lotes',
        'Desde Administración',
        () => _ir(const ServiciosAdminScreen()),
      ),
      _subModulo('APP PLUS'),
      _tarjetaFlujo(
        Icons.star_rounded,
        'Reportes App Plus',
        _swrReportes.cargando
            ? 'Consultando reportes…'
            : _swrReportes.sinCargar
                ? 'Sin conexión para consultar reportes'
                : _swrReportes.vacioSinRevalidar
                    ? 'Sin reportes conocidos · '
                        '${_swrReportes.notaSinRed}'
                    : _swrReportes.datos.isEmpty
                        ? 'Pagos del Plus reportados por invitados'
                        : '${_swrReportes.datos.length} por confirmar',
        () => _ir(const ReportesPlusScreen()),
      ),
      _tarjetaFlujo(
        Icons.inbox_rounded,
        'Reservas',
        _reservasSolicitadas.isEmpty
            ? 'Bandeja de reservas de los clientes'
            : '${_reservasSolicitadas.length} por confirmar',
        () => _ir(const ReservasScreen()),
      ),
      _tarjetaFlujo(
        Icons.menu_book_rounded,
        'Biblioteca',
        'GymPedia y Guía para la app de clientes',
        () => _ir(const BibliotecaScreen()),
      ),
      // 1.24 Bloque 6 (ítem 17): el banco «Del gym» de la app
      // de clientes se arma desde aquí (RPC admin_*).
      _tarjetaFlujo(
        Icons.fitness_center_rounded,
        'Rutinas del gym',
        'El banco «Del gym» que los clientes adoptan',
        () => _ir(const EditorRutinasGymScreen()),
      ),
      _tarjetaFlujo(
        Icons.mail_rounded,
        'Bandeja GymPedia',
        'Solicitudes de artículos, borradores y permisos',
        () => _ir(const BandejaScreen()),
      ),
    ];
  }

  // -- Módulo 5 · Precios, Tarifas y Configuración ----------------------------
  List<Widget> _tarjetasModuloPrecios() {
    return [
      // 1.25 T99: esto es el CENTRO único de Precios — un
      // solo sitio con sus cinco secciones, en este orden.
      // «Otros precios» desaparece: 4 de sus 5 claves
      // duplicaban a «Precios por método» (el «¿qué
      // pantalla manda?» de T36) y su única clave propia,
      // la tasa USD, vive ahora en la lista única.
      _subModulo('PRECIOS Y TARIFAS'),
      _tarjetaFlujo(
        Icons.tune_rounded,
        'Precios por método',
        'La lista única: mensualidad, períodos, App Plus y tasa USD · se guarda por campo',
        () => _irConfig(const PreciosMetodoScreen()),
      ),
      _tarjetaFlujo(
        Icons.payments_rounded,
        'Tipos de pago',
        '${_tipos.length} tipos configurados',
        () => _irConfig(_pantallaAjustes(seccion: 'tipos')),
      ),
      _tarjetaFlujo(
        Icons.local_offer_rounded,
        'Tarifas especiales',
        'Por cliente: otorgar y revocar la suya',
        () => _ir(const TarifasScreen()),
      ),
      // 1.25 T99: los Datos bancarios son parte del centro
      // de Precios (antes vivían en Configuración).
      _tarjetaFlujo(
        Icons.account_balance_rounded,
        'Datos bancarios',
        'Tarjetas y móvil de confirmación',
        () => _irConfig(_pantallaAjustes(seccion: 'bancarios')),
      ),
      // 1.14 (rediseño): _elegirPagoEntrenador llevaba huérfano
      // desde la v1.6.0 (sin botón). Vuelve como «Pago base a
      // entrenadores»: el mismo diálogo de siempre.
      _tarjetaFlujo(
        Icons.payments_rounded,
        'Pago base a entrenadores',
        '$_pagoEntrenador CUP por cliente que pagó',
        () => _elegirPagoEntrenador(),
      ),
      _subModulo('CONFIGURACIÓN'),
      _tarjetaFlujo(
        Icons.settings_rounded,
        'Ajustes del gym',
        'Métodos y textos del gym',
        () => _irConfig(const AjustesGymScreen()),
      ),
      _tarjetaFlujo(
        Icons.book_rounded,
        'Registro mensual',
        'Visor + copiar resumen en Markdown',
        () => _ir(const RegistroMensualScreen()),
      ),
    ];
  }

  // -- Módulo 6 · Control, Auditoría y Sistema --------------------------------
  List<Widget> _tarjetasModuloControl() {
    return [
      _subModulo('CONTROL'),
      if (_syncDet.error != null && _syncDet.error!.isNotEmpty)
        _tarjetaCompacta(
          Icons.error_outline_rounded,
          'Último error',
          // v1.3.8: lenguaje común, no tecnicismos.
          errorSyncLegible(_syncDet.error!),
          AppColores.error,
        ),
      // Módulo 6 (estado único): Diagnóstico absorbe la vista por
      // teléfono de EstadoSyncScreen (F4); una sola entrada.
      _tarjetaFlujo(
        Icons.sync_rounded,
        'Estado de sync',
        _pendientesSubir > 0
            ? '$_pendientesSubir ops por subir'
            : 'Sincronizado',
        () => _irLigera(const SeccionDiagnosticoScreen()),
      ),
      // Módulo 6 (pendientes + reintento): la pantalla ya existía
      // (detalle por operación, reintento uno/a uno y por lote,
      // bloqueadas, fotos) pero solo se abría desde Home; ahora
      // también desde el módulo, con filtro de ops ajenas.
      _tarjetaFlujo(
        Icons.queue_rounded,
        'Cola de sincronización',
        'Detalle por operación y reintentos',
        () => _ir(const ColaScreen()),
      ),
      // Módulo 6 (historial de sync): últimos eventos del módulo
      // 'sync' de la bitácora, sin exportar archivo.
      _tarjetaFlujo(
        Icons.timeline_rounded,
        'Historial de sync',
        'Subidas, bajadas, purgas y fallos recientes',
        () => _irSoloLectura(const HistorialSyncScreen()),
      ),
      // Módulo 6 (1.19): conteos local antes/después de un ciclo
      // forzado, con su alcance declarado (cantidad, no contenido).
      _tarjetaFlujo(
        Icons.verified_rounded,
        'Verificación del espejo',
        'Conteos por tabla, con alcance declarado',
        () => _ir(const VerificacionEspejoScreen()),
      ),
      _tarjetaFlujo(
        Icons.warning_amber_rounded,
        'Incidencias',
        'Errores que requieren atención',
        () => _ir(const ListaIncidenciasScreen()),
      ),
      _tarjetaFlujo(
        Icons.sync_problem_rounded,
        'Errores de sync',
        'En sencillo, sin «Descartar» para ops de datos',
        () => _ir(const ErroresSyncPanelScreen()),
      ),
      _subModulo('AUDITORÍA'),
      // 1.25 T112: UNA sola entrada «Centro de control»
      // con las cuatro miradas en pestañas de nombres
      // en sencillo (Qué pasó · Registro · Por persona ·
      // Anomalías). Las tarjetas sueltas salen del
      // módulo: viven en el centro. (F5-23 ya había
      // quitado la intermedia «Auditoría detallada».)
      _tarjetaFlujo(
        Icons.fact_check_rounded,
        'Centro de control',
        'Qué pasó, el registro, por persona y anomalías en un solo lugar',
        () => _irSoloLectura(const CentroControlScreen()),
      ),
      _subModulo('SISTEMA'),
      _tarjetaFlujo(
        Icons.build_rounded,
        'Mantenimiento',
        'Lista cerrada, con confirmación y auditoría',
        () => _ir(const MantenimientoScreen()),
      ),
      _tarjetaFlujo(
        Icons.backup_rounded,
        'Copia de seguridad',
        'Exportar solo, copia en frío sin fotos',
        () => _ir(const CopiaSeguridadScreen()),
      ),
      // Módulo 6 (rediseño): exportar directo, sin la pantalla
      // intermedia SeccionSistemaScreen (que repetía Salud,
      // Auditoría y Exportar). La bitácora sale de Ajustes y
      // queda aquí, donde se necesita cuando algo falla.
      _tarjetaFlujo(
        Icons.file_download_rounded,
        'Exportar CSV',
        'Clientes y pagos del mes',
        () => _exportar(),
      ),
      _tarjetaFlujo(
        Icons.table_chart_rounded,
        'Exportar Excel',
        'Clientes y pagos',
        () => _exportarExcel(),
      ),
      _tarjetaFlujo(
        Icons.bug_report_rounded,
        'Bitácora',
        'Exportar el registro para diagnóstico',
        () => _exportarBitacora(),
      ),
      // Módulo 6 (1.19, AL FINAL por orden Terra): bajada completa
      // segura (21/25): re-descarga sin borrar pendientes ni
      // datos locales; la pantalla prepara subir + copia primero.
      _tarjetaFlujo(
        Icons.download_for_offline_rounded,
        'Bajada completa',
        'Re-descarga segura de todos los espejos',
        () => _ir(const BajadaCompletaScreen()),
      ),
    ];
  }

  /// Construye la pantalla de Ajustes (se reutiliza en 3 tarjetas).
  Widget _pantallaAjustes({String? seccion}) {
    return SeccionAjustesScreen(
      seccion: seccion,
      getTipos: () => _tipos,
      onToggleTipo: _toggleTipo,
      onEditarTipo: _editarTipo,
      onEliminarTipo: _eliminarTipo,
      onAgregarTipo: _agregarTipo,
      onGuardarTipos: _guardarTipos,
      montos: _montos,
      clavesMonto: clavesMontoConfig,
      onGuardarMontos: _guardarMontos,
      bancarios: _bancarios,
      onGuardarBancarios: _guardarBancarios,
      esTipoFijo: _esTipoFijo,
    );
  }

  /// Tarjeta de flujo: badge + título + una línea de resumen.
  Widget _tarjetaFlujo(
      IconData icono, String titulo, String resumen, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        onTap: onTap,
        child: Row(
          children: [
            IconoModuloBadge.naranja(icono),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo, style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    resumen,
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }

  /// Tarjeta compacta informativa (no navegable): Estado / Último error.
  Widget _tarjetaCompacta(
      IconData icono, String titulo, String detalle, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Row(
          children: [
            Icon(icono, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo,
                      style: AppTexto.cuerpo
                          .copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    detalle,
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Formatea fecha/hora para la sección de salud ("nunca" si es null).
  String _fechaHora(DateTime? dt) {
    if (dt == null) return 'nunca';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $h:$min';
  }
}

/// Un pendiente del bloque «Necesita tu atención» (v1.6.0): icono,
/// textos, botón de acción y destino. Solo decisiones del dueño.
class _PendientePanel {
  final IconData icono;
  final Color tinte;
  final String titulo;
  final String detalle;
  final String boton;
  final bool primario;
  final int gravedad;
  final VoidCallback onTap;

  const _PendientePanel({
    required this.icono,
    required this.tinte,
    required this.titulo,
    required this.detalle,
    required this.boton,
    required this.primario,
    required this.gravedad,
    required this.onTap,
  });
}

/// Contenedor de un módulo del Panel del dueño (v1.6.0): lista las
/// tarjetas de destino existentes del módulo. No añade funciones;
/// solo agrupa las que ya estaban en el hub.
class _ModuloAdminScreen extends StatelessWidget {
  final String titulo;
  final List<Widget> tarjetas;

  const _ModuloAdminScreen({required this.titulo, required this.tarjetas});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, titulo),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: tarjetas,
      ),
    );
  }
}
