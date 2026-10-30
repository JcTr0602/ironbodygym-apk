/// Pantallas C del Panel (1.11.0): C1, C2, C3.
///
/// - C1: arqueo de entrega de efectivo por DELTA (Argón ajuste 1).
///   El pendiente que se muestra es `pendienteEntrega() - entregas C1
///   registradas`. Liquidar pide confirmar el monto exacto; si el
///   pendiente cambió entre abrir y confirmar, se muestra el nuevo y
///   se pide confirmar de nuevo (nunca se liquida un monto viejo).
/// - C2: nómina pre-calculada, SOLO LECTURA, con la definición única
///   de NominaCalc (150 por cliente que pagó el mes, dueño ×300, sin
///   comisiones salvo dosis). Aviso de vista previa + fecha/hora.
/// - C3: lista de adelantos (vista; la lógica es la de 1.8.0 y el
///   registro nuevo vive en la pantalla de Nómina, no se duplica).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../adelantos.dart';
import '../auth.dart';
import '../bloque2_resto.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_bonos.dart';
import '../nomina_calc.dart';
import '../perfil.dart';
import '../plus_reportes.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'nomina.dart';

// ---------------------------------------------------------------------------
// C1
// ---------------------------------------------------------------------------

class ArqueoEntregaScreen extends StatefulWidget {
  const ArqueoEntregaScreen({super.key});
  @override
  State<ArqueoEntregaScreen> createState() => _ArqueoEntregaScreenState();
}

class _ArqueoEntregaScreenState extends State<ArqueoEntregaScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _entrenadores = [];
  // Lote 3 (MEDIO): bloquea el doble toque sobre "Liquidar" mientras
  // el primer llamado espera el pendiente (sin esto se apilaban dos
  // diálogos independientes).
  bool _liquidando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final lista = await entrenadoresConPendiente();
      // 1.15-turnos (#2, mecanismo único): e['cup'] ya es
      // pendienteArqueo, que descuenta el libro C1 con marca; NO
      // se resta otra vez (antes el arqueo no restaba el libro y
      // esta resta era necesaria; restarla ahora duplicaría).
      for (final e in lista) {
        e['pendiente_c1'] = e['cup'] as double;
      }
      if (mounted) {
        setState(() {
          _entrenadores = lista;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _liquidar(Map<String, dynamic> e) async {
    // Lote 3 (MEDIO): la guarda no puede vivir solo en build; el
    // método también la exige, y la bandera bloquea el doble toque.
    if (!AuthService().isOwner) return;
    if (_liquidando) return;
    final tid = e['telegram_id'] as int?;
    if (tid == null) return;
    setState(() => _liquidando = true);
    try {
      await _liquidarAhora(e, tid);
    } finally {
      if (mounted) setState(() => _liquidando = false);
    }
  }

  /// Cuerpo real de _liquidar, separado para que la bandera viva en
  /// el finally del llamador aunque el diálogo se cancele o falle.
  Future<void> _liquidarAhora(Map<String, dynamic> e, int tid) async {
    final nombre = '${e['nombre'] ?? 'Entrenador'}';
    // Re-leer el pendiente en el momento de confirmar (diseño C1).
    var pendiente = await pendienteDeltaC1(tid);
    if (pendiente <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ya no hay pendiente que liquidar')));
      }
      return;
    }
    final montoCtrl =
        TextEditingController(text: pendiente.toStringAsFixed(0));
    var confirmado = false;
    while (!confirmado) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Liquidar entrega',
          iconoTitulo: Icons.handshake,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$nombre · pendiente actual: '
                  '${pendiente.toStringAsFixed(0)} CUP'),
              const SizedBox(height: 4),
              const Text(
                'Se registra como movimiento propio de custodia '
                '(entrega_efectivo_dueno): no es gasto ni adelanto de '
                'nómina, y no toca el reporte de ingresos.',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: 8),
              TextField(
                  controller: montoCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Monto entregado en efectivo (CUP)')),
            ],
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Liquidar')),
          ],
        ),
      );
      if (ok != true) {
        montoCtrl.dispose();
        return;
      }
      final monto = double.tryParse(montoCtrl.text.trim()) ?? -1;
      // Si el pendiente cambió desde que se abrió el diálogo, se
      // muestra el nuevo y se pide confirmar de nuevo (diseño C1).
      final nuevo = await pendienteDeltaC1(tid);
      if ((nuevo - pendiente).abs() > 0.01) {
        pendiente = nuevo;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('El pendiente cambió a '
                  '${nuevo.toStringAsFixed(0)} CUP. Confirma de nuevo.')));
        }
        montoCtrl.text = nuevo.toStringAsFixed(0);
        continue;
      }
      if (monto <= 0 || monto - pendiente > 0.01) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Monto inválido o mayor que el pendiente')));
        }
        continue;
      }
      try {
        await registrarEntregaEfectivo(
          entrenadorTelegramId: tid,
          montoEntregado: monto,
          autorDuenoId: AuthService().telegramId ?? 0,
        );
        confirmado = true;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Entrega registrada')));
        }
        await _cargar();
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$err')));
        }
        montoCtrl.dispose();
        return;
      }
    }
    // Lote 3 (MEDIO): el controlador se creaba en cada llamado y
    // nunca se liberaba en ningún camino de salida.
    montoCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Arqueo de entrega')),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Arqueo de entrega')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Pendiente = efectivo cobrado − adelantos de gaveta '
                  '− entregas ya registradas. Un cobro offline que llegue después '
                  'de liquidar suma limpio, sin descontarse dos veces.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                if (_entrenadores.isEmpty)
                  const Text('Nadie tiene pendiente por entregar.',
                      style: AppTexto.secundario)
                else
                  for (final e in _entrenadores)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${e['nombre']}',
                            style: AppTexto.cuerpo),
                        subtitle: Text(
                            'Pendiente: '
                            '${((e['pendiente_c1'] ?? e['cup']) as double).toStringAsFixed(0)} CUP'
                            '${((e['usd'] as double) > 0) ? ' · USD aparte: ${(e['usd'] as double).toStringAsFixed(0)}' : ''}',
                            style: AppTexto.secundario),
                        trailing: TextButton(
                            onPressed:
                                _liquidando ? null : () => _liquidar(e),
                            child: const Text('Liquidar')),
                      ),
                    ),
              ],
            ),
    );
  }
}

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
      // P2#10: base GLOBAL, no agrupada por quién cobró. Es la
      // misma definición que la pantalla de Nómina: clientes
      // únicos que pagaron el mes (NominaCalc, ya excluye Casa y
      // el vencido-dentro-del-mes) × tarifa configurable.
      final pagaron =
          await NominaCalc.clientesQuePagaronElMes(mes);
      final tarifa =
          (await PerfilService.instance.getPagoEntrenador())
              .toDouble();
      final baseGlobal = pagaron * tarifa;
      final bonos = await BonosNominaService.instance.leerBonos(mes);
      final ventasServ =
          await LocalDb.instance.allMirror('servicio_ventas');
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
        final id = persona['id'] as String;
        final bono = username.isEmpty
            ? NominaCalc.bonoSoloAmbos(bonos)
            : NominaCalc.bonosPara(bonos, username);
        final comision = tid == null
            ? 0.0
            : NominaCalc.comisionDosisDesdeVentas(
                    ventasServ, tid, mes)
                .total;
        // Libro corrido de adelantos hasta este mes (igual que la
        // pantalla de Nómina): adelantos del mes y deuda entrante.
        var adelantosMes = 0.0;
        var deudaEntrante = 0.0;
        try {
          final eventos = await AdelantosService.instance
              .eventosDe(id, telegramId: tid);
          var primero = mes;
          for (final ev in eventos) {
            final mm = '${ev['mes_nomina'] ?? ''}';
            if (mm.length == 7 && mm.compareTo(primero) < 0) {
              primero = mm;
            }
          }
          final brutoPorMes = <String, double>{};
          var m = primero;
          while (m.compareTo(mes) <= 0) {
            brutoPorMes[m] =
                (await NominaCalc.clientesQuePagaronElMes(m)) *
                    tarifa;
            m = mesSiguiente(m);
          }
          final libro = libroAdelantos(
            eventos: eventos,
            brutoPorMes: brutoPorMes,
            comisionesPorMes: tid == null
                ? {mes: comision}
                : NominaCalc.comisionesPorMesDesdeVentas(
                    ventasServ, tid, primero, mes),
            hastaMes: mes,
          );
          for (final filaLibro in libro) {
            if (filaLibro.mes == mes) {
              adelantosMes = filaLibro.adelantos;
              deudaEntrante = filaLibro.deudaEntrante;
            }
          }
        } catch (_) {}
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
          appBar: AppBar(title: const Text('Nómina pre-calculada')),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Nómina pre-calculada')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
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
                for (final f in _porEntrenador)
                  Tarjeta(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${f['nombre']}',
                          style: AppTexto.cuerpo),
                      subtitle: Text(
                          'Pagaron (global): ${f['pagaron']} · base: '
                          '${(f['base'] as double).toStringAsFixed(0)} · '
                          'bono: '
                          '${(f['bono'] as double).toStringAsFixed(0)} · '
                          'comisión dosis: '
                          '${(f['comision'] as double).toStringAsFixed(0)} · '
                          'adelantos: '
                          '${(f['adelantos'] as double).toStringAsFixed(0)} · '
                          'deuda anterior: '
                          '${(f['deudaEntrante'] as double).toStringAsFixed(0)} · '
                          'neto: ${(f['neto'] as double).toStringAsFixed(0)} CUP',
                          style: AppTexto.secundario),
                    ),
                  ),
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
    try {
      final filas = <Map<String, dynamic>>[];
      for (final a in await LocalDb.instance.allMirror('adelantos')) {
        filas.add(a);
      }
      // Registrar_adelanto aún en cola en este teléfono (provisional).
      for (final op in await LocalDb.instance.pendingOps()) {
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
      appBar: AppBar(title: const Text('Adelantos')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Vista de solo lectura. La lógica de adelantos es '
                  'la de 1.8.0 (no se reescribe): el excedente sobre '
                  'el bruto arrastra como deuda al mes siguiente.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  value: _filtroMes,
                  isExpanded: true,
                  items: [
                    for (final m in meses)
                      DropdownMenuItem(
                          value: m,
                          child: Text(m == 'todos' ? 'Todos los meses' : m))
                  ],
                  onChanged: (v) =>
                      setState(() => _filtroMes = v ?? 'todos'),
                ),
                const SizedBox(height: 8),
                if (visibles.isEmpty)
                  const Text('Sin adelantos en este filtro.',
                      style: AppTexto.secundario)
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
                            '${f['fecha'] ?? ''} · mes nómina: '
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
                      MaterialPageRoute(
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
  const IngresosPeriodoScreen({super.key});
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
  int _nPlus = 0;

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
    setState(() => _cargando = true);
    try {
      final filas = <FilaIngreso>[];
      for (final p in await LocalDb.instance.allMirror('pagos')) {
        final f = filaIngresoDesdeEspejo('pagos', p);
        if (f != null) filas.add(f);
      }
      for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
        final f = filaIngresoDesdeEspejo('pagos_diarios', d);
        if (f != null) filas.add(f);
      }
      for (final v in await LocalDb.instance.allMirror('ventas_suplementos')) {
        final f = filaIngresoDesdeEspejo('ventas_suplementos', v);
        if (f != null) filas.add(f);
      }
      for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
        final f = filaIngresoDesdeEspejo('servicio_ventas', v);
        if (f != null) filas.add(f);
      }
      // Plus: línea propia, solo por transferencia, desde reportes
      // CONFIRMADOS del servidor (el espejo local no existe). Si la
      // RPC falla o no hay red, la línea queda marcada sin datos y
      // NO suma al total (nunca se inventa un número).
      var plusSinDatos = false;
      var nPlus = 0;
      try {
        final reps = await PlusReportesService().confirmados();
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
      } catch (_) {
        plusSinDatos = true;
      }
      final resumen = resumenIngresos(filas, _desde, _hasta);
      if (mounted) {
        setState(() {
          _resumen = resumen;
          _plusSinDatos = plusSinDatos;
          _nPlus = nPlus;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _resumen;
    return Scaffold(
      appBar: AppBar(title: const Text('Ingresos por período')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Solo transacciones reales del rango, con el monto '
                  'congelado de cada cobro. Casa nunca ingresa. Un '
                  'invitado convertido suma su pase diario en Diarios '
                  'y su completivo en Mensualidades, sin duplicar.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  value: _preset,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'mes', child: Text('Mes en curso')),
                    DropdownMenuItem(value: 'semana', child: Text('Últimos 7 días')),
                    DropdownMenuItem(
                        value: 'quincena', child: Text('Últimos 15 días')),
                  ],
                  onChanged: (v) {
                    setState(() => _preset = v ?? 'mes');
                    _aplicarPreset();
                  },
                ),
                Text('Del $_desde al $_hasta (hora Habana)',
                    style: AppTexto.secundario),
                const SizedBox(height: 12),
                if (r == null)
                  const Text('Sin datos.', style: AppTexto.secundario)
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
                        Text('Total: ${r.total.toStringAsFixed(0)} CUP',
                            style: AppTexto.titulo),
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
                                _plusSinDatos
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
};

class _PreciosMetodoScreenState extends State<PreciosMetodoScreen> {
  bool _cargando = true;
  final _ctrls = <String, TextEditingController>{};

  @override
  void dispose() {
    // Lote 3 (MENOR): los 7 controladores se creaban en _cargar y
    // nunca se liberaban.
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final aj = await LocalDb.instance.getAjustes();
    for (final k in kClavesPreciosC6) {
      _ctrls[k] = TextEditingController(
          text: '${(aj[k] as num?)?.toDouble() ?? 0}');
    }
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar() async {
    final cambios = <String, dynamic>{};
    for (final k in kClavesPreciosC6) {
      final v = double.tryParse(_ctrls[k]!.text.trim());
      // P2#16: el 0 también se rechaza (antes pasaba con v < 0).
      if (v == null || v <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Precio inválido: ${_kEtiquetasPrecios[k]}')));
        return;
      }
      cambios[k] = v;
    }
    try {
      await guardarConfigGym(cambios);
      // P2#16: republicar precio_app_plus a info_publica con
      // reintento durable, como hace admin (la cotización S2 lee
      // el precio de ahí, no del ajuste local).
      final precioPlus = cambios['precio_app_plus'];
      if (precioPlus != null) {
        final entero = (precioPlus as num).round();
        unawaited(invitados_svc.InvitadosService()
            .guardarInfoPublicaConReintento(
                'precio_app_plus', '$entero'));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Precios guardados y sincronizados a los entrenadores')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Precios por método')),
          body: const Center(
              child: Text('Solo el dueño cambia precios.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Precios por método')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Única fuente de precios: todo lo que cambias aquí '
                  'alimenta a calcularPrecioCobro() en todos los '
                  'teléfonos. Las tarifas especiales NO se editan '
                  'aquí: tienen su pantalla en Tarifas. Los '
                  'cambios rigen hacia adelante: los cobros ya hechos '
                  'conservan su monto congelado.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                for (final k in kClavesPreciosC6)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _ctrls[k],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: _kEtiquetasPrecios[k],
                          suffixText: 'CUP'),
                    ),
                  ),
                const SizedBox(height: 12),
                ElevatedButton(
                    onPressed: _guardar,
                    child: const Text('Guardar y sincronizar')),
              ],
            ),
    );
  }
}
