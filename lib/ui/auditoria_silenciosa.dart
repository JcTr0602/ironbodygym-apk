import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// v1.3.7 (Fase A, 6.3): auditoría silenciosa de anomalías (solo dueño).
///
/// Revisión automática SIN notificaciones: lista patrones sospechosos
/// para que el dueño los revise en bloque. No acusa a nadie.
/// Umbrales conservadores para evitar falsos positivos.
class AuditoriaSilenciosaScreen extends StatefulWidget {
  const AuditoriaSilenciosaScreen({super.key});

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
  const _Caso(this.tipo, this.titulo, this.detalle, this.fecha);
}

class _AuditoriaSilenciosaScreenState
    extends State<AuditoriaSilenciosaScreen> {
  bool _cargando = true;
  final List<_Caso> _casos = [];

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
    try {
      await _detectarTurnosCortos();
      await _detectarEdiciones();
      await _detectarSinSync();
    } catch (_) {}
    if (mounted) setState(() => _cargando = false);
  }

  /// (a) Turnos cerrados que duraron menos de 30 minutos.
  Future<void> _detectarTurnosCortos() async {
    final db = await LocalDb.instance.db;
    List<Map<String, dynamic>> turnos = [];
    try {
      turnos = await db.query('turnos',
          where: "hora_cierre IS NOT NULL AND estado LIKE 'cerrado%'",
          orderBy: 'fecha_turno DESC',
          limit: 100);
    } catch (_) {
      return;
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
      if (min >= 0 && min < 30) {
        _casos.add(_Caso(
          'turno_corto',
          'Turno de $min min (${t['turno'] ?? '?'})',
          'Entrenador ID ${t['telegram_id'] ?? '?'} · '
              'apertura ${_horaCorta(ap)} · cierre ${_horaCorta(ci)}',
          '${t['fecha_turno'] ?? ''}',
        ));
      }
    }
  }

  String _horaCorta(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  /// (b) Ediciones de pagos en los últimos 30 días (para revisar si
  /// tuvieron movimiento de caja asociado).
  Future<void> _detectarEdiciones() async {
    final db = await LocalDb.instance.db;
    List<Map<String, dynamic>> ops = [];
    try {
      final desde = ahoraHabana()
          .subtract(const Duration(days: 30))
          .toIso8601String();
      ops = await db.query('ops_queue',
          columns: ['tipo', 'creada_ts', 'telegram_id', 'estado'],
          where: "tipo IN ('editar_pago', 'editar_pago_diario') "
              "AND creada_ts >= ?",
          whereArgs: [desde],
          orderBy: 'creada_ts DESC',
          limit: 50);
    } catch (_) {
      return;
    }
    for (final op in ops) {
      final ts = '${op['creada_ts'] ?? ''}';
      _casos.add(_Caso(
        'edicion',
        'Edición: ${op['tipo']}',
        'Por ID ${op['telegram_id'] ?? '?'} · estado ${op['estado']}',
        ts.length >= 10 ? ts.substring(0, 10) : '',
      ));
    }
  }

  /// (c) Este dispositivo lleva más de 3 días sin sincronizar.
  Future<void> _detectarSinSync() async {
    try {
      final ultimo =
          await LocalDb.instance.getMeta('last_pull_ok');
      if (ultimo == null || ultimo.isEmpty) return;
      final dt = DateTime.tryParse(ultimo);
      if (dt == null) return;
      final dias = ahoraHabana().difference(dt).inDays;
      if (dias > 3) {
        _casos.add(_Caso(
          'sin_sync',
          'Sin sincronizar hace $dias días',
          'Último pull exitoso: ${fmtFecha(ultimo.substring(0, 10))}',
          ultimo.substring(0, 10),
        ));
      }
    } catch (_) {}
  }

  IconData _iconoCaso(String tipo) {
    switch (tipo) {
      case 'turno_corto':
        return Icons.timer_off_outlined;
      case 'edicion':
        return Icons.edit_note_outlined;
      case 'sin_sync':
        return Icons.sync_problem_outlined;
      default:
        return Icons.flag_outlined;
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
        appBar: AppBar(title: const Text('Auditoría')),
        body: const Center(
          child: Text('Solo el dueño puede ver la auditoría.'),
        ),
      );
    }
    final grupos = <String, List<_Caso>>{};
    for (final c in _casos) {
      grupos.putIfAbsent(c.tipo, () => []).add(c);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditoría silenciosa'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _casos.isEmpty
              ? const EstadoVacio(
                  icono: Icons.verified_outlined,
                  titulo: 'Sin anomalías',
                  subtitulo:
                      'No se detectaron patrones sospechosos.',
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
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
                              bottom: 8),
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
                              ],
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }
}
