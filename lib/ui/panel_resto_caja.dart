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

import '../auth.dart';
import '../bloque2_resto.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../nomina_foto.dart';
import '../plus_reportes.dart';
import '../tiempo.dart';
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
      // 1.22 T-03: la membresía de la lista no puede salir
      // solo del espejo: un entrenador cuyo pendiente vive
      // SOLO en la cola local de este teléfono (ops que aún
      // no bajan al espejo) no aparecía nunca, aunque
      // pendienteEntrega — que sí suma la cola — lo contaba.
      // Se añaden los beneficiarios con monto en cola que no
      // estén ya en la lista; el monto fino lo sigue dando
      // pendienteDeltaC1 más abajo, como a todos.
      try {
        // Panel Pieza 2: los ids se NORMALIZAN también en la
        // lista base (no solo en la cola): si un productor
        // futuro devolviera el telegram_id como texto, el
        // entrenador saldría dos veces (su tarjeta del espejo
        // y la de la cola).
        final tidsEnLista = <int>{
          for (final e in lista)
            if (LocalDb.normalizarTelegramId(e['telegram_id'])
                case final tidEnLista?)
              tidEnLista,
        };
        final pr = await preciosVigentes();
        final enCola = <int>{};
        for (final op
            in await LocalDb.instance.pendingOpsLectura()) {
          int? benef;
          if ('${op['tipo']}' == 'venta_servicio') {
            Map<String, dynamic>? pay;
            try {
              pay = jsonDecode(op['payload'] as String)
                  as Map<String, dynamic>;
            } catch (_) {}
            benef = (pay == null
                    ? null
                    : LocalDb.normalizarTelegramId(
                        pay['responsable_efectivo_id'])) ??
                LocalDb.normalizarTelegramId(op['telegram_id']);
          } else {
            benef = LocalDb.normalizarTelegramId(op['telegram_id']);
          }
          if (benef == null || tidsEnLista.contains(benef)) {
            continue;
          }
          if (montoEfectivoOp(op, pr) > 0 ||
              montoCobradoUsdOp(op) > 0) {
            enCola.add(benef);
          }
        }
        if (enCola.isNotEmpty) {
          final nombres = <int, String>{};
          try {
            final raw =
                await LocalDb.instance.getMeta('usuarios_apk');
            if (raw != null && raw.isNotEmpty) {
              for (final u in jsonDecode(raw) as List) {
                final m = Map<String, dynamic>.from(u as Map);
                final tidU =
                    LocalDb.normalizarTelegramId(m['telegram_id']);
                final n = '${m['nombre'] ?? ''}';
                if (tidU != null && n.isNotEmpty) {
                  nombres[tidU] = n;
                }
              }
            }
          } catch (_) {}
          for (final tid in enCola) {
            lista.add({
              'telegram_id': tid,
              'nombre': nombres[tid] ?? 'Entrenador $tid',
              'cup': 0.0,
              'usd': 0.0,
            });
          }
        }
      } catch (_) {}
      // H10 (Argón caja): la lista y el diálogo de liquidar usan
      // LA MISMA función. Antes la lista venía de pendienteArqueo
      // (e['cup']) y _liquidarAhora validaba con pendienteDeltaC1:
      // tras una parcial la tarjeta decía 700 y el botón decía
      // que no había pendiente. entrenadoresConPendiente solo se
      // conserva para la lista de entrenadores/nombres.
      // Autoauditoría 1.22 #1: pendiente_c1 Y el USD canónico
      // (ver completarPendientesArqueoC1; antes el usd quedaba
      // el de la lista base, ciego a la cola).
      await completarPendientesArqueoC1(lista);
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
    final tid = LocalDb.normalizarTelegramId(e['telegram_id']);
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
        // 1.22 T-03: si lo único pendiente es USD, el callejón
        // «Ya no hay pendiente» mentía: el USD existe y se
        // liquida en el Arqueo principal.
        final usd = (e['usd'] as num?)?.toDouble() ?? 0;
        mostrarSnack(
            context,
            usd > 0
                ? 'El pendiente de $nombre es solo en USD: se '
                    'liquida en el Arqueo principal, no en esta '
                    'pantalla.'
                : 'Ya no hay pendiente que liquidar',
            significado: SignificadoChip.alerta);
      }
      return;
    }
    // 1.29 (Oleada 4, barrido): el diálogo vive en un
    // StatefulWidget dueño de su controlador
    // (_DialogoLiquidarEntrega). Antes el controlador se
    // creaba aquí, sobrevivía entre las vueltas del bucle de
    // confirmación y se disponía al salir, con la animación
    // de salida del último diálogo aún reconstruyendo el
    // campo (defecto D-B1-08). El texto tecleado viaja ahora
    // de vuelta en vuelta como texto inicial.
    var textoMonto = pendiente.toStringAsFixed(0);
    var confirmado = false;
    while (!confirmado) {
      final r = await showDialog<String>(
        context: context,
        builder: (_) => _DialogoLiquidarEntrega(
          nombre: nombre,
          pendiente: pendiente,
          textoInicial: textoMonto,
        ),
      );
      if (r == null) return;
      textoMonto = r;
      final monto = double.tryParse(r.trim()) ?? -1;
      // Si el pendiente cambió desde que se abrió el diálogo, se
      // muestra el nuevo y se pide confirmar de nuevo (diseño C1).
      final nuevo = await pendienteDeltaC1(tid);
      if ((nuevo - pendiente).abs() > 0.01) {
        pendiente = nuevo;
        if (mounted) {
          mostrarSnack(context, 'El pendiente cambió a '
                  '${nuevo.toStringAsFixed(0)} CUP. Confirma de nuevo.', significado: SignificadoChip.alerta);
        }
        textoMonto = nuevo.toStringAsFixed(0);
        continue;
      }
      // Autoauditoría 1.22 #2 (clase N-2): NaN no es <= 0 ni
      // supera el pendiente (comparaciones falsas) y llegaba a
      // registrarEntregaEfectivo como monto de la entrega C1.
      if (!monto.isFinite || monto <= 0 || monto - pendiente > 0.01) {
        if (mounted) {
          mostrarSnack(context, 'Monto inválido o mayor que el pendiente', significado: SignificadoChip.alerta);
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
          mostrarSnack(context, 'Entrega registrada', significado: SignificadoChip.exito);
        }
        await _cargar();
      } catch (err) {
        if (mounted) {
          AppLog.error('panel_caja', 'registrar_entrega_fallo', d: '$err');
          mostrarSnack(context, mensajeErrorAmable(err), significado: SignificadoChip.error);
        }
        return;
      }
    }
  }

  /// 1.22 T-03: subtítulo de la tarjeta. Si el pendiente CUP
  /// es 0 pero hay USD, la tarjeta lo dice y apunta al Arqueo
  /// principal (antes el USD quedaba como un apunte «aparte»
  /// y el botón Liquidar caía en «Ya no hay pendiente»).
  String _subtituloPendiente(Map<String, dynamic> e) {
    final pend = ((e['pendiente_c1'] ?? e['cup']) as double);
    final usd = (e['usd'] as num?)?.toDouble() ?? 0;
    if (pend <= 0 && usd > 0) {
      return 'Sin pendiente en CUP · USD aparte: '
          '${usd.toStringAsFixed(0)} — el USD se liquida en el '
          'Arqueo principal';
    }
    return 'Pendiente: ${pend.toStringAsFixed(0)} CUP'
        '${usd > 0 ? ' · USD aparte: ${usd.toStringAsFixed(0)}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Liquidar efectivo'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Liquidar efectivo'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando liquidaciones…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
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
                        subtitle: Text(_subtituloPendiente(e),
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

/// 1.29 (Oleada 4, barrido de diálogos): «Liquidar entrega»
/// como StatefulWidget DUEÑO de su controlador, dispuesto
/// en dispose() — el patrón de la casa. Devuelve el texto
/// del monto al liquidar; null al cancelar. El bucle de
/// confirmación (pendiente cambiado / monto inválido) vive
/// en la pantalla y reabre el diálogo con el texto vigente.
class _DialogoLiquidarEntrega extends StatefulWidget {
  const _DialogoLiquidarEntrega({
    required this.nombre,
    required this.pendiente,
    required this.textoInicial,
  });

  final String nombre;
  final double pendiente;
  final String textoInicial;

  @override
  State<_DialogoLiquidarEntrega> createState() =>
      _DialogoLiquidarEntregaState();
}

class _DialogoLiquidarEntregaState
    extends State<_DialogoLiquidarEntrega> {
  late final TextEditingController _montoCtrl;

  @override
  void initState() {
    super.initState();
    _montoCtrl = TextEditingController(text: widget.textoInicial);
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Liquidar entrega',
      iconoTitulo: Icons.handshake_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.nombre} · pendiente actual: '
              '${widget.pendiente.toStringAsFixed(0)} CUP'),
          const SizedBox(height: 4),
          const Text(
            'Se registra como movimiento propio de custodia '
            '(entrega_efectivo_dueno): no es gasto ni adelanto de '
            'nómina, y no toca el reporte de ingresos.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 8),
          TextField(
              controller: _montoCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Monto entregado en efectivo (CUP)')),
        ],
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () =>
                Navigator.pop(context, _montoCtrl.text),
            child: const Text('Liquidar')),
      ],
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
    // Pasada 2 de Argón (1.20): los ingresos del gym son solo
    // del dueño (C5 no guardaba; C1/C2/C6 sí).
    if (!AuthService().isOwner) return;
    setState(() => _cargando = true);
    try {
      // 1.29 (Oleada 2, D-A2): lectura por consultas de
      // rango (índice en pagos, filtro SQL en las demás)
      // en vez de cargar los cuatro espejos enteros y
      // filtrar en Dart; las cifras no cambian (la
      // equivalencia la vigila un test).
      final filas = await filasIngresoPeriodo(_desde, _hasta);
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
      // Pasada 2 de Argón (1.20): liberar el controlador
      // anterior si _cargar corre más de una vez.
      _ctrls[k]?.dispose();
      _ctrls[k] = TextEditingController(
          text: '${(aj[k] as num?)?.toDouble() ?? 0}');
      _valores[k] = (aj[k] as num?)?.toDouble() ?? 0;
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
