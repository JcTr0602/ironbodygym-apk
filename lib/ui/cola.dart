/// Sincronización detallada: última vez, qué subió/bajó, errores
/// y cola de operaciones (con opción de cancelar las pendientes).
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';

class ColaScreen extends StatefulWidget {
  const ColaScreen({super.key});
  @override
  State<ColaScreen> createState() => _ColaScreenState();
}

class _ColaScreenState extends State<ColaScreen> {
  List<Map<String, dynamic>> _ops = [];
  SyncDetalle _det = const SyncDetalle();
  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final ops = await LocalDb.instance.recentOps();
    final det = await SyncEngine.instance.detalle();
    if (mounted) {
      setState(() {
        _ops = ops;
        _det = det;
      });
    }
  }

  Future<void> _sincronizar() async {
    setState(() => _sincronizando = true);
    await SyncEngine.instance.run();
    await _cargar();
    if (mounted) setState(() => _sincronizando = false);
    // Resumen post-sync (solo en sincronización manual desde aquí)
    if (mounted) _mostrarResumen();
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
        return Icons.upload;
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
        return AppColores.info;
      case 'rechazada':
      case 'error':
        return AppColores.error;
      default:
        return AppColores.naranja;
    }
  }

  String _tipo(String t) {
    switch (t) {
      case 'inscribir':
        return 'Inscripción';
      case 'pago_mensual':
        return 'Pago mensual';
      case 'pago_diario':
        return 'Pago diario';
      case 'foto':
        return 'Foto';
      case 'editar_cliente':
        return 'Edición de cliente';
      case 'cambiar_estado':
        return 'Cambio de estado';
      case 'ajuste':
        return 'Cambio de precio';
      case 'admin_usuario':
        return 'Usuario APK';
      case 'confirmar_entrega':
        return 'Confirmar entrega';
      case 'gasto':
        return 'Gasto';
      case 'editar_pago':
        return 'Corrección de pago';
      case 'anular_pago':
        return 'Anulación de pago';
      case 'inscripcion_venta_suplemento':
        return 'Inscripción + venta';
      default:
        return t;
    }
  }

  String _hora(DateTime? d) {
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Muestra el detalle completo de una operación al tocarla.
  Future<void> _reenviar(Map<String, dynamic> op) async {
    final uuid = op['op_uuid'] as String;
    // Marca como pendiente para que se reintente en el próximo push
    await LocalDb.instance.markOp(uuid, 'pendiente', error: null);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Operación marcada para reenviar')),
      );
      _cargar();
    }
  }

  void _verDetalle(Map<String, dynamic> op) async {
    final tipo = _tipo('${op['tipo']}');
    final estado = '${op['estado']}';
    final fecha = '${op['creada_ts']}'.substring(0, 16).replaceAll('T', ' ');
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

  /// Detalles legibles del payload según el tipo de operación (v1.0.11).
  Future<List<String>> _detallesOp(Map<String, dynamic> op) async {
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
        return c?['nombre'] as String?;
      } catch (_) {
        return null;
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
    }
    return detalles;
  }

  @override
  Widget build(BuildContext context) {
    final pendientes =
        _ops.where((o) => o['estado'] == 'pendiente').length;
    final conError =
        _ops.where((o) => o['estado'] == 'error').length;
    // v1.0.14: tres estados claros en vez de binario ok/error
    // v1.1: icono Material en vez de emoji
    final String estadoSync;
    final List<Color> colores;
    final IconData iconoEstado;
    final String titulo;
    final String subtitulo;
    if (conError > 0) {
      estadoSync = 'error';
      colores = [AppColores.error, AppColores.errorOscuro];
      iconoEstado = Icons.warning;
      titulo = 'Atención requerida';
      subtitulo = conError == 1
          ? '1 operación falló y necesita tu revisión'
          : '$conError operaciones fallaron y necesitan tu revisión';
    } else if (pendientes > 0) {
      estadoSync = 'pendiente';
      colores = [AppColores.alerta, AppColores.alertaOscuro];
      iconoEstado = Icons.schedule;
      titulo = 'Pendiente de sincronizar';
      subtitulo = pendientes == 1
          ? '1 operación esperando conexión'
          : '$pendientes operaciones esperando conexión';
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
                    'Última: ${_hora(_det.ultimaPull)}',
                    AppColores.info,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _tarjetaStat(
                    Icons.upload,
                    'Subidos',
                    '${_det.subidos}',
                    'Última: ${_hora(_det.ultimaPush)}',
                    AppColores.naranja,
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
                final cancelable = esPendiente || esError;
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
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${op['error']}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColores.error),
                            ),
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
                              if (esError)
                                IconButton(
                                  tooltip: 'Reintentar',
                                  icon: const Icon(Icons.refresh,
                                      color: AppColores.info),
                                  onPressed: () => _sincronizar(),
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

  /// Tarjeta de estadística (v1.0.9.1)
  Widget _tarjetaStat(
      IconData icono, String titulo, String valor, String subtitulo, Color color) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 24, color: color),
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

  /// Chip de estado para operaciones (v1.0.9.1)
  Widget _estadoChip(String estado) {
    Color color;
    IconData icono;
    String texto;
    if (estado == 'aplicada') {
      color = AppColores.exito;
      icono = Icons.check_circle;
      texto = 'aplicada';
    } else if (estado == 'rechazada') {
      color = AppColores.error;
      icono = Icons.block;
      texto = 'rechazada';
    } else if (estado == 'enviada') {
      color = AppColores.info;
      icono = Icons.upload;
      texto = 'enviada';
    } else {
      color = AppColores.naranja;
      icono = Icons.schedule;
      texto = estado;
    }
    return ChipEstado(texto: texto, color: color, icono: icono);
  }


}
