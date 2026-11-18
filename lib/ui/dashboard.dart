/// 📊 Dashboard: resumen del negocio de un vistazo.
///
/// Ingresos de hoy / últimos 7 días / mes, activos vs vencidos y
/// pendiente a entregar por entrenador.
library;

import '../app_log.dart';
import '../errores_sync.dart';
import 'package:flutter/material.dart';

import '../negocio.dart';
import '../auth.dart';
import '../cliente_protegido.dart';
import '../conciliacion.dart';
import '../diferencias_caja.dart';
import '../invitados.dart';
import '../nomina_total.dart';
import '../permisos_entrenador.dart';
import '../permisos_visibilidad.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'arqueo.dart';
import 'diseno.dart';
import 'componentes.dart';
import 'hoja_accion.dart';
import 'buscar.dart';
import 'conciliacion.dart';
import 'skeleton.dart';
import 'cumpleanos.dart';
import 'diferencias_caja.dart';
import 'listas.dart';
import 'suplementos.dart';
import 'widgets.dart';
import 'detalle_pendiente.dart';

/// La fila de utilidad del balance (1.25 T06).
///
/// Con la nómina proyectada calculada, la «Utilidad neta
/// real» la descuenta: antes la fila titular era
/// ingresos − gastos aunque la nómina saliera dos líneas
/// encima, y hacía falta una segunda fila «estimada tras
/// nómina» para la cifra verdadera. Sin nómina calculada
/// (el cálculo falló o aún no llegó), la fila se etiqueta
/// con honestidad «Utilidad antes de nómina».
({String etiqueta, double valor}) filaUtilidadBalance({
  required double ingresos,
  required double gastos,
  required double? nominaProy,
}) {
  if (nominaProy != null) {
    return (
      etiqueta: 'Utilidad neta real',
      valor: ingresos - gastos - nominaProy,
    );
  }
  return (
    etiqueta: 'Utilidad antes de nómina',
    valor: ingresos - gastos,
  );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  double _hoy = 0;
  double _semana = 0;
  double _mes = 0;
  double _mesAnterior = 0;
  double _proyeccion = 0;
  Map<String, double> _porMetodo = {};
  Map<String, double> _porTipo = {};
  Map<String, Map<String, dynamic>> _mejorPeor = {};
  int _activos = 0;
  int _morosos = 0;
  // 1.32 (Compuertas, fila X-1): desglose de morosos de
  // +30 días, para que «vencidos» abra la pestaña que
  // promete (ver _tabVencidos).
  int _atras30 = 0;
  int _porVencer = 0;
  double _gastosMes = 0;
  int _nuevos = 0;
  List<Map<String, dynamic>> _ranking = [];
  int _inactivos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _ultimos7 = [];
  List<Map<String, dynamic>> _ultimos30 = [];
  String _periodoGrafico = '7'; // 7 | 30
  // Dashboard 1.19 (H1/Q6 Argón): urgencias del bloque superior,
  // balance y fila Plus/Casa. _nominaProy queda en null hasta que
  // el cálculo devuelve un número (nunca se muestra un neto
  // inventado); _plusVigentes null = sin dato (sin red o más
  // invitados que el tope de la página), la fila lo omite.
  int _vencenHoy = 0;
  int _cumpleHoy = 0;
  double? _nominaProy;
  int _casaActivas = 0;
  List<Map<String, dynamic>> _stockBajo = [];
  List<Map<String, dynamic>> _turnosOlvidados = [];
  int? _plusVigentes;
  // T4 (1.20): transferencias por transferencia sin comprobar
  // (pendientes + con problema) para el bloque «Hoy hay que…».
  int _porComprobar = 0;
  // T5 (1.20): expedientes de diferencia de caja abiertos del
  // dueño (FIN-23 de Argón: faltaba su fila en «Hoy hay que…»).
  int _diferenciasAbiertas = 0;
  // T5 (1.20): expedientes de diferencia del entrenador
  // (su vista de transparencia en «Mi dashboard»).
  List<Map<String, dynamic>> _misDiferencias = [];
  // (M2-BC C2) día seleccionado en el gráfico de ingresos
  // y su desglose para la burbuja (null = calculando).
  String? _diaSel;
  ({
    double efectivo,
    double transferencia,
    double diario,
    double suplementos,
    double servicios,
    double total,
    int movimientos,
  })? _detalleSel;

  /// 1.36 H-C3 (136-1029, GF-065): la lectura del día
  /// seleccionado falló (la burbuja lo dice, no «Calculando…»).
  bool _falloDetalleDia = false;

  // Vista por rol (v1.2): el entrenador ve solo sus propios números.
  final _auth = AuthService();
  bool get _esDueno => _auth.isOwner;

  /// 1.32 (Compuertas, fila X-1 — la D-3 del barrido de la
  /// 1.31 seguía viva): la pestaña de Listas que promete la
  /// cifra «vencidos». La cifra cuenta a TODOS los morosos
  /// (morosos()); el destino lo dicta el oráculo compartido
  /// urgenciaVencimientos (el mismo de Home): con atrasados
  /// de +30 días se abre SU pestaña (3); solo leves, la de
  /// −30 días (2). Antes ambos toques abrían siempre la 2 y
  /// los peores quedaban fuera de la vista prometida.
  int get _tabVencidos => urgenciaVencimientos(
        atrasLeve: (_morosos - _atras30).clamp(0, _morosos),
        atras30: _atras30,
      ).tabInicial;
  // Campos de la vista del entrenador.
  double _miHoy = 0;
  double _miSemana = 0;
  double _miMes = 0;
  double _miPendCup = 0;
  double _miPendUsd = 0;
  Map<String, double> _miPorMetodo = {};
  Map<String, double> _miPorTipo = {};
  Map<String, Map<String, dynamic>> _miMejorPeor = {};
  // Dashboard 1.19 (H5 Argón): «Hoy en sala» del entrenador
  // (nombres ya filtrados por protegidos). _salaCargada evita
  // mostrar el bloque vacío antes de la primera carga.
  List<String> _cumpleHoyNombres = [];
  List<String> _vencenHoyNombres = [];
  bool _salaCargada = false;

  static const naranja = AppColores.naranja;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  // Versión de carga (panel 2026-10-21): una recarga nueva invalida
  // el resultado de cualquier carga anterior aún en vuelo, para que
  // datos viejos no sobrescriban datos frescos. `_cargando` solo
  // gobierna la PRIMERA carga (spinner de pantalla completa); las
  // recargas conservan los datos visibles y el scroll.
  int _versionCarga = 0;

  Future<void> _cargar() async {
    final v = ++_versionCarga;
    try {
      if (!_esDueno) {
        await _cargarEntrenador(v);
        return;
      }
      final mesIso = hoyHabanaIso().substring(0, 7);
      // H2 (Argón): las 17 lecturas en serie pasan a 3 esperas
      // lanzadas a la vez (ingresos / clientes / novedades del
      // dashboard); dentro de cada grupo las lecturas corren en
      // paralelo. NO se añaden consultas nuevas en serie.
      // (M2-A A11) las diez cifras de ingresos salen de UNA
      // foto de una pasada por tabla (fotoIngresosDashboard),
      // no de diez funciones que re-escaneaban los espejos.
      final fIngresos = fotoIngresosDashboard();
      final fClientes = Future.wait([
        activosCount(),
        morosos(),
        // Una sola lectura particionada (ver nota en negocio.dart):
        // por vencer (sin hoy) + vencen hoy, sin 2ª consulta.
        vencimientosResumen(dias: 3),
        gastosDelMes(mesIso),
        nuevosEsteMes(),
        rankingEntrenadores(),
        inactivosCount(),
        pendientePorEntrenador(),
        // 1.32 (Compuertas, fila X-1): el desglose +30 días
        // viaja en la MISMA foto paralela (sin lecturas en
        // serie nuevas): es subconjunto exacto de morosos().
        atrasados(masDe30: true),
      ]);
      final fNovedades = Future.wait([
        // Un fallo del pre-cálculo de nómina no puede tumbar todo
        // el panel: degrada a null y se conserva el valor anterior.
        totalNetoNominaMes(mesIso).catchError((_) => null),
        cumpleanosHoyCount(),
        cuentasCasaActivasCount(),
        alertasStockBajo(),
        turnosAbiertosAyer(),
        InvitadosService().contarPlusVigentes(),
        // T4 (1.20): transferencias por comprobar del dueño.
        // Un fallo degrada a -1 y se conserva el valor anterior.
        ConciliacionService.instance
            .conteoPorComprobar()
            .catchError((_) => -1),
        // T5 (1.20): diferencias de caja abiertas del dueño
        // (FIN-23 de Argón). Misma degradación a -1.
        DiferenciasCajaService.instance
            .conteoAbiertas()
            .catchError((_) => -1),
      ]);
      // Panel Terra B2: cada grupo se espera por separado. Un fallo
      // en un grupo ya no tumba los otros dos: el grupo que falló
      // conserva los valores anteriores y los demás se aplican.
      FotoIngresos? ing;
      List<dynamic>? cli;
      List<dynamic>? nov;
      try {
        ing = await fIngresos;
      } catch (_) {}
      try {
        cli = await fClientes;
      } catch (_) {}
      if (mounted && v == _versionCarga) {
        setState(() {
          if (ing != null) {
            _hoy = ing.hoy;
            _semana = ing.semana;
            _mes = ing.mes;
            _mesAnterior = ing.mesAnterior;
            _proyeccion = ing.proyeccion;
            _porMetodo = ing.porMetodo;
            _porTipo = ing.porTipo;
            _mejorPeor = ing.mejorPeor;
            _ultimos7 = ing.ultimos7;
            _ultimos30 = ing.ultimos30;
          }
          if (cli != null) {
            final venc = cli[2]
                as ({
                  List<Map<String, dynamic>> porVencer,
                  List<Map<String, dynamic>> vencenHoy,
                });
            _activos = cli[0] as int;
            _morosos = cli[1] as int;
            // H3: la estadística sigue siendo el total 3d (sin hoy);
            // el subtítulo «N hoy» sale del mismo resumen.
            _porVencer = venc.porVencer.length;
            _vencenHoy = venc.vencenHoy.length;
            _gastosMes = cli[3] as double;
            _nuevos = cli[4] as int;
            _ranking = cli[5] as List<Map<String, dynamic>>;
            _inactivos = cli[6] as int;
            _pend = cli[7] as List<Map<String, dynamic>>;
            _atras30 = (cli[8] as List).length;
          }
          _cargando = false;
          _falloCarga = false;
        });
      }
      // Campo 2026-11-02 (1.22): las novedades se aplican en
      // una SEGUNDA pintura. El grupo incluye la única lectura
      // de red del panel (Plus vigentes por RPC de Invitados):
      // con la conexión colgada, la primera pintura ya salió
      // con los datos locales y el panel no queda en
      // «Cargando panel…» (y la RPC de lectura ahora tiene
      // timeout en InvitadosService).
      try {
        nov = await fNovedades;
      } catch (_) {}
      if (mounted && v == _versionCarga && nov != null) {
        final novedades = nov;
        // 1.36 H-C3 (136-1028, GF-064): conversión TOLERANTE
        // índice a índice y aplicación por separado: un
        // índice con forma inesperada conserva su valor
        // anterior y NO aborta las demás novedades (antes un
        // solo cast estricto tumbaba el grupo entero y las
        // urgencias quedaban viejas).
        int? intTol(int i) =>
            novedades.length > i ? (novedades[i] as num?)?.toInt() : null;
        List<Map<String, dynamic>>? listaTol(
            int i, List<Map<String, dynamic>> anterior) {
          if (novedades.length <= i) return anterior;
          final v = novedades[i];
          if (v is! List) return anterior;
          try {
            return [
              for (final e in v)
                Map<String, dynamic>.from(e as Map),
            ];
          } catch (_) {
            return anterior;
          }
        }

        setState(() {
          // (M2-A A11) si el precálculo falló, la nómina
          // anterior NO se conserva (podía ser de otro mes y
          // la fila seguía diciendo «Utilidad neta real»):
          // null devuelve la etiqueta honesta «antes de
          // nómina» de filaUtilidadBalance.
          _nominaProy = novedades.isNotEmpty
              ? (novedades[0] as num?)?.toDouble()
              : null;
          _cumpleHoy = intTol(1) ?? _cumpleHoy;
          _casaActivas = intTol(2) ?? _casaActivas;
          _stockBajo = listaTol(3, _stockBajo) ?? _stockBajo;
          _turnosOlvidados =
              listaTol(4, _turnosOlvidados) ?? _turnosOlvidados;
          _plusVigentes = intTol(5) ?? _plusVigentes;
          final porComprobarT4 = intTol(6);
          if (porComprobarT4 != null && porComprobarT4 >= 0) {
            _porComprobar = porComprobarT4;
          }
          final diferenciasT5 = intTol(7);
          if (diferenciasT5 != null && diferenciasT5 >= 0) {
            _diferenciasAbiertas = diferenciasT5;
          }
        });
      }
    } catch (e) {
      // Un fallo de lectura no debe dejar el spinner eterno ni
      // borrar lo ya mostrado: se conserva el estado anterior.
      // (1.36 H-B4 136-1027) y se DICE: banner de error con
      // reintento (antes el panel quedaba en ceros mudos si
      // era la primera carga).
      AppLog.error('ui', 'dashboard_carga_fallo', d: '$e');
      if (mounted && v == _versionCarga) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  /// Carga los números propios del entrenador (dashboard por rol, v1.2).
  Future<void> _cargarEntrenador(int v) async {
    // §14 (1.20): degradación POR MÉTRICA. Antes las nueve
    // lecturas compartían un solo try: si una fallaba (p. ej.
    // pendienteEntrega), el panel entero quedaba sin cifras
    // aunque las demás estuvieran bien. Ahora cada lectura
    // conserva su valor anterior si falla (mismo patrón que
    // las diferencias T5 y los índices del panel del dueño).
    Future<T> seguro<T>(Future<T> lectura, T anterior) async {
      try {
        return await lectura;
      } catch (_) {
        return anterior;
      }
    }

    try {
      final tid = _auth.telegramId;
      // 1.36 H-C3 (136-1033, GF-069): las lecturas corren en
      // PARALELO (Future.wait), cada una con su seguro por
      // métrica de siempre (antes ocho esperas en serie).
      final r = await Future.wait<dynamic>([
        seguro(ingresosHoyPorEntrenador(tid), _miHoy),
        seguro(ingresosSemanaPorEntrenador(tid), _miSemana),
        seguro(cobradoMes(tid), _miMes),
        seguro(pendienteEntrega(tid), _miPendCup),
        seguro(pendienteEntregaUsd(tid), _miPendUsd),
        seguro(ingresosPorMetodoEntrenador(tid), _miPorMetodo),
        seguro(ingresosPorTipoEntrenador(tid), _miPorTipo),
        seguro(mejorPeorDiaEntrenador(tid), _miMejorPeor),
      ]);
      final hoy = r[0] as double;
      final semana = r[1] as double;
      final mes = r[2] as double;
      final pendCup = r[3] as double;
      final pendUsd = r[4] as double;
      final porMet = r[5] as Map<String, double>;
      final porTip = r[6] as Map<String, double>;
      final mp = r[7] as Map<String, Map<String, dynamic>>;
      // T5 (1.20): sus expedientes de diferencia de caja
      // (degrada en silencio: un fallo no tumba el panel).
      var misDif = _misDiferencias;
      try {
        if (tid != null) {
          misDif = await DiferenciasCajaService.instance
              .deEntrenador(tid);
        }
      } catch (_) {}
      // H5 (Argón): «Hoy en sala» sin montos. Los nombres ya
      // vienen filtrados: un cliente protegido NO se le muestra
      // al entrenador (misma regla que la bandeja de avisos).
      // Si la lectura de la sala falla, se conservan los
      // nombres anteriores en vez de vaciar la sección.
      var nombresCump = _cumpleHoyNombres;
      var nombresVencen = _vencenHoyNombres;
      try {
        final sala = await Future.wait([
          cumpleanosProximos(dias: 0),
          vencenHoy(),
        ]);
        final cump = <String>[];
        for (final c in sala[0]) {
          if ((c['_dias_para'] as int?) != 0) continue;
          if (esVistaProtegida(c, esDueno: false)) continue;
          final n = '${c['nombre'] ?? ''}'.trim();
          if (n.isNotEmpty) cump.add(n);
        }
        nombresCump = cump;
        final vencen = <String>[];
        for (final c in sala[1]) {
          if (esVistaProtegida(c, esDueno: false)) continue;
          final n = '${c['nombre'] ?? ''}'.trim();
          if (n.isNotEmpty) vencen.add(n);
        }
        nombresVencen = vencen;
      } catch (_) {}
      if (mounted && v == _versionCarga) {
        setState(() {
          _miHoy = hoy;
          _miSemana = semana;
          _miMes = mes;
          _miPendCup = pendCup;
          _miPendUsd = pendUsd;
          _miPorMetodo = porMet;
          _miPorTipo = porTip;
          _miMejorPeor = mp;
          _cumpleHoyNombres = nombresCump;
          _vencenHoyNombres = nombresVencen;
          _misDiferencias = misDif;
          _salaCargada = true;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted && v == _versionCarga) {
        setState(() => _cargando = false);
      }
    }
  }

  /// (M2-BC C1) Tarjeta héroe del Dashboard: la foto del
  /// mes de un vistazo en la tarjeta con el gradiente de la
  /// marca — ingresos del mes, utilidad (con la etiqueta
  /// honesta de [filaUtilidadBalance]) y pendiente a
  /// entregar — con las cifras animadas de la casa.
  Widget _tarjetaHeroe() {
    final utilidad = filaUtilidadBalance(
        ingresos: _mes, gastos: _gastosMes, nominaProy: _nominaProy);
    var pendCup = 0.0;
    var pendUsd = 0.0;
    for (final t in _pend) {
      pendCup += (t['total'] as double?) ?? 0;
      pendUsd += (t['total_usd'] as double?) ?? 0;
    }
    return Container(
      padding: const EdgeInsets.all(AppEspacio.lg),
      decoration: BoxDecoration(
        gradient: AppColores.gradienteNaranja,
        borderRadius: BorderRadius.circular(AppRadio.lg),
        boxShadow: [
          BoxShadow(
            color: AppColores.naranja.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ESTE MES',
              style: AppTexto.metadato.copyWith(
                  color: Colors.white70,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1)),
          const SizedBox(height: AppEspacio.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 1.36 H-C3 (136-1031, GF-067): la cifra del
              // héroe se encoge con FittedBox en vez de
              // desbordar con montos grandes.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: MontoAnimado(
                      valor: _mes,
                      formato: fmtMonto,
                      style: AppTexto.display.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('CUP de ingresos',
                    style: AppTexto.secundario
                        .copyWith(color: Colors.white)),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  child: _heroeCifra(utilidad.etiqueta, utilidad.valor,
                      'CUP')),
              Expanded(
                  child: _heroeCifra(
                      'Pendiente a entregar',
                      pendCup,
                      pendUsd > 0
                          ? 'CUP + ${fmtMonto(pendUsd)} USD'
                          : 'CUP')),
            ],
          ),
          // 1.35 (UX-12): la comparativa contra el mes
          // anterior vive INTEGRADA en el héroe — deja de
          // ser una tarjeta suelta bajo los ingresos. El
          // dato y su condición son los de siempre (solo
          // con mes anterior > 0).
          if (_mesAnterior > 0) ...[
            const SizedBox(height: AppEspacio.md),
            const Divider(color: Colors.white24, height: 1),
            const SizedBox(height: 10),
            Builder(builder: (context) {
              final diff = _mes - _mesAnterior;
              final pct = diff / _mesAnterior * 100;
              final sube = diff >= 0;
              return Row(
                children: [
                  Icon(
                      sube
                          ? Icons.trending_up_rounded
                          : Icons.trending_down_rounded,
                      size: 20,
                      color: Colors.white),
                  const SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: Text(
                      sube
                          ? 'Sube ${pct.toStringAsFixed(0)}% vs mes anterior '
                              '(${fmtMonto(_mesAnterior)} CUP)'
                          : 'Baja ${pct.abs().toStringAsFixed(0)}% vs mes anterior '
                              '(${fmtMonto(_mesAnterior)} CUP)',
                      style: AppTexto.secundario
                          .copyWith(color: Colors.white),
                    ),
                  ),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _heroeCifra(String etiqueta, double valor, String sufijo) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta,
            style:
                AppTexto.metadato.copyWith(color: Colors.white70)),
        const SizedBox(height: 2),
        MontoAnimado(
            valor: valor,
            formato: fmtMonto,
            style: AppTexto.subtitulo.copyWith(
                color: Colors.white, fontWeight: FontWeight.bold)),
        Text(sufijo,
            style:
                AppTexto.minuscula.copyWith(color: Colors.white70)),
      ],
    );
  }

  /// Detalle de ingresos por período (v1.0.11).
  /// Muestra desglose por método de pago.
  Future<void> _detalleIngresos(String periodo) async {
    // 1.36 H-C3 (136-1029, GF-065): un fallo de la lectura
    // se DICE (snack amable); antes la hoja simplemente no
    // se abría y no pasaba nada visible.
    try {
      await _detalleIngresosDatos(periodo);
    } catch (e) {
      AppLog.error('ui', 'dashboard_detalle_ingresos_fallo',
          d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudo cargar el detalle: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _detalleIngresosDatos(String periodo) async {
    final titulo = periodo == 'hoy'
        ? 'Ingresos de hoy'
        : periodo == 'semana'
            ? 'Ingresos últimos 7 días'
            : 'Ingresos del mes';
    // Partición por ORIGEN (panel 2026-10-21): cada movimiento cae
    // en UNA sola fila y las filas suman el total. Los pagos se
    // clasifican por método (todo lo que no sea exactamente
    // 'transferencia' va a Efectivo, la regla histórica); diarios y
    // suplementos tienen su fila propia y ya NO se pliegan dentro
    // de Efectivo (antes se contaban dos veces).
    final pagos = await pagosDelPeriodo(periodo);
    double efectivo = 0,
        transferencia = 0,
        diario = 0,
        suplementos = 0,
        servicios = 0;
    for (final p in pagos) {
      final m = (p['monto'] as num?)?.toDouble() ?? 0;
      switch ('${p['origen'] ?? 'pago'}') {
        case 'diario':
          diario += m;
        case 'suplemento':
          suplementos += m;
        case 'servicios':
          servicios += m;
        default:
          if ('${p['metodo']}' == 'transferencia') {
            transferencia += m;
          } else {
            efectivo += m;
          }
      }
    }
    final total =
        efectivo + transferencia + diario + suplementos + servicios;
    if (!mounted) return;
    // SL-3 (G01-5): la hoja de la casa (showHojaIron, la
    // misma de _detalleDia), no showModalBottomSheet crudo.
    // Mismo contenido y comportamiento: filas por origen,
    // total animado y conteo de movimientos.
    showHojaIron(
      context,
      titulo: titulo,
      icono: Icons.payments_rounded,
      cuerpo: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1.29 (Oleada 2, D-11): las filas de método
          // llevan su punto categórico junto a la palabra
          // (efectivo dorado, transferencia azul).
          _filaDetalle('Efectivo', efectivo,
              punto: AppColores.metodoEfectivo),
          _filaDetalle('Transferencia', transferencia,
              punto: AppColores.metodoTransferencia),
          if (diario > 0) _filaDetalle('Pago diario', diario),
          if (suplementos > 0)
            _filaDetalle('Suplementos', suplementos),
          if (servicios > 0) _filaDetalle('Servicios', servicios),
          const Divider(),
          // 1.29 (Oleada 2, D-19): el total cuenta hasta
          // su cifra (MontoAnimado) en vez de texto plano.
          _filaDetalle('Total', total, negrita: true, animado: true),
          const SizedBox(height: AppEspacio.sm),
          Text('${pagos.length} movimientos registrados',
              style: AppTexto.secundario.copyWith(
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  Widget _filaDetalle(String etiqueta, double valor,
      {bool negrita = false, Color? punto, bool animado = false}) {
    final estiloValor = AppTexto.subtitulo.copyWith(
        color: negrita ? naranja : null, fontWeight: FontWeight.bold);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (punto != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: punto, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(etiqueta, style: AppTexto.subtitulo),
            ],
          ),
          if (animado)
            MontoAnimado(
              valor: valor,
              formato: (v) => '${fmtMonto(v)} CUP',
              style: estiloValor,
            )
          else
            Text('${fmtMonto(valor)} CUP', style: estiloValor),
        ],
      ),
    );
  }

  /// Vista del entrenador (v1.2): solo sus propios números.
  /// Sin ranking, sin totales globales, sin pendiente de otros.
  Widget _buildEntrenador() {
    // Permisos 2+3 (candado de UI): can_ver_cifras apagada =
    // el panel no muestra importes. Los cobros se registran
    // igual; solo cambia lo que esta pantalla enseña.
    if (!cifrasVisibles(
      esDueno: _esDueno,
      permisosCargados: PermisosEntrenador().cargado,
      canVerCifras: PermisosEntrenador().canVerCifras,
    )) {
      return Scaffold(
        appBar: appBarIron(
          context,
          'Mi dashboard',
          acciones: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _cargar,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(AppEspacio.lg),
          children: [
            const SyncBanner(),
            const SizedBox(height: AppEspacio.sm),
            // H5 (Argón): «Hoy en sala» va POR ENCIMA del candado
            // de cifras: no son cifras, y hoy el return temprano
            // lo ocultaba todo.
            if (_salaCargada) ...[
              const EncabezadoSeccion(titulo: 'Hoy en sala'),
              _bloqueHoyEnSala(),
              const SizedBox(height: AppEspacio.sm),
            ],
            Tarjeta(
              child: Text(
                PermisosEntrenador().cargado
                    ? 'El dueño desactivó la vista de cifras de '
                        'este panel. Tus cobros se siguen '
                        'registrando igual; pídele que active '
                        '«Ver cifras» si lo necesitas.'
                    : 'Cargando tus permisos… En cuanto se '
                        'comprueben, este panel muestra tus '
                        'cifras. Si tarda, revisa tu conexión y '
                        'toca el botón de actualizar.',
                style: AppTexto.cuerpo,
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Mi dashboard',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          // (M2-BC C5) esqueleto estructural también en la
          // vista del entrenador.
          ? ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: const [
                SyncBanner(),
                SizedBox(height: AppEspacio.sm),
                SkeletonLista(items: 3),
              ],
            )
          : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  const SyncBanner(),
                  const SizedBox(height: AppEspacio.sm),
                  // (1.36 H-B4 136-1027) la última carga
                  // falló: las cifras pueden estar viejas.
                  if (_falloCarga) ...[
                    Tarjeta(
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off_rounded,
                              color: AppColores.errorTexto(context)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No se pudo actualizar el panel: '
                              'se muestran los últimos datos '
                              'cargados.',
                              style: AppTexto.secundario,
                            ),
                          ),
                          TextButton(
                            onPressed: () => _cargar(),
                            child: const Text('Reintentar'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppEspacio.sm),
                  ],
                  // H5 (Argón): «Hoy en sala» también abre la vista
                  // sin candado, antes de las cifras.
                  if (_salaCargada) ...[
                    const EncabezadoSeccion(titulo: 'Hoy en sala'),
                    _bloqueHoyEnSala(),
                    const SizedBox(height: AppEspacio.lg),
                  ],
                  const EncabezadoSeccion(titulo: 'Mis cobros'),
                  Row(
                    children: [
                      _tarjetaSimple('Hoy', _miHoy, Icons.today_rounded),
                      const SizedBox(width: AppEspacio.sm),
                      _tarjetaSimple(
                          '7 días', _miSemana, Icons.date_range_rounded),
                      const SizedBox(width: AppEspacio.sm),
                      _tarjetaSimple('Este mes', _miMes,
                          Icons.calendar_month_rounded),
                    ],
                  ),
                  const EncabezadoSeccion(
                      titulo: 'Mi pendiente a entregar'),
                  Tarjeta(
                    // Q4 (Argón): el pendiente propio abre su
                    // desglose. (El onTap de las 3 tarjetas
                    // superiores es explícitamente no-P0: no va.)
                    onTap: _auth.telegramId == null
                        ? null
                        : () => _ir(DetallePendienteScreen(
                            trainerId: _auth.telegramId!,
                            nombre: _auth.displayName)),
                    child: Column(
                      children: [
                        _filaMonto('CUP', _miPendCup, 'CUP'),
                        if (_miPendUsd > 0) ...[
                          const Divider(height: 16),
                          _filaMonto(
                              'USD a entregar', _miPendUsd, 'USD'),
                        ],
                        if (_miPendCup <= 0 && _miPendUsd <= 0)
                          const Text('Nada pendiente. Todo entregado.',
                              style: AppTexto.secundario),
                      ],
                    ),
                  ),
                  // T5 (1.20): sus diferencias de caja, si
                  // tiene: transparencia (el expediente no
                  // descuenta nada automáticamente).
                  if (_misDiferencias.isNotEmpty) ...[
                    const EncabezadoSeccion(
                        titulo: 'Mis diferencias de caja'),
                    Tarjeta(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          // 1.29 (Oleada 2, D-A4): la tarjeta
                          // cortaba la lista a 5 EN SILENCIO
                          // (take(5) sin salida): del sexto
                          // expediente en adelante no existía
                          // en su vista. Ahora pinta 5 + «y N
                          // más», que lleva a la lista
                          // completa filtrada por él.
                          ListaDiferenciasResumen(
                            expedientes: _misDiferencias,
                            onVerMas: _auth.telegramId == null
                                ? null
                                : () => _ir(DiferenciasCajaScreen(
                                    soloEntrenadorTid:
                                        _auth.telegramId)),
                          ),
                          Text(
                            'El dueño abre un expediente cuando '
                            'falta dinero en una liquidación y no '
                            'es el arrastre normal. No se te '
                            'descuenta nada automáticamente.',
                            style: AppTexto.metadato.copyWith(
                                color: AppColores.textoSecundario(
                                    context)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const EncabezadoSeccion(
                      titulo: 'Desglose del mes'),
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        _filaDesglose(
                            'Efectivo',
                            _miPorMetodo['efectivo'] ?? 0,
                            _miMes),
                        _filaDesglose(
                            'Transferencia',
                            _miPorMetodo['transferencia'] ?? 0,
                            _miMes),
                        _filaDesglose(
                            'Suplementos',
                            _miPorMetodo['suplementos'] ?? 0,
                            _miMes),
                        // Ronda 3-9 #7: servicios del entrenador.
                        _filaDesglose(
                            'Servicios',
                            _miPorMetodo['servicios'] ?? 0,
                            _miMes),
                        const Divider(height: 16),
                        _filaDesglose(
                            'Mensualidades',
                            _miPorTipo['mensual'] ?? 0,
                            _miMes),
                        _filaDesglose(
                            'Pago diario',
                            _miPorTipo['diario'] ?? 0,
                            _miMes),
                        // D2: el bloque por tipo también suma el mes;
                        // faltaba Suplementos (panel 2026-10-21).
                        _filaDesglose(
                            'Suplementos',
                            _miPorTipo['suplementos'] ?? 0,
                            _miMes),
                        // Ronda 3-9 #7: servicios del entrenador.
                        _filaDesglose(
                            'Servicios',
                            _miPorTipo['servicios'] ?? 0,
                            _miMes),
                        if (_miMejorPeor.isNotEmpty) ...[
                          const SizedBox(height: AppEspacio.sm),
                          Text(
                            'Mi mejor día: ${fmtFecha(_miMejorPeor['mejor']!['dia'] as String?)} '
                            '(${fmtMonto(_miMejorPeor['mejor']!['monto'] as double)} CUP)',
                            style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                        context)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Tarjeta simple de monto para la vista del entrenador.
  Widget _tarjetaSimple(String titulo, double valor, IconData icono) {
    return Expanded(
      child: Tarjeta(
        padding:
            const EdgeInsets.symmetric(vertical: AppEspacio.lg, horizontal: AppEspacio.sm),
        child: Column(
          children: [
            Icon(icono, color: AppColores.textoSecundario(context), size: 24),
            const SizedBox(height: AppEspacio.sm),
            Text(titulo,
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
            const SizedBox(height: 2),
            MontoAnimado(
                valor: valor,
                formato: fmtMonto,
                style: AppTexto.metrica.copyWith(color: naranja)),
            Text('CUP',
                // 1.36 (136-306): la unidad de la cifra
                // principal es texto operativo: no va a 11.
                style: AppTexto.etiqueta.copyWith(color: AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
  }

  /// Fila de monto con etiqueta para la vista del entrenador.
  Widget _filaMonto(String etiqueta, double valor, String moneda) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(etiqueta, style: AppTexto.secundario),
        Text('${fmtMonto(valor)} $moneda',
            style: AppTexto.subtitulo.copyWith(color: naranja, fontWeight: FontWeight.bold)),
      ],
    );
  }

  /// 1.35 (UX-12): la banda segmentada de ingresos — las
  /// tres cifras (hoy, 7 días, este mes) en UNA tarjeta,
  /// con «hoy» encendida (tinte y cifra en la marca) y
  /// cada segmento tocable a su detalle, como lo eran
  /// las tres tarjetas de antes. Ni un dato más, ni uno
  /// menos.
  Widget _bandaIngresos() {
    return Tarjeta(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadio.lg),
        child: Row(
          children: [
            _segmentoIngreso('Hoy', _hoy, Icons.today_rounded,
                () => _detalleIngresos('hoy'),
                encendida: true),
            _segmentoIngreso('7 días', _semana,
                Icons.date_range_rounded,
                () => _detalleIngresos('semana')),
            _segmentoIngreso('Este mes', _mes,
                Icons.calendar_month_rounded,
                () => _detalleIngresos('mes')),
          ],
        ),
      ),
    );
  }

  Widget _segmentoIngreso(String titulo, double valor,
      IconData icono, VoidCallback onTap,
      {bool encendida = false}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: encendida
              ? AppColores.naranja.withValues(alpha: 0.12)
              : null,
          padding: const EdgeInsets.symmetric(
              vertical: AppEspacio.lg, horizontal: AppEspacio.sm),
          child: Column(
            children: [
              Icon(icono,
                  color: encendida
                      ? AppColores.naranja
                      : AppColores.textoSecundario(context),
                  size: 24),
              const SizedBox(height: AppEspacio.sm),
              Text(titulo,
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
              const SizedBox(height: 2),
              MontoAnimado(
                  valor: valor,
                  formato: fmtMonto,
                  style: AppTexto.metrica.copyWith(
                      color: encendida
                          ? AppColores.naranja
                          : AppColores.texto(context))),
              Text('CUP',
                  // 1.36 (136-306): texto operativo, no a 11.
                  style: AppTexto.etiqueta.copyWith(
                      color: AppColores.textoSecundario(context))),
            ],
          ),
        ),
      ),
    );
  }

  /// Navega a una pantalla y recarga al volver (v1.0.11).
  Future<void> _ir(Widget w) async {
    await Navigator.of(context)
        .push(RutaIron(builder: (_) => w));
    if (mounted) _cargar();
  }


  /// v1.0.15: desgloses por método y tipo + proyección.
  /// D2 (panel 2026-10-21): AMBOS bloques incluyen Suplementos y
  /// usan como denominador el total del mes (_mes, de ingresosMes),
  /// así cada bloque suma exactamente la tarjeta «Este mes».
  /// Antes el denominador era ef+tr y los suplementos no tenían
  /// fila: las filas no sumaban el mes y los % salían inflados.
  /// Dashboard 1.19 (Q2 Argón): el bloque es «Balance y desglose
  /// del mes»: Bloque A (método/tipo, lo de antes) + Bloque B
  /// (balance: brutos / gastos / nómina proyectada / utilidad
  /// neta real). El título de sección vive en el build
  /// (EncabezadoSeccion, H6); aquí ya no se repite.
  Widget _desgloses() {
    // 1.25 T06: la utilidad y su etiqueta salen de la
    // función única (con nómina, «real» la descuenta).
    final utilidad = filaUtilidadBalance(
        ingresos: _mes, gastos: _gastosMes, nominaProy: _nominaProy);
    // 1.36 H-C3 (136-1030, GF-066): acceso nulo-seguro con
    // toDouble (un monto entero en el mapa tumbaba el
    // desglose con el cast implícito).
    double de(Map<String, double> m, String k) =>
        (m[k] as num?)?.toDouble() ?? 0;
    final ef = de(_porMetodo, 'efectivo');
    final tr = de(_porMetodo, 'transferencia');
    final supM = de(_porMetodo, 'suplementos');
    final servM = de(_porMetodo, 'servicios');
    final men = de(_porTipo, 'mensual');
    final dia = de(_porTipo, 'diario');
    final supT = de(_porTipo, 'suplementos');
    final servT = de(_porTipo, 'servicios');
    final total = _mes;
    return Tarjeta(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filaDesglose('Efectivo', ef, total),
            _filaDesglose('Transferencia', tr, total),
            _filaDesglose('Suplementos', supM, total),
            _filaDesglose('Servicios', servM, total),
            const Divider(height: 16),
            _filaDesglose('Mensualidades', men, total),
            _filaDesglose('Pago diario', dia, total),
            _filaDesglose('Suplementos', supT, total),
            _filaDesglose('Servicios', servT, total),
            // Bloque B: balance (H1 Argón). Los gastos ya no son
            // una cifra que solo aparece sola: van dentro de la
            // terna junto a brutos, nómina y utilidad.
            const Divider(height: 16),
            Text('Balance',
                style:
                    AppTexto.cuerpo.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: AppEspacio.xs),
            _filaDetalle('Ingresos brutos', _mes),
            _filaDetalle('Gastos', _gastosMes),
            if (_nominaProy != null) ...[
              _filaDetalle('Nómina proyectada', _nominaProy!),
              Text(
                'Proyección, no cierre: se descuenta al cerrar el mes.',
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
              ),
            ],
            // 1.25 T06: la utilidad REAL ya descuenta la
            // nómina proyectada cuando está calculada (la
            // fila «estimada tras nómina» sobra); sin ella,
            // la etiqueta avisa: «Utilidad antes de nómina».
            _filaDetalle(utilidad.etiqueta, utilidad.valor,
                negrita: true),
            // Q3 (Argón): la proyección es «Ritmo de cierre
            // estimado» y NO se muestra los días 1–2 del mes: con
            // 1 día de ingreso, actual/1*díasMes proyecta 30× el
            // primer día y es puro ruido.
            if (_proyeccion > 0 && ahoraHabana().day >= 3) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Ritmo de cierre estimado',
                      style: AppTexto.secundario),
                  Text('${fmtMonto(_proyeccion.round())} CUP',
                      // 1.36 (136-296/314): importe tabular.
                      style: AppTexto.conTabulares(AppTexto.secundario.copyWith(color: naranja, fontWeight: FontWeight.bold))),
                ],
              ),
            ],
            // 1.36 H-C3 (136-1030, GF-066): «mejor» puede
            // faltar o traer el monto entero: sin `!` ni cast.
            if (_mejorPeor['mejor'] is Map) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(
                'Mejor día: ${fmtFecha('${(_mejorPeor['mejor'] as Map)['dia'] ?? ''}')} '
                '(${fmtMonto(((_mejorPeor['mejor'] as Map)['monto'] as num?)?.toDouble() ?? 0)} CUP)',
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
              ),
            ],
          ],
        ),
    );
  }

  Widget _filaDesglose(String etiqueta, double valor, double total) {
    final pct = total > 0 ? valor / total * 100 : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(etiqueta,
                  style: AppTexto.secundario)),
          Text('${fmtMonto(valor)} CUP',
              // 1.36 (136-296/314): importe tabular.
              style: AppTexto.conTabulares(AppTexto.secundario.copyWith(fontWeight: FontWeight.bold))),
          const SizedBox(width: AppEspacio.sm),
          Text('${pct.toStringAsFixed(0)}%',
              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  /// (M2-BC C2) selecciona un día del gráfico y carga su
  /// desglose para la burbuja (la hoja completa sigue en
  /// [_detalleDia]).
  Future<void> _seleccionarDia(String fecha) async {
    setState(() {
      _diaSel = fecha;
      _detalleSel = null;
      _falloDetalleDia = false;
    });
    // 1.36 H-C3 (136-1029, GF-065): si la lectura falla, la
    // burbuja lo dice con Reintentar (antes «Calculando…»
    // eterno).
    try {
      final r = await resumenIngresosDia(fecha);
      if (mounted && _diaSel == fecha) {
        setState(() => _detalleSel = r);
      }
    } catch (e) {
      AppLog.error('ui', 'dashboard_detalle_dia_fallo', d: '$e');
      if (mounted && _diaSel == fecha) {
        setState(() => _falloDetalleDia = true);
      }
    }
  }

  /// (M2-BC C2) burbuja del día tocado: total y desglose
  /// sin salir del Dashboard, con la puerta a la hoja
  /// completa de [_detalleDia].
  Widget _burbujaDia() {
    final fecha = _diaSel!;
    final d = _detalleSel;
    return Container(
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        border: Border.all(color: AppColores.borde(context)),
        borderRadius: BorderRadius.circular(AppRadio.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(fmtFecha(fecha),
                      style: AppTexto.subtitulo)),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Cerrar detalle del día',
                onPressed: () => setState(() {
                  _diaSel = null;
                  _detalleSel = null;
                }),
              ),
            ],
          ),
          if (_falloDetalleDia && d == null) ...[
            const Text('No se pudo cargar el detalle del día',
                style: AppTexto.secundario),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _seleccionarDia(fecha),
                child: const Text('Reintentar'),
              ),
            ),
          ] else if (d == null)
            const Text('Calculando…', style: AppTexto.secundario)
          else ...[
            Text(
              'Total: ${fmtMonto(d.total)} CUP · '
              '${d.movimientos} movimientos',
              style: AppTexto.cuerpo
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              'Efectivo ${fmtMonto(d.efectivo)} · '
              'Transferencia ${fmtMonto(d.transferencia)} · '
              'Diario ${fmtMonto(d.diario)}'
              '${d.suplementos > 0 ? ' · Suplementos ${fmtMonto(d.suplementos)}' : ''}'
              '${d.servicios > 0 ? ' · Servicios ${fmtMonto(d.servicios)}' : ''}',
              style: AppTexto.secundario,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _detalleDia(fecha),
                child: const Text('Detalle completo'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// v1.0.15: gráfico de días (7 o 30 según selector).
  /// D1 (estéticas 1.19): etiquetas legibles (11 px), día de hoy
  /// destacado en verde y mejor día en ámbar. Sin esto el monto
  /// iba en 8 px y el día en 7 px y no se leía ningún número.
  Widget _graficoDias() {
    final datos = _periodoGrafico == '30' ? _ultimos30 : _ultimos7;
    // 1.36 H-C3 (136-1031, GF-067): gráfico sin datos se
    // EXPLICA (antes un hueco vacío sin decir nada).
    if (datos.isEmpty) {
      return const EstadoVacio(
        icono: Icons.bar_chart_rounded,
        titulo: 'Sin ingresos en el período',
        subtitulo: 'Cuando haya cobros, aquí verás su gráfico.',
      );
    }
    final maxMonto = datos
        .map((e) => (e['monto'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    final hoyIso = hoyHabanaIso();
    // V15: promedio diario del período, para la línea discreta
    // de tendencia sobre las barras.
    final prom = datos.isEmpty
        ? 0.0
        : datos
                .map((e) => (e['monto'] as num).toDouble())
                .reduce((a, b) => a + b) /
            datos.length;
    return Column(
      children: [
        Container(
      height: 150,
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        border: Border.all(color: AppColores.borde(context)),
        borderRadius: BorderRadius.circular(AppRadio.md),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
          children: datos.asMap().entries.map((e) {
            final d = e.value;
            final i = e.key;
            final monto = (d['monto'] as num).toDouble();
            final altura = maxMonto > 0
                ? (monto / maxMonto * 80).clamp(4.0, 80.0)
                : 4.0;
            final es30 = _periodoGrafico == '30';
            // En 30 días la etiqueta es el Nº de día (de la fecha),
            // solo cada 5 barras para no amontonar; en 7 días, el
            // día de semana como siempre.
            final fecha = '${d['fecha'] ?? ''}';
            final etiqueta = es30
                ? (i % 5 == 0 && fecha.length >= 10
                    ? fecha.substring(8, 10)
                    : '')
                : d['dia'] as String;
            final esHoy = fecha == hoyIso;
            final esMejor = maxMonto > 0 && monto == maxMonto;
            final colorBarra = esHoy
                ? AppColores.exito
                : esMejor
                    ? AppColores.alerta
                    : AppColores.naranja;
            // 1.30 (Oleada D6, UI130-22): la barra se
            // anuncia como botón con su detalle (día y
            // monto): era un GestureDetector sin etiqueta.
            return Semantics(
              button: true,
              label: 'Ingresos del ${fmtFecha(fecha)}: '
                  '${fmtMonto(monto)} CUP',
              child: GestureDetector(
              // v1.0.15: tocar barra muestra el detalle.
              // (M2-BC C2) ahora selecciona el día y abre la
              // burbuja con su desglose bajo el gráfico (la
              // hoja completa vive en la burbuja).
              // Corrección A1-D3: también los días en 0 son
              // tocables — su detalle (todo a cero) se puede
              // consultar igual; antes el toque estaba
              // deshabilitado y el día parecía muerto.
              onTap: () => _seleccionarDia(d['fecha'] as String),
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: es30 ? 3 : 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!es30 || monto > 0)
                      Text(
                        // Argón Estadísticas #8: mismo formato
                        // que el resto de montos de la app.
                        monto > 0
                            ? fmtMonto(monto)
                            : '',
                        style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700),
                      ),
                    const SizedBox(height: 2),
                    // (M2-BC C2) animación de entrada: la
                    // barra crece de 0 a su altura al aparecer
                    // (la clave por fecha+período la relanza
                    // al cambiar el selector 7/30).
                    TweenAnimationBuilder<double>(
                      // 1.36 H-C3 (136-1032, GF-068): la
                      // clave lleva el MONTO: si el dato del
                      // día cambia, la barra se re-anima a su
                      // nueva altura (antes la clave era solo
                      // fecha+período y el cambio era seco).
                      key: ValueKey(
                          'barra-$fecha-$_periodoGrafico-$monto'),
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: AppMovimiento.larga,
                      curve: AppMovimiento.curvaSuave,
                      builder: (ctx, f, _) => Container(
                        width: es30 ? 12 : 28,
                        height: altura * f,
                        decoration: BoxDecoration(
                          color: colorBarra,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppEspacio.xs),
                    Text(
                      etiqueta,
                      style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              ),
            );
              }).toList(),
            ),
            if (prom > 0 && maxMonto > 0)
              Positioned(
                left: 0,
                right: 0,
                // La base de las barras: etiqueta (≈15) + 4 de aire.
                bottom: 19 +
                    (prom / maxMonto * 80).clamp(4.0, 80.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                          height: 1,
                          color: AppColores.borde(context)),
                    ),
                    Container(
                      color: AppColores.superficie(context),
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppEspacio.xs),
                      child: Text('prom ${fmtMonto(prom)}',
                          style: AppTexto.minuscula.copyWith(
                              color: AppColores.textoSecundario(
                                  context))),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
        ),
        // (M2-BC C2) la burbuja del día tocado, bajo el
        // gráfico.
        if (_diaSel != null) ...[
          const SizedBox(height: AppEspacio.sm),
          _burbujaDia(),
        ],
      ],
    );
  }

  /// v1.0.15: detalle de un día al tocar su barra.
  /// Partición real (panel 2026-10-21): diarios y suplementos ya
  /// NO se suman también dentro de Efectivo; el Total se calcula
  /// de las propias filas de la hoja (el monto de la barra puede
  /// estar viejo si hubo un sync entre la carga y el toque).
  Future<void> _detalleDia(String fechaIso) async {
    // H2 (Argón): el cálculo vive en negocio.dart
    // (`resumenIngresosDia`); la UI solo muestra el resultado.
    final r = await resumenIngresosDia(fechaIso);
    final efectivo = r.efectivo;
    final transferencia = r.transferencia;
    final diario = r.diario;
    final suplementos = r.suplementos;
    final servicios = r.servicios;
    final n = r.movimientos;
    final total = r.total;
    if (!mounted) return;
    // 1.30 (D3, UI130-15): superficie única HojaAccion
    // (showHojaIron); el radio y el fondo los da el tema.
    showHojaIron(
      context,
      titulo: fmtFecha(fechaIso),
      icono: Icons.calendar_today_rounded,
      cuerpo: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filaDetalle('Efectivo', efectivo),
          _filaDetalle('Transferencia', transferencia),
          _filaDetalle('Pago diario', diario),
          if (suplementos > 0)
            _filaDetalle('Suplementos', suplementos),
          if (servicios > 0) _filaDetalle('Servicios', servicios),
          const Divider(),
          _filaDetalle('Total', total, negrita: true),
          const SizedBox(height: AppEspacio.sm),
          Text('$n movimientos registrados',
              style: AppTexto.secundario.copyWith(
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  /// Tarjeta de estadística de clientes tocable (v1.0.11).
  Widget _statCliente(String valor, String etiqueta, Color? color,
      VoidCallback onTap,
      {String? subtitulo}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadio.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        child: Column(
          children: [
            Text(valor,
                style: AppTexto.metrica.copyWith(color: color)),
            const SizedBox(height: 2),
            Text(etiqueta,
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
            // H3 (Argón): el subtítulo «N hoy» bajo «por vencer».
            if (subtitulo != null)
              Text(subtitulo,
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
  }

  /// Dashboard 1.19 (H1 Argón): una fila de urgencia del bloque
  /// «Hoy hay que…»: icono tintado + texto + detalle opcional +
  /// chevron solo si hay destino.
  Widget _filaUrgencia({
    required IconData icono,
    required Color color,
    required String texto,
    String? detalle,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadio.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icono, size: 18, color: color),
            ),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(texto,
                      style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.bold)),
                  if (detalle != null)
                    Text(detalle,
                        style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }

  /// SL-3 (G01-7): ¿hay algo urgente que pintar? Las MISMAS
  /// fuentes que alimentan las filas de [_bloqueHoyHayQue]:
  /// sin ninguna, ni la tarjeta ni su encabezado se pintan.
  bool get _hayUrgencias =>
      _pend.isNotEmpty ||
      _vencenHoy > 0 ||
      _cumpleHoy > 0 ||
      _porComprobar > 0 ||
      _diferenciasAbiertas > 0 ||
      _stockBajo.isNotEmpty ||
      _turnosOlvidados.isNotEmpty;

  /// Dashboard 1.19 (H1 + Q1 Argón): bloque «Hoy hay que…» del
  /// dueño. El pendiente a entregar va con su multimoneda CUP+USD
  /// y abre DetallePendienteScreen (NO Arqueo genérico); vencen
  /// hoy y cumpleaños hoy abren sus pantallas; el stock bajo, el
  /// catálogo. Los turnos de ayer sin cerrar son chips sin
  /// destino (ninguna pantalla muestra el ayer). Si no hay nada,
  /// la fila honesta «Nada urgente hoy».
  Widget _bloqueHoyHayQue() {
    final filas = <Widget>[];
    for (final t in _pend) {
      final cup = (t['total'] as double?) ?? 0;
      final usd = (t['total_usd'] as double?) ?? 0;
      final n = (t['n'] as int?) ?? 0;
      // (M2-BC B3) alerta de pendiente acumulado: si el
      // entrenador pasa el umbral de días o de monto, su
      // fila se vuelve de urgencia («lleva N días sin
      // entregar») y el toque va DIRECTO a su Arqueo, que
      // es donde se liquida.
      final dias = (t['dias_pendiente'] as int?) ?? 0;
      if (pendienteAcumuladoEnAlerta(dias: dias, cup: cup, usd: usd)) {
        filas.add(_filaUrgencia(
          icono: Icons.warning_amber_rounded,
          color: dias >= kDiasAlertaPendiente
              ? AppColores.error
              : AppColores.alerta,
          texto: dias > 0
              ? '${t['nombre']} lleva $dias días sin entregar'
              : 'Pendiente acumulado: ${t['nombre']}',
          detalle: '${fmtMonto(cup)} CUP'
              '${usd > 0 ? ' · ${fmtMonto(usd)} USD' : ''}'
              ' · $n movimientos · toca para liquidar',
          onTap: () => _ir(DetalleArqueoScreen(
              telegramId: t['id'] as int, nombre: '${t['nombre']}')),
        ));
        continue;
      }
      var det = '$n movimientos sin entregar · ${fmtMonto(cup)} CUP';
      if (usd > 0) det += ' · ${fmtMonto(usd)} USD';
      filas.add(_filaUrgencia(
        icono: Icons.schedule_rounded,
        color: AppColores.naranja,
        texto: 'Pendiente: ${t['nombre']}',
        detalle: det,
        onTap: () => _ir(DetallePendienteScreen(
            trainerId: t['id'] as int, nombre: '${t['nombre']}')),
      ));
    }
    if (_vencenHoy > 0) {
      filas.add(_filaUrgencia(
        icono: Icons.event_busy_rounded,
        color: AppColores.alerta,
        texto: 'Vencen hoy: $_vencenHoy',
        onTap: () => _ir(const ListasScreen(inicial: 0)),
      ));
    }
    if (_cumpleHoy > 0) {
      filas.add(_filaUrgencia(
        icono: Icons.cake_rounded,
        color: AppColores.exito,
        texto: 'Cumpleaños hoy: $_cumpleHoy',
        onTap: () => _ir(const CumpleanosScreen()),
      ));
    }
    // T4 (1.20): transferencias cobradas sin comprobar que el
    // dinero llegó a la cuenta del dueño.
    if (_porComprobar > 0) {
      filas.add(_filaUrgencia(
        icono: Icons.fact_check_rounded,
        color: AppColores.alerta,
        texto: 'Transferencias por comprobar: $_porComprobar',
        onTap: () => _ir(const ConciliacionScreen()),
      ));
    }
    // T5 (1.20): expedientes de diferencia de caja sin resolver
    // (FIN-23 de Argón).
    if (_diferenciasAbiertas > 0) {
      filas.add(_filaUrgencia(
        icono: Icons.balance_rounded,
        color: AppColores.alerta,
        texto: 'Diferencias de caja abiertas: $_diferenciasAbiertas',
        onTap: () => _ir(const DiferenciasCajaScreen()),
      ));
    }
    if (_stockBajo.isNotEmpty) {
      filas.add(_filaUrgencia(
        icono: Icons.inventory_2_rounded,
        color: AppColores.error,
        texto: 'Stock bajo: ${_stockBajo.length}',
        onTap: () => _ir(const SuplementosScreen()),
      ));
    }
    if (filas.isEmpty && _turnosOlvidados.isEmpty) {
      // SL-3 (G01-7, decisión de Jc): sin nada urgente la
      // tarjeta NO se pinta — la regla de que lo en cero no
      // ocupa manda sobre la vieja «fila honesta» («Nada
      // urgente hoy.» en una tarjeta entera).
      return const SizedBox.shrink();
    }
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < filas.length; i++) ...[
            if (i > 0) const Divider(height: 12),
            filas[i],
          ],
          if (_turnosOlvidados.isNotEmpty) ...[
            if (filas.isNotEmpty) const Divider(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in _turnosOlvidados)
                  Chip(
                    label: Text(
                      'Ayer sin cerrar: '
                      '${(('${a['entrenador_nombre'] ?? ''}').trim().isEmpty ? 'Sin nombre' : a['entrenador_nombre'])} '
                      '(${a['turno'] ?? ''})',
                      style: AppTexto.metadato,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Dashboard 1.19 (H5 Argón): «Hoy en sala» del entrenador:
  /// cumpleaños hoy + vencen hoy, SIN montos. Los nombres ya
  /// vienen filtrados por protegidos en `_cargarEntrenador`.
  /// Se muestran 3 nombres como mucho y el resto como «y N más».
  Widget _bloqueHoyEnSala() {
    String nombres(List<String> l) {
      if (l.isEmpty) return 'Nadie';
      if (l.length <= 3) return l.join(' · ');
      return '${l.take(3).join(' · ')} y ${l.length - 3} más';
    }

    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filaUrgencia(
            icono: Icons.cake_rounded,
            color: AppColores.exito,
            texto: 'Cumpleaños hoy',
            detalle: nombres(_cumpleHoyNombres),
          ),
          const Divider(height: 12),
          _filaUrgencia(
            icono: Icons.event_busy_rounded,
            color: AppColores.alerta,
            texto: 'Vencen hoy',
            detalle: nombres(_vencenHoyNombres),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dashboard por rol (v1.2): el entrenador ve solo sus propios números.
    if (!_esDueno) return _buildEntrenador();
    // Argón Estadísticas #5: acotados siempre. Hoy morosos()
    // sale de los propios _activos (no puede excederlos),
    // pero si una definición cambia, un alDia negativo se
    // vería como un dato, no como un error.
    final alDia = (_activos - _morosos).clamp(0, _activos);
    return Scaffold(
      appBar: appBarIron(
        context,
        'Dashboard',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: CruceEstados(
        // Corrección A1-D4 (auditoría 1 de la 1.28): el paso
        // esqueleto→contenido va con el fundido de la casa
        // (CruceEstados, 220 ms), como en las pantallas ya
        // migradas; el ternario directo cambiaba de golpe.
        estado: _cargando ? 'cargando' : 'contenido',
        child: _cargando
            // (M2-BC C5) esqueleto estructural en vez del
            // spinner genérico.
            ? const SkeletonDashboard()
            : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  const SyncBanner(),
                  const SizedBox(height: AppEspacio.sm),
                  // (M2-BC C1) la foto del mes abre el panel.
                  _tarjetaHeroe(),
                  const SizedBox(height: AppEspacio.lg),
                  // H1 (Argón): el bloque de urgencias abre el panel.
                  // SL-3 (G01-7): sin urgencias, ni encabezado
                  // ni tarjeta (lo en cero no ocupa).
                  if (_hayUrgencias) ...[
                    const EncabezadoSeccion(titulo: 'Hoy hay que…'),
                    _bloqueHoyHayQue(),
                  ],
                  const EncabezadoSeccion(titulo: 'Ingresos'),
                  // 1.35 (UX-12): las tres cifras de ingreso
                  // pasan a UNA banda segmentada, con «hoy»
                  // encendida; cada segmento conserva su
                  // destino (el detalle del período).
                  _bandaIngresos(),
                  // Gráfico con selector de período (v1.0.15: 7 o 30 días)
                  Row(
                    children: [
                      const Expanded(
                          child: EncabezadoSeccion(
                              titulo: 'Ingresos por día')),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                              value: '7', label: Text('7 días')),
                          ButtonSegment(
                              value: '30', label: Text('30 días')),
                        ],
                        selected: {_periodoGrafico},
                        onSelectionChanged: (s) => setState(() {
                          _periodoGrafico = s.first;
                          // (M2-BC C2) la burbuja es del
                          // período anterior: se cierra.
                          _diaSel = null;
                          _detalleSel = null;
                        }),
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  _graficoDias(),
                  const EncabezadoSeccion(titulo: 'Clientes'),
                  Tarjeta(
                      child: Column(
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceAround,
                            children: [
                              _statCliente(
                                  '$_activos', 'activos', null,
                                  () => _ir(const BuscarScreen())),
                              _statCliente(
                                  '$alDia',
                                  'al día',
                                  AppColores.exito,
                                  () => _ir(const BuscarScreen())),
                              _statCliente(
                                  '$_porVencer',
                                  'por vencer',
                                  AppColores.naranja,
                                  () => _ir(const ListasScreen(
                                      inicial: 1)),
                                  // H3: total 3d con subtítulo «N hoy».
                                  subtitulo: '$_vencenHoy hoy'),
                              _statCliente(
                                  '$_morosos',
                                  'vencidos',
                                  AppColores.error,
                                  () => _ir(ListasScreen(
                                      inicial: _tabVencidos))),
                            ],
                          ),
                          const SizedBox(height: AppEspacio.md),
                          // (1.30 D4 · UI130-11) barra apilada de
                          // tres segmentos disjuntos con leyenda:
                          // la vieja pintaba todo lo no-«al día»
                          // sobre error y llamaba morosos también
                          // a los por vencer.
                          BarraClientesSegmentos(
                            activos: _activos,
                            porVencer: _porVencer,
                            morosos: _morosos,
                            onAlDia: () =>
                                _ir(const BuscarScreen()),
                            onPorVencer: () => _ir(
                                const ListasScreen(inicial: 1)),
                            onVencidos: () => _ir(
                                ListasScreen(inicial: _tabVencidos)),
                          ),
                          // v1.0.15: nuevos este mes + inactivos
                          if (_nuevos > 0 || _inactivos > 0) ...[
                            const SizedBox(height: AppEspacio.sm),
                            Container(
                              padding: const EdgeInsets.all(AppEspacio.sm),
                              decoration: BoxDecoration(
                                color: AppColores.info
                                    .withValues(alpha: 0.12),
                                borderRadius:
                                    BorderRadius.circular(AppRadio.sm),
                                border: Border.all(
                                    color: AppColores.info
                                        .withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (_nuevos > 0)
                                    Text('$_nuevos nuevos',
                                        style: AppTexto.secundario.copyWith(color: AppColores.info, fontWeight: FontWeight.bold)),
                                  if (_inactivos > 0)
                                    Text('$_inactivos inactivos',
                                        style: AppTexto.secundario.copyWith(color: AppColores
                                                .textoSecundario(
                                                    context))),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                  ),
                  const SizedBox(height: AppEspacio.lg),
                  // Q2 (Argón): balance y desglose unificados.
                  const EncabezadoSeccion(
                      titulo: 'Balance y desglose del mes'),
                  _desgloses(),
                  const SizedBox(height: AppEspacio.lg),
                  // Fila Plus/Casa (propuesta punto 9, solo conteos).
                  // Sin Plus (sin red o sobre el tope) solo Casa.
                  if (_casaActivas > 0 || _plusVigentes != null) ...[
                    Tarjeta(
                      child: Text(
                        [
                          if (_plusVigentes != null)
                            'Plus vigentes: $_plusVigentes',
                          if (_casaActivas > 0)
                            'Cuentas Casa: $_casaActivas',
                        ].join(' · '),
                        style: AppTexto.secundario,
                      ),
                    ),
                    const SizedBox(height: AppEspacio.lg),
                  ],
                  // Q3 (Argón): el ranking degrada a UNA fila
                  // compacta al final, sin trofeos.
                  // 1.35 (UX-12): los dos entrenadores se
                  // COMPARAN en la portada — nombre, cifra y
                  // su barra proporcional — con los mismos
                  // datos de siempre (los dos primeros del
                  // ranking del mes).
                  if (_ranking.length > 1) ...[
                    const EncabezadoSeccion(
                        titulo: 'Ranking del mes'),
                    Tarjeta(
                      padding: const EdgeInsets.all(AppEspacio.md),
                      child: Builder(builder: (context) {
                        final dos = _ranking.take(2).toList();
                        final maximo = dos
                            .map((e) =>
                                (e['total'] as num?)?.toDouble() ??
                                0)
                            .fold<double>(0, (m, v) => v > m ? v : m);
                        return Column(
                          children: [
                            for (var i = 0; i < dos.length; i++) ...[
                              if (i > 0)
                                const SizedBox(
                                    height: AppEspacio.md),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                        '${i + 1}° ${dos[i]['nombre'] ?? ''}',
                                        style: AppTexto.cuerpo,
                                        maxLines: 1,
                                        overflow:
                                            TextOverflow.ellipsis),
                                  ),
                                  Text(
                                      '${fmtMonto((dos[i]['total'] as num?)?.toDouble() ?? 0)} CUP',
                                      style: AppTexto.cuerpo.copyWith(
                                          fontWeight:
                                              FontWeight.w700)),
                                ],
                              ),
                              const SizedBox(height: AppEspacio.xs),
                              Container(
                                height: 8,
                                decoration: BoxDecoration(
                                  color: AppColores.borde(context),
                                  borderRadius:
                                      BorderRadius.circular(4),
                                ),
                                child: FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: maximo <= 0
                                      ? 0
                                      : (((dos[i]['total'] as num?)
                                                  ?.toDouble() ??
                                              0) /
                                          maximo),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: i == 0
                                          ? AppColores.naranja
                                          : AppColores.naranja
                                              .withValues(alpha: 0.45),
                                      borderRadius:
                                          BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      }),
                    ),
                    const SizedBox(height: AppEspacio.lg),
                  ],
                ],
              ),
            ),
      ),
    );
  }
}

/// (1.30 D4 · UI130-11) Partición DISJUNTA de los activos
/// para la barra de Clientes del Dashboard. El «al día» del
/// conteo de la tarjeta es activos − vencidos (incluye a
/// los por vencer, y esa cifra NO cambia); el segmento
/// verde de la barra es el resto tras quitar por vencer
/// y vencidos, como en el mockup aprobado (128 = 96 +
/// 19 por vencer + 13 vencidos). Corrección E3 (C6-02):
/// ese segmento se rotula «Sin vencer», NO «al día» — la
/// misma pantalla decía «al día» con dos cifras distintas
/// (115 en la tarjeta, 96 en la leyenda). Con las
/// acotaciones, los tres segmentos suman SIEMPRE el
/// total de activos y ninguno sale negativo aunque un
/// conteo venga desfasado.
({int alDia, int porVencer, int vencidos}) segmentosBarraClientes({
  required int activos,
  required int porVencer,
  required int morosos,
}) {
  final a = activos < 0 ? 0 : activos;
  final v = morosos.clamp(0, a);
  final p = porVencer.clamp(0, a - v);
  return (alDia: a - p - v, porVencer: p, vencidos: v);
}

/// (1.30 D4 · UI130-11) Barra apilada de tres segmentos
/// de la tarjeta de Clientes: sin vencer (verde), por vencer
/// (naranja) y vencidos (rojo), con su leyenda de conteos
/// debajo. Cada segmento es tocable a su lista, como ya
/// lo son los conteos de la tarjeta. Con 0 activos,
/// barra neutra sin segmentos.
class BarraClientesSegmentos extends StatelessWidget {
  final int activos;
  final int porVencer;
  final int morosos;
  final VoidCallback? onAlDia;
  final VoidCallback? onPorVencer;
  final VoidCallback? onVencidos;

  const BarraClientesSegmentos({
    super.key,
    required this.activos,
    required this.porVencer,
    required this.morosos,
    this.onAlDia,
    this.onPorVencer,
    this.onVencidos,
  });

  Widget _segmento(String clave, int conteo, Color color,
      String etiqueta, VoidCallback? alTocar) {
    return Expanded(
      flex: conteo,
      // 1.30 (Oleada D6, UI130-22): el segmento se
      // anuncia con su leyenda y su conteo (era un
      // GestureDetector sin etiqueta sobre 10 dp).
      child: Semantics(
        button: alTocar != null,
        label: '$etiqueta: $conteo',
        child: GestureDetector(
          key: ValueKey(clave),
          onTap: alTocar,
          child: Container(height: 10, color: color),
        ),
      ),
    );
  }

  Widget _leyenda(
      BuildContext context, Color color, String texto) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
              color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppEspacio.xs),
        Text(texto,
            style: AppTexto.metadato.copyWith(
                color: AppColores.textoSecundario(context))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final seg = segmentosBarraClientes(
        activos: activos,
        porVencer: porVencer,
        morosos: morosos);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadio.sm),
          child: activos <= 0
              ? Container(
                  key: const ValueKey('seg-neutra'),
                  height: 10,
                  color: AppColores.borde(context)
                      .withValues(alpha: 0.35),
                )
              : Row(
                  children: [
                    if (seg.alDia > 0)
                      _segmento('seg-al-dia', seg.alDia,
                          AppColores.exito, 'Sin vencer', onAlDia),
                    if (seg.porVencer > 0)
                      _segmento('seg-por-vencer', seg.porVencer,
                          AppColores.naranja, 'Por vencer',
                          onPorVencer),
                    if (seg.vencidos > 0)
                      _segmento('seg-vencidos', seg.vencidos,
                          AppColores.error, 'Vencidos',
                          onVencidos),
                  ],
                ),
        ),
        const SizedBox(height: AppEspacio.xs),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          children: [
            _leyenda(context, AppColores.exito,
                '${seg.alDia} sin vencer'),
            _leyenda(context, AppColores.naranja,
                '${seg.porVencer} por vencer'),
            _leyenda(context, AppColores.error,
                '${seg.vencidos} vencidos'),
          ],
        ),
      ],
    );
  }
}
