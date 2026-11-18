/// Administración (solo admin) — Panel del dueño desde v1.6.0.
///
/// Consola del dueño: pendientes con acción, acciones rápidas de caja,
/// resumen del mes y los módulos de siempre (estadísticas, montos,
/// usuarios APK, pendiente a entrega, gastos, cierre de caja, papelera
/// y exportar). Todo funciona offline: los cambios se encolan y suben
/// al sincronizar.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart' show mensajeErrorAmable;
import '../config.dart' show AppConfig;
import '../bloque2_resto.dart';
import '../conciliacion.dart';
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
import '../tarifa_especial.dart';
import '../tiempo.dart';
import '../turnos_resolucion.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'config_precios_bancarios.dart';
import 'panel_dueno_swr.dart';
import 'panel_dueno_atencion.dart';
import 'panel_cache.dart';
import 'panel_modulos.dart';
import 'panel_por_revisar.dart';
import 'skeleton.dart';
import 'bandeja_whatsapp.dart';
import 'ficha.dart';
import 'panel_buscador.dart';
import 'hub_comunicacion.dart';
import 'centro_control.dart';
import 'actividad.dart';
import 'buscar.dart';
import 'lupa_universal.dart';
import 'marco.dart';
import 'admin_secciones.dart';
import 'salud_sync_screen.dart';
import 'cola.dart';
import 'conciliacion.dart';
import 'arqueo.dart';
import 'guia.dart';
import 'categorias_suplemento.dart';
import 'por_cobrar.dart';
import 'historial_ventas.dart';
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
import 'congelaciones.dart';
import 'editor_rutinas_gym.dart';
import 'bandeja.dart';
import 'exportar_excel.dart';
import 'incidencias_sync.dart';
import 'pago.dart';
import 'reportes_plus.dart';
import 'reservas.dart';
import 'suplementos.dart';
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
import 'centro_compras.dart';
import 'tarifas_especiales.dart';
import 'usuarios.dart';
import 'servicios_admin.dart';

/// SL-9 (A1): líneas de DIFERENCIA de un cambio de montos —
/// «Etiqueta: viejo → nuevo» SOLO para las claves cuyo valor
/// cambia de verdad. Pura: la confirmación previa a aplicar
/// un cambio de precios se arma con esto (antes la
/// confirmación listaba solo los valores nuevos y el dueño no
/// veía qué se movía ni desde dónde).
List<String> lineasDiffMontos(
    Map<String, double> cambios, Map<String, dynamic> actuales) {
  return [
    for (final e in cambios.entries)
      if ((montoAjusteTolerante(actuales[e.key]) ?? 0) != e.value)
        '${etiquetaMonto(e.key)}: '
            '${fmtMonto(montoAjusteTolerante(actuales[e.key]) ?? 0)} → '
            '${fmtMonto(e.value)} CUP',
  ];
}

/// SL-9 (A1): diferencia de UN tipo de pago editado, campo a
/// campo («Monto: 2000 → 2500 CUP»). Cadena vacía si el tipo
/// quedó igual.
String textoDiffTipoPago(TipoPago antes, TipoPago despues) {
  final lineas = <String>[
    if (antes.nombre != despues.nombre)
      'Nombre: ${antes.nombre} → ${despues.nombre}',
    if (antes.monto != despues.monto)
      'Monto: ${fmtMonto(antes.monto)} → ${fmtMonto(despues.monto)} CUP',
    if (antes.dias != despues.dias)
      'Días: ${antes.dias} → ${despues.dias}',
  ];
  return lineas.join('\n');
}

/// SL-9 (A1): diferencias entre la lista de tipos vigente y
/// la editada (cambios de monto/días, altas y bajas), para la
/// confirmación de «Guardar tipos de pago».
List<String> lineasDiffTipos(
    List<TipoPago> antes, List<TipoPago> despues) {
  final porIdAntes = {for (final t in antes) t.id: t};
  final idsDespues = {for (final t in despues) t.id};
  return [
    for (final t in despues)
      if (!porIdAntes.containsKey(t.id))
        'Nuevo: ${t.nombre} — ${fmtMonto(t.monto)} CUP · ${t.dias} días'
      else if (textoDiffTipoPago(porIdAntes[t.id]!, t).isNotEmpty)
        '${t.nombre}: ${textoDiffTipoPago(porIdAntes[t.id]!, t)}',
    for (final t in antes)
      if (!idsDespues.contains(t.id)) 'Se elimina: ${t.nombre}',
  ];
}

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
  // 1.29 (Oleada 5, D-23): las FILAS de incidencias de
  // sync pendientes (no solo su conteo): de ellas salen
  // los ítems «POR REVISAR» de Control y su distintivo
  // (= filas.length por construcción). _incidenciasPend
  // se conserva como la cifra de la bandeja raíz, que
  // lee la misma foto.
  List<Map<String, dynamic>> _incidenciasFilas = [];

  /// 1.30 (Oleada D2, GEN-03): transferencias por
  /// comprobar (solo dueño): alimenta el ítem de Caja
  /// del «Por revisar» con el MISMO conteo espejo del
  /// buzón de Hoy (UI130-33).
  int _conciliacionesPorComprobar = 0;

  /// 1.30 (Oleada 5, H-06): señal de «se volvió de una
  /// herramienta» para la pantalla de módulo abierta: los
  /// ayudantes de navegación con recarga (_ir, _irConfig,
  /// _irLigera) la incrementan DESPUÉS de su recarga, y la
  /// pantalla de módulo (si sigue montada) re-lee su franja
  /// y sus tarjetas desde los proveedores. Local a este
  /// archivo: sin RouteObserver global y sin tocar
  /// main.dart (vía barata verificada, ajuste MEDIA-04).
  final ValueNotifier<int> _senalRetorno = ValueNotifier<int>(0);
  // 1.29 (Oleada 5, D-23): las claves de precio sin
  // fijar como LISTA (los ítems de Configuración); el
  // entero _preciosSinFijar es su longitud.
  List<String> _clavesSinFijar = [];
  // 1.29 (Oleada 5): los ajustes retenidos de la última
  // carga completa, para resolver el entrenador
  // asignado a cada turno sin reporte (plan de turnos)
  // al derivar los ítems de Equipo. Vacío = aún sin
  // carga completa: los ítems enseñan solo el día.
  Map<String, dynamic> _ajustesPanel = const {};
  // 1.29 (Oleada 5, D-23): padrón id → nombre para los
  // detalles de ítems (cliente de una incidencia o de
  // una reserva). Se carga solo si hay ítems que lo
  // necesitan.
  Map<int, String> _nombresClientesPanel = {};
  // 1.29 (Oleada 5, FA-04): tarifas especiales por
  // revisar (vencidas + por vencer ≤ 7 días) sobre la
  // MISMA fuente fusionada y el MISMO predicado que la
  // pantalla de Tarifas: un número, dos escaparates.
  int _tarifasPorRevisar = 0;
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

  // 1.28 (M5-B2): vales de Premios por aprobar, contados
  // sin entrar a Premios (tarjeta del módulo y fila de
  // atención). _valesCargados distingue «sabemos que son
  // 0» de «aún no se pudo saber»; _valesError marca el
  // último intento fallido (con _valesCargados en false,
  // la atención enseña la fila «sin cargar»).
  int _valesPorAprobar = 0;
  bool _valesCargados = false;
  bool _valesError = false;
  int _valesGen = 0;
  // 1.29 (Oleada 5, D-23): la foto de los vales como
  // filas ligeras (nombre + días del premio): los ítems
  // «POR REVISAR» de Clientes salen de aquí y el conteo
  // _valesPorAprobar es su longitud cuando hay foto.
  List<({String nombre, int dias})> _valesFoto = [];

  // 1.29 (Comunidad C3, COM-25): reportes NUEVOS de
  // la Comunidad (pendientes por encima de la marca
  // de vistos, DF-27) para el distintivo de su
  // tarjeta. 0 = nada nuevo que enseñar.
  int _reportesComunidadNuevos = 0;
  int _reportesComunidadGen = 0;

  // 1.28 (M5-B1): la foto de cifras de la visita anterior
  // pinta AL INSTANTE al abrir mientras la carga real
  // refresca en segundo plano; _cargaFrescaLista evita
  // que una foto que llega tarde pise cifras ya frescas.
  // (La hora de la foto solo la leía el sello «Actualizado
  // …», retirado por SL-9 G09-5: el campo se fue con él.)
  bool _cargaFrescaLista = false;

  // 1.28 (M5-C1): los badges de la última visita: un
  // contador que SUBIÓ desde entonces late al pintar.
  Map<String, int> _badgesPrevios = {};

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
    // 1.28 (M5-B1): la foto guardada se restaura SIN
    // esperar a la carga (que corre en paralelo); si la
    // carga fresca llega antes, la foto ya no se aplica.
    unawaited(_restaurarCachePanel());
  }

  @override
  void dispose() {
    _senalRetorno.dispose();
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
    // 1.36 H-B3 (136-819): el ciclo puede LANZAR — el
    // pull-to-refresh no termina mudo: snack amable y el
    // detalle en bitácora.
    SyncResultado res;
    try {
      res = await SyncEngine.instance.run();
    } catch (e) {
      AppLog.error('ui', 'actualizar_panel_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudo sincronizar: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
      return;
    }
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

  /// 1.28 (M5-A5/R3M5-H01): corre una lectura del Panel a
  /// prueba de fallos: si UNA cifra revienta, cae SOLO
  /// esa (conserva su valor vigente) y las demás siguen
  /// cargando. Antes _cargar encadenaba ~20 lecturas sin
  /// red de seguridad: un solo fallo dejaba el Panel en
  /// «cargando» para siempre (el _cargando=false vivía
  /// solo en el setState final, al que nunca se llegaba).
  Future<T> _seguro<T>(Future<T> Function() lectura, T respaldo) async {
    try {
      return await lectura();
    } catch (_) {
      return respaldo;
    }
  }

  Future<void> _cargar() async {
    // Ronda 17 M2-H1 (defensa en profundidad): sin dueño no
    // se cargan los KPIs financieros aunque se invoque directo.
    if (!AuthService().isOwner) return;
    try {
      await _cargarReal();
    } finally {
      // El spinner nunca se queda puesto: si algo no
      // aislado revienta en _cargarReal, el Panel abre
      // con las cifras que tenga.
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarReal() async {
    final ing = await _seguro(ingresosMes, _ingresos);
    // 1.23 (Delta Argón 4ª#3): derivaciones en memoria en vez
    // de re-escanear espejos enteros por cifra:
    // - inscripcionesMes = suma de inscripcionesPorEntrenador
    //   (ambas cuentan clientes no eliminados con
    //   fecha_inscripcion del mes actual).
    // - morosos y activos salen de resumenActivosMorosos (una
    //   sola lectura del padrón activo).
    final resumenAct = await _seguro(resumenActivosMorosos,
        (activos: _clientesActivos, morosos: 0));
    final pend = await _seguro(pendientePorEntrenador, _pend);
    // 1.25 T40: inscripciones del mes y morosos ya no se
    // calculan aquí: solo alimentaban el resumen fino que
    // Ingresos dejó de abrir (el Dashboard trae los suyos).
    final gastos = await _seguro(gastosTodos, _gastos);
    final caja = await _seguro(cobradoHoyPorMetodo, _caja);
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
    // 1.28 (M5-A5): los ajustes se leen aparte: si fallan,
    // NO se reaplica la configuración (aplicarla desde un
    // mapa vacío borraría los campos de precios pintados)
    // y el contador de precios sin fijar conserva su valor.
    Map<String, dynamic>? ajOk;
    try {
      ajOk = await LocalDb.instance.getAjustes();
    } catch (_) {}
    final aj = ajOk ?? const <String, dynamic>{};
    // 1.25 Panel 10: decisiones pendientes del módulo de
    // Precios = claves C6 sin valor válido.
    // 1.29 (Oleada 5, D-23): se conserva la LISTA de
    // claves (los ítems de Configuración); el entero es
    // su longitud por construcción.
    final clavesSinFijar =
        ajOk == null ? _clavesSinFijar : clavesPrecioSinFijar(aj);
    final preciosSinFijar = clavesSinFijar.length;
    final tipos = await _seguro(
        () => getTiposPago(soloActivos: false), _tipos);
    final pagoEnt = await _seguro(
        PerfilService.instance.getPagoEntrenador, _pagoEntrenador);
    // Salud del sistema
    final det = await _seguro(SyncEngine.instance.detalle, _syncDet);
    final pendSubir = await _seguro(
        LocalDb.instance.countPendingOps, _pendientesSubir);
    // Panel del dueño (v1.6.0): KPIs del mes y pendientes reales,
    // todos de fuentes existentes (sin cifras inventadas).
    // Panel 1.6.0 (decisión de Jc): el KPI «Pagos este mes» usa la
    // definición del dueño — la MISMA de Home y de la lista
    // (NominaCalc: descuenta a quien vence dentro del propio mes).
    // pagosRealizadosMes() conserva su sentido contable en sus
    // otros usos; aquí no se usa.
    final pagosMes = await _seguro(
        () => NominaCalc.clientesQuePagaronElMes(
            NominaCalc.prefMesActual()),
        _pagosMes);
    // 1.25 Panel 7: las cifras de comparación del mes pasado
    // y la serie de 7 días de la mini-tendencia.
    final ingAnt = await _seguro<double?>(
        () => ingresosMesAnterior(), _ingresosMesAnt);
    final pagosMesAnt = await _seguro<int?>(
        () => NominaCalc.clientesQuePagaronElMes(
            NominaCalc.prefMesAnterior()),
        _pagosMesAnt);
    final serie7Panel =
        await _seguro(ingresosUltimos7Dias, _serie7Panel);
    final activos = resumenAct.activos; // 4ª#3: de la lectura única
    final fotoRS = await _seguro(_fotoReservasStock, (
      solicitadas: _reservasSolicitadas,
      nombreSupl: _nombreSupl,
      criticos: _stockCritico,
    ));
    final solicitadas = fotoRS.solicitadas;
    final nombreSupl = fotoRS.nombreSupl;
    final criticos = fotoRS.criticos;
    final hoyH = ahoraHabana();
    String isoDia(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final sinHoy = await _seguro(
        () => turnosSinReporte(isoDia(hoyH)), _sinReporteHoy);
    final sinAyer = await _seguro(
        () => turnosSinReporte(
            isoDia(hoyH.subtract(const Duration(days: 1)))),
        _sinReporteAyer);
    // 1.25 T97: los que vencen hoy, para la bandeja única.
    final vencenNombres = await _seguro(
        () async => [
              for (final c in await vencenHoy())
                '${c['nombre'] ?? ''}',
            ],
        _vencenHoyNombres);
    // 1.29 (Oleada 5, D-23): las FILAS pendientes, no
    // solo su número: el distintivo de Control y su
    // franja salen de esta misma lista.
    final incidenciasFilas = await _seguro(
        incidenciasSyncPendientes, _incidenciasFilas);
    final incidenciasPend = incidenciasFilas.length;
    // v1.7.0: contador de Cuentas a la Casa (consulta local).
    final casa = await _seguro(
        LocalDb.instance.conteoCuentasCasa, _cuentasCasa);
    // 1.29 (Oleada 5, FA-04): tarifas por revisar desde
    // la fuente fusionada y el predicado compartidos
    // con la pantalla de Tarifas (contarTarifasPorRevisar).
    final tarifasRev =
        await _seguro(contarTarifasPorRevisar, _tarifasPorRevisar);
    // 1.30 (Oleada D2, GEN-03): el conteo de
    // conciliaciones por comprobar, solo del dueño (la
    // conciliación es su control, no contabilidad) y
    // fail-silent como el resto: un fallo conserva el
    // conteo anterior, nunca lo pone a 0.
    final conciliacionesRev = AuthService().isOwner
        ? await _seguro(
            ConciliacionService.instance.conteoPorComprobar,
            _conciliacionesPorComprobar)
        : 0;
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
    // 1.29 (Oleada 5, D-23): el padrón id → nombre solo
    // se lee si algún ítem lo necesita (incidencias o
    // reservas vivas); si la lectura falla, se conserva
    // el mapa anterior y los detalles caen a «Cliente
    // #id», como la pantalla de Reservas.
    final nombresPanel = await _nombresPanelSiHaceFalta(
        incidenciasFilas.isNotEmpty || solicitadas.isNotEmpty);
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
        _clavesSinFijar = clavesSinFijar;
        _pagosMesAnt = pagosMesAnt;
        _serie7Panel = serie7Panel;
        _netoNominaMes = netoNomina;
        _clientesActivos = activos;
        _reservasSolicitadas = solicitadas;
        _nombreSupl = nombreSupl;
        _stockCritico = criticos;
        _sinReporteAyer = sinAyer;
        _sinReporteHoy = sinHoy;
        _vencenHoyNombres = vencenNombres;
        _incidenciasPend = incidenciasPend;
        _incidenciasFilas = incidenciasFilas;
        _conciliacionesPorComprobar = conciliacionesRev;
        _tarifasPorRevisar = tarifasRev;
        _nombresClientesPanel = nombresPanel;
        if (ajOk != null) _ajustesPanel = aj;
        // B3 (SWR): las bandejas RPC NO se vacían al recargar —
        // conservan su último payload bueno hasta que el
        // segundo pase lo renueve o falle (y si falla, queda la
        // caché con su nota «Sin red · datos de…»).
        _cuentasCasa = casa;
        // 1.28 (M5-A5): sin ajustes leídos no se reaplica
        // la configuración (ver la lectura aislada arriba).
        if (ajOk != null) _aplicarConfig(aj, tipos, pagoEnt);
        _cargando = false;
        // 1.28 (M5-B1): lo pintado ya es fresco: la foto
        // guardada deja de mandar.
        _cargaFrescaLista = true;
      });
    }
    // La fila de solicitudes se rellena en segundo plano, sin
    // bloquear el pintado que acaba de ocurrir.
    unawaited(_cargarSolicitudesInvitados());
    unawaited(_cargarReportesPlus());
    // 1.28 (M5-B1/B2): la foto fresca se guarda para la
    // próxima apertura y los vales se cuentan en segundo
    // plano (su RPC no retrasa el pintado).
    unawaited(_guardarCachePanel());
    unawaited(_cargarValesPremios());
    unawaited(_cargarReportesComunidad());
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

  /// 1.29 (Oleada 5, D-23): el padrón id → nombre para
  /// los detalles de los ítems «POR REVISAR», leído solo
  /// cuando algún ítem lo necesita. Un fallo conserva el
  /// mapa vigente (nunca un vacío fingido).
  Future<Map<int, String>> _nombresPanelSiHaceFalta(
      bool haceFalta) async {
    if (!haceFalta) return _nombresClientesPanel;
    return _seguro(() async {
      final filas = await LocalDb.instance.allMirror('clientes');
      return <int, String>{
        for (final c in filas)
          if ((c['id'] as num?) != null)
            (c['id'] as num).toInt(): '${c['nombre'] ?? ''}',
      };
    }, _nombresClientesPanel);
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
    // 1.28 (M5-A5/R3M5-H01): misma pauta aislada que
    // _cargar: cada contador cae solo, no en cadena.
    final pend = await _seguro(pendientePorEntrenador, _pend);
    final det = await _seguro(SyncEngine.instance.detalle, _syncDet);
    final pendSubir = await _seguro(
        LocalDb.instance.countPendingOps, _pendientesSubir);
    final pagosMes = await _seguro(
        () => NominaCalc.clientesQuePagaronElMes(
            NominaCalc.prefMesActual()),
        _pagosMes);
    final activos = await _seguro(activosCount, _clientesActivos);
    final fotoRS = await _seguro(_fotoReservasStock, (
      solicitadas: _reservasSolicitadas,
      nombreSupl: _nombreSupl,
      criticos: _stockCritico,
    ));
    final hoyH = ahoraHabana();
    String isoDia(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final sinHoy = await _seguro(
        () => turnosSinReporte(isoDia(hoyH)), _sinReporteHoy);
    final sinAyer = await _seguro(
        () => turnosSinReporte(
            isoDia(hoyH.subtract(const Duration(days: 1)))),
        _sinReporteAyer);
    // 1.25 T97: los que vencen hoy, para la bandeja única.
    final vencenNombres = await _seguro(
        () async => [
              for (final c in await vencenHoy())
                '${c['nombre'] ?? ''}',
            ],
        _vencenHoyNombres);
    // 1.29 (Oleada 5, D-23): las filas, como en la carga
    // completa — la franja de Control se refresca también
    // tras los destinos ligeros (Diagnóstico).
    final incidenciasFilas = await _seguro(
        incidenciasSyncPendientes, _incidenciasFilas);
    final incidenciasPend = incidenciasFilas.length;
    // 1.30 (Oleada D2, GEN-03): el conteo de
    // conciliaciones se refresca también en esta vía
    // (la franja de Caja se re-lee al volver, como la
    // de Control con las incidencias).
    final conciliacionesLigero = AuthService().isOwner
        ? await _seguro(
            ConciliacionService.instance.conteoPorComprobar,
            _conciliacionesPorComprobar)
        : 0;
    final nombresPanel = await _nombresPanelSiHaceFalta(
        incidenciasFilas.isNotEmpty ||
            fotoRS.solicitadas.isNotEmpty);
    final casa = await _seguro(
        LocalDb.instance.conteoCuentasCasa, _cuentasCasa);
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
      _vencenHoyNombres = vencenNombres;
      _incidenciasFilas = incidenciasFilas;
      _conciliacionesPorComprobar = conciliacionesLigero;
      _nombresClientesPanel = nombresPanel;
      _incidenciasPend = incidenciasPend;
      _cuentasCasa = casa;
    });
    unawaited(_cargarSolicitudesInvitados());
    unawaited(_cargarReportesPlus());
    // 1.28 (M5-B1/B2): la foto se refresca con los
    // contadores nuevos y los vales se cuentan (el hub
    // de Premios pudo resolver alguno por el camino).
    unawaited(_guardarCachePanel());
    unawaited(_cargarValesPremios());
    unawaited(_cargarReportesComunidad());
  }

  /// 1.28 (M5-B2): cuenta los vales por aprobar en
  /// segundo plano. Un fallo NO pone el contador a 0:
  /// conserva el último conteo bueno y, si nunca se
  /// supo, la atención enseña la fila «sin cargar».
  Future<void> _cargarValesPremios() async {
    final gen = ++_valesGen;
    // 1.29 (Oleada 5, D-23): se traen las FILAS (la
    // misma lectura que contaba): el conteo es su
    // longitud y la foto alimenta los ítems de
    // Clientes. Un fallo conserva foto y conteo buenos.
    final lista = await valesVisiblesPorAprobar();
    if (!mounted || gen != _valesGen) return;
    setState(() {
      if (lista != null) {
        _valesFoto = [
          for (final v in lista) (nombre: v.nombre, dias: v.premioDias),
        ];
        _valesPorAprobar = lista.length;
        _valesCargados = true;
        _valesError = false;
      } else {
        _valesError = true;
      }
    });
  }

  /// 1.29 (Comunidad C3): el conteo de reportes
  /// nuevos de la Comunidad, en segundo plano como
  /// el de vales. null (no se pudo saber) deja la
  /// cifra anterior: nunca un 0 mentiroso.
  Future<void> _cargarReportesComunidad() async {
    if (!AuthService().isOwner) return;
    final gen = ++_reportesComunidadGen;
    // 1.36 H-B3 (136-819): se dispara con unawaited — un
    // lanzamiento dejaba un error no gestionado; ahora se
    // captura y el conteo anterior se CONSERVA.
    int? n;
    try {
      n = await contarReportesComunidadNuevos();
    } catch (e) {
      AppLog.error('ui', 'reportes_comunidad_fallo', d: '$e');
      return;
    }
    if (!mounted || gen != _reportesComunidadGen) return;
    final conteo = n;
    if (conteo != null) {
      setState(() => _reportesComunidadNuevos = conteo);
    }
  }

  /// 1.28 (M5-B1): el mapa de cifras que se guarda como
  /// foto de la próxima apertura (solo valores JSON
  /// seguros: escalares y listas de mapas del espejo).
  Map<String, dynamic> _cifrasParaCache() => {
        'ingresos': _ingresos,
        'pagosMes': _pagosMes,
        'pagosMesAnt': _pagosMesAnt,
        'ingresosMesAnt': _ingresosMesAnt,
        'clientesActivos': _clientesActivos,
        'caja': _caja,
        'gastosHoy': _gastosHoy,
        'gastos': _gastos,
        'netoNominaMes': _netoNominaMes,
        'preciosSinFijar': _preciosSinFijar,
        'incidenciasPend': _incidenciasPend,
        // 1.29 (Oleada 5, D-23): las listas de las que
        // salen los ítems, para que la foto de apertura
        // pinte distintivo y franja iguales que la carga
        // fresca (las cachés viejas no las traen: esos
        // ítems llegan con la carga real, como ya hacían
        // las bandejas de segundo pase).
        'incidenciasFilas': _incidenciasFilas,
        'clavesSinFijar': _clavesSinFijar,
        'valesFoto': [
          for (final v in _valesFoto) {'n': v.nombre, 'd': v.dias},
        ],
        'tarifasPorRevisar': _tarifasPorRevisar,
        'cuentasCasa': _cuentasCasa,
        'pendientesSubir': _pendientesSubir,
        'pend': _pend,
        'sinReporteHoy': _sinReporteHoy,
        'sinReporteAyer': _sinReporteAyer,
        'vencenHoyNombres': _vencenHoyNombres,
        'reservasSolicitadas': _reservasSolicitadas,
        'nombreSupl': _nombreSupl,
        'stockCritico': _stockCritico,
        'serie7Panel': _serie7Panel,
        'syncError': _syncDet.error,
        'valesPorAprobar': _valesPorAprobar,
      };

  /// Guarda la foto de cifras y los badges vistos, por
  /// usuario. Un fallo aquí es invisible a propósito: la
  /// caché es una cortesía de apertura, no un dato.
  Future<void> _guardarCachePanel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tid = AuthService().telegramId;
      await prefs.setString(
        claveCachePanel(tid),
        FotoPanelCache(ahoraHabana(), _cifrasParaCache())
            .codificar(),
      );
      final badges = <String, String>{
        for (final d in _datosModulos())
          if (d.badge != null) d.titulo: '${d.badge}',
      };
      await prefs.setString(
          claveBadgesPanel(tid), jsonEncode(badges));
    } catch (_) {}
  }

  /// 1.28 (M5-B1): restaura la foto guardada y los badges
  /// vistos. La foto solo se aplica si es de HOY (hora
  /// Habana): las cifras «de hoy» y «del mes» de ayer
  /// serían una mentira con sello fresco. Y solo si la
  /// carga real aún no pintó lo fresco.
  Future<void> _restaurarCachePanel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tid = AuthService().telegramId;
      final badgesTxt = prefs.getString(claveBadgesPanel(tid));
      if (badgesTxt != null) {
        final j = jsonDecode(badgesTxt);
        if (j is Map) {
          _badgesPrevios = {
            for (final e in j.entries)
              '${e.key}': int.tryParse('${e.value}') ?? 0,
          };
        }
      }
      final foto = FotoPanelCache.decodificar(
          prefs.getString(claveCachePanel(tid)));
      if (foto == null || !mounted || _cargaFrescaLista) return;
      final hoy = ahoraHabana();
      final h = foto.hora;
      if (h.year != hoy.year ||
          h.month != hoy.month ||
          h.day != hoy.day) {
        return;
      }
      _aplicarCifrasCache(foto.cifras);
      if (!mounted) return;
      setState(() {
        _cargando = false;
      });
    } catch (_) {}
  }

  /// Aplica una foto de cifras a los campos (lecturas
  /// tolerantes: lo degradado degrada a su valor en
  /// curso, nunca revienta). Sin setState propio: la
  /// llama la restauración dentro del suyo.
  void _aplicarCifrasCache(Map<String, dynamic> c) {
    _ingresos = cifraDoble(c, 'ingresos', _ingresos);
    _pagosMes = cifraEntera(c, 'pagosMes', _pagosMes);
    _pagosMesAnt = c['pagosMesAnt'] == null
        ? _pagosMesAnt
        : cifraEntera(c, 'pagosMesAnt');
    _ingresosMesAnt = c['ingresosMesAnt'] == null
        ? _ingresosMesAnt
        : cifraDoble(c, 'ingresosMesAnt');
    _clientesActivos =
        cifraEntera(c, 'clientesActivos', _clientesActivos);
    final caja = cifraMapa(c, 'caja');
    if (caja.isNotEmpty) {
      _caja = {
        'efectivo': cifraDoble(caja, 'efectivo'),
        'transferencia': cifraDoble(caja, 'transferencia'),
      };
    }
    _gastosHoy = cifraDoble(c, 'gastosHoy', _gastosHoy);
    _gastos = cifraLista(c, 'gastos');
    _netoNominaMes = c['netoNominaMes'] == null
        ? _netoNominaMes
        : cifraDoble(c, 'netoNominaMes');
    _preciosSinFijar =
        cifraEntera(c, 'preciosSinFijar', _preciosSinFijar);
    // 1.29 (Oleada 5, D-23): si la foto trae las listas,
    // los enteros salen de ellas (misma construcción que
    // la carga fresca); si es una caché vieja, manda el
    // entero guardado y los ítems llegan con la carga.
    if (c['clavesSinFijar'] is List) {
      _clavesSinFijar = cifraListaTextos(c, 'clavesSinFijar');
      _preciosSinFijar = _clavesSinFijar.length;
    }
    if (c['incidenciasFilas'] is List) {
      _incidenciasFilas = cifraLista(c, 'incidenciasFilas');
      _incidenciasPend = _incidenciasFilas.length;
    } else {
      _incidenciasPend =
          cifraEntera(c, 'incidenciasPend', _incidenciasPend);
    }
    if (c['valesFoto'] is List) {
      _valesFoto = [
        for (final v in cifraLista(c, 'valesFoto'))
          (nombre: '${v['n'] ?? ''}', dias: (v['d'] as num?)?.toInt() ?? 0),
      ];
    }
    _tarifasPorRevisar =
        cifraEntera(c, 'tarifasPorRevisar', _tarifasPorRevisar);
    _cuentasCasa = cifraEntera(c, 'cuentasCasa', _cuentasCasa);
    _pendientesSubir =
        cifraEntera(c, 'pendientesSubir', _pendientesSubir);
    _pend = cifraLista(c, 'pend');
    _sinReporteHoy = cifraListaTextos(c, 'sinReporteHoy');
    _sinReporteAyer = cifraListaTextos(c, 'sinReporteAyer');
    _vencenHoyNombres = cifraListaTextos(c, 'vencenHoyNombres');
    _reservasSolicitadas = cifraLista(c, 'reservasSolicitadas');
    _nombreSupl = {
      for (final e in cifraMapa(c, 'nombreSupl').entries)
        e.key: '${e.value}',
    };
    _stockCritico = cifraLista(c, 'stockCritico');
    _serie7Panel = cifraLista(c, 'serie7Panel');
    final err = c['syncError'];
    _syncDet = SyncDetalle(error: err is String ? err : null);
    if (c['valesPorAprobar'] != null) {
      _valesPorAprobar = cifraEntera(c, 'valesPorAprobar');
      _valesCargados = true;
    }
  }

  /// 1.29 (Oleada 5, D-23): la foto de pendientes del
  /// Panel desde el estado cargado. El entrenador de
  /// cada turno sin reporte se resuelve AQUÍ, con el
  /// plan de turnos retenido de la carga completa (la
  /// misma resolución del hub de turnos); sin ajustes
  /// retenidos o sin asignación, el ítem enseña solo el
  /// día — nunca un nombre inventado. El cliente de una
  /// incidencia sale del payload o del padrón cargado,
  /// con la precedencia de IncidenciasSyncScreen.
  FotoPendientesModulos _fotoPendientes() {
    List<({String turno, String? entrenador})> conAsignado(
        List<String> turnos, DateTime fecha) {
      if (_ajustesPanel.isEmpty) {
        return [for (final t in turnos) (turno: t, entrenador: null)];
      }
      final patron = parsePatronTurnos(_ajustesPanel['horario_turnos']);
      final excepciones =
          parseExcepcionesTurnos(_ajustesPanel['horario_excepciones']);
      return [
        for (final t in turnos)
          (
            turno: t,
            entrenador: programadoEn(
              fecha: fecha,
              // Las claves del plan son 'manana'/'tarde';
              // turnosSinReporte devuelve 'mañana'/'tarde'.
              franja: t == 'mañana' ? 'manana' : 'tarde',
              patron: patron,
              excepciones: excepciones,
            ),
          ),
      ];
    }

    String? clienteDeIncidencia(Map<String, dynamic> inc) {
      final raw = inc['payload'];
      if (raw != null && !(raw is String && raw.isEmpty)) {
        try {
          final p = raw is String
              ? jsonDecode(raw) as Map<String, dynamic>
              : Map<String, dynamic>.from(raw as Map);
          final nombreP = (p['nombre'] as String?)?.trim();
          if (nombreP != null && nombreP.isNotEmpty) return nombreP;
          final cid = (p['cliente_id'] as num?)?.toInt();
          if (cid != null) {
            final n = _nombresClientesPanel[cid];
            if (n != null && n.isNotEmpty) return n;
          }
        } catch (_) {
          // Payload ilegible: el ítem sale sin cliente,
          // como la tarjeta de la pantalla destino.
        }
      }
      return null;
    }

    final hoy = ahoraHabana();
    final fechaHoy = DateTime(hoy.year, hoy.month, hoy.day);
    final fechaAyer = DateTime(hoy.year, hoy.month, hoy.day - 1);
    return FotoPendientesModulos(
      conciliacionesPorComprobar: _conciliacionesPorComprobar,
      // 1.30 (Oleada D6, GEN-06): el MISMO conteo que el
      // Panel ya carga para la línea de estado de
      // Control — ninguna lectura nueva.
      cambiosPorSubir: _pendientesSubir,
      pendientesLiquidar: [
        for (final e in _pend)
          if (((e['total'] as num?)?.toDouble() ?? 0) > 0)
            (
              nombre: '${e['nombre'] ?? ''}',
              total: (e['total'] as num).toDouble(),
            ),
      ],
      solicitudes: [
        for (final s in _swrSolicitudes.datos)
          (nombre: s.nombre, desde: s.solicitudDesde),
      ],
      reportes: [
        for (final r in _swrReportes.datos)
          (nombre: r.nombre, monto: r.monto, referencia: r.referencia),
      ],
      vales: _valesFoto,
      sinReporteHoy: conAsignado(_sinReporteHoy, fechaHoy),
      sinReporteAyer: conAsignado(_sinReporteAyer, fechaAyer),
      reservas: [
        for (final r in _reservasSolicitadas)
          (
            suplemento: _nombreSupl['${r['suplemento_id']}'] ??
                'Suplemento',
            cliente: _nombresClientesPanel[
                    (r['cliente_id'] as num?)?.toInt()] ??
                'Cliente #${r['cliente_id']}',
            cantidad: (r['cantidad'] as num?)?.toInt() ?? 0,
          ),
      ],
      preciosSinFijar: _clavesSinFijar,
      incidencias: [
        for (final f in _incidenciasFilas)
          (
            tipo: '${f['tipo'] ?? ''}',
            cliente: clienteDeIncidencia(f),
            dispositivo: () {
              final d = '${f['dispositivo'] ?? ''}'.trim();
              return d.isEmpty ? null : d;
            }(),
            creadaEn: DateTime.tryParse('${f['creada_en'] ?? ''}'),
          ),
      ],
    );
  }

  /// 1.29 (Oleada 5, D-23): los ítems «POR REVISAR» de
  /// la foto actual — UNA derivación por construcción,
  /// compartida por los distintivos (vía [_datosModulos])
  /// y por las franjas de las pantallas de módulo.
  Map<ModuloPanel, List<ItemPorRevisar>> _itemsPorRevisar() =>
      pendientesPorModulo(_fotoPendientes());

  /// 1.28 (M5-C1): los descriptores de los 6 módulos con
  /// el estado vivo de la foto actual (función pura en
  /// panel_modulos.dart; aquí solo se le pasa la foto).
  /// 1.29 (Oleada 5, D-23): los conteos llegan como las
  /// LISTAS de ítems; cada badge es su longitud.
  List<DatoModuloPanel> _datosModulos(
          {Map<ModuloPanel, List<ItemPorRevisar>>? items}) =>
      modulosPanel(
        items: items ?? _itemsPorRevisar(),
        pendCajaTotal: _pend.fold<double>(
            0, (s, e) => s + ((e['total'] as num?)?.toDouble() ?? 0)),
        cajaHoyTotal:
            (_caja['efectivo'] ?? 0) + (_caja['transferencia'] ?? 0),
        clientesActivos: _clientesActivos,
        stockCritico: _stockCritico.length,
        pendientesSubir: _pendientesSubir,
      );

  /// Oleada 2 (Fase 1, desviación 1): liquidar ya no abre
  /// una pantalla propia del Panel — la puerta única vive
  /// en la Caja del Pilar 4 (la hoja «Liquidar Arqueo» con
  /// selector de modo cierre/C1). El Panel se cierra y el
  /// marco salta a la Caja: el mismo gesto que la Lupa usa
  /// para el destino 'liquidar'. (ArqueoEntregaScreen quedó
  /// sin llamadores y se retiró.)
  void _irACajaPilar() {
    Navigator.of(context).pop();
    MarcoNav.irANegocio('caja');
  }

  /// 1.29 (Oleada 5, D-23): el destino de un ítem «POR
  /// REVISAR» — las mismas pantallas que abren las
  /// tarjetas de cada módulo.
  void _abrirItemPorRevisar(ItemPorRevisar item) {
    switch (item.destino) {
      case DestinoPorRevisar.liquidacion:
        _irACajaPilar();
      case DestinoPorRevisar.solicitudesInvitados:
        _ir(const InvitadosScreen());
      case DestinoPorRevisar.reportesPlus:
        _ir(const ReportesPlusScreen());
      case DestinoPorRevisar.valesPremios:
        _ir(const PremiosHubScreen());
      case DestinoPorRevisar.cierreCaja:
        _ir(_pantallaCierre());
      case DestinoPorRevisar.reservas:
        _ir(const ReservasScreen());
      case DestinoPorRevisar.precios:
        _irConfig(const PreciosMetodoScreen());
      case DestinoPorRevisar.incidenciasSync:
        _ir(const IncidenciasSyncScreen());
      // 1.30 (D2, GEN-03): el ítem de Caja abre la
      // bandeja de Conciliación.
      case DestinoPorRevisar.conciliaciones:
        _ir(const ConciliacionScreen());
      // 1.30 (Oleada D6, GEN-06): el ítem de cambios por
      // subir abre la Cola (la misma puerta del módulo).
      case DestinoPorRevisar.colaSincronizacion:
        _ir(const ColaScreen());
    }
  }

  /// 1.30 (Oleada 5, H-06): devuelve el Future de la
  /// cadena (antes void): al volver recarga y DESPUÉS
  /// avisa con la señal de retorno, para que la franja
  /// del módulo abierto se re-lea sobre la foto fresca.
  Future<void> _ir(Widget w) {
    return Navigator.of(context)
        .push(RutaIron(builder: (_) => w))
        .then((_) => _cargar())
        .then((_) => _notificarRetorno());
  }

  /// Incrementa la señal de retorno (H-06) si el Panel
  /// sigue vivo; la escucha la pantalla de módulo abierta.
  void _notificarRetorno() {
    if (!mounted) return;
    _senalRetorno.value++;
  }

  /// Navega a un destino estrictamente operativo (sin
  /// mutaciones de dinero/inscripciones/configuración) y al
  /// volver recarga SOLO los contadores. Ver el contrato en
  /// _cargarContadores: ante la duda, usa _ir.
  Future<void> _irLigera(Widget w) {
    return Navigator.of(context)
        .push(RutaIron(builder: (_) => w))
        .then((_) => _cargarContadores())
        .then((_) => _notificarRetorno());
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
      // Corrección A5-D2: 'Mensualidad menores' muestra la
      // FUENTE ÚNICA (precioMenoresDesdeAjustes: el tipo del
      // blob manda), no la clave fija legacy — el campo
      // enseñaba una cifra que podía no ser la cobrada.
      // Yunque 4 (L2-2, clase K6-3): lector tolerante —
      // el cast duro moría a mitad del bucle con la clave
      // en texto y la foto de precios quedaba a medias.
      final num? v = clave == 'mensualidad_menores'
          ? precioMenoresDesdeAjustes(aj)
          : montoAjusteTolerante(aj[clave]);
      _montos
          .putIfAbsent(clave, () => TextEditingController())
          .text = v != null
              ? (v == v.roundToDouble() ? '${v.toInt()}' : '$v')
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
  /// 1.36 H-B3 (136-819): si la recarga LANZA, el aviso de
  /// retorno corre IGUAL (try/finally) y la recarga va por
  /// el seguro de la casa — antes la franja quedaba vieja
  /// sin decir nada.
  Future<void> _irConfig(Widget w) async {
    await Navigator.of(context).push(RutaIron(builder: (_) => w));
    try {
      await _seguro(() => _cargarConfiguracion(), null);
    } finally {
      _notificarRetorno();
    }
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
        _irLigera(const SaludSyncScreen());
      case DestinoAtencion.suplementos:
        _ir(const SuplementosScreen());
      case DestinoAtencion.premios:
        _ir(const PremiosHubScreen());
      case DestinoAtencion.reintentarVales:
        unawaited(_cargarValesPremios());
    unawaited(_cargarReportesComunidad());
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

  /// 1.25 T100: el resolvedor del buscador.
  ///
  /// 1.32 (Oleada 2, Fase 1 — desviación 3 de Argón): el
  /// resolvedor de destinos es ÚNICO, el de la Lupa
  /// (abrirFuncionLupa). Aquí solo quedan los destinos
  /// atados al ESTADO de esta pantalla, que la Lupa no puede
  /// abrir igual:
  /// - 'cliente:' — el buscador devuelve el id del cliente
  ///   y su ficha se abre desde aquí.
  /// - 'cierre_caja' — la SeccionCobrosScreen de
  ///   _pantallaCierre, atada a los getters del Panel.
  /// - 'gastos' — SeccionGastosScreen con los callbacks del
  ///   Panel (su lista _gastos y _agregarGasto).
  /// - 'tipos_pago' / 'bancarios' — Ajustes abierto en la
  ///   sección exacta, con recarga de configuración.
  /// - 'pago_base' — el diálogo _elegirPagoEntrenador.
  /// - 'permisos_explicados' — un diálogo sobre esta
  ///   pantalla, sin navegar.
  /// - 'exportar_csv' / 'exportar_excel' / 'bitacora' —
  ///   acciones sobre los datos cargados del Panel.
  /// - 'liquidar' — la puerta única vive en la Caja del
  ///   Pilar 4 (_irACajaPilar).
  /// Todo lo demás delega en la Lupa con cerrarActual: false
  /// (el Panel queda debajo del destino); al volver se
  /// recargan los datos, como hacía el _ir de siempre (los
  /// viejos _irSoloLectura/_irLigera no recargaban: recargar
  /// de más es un refresco inocuo, nunca un dato inventado).
  Future<void> _abrirFuncionPanel(String id) async {
    // 1.25 Panel 11: un resultado de cliente del buscador
    // global abre su ficha directamente.
    if (id.startsWith('cliente:')) {
      final cid = int.tryParse(id.substring(8));
      if (cid != null && cid > 0) _ir(FichaScreen(clienteId: cid));
      return;
    }
    switch (id) {
      case 'cierre_caja':
        _ir(_pantallaCierre());
        return;
      case 'liquidar':
        // Puerta única en la Caja del Pilar 4 (Oleada 2 F1).
        _irACajaPilar();
        return;
      case 'gastos':
        _ir(SeccionGastosScreen(
          getGastos: () => _gastos,
          onAgregarGasto: _agregarGasto,
        ));
        return;
      case 'tipos_pago':
        _irConfig(_pantallaAjustes(seccion: 'tipos'));
        return;
      case 'bancarios':
        _irConfig(_pantallaAjustes(seccion: 'bancarios'));
        return;
      case 'pago_base':
        _elegirPagoEntrenador();
        return;
      case 'permisos_explicados':
        mostrarPermisosExplicados(context);
        return;
      case 'exportar_csv':
        _exportar();
        return;
      case 'exportar_excel':
        _exportarExcel();
        return;
      case 'bitacora':
        _exportarBitacora();
        return;
    }
    await abrirFuncionLupa(context, id, cerrarActual: false);
    // Si el destino era un salto de pilar, esta pantalla ya
    // salió de la pila y la recarga no aplica. Si no, se
    // hace lo mismo que _ir al volver: recarga completa y
    // señal de retorno.
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      await _cargar();
      _notificarRetorno();
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
    // SL-9 (A1): la confirmación muestra las DIFERENCIAS
    // (viejo → nuevo) contra los ajustes vigentes, no solo los
    // valores nuevos; sin diferencias no hay nada que aplicar
    // y no se encola nada.
    final ajVigentes = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    final diffs = lineasDiffMontos(cambios, ajVigentes);
    if (diffs.isEmpty) {
      mostrarSnack(context, 'Los precios ya son esos; no hay cambios.', significado: SignificadoChip.alerta);
      return;
    }
    final mensaje = [
      for (final d in diffs) '• $d',
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
    final tiposJson = [for (final t in _tipos) t.toJson()];
    // v1.3.1: optimismo local (tipos visibles al instante al cobrar).
    // Corrección PROPIA-F5-01: el optimismo cubre TAMBIÉN las
    // claves planas de precio (ajustesTrasGuardarTipos: el
    // write-through que el servidor hace en set_tipos_pago).
    // Sin él, la renovación rápida de ficha —que cotiza desde
    // preciosVigentes(), lector de las claves planas— seguía
    // cobrando el precio viejo mientras el diálogo (lector
    // del blob) y el servidor aplicaban el nuevo. Op y
    // ajustes en UNA transacción, como aplicarCambiosMontos:
    // ni precio local sin op ni op sin precio local.
    final aj = await LocalDb.instance.getAjustes();
    final nuevos = ajustesTrasGuardarTipos(aj, tiposJson);
    final conn = await LocalDb.instance.db;
    await conn.transaction((txn) async {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'guardar_tipos_pago',
        payload: {'tipos': tiposJson},
        txn: txn,
      );
      await LocalDb.instance.setAjustes(nuevos, executor: txn);
    });
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
    final datos = await showDialog<_DatosTipoPago>(
      context: context,
      builder: (ctx) => _DialogoTipoPago(
        titulo: 'Editar ${t.nombre}',
        icono: Icons.edit_rounded,
        botonOk: 'Guardar',
        nombreIni: t.nombre,
        montoIni: '${t.monto}',
        diasIni: '${t.dias}',
      ),
    );
    if (datos == null || !mounted) return;
    final nombre = datos.nombre.trim();
    final monto = double.tryParse(
        datos.monto.trim().replaceAll(',', '.'));
    final dias = int.tryParse(datos.dias.trim());
    if (nombre.isEmpty || monto == null || !monto.isFinite || monto <= 0) {
      mostrarSnack(context, 'Nombre y monto válido requeridos', significado: SignificadoChip.alerta);
      return;
    }
    final nuevo = TipoPago(
        id: t.id,
        nombre: nombre,
        monto: monto,
        dias: (dias != null && dias > 0) ? dias : t.dias,
        activo: t.activo,
        soloMenores: t.soloMenores);
    // SL-9 (A1): un cambio de PRECIO no se aplica a ciegas: se
    // muestra la diferencia (viejo → nuevo) y se confirma;
    // cancelar deja el tipo intacto y no encola nada.
    final diff = textoDiffTipoPago(t, nuevo);
    if (diff.isEmpty) {
      mostrarSnack(context, 'El tipo quedó igual; no se guardó nada.', significado: SignificadoChip.alerta);
      return;
    }
    final okCambio = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar cambio de precio',
      mensaje: '${t.nombre}\n$diff\n\n'
          'Se aplicará en la próxima sincronización.',
      aceptar: 'Aplicar cambio',
      icono: Icons.price_change_rounded,
    );
    if (okCambio != true || !mounted) return;
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id) nuevo else x,
      ];
    });
    await _persistirTipos();
    if (!mounted) return;
    mostrarSnack(context, 'Tipo de pago actualizado (se sincronizará)', significado: SignificadoChip.exito);
  }

  Future<void> _agregarTipo() async {
    final datos = await showDialog<_DatosTipoPago>(
      context: context,
      builder: (ctx) => const _DialogoTipoPago(
        titulo: 'Nuevo tipo de pago',
        icono: Icons.add_rounded,
        botonOk: 'Agregar',
        etiquetaNombre: 'Nombre (ej: Trimestre)',
        diasIni: '30',
      ),
    );
    if (datos == null || !mounted) return;
    final nombre = datos.nombre.trim();
    final monto = double.tryParse(
        datos.monto.trim().replaceAll(',', '.'));
    final dias = int.tryParse(datos.dias.trim()) ?? 30;
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

  // 1.36 H-B3 (136-818, adjudicación): la doble vía NO se
  // unifica retirando el guardado global — ese guardado
  // tiene una función real y PROBADA (F5-01, decisión de
  // Jc 2026-11-17): si una bajada cambió los ajustes con
  // el editor abierto, «Guardar tipos» impone lo del
  // editor con write-through completo. Lo que mentía era
  // el mensaje de «sin cambios»: ahora dice la verdad
  // (cada cambio ya se aplica al momento).

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
    // SL-9 (A1): la confirmación muestra las DIFERENCIAS
    // contra el blob vigente en ajustes (viejo → nuevo, altas
    // y bajas), no la lista nueva a secas; sin diferencias no
    // se encola nada.
    final ajVigentes = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    final crudo = ajVigentes['tipos_pago'];
    final antes = <TipoPago>[
      if (crudo is List)
        for (final t in crudo)
          if (t is Map)
            TipoPago.desdeJson(Map<String, dynamic>.from(t)),
    ];
    final diffs = lineasDiffTipos(antes, _tipos);
    if (diffs.isEmpty) {
      mostrarSnack(context, 'Los tipos ya están guardados: cada cambio se aplica al momento.', significado: SignificadoChip.info);
      return;
    }
    final mensaje = [
      for (final d in diffs) '• $d',
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
    final tiposJson = [for (final t in _tipos) t.toJson()];
    // Corrección PROPIA-F5-01: esta vía SOLO encolaba la op —
    // ni el blob ni las claves planas se movían en local, así
    // que TODO lector local seguía con el precio anterior
    // mientras el servidor, al aplicar la op, asentaba con el
    // guardado (y hacía su write-through a las claves). El
    // guardado local es ahora el mismo acto que la op: blob +
    // claves planas (ajustesTrasGuardarTipos), en una
    // transacción, con el payload de siempre.
    final aj = await LocalDb.instance.getAjustes();
    final nuevos = ajustesTrasGuardarTipos(aj, tiposJson);
    final conn = await LocalDb.instance.db;
    await conn.transaction((txn) async {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'guardar_tipos_pago',
        payload: {'tipos': tiposJson},
        txn: txn,
      );
      await LocalDb.instance.setAjustes(nuevos, executor: txn);
    });
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
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) =>
          _DialogoPagoEntrenador(inicial: _pagoEntrenador),
    );
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
    final notaTexto = await showDialog<String>(
      context: context,
      builder: (ctx) => _DialogoConfirmarEntrega(nombre: nombre),
    );
    if (notaTexto == null || !mounted) return;
    final nota = notaTexto.trim();
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
    final montoTexto = await showDialog<String>(
      context: context,
      builder: (ctx) => _DialogoRegistrarRecogida(
        nombre: nombre,
        pendiente: pendiente,
      ),
    );
    if (montoTexto == null || !mounted) return;
    final monto =
        double.tryParse(montoTexto.trim().replaceAll(',', '.'));
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
      // SL-9 (G09-4): la excepción va a la bitácora; a la
      // pantalla solo llega el mensaje amable de la casa —
      // nunca «No se pudo registrar: Exception: …» en un flujo
      // de efectivo.
      AppLog.error('admin', 'recogida_fallo', d: '$e');
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo registrar: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
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
  // Yunque R5-M3-3: el escape es el CANÓNICO de
  // csvDeExportacion (exportar_excel.dart), con la
  // neutralización anti-fórmulas de D-B3-08 — esta copia
  // solo entrecomillaba y un nombre que empezara por «=»
  // se abría en Excel como fórmula viva.
  String _csv(List<String> cab, List<List<String>> filas) =>
      csvDeExportacion(cab, filas);

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
    // Yunque R5-M3-4: el fallo se AVISA (antes la promesa
    // quedaba sin gestionar y el dueño no sabía si exportó).
    try {
      await _exportarReal();
    } catch (e) {
      AppLog.error('ui', 'exportar_fallo', d: '$e');
      if (mounted) {
        // 1.36 H-B3 (136-820): snack amable; el crudo ya
        // quedó en la bitácora.
        mostrarSnack(context,
            'No se pudo exportar: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _exportarReal() async {
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
    // Yunque R5-M3-1: los filtros canónicos, como la hoja
    // principal (Casa, anulados en cola, cortesías fuera).
    final casasExp = await LocalDb.instance.idsCuentasCasa();
    final anuladosExp = await LocalDb.instance.pagosAnuladosEnCola();
    final csvPagos = _csv(
      ['id', 'cliente_id', 'fecha', 'monto', 'metodo', 'periodo'],
      [
        for (final p in pagosMes)
          if (!protegidos.contains((p['cliente_id'] as num?)?.toInt()) &&
              pagoExportable(p, casasExp, anuladosExp))
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
          // SL-9 (G09-5): fuera la banda de sync del Panel — la
          // sync se dice UNA sola vez, en la cabecera de la app
          // (regla de Jc 2026-11-14); aquí era la primera de
          // cinco superficies que la repetían.
          Expanded(
            child: _cargando
                // 1.28 (M5-C3): esqueleto con la forma
                // real del Panel (con foto guardada, B1,
                // ni siquiera se llega aquí: se pinta la
                // foto al instante).
                ? const SkeletonPanel()
                : RefrescoIron(
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
                        const EncabezadoSeccion(
                          titulo: 'ESTACIÓN DIARIA',
                          variante: VarianteEncabezado.panel),
                        _estacionDiaria(),
                        const EncabezadoSeccion(
                          titulo: 'PULSO DEL MES',
                          variante: VarianteEncabezado.panel),
                        _resumenMes(),
                        _lineaCuentasCasa(),
                        _lineaNomina(),
                        _miniTendencia7(),
                        const EncabezadoSeccion(
                          titulo: 'MÓDULOS',
                          variante: VarianteEncabezado.panel),
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

  /// Cabecera del panel (mockup v2): título con acento naranja
  /// y subtítulo. SL-9 (G09-5): el chip con el estado de
  /// sincronización SALE de aquí — la sync se dice una sola
  /// vez, en la cabecera de la app; el diagnóstico sigue a un
  /// toque en la tarjeta «Estado de sync» del módulo Control.
  Widget _cabeceraPanel() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  style: AppTexto.displayPequeno.copyWith(fontWeight: FontWeight.w700),
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
      ],
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
        // 1.28 (M5-B2): vales por aprobar (o su «sin
        // cargar» si nunca se supo y el intento falló).
        valesPorAprobar: _valesPorAprobar,
        valesSinCargar: _valesError && !_valesCargados,
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
        const EncabezadoSeccion(
          titulo: 'NECESITA TU ATENCIÓN',
          variante: VarianteEncabezado.panel,
          aviso: true),
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
                  oscuro ? AppColores.avisoPanelFondoOscuro : AppColores.avisoPanelFondoClaro,
              borderRadius: BorderRadius.circular(AppRadio.lg),
              border: Border.all(
                  color: oscuro
                      ? AppColores.avisoPanelBordeOscuro
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
                            ? AppColores.sobreNaranjaOscuro
                            : null, fontWeight: FontWeight.w700)),
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
    final fg = primario ? AppColores.sobreNaranjaOscuro : null;
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
                style: AppTexto.cuerpo.copyWith(color: fg, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
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
            child: _kpi('${fmtMonto(_ingresos)} CUP', 'Ingresos de $mes',
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
                  : 'Nómina del mes: ${fmtMonto(neto)} CUP a pagar',
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
          // 1.36 (136-307/317): el VALOR del KPI es el dato
          // de decisión: no se elide a letra grande.
          Text(valor,
              style: AppTexto.titulo.copyWith(color: color, fontWeight: FontWeight.w700),
              maxLines: 2),
          const SizedBox(height: 2),
          // 1.36 H-B3 (136-772): la etiqueta también cede
          // con elipsis — a 360 dp con texto grande la
          // tarjeta desbordaba por ella.
          Text(etiqueta,
              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
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
                            // 1.36 H-B3 (136-822): un día a
                            // CERO no pinta barra (antes 6 px
                            // naranjas simulaban actividad).
                            child: ((f['monto'] as num?)
                                            ?.toDouble() ??
                                        0) <=
                                    0
                                ? const SizedBox.shrink()
                                : Container(
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
                                      borderRadius:
                                          BorderRadius.circular(3),
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
    // pendientes, sin badge).
    // 1.28 (M5-C1 ★ ÍTEM FIJO): los títulos pasan a los
    // NOMBRES CORTOS («Caja y dinero», «Clientes e
    // invitados», «Equipo y turnos», «Suplementos y
    // contenido», «Configuración y datos», «Control y
    // sistema») y el resumen estático cede el sitio a la
    // LÍNEA DE ESTADO VIVA de cada módulo. Los
    // descriptores (icono, color, título, estado, badge)
    // salen de la función pura modulosPanel
    // (panel_modulos.dart); las TARJETAS de cada módulo
    // no se mueven: se emparejan por índice, como antes.
    // 1.29 (Oleada 5, D-23): UNA derivación de ítems
    // por construcción alimenta el distintivo de cada
    // fila Y la franja «POR REVISAR» de su pantalla.
    final items = _itemsPorRevisar();
    final datos = _datosModulos(items: items);
    final tarjetasPorModulo = <List<Widget> Function()>[
      _tarjetasModuloCaja,
      _tarjetasModuloClientes,
      _tarjetasModuloEquipo,
      _tarjetasModuloSuplementos,
      _tarjetasModuloPrecios,
      _tarjetasModuloControl,
    ];
    const ordenModulos = [
      ModuloPanel.caja,
      ModuloPanel.clientes,
      ModuloPanel.equipo,
      ModuloPanel.suplementos,
      ModuloPanel.configuracion,
      ModuloPanel.control,
    ];
    // 1.30 (Oleada D6, UI130-32): la lista de módulos
    // adopta la cascada de la fundación (como el Home):
    // las filas aparecen escalonadas solo al abrir.
    return EntradaCascada(
      child: Container(
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(color: AppColores.borde(context)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < datos.length; i++) ...[
            if (i > 0)
              Divider(height: 1, color: AppColores.borde(context)),
            ItemCascada(
              indice: i,
              child: FilaModuloPanel(
              dato: datos[i],
              // Pulso sutil si el contador SUBIÓ desde
              // la última visita (M5-C1).
              pulso: datos[i].badge != null &&
                  datos[i].badge! > (_badgesPrevios[datos[i].titulo] ?? 0),
              onTap: () => _ir(_ModuloAdminScreen(
                  titulo: datos[i].titulo,
                  // 1.30 (Oleada 5, H-06): PROVEEDORES,
                  // no la foto del momento: al volver de
                  // una tarjeta, la señal de retorno
                  // reconstruye la pantalla con la
                  // derivación y las tarjetas frescas.
                  obtenerItems: () =>
                      _itemsPorRevisar()[ordenModulos[i]] ?? const [],
                  onAbrirItem: (item) {
                    // La pantalla del módulo se cierra y
                    // el destino abre sobre el Panel: al
                    // volver, la recarga del Panel ya trae
                    // el ítem resuelto fuera de la lista y
                    // del distintivo, en la misma foto.
                    Navigator.of(context).pop();
                    _abrirItemPorRevisar(item);
                  },
                  obtenerTarjetas: tarjetasPorModulo[i],
                  senalRetorno: _senalRetorno)),
              ),
            ),
          ],
        ],
      ),
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
        // 1.36 (136-306/313): rol cabeceraPanel.
        style: AppTexto.cabeceraPanel.copyWith(
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
        // SL-9 (G09-10): el texto dice la acción del toque, no
        // cómo está implementada la puerta.
        'Liquidar en la Caja',
        () => _irACajaPilar(),
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
      // Congelación 0.5: SOLO el dueño (los motivos pueden
      // traer datos de salud; el espejo ni siquiera baja al
      // teléfono de un entrenador).
      if (AuthService().isOwner)
        _tarjetaFlujo(
          Icons.ac_unit_rounded,
          'Congelaciones',
          'Pausas de mensualidad pedidas desde la app de Clientes',
          () => _ir(const CongelacionesScreen()),
        ),
    ];
  }

  // -- Módulo 2 · Clientes, Invitados y Comunicación --------------------------
  List<Widget> _tarjetasModuloClientes() {
    return [
      // 1.29 (Oleada 5, FA-04): la línea viva de tarifas
      // por revisar, con LA MISMA cifra que el aviso de
      // la lista de Tarifas (misma fuente fusionada,
      // mismo predicado): un número, dos escaparates.
      // Sin nada por revisar, la línea no existe.
      if (_tarifasPorRevisar > 0)
        _tarjetaFlujo(
          Icons.local_offer_rounded,
          _tarifasPorRevisar == 1
              ? '1 tarifa especial por revisar'
              : '$_tarifasPorRevisar tarifas especiales por revisar',
          'Vencidas o por vencer esta semana',
          () => _ir(const TarifasScreen()),
        ),
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
        // 1.28 (M5-B2): el conteo de vales se ve en la
        // propia tarjeta, sin entrar al hub.
        _valesPorAprobar > 0
            ? (_valesPorAprobar == 1
                ? '1 vale por aprobar · catálogo de premios'
                : '$_valesPorAprobar vales por aprobar · '
                    'catálogo de premios')
            : 'Vales por aprobar y catálogo de premios por logro',
        () => _ir(const PremiosHubScreen()),
      ),
      // 1.27 (Comunidad MVP, Pieza G): los perfiles
      // visibles de la Comunidad y su ocultación.
      // 1.29 (Comunidad C3, COM-25): el distintivo de
      // la tarjeta son los reportes NUEVOS por
      // revisar (pendientes sobre la marca de
      // vistos, DF-27), en el resumen como en Premios.
      _tarjetaFlujo(
        Icons.groups_rounded,
        'Comunidad',
        _reportesComunidadNuevos > 0
            ? (_reportesComunidadNuevos == 1
                ? '1 reporte nuevo por revisar · '
                    'perfiles de los clientes'
                : '$_reportesComunidadNuevos reportes '
                    'nuevos por revisar · perfiles de '
                    'los clientes')
            : 'Perfiles visibles de los clientes y ocultación',
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
      // 1.29 (Oleada 5, D-23): la puerta que el ítem de
      // Equipo no tenía dentro de su módulo — los
      // reportes de caja viven en la pantalla de cierre
      // (la misma que abre la franja «POR REVISAR»).
      _tarjetaFlujo(
        Icons.point_of_sale_rounded,
        'Reportes de caja del día',
        'Cierres y reportes por turno, hoy y días pasados',
        () => _ir(_pantallaCierre()),
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
        // SL-9 (G09-5): la tarjeta dice la ACCIÓN que abre el
        // toque, no el estado de sync (eso ya lo dice la
        // cabecera de la app, una sola vez).
        'Diagnóstico y salud de la sincronización',
        () => _irLigera(const SaludSyncScreen()),
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
      // 1.29 (Oleada 5, D-23): la tarjeta vieja se
      // renombra «Incidencias (reportes)» — abre los
      // REPORTES de clientes y equipo (v1.3.0), no las
      // de sync; el homónimo confirmaba en falso. La
      // puerta que faltaba va justo debajo.
      _tarjetaFlujo(
        Icons.warning_amber_rounded,
        'Incidencias (reportes)',
        'Reportes de clientes y equipo, con su seguimiento',
        () => _ir(const ListaIncidenciasScreen()),
      ),
      _tarjetaFlujo(
        Icons.sync_problem_rounded,
        'Incidencias de sync',
        _incidenciasPend > 0
            ? (_incidenciasPend == 1
                ? '1 operación rechazada por revisar'
                : '$_incidenciasPend operaciones rechazadas '
                    'por revisar')
            : 'Operaciones que el servidor rechazó al sincronizar',
        () => _ir(const IncidenciasSyncScreen()),
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
/// 1.29 (Oleada 5, D-23): si el módulo tiene ítems «POR
/// REVISAR», la pantalla abre con su franja (la misma
/// lista de la que salió el distintivo); sin ítems, la
/// pantalla es la de siempre.
/// 1.30 (Oleada 5, H-06): con ESTADO y PROVEEDORES —
/// recibe obtenerItems/obtenerTarjetas en vez de las
/// fotos del momento, y escucha la señal de retorno del
/// Panel: al volver de una herramienta abierta desde una
/// tarjeta, se reconstruye re-invocando los proveedores
/// y la franja enseña la foto fresca (antes se quedaba
/// con la vieja). La vía de la franja (onAbrirItem: pop
/// de la pantalla + destino sobre el Panel) no cambia.
/// _irSoloLectura NO dispara la señal: su contrato es
/// «nada pudo cambiar» y volver de él no reconstruye nada.
class _ModuloAdminScreen extends StatefulWidget {
  final String titulo;
  final List<Widget> Function() obtenerTarjetas;
  final List<ItemPorRevisar> Function() obtenerItems;
  final void Function(ItemPorRevisar item)? onAbrirItem;
  final ValueListenable<int> senalRetorno;

  const _ModuloAdminScreen({
    required this.titulo,
    required this.obtenerTarjetas,
    required this.obtenerItems,
    required this.senalRetorno,
    this.onAbrirItem,
  });

  @override
  State<_ModuloAdminScreen> createState() => _ModuloAdminScreenState();
}

class _ModuloAdminScreenState extends State<_ModuloAdminScreen> {
  @override
  void initState() {
    super.initState();
    widget.senalRetorno.addListener(_alVolver);
  }

  @override
  void dispose() {
    widget.senalRetorno.removeListener(_alVolver);
    super.dispose();
  }

  /// La señal llega DESPUÉS de la recarga del Panel:
  /// basta reconstruir re-invocando los proveedores.
  void _alVolver() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final itemsPorRevisar = widget.obtenerItems();
    final tarjetas = widget.obtenerTarjetas();
    return Scaffold(
      appBar: appBarIron(context, widget.titulo),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          if (itemsPorRevisar.isNotEmpty && widget.onAbrirItem != null)
            FranjaPorRevisar(
                items: itemsPorRevisar, onTapItem: widget.onAbrirItem!),
          ...tarjetas,
        ],
      ),
    );
  }
}

/// Datos que devuelve el diálogo de tipo de pago al guardar.
typedef _DatosTipoPago = ({
  String nombre,
  String monto,
  String dias,
});

/// 1.30 (Oleada 7, clase B): diálogo de tipo de pago (editar
/// / nuevo) como StatefulWidget propio: posee y dispone sus
/// tres controladores (antes se creaban en el método y nunca
/// se liberaban; el dispose tras showDialog está prohibido
/// por Argón #11). Devuelve los textos al guardar o null.
class _DialogoTipoPago extends StatefulWidget {
  final String titulo;
  final IconData icono;
  final String botonOk;
  final String etiquetaNombre;
  final String nombreIni;
  final String montoIni;
  final String diasIni;
  const _DialogoTipoPago({
    required this.titulo,
    required this.icono,
    required this.botonOk,
    this.etiquetaNombre = 'Nombre',
    this.nombreIni = '',
    this.montoIni = '',
    this.diasIni = '',
  });

  @override
  State<_DialogoTipoPago> createState() => _DialogoTipoPagoState();
}

class _DialogoTipoPagoState extends State<_DialogoTipoPago> {
  late final TextEditingController _nombreCtrl;
  late final TextEditingController _montoCtrl;
  late final TextEditingController _diasCtrl;

  @override
  void initState() {
    super.initState();
    _nombreCtrl = TextEditingController(text: widget.nombreIni);
    _montoCtrl = TextEditingController(text: widget.montoIni);
    _diasCtrl = TextEditingController(text: widget.diasIni);
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _montoCtrl.dispose();
    _diasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: widget.titulo,
      iconoTitulo: widget.icono,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CampoTexto(
              controller: _nombreCtrl,
              etiqueta: widget.etiquetaNombre),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _montoCtrl,
              etiqueta: 'Monto (CUP)',
              teclado: const TextInputType
                  .numberWithOptions(decimal: true)),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _diasCtrl,
              etiqueta: 'Días que cubre',
              teclado: TextInputType.number),
        ],
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context, (
                  nombre: _nombreCtrl.text,
                  monto: _montoCtrl.text,
                  dias: _diasCtrl.text,
                )),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
              ),
            ),
            child: Text(widget.botonOk)),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Pago a entrenadores»
/// como StatefulWidget propio: posee y dispone su
/// controlador (antes se creaba en el método y nunca se
/// liberaba). Devuelve el valor válido (> 0) o null.
class _DialogoPagoEntrenador extends StatefulWidget {
  final int inicial;
  const _DialogoPagoEntrenador({required this.inicial});

  @override
  State<_DialogoPagoEntrenador> createState() =>
      _DialogoPagoEntrenadorState();
}

class _DialogoPagoEntrenadorState
    extends State<_DialogoPagoEntrenador> {
  late final TextEditingController _ctrl;
  // SL-9 (G09-3): el error de validación vive dentro.
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.inicial}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pago a entrenadores'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'CUP por cada cliente que pagó su mensualidad:'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              suffixText: 'CUP',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.cuerpo
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        BotonPrimario(
          texto: 'Guardar',
          onPressed: () {
              // SL-9 (G09-3): validar ANTES de cerrar — antes un
              // «12x» o un 0 cerraban el diálogo en silencio
              // (pop con null = cancelar) y parecía guardado.
              final v = int.tryParse(_ctrl.text.trim());
              if (v == null || v <= 0) {
                setState(() => _error =
                    'Pago inválido: escribe un número mayor que 0.');
                return;
              }
              Navigator.pop(context, v);
            },
          expandido: false,
        ),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Confirmar entrega»
/// como StatefulWidget propio: posee y dispone el
/// controlador de la nota (antes se creaba en el método y
/// nunca se liberaba). Devuelve la nota al confirmar o
/// null si se cancela.
class _DialogoConfirmarEntrega extends StatefulWidget {
  final String nombre;
  const _DialogoConfirmarEntrega({required this.nombre});

  @override
  State<_DialogoConfirmarEntrega> createState() =>
      _DialogoConfirmarEntregaState();
}

class _DialogoConfirmarEntregaState
    extends State<_DialogoConfirmarEntrega> {
  final _notaCtrl = TextEditingController();

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Confirmar entrega',
      iconoTitulo: Icons.done_all_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '¿Confirmas que recibiste el dinero pendiente de '
              '"${widget.nombre}"? Su pendiente se pondrá en cero.',
              style: AppTexto.cuerpo),
          const SizedBox(height: 12),
          CampoTexto(
            controller: _notaCtrl,
            etiqueta: 'Nota (opcional)',
            hint: 'Ej: entregó en dos partes',
            maxLineas: 2,
          ),
        ],
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context, _notaCtrl.text),
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
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Registrar recogida»
/// como StatefulWidget propio: posee y dispone su
/// controlador (antes se creaba en el método y nunca se
/// liberaba). Devuelve el monto escrito o null si se
/// cancela.
class _DialogoRegistrarRecogida extends StatefulWidget {
  final String nombre;
  final double pendiente;
  const _DialogoRegistrarRecogida(
      {required this.nombre, required this.pendiente});

  @override
  State<_DialogoRegistrarRecogida> createState() =>
      _DialogoRegistrarRecogidaState();
}

class _DialogoRegistrarRecogidaState
    extends State<_DialogoRegistrarRecogida> {
  late final TextEditingController _montoCtrl;

  @override
  void initState() {
    super.initState();
    _montoCtrl = TextEditingController(
        text: widget.pendiente > 0
            ? widget.pendiente.toStringAsFixed(0)
            : '');
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Registrar recogida',
      iconoTitulo: Icons.handshake_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Entrenador: ${widget.nombre}',
              style: AppTexto.cuerpo),
          Text(
              'Pendiente visible: ${fmtMonto(widget.pendiente)} CUP',
              style: AppTexto.cuerpo),
          const SizedBox(height: 12),
          CampoTexto(
            controller: _montoCtrl,
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
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context, _montoCtrl.text),
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
    );
  }
}
