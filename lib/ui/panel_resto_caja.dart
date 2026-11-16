/// Pantallas C del Panel (1.11.0): C1, C2, C3.
///
/// - C1: la pantalla de arqueo de entrega por delta se retiró
///   en la Oleada 2 (Fase 1): la puerta única es la hoja
///   «Liquidar Arqueo» del Pilar 4 con modo «Entrega
///   anticipada C1». De C1 queda aquí solo la función de
///   datos completarPendientesArqueoC1 (con su test).
/// - C2: nómina pre-calculada, SOLO LECTURA, con la definición única
///   de NominaCalc (150 por cliente que pagó el mes, dueño ×300, sin
///   comisiones salvo dosis). Aviso de vista previa + fecha/hora.
/// - C3: lista de adelantos (vista; la lógica es la de 1.8.0 y el
///   registro nuevo vive en la pantalla de Nómina, no se duplica).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque2_resto.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../nomina_foto.dart';
import '../plus_reportes.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'mi_nomina.dart' show BarraComposicionNomina;
import 'diseno.dart';
import 'nomina.dart';
import '../errores_sync.dart';
import '../app_log.dart';

// ---------------------------------------------------------------------------
// C1
// ---------------------------------------------------------------------------

/// Completa cada tarjeta de la lista C1 con su pendiente CUP
/// del delta (pendienteDeltaC1) y su pendiente USD CANÓNICO
/// (pendienteEntregaUsd: espejo + cola + arrastre).
///
/// Autoauditoría 1.22 #1 (2026-11-03): la pieza 2 (T-03)
/// añadía a la lista a los entrenadores con pendiente solo en
/// cola con la entrada en ceros, y el `usd` de la tarjeta nunca
/// se recalculaba (el de la lista base sale de pendienteArqueo,
/// que NO mira la cola). Si lo único pendiente era una venta
/// USD aún en cola, la tarjeta decía «Pendiente: 0 CUP» y el
/// botón Liquidar caía en «Ya no hay pendiente que liquidar»:
/// el callejón sin salida que T-03 quería cerrar. El subtítulo
/// y el aviso de solo-USD leen `e['usd']`: tiene que ser el
/// canónico, para todas las entradas.
Future<void> completarPendientesArqueoC1(
    List<Map<String, dynamic>> lista) async {
  for (final e in lista) {
    final tid = LocalDb.normalizarTelegramId(e['telegram_id']);
    e['pendiente_c1'] =
        tid != null ? await pendienteDeltaC1(tid) : e['cup'] as double;
    if (tid != null) {
      e['usd'] = await pendienteEntregaUsd(tid);
    }
  }
}

/// Oleada 2 (Fase 1, desviación 1): la PANTALLA C1
/// (ArqueoEntregaScreen y su diálogo de liquidar) se retiró:
/// la puerta única de liquidación vive en la hoja «Liquidar
/// Arqueo» del Pilar 4, con selector de modo cierre / entrega
/// anticipada C1 ejecutando la misma registrarEntregaEfectivo.
/// Queda arriba completarPendientesArqueoC1, función de datos
/// con su test vivo (turnos_122 T-03).

// ---------------------------------------------------------------------------
// C2
// ---------------------------------------------------------------------------

class NominaPrecalculadaScreen extends StatefulWidget {
  const NominaPrecalculadaScreen({super.key});
  @override
  State<NominaPrecalculadaScreen> createState() =>
      _NominaPrecalculadaScreenState();
}

class _NominaPrecalculadaScreenState extends State<NominaPrecalculadaScreen> {
  bool _cargando = true;
  String _mes = '';
  String _calculadoEn = '';
  List<Map<String, dynamic>> _porEntrenador = [];
  // P2#10: base GLOBAL (no por quién cobró): la misma para cada
  // entrenador, igual que en la pantalla de Nómina.
  int _pagaronGlobal = 0;
  double _tarifa = 0;
  double _baseGlobal = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Lote 3 (BLOQUEANTE): solo el dueño puede abrir esta pantalla.
    if (!AuthService().isOwner) return;
    final mes = mesHabanaActual();
    try {
      // 1.23 AT-08 (auditoría total de Argón): TODOS los
      // componentes salen de la FOTO compartida del mes
      // (fotoNominaMes, la misma que consume la pantalla de
      // Nómina): tarifa, comisiones por dosis acumuladas por
      // clave con TODOS sus telegram_id, y el libro de
      // adelantos con las fotos de los meses liquidados ya
      // aplicadas (aplicarFotosLibro). Esta pantalla armaba el
      // libro por su cuenta — sin fotos de liquidación y con
      // una sola id por entrenador — y divergía de Nómina en
      // cuanto cambiaba la tarifa tras liquidar un mes.
      final foto = await fotoNominaMes(mes);
      // P2#10: base GLOBAL, no agrupada por quién cobró. Es la
      // misma definición que la pantalla de Nómina: clientes
      // únicos que pagaron el mes (NominaCalc, ya excluye Casa y
      // el vencido-dentro-del-mes) × tarifa configurable. La
      // foto no incluye el conteo por diseño: se lee de la
      // definición única, como hace la pantalla.
      final pagaron =
          await NominaCalc.clientesQuePagaronElMes(mes);
      final tarifa = foto.tarifa.toDouble();
      final baseGlobal = pagaron * tarifa;
      // Bonos por el MISMO camino que la pantalla (con la
      // migración legada de prefs aplicada).
      final bonos = await leerBonosMesConMigracion(mes);
      // Entrenadores desde usuarios_apk (rol != admin); si el meta
      // falta, respaldo con los cobradores del mes sin el dueño.
      final personas = <Map<String, dynamic>>[];
      try {
        final raw = await LocalDb.instance.getMeta('usuarios_apk');
        if (raw != null && raw.isNotEmpty) {
          for (final u in jsonDecode(raw) as List) {
            final m = Map<String, dynamic>.from(u as Map);
            if ('${m['rol'] ?? 'entrenador'}' == 'admin') continue;
            final username = '${m['username'] ?? ''}'.toLowerCase();
            if (username.isEmpty) continue;
            personas.add({
              'username': username,
              'id': '${m['id'] ?? ''}',
              'tid': LocalDb.normalizarTelegramId(m['telegram_id']),
              'nombre': '${m['nombre'] ?? m['username'] ?? ''}',
            });
          }
        }
      } catch (_) {}
      if (personas.isEmpty) {
        final yo = AuthService().telegramId;
        final nombres = <int, String>{};
        for (final p in await LocalDb.instance.pagosDelMes(mes)) {
          final tid =
              LocalDb.normalizarTelegramId(p['telegram_user_id']);
          if (tid == null || tid == yo) continue;
          nombres[tid] ??= '${p['registrado_por'] ?? ''}';
        }
        for (final e in nombres.entries) {
          personas.add({
            'username': '',
            'id': '',
            'tid': e.key,
            'nombre': e.value.isEmpty ? 'Entrenador' : e.value,
          });
        }
      }
      final filas = <Map<String, dynamic>>[];
      for (final persona in personas) {
        final username = persona['username'] as String;
        final tid = persona['tid'] as int?;
        // 1.23 AT-08: bono, comisión y libro salen de la FOTO
        // compartida, por la CLAVE canónica de la persona (la
        // clave resuelve por username y, en el respaldo sin
        // username, por nombre — mismo criterio que la foto y
        // que la pantalla de Nómina al repartir los bonos).
        // La comisión de la foto acumula TODOS los telegram_id
        // de la clave y el libro ya trae aplicarFotosLibro:
        // un mes liquidado manda por su foto, no por la tarifa
        // viva. Sin clave (persona del respaldo por cobros que
        // no resuelve), los componentes quedan en 0 como
        // degradación visible, no con un libro paralelo.
        final claveFoto =
            NominaCalc.claveEntrenador(username) ??
                NominaCalc.claveEntrenador(
                    '${persona['nombre'] ?? ''}');
        final bono = claveFoto == null
            ? NominaCalc.bonoSoloAmbos(bonos)
            : NominaCalc.bonosPara(bonos, claveFoto);
        final comision = claveFoto == null
            ? 0.0
            : (foto.comisionDosis[claveFoto]?.total ?? 0.0);
        final libroFoto =
            claveFoto == null ? null : foto.libroMes[claveFoto];
        final adelantosMes = libroFoto?.adelantos ?? 0.0;
        final deudaEntrante = libroFoto?.deudaEntrante ?? 0.0;
        final neto = NominaCalc.totalVivo(
          base: baseGlobal,
          bono: bono,
          comision: comision,
          adelantos: adelantosMes,
          deudaEntrante: deudaEntrante,
        );
        filas.add({
          'tid': tid,
          'nombre': persona['nombre'],
          'pagaron': pagaron,
          'base': baseGlobal,
          'bono': bono,
          'comision': comision,
          'adelantos': adelantosMes,
          'deudaEntrante': deudaEntrante,
          'neto': neto,
        });
      }
      filas.sort((a, b) =>
          (b['neto'] as double).compareTo(a['neto'] as double));
      if (mounted) {
        setState(() {
          _mes = mes;
          _calculadoEn = isoHabana(ahoraHabana());
          _porEntrenador = filas;
          _pagaronGlobal = pagaron;
          _tarifa = tarifa;
          _baseGlobal = baseGlobal;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Lote 3 (BLOQUEANTE): ver guarda en _cargar.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Nómina pre-calculada'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Nómina pre-calculada'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando nómina…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                  'Vista previa, puede cambiar con cobros hasta el 31. '
                  'El cierre real sigue siendo el día 31. Solo lectura: '
                  'nada de lo que ves aquí modifica la nómina.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                Text('Mes: $_mes · calculado: $_calculadoEn',
                    style: AppTexto.secundario),
                const SizedBox(height: 12),
                Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Base global: $_pagaronGlobal clientes × '
                          '${_tarifa.toStringAsFixed(0)} CUP = '
                          '${_baseGlobal.toStringAsFixed(0)} CUP '
                          'por entrenador',
                          style: AppTexto.cuerpo),
                      const Text(
                          'La base ya no depende de quién cobró: '
                          'cada entrenador parte de la misma base '
                          'global del mes.',
                          style: AppTexto.secundario),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 1.25 T105: la nómina VISUAL por
                // entrenador (antes, siete magnitudes
                // encadenadas en una frase con el neto
                // enterrado al final): neto protagonista,
                // la cascada en filas y la barra de
                // composición de T73.
                for (final f in _porEntrenador)
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment:
                              CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Text('${f['nombre']}',
                                  style: AppTexto.titulo),
                            ),
                            Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.end,
                              children: [
                                const Text('NETO',
                                    style: AppTexto.metadato),
                                Text(
                                  '${fmtMonto((f['neto'] as double))} CUP',
                                  style: AppTexto.metrica,
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: AppEspacio.sm),
                        _filaNominaVisual(
                            'Base (${f['pagaron']} pagaron)',
                            (f['base'] as double)),
                        if ((f['bono'] as double) != 0)
                          _filaNominaVisual(
                              '+ Bono', (f['bono'] as double)),
                        if ((f['comision'] as double) != 0)
                          _filaNominaVisual('+ Comisión dosis',
                              (f['comision'] as double)),
                        if ((f['adelantos'] as double) != 0)
                          _filaNominaVisual('− Adelantos',
                              (f['adelantos'] as double)),
                        if ((f['deudaEntrante'] as double) != 0)
                          _filaNominaVisual('− Deuda anterior',
                              (f['deudaEntrante'] as double)),
                        const SizedBox(height: AppEspacio.sm),
                        BarraComposicionNomina(
                          bruto: (f['base'] as double) +
                              (f['bono'] as double) +
                              (f['comision'] as double),
                          neto: (f['neto'] as double),
                          descuentos:
                              (f['adelantos'] as double) +
                                  (f['deudaEntrante'] as double),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  /// 1.25 T105: una fila de la cascada de la nómina
  /// visual (etiqueta a la izquierda, monto a la
  /// derecha, sin cortar con puntos suspensivos).
  Widget _filaNominaVisual(String etiqueta, double monto) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(etiqueta, style: AppTexto.cuerpo),
          ),
          Text('${fmtMonto(monto)} CUP', style: AppTexto.cuerpo),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// C3
// ---------------------------------------------------------------------------

class AdelantosListaScreen extends StatefulWidget {
  const AdelantosListaScreen({super.key});
  @override
  State<AdelantosListaScreen> createState() => _AdelantosListaScreenState();
}

class _AdelantosListaScreenState extends State<AdelantosListaScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _filas = [];
  String _filtroMes = 'todos';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Pasada 2 de Argón (1.20): la lista completa de adelantos
    // es solo del dueño (C1/C2/C6 ya guardaban; C3 no).
    if (!AuthService().isOwner) return;
    try {
      final filas = <Map<String, dynamic>>[];
      // 1.22 T-06: uuids ya presentes en el espejo, para cruzar
      // con la cola (patrón AR-C03): sin el cruce, un adelanto
      // recién sincronizado salía DOS veces en la ventana
      // push→pull (la fila del espejo y su op aún en cola).
      final uuidsEspejo = <String>{};
      for (final a in await LocalDb.instance.allMirror('adelantos')) {
        filas.add(a);
        final u = '${a['op_uuid'] ?? ''}'.trim();
        if (u.isNotEmpty) uuidsEspejo.add(u);
      }
      // Registrar_adelanto aún en cola en este teléfono (provisional).
      // Autoauditoría 1.22 #1: pendingOpsLectura (incluye
      // 'enviada'): con pendingOps, un adelanto recién enviado
      // desaparecía de la lista en esa ventana (T-06 era solo
      // el duplicado; la ventana inversa quedaba).
      for (final op in await LocalDb.instance.pendingOpsLectura()) {
        final opUuid = '${op['op_uuid'] ?? ''}'.trim();
        if (opUuid.isNotEmpty && uuidsEspejo.contains(opUuid)) {
          continue;
        }
        try {
          final p = jsonDecode(op['payload'] as String)
              as Map<String, dynamic>;
          if (op['tipo'] == 'registrar_adelanto') {
            filas.add({
              'id': null,
              'entrenador': p['entrenador'],
              'entrenador_nombre': p['entrenador_nombre'],
              'monto': p['monto'],
              'fecha': p['fecha'],
              'mes_nomina': '${p['fecha']}'.substring(0, 7),
              'nota': p['nota'],
              'pendiente': 1,
            });
          }
        } catch (_) {}
      }
      filas.sort((a, b) =>
          '${b['fecha']}'.compareTo('${a['fecha']}'));
      if (mounted) {
        setState(() {
          _filas = filas;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Adelantos'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    final meses = <String>{'todos'};
    for (final f in _filas) {
      meses.add('${f['mes_nomina'] ?? ''}');
    }
    meses.remove('');
    final visibles = _filtroMes == 'todos'
        ? _filas
        : _filas
            .where((f) => '${f['mes_nomina']}' == _filtroMes)
            .toList();
    return Scaffold(
      appBar: appBarIron(context, 'Adelantos'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando adelantos…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                  'Vista de solo lectura. La lógica de adelantos es '
                  'la de 1.8.0 (no se reescribe): el excedente sobre '
                  'el bruto arrastra como deuda al mes siguiente.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                SelectorIron<String>(
                  valor: _filtroMes,
                  tituloPanel: 'Mes',
                  opciones: [
                    for (final m in meses)
                      OpcionSelector(
                          m, m == 'todos' ? 'Todos los meses' : m)
                  ],
                  alCambiar: (v) =>
                      setState(() => _filtroMes = v ?? 'todos'),
                ),
                const SizedBox(height: 8),
                if (visibles.isEmpty)
                  // 1.25 T107: vacío con el estándar
                  // EstadoVacio (icono + explicación).
                  const EstadoVacio(
                    icono: Icons.forward_rounded,
                    titulo: 'Sin adelantos en este filtro',
                    subtitulo:
                        'Cuando un entrenador reciba un adelanto '
                        'de su nómina, saldrá aquí.',
                  )
                else
                  for (final f in visibles)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            '${f['entrenador_nombre'] ?? f['entrenador'] ?? '—'} · '
                            '${((f['monto'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)} CUP',
                            style: AppTexto.cuerpo),
                        subtitle: Text(
                            // SL-5 G07-5: fecha habanera con
                            // fmtFecha, no el ISO crudo.
                            '${fmtFecha('${f['fecha'] ?? ''}')} · mes nómina: '
                            '${f['mes_nomina'] ?? ''}'
                            '${f['pendiente'] == 1 ? ' · aún sin subir' : ''}'
                            '${f['nota'] != null && '${f['nota']}'.isNotEmpty ? ' · ${f['nota']}' : ''}',
                            style: AppTexto.secundario),
                      ),
                    ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      RutaIron(
                          builder: (_) => const NominaScreen())),
                  child: const Text(
                      'Registrar un adelanto nuevo (pantalla de Nómina)'),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// C5
// ---------------------------------------------------------------------------

class IngresosPeriodoScreen extends StatefulWidget {
  /// El servicio de reportes Plus es inyectable SOLO en
  /// tests (patrón de la casa): permite colgar la RPC de
  /// confirmados y verificar que el resumen local pinta
  /// sin esperarla (H-B5-4). Null en producción.
  final PlusReportesService? servicioPlus;

  const IngresosPeriodoScreen({super.key, this.servicioPlus});
  @override
  State<IngresosPeriodoScreen> createState() =>
      _IngresosPeriodoScreenState();
}

class _IngresosPeriodoScreenState extends State<IngresosPeriodoScreen> {
  bool _cargando = true;
  String _preset = 'mes';
  String _desde = '';
  String _hasta = '';
  ResumenIngresos? _resumen;
  bool _plusSinDatos = false;

  /// 1.32 (H-B5-4): la línea Plus aún se está consultando
  /// al servidor; la pantalla ya pintó el resumen local.
  bool _plusConsultando = false;
  int _nPlus = 0;

  /// Guarda de generación: cambiar de rango relanza la
  /// carga y la respuesta Plus de una carga vieja no
  /// puede recomponer el resumen del rango nuevo.
  int _generacion = 0;

  @override
  void initState() {
    super.initState();
    _aplicarPreset();
  }

  void _aplicarPreset() {
    final hoy = hoyHabanaIso();
    if (_preset == 'mes') {
      _desde = '${hoy.substring(0, 7)}-01';
      _hasta = hoy;
    } else if (_preset == 'semana') {
      final h = DateTime.tryParse(hoy) ?? ahoraHabana();
      final d = h.subtract(const Duration(days: 6));
      _desde =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      _hasta = hoy;
    } else if (_preset == 'quincena') {
      final h = DateTime.tryParse(hoy) ?? ahoraHabana();
      final d = h.subtract(const Duration(days: 14));
      _desde =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      _hasta = hoy;
    }
    _cargar();
  }

  Future<void> _cargar() async {
    // Pasada 2 de Argón (1.20): los ingresos del gym son solo
    // del dueño (C5 no guardaba; C1/C2/C6 sí).
    if (!AuthService().isOwner) return;
    final gen = ++_generacion;
    setState(() {
      _cargando = true;
      _plusConsultando = false;
      _plusSinDatos = false;
      _nPlus = 0;
    });
    final List<FilaIngreso> filas;
    try {
      // 1.29 (Oleada 2, D-A2): lectura por consultas de
      // rango (índice en pagos, filtro SQL en las demás)
      // en vez de cargar los cuatro espejos enteros y
      // filtrar en Dart; las cifras no cambian (la
      // equivalencia la vigila un test).
      filas = await filasIngresoPeriodo(_desde, _hasta);
    } catch (_) {
      if (mounted && gen == _generacion) {
        setState(() => _cargando = false);
      }
      return;
    }
    if (!mounted || gen != _generacion) return;
    // 1.32 (H-B5-4/B567): el resumen LOCAL se pinta ya,
    // con la línea Plus en estado «consultando»; la RPC
    // de confirmados va DETRÁS y al resolver recompone el
    // resumen sumándola. Antes, una conexión colgada
    // dejaba la pantalla en spinner eterno con el resumen
    // ya calculable en el teléfono (la clase de la ficha).
    setState(() {
      _resumen = resumenIngresos(filas, _desde, _hasta);
      _plusConsultando = true;
      _cargando = false;
    });
    unawaited(_sumarPlusDetras(filas, gen));
  }

  /// La línea Plus tras el primer pintado: reportes
  /// CONFIRMADOS del servidor (el espejo local no existe),
  /// solo por transferencia. Si la RPC falla o no hay red,
  /// la línea queda marcada sin datos y NO suma al total
  /// (nunca se inventa un número).
  Future<void> _sumarPlusDetras(
      List<FilaIngreso> filasLocales, int gen) async {
    try {
      final reps =
          await (widget.servicioPlus ?? PlusReportesService())
              .confirmados();
      final filas = [...filasLocales];
      var nPlus = 0;
      for (final r in reps) {
        // Fecha del ingreso: cuando se confirmó (resueltoEn); si
        // falta, cuando se reportó (creadoEn).
        final fecha = r.resueltoEn ?? r.creadoEn;
        if (fecha == null) continue;
        final f = '${fecha.year.toString().padLeft(4, '0')}-'
            '${fecha.month.toString().padLeft(2, '0')}-'
            '${fecha.day.toString().padLeft(2, '0')}';
        filas.add(FilaIngreso('plus', 'transferencia', r.monto, f));
        nPlus++;
      }
      if (!mounted || gen != _generacion) return;
      setState(() {
        _resumen = resumenIngresos(filas, _desde, _hasta);
        _nPlus = nPlus;
        _plusSinDatos = false;
        _plusConsultando = false;
      });
    } catch (_) {
      if (!mounted || gen != _generacion) return;
      setState(() {
        _plusSinDatos = true;
        _plusConsultando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Ingresos por período'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    final r = _resumen;
    return Scaffold(
      appBar: appBarIron(context, 'Ingresos por período'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando ingresos…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                  'Solo transacciones reales del rango, con el monto '
                  'congelado de cada cobro. Casa nunca ingresa. Un '
                  'invitado convertido suma su pase diario en Diarios '
                  'y su completivo en Mensualidades, sin duplicar.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                SelectorIron<String>(
                  valor: _preset,
                  tituloPanel: 'Período',
                  opciones: const [
                    OpcionSelector('mes', 'Mes en curso'),
                    OpcionSelector('semana', 'Últimos 7 días'),
                    OpcionSelector('quincena', 'Últimos 15 días'),
                  ],
                  alCambiar: (v) {
                    setState(() => _preset = v ?? 'mes');
                    _aplicarPreset();
                  },
                ),
                Text('Del $_desde al $_hasta (hora Habana)',
                    style: AppTexto.secundario),
                const SizedBox(height: 12),
                if (r == null)
                  // 1.25 T107: vacío con el estándar.
                  const EstadoVacio(
                    icono: Icons.insights_rounded,
                    titulo: 'Sin ingresos en este período',
                    subtitulo:
                        'Prueba con otro rango de fechas.',
                  )
                else ...[
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'Efectivo: ${r.efectivo.toStringAsFixed(0)} CUP',
                            style: AppTexto.cuerpo),
                        Text(
                            'Transferencia: '
                            '${r.transferencia.toStringAsFixed(0)} CUP',
                            style: AppTexto.cuerpo),
                        // 1.29 (Oleada 2, D-19): el total del
                        // período cuenta hasta su cifra al
                        // cambiar de rango (MontoAnimado), con
                        // el mismo formato final de antes.
                        MontoAnimado(
                          valor: r.total,
                          formato: (v) =>
                              'Total: ${v.toStringAsFixed(0)} CUP',
                          style: AppTexto.titulo,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Desglose por concepto',
                      style: AppTexto.titulo),
                  for (final c in kConceptosC5)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            c == 'plus'
                                ? 'Invitados Plus'
                                : '${c[0].toUpperCase()}${c.substring(1)}',
                            style: AppTexto.cuerpo),
                        trailing: Text(
                            '${(r.porConcepto[c] ?? 0).toStringAsFixed(0)} CUP',
                            style: AppTexto.cuerpo),
                        subtitle: c == 'plus'
                            ? Text(
                                _plusConsultando
                                    ? 'Consultando los confirmados al servidor…'
                                    : _plusSinDatos
                                        ? 'Sin datos del servidor (sin conexión o la RPC no devolvió confirmados): no suma al total.'
                                        : '$_nPlus confirmados en el rango · suma a Transferencias y al Total.',
                                style: AppTexto.secundario)
                            : null,
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// C6
// ---------------------------------------------------------------------------

class PreciosMetodoScreen extends StatefulWidget {
  const PreciosMetodoScreen({super.key});
  @override
  State<PreciosMetodoScreen> createState() => _PreciosMetodoScreenState();
}

const _kEtiquetasPrecios = {
  'mensualidad': 'Mensualidad (efectivo)',
  'mensualidad_menores': 'Mensualidad menores',
  'transferencia': 'Mensualidad (transferencia)',
  'pago_diario': 'Pago diario',
  'pago_semanal': 'Semanal',
  'pago_quincenal': 'Quincenal',
  'precio_app_plus': 'App Plus (A++)',
  'tasa_usd': 'Tasa USD (CUP por 1 USD)',
};

class _PreciosMetodoScreenState extends State<PreciosMetodoScreen> {
  bool _cargando = true;
  final _ctrls = <String, TextEditingController>{};
  // 1.25 T99: autoguardado por campo — focos propios (al
  // perder el foco se guarda ese campo), último valor
  // vigente por clave y la marca «guardado» por campo.
  final _focos = <String, FocusNode>{};
  final _valores = <String, double>{};
  final _okCampo = <String>{};
  String? _guardandoCampo;

  @override
  void dispose() {
    // Lote 3 (MENOR): los controladores se creaban en _cargar y
    // nunca se liberaban.
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focos.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // 1.22 T-10: guarda de dueño también en el método (la de
    // build sola no basta si el estado se crea por otra vía).
    if (!AuthService().isOwner) return;
    final aj = await LocalDb.instance.getAjustes();
    for (final k in kClavesPreciosC6) {
      // Yunque 4 (L2-1, clase K6-3): lector tolerante —
      // con una clave en texto (edición por bot/SQL), el
      // cast duro lanzaba TypeError y la pantalla quedaba
      // en «Cargando precios…» eterno, sin poder editar
      // ningún precio (ni la tasa que habría que corregir).
      final valor = montoAjusteTolerante(aj[k]) ?? 0;
      // Pasada 2 de Argón (1.20): liberar el controlador
      // anterior si _cargar corre más de una vez.
      _ctrls[k]?.dispose();
      _ctrls[k] = TextEditingController(text: '$valor');
      _valores[k] = valor;
      _focos[k]?.dispose();
      final foco = FocusNode();
      foco.addListener(() {
        if (!foco.hasFocus) unawaited(_autoguardar(k));
      });
      _focos[k] = foco;
    }
    if (mounted) setState(() => _cargando = false);
  }

  /// 1.25 T99: autoguardado por campo. Al salir del campo
  /// (o con «Listo» en el teclado), SOLO ese precio se
  /// guarda y se sincroniza: válido y distinto del
  /// vigente. Inválido: aviso y el campo vuelve al valor
  /// que SÍ rige (nunca queda en pantalla un precio que
  /// no está guardado).
  Future<void> _autoguardar(String k) async {
    // 1.22 T-10: cambiar precios es solo del dueño, también
    // guardado en el método.
    if (!AuthService().isOwner) return;
    if (_guardandoCampo != null) return;
    final ctrl = _ctrls[k];
    if (ctrl == null) return;
    final v = parsePrecioCampo(ctrl.text);
    if (v == null) {
      mostrarSnack(context, 'Precio inválido: ${_kEtiquetasPrecios[k]}', significado: SignificadoChip.alerta);
      ctrl.text = '${_valores[k] ?? ''}';
      return;
    }
    if (v == _valores[k]) return;
    setState(() {
      _guardandoCampo = k;
      _okCampo.remove(k);
    });
    try {
      await guardarConfigGym({k: v});
      // P2#16: republicar precio_app_plus a info_publica con
      // reintento durable (la cotización S2 lee el precio de
      // ahí, no del ajuste local).
      if (k == 'precio_app_plus') {
        unawaited(invitados_svc.InvitadosService()
            .guardarInfoPublicaConReintento(
                'precio_app_plus', '${v.round()}'));
      }
      _valores[k] = v;
      if (mounted) {
        setState(() {
          _guardandoCampo = null;
          _okCampo.add(k);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardandoCampo = null);
        AppLog.error('panel_caja', 'guardar_campo_fallo', d: '$e');
        mostrarSnack(context, mensajeErrorAmable(e), significado: SignificadoChip.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Precios por método'),
          body: const Center(
              child: Text('Solo el dueño cambia precios.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Precios por método'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando precios…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                  'Única fuente de precios: todo lo que cambias aquí '
                  'alimenta a calcularPrecioCobro() en todos los '
                  'teléfonos. Cada campo se guarda SOLO al salir de '
                  'él (mira el ✓ de cada precio). Las tarifas '
                  'especiales NO se editan aquí: tienen su pantalla '
                  'en Tarifas. Los cambios rigen hacia adelante: '
                  'los cobros ya hechos conservan su monto '
                  'congelado.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                for (final k in kClavesPreciosC6)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppEspacio.sm),
                    child: CampoMoneda(
                      controller: _ctrls[k]!,
                      focusNode: _focos[k],
                      etiqueta: _kEtiquetasPrecios[k],
                      moneda: 'CUP',
                      onSubmitted: (_) => _autoguardar(k),
                      onChanged: (_) =>
                          setState(() => _okCampo.remove(k)),
                      sufijo: _guardandoCampo == k
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              ),
                            )
                          : _okCampo.contains(k)
                              ? const Icon(Icons.check_circle_rounded,
                                  color: AppColores.exito, size: 20)
                              : null,
                    ),
                  ),
              ],
            ),
    );
  }
}
