import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import '../turno_service.dart';
import 'app_bar.dart';
import 'auditoria.dart' show descripcionOp;
import 'auditoria_persona.dart';
import 'cola.dart' show etiquetaEstadoOp;
import 'componentes.dart';
import 'ficha.dart';
import 'salud_sync_screen.dart';
import 'skeleton.dart';
import 'diseno.dart';

/// v1.3.7 (Fase A, 6.3): auditoría silenciosa de anomalías (solo dueño).
///
/// Revisión automática SIN notificaciones: lista patrones sospechosos
/// para que el dueño los revise en bloque. No acusa a nadie.
/// Umbrales conservadores para evitar falsos positivos.
class AuditoriaSilenciosaScreen extends StatefulWidget {
  // 1.25 T112: embebida = pestaña del Centro de control.
  final bool embebida;
  const AuditoriaSilenciosaScreen({super.key, this.embebida = false});

  @override
  State<AuditoriaSilenciosaScreen> createState() =>
      _AuditoriaSilenciosaScreenState();
}

/// Un caso detectado por la auditoría.
class _Caso {
  final String tipo; // turno_corto | edicion | sin_sync
  final String titulo;
  final String detalle;
  final String fecha;

  /// 1.29 (Oleada 6, FB-17): la identidad del HECHO fuente
  /// del que nace el caso (el id del turno, el op_uuid de
  /// la edición, el valor de last_pull_ok). La huella de
  /// «ya revisado» se construye con tipo + idFuente: el
  /// caso marcado no reaparece, pero un hecho NUEVO del
  /// mismo tipo y persona (otro id fuente) sí vuelve a
  /// salir — por eso la huella no es tipo+persona.
  final String idFuente;

  /// Destino al tocar el caso: la ficha de este cliente
  /// si el hecho lo trae; si no, la auditoría de la
  /// persona de este telegram_id.
  final int? clienteId;
  final int? telegramId;

  const _Caso(this.tipo, this.titulo, this.detalle, this.fecha,
      {required this.idFuente, this.clienteId, this.telegramId});

  String get huella => huellaCasoAnomalia(tipo, idFuente);
}

/// 1.29 (Oleada 6, FB-17): huella de un caso para la marca
/// «ya revisado» (persistida en el almacén local de
/// metadatos, sin migración). Incluye el id del hecho
/// fuente, no solo tipo+persona.
String huellaCasoAnomalia(String tipo, String idFuente) =>
    '$tipo|$idFuente';

/// 1.29 (Oleada 6, D-B3-04): cómo terminó un detector.
/// Antes los detectores tragaban sus errores en silencio
/// y la pantalla decía «Sin anomalías» también cuando NO
/// había podido revisar: «limpio» y «no pude revisar»
/// eran indistinguibles.
enum EstadoDetector { ok, fallo, parcial }

/// Nombre legible de cada detector para el aviso de
/// «No se pudo revisar X».
const nombresDetectores = <String, String>{
  'turnos': 'los turnos cortos',
  'ediciones': 'las ediciones de pagos',
  'sync': 'la sincronización',
};

/// 1.32 (H-B7-1): ¿existe un `ajuste` de caja del mismo autor
/// dentro de la ventana ±[horas] alrededor de [instante]?
///
/// La comparación es por INSTANTE —epoch entero contra
/// `CAST(strftime('%s', creada_ts) AS INTEGER)`, el patrón A-05
/// de la casa—, nunca por texto: la columna `creada_ts` guarda
/// textos con offset habanero y el borde construido con
/// `toIso8601String()` salía con «Z»; el orden lexicográfico
/// entre designadores distintos desplazaba AMBOS bordes de la
/// ventana el offset completo (4-5 h): un ajuste legítimo a −23 h
/// parecía fuera (falsa anomalía) y uno a +25 h parecía dentro
/// (anomalía invisible). SQLite interpreta el offset de cada
/// texto al calcular su epoch, así que la comparación por
/// instante es inmune al formato guardado y al cambio de hora.
@visibleForTesting
Future<bool> ajusteRespaldaEnVentana(
    Database db, int telegramId, DateTime instante, int horas) async {
  final iniE =
      instante.subtract(Duration(hours: horas)).millisecondsSinceEpoch ~/
          1000;
  final finE =
      instante.add(Duration(hours: horas)).millisecondsSinceEpoch ~/ 1000;
  final ajustes = await db.query('ops_queue',
      columns: ['op_uuid'],
      where: "tipo = 'ajuste' AND telegram_id = ? "
          "AND CAST(strftime('%s', creada_ts) AS INTEGER) >= ? "
          "AND CAST(strftime('%s', creada_ts) AS INTEGER) <= ?",
      whereArgs: [telegramId, iniE, finE],
      limit: 1);
  return ajustes.isNotEmpty;
}

// v1.3.7 (Fase B, nota de Argón): umbrales centralizados como constantes
// nombradas (antes literales dispersos). Conservadores para evitar
// falsos positivos.
class _Umbrales {
  /// Turno sospechoso si duró menos de este tiempo.
  static const turnoCortoMin = 30;

  /// Ventana de búsqueda de ediciones de pago.
  static const edicionesDias = 30;

  /// Días sin sync para alertar.
  static const sinSyncDias = 3;

  /// Ventana para buscar el ajuste de caja que respalda una edición.
  static const ajusteVentanaHoras = 24;
}

class _AuditoriaSilenciosaScreenState
    extends State<AuditoriaSilenciosaScreen> {
  bool _cargando = true;
  final List<_Caso> _casos = [];
  // 1.29 (Oleada 6, D-B3-04): el resultado de cada
  // detector en la última carga — la pantalla distingue
  // «limpio» de «no pude revisar».
  Map<String, EstadoDetector> _estados = {};
  // 1.29 (Oleada 6, FB-17): huellas marcadas «ya
  // revisado» (meta local, sin migración).
  Set<String> _revisadas = {};
  // 1.25 T123 (F6-05): telegram_id → nombre, desde el meta
  // usuarios_apk (la misma fuente que usa Nómina).
  Map<int, String> _nombresTelegram = {};

  String _nombreEntrenador(dynamic tid) {
    final id = tid is num ? tid.toInt() : int.tryParse('${tid ?? ''}');
    final n = id != null ? _nombresTelegram[id] : null;
    return (n != null && n.isNotEmpty) ? n : 'Un entrenador';
  }

  Future<void> _cargarNombres() async {
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw == null || raw.isEmpty) return;
      final mapa = <int, String>{};
      for (final u in jsonDecode(raw) as List) {
        final m = Map<String, dynamic>.from(u as Map);
        final tid = (m['telegram_id'] as num?)?.toInt() ??
            int.tryParse('${m['telegram_id'] ?? ''}');
        final nombre = '${m['nombre'] ?? ''}'.trim();
        if (tid != null && nombre.isNotEmpty) mapa[tid] = nombre;
      }
      _nombresTelegram = mapa;
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _casos.clear();
    });
    // FB-17: las marcas «ya revisado» viven en meta (una
    // sola clave con la lista de huellas).
    try {
      final raw =
          await LocalDb.instance.getMeta('anomalias_revisadas');
      if (raw != null && raw.isNotEmpty) {
        final dec = jsonDecode(raw);
        if (dec is List) {
          _revisadas = {for (final h in dec) '$h'};
        }
      }
    } catch (_) {}
    final estados = <String, EstadoDetector>{};
    try {
      await _cargarNombres();
      estados['turnos'] = await _detectarTurnosCortos();
      estados['ediciones'] = await _detectarEdiciones();
      estados['sync'] = await _detectarSinSync();
    } catch (_) {
      // Un fallo fuera de los detectores no debe pintar
      // «limpio»: lo que no tenga estado cuenta como fallo.
      estados.putIfAbsent('turnos', () => EstadoDetector.fallo);
      estados.putIfAbsent('ediciones', () => EstadoDetector.fallo);
      estados.putIfAbsent('sync', () => EstadoDetector.fallo);
    }
    _estados = estados;
    // FB-17: lo ya revisado no vuelve a salir (la marca es
    // por hecho fuente: un hecho nuevo sí reaparece).
    _casos.removeWhere((c) => _revisadas.contains(c.huella));
    if (mounted) setState(() => _cargando = false);
  }

  /// FB-17: marca un caso como revisado y lo retira de la
  /// lista. La marca persiste en meta (sin migración).
  Future<void> _marcarRevisado(_Caso c) async {
    _revisadas = {..._revisadas, c.huella};
    try {
      await LocalDb.instance.setMeta(
          'anomalias_revisadas', jsonEncode(_revisadas.toList()));
    } catch (_) {}
    if (mounted) {
      setState(() => _casos.removeWhere((x) => x.huella == c.huella));
    }
  }

  /// FB-17: tocar un caso lleva a su contexto: la ficha
  /// del cliente si el hecho lo trae; la auditoría de la
  /// persona si es de un entrenador; la salud del sync si
  /// es el caso de sincronización.
  void _abrirCaso(_Caso c) {
    if (c.clienteId != null) {
      Navigator.of(context).push(
        RutaIron(
            builder: (_) => FichaScreen(clienteId: c.clienteId!)),
      );
    } else if (c.tipo == 'sin_sync') {
      Navigator.of(context).push(
        RutaIron(builder: (_) => const SaludSyncScreen()),
      );
    } else if (c.telegramId != null) {
      Navigator.of(context).push(
        RutaIron(
            builder: (_) => AuditoriaPersonaScreen(
                telegramIdInicial: c.telegramId)),
      );
    }
  }

  /// (a) Turnos cerrados que duraron menos de [_Umbrales.turnoCortoMin].
  /// Tope declarado: 100 turnos (si se alcanza, el estado
  /// es PARCIAL: se revisó hasta el tope, no todo).
  Future<EstadoDetector> _detectarTurnosCortos() async {
    final db = await LocalDb.instance.db;
    List<Map<String, dynamic>> turnos = [];
    try {
      turnos = await db.query('turnos',
          where: "hora_cierre IS NOT NULL AND estado LIKE 'cerrado%'",
          orderBy: 'fecha_turno DESC',
          limit: 100);
    } catch (_) {
      return EstadoDetector.fallo;
    }
    for (final t in turnos) {
      DateTime ap, ci;
      try {
        ap = DateTime.parse('${t['hora_apertura']}');
        ci = DateTime.parse('${t['hora_cierre']}');
      } catch (_) {
        continue;
      }
      final min = ci.difference(ap).inMinutes;
      if (min >= 0 && min < _Umbrales.turnoCortoMin) {
        _casos.add(_Caso(
          'turno_corto',
          'Turno de $min min (${t['turno'] ?? '?'})',
          '${_nombreEntrenador(t['telegram_id'])} · '
              // 1.14 (D12): la misma hora corrida del Home: usar la
              // horaCorta compartida (Habana) en vez del helper
              // local que pintaba en zona del teléfono.
              'apertura ${horaCorta('${t['hora_apertura']}')} · '
              'cierre ${horaCorta('${t['hora_cierre']}')}',
          '${t['fecha_turno'] ?? ''}',
          idFuente: '${t['turno_id'] ?? ''}',
          telegramId: (t['telegram_id'] as num?)?.toInt() ??
              int.tryParse('${t['telegram_id'] ?? ''}'),
        ));
      }
    }
    return turnos.length >= 100
        ? EstadoDetector.parcial
        : EstadoDetector.ok;
  }

  /// (b) Ediciones de pagos en los últimos [_Umbrales.edicionesDias] días.
  /// Nota de Argón: solo se listan las ediciones SIN movimiento de caja
  /// asociado (un `ajuste` del mismo autor en ±24h la respalda como
  /// corrección legítima con asiento contable).
  /// Tope declarado: 50 ediciones (si se alcanza, PARCIAL).
  Future<EstadoDetector> _detectarEdiciones() async {
    final db = await LocalDb.instance.db;
    List<Map<String, dynamic>> ops = [];
    try {
      // 1.32 (H-B7-1, residuo del mismo detector): el corte de
      // días también compara por instante (epoch entero), no
      // por texto: el toIso8601String() salía SIN zona y la
      // columna guarda offset, así que el borde se desplazaba
      // las horas del día de corte.
      final desdeE = ahoraHabana()
              .subtract(Duration(days: _Umbrales.edicionesDias))
              .millisecondsSinceEpoch ~/
          1000;
      ops = await db.query('ops_queue',
          columns: [
            'op_uuid',
            'tipo',
            'creada_ts',
            'telegram_id',
            'estado',
            'payload'
          ],
          where: "tipo IN ('editar_pago', 'editar_pago_diario') "
              "AND CAST(strftime('%s', creada_ts) AS INTEGER) >= ?",
          whereArgs: [desdeE],
          orderBy: 'creada_ts DESC',
          limit: 50);
    } catch (_) {
      return EstadoDetector.fallo;
    }
    for (final op in ops) {
      final ts = '${op['creada_ts'] ?? ''}';
      final tid = op['telegram_id'];
      // ¿Hay un ajuste de caja del mismo autor cerca en el tiempo?
      var respaldada = false;
      if (tid != null && ts.isNotEmpty) {
        try {
          // 1.32 (H-B7-1): comparación por instante (epoch),
          // no por texto ISO de formatos mezclados — ver
          // ajusteRespaldaEnVentana.
          final tidInt = tid is num ? tid.toInt() : null;
          if (tidInt != null) {
            respaldada = await ajusteRespaldaEnVentana(db, tidInt,
                DateTime.parse(ts), _Umbrales.ajusteVentanaHoras);
          }
        } catch (_) {}
      }
      if (respaldada) continue;
      // FB-17: el cliente del pago editado sale del payload
      // (editar_pago trae cliente_id): tocar el caso abre
      // su ficha. Sin cliente_id, el destino es la
      // auditoría del autor.
      int? clienteIdEdicion;
      try {
        final p = jsonDecode('${op['payload'] ?? ''}');
        if (p is Map) {
          clienteIdEdicion =
              int.tryParse('${p['cliente_id'] ?? ''}');
        }
      } catch (_) {}
      _casos.add(_Caso(
        'edicion',
        'Edición sin respaldo: ${descripcionOp('${op['tipo']}')}',
        'Por ${_nombreEntrenador(tid)} · ${etiquetaEstadoOp('${op['estado']}')} · '
            'sin ajuste de caja en ±${_Umbrales.ajusteVentanaHoras}h',
        ts.length >= 10 ? ts.substring(0, 10) : '',
        idFuente: '${op['op_uuid'] ?? ''}',
        clienteId: clienteIdEdicion,
        telegramId:
            (tid as num?)?.toInt() ?? int.tryParse('${tid ?? ''}'),
      ));
    }
    return ops.length >= 50
        ? EstadoDetector.parcial
        : EstadoDetector.ok;
  }

  /// (c) Este dispositivo lleva más de [_Umbrales.sinSyncDias] días
  /// sin sincronizar.
  Future<EstadoDetector> _detectarSinSync() async {
    try {
      final ultimo =
          await LocalDb.instance.getMeta('last_pull_ok');
      if (ultimo == null || ultimo.isEmpty) {
        return EstadoDetector.ok;
      }
      final dt = DateTime.tryParse(ultimo);
      if (dt == null) return EstadoDetector.ok;
      final dias = ahoraHabana().difference(dt).inDays;
      if (dias > _Umbrales.sinSyncDias) {
        _casos.add(_Caso(
          'sin_sync',
          'Sin sincronizar hace $dias días',
          'Último pull exitoso: ${fmtFecha(ultimo.substring(0, 10))}',
          ultimo.substring(0, 10),
          // El hecho fuente es el último pull: si el
          // teléfono vuelve a sincronizar y se vuelve a
          // atrasar, el valor cambia y el caso es NUEVO.
          idFuente: ultimo,
        ));
      }
      return EstadoDetector.ok;
    } catch (_) {
      return EstadoDetector.fallo;
    }
  }

  IconData _iconoCaso(String tipo) {
    switch (tipo) {
      case 'turno_corto':
        return Icons.timer_off_rounded;
      case 'edicion':
        return Icons.edit_note_rounded;
      case 'sin_sync':
        return Icons.sync_problem_rounded;
      default:
        return Icons.flag_rounded;
    }
  }

  String _tituloTipo(String tipo) {
    switch (tipo) {
      case 'turno_corto':
        return 'Turnos cortos';
      case 'edicion':
        return 'Ediciones de pagos';
      case 'sin_sync':
        return 'Sincronización';
      default:
        return 'Otros';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: widget.embebida
            ? null
            : appBarIron(context, 'Auditoría'),
        body: const Center(
          child: Text('Solo el dueño puede ver la auditoría.'),
        ),
      );
    }
    final grupos = <String, List<_Caso>>{};
    for (final c in _casos) {
      grupos.putIfAbsent(c.tipo, () => []).add(c);
    }
    // D-B3-04: «limpio» solo si TODOS los detectores
    // terminaron bien. Un fallo o un parcial se DICE.
    final fallos = <String>[
      for (final e in _estados.entries)
        if (e.value == EstadoDetector.fallo)
          nombresDetectores[e.key] ?? e.key,
    ];
    final parciales = <String>[
      for (final e in _estados.entries)
        if (e.value == EstadoDetector.parcial)
          nombresDetectores[e.key] ?? e.key,
    ];
    final todoOk = fallos.isEmpty && parciales.isEmpty;
    return Scaffold(
      appBar: widget.embebida
          ? null
          : appBarIron(
        context,
        'Auditoría silenciosa',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          // 1.25 T114: esqueleto con la forma de la lista.
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 3))
          : _casos.isEmpty && todoOk
              ? const EstadoVacio(
                  icono: Icons.verified_rounded,
                  titulo: 'Sin anomalías',
                  subtitulo:
                      'No se detectaron patrones sospechosos.',
                )
              : _casos.isEmpty
                  // D-B3-04: sin casos pero con detectores
                  // que no pudieron revisar: NO es «limpio».
                  ? EstadoVacio(
                      icono: Icons.sync_problem_rounded,
                      titulo: 'Revisión incompleta',
                      subtitulo: [
                        if (fallos.isNotEmpty)
                          'No se pudo revisar: '
                              '${fallos.join(', ')}.',
                        if (parciales.isNotEmpty)
                          'Revisión parcial de: '
                              '${parciales.join(', ')} '
                              '(se alcanzó el tope de lectura).',
                      ].join(' '),
                      textoAccion: 'Reintentar',
                      onAccion: _cargar,
                    )
                  : ListView(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                      decoration: BoxDecoration(
                        color: AppColores.textoSecundario(
                                context)
                            .withValues(alpha: 0.1),
                        borderRadius:
                            BorderRadius.circular(AppRadio.md),
                      ),
                      child: Text(
                        'Revisión automática sin notificaciones. '
                        'Estos casos son para revisar, no acusaciones.',
                        style: AppTexto.etiqueta.copyWith(
                          color: AppColores.textoSecundario(
                              context),
                        ),
                      ),
                    ),
                    // D-B3-04: con casos en la lista, un
                    // detector que falló o llegó a su tope
                    // también se dice (la revisión no fue
                    // completa aunque haya casos que enseñar).
                    if (!todoOk) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppEspacio.md,
                            vertical: AppEspacio.sm),
                        decoration: BoxDecoration(
                          color: AppColores.alerta
                              .withValues(alpha: 0.12),
                          borderRadius:
                              BorderRadius.circular(AppRadio.md),
                        ),
                        child: Text(
                          [
                            if (fallos.isNotEmpty)
                              'No se pudo revisar: '
                                  '${fallos.join(', ')}.',
                            if (parciales.isNotEmpty)
                              'Revisión parcial de: '
                                  '${parciales.join(', ')} '
                                  '(tope de lectura alcanzado).',
                          ].join(' '),
                          style: AppTexto.etiqueta.copyWith(
                            color: AppColores.alerta,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    for (final tipo in grupos.keys) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            4, 8, 4, 4),
                        child: Text(
                          '${_tituloTipo(tipo)} '
                          '(${grupos[tipo]!.length})',
                          style: AppTexto.subtitulo.copyWith(
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      for (final c in grupos[tipo]!)
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                          // FB-17: el caso se toca para ir a
                          // su contexto (ficha / auditoría de
                          // la persona / salud del sync) y se
                          // marca «Ya revisado» con el botón:
                          // la marca es por hecho fuente y no
                          // vuelve a salir; un hecho nuevo sí.
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _abrirCaso(c),
                            child: Tarjeta(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  IconoModuloBadge.naranja(
                                      _iconoCaso(c.tipo)),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment
                                              .start,
                                      children: [
                                        Text(c.titulo,
                                            style: AppTexto
                                                .subtitulo
                                                .copyWith(
                                                    fontWeight:
                                                        FontWeight
                                                            .bold)),
                                        const SizedBox(
                                            height: 2),
                                        Text(c.detalle,
                                            style: AppTexto
                                                .etiqueta
                                                .copyWith(
                                              color: AppColores
                                                  .textoSecundario(
                                                      context),
                                            )),
                                        if (c.fecha.isNotEmpty)
                                          Text(c.fecha,
                                              style: AppTexto
                                                  .etiqueta
                                                  .copyWith(
                                                color: AppColores
                                                    .textoSecundario(
                                                        context),
                                              )),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons
                                        .check_circle_outline_rounded),
                                    tooltip: 'Ya revisado',
                                    onPressed: () =>
                                        _marcarRevisado(c),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }
}
