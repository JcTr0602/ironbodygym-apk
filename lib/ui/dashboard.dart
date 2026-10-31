/// 📊 Dashboard: resumen del negocio de un vistazo.
///
/// Ingresos de hoy / últimos 7 días / mes, activos vs vencidos y
/// pendiente a entregar por entrenador.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import '../auth.dart';
import '../cliente_protegido.dart';
import '../invitados.dart';
import '../nomina_total.dart';
import '../permisos_entrenador.dart';
import '../permisos_visibilidad.dart';
import '../tiempo.dart';
import 'diseno.dart';
import 'componentes.dart';
import 'buscar.dart';
import 'cumpleanos.dart';
import 'listas.dart';
import 'suplementos.dart';
import 'widgets.dart';
import 'detalle_pendiente.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _cargando = true;
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

  // Vista por rol (v1.2): el entrenador ve solo sus propios números.
  final _auth = AuthService();
  bool get _esDueno => _auth.isOwner;
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
      final fIngresos = Future.wait([
        ingresosHoy(),
        ingresosSemana(),
        ingresosMes(),
        ingresosMesAnterior(),
        proyeccionMes(),
        ingresosPorMetodo(),
        ingresosPorTipo(),
        mejorPeorDia(),
        ingresosUltimos7Dias(),
        ingresosUltimos30Dias(),
      ]);
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
      ]);
      // Panel Terra B2: cada grupo se espera por separado. Un fallo
      // en un grupo ya no tumba los otros dos: el grupo que falló
      // conserva los valores anteriores y los demás se aplican.
      List<dynamic>? ing;
      List<dynamic>? cli;
      List<dynamic>? nov;
      try {
        ing = await fIngresos;
      } catch (_) {}
      try {
        cli = await fClientes;
      } catch (_) {}
      try {
        nov = await fNovedades;
      } catch (_) {}
      if (mounted && v == _versionCarga) {
        setState(() {
          if (ing != null) {
            _hoy = ing[0] as double;
            _semana = ing[1] as double;
            _mes = ing[2] as double;
            _mesAnterior = ing[3] as double;
            _proyeccion = ing[4] as double;
            _porMetodo = ing[5] as Map<String, double>;
            _porTipo = ing[6] as Map<String, double>;
            _mejorPeor = ing[7] as Map<String, Map<String, dynamic>>;
            _ultimos7 = ing[8] as List<Map<String, dynamic>>;
            _ultimos30 = ing[9] as List<Map<String, dynamic>>;
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
          }
          if (nov != null) {
            final nomina = nov[0] as double?;
            if (nomina != null) _nominaProy = nomina;
            _cumpleHoy = nov[1] as int;
            _casaActivas = nov[2] as int;
            _stockBajo = nov[3] as List<Map<String, dynamic>>;
            _turnosOlvidados = nov[4] as List<Map<String, dynamic>>;
            _plusVigentes = nov[5] as int?;
          }
          _cargando = false;
        });
      }
    } catch (_) {
      // Un fallo de lectura no debe dejar el spinner eterno ni
      // borrar lo ya mostrado: se conserva el estado anterior.
      if (mounted && v == _versionCarga) {
        setState(() => _cargando = false);
      }
    }
  }

  /// Carga los números propios del entrenador (dashboard por rol, v1.2).
  Future<void> _cargarEntrenador(int v) async {
    try {
      final tid = _auth.telegramId;
      final hoy = await ingresosHoyPorEntrenador(tid);
      final semana = await ingresosSemanaPorEntrenador(tid);
      final mes = await cobradoMes(tid);
      final pendCup = await pendienteEntrega(tid);
      final pendUsd = await pendienteEntregaUsd(tid);
      final porMet = await ingresosPorMetodoEntrenador(tid);
      final porTip = await ingresosPorTipoEntrenador(tid);
      final mp = await mejorPeorDiaEntrenador(tid);
      // H5 (Argón): «Hoy en sala» sin montos. Los nombres ya
      // vienen filtrados: un cliente protegido NO se le muestra
      // al entrenador (misma regla que la bandeja de avisos).
      final sala = await Future.wait([
        cumpleanosProximos(dias: 0),
        vencenHoy(),
      ]);
      final nombresCump = <String>[];
      for (final c in sala[0]) {
        if ((c['_dias_para'] as int?) != 0) continue;
        if (esVistaProtegida(c, esDueno: false)) continue;
        final n = '${c['nombre'] ?? ''}'.trim();
        if (n.isNotEmpty) nombresCump.add(n);
      }
      final nombresVencen = <String>[];
      for (final c in sala[1]) {
        if (esVistaProtegida(c, esDueno: false)) continue;
        final n = '${c['nombre'] ?? ''}'.trim();
        if (n.isNotEmpty) nombresVencen.add(n);
      }
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

  /// Detalle de ingresos por período (v1.0.11).
  /// Muestra desglose por método de pago.
  Future<void> _detalleIngresos(String periodo) async {
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
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo, style: AppTexto.titulo),
            const SizedBox(height: 12),
            _filaDetalle('Efectivo', efectivo),
            _filaDetalle('Transferencia', transferencia),
            if (diario > 0) _filaDetalle('Pago diario', diario),
            if (suplementos > 0)
              _filaDetalle('Suplementos', suplementos),
            if (servicios > 0) _filaDetalle('Servicios', servicios),
            const Divider(),
            _filaDetalle('Total', total, negrita: true),
            const SizedBox(height: 8),
            Text('${pagos.length} movimientos registrados',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(ctx))),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _filaDetalle(String etiqueta, double valor,
      {bool negrita = false}) {    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: const TextStyle(fontSize: 15)),
          Text('${fmtMonto(valor)} CUP',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight:
                      negrita ? FontWeight.bold : FontWeight.normal,
                  color: negrita ? naranja : null)),
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
        appBar: AppBar(
          title: const Text('Mi dashboard'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _cargar,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SyncBanner(),
            const SizedBox(height: 8),
            // H5 (Argón): «Hoy en sala» va POR ENCIMA del candado
            // de cifras: no son cifras, y hoy el return temprano
            // lo ocultaba todo.
            if (_salaCargada) ...[
              const EncabezadoSeccion(titulo: 'Hoy en sala'),
              const SizedBox(height: 8),
              _bloqueHoyEnSala(),
              const SizedBox(height: 8),
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
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando panel…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SyncBanner(),
                  const SizedBox(height: 8),
                  // H5 (Argón): «Hoy en sala» también abre la vista
                  // sin candado, antes de las cifras.
                  if (_salaCargada) ...[
                    const EncabezadoSeccion(titulo: 'Hoy en sala'),
                    const SizedBox(height: 8),
                    _bloqueHoyEnSala(),
                    const SizedBox(height: 16),
                  ],
                  const EncabezadoSeccion(titulo: 'Mis cobros'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _tarjetaSimple('Hoy', _miHoy, Icons.today),
                      const SizedBox(width: 8),
                      _tarjetaSimple(
                          '7 días', _miSemana, Icons.date_range),
                      const SizedBox(width: 8),
                      _tarjetaSimple('Este mes', _miMes,
                          Icons.calendar_month),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const EncabezadoSeccion(
                      titulo: 'Mi pendiente a entregar'),
                  const SizedBox(height: 8),
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
                              style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const EncabezadoSeccion(
                      titulo: 'Desglose del mes'),
                  const SizedBox(height: 8),
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
                          const SizedBox(height: 8),
                          Text(
                            'Mi mejor día: ${fmtFecha(_miMejorPeor['mejor']!['dia'] as String?)} '
                            '(${fmtMonto(_miMejorPeor['mejor']!['monto'] as double)} CUP)',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    AppColores.textoSecundario(
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
            const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Icon(icono, color: naranja, size: 26),
            const SizedBox(height: 6),
            Text(titulo,
                style: TextStyle(
                    fontSize: 11,
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 2),
            Text(fmtMonto(valor),
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: naranja)),
            Text('CUP',
                style: TextStyle(
                    fontSize: 10,
                    color: AppColores.textoSecundario(context))),
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
        Text(etiqueta, style: const TextStyle(fontSize: 13)),
        Text('${fmtMonto(valor)} $moneda',
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: naranja)),
      ],
    );
  }

  Widget _tarjetaIngreso(
      String titulo, double valor, IconData icono, VoidCallback onTap) {
    return Expanded(
      child: Tarjeta(
        onTap: onTap,
        padding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Icon(icono, color: naranja, size: 26),
            const SizedBox(height: 6),
            Text(titulo,
                style: TextStyle(
                    fontSize: 11,
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 2),
            Text(fmtMonto(valor),
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: naranja)),
            Text('CUP',
                style: TextStyle(
                    fontSize: 10,
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 4),
            Icon(Icons.touch_app,
                size: 14,
                color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }

  /// Navega a una pantalla y recarga al volver (v1.0.11).
  Future<void> _ir(Widget w) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w));
    if (mounted) _cargar();
  }

  /// v1.0.15: comparativa vs mes anterior.
  Widget _comparativaMes() {
    if (_mesAnterior <= 0) return const SizedBox.shrink();
    final diff = _mes - _mesAnterior;
    final pct = _mesAnterior > 0 ? diff / _mesAnterior * 100 : 0.0;
    final sube = diff >= 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sube
            ? AppColores.exito.withValues(alpha: 0.12)
            : AppColores.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: sube
                ? AppColores.exito.withValues(alpha: 0.35)
                : AppColores.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(sube ? Icons.trending_up : Icons.trending_down,
              size: 20,
              color: sube ? AppColores.exito : AppColores.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              sube
                  ? 'Sube ${pct.toStringAsFixed(0)}% vs mes anterior '
                      '(${fmtMonto(_mesAnterior)} CUP)'
                  : 'Baja ${pct.abs().toStringAsFixed(0)}% vs mes anterior '
                      '(${fmtMonto(_mesAnterior)} CUP)',
              style: TextStyle(
                  fontSize: 13,
                  color: sube
                      ? AppColores.exito
                      : AppColores.error),
            ),
          ),
        ],
      ),
    );
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
    final ef = _porMetodo['efectivo'] ?? 0;
    final tr = _porMetodo['transferencia'] ?? 0;
    final supM = _porMetodo['suplementos'] ?? 0;
    final servM = _porMetodo['servicios'] ?? 0;
    final men = _porTipo['mensual'] ?? 0;
    final dia = _porTipo['diario'] ?? 0;
    final supT = _porTipo['suplementos'] ?? 0;
    final servT = _porTipo['servicios'] ?? 0;
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
            const Text('Balance',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            _filaDetalle('Ingresos brutos', _mes),
            _filaDetalle('Gastos', _gastosMes),
            if (_nominaProy != null) ...[
              _filaDetalle('Nómina proyectada', _nominaProy!),
              Text(
                'Proyección, no cierre: se descuenta al cerrar el mes.',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context)),
              ),
            ],
            _filaDetalle('Utilidad neta real', _mes - _gastosMes,
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
                      style: TextStyle(fontSize: 13)),
                  Text('${fmtMonto(_proyeccion.round())} CUP',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: naranja)),
                ],
              ),
            ],
            if (_mejorPeor.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Mejor día: ${fmtFecha(_mejorPeor['mejor']!['dia'] as String?)} '
                '(${fmtMonto(_mejorPeor['mejor']!['monto'] as double)} CUP)',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context)),
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
                  style: const TextStyle(fontSize: 13))),
          Text('${fmtMonto(valor)} CUP',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text('${pct.toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(context))),
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
    if (datos.isEmpty) return const SizedBox.shrink();
    final maxMonto = datos
        .map((e) => (e['monto'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    final hoyIso = hoyHabanaIso();
    return Container(
      height: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        border: Border.all(color: AppColores.borde(context)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
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
            return GestureDetector(
              // v1.0.15: tocar barra muestra el detalle
              onTap: monto > 0
                  ? () => _detalleDia(d['fecha'] as String)
                  : null,
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: es30 ? 3 : 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!es30 || monto > 0)
                      Text(
                        monto > 0
                            ? monto.toStringAsFixed(0)
                            : '',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: (esHoy || esMejor)
                                ? FontWeight.w700
                                : null),
                      ),
                    const SizedBox(height: 2),
                    Container(
                      width: es30 ? 12 : 28,
                      height: altura,
                      decoration: BoxDecoration(
                        color: colorBarra,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      etiqueta,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              esHoy ? FontWeight.w700 : null),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
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
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fmtFecha(fechaIso), style: AppTexto.titulo),
            const SizedBox(height: 12),
            _filaDetalle('Efectivo', efectivo),
            _filaDetalle('Transferencia', transferencia),
            _filaDetalle('Pago diario', diario),
            if (suplementos > 0)
              _filaDetalle('Suplementos', suplementos),
            if (servicios > 0) _filaDetalle('Servicios', servicios),
            const Divider(),
            _filaDetalle('Total', total, negrita: true),
            const SizedBox(height: 8),
            Text('$n movimientos registrados',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(ctx))),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Tarjeta de estadística de clientes tocable (v1.0.11).
  Widget _statCliente(String valor, String etiqueta, Color? color,
      VoidCallback onTap,
      {String? subtitulo}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Text(valor,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color)),
            const SizedBox(height: 2),
            Text(etiqueta,
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context))),
            // H3 (Argón): el subtítulo «N hoy» bajo «por vencer».
            if (subtitulo != null)
              Text(subtitulo,
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColores.textoSecundario(context))),
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
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icono, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(texto,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  if (detalle != null)
                    Text(detalle,
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                AppColores.textoSecundario(context))),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right,
                  size: 20,
                  color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }

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
      var det = '$n movimientos sin entregar · ${fmtMonto(cup)} CUP';
      if (usd > 0) det += ' · ${fmtMonto(usd)} USD';
      filas.add(_filaUrgencia(
        icono: Icons.schedule,
        color: AppColores.naranja,
        texto: 'Pendiente: ${t['nombre']}',
        detalle: det,
        onTap: () => _ir(DetallePendienteScreen(
            trainerId: t['id'] as int, nombre: '${t['nombre']}')),
      ));
    }
    if (_vencenHoy > 0) {
      filas.add(_filaUrgencia(
        icono: Icons.event_busy,
        color: AppColores.alerta,
        texto: 'Vencen hoy: $_vencenHoy',
        onTap: () => _ir(const ListasScreen(inicial: 0)),
      ));
    }
    if (_cumpleHoy > 0) {
      filas.add(_filaUrgencia(
        icono: Icons.cake,
        color: AppColores.exito,
        texto: 'Cumpleaños hoy: $_cumpleHoy',
        onTap: () => _ir(const CumpleanosScreen()),
      ));
    }
    if (_stockBajo.isNotEmpty) {
      filas.add(_filaUrgencia(
        icono: Icons.inventory_2,
        color: AppColores.error,
        texto: 'Stock bajo: ${_stockBajo.length}',
        onTap: () => _ir(const SuplementosScreen()),
      ));
    }
    if (filas.isEmpty && _turnosOlvidados.isEmpty) {
      return Tarjeta(
        child: Text('Nada urgente hoy.',
            style: TextStyle(
                color: AppColores.textoSecundario(context))),
      );
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
                      style: const TextStyle(fontSize: 12),
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
            icono: Icons.cake,
            color: AppColores.exito,
            texto: 'Cumpleaños hoy',
            detalle: nombres(_cumpleHoyNombres),
          ),
          const Divider(height: 12),
          _filaUrgencia(
            icono: Icons.event_busy,
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
    final alDia = _activos - _morosos;
    final pctAlDia =
        _activos > 0 ? alDia / _activos : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando panel…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SyncBanner(),
                  const SizedBox(height: 8),
                  // H1 (Argón): el bloque de urgencias abre el panel.
                  const EncabezadoSeccion(titulo: 'Hoy hay que…'),
                  const SizedBox(height: 8),
                  _bloqueHoyHayQue(),
                  const SizedBox(height: 16),
                  const EncabezadoSeccion(titulo: 'Ingresos'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _tarjetaIngreso('Hoy', _hoy, Icons.today,
                          () => _detalleIngresos('hoy')),
                      const SizedBox(width: 8),
                      _tarjetaIngreso('7 días', _semana,
                          Icons.date_range, () => _detalleIngresos('semana')),
                      const SizedBox(width: 8),
                      _tarjetaIngreso('Este mes', _mes,
                          Icons.calendar_month, () => _detalleIngresos('mes')),
                    ],
                  ),
                  // v1.0.15: comparativa vs mes anterior
                  if (_mesAnterior > 0) ...[
                    const SizedBox(height: 8),
                    _comparativaMes(),
                  ],
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
                        onSelectionChanged: (s) => setState(
                            () => _periodoGrafico = s.first),
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _graficoDias(),
                  const SizedBox(height: 16),
                  const EncabezadoSeccion(titulo: 'Clientes'),
                  const SizedBox(height: 8),
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
                                  () => _ir(const ListasScreen(
                                      inicial: 2))),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: pctAlDia,
                              minHeight: 10,
                              backgroundColor: AppColores.error
                                  .withValues(alpha: 0.2),
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(
                                      AppColores.exito),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              '${(pctAlDia * 100).toStringAsFixed(0)}% al día',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppColores.textoSecundario(
                                      context))),
                          // v1.0.15: nuevos este mes + inactivos
                          if (_nuevos > 0 || _inactivos > 0) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColores.info
                                    .withValues(alpha: 0.12),
                                borderRadius:
                                    BorderRadius.circular(8),
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
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppColores.info,
                                            fontWeight:
                                                FontWeight.bold)),
                                  if (_inactivos > 0)
                                    Text('$_inactivos inactivos',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: AppColores
                                                .textoSecundario(
                                                    context))),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                  ),
                  const SizedBox(height: 16),
                  // Q2 (Argón): balance y desglose unificados.
                  const EncabezadoSeccion(
                      titulo: 'Balance y desglose del mes'),
                  const SizedBox(height: 8),
                  _desgloses(),
                  const SizedBox(height: 16),
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
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Q3 (Argón): el ranking degrada a UNA fila
                  // compacta al final, sin trofeos.
                  if (_ranking.length > 1) ...[
                    const EncabezadoSeccion(
                        titulo: 'Ranking del mes'),
                    const SizedBox(height: 8),
                    Tarjeta(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Mes: ${_ranking.take(2).toList().asMap().entries.map((e) => '${e.key + 1}° ${e.value['nombre']} (${fmtMonto(e.value['total'])} CUP)').join(' · ')}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
    );
  }
}
