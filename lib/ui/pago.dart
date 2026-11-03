/// Agregar pago: caja rápida de mensualidades.
///
/// Resumen del día arriba (total, cantidad, efectivo vs transferencia),
/// deshacer último pago propio, últimos 10 cobros con hora.
/// La lista de clientes va con vencidos primero y filtro Solo vencidos;
/// el cobro se hace en 2 toques vía el diálogo unificado de pago.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'buscar.dart';
import 'componentes.dart';
import 'dialogo_pago.dart';
import 'preview_cobro.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

/// Un cobro del día: viene del espejo (ya sincronizado) o de una op
/// local aún en cola. Se ordenan por hora descendente.
class _Cobro {
  final String nombre;
  final double monto;
  final String metodo; // 'efectivo' | 'transferencia'
  final DateTime ts;
  final String? opUuid; // op local (pendiente/error/enviada)
  final String? estadoOp;
  final int? pagoId; // pago en el espejo (servidor)
  final int? telegramUserId; // quién lo registró (espejo)
  final int? clienteId;
  // Contrato P1#4 con preview_cobro: si la op trae
  // 'pagado_hasta_anterior', al deshacerla se restaura el espejo
  // a ese valor. [tienePagadoHastaAnterior] distingue "campo
  // ausente" (otro agente aún no lo escribe) de "anterior null".
  final bool tienePagadoHastaAnterior;
  final String? pagadoHastaAnterior;

  const _Cobro({
    required this.nombre,
    required this.monto,
    required this.metodo,
    required this.ts,
    this.opUuid,
    this.estadoOp,
    this.pagoId,
    this.telegramUserId,
    this.clienteId,
    this.tienePagadoHastaAnterior = false,
    this.pagadoHastaAnterior,
  });

  bool get esLocal => opUuid != null;

  /// Solo se puede deshacer lo que cobré yo: mis ops locales
  /// (la cola es por dispositivo) o mis pagos en el espejo.
  bool esMio(int? miTelegramId) {
    if (esLocal) return true;
    if (miTelegramId == null) return false;
    return telegramUserId == miTelegramId;
  }

  String get hora =>
      '${ts.hour.toString().padLeft(2, '0')}:'
      '${ts.minute.toString().padLeft(2, '0')}';
}

class PagoScreen extends StatefulWidget {
  const PagoScreen({super.key});
  @override
  State<PagoScreen> createState() => _PagoScreenState();
}

class _PagoScreenState extends State<PagoScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _res = [];
  bool _busco = false;
  bool _soloVencidos = false;
  List<_Cobro> _cobros = [];
  bool _cargandoCobros = true;
  // PagoIds del espejo con anular_pago ya en cola (ver _cargarDatos).
  Set<int> _anulacionesVivas = {};

  final _auth = AuthService();

  // Argón 1.21 AR-03: mismo patrón que BuscarScreen (D-09):
  // debounce de 200 ms al teclear y contador de generación
  // para descartar resultados obsoletos que lleguen tarde.
  int _gen = 0;
  Timer? _debounceBusqueda;

  void _buscarConDebounce() {
    _debounceBusqueda?.cancel();
    _debounceBusqueda =
        Timer(const Duration(milliseconds: 200), _buscar);
  }

  @override
  void dispose() {
    // Pasada 2 de Argón (1.20): _q no se liberaba nunca.
    _debounceBusqueda?.cancel();
    _q.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _buscar();
    _cargarDatos();
  }

  String _hoyStr() => hoyHabanaIso();

  /// Cobros del día: espejo + ops locales pago_mensual aún no aplicadas.
  /// Incluye las pendientes aunque no haya internet (caja offline).
  Future<void> _cargarDatos() async {
    final hoyStr = _hoyStr();
    final cobros = <_Cobro>[];
    // P1#3: el dueño ve todo (soloTelegramId null); el entrenador
    // solo sus cobros. Los protegidos se omiten para no-dueño.
    final esDueno = _auth.isOwner;
    final soloTid = esDueno
        ? null
        : LocalDb.normalizarTelegramId(_auth.telegramId);

    // 1) Espejo: pagos con fecha de hoy (ya pasaron por el servidor).
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    final pagosHoy = await LocalDb.instance.pagosDelDia(
      hoyStr,
      soloTelegramId: soloTid,
    );

    // 2) Cola local: pago_mensual de hoy en pendiente/error/enviada.
    //    Una op aplicada ya está en el espejo (sin duplicados).
    final opsHoy = <Map<String, dynamic>>[];
    final opsPayload = <Map<String, dynamic>>[];
    for (final op in [
      ...await LocalDb.instance.pendingOps(),
      ...await LocalDb.instance.opsByEstado('enviada'),
    ]) {
      if ('${op['tipo']}' != 'pago_mensual') continue;
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(op['payload'] as String);
      } catch (_) {
        continue;
      }
      if (!'${payload['fecha'] ?? ''}'.startsWith(hoyStr)) continue;
      opsHoy.add(op);
      opsPayload.add(payload);
    }

    // Pasada 2 de Argón (1.20): pagos del espejo con una
    // anulación ya en cola NO se ofrecen otra vez en «Deshacer
    // último» (la fila sigue en el espejo hasta que el pull la
    // retira; sin esto, un segundo toque encolaba otra
    // anular_pago para el mismo pago). El pago SIGUE contando
    // en los totales del día hasta que la anulación se aplica:
    // solo se excluye de _ultimoMio vía este conjunto.
    _anulacionesVivas = <int>{};
    for (final op in [
      ...await LocalDb.instance.pendingOps(),
      ...await LocalDb.instance.opsByEstado('enviada'),
    ]) {
      if ('${op['tipo']}' != 'anular_pago') continue;
      try {
        final p = jsonDecode(op['payload'] as String)
            as Map<String, dynamic>;
        final pid = (p['pago_id'] as num?)?.toInt();
        if (pid != null) _anulacionesVivas.add(pid);
      } catch (_) {}
    }

    // P1#15: una sola mirrorPorIds para todos los clientes, en vez
    // de un clientePorId por cobro dentro de los bucles.
    final ids = <int>{
      for (final p in pagosHoy)
        if ((p['cliente_id'] as num?) != null)
          (p['cliente_id'] as num).toInt(),
      for (final payload in opsPayload)
        if ((payload['cliente_id'] as num?) != null)
          (payload['cliente_id'] as num).toInt(),
    };
    final porId = <int, Map<String, dynamic>>{};
    for (final c in await LocalDb.instance
        .mirrorPorIds('clientes', ids.toList())) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) porId[id] = c;
    }
    bool protegido(int cid) =>
        !esDueno && porId[cid] != null && esVistaProtegida(porId[cid]!);

    for (final p in pagosHoy) {
      final cid = (p['cliente_id'] as num?)?.toInt() ?? 0;
      if (protegido(cid)) continue;
      final nombre = '${porId[cid]?['nombre'] ?? '¿?'}';
      DateTime ts;
      try {
        // Auditoría 1.21 D-01: a Habana por la regla canónica,
        // no a la zona del dispositivo (.toLocal()).
        final p0 = DateTime.parse('${p['created_at']}');
        ts = p0.isUtc ? aHabana(p0) : p0;
      } catch (_) {
        ts = ahoraHabana();
      }
      cobros.add(_Cobro(
        nombre: nombre,
        monto: (p['monto'] as num?)?.toDouble() ?? 0,
        metodo: '${p['metodo'] ?? 'efectivo'}',
        ts: ts,
        pagoId: p['id'] as int?,
        telegramUserId: (p['telegram_user_id'] as num?)?.toInt(),
        clienteId: cid,
      ));
    }

    for (var i = 0; i < opsHoy.length; i++) {
      final op = opsHoy[i];
      final payload = opsPayload[i];
      final cid = (payload['cliente_id'] as num?)?.toInt() ?? 0;
      if (protegido(cid)) continue;
      final nombre = '${porId[cid]?['nombre'] ?? '¿?'}';
      DateTime ts;
      try {
        final p0 = DateTime.parse('${op['creada_ts']}');
        ts = p0.isUtc ? aHabana(p0) : p0;
      } catch (_) {
        ts = ahoraHabana();
      }
      final anteriorRaw = payload['pagado_hasta_anterior'];
      cobros.add(_Cobro(
        nombre: nombre,
        monto: (payload['monto'] as num?)?.toDouble() ?? 0,
        metodo: '${payload['metodo'] ?? 'efectivo'}',
        ts: ts,
        opUuid: '${op['op_uuid']}',
        estadoOp: '${op['estado']}',
        clienteId: cid,
        tienePagadoHastaAnterior:
            payload.containsKey('pagado_hasta_anterior'),
        pagadoHastaAnterior: anteriorRaw == null
            ? null
            : '$anteriorRaw',
      ));
    }

    cobros.sort((a, b) => b.ts.compareTo(a.ts));
    if (mounted) {
      setState(() {
        _cobros = cobros;
        _cargandoCobros = false;
      });
    }
  }

  double get _totalHoy =>
      _cobros.fold(0.0, (t, c) => t + c.monto);
  double get _efectivoHoy => _cobros
      .where((c) => c.metodo == 'efectivo')
      .fold(0.0, (t, c) => t + c.monto);
  double get _transferHoy => _totalHoy - _efectivoHoy;

  /// El último cobro propio del día (el que se puede deshacer).
  _Cobro? get _ultimoMio {
    final miTid = _auth.telegramId;
    for (final c in _cobros) {
      if (!c.esMio(miTid)) continue;
      // Con anulación ya en cola no se ofrece de nuevo.
      if (c.pagoId != null && _anulacionesVivas.contains(c.pagoId)) {
        continue;
      }
      return c;
    }
    return null;
  }

  Future<void> _buscar() async {
    // Argón 1.21 AR-03: descartar resultados obsoletos.
    final gen = ++_gen;
    var r = await listaClientes(_q.text);
    if (gen != _gen) return;
    // P1#3: listaClientes('') devuelve todos los activos sin filtro
    // de protegido; el no-dueño no debe verlos ni siquiera en la
    // lista (la fuga real con "Solo vencidos": FilaCliente ya
    // oculta el botón Pagar al protegido).
    if (!_auth.isOwner) {
      r = r.where((c) => !esVistaProtegida(c)).toList();
    }
    // Vencidos primero, luego por vencer.
    r.sort((a, b) {
      final da = _diasRestantes(a);
      final db = _diasRestantes(b);
      return da.compareTo(db);
    });
    if (_soloVencidos) {
      r = r.where((c) => _diasRestantes(c) < 0).toList();
    }
    if (mounted) {
      setState(() {
        _res = r;
        _busco = true;
      });
    }
  }

  int _diasRestantes(Map<String, dynamic> c) {
    try {
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.length < 10) return 999;
      final v = DateTime.parse(ph.substring(0, 10));
      final hoy = ahoraHabana();
      final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
      return v.difference(hoyDia).inDays;
    } catch (_) {
      return 999;
    }
  }

  Future<void> _pagar(Map<String, dynamic> c) async {
    // Bloque 1 (Argón AMARILLO): Casa no paga mensualidad, y todo
    // cobro pasa por Preview + Recibo (sin atajos).
    if (await mostrarBloqueoCasa(context, c)) return;
    if (!mounted) return;
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    final deshecho = await cobrarConPreviewYRecibo(
      context: context,
      nombreCliente: '${c['nombre'] ?? ''}',
      payload: payload,
    );
    // v1.0.15: vibración de confirmación (caja rápida).
    if (!deshecho) HapticFeedback.lightImpact();
    if (!mounted) return;
    mostrarSnack(context, deshecho
            ? 'Cobro deshecho'
            : 'Pago de ${c['nombre']} guardado', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
    _cargarDatos();
    _buscar();
  }

  /// Deshace el último cobro propio del día.
  ///
  /// - Op local pendiente/error: nunca llegó al servidor → se elimina
  ///   de la cola (deleteOp solo borra esos estados, es seguro).
  /// - Pago en espejo: se encola 'anular_pago' (op ya soportada por
  ///   el servidor).
  /// - Op 'enviada' (en camino): no se toca, se avisa que espere.
  Future<void> _deshacerUltimo() async {
    final u = _ultimoMio;
    if (u == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Deshacer último pago',
        iconoTitulo: Icons.undo_rounded,
        contenido: Text(
            '¿Anular el cobro de ${u.nombre} por '
            '${fmtMonto(u.monto)} CUP (${u.hora})?'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, deshacer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    if (u.esLocal && u.opUuid != null) {
      if (u.estadoOp == 'pendiente' || u.estadoOp == 'error') {
        // Nunca se envió: borrar la op es seguro.
        // SA-03: comprobar el borrado antes de anunciarlo.
        // Autoauditoría 1.22 #2 (D2-06): el ORDEN importa —
        // primero se borra la op y SOLO si se borró se restaura
        // el espejo. Antes se restauraba el pagado_hasta primero
        // y, si deleteOp devolvía 0 (la op ya había subido entre
        // la carga y el toque), el espejo quedaba revertido con
        // el pago vivo en el servidor: el cliente aparecía
        // vencido en este teléfono estando pagado.
        final borradas =
            await LocalDb.instance.deleteOp(u.opUuid!);
        if (!mounted) return;
        if (borradas == 0) {
          mostrarSnack(context, 'Ese pago se está sincronizando, intenta en unos segundos', significado: SignificadoChip.alerta);
          return;
        }
        // P1#4 (contrato): si la op trae 'pagado_hasta_anterior',
        // restaurar el espejo a ese valor al borrarla. Sin ese
        // campo (otro agente aún no lo escribe en preview_cobro),
        // no se inventa otro mecanismo: solo se borra la op.
        if (u.tienePagadoHastaAnterior && u.clienteId != null) {
          final anterior = u.pagadoHastaAnterior;
          if (anterior != null && anterior.isNotEmpty) {
            await LocalDb.instance
                .updateMirrorPagadoHasta(u.clienteId!, anterior);
          } else {
            // Anterior null: updateMirrorPagadoHasta no acepta
            // null, así que se quita la clave del JSON del espejo
            // (pagado_hasta no es columna dedicada, solo JSON).
            await LocalDb.instance.updateMirrorBasico(
                u.clienteId!, {'pagado_hasta': null});
          }
        }
        mostrarSnack(context, 'Pago deshecho (no había sido enviado)', significado: SignificadoChip.exito);
      } else {
        // 'enviada': ya va en camino al servidor, no se puede borrar.
        if (!mounted) return;
        mostrarSnack(context, 'Ese pago se está sincronizando, intenta en unos segundos', significado: SignificadoChip.alerta);
        return;
      }
    } else if (u.pagoId != null) {
      // Panel 1.9 (Luna, rebajado a MEDIO tras verificar el
      // servidor): anular_pago EXIGE dueño en el servidor
      // (_require_owner), así que ofrecerlo al entrenador solo
      // produce un mensaje engañoso de éxito y una op rechazada.
      // Sin ser dueño, avisar y no encolar.
      if (!_auth.isOwner) {
        if (!mounted) return;
        mostrarSnack(context, 'Solo el dueño puede anular un pago ya sincronizado', significado: SignificadoChip.alerta);
        return;
      }
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago',
        payload: {'pago_id': u.pagoId},
      );
      if (!mounted) return;
      mostrarSnack(context, 'Pago anulado (se sincronizará)', significado: SignificadoChip.exito);
      SyncEngine.instance.push();
    } else {
      return;
    }
    _cargarDatos();
    _buscar();
  }

  Widget _resumenDia() {
    final ultimo = _ultimoMio;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Tarjeta(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    Text(
                      '${fmtMonto(_totalHoy)} CUP',
                      style: AppTexto.metrica.copyWith(
                          color: AppColores.naranja),
                    ),
                    Text('Cobrado hoy',
                        style: AppTexto.etiqueta.copyWith(
                            color: cs.onSurfaceVariant)),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      '${_cobros.length}',
                      style: AppTexto.metrica,
                    ),
                    Text('Pagos hoy',
                        style: AppTexto.etiqueta.copyWith(
                            color: cs.onSurfaceVariant)),
                  ],
                ),
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.payments_rounded,
                          size: 14,
                          color: AppColores.exito),
                      const SizedBox(width: 4),
                      Text(fmtMonto(_efectivoHoy),
                          style: AppTexto.cuerpo),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.smartphone_rounded,
                          size: 14,
                          color: AppColores.info),
                      const SizedBox(width: 4),
                      Text(fmtMonto(_transferHoy),
                          style: AppTexto.cuerpo),
                    ]),
                  ],
                ),
              ],
            ),
            if (ultimo != null) ...[
              const SizedBox(height: AppEspacio.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: Text(
                      'Deshacer último (${fmtMonto(ultimo.monto)} CUP)'),
                  onPressed: _deshacerUltimo,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColores.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _ultimosCobros() {
    if (_cargandoCobros) return const SizedBox.shrink();
    final items = _cobros.take(10).toList();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          leading: Icon(Icons.schedule_rounded,
              color: AppColores.textoSecundario(context)),
          title: Text('Últimos cobros (${items.length})',
              style: AppTexto.cuerpo
                  .copyWith(fontWeight: FontWeight.w600)),
          children: items.isEmpty
              ? const [
                  Padding(
                    padding: EdgeInsets.all(
                        AppEspacio.md),
                    child: Text('Aún no hay cobros hoy.',
                        style: AppTexto.secundario),
                  ),
                ]
              : items.map((c) {
                  final mio = c.esMio(_auth.telegramId);
                  final iconoMetodo =
                      c.metodo == 'efectivo'
                          ? Icons.payments_rounded
                          : Icons.smartphone_rounded;
                  return ListTile(
                    dense: true,
                    leading: Icon(iconoMetodo,
                        size: 20,
                        color: c.metodo == 'efectivo'
                            ? AppColores.exito
                            : AppColores.info),
                    title: Text(c.nombre,
                        style: AppTexto.cuerpo.copyWith(
                            fontWeight: mio
                                ? FontWeight.bold
                                : FontWeight.normal)),
                    subtitle: Text(
                        '${c.hora}'
                        '${c.esLocal && c.estadoOp != 'enviada' ? ' · por subir' : ''}'
                        '${c.esLocal && c.estadoOp == 'enviada' ? ' · subiendo' : ''}',
                        style: AppTexto.etiqueta.copyWith(
                            color: cs.onSurfaceVariant)),
                    trailing: Text('${fmtMonto(c.monto)} CUP',
                        style: AppTexto.cuerpo.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColores.naranja)),
                  );
                }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agregar pago')),
      body: Column(
        children: [
          const SyncBanner(compact: true, alcance: 'pagos'),
          _resumenDia(),
          _ultimosCobros(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CampoTexto(
                    controller: _q,
                    hint: 'Nombre, carnet o teléfono',
                    icono: Icons.search_rounded,
                    onChanged: (_) => _buscarConDebounce(),
                  ),
                ),
                const SizedBox(width: 8),
                BotonPrimario(
                    texto: 'Buscar',
                    onPressed: _buscar,
                    expandido: false),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Solo vencidos'),
                  selected: _soloVencidos,
                  onSelected: (v) {
                    setState(() => _soloVencidos = v);
                    _buscar();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _res.isEmpty
                ? EstadoVacio(
                    icono: Icons.search_off_rounded,
                    titulo: _busco ? 'Sin resultados' : 'Busca un cliente',
                    subtitulo: _busco
                        ? 'Prueba con otro nombre, carnet o teléfono'
                        : null,
                  )
                : ListView.builder(
                    itemCount: _res.length,
                    itemBuilder: (ctx, i) {
                      final c = _res[i];
                      return FilaCliente(
                        cliente: c,
                        onTap: () => Navigator.of(context).push(
                            RutaIron(
                                builder: (_) => FichaScreen(
                                    clienteId:
                                        (c['id'] as int?) ??
                                            0))),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            BotonPrimario(
                              texto: 'Pagar',
                              icono: Icons.payments_rounded,
                              onPressed: () => _pagar(c),
                              expandido: false,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
