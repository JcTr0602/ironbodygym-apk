/// Sincronización detallada: última vez, qué subió/bajó, errores
/// y cola de operaciones (con opción de cancelar las pendientes).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../errores_sync.dart';
import '../app_log.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_operacion.dart';
import 'componentes.dart';
import 'diseno.dart';


/// v1.3.4 (detalle ampliable Bajados/Subidos): utilidades de UI
/// compartidas entre [ColaScreen] y [DetalleSyncScreen].
/// Detalles legibles del payload según el tipo de operación (v1.0.11).
/// v1.3.4: extraído de `_ColaScreenState._detallesOp` a función top-level
/// para reutilizarlo en [DetalleSyncScreen].
Future<List<String>> detallesDeOp(Map<String, dynamic> op) async {
  final detalles = <String>[];
  Map<String, dynamic> payload = {};
  try {
    final raw = op['payload'];
    if (raw is String && raw.isNotEmpty) {
      payload = Map<String, dynamic>.from(
          jsonDecode(raw) as Map);
    } else if (raw is Map) {
      payload = Map<String, dynamic>.from(raw);
    }
  } catch (_) {}
  if (payload.isEmpty) return detalles;

  // Nombre del cliente si hay cliente_id
  Future<String?> nombreCliente(dynamic id) async {
    if (id == null) return null;
    try {
      final c = await clientePorId(int.tryParse('$id') ?? 0);
      final nombre = c?['nombre'] as String?;
      // v1.3.9: si no se encuentra el nombre, mostrar el ID
      // para identificar el pago pendiente
      if (nombre == null || nombre.isEmpty) {
        return 'ID $id';
      }
      return nombre;
    } catch (_) {
      return 'ID $id';
    }
  }

  final tipo = '${op['tipo']}';
  if (tipo == 'foto') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
  } else if (tipo == 'pago_mensual' || tipo == 'pago_diario') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
    if (payload['monto'] != null) {
      detalles.add('Monto: ${payload['monto']} CUP');
    }
    if (payload['metodo'] != null) {
      final m = payload['metodo'] == 'efectivo'
          ? 'Efectivo'
          : 'Transferencia';
      detalles.add('Método: $m');
    }
    if (payload['fecha'] != null) {
      detalles.add('Fecha: ${payload['fecha']}');
    }
  } else if (tipo == 'inscribir') {
    if (payload['nombre'] != null) {
      detalles.add('Cliente: ${payload['nombre']}');
    }
  } else if (tipo == 'editar_cliente') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
  } else if (tipo == 'cambiar_estado') {
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) detalles.add('Cliente: $n');
    if (payload['estado'] != null) {
      detalles.add('Estado: ${payload['estado']}');
    }
  } else if (tipo == 'gasto') {
    if (payload['concepto'] != null) {
      detalles.add('${payload['concepto']}');
    }
    if (payload['monto'] != null) {
      detalles.add('Monto: ${payload['monto']} CUP');
    }
  } else if (tipo == 'confirmar_entrega') {
    if (payload['monto'] != null) {
      detalles.add('Monto: ${payload['monto']} CUP');
    }
  } else if (tipo == 'venta_suplemento') {
    if (payload['suplemento_nombre'] != null) {
      detalles.add('Suplemento: ${payload['suplemento_nombre']}');
    }
    final cant = (payload['cantidad'] as num?) ?? 1;
    detalles.add('Cantidad: $cant');
    final total = (payload['total'] as num?) ??
        (((payload['precio'] as num?) ?? 0) * cant);
    final moneda = payload['moneda'] ?? 'CUP';
    if (total > 0) detalles.add('Total: ${fmtMonto(total)} $moneda');
    final n = await nombreCliente(payload['cliente_id']);
    if (n != null) {
      detalles.add('Cliente: $n');
    } else if (payload['comprador_nombre'] != null) {
      detalles.add('Comprador: ${payload['comprador_nombre']}');
    }
  } else if (tipo == 'crear_suplemento' || tipo == 'editar_suplemento') {
    if (payload['nombre'] != null) {
      detalles.add('Suplemento: ${payload['nombre']}');
    }
    final p = payload['precio_oficial'] ?? payload['precio'];
    if (p != null) detalles.add('Precio: $p USD');
  } else if (tipo == 'eliminar_suplemento') {
    detalles.add('ID suplemento: ${payload['suplemento_id'] ?? '—'}');
    detalles.add('Acción: Eliminar');
  } else if (tipo == 'incidencia' || tipo == 'incidencia_estado') {
    if (payload['descripcion'] != null) {
      detalles.add('Descripción: ${payload['descripcion']}');
    }
    if (payload['tipo'] != null) {
      detalles.add('Tipo: ${payload['tipo']}');
    }
    if (payload['estado'] != null) {
      detalles.add('Estado: ${payload['estado']}');
    }
    if (payload['nota_resolucion'] != null) {
      detalles.add('Nota: ${payload['nota_resolucion']}');
    }
  } else if (tipo == 'cierre_turno') {
    if (payload['fecha'] != null) {
      detalles.add('Fecha: ${payload['fecha']}');
    }
    if (payload['turno'] != null) {
      detalles.add('Turno: ${payload['turno']}');
    }
    final tc = payload['total_cobrado'] ?? payload['total'];
    if (tc != null) detalles.add('Total cobrado: ${fmtMonto(tc)} CUP');
  } else if (tipo == 'foto_suplemento') {
    if (payload['suplemento_id'] != null) {
      detalles.add('Suplemento ID: ${payload['suplemento_id']}');
    }
  }
  return detalles;
}

/// Chip de estado para operaciones (v1.0.9.1).
/// v1.3.4: extraído de `_ColaScreenState._estadoChip` a función top-level
/// para reutilizarlo en [DetalleSyncScreen].
Widget chipEstadoOp(String estado) {
  Color color;
  IconData icono;
  String texto;
  if (estado == 'aplicada') {
    color = AppColores.exito;
    icono = Icons.check_circle;
    texto = 'Confirmada';
  } else if (estado == 'rechazada') {
    color = AppColores.error;
    icono = Icons.block;
    texto = 'Rechazada';
  } else if (estado == 'enviada') {
    // v1.2.9+46: ámbar + etiqueta legible.
    color = AppColores.alerta;
    icono = Icons.sync_problem;
    texto = 'Confirmación pendiente';
  } else if (estado == 'pendiente') {
    color = AppColores.naranja;
    icono = Icons.schedule;
    texto = 'Pendiente';
  } else if (estado == 'error') {
    color = AppColores.error;
    icono = Icons.warning;
    texto = 'Falló';
  } else if (estado == 'necesita_revision') {
    // v1.3.5 (auditoría 2026-10-16): etiqueta legible en vez del código.
    color = AppColores.alerta;
    icono = Icons.rule;
    texto = 'Requiere revisión';
  } else {
    color = AppColores.naranja;
    icono = Icons.schedule;
    texto = estado;
  }
  return ChipEstado(texto: texto, color: color, icono: icono);
}

class ColaScreen extends StatefulWidget {
  const ColaScreen({super.key});
  @override
  State<ColaScreen> createState() => _ColaScreenState();
}

class _ColaScreenState extends State<ColaScreen> {
  List<Map<String, dynamic>> _ops = [];
  // v1.2.5 (D15): ops bloqueadas que necesitan revisión manual.
  List<Map<String, dynamic>> _bloqueadas = [];
  SyncDetalle _det = const SyncDetalle();
  bool _sincronizando = false;
  // v1.2.9+46: contadores de la cola de fotos.
  int _fotosPendientes = 0;
  int _fotosSubiendo = 0;
  int _fotosError = 0;
  // v1.2.9+46: detalle de fotos pendientes/error para gestión.
  List<Map<String, dynamic>> _fotosDetalle = [];
  bool _fotosExpandido = false;
  StreamSubscription<SyncStatus>? _syncSub;

  @override
  void initState() {
    super.initState();
    _cargar();
    // v1.2.9+46 (Gemini): refresco reactivo al terminar un push/pull.
    _syncSub = SyncEngine.instance.statusStream.listen((s) {
      if (s.phase == SyncPhase.idle) _cargar();
    });
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }


  /// v1.3.1: permite descartar una foto pendiente (ej: sin cliente asociado).
  Future<void> _cancelarFoto(int id) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Descartar foto',
      mensaje: '¿Descartar esta foto pendiente? No se subirá al sistema.',
      aceptar: 'Sí, descartar',
      peligro: true,
      icono: Icons.delete_outline,
    );
    if (ok != true) return;
    try {
      final db = await LocalDb.instance.db;
      await db.delete(
        'fotos_cola',
        where: 'id = ?',
        whereArgs: [id],
      );
      AppLog.info('fotos', 'descartada_manual', d: 'id=$id');
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Foto descartada')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _cargar() async {
    final ops = await LocalDb.instance.recentOps();
    final bloqueadas = await LocalDb.instance.opsNecesitanRevision();
    final det = await SyncEngine.instance.detalle();
    // v1.2.9+46: contadores y detalle de fotos.
    int fPend = 0, fSub = 0, fErr = 0;
    List<Map<String, dynamic>> fDet = [];
    try {
      final db = await LocalDb.instance.db;
      fPend = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM fotos_cola WHERE estado='pendiente'")) ??
          0;
      fSub = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM fotos_cola WHERE estado='subiendo'")) ??
          0;
      fErr = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM fotos_cola WHERE estado='error'")) ??
          0;
      // v1.2.9+46: detalle para gestión (pendientes y con error).
      fDet = await db.query(
        'fotos_cola',
        columns: [
          'id',
          'tipo',
          'cliente_id',
          'suplemento_id',
          'ruta_local',
          'estado',
          'intentos',
          'ultimo_error',
          'creado_en',
          'proximo_intento_en'
        ],
        where: "estado IN ('pendiente', 'subiendo', 'error')",
        orderBy: 'creado_en DESC',
        limit: 50,
      );
    } catch (_) {}
    if (mounted) {
      setState(() {
        _ops = ops;
        _bloqueadas = bloqueadas;
        _det = det;
        _fotosPendientes = fPend;
        _fotosSubiendo = fSub;
        _fotosError = fErr;
        _fotosDetalle = fDet;
      });
    }
  }

  /// v1.2.9+46: reintenta una foto específica (resetea backoff).
  Future<void> _reintentarFoto(int id) async {
    try {
      final db = await LocalDb.instance.db;
      await db.update(
        'fotos_cola',
        {
          'estado': 'pendiente',
          'intentos': 0,
          'ultimo_error': null,
          'proximo_intento_en': null,
          'worker_id': null,
          'lease_hasta': null,
          // v1.3.10: el reintento manual salta el filtro QoS de 'original'.
          'forzar_qos': 1,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      AppLog.info('fotos', 'reintento_manual', d: 'id=$id');
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Foto marcada para reintento')));
      }
      // Disparar sincronización para procesarla de inmediato.
      unawaited(SyncEngine.instance.push());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo reintentar: $e')));
      }
    }
  }

  /// v1.2.9+46: reintenta todas las fotos pendientes/con error.
  Future<void> _reintentarTodasFotos() async {
    try {
      final db = await LocalDb.instance.db;
      await db.update(
        'fotos_cola',
        {
          'estado': 'pendiente',
          'intentos': 0,
          'ultimo_error': null,
          'proximo_intento_en': null,
          'worker_id': null,
          'lease_hasta': null,
        },
        where: "estado IN ('pendiente', 'error')",
      );
      AppLog.info('fotos', 'reintento_manual_todas');
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Todas las fotos marcadas para reintento')));
      }
      unawaited(SyncEngine.instance.push());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo reintentar: $e')));
      }
    }
  }

  Future<void> _sincronizar() async {
    setState(() => _sincronizando = true);
    // v1.2.5 (D14): "Sincronizar ahora" cancela el backoff de reintentos.
    await SyncEngine.instance.run(forzar: true);
    await _cargar();
    if (mounted) setState(() => _sincronizando = false);
    // Resumen post-sync (solo en sincronización manual desde aquí)
    if (mounted) _mostrarResumen();
  }

  /// v1.2.5 (D15): reintento manual de una bloqueada. La devuelve a
  /// 'pendiente' (limpia backoff); si vuelve a fallar, se reclasifica.
  Future<void> _reintentarBloqueada(String opUuid) async {
    await LocalDb.instance
        .markOp(opUuid, 'pendiente', error: null);
    // Limpia el backoff y el código para que salga en el próximo ciclo.
    final d = await LocalDb.instance.db;
    await d.rawUpdate(
        'UPDATE ops_queue SET proximo_reintento=NULL, codigo_error=NULL, '
        'intentos=0 WHERE op_uuid=?',
        [opUuid]);
    await _cargar();
    // v1.3.1 (E6): sincronizar al instante.
    unawaited(SyncEngine.instance.push());
    // v1.2.6 (Gemini): confirmación háptica en reintento manual.
    await vibrarConfirmacion();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Reintentando sincronización...')));
    }
  }

  /// Muestra un diálogo con el resumen de la sincronización recién hecha.
  Future<void> _mostrarResumen() async {
    final det = await SyncEngine.instance.detalle();
    if (!mounted) return;
    final subidos = det.subidos;
    final bajados = det.bajados;
    final error = det.error;
    await showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Sincronización completada',
        iconoTitulo: Icons.sync,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _resumenFila(context, Icons.upload, 'Subidos', '$subidos'),
            const SizedBox(height: 8),
            _resumenFila(context, Icons.download, 'Bajados', '$bajados'),
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning,
                      size: 16,
                      color: AppColores.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      error,
                      style: const TextStyle(
                          color: AppColores.error,
                          fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
            if (subidos == 0 && bajados == 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'No hubo cambios nuevos.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(
                          context)),
                ),
              ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _resumenFila(
      BuildContext ctx, IconData icono, String etiqueta, String valor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icono,
                size: 20,
                color:
                    Theme.of(ctx).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(etiqueta,
                style: const TextStyle(fontSize: 16)),
          ],
        ),
        Text(
          valor,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColores.naranja,
          ),
        ),
      ],
    );
  }

  Future<void> _cancelar(String uuid, String tipo) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cancelar operación',
      mensaje:
          '¿Cancelar esta operación (${_tipo(tipo)})? No se subirá al sistema.',
      aceptar: 'Sí, cancelar',
      peligro: true,
      icono: Icons.cancel_outlined,
    );
    if (ok != true) return;
    final borrada = await LocalDb.instance.cancelOp(uuid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(borrada
            ? 'Operación cancelada'
            : 'Ya no se puede cancelar (fue aplicada)')));
    _cargar();
  }

  /// Icono y color por estado de operación (v1.1: sin emojis).
  IconData _iconoEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return Icons.check_circle;
      case 'enviada':
        // v1.2.9+46: ámbar = confirmación pendiente.
        return Icons.sync_problem;
      case 'rechazada':
        return Icons.block;
      case 'error':
        return Icons.warning;
      default:
        return Icons.schedule;
    }
  }

  Color _colorEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return AppColores.exito;
      case 'enviada':
        // v1.2.9+46: ámbar = confirmación pendiente.
        return AppColores.alerta;
      case 'rechazada':
      case 'error':
        return AppColores.error;
      default:
        return AppColores.naranja;
    }
  }

  /// v1.2.9+46: etiqueta legible del estado (no el identificador técnico).
  String _etiquetaEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return 'Confirmada';
      case 'enviada':
        return 'Confirmación pendiente';
      case 'pendiente':
        return 'Pendiente';
      case 'rechazada':
        return 'Rechazada';
      case 'error':
        return 'Falló';
      default:
        return estado;
    }
  }

  /// v1.2.9+46 (Gemini): delega al mapa centralizado.
  String _tipo(String t) => describirTipoOp(t);

  String _hora(DateTime? d) {
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// v1.2.9+46: tarjeta expandible con gestión completa de fotos.
  /// Muestra cada foto pendiente: miniatura, entidad, cuándo se solicitó,
  /// intentos, error exacto, y botones para reintentar una o todas.
  Widget _tarjetaFotos(BuildContext context) {
    final total = _fotosPendientes + _fotosSubiendo + _fotosError;
    final hayError = _fotosError > 0;
    final color = hayError
        ? AppColores.error
        : (total > 0 ? AppColores.alerta : AppColores.exito);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: total > 0
                ? () => setState(
                    () => _fotosExpandido = !_fotosExpandido)
                : null,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(Icons.photo_library,
                    size: 24, color: AppColores.naranja),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Fotos', style: AppTexto.subtitulo),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    total == 0
                        ? 'Al día'
                        : '$_fotosPendientes pendientes · '
                            '$_fotosSubiendo subiendo',
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                if (total > 0)
                  Icon(
                    _fotosExpandido
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: AppColores.textoSecundario(context),
                  ),
              ],
            ),
          ),
          if (_fotosExpandido && _fotosDetalle.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            for (final f in _fotosDetalle) _filaFoto(context, f),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reintentar todas'),
                onPressed: _reintentarTodasFotos,
              ),
            ),
          ],
          if (hayError && !_fotosExpandido) ...[
            const SizedBox(height: 8),
            Text(
              '$_fotosError ${_fotosError == 1 ? 'foto falló' : 'fotos fallaron'} — toca para ver detalle',
              style: const TextStyle(
                  color: AppColores.error, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  /// Fila de una foto pendiente: miniatura, entidad, fecha, intentos, error.
  Widget _filaFoto(BuildContext context, Map<String, dynamic> f) {
    final id = f['id'] as int;
    final tipo = '${f['tipo']}';
    final estado = '${f['estado']}';
    final intentos = f['intentos'] as int? ?? 0;
    final error = f['ultimo_error'] as String?;
    final ruta = f['ruta_local'] as String?;
    final creadoEn = DateTime.tryParse('${f['creado_en']}');
    // Entidad: cliente o suplemento.
    String entidad = '—';
    if (f['cliente_id'] != null) {
      entidad = 'Cliente ${f['cliente_id']}';
    } else if (f['suplemento_id'] != null) {
      entidad = 'Suplemento ${f['suplemento_id']}';
    }
    final colorEstado = estado == 'error'
        ? AppColores.error
        : estado == 'subiendo'
            ? AppColores.info
            : AppColores.alerta;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Miniatura.
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ruta != null
                ? Image.file(
                    File(ruta),
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 48,
                      height: 48,
                      color: AppColores.fondo(context),
                      child: const Icon(Icons.broken_image, size: 24),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    color: AppColores.fondo(context),
                    child: const Icon(Icons.image, size: 24),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$entidad · $tipo',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorEstado.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        estado == 'error'
                            ? 'Falló'
                            : estado == 'subiendo'
                                ? 'Subiendo'
                                : 'Pendiente',
                        style: TextStyle(
                            color: colorEstado,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Solicitada: ${_hora(creadoEn)} · $intentos ${intentos == 1 ? 'intento' : 'intentos'}',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColores.textoSecundario(context)),
                ),
                if (error != null && error.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Error: $error',
                    style: const TextStyle(
                        fontSize: 11, color: AppColores.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Reintentar',
            onPressed: () => _reintentarFoto(id),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Descartar',
            onPressed: () => _cancelarFoto(id),
          ),
        ],
      ),
    );
  }

  /// Muestra el detalle de las fotos con error permanente.
  Future<void> _verFallosFotos(BuildContext context) async {
    List<Map<String, dynamic>> fallos = [];
    try {
      final db = await LocalDb.instance.db;
      fallos = await db.query(
        'fotos_cola',
        columns: ['id', 'tipo', 'intentos', 'ultimo_error', 'actualizado_en'],
        where: "estado = 'error'",
        orderBy: 'actualizado_en DESC',
        limit: 20,
      );
    } catch (_) {}
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Fotos con error',
        iconoTitulo: Icons.error_outline,
        contenido: fallos.isEmpty
            ? const Text('No hay fotos con error.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final f in fallos)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.photo,
                          color: AppColores.error),
                      title: Text(
                          'Foto ${f['id']} (${f['tipo']}) — '
                          '${f['intentos']} intentos'),
                      subtitle: Text(
                        '${f['ultimo_error'] ?? 'sin detalle'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  /// Muestra el detalle completo de una operación al tocarla.
  Future<void> _reenviar(Map<String, dynamic> op) async {
    final uuid = op['op_uuid'] as String;
    // v1.3.1 (E6): limpiar campos de error y disparar sync inmediatamente.
    final db = await LocalDb.instance.db;
    await db.update(
      'ops_queue',
      {
        'estado': 'pendiente',
        'error': null,
        'intentos': 0,
        'proximo_reintento': null,
        'codigo_error': null,
      },
      where: 'op_uuid=?',
      whereArgs: [uuid],
    );
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reenviando operación...')),
      );
      _cargar();
    }
  }

  void _verDetalle(Map<String, dynamic> op) async {
    final tipo = _tipo('${op['tipo']}');
    final estado = '${op['estado']}';
    final fecha =
        fechaCorta(op['creada_ts'], 16).replaceAll('T', ' ');
    final error = '${op['error'] ?? ''}';
    // Traduce errores técnicos a lenguaje claro
    String errorClaro = error;
    if (error.contains('cliente no existe')) {
      errorClaro =
          'El cliente ya no existe en el servidor (fue eliminado). No es necesario reintentar.';
    } else if (error.contains('HTTP 400')) {
      errorClaro =
          'El servidor rechazó la operación por datos inválidos. Revisa los datos e intenta de nuevo.';
    } else if (error.contains('HTTP 409')) {
      errorClaro = 'La operación ya fue registrada (duplicada). No es necesario reintentar.';
    }
    // Detalles del payload según tipo (v1.0.11)
    final detalles = await _detallesOp(op);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: tipo,
        iconoTitulo: _iconoEstado(estado),
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_today,
                    size: 14,
                    color:
                        AppColores.textoSecundario(context)),
                const SizedBox(width: 6),
                Text(fecha,
                    style:
                        const TextStyle(fontSize: 13)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Estado: $estado'),
            for (final d in detalles) ...[
              const SizedBox(height: 4),
              Text(d),
            ],
            if (errorClaro.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning,
                      size: 16,
                      color: AppColores.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(errorClaro,
                        style: const TextStyle(
                            color:
                                AppColores.error)),
                  ),
                ],
              ),
            ],
          ],
        ),
        acciones: [
          if (estado == 'rechazada') ...[
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _reenviar(op);
              },
              child: const Text('Reenviar',
                  style:
                      TextStyle(color: AppColores.naranja)),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// Detalles legibles del payload segun el tipo de operacion (v1.0.11).
  /// v1.3.4: delega en la funcion top-level [detallesDeOp].
  Future<List<String>> _detallesOp(Map<String, dynamic> op) =>
      detallesDeOp(op);

  @override
  Widget build(BuildContext context) {
    // v1.3.1 (E2): conteos reales incluyendo bloqueadas y fotos.
    // _ops tiene limit 30, así que sumar las bloqueadas cargadas por separado.
    final pendientes =
        _ops.where((o) => o['estado'] == 'pendiente').length;
    final conError =
        _ops.where((o) => o['estado'] == 'error').length;
    // v1.2.9+46 (Gemini): 'enviada' = confirmación pendiente (ámbar).
    final enLimbo =
        _ops.where((o) => o['estado'] == 'enviada').length;
    // v1.3.1 (E2): bloqueadas (necesita_revision/rechazada) van a rojo.
    final bloqueadas = _bloqueadas.length;
    final rechazadas =
        _ops.where((o) => o['estado'] == 'rechazada').length;
    final totalError = conError + bloqueadas + rechazadas + _fotosError;
    final totalPendiente = pendientes + _fotosPendientes + _fotosSubiendo;
    final errorReciente = _det.error;
    // v1.0.14: tres estados claros en vez de binario ok/error
    // v1.1: icono Material en vez de emoji
    // v1.2.9+46: cinco estados (error, limbo, error reciente, pendiente, ok)
    final String estadoSync;
    final List<Color> colores;
    final IconData iconoEstado;
    final String titulo;
    final String subtitulo;
    if (totalError > 0) {
      estadoSync = 'error';
      colores = [AppColores.error, AppColores.errorOscuro];
      iconoEstado = Icons.warning;
      titulo = 'Atención requerida';
      subtitulo = totalError == 1
          ? '1 elemento falló y necesita tu revisión'
          : '$totalError elementos fallaron y necesitan tu revisión';
    } else if (enLimbo > 0) {
      estadoSync = 'limbo';
      colores = [AppColores.alerta, AppColores.alertaOscuro];
      iconoEstado = Icons.sync_problem;
      titulo = 'Confirmación pendiente';
      subtitulo = enLimbo == 1
          ? '1 operación se envió pero no se confirmó'
          : '$enLimbo operaciones se enviaron pero no se confirmaron';
    } else if (errorReciente != null && errorReciente.isNotEmpty) {
      estadoSync = 'error';
      colores = [AppColores.error, AppColores.errorOscuro];
      iconoEstado = Icons.warning;
      titulo = 'Falló la última sincronización';
      // v1.2.9+46: mensaje en lenguaje natural, no genérico.
      subtitulo = describirError(errorReciente);
    } else if (totalPendiente > 0) {
      estadoSync = 'pendiente';
      colores = [AppColores.alerta, AppColores.alertaOscuro];
      iconoEstado = Icons.schedule;
      titulo = 'Pendiente de sincronizar';
      subtitulo = totalPendiente == 1
          ? '1 elemento esperando conexión'
          : '$totalPendiente elementos esperando conexión';
    } else {
      estadoSync = 'ok';
      colores = [AppColores.exito, AppColores.exitoOscuro];
      iconoEstado = Icons.check_circle;
      titulo = 'Sincronizado';
      subtitulo = 'Todo al día';
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Sincronización')),
      body: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Cabecera de estado visual (v1.0.14: tres estados)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colores,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: colores[0].withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Icon(
                    iconoEstado,
                    size: 48,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    titulo,
                    style: AppTexto.displayPequeno.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitulo,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  // v1.0.14: guía contextual según el estado
                  if (estadoSync == 'pendiente') ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Se subirán automáticamente cuando haya conexión. '
                      'Puedes seguir trabajando sin internet.',
                      style: TextStyle(
                          color: Colors.white70, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (estadoSync == 'error') ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Revisa las operaciones marcadas abajo. '
                      'Puedes reintentarlas o cancelarlas.',
                      style: TextStyle(
                          color: Colors.white70, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Tarjetas de estadísticas
            Row(
              children: [
                Expanded(
                  child: _tarjetaStat(
                    Icons.download,
                    'Bajados',
                    '${_det.bajados}',
                    // v1.3.1 (E5): acumulado histórico + última sync.
                    'Total: ${_det.totalBajados} · ${_hora(_det.ultimaPull)}',
                    AppColores.info,
                    onTap: _abrirDetalleBajados,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _tarjetaStat(
                    Icons.upload,
                    'Subidos',
                    '${_det.subidos}',
                    // v1.3.1 (E5): acumulado histórico + última sync.
                    'Total: ${_det.totalSubidos} · ${_hora(_det.ultimaPush)}',
                    AppColores.naranja,
                    onTap: _abrirDetalleSubidos,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Botón sincronizar
            BotonPrimario(
              texto:
                  _sincronizando ? 'Sincronizando…' : 'Sincronizar ahora',
              icono: Icons.sync,
              onPressed: _sincronizando ? null : _sincronizar,
            ),
            if (_det.error != null && _det.error!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColores.error
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadio.md),
                  border: Border.all(
                      color: AppColores.error
                          .withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning,
                        size: 20,
                        color: AppColores.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _det.error!,
                        style: const TextStyle(
                            color: AppColores.error,
                            fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            // v1.2.5 (D15): bloqueadas que necesitan revisión manual.
            if (_bloqueadas.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColores.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: AppColores.error.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColores.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${_bloqueadas.length} necesitan revisión',
                            style: AppTexto.titulo.copyWith(
                                color: AppColores.error),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Estas operaciones no se pudieron enviar. '
                      'No se reintentarán solas.',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    for (final b in _bloqueadas)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.block, size: 20),
                        title: Text(
                            '${b['tipo'] ?? ''}',
                            style: AppTexto.cuerpo),
                        subtitle: Text(
                            '${b['codigo_error'] ?? 'error'} · '
                            '${(b['error'] as String? ?? '').split('\n').first}',
                            style: AppTexto.secundario,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        trailing: TextButton(
                          onPressed: () => _reintentarBloqueada(
                              b['op_uuid'] as String),
                          child: const Text('Reintentar'),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            // v1.2.9+46 (Gemini): visibilidad de la cola de fotos.
            _tarjetaFotos(context),
            const SizedBox(height: 16),
            const Text(
              'Operaciones recientes',
              style: AppTexto.titulo,
            ),
            const SizedBox(height: 8),
            if (_ops.isEmpty)
              const EstadoVacio(
                icono: Icons.inbox_outlined,
                titulo: 'Sin operaciones todavía',
                subtitulo:
                    'Las operaciones pendientes aparecerán aquí.',
              )
            else
              ..._ops.map((op) {
                final estado = '${op['estado']}';
                final esPendiente = estado == 'pendiente';
                final esError = estado == 'error';
                // v1.3.1 (E6): rechazada y necesita_revision también
                // son reintentables/cancelables.
                final esBloqueada =
                    estado == 'rechazada' || estado == 'necesita_revision';
                final cancelable = esPendiente || esError || esBloqueada;
                // v1.0.14: tiempo relativo para saber hace cuánto espera
                final creada = '${op['creada_ts'] ?? ''}';
                final hace = tiempoRelativo(creada);
                return Padding(
                  padding:
                      const EdgeInsets.only(bottom: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColores.superficie(context),
                      borderRadius:
                          BorderRadius.circular(AppRadio.lg),
                      border: Border.all(
                        color: esError
                            ? AppColores.error
                                .withValues(alpha: 0.5)
                            : esPendiente
                                ? AppColores.naranja
                                    .withValues(alpha: 0.5)
                                : AppColores.exito
                                    .withValues(alpha: 0.4),
                        width: 1,
                      ),
                      boxShadow:
                          AppSombra.tarjeta(context),
                    ),
                    child: ListTile(
                      leading: Icon(_iconoEstado(estado),
                          size: 26,
                          color: _colorEstado(estado)),
                    title: Text(_tipo('${op['tipo']}')),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hace == 'Sin accesos registrados'
                              ? creada.substring(0,
                                      creada.length > 16 ? 16 : creada.length)
                                  .replaceAll('T', ' ')
                              : hace,
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (esError &&
                            op['error'] != null &&
                            '${op['error']}'.isNotEmpty)
                          Builder(
                            builder: (context) {
                              // v1.3.9: traducir error a lenguaje humano
                              final errTraducido =
                                  traducirErrorSync(
                                      '${op['error']}');
                              return Padding(
                                padding:
                                    const EdgeInsets.only(
                                        top: 4),
                                child: Text(
                                  errTraducido.mensaje,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color:
                                          AppColores.error),
                                ),
                              );
                            },
                          ),
                        if (esPendiente)
                          Padding(
                            padding:
                                const EdgeInsets.only(top: 4),
                            child: Text(
                              'Se subirá cuando haya conexión',
                              style: AppTexto.secundario.copyWith(
                                  color: AppColores
                                      .textoSecundario(
                                          context)),
                            ),
                          ),
                      ],
                    ),
                    trailing: cancelable
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (esError || esBloqueada)
                                IconButton(
                                  tooltip: 'Reintentar',
                                  icon: const Icon(Icons.refresh,
                                      color: AppColores.info),
                                  onPressed: () => _reenviar(op),
                                ),
                              IconButton(
                                tooltip: 'Cancelar',
                                icon: const Icon(Icons.cancel_outlined,
                                    color: AppColores.error),
                                onPressed: () => _cancelar(
                                    '${op['op_uuid']}',
                                    '${op['tipo']}'),
                              ),
                            ],
                          )
                        : _estadoChip(estado),
                    onTap: () => _verDetalle(op),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  /// v1.3.4: abre el detalle ampliable de las ops del último push.
  Future<void> _abrirDetalleSubidos() async {
    final uuids = parsearUuidsPush(
        await LocalDb.instance.getMeta('ultimo_push_op_uuids'));
    if (uuids.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay registros en este ciclo')));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          const DetalleSyncScreen(tipo: TipoDetalleSync.subidos)));
  }

  /// v1.3.4: abre el detalle ampliable del último pull.
  Future<void> _abrirDetalleBajados() async {
    final detalle = parsearDetallePull(
        await LocalDb.instance.getMeta('ultimo_pull_detalle'));
    if (detalle.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay registros en este ciclo')));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          const DetalleSyncScreen(tipo: TipoDetalleSync.bajados)));
  }

  /// Tarjeta de estadística (v1.0.9.1).
  /// v1.3.4: `onTap` opcional abre el detalle ampliable (Bajados/Subidos);
  /// cuando está presente se muestra un chevron como affordance.
  Widget _tarjetaStat(IconData icono, String titulo, String valor,
      String subtitulo, Color color,
      {VoidCallback? onTap}) {
    return Tarjeta(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 24, color: color),
              if (onTap != null) ...[
                const Spacer(),
                Icon(Icons.chevron_right,
                    size: 16,
                    color: AppColores.textoSecundario(context)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            valor,
            style: AppTexto.displayPequeno.copyWith(
              color: color,
            ),
          ),
          Text(
            titulo,
            style: AppTexto.subtitulo,
          ),
          const SizedBox(height: 4),
          Text(
            subtitulo,
            style: AppTexto.minuscula.copyWith(
                color:
                    AppColores.textoSecundario(context)),
          ),
        ],
      ),
    );
  }

  /// Chip de estado para operaciones (v1.0.9.1).
  /// v1.3.4: delega en la funcion top-level [chipEstadoOp].
  Widget _estadoChip(String estado) => chipEstadoOp(estado);


}

/// v1.3.4: tipo de detalle ampliable de sincronización.
enum TipoDetalleSync { subidos, bajados }

/// Etiquetas de negocio por tabla espejo (veredicto Argón A1).
const Map<String, String> kEtiquetasTablaSync = {
  'clientes': 'Clientes actualizados/creados',
  'pagos': 'Pagos de mensualidad',
  'pagos_diarios': 'Pagos diarios',
  'ventas_suplementos': 'Ventas de suplementos',
  'suplementos': 'Inventario de suplementos',
  'categorias_suplemento': 'Categorías de suplementos',
  'turnos': 'Cierres de turno',
  'turnos_cierre': 'Cierres de turno',
  'incidencias': 'Incidencias operativas',
  'liquidaciones_caja': 'Liquidaciones de caja',
};

/// v1.3.4: detalle ampliable de un ciclo de sincronización.
/// Muestra qué se subió en el último push (con estado y motivos de
/// rechazo) o qué se bajó en el último pull (por tabla espejo).
class DetalleSyncScreen extends StatefulWidget {
  final TipoDetalleSync tipo;
  const DetalleSyncScreen({super.key, required this.tipo});

  @override
  State<DetalleSyncScreen> createState() => _DetalleSyncScreenState();
}

class _DetalleSyncScreenState extends State<DetalleSyncScreen> {
  bool _cargando = true;
  // Subidos.
  List<Map<String, dynamic>> _ops = [];
  Map<String, List<String>> _detallesPorOp = {};
  String? _pushTs;
  String? _pushDetalleTs;
  // Bajados.
  Map<String, int> _detallePull = {};
  String? _detalleTs;
  String? _pullTs;

  @override
  void initState() {
    super.initState();
    if (widget.tipo == TipoDetalleSync.subidos) {
      _cargarSubidos();
    } else {
      _cargarBajados();
    }
  }

  Future<void> _cargarSubidos() async {
    final uuids = parsearUuidsPush(
        await LocalDb.instance.getMeta('ultimo_push_op_uuids'));
    final ts = await LocalDb.instance.getMeta('ultimo_push_ts');
    final detalleTs =
        await LocalDb.instance.getMeta('ultimo_push_detalle_ts');
    final ops = await LocalDb.instance.opsPorUuids(uuids);
    final detalles = <String, List<String>>{};
    for (final op in ops) {
      detalles['${op['op_uuid']}'] = await detallesDeOp(op);
    }
    if (!mounted) return;
    setState(() {
      _ops = ops;
      _detallesPorOp = detalles;
      _pushTs = ts;
      _pushDetalleTs = detalleTs;
      _cargando = false;
    });
  }

  Future<void> _cargarBajados() async {
    final detalle = parsearDetallePull(
        await LocalDb.instance.getMeta('ultimo_pull_detalle'));
    final detalleTs =
        await LocalDb.instance.getMeta('ultimo_pull_detalle_ts');
    final pullTs = await LocalDb.instance.getMeta('ultimo_pull_ts');
    if (!mounted) return;
    setState(() {
      _detallePull = detalle;
      _detalleTs = detalleTs;
      _pullTs = pullTs;
      _cargando = false;
    });
  }

  /// dd/MM HH:mm, '—' si no hay fecha.
  String _fmtHora(String? iso) {
    final d = parseFecha(iso);
    if (d == null) return '—';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.day)}/${p(d.month)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// HH:mm, '—' si no hay fecha.
  String _fmtHoraCorta(String? iso) {
    final d = parseFecha(iso);
    if (d == null) return '—';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.hour)}:${p(d.minute)}';
  }

  /// Motivo de rechazo legible para una op rechazada.
  String _motivoOp(Map<String, dynamic> op) {
    dynamic res;
    try {
      res = jsonDecode('${op['resultado_servidor'] ?? ''}');
    } catch (_) {
      res = null;
    }
    final motivo = motivoRechazo(res, op['error'] as String?);
    if (motivo != null && motivo.isNotEmpty) return motivo;
    final err = op['error'] as String?;
    if (err != null && err.isNotEmpty) return err;
    return 'Rechazada por el servidor';
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined,
              size: 48,
              color: AppColores.textoSecundario(context)),
          const SizedBox(height: 12),
          Text(
            'Sin registros en este ciclo',
            style: AppTexto.subtitulo.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildSubidos() {
    if (_ops.isEmpty) return _placeholder();
    // v1.3.5 (Argón ajuste 1): si el último chequeo no envió nada,
    // se muestra el lote anterior con nota informativa.
    final pushTs = _pushTs ?? '';
    final detTs = _pushDetalleTs ?? '';
    final mostrarBanner =
        pushTs.isNotEmpty && detTs.isNotEmpty && pushTs != detTs;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            'Lote de ${_fmtHora(_pushDetalleTs ?? _pushTs)}',
            style: AppTexto.subtitulo,
          ),
        ),
        if (mostrarBanner)
          Container(
            margin: const EdgeInsets.only(bottom: 12, top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColores.info.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadio.md),
              border: Border.all(
                  color: AppColores.info.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 20, color: AppColores.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sin envíos en el último chequeo '
                    '(${_fmtHoraCorta(_pushTs)}). Mostrando datos del lote '
                    'anterior (${_fmtHoraCorta(_pushDetalleTs)}).',
                    style: AppTexto.minuscula,
                  ),
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 12),
        ..._ops.map(_tarjetaOp),
      ],
    );
  }

  Widget _tarjetaOp(Map<String, dynamic> op) {
    final estado = '${op['estado']}';
    final detalles = _detallesPorOp['${op['op_uuid']}'] ?? [];
    final uuid = '${op['op_uuid']}';
    final uuidCorto = uuid.length > 8 ? uuid.substring(0, 8) : uuid;
    final textoDetalles =
        detalles.isEmpty ? 'op $uuidCorto' : detalles.join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(describirTipoOp('${op['tipo']}')),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(textoDetalles),
            // v1.3.5 (auditoría 2026-10-16): el motivo también se muestra
            // para necesita_revision, no solo rechazada.
            if (estado == 'rechazada' || estado == 'necesita_revision')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _motivoOp(op),
                  style: AppTexto.minuscula.copyWith(
                      color: estado == 'rechazada'
                          ? AppColores.error
                          : AppColores.alerta),
                ),
              ),
          ],
        ),
        trailing: chipEstadoOp(estado),
      ),
    );
  }

  Widget _buildBajados() {
    final entradas = _detallePull.entries.toList();
    if (entradas.isEmpty) return _placeholder();
    final d = parseFecha(_detalleTs);
    String p(int n) => n.toString().padLeft(2, '0');
    final cabecera = d == null
        ? 'Lote sin fecha registrada'
        : 'Lote de ${p(d.hour)}:${p(d.minute)} del ${p(d.day)}/${p(d.month)}';
    final pullTs = _pullTs ?? '';
    final detTs = _detalleTs ?? '';
    final mostrarBanner =
        pullTs.isNotEmpty && detTs.isNotEmpty && pullTs != detTs;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(cabecera, style: AppTexto.subtitulo),
        ),
        if (mostrarBanner)
          Container(
            margin: const EdgeInsets.only(bottom: 12, top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColores.info.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadio.md),
              border: Border.all(
                  color: AppColores.info.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 20, color: AppColores.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sin cambios en el último chequeo '
                    '(${_fmtHoraCorta(_pullTs)}). Mostrando datos del lote '
                    'anterior (${_fmtHoraCorta(_detalleTs)}).',
                    style: AppTexto.minuscula,
                  ),
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 12),
        ...entradas.map(
          (e) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading:
                  const Icon(Icons.download, color: AppColores.info),
              title: Text(kEtiquetasTablaSync[e.key] ?? e.key),
              trailing: Text(
                '${e.value}',
                style:
                    AppTexto.subtitulo.copyWith(color: AppColores.info),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final esSubidos = widget.tipo == TipoDetalleSync.subidos;
    return Scaffold(
      appBar: AppBar(
        title:
            Text(esSubidos ? 'Detalle de subidos' : 'Detalle de bajados'),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : esSubidos
              ? _buildSubidos()
              : _buildBajados(),
    );
  }
}
