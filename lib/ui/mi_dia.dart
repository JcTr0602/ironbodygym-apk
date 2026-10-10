/// 📅 Mi día: lo que el entrenador cobró hoy, lo que falta por
/// cobrar hoy y botón para cerrar el turno con un resumen.
library;

import 'package:flutter/material.dart';

import 'dart:io';

import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class MiDiaScreen extends StatefulWidget {
  const MiDiaScreen({super.key});

  @override
  State<MiDiaScreen> createState() => _MiDiaScreenState();
}

class _MiDiaScreenState extends State<MiDiaScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _cobrados = [];
  List<Map<String, dynamic>> _porCobrar = [];
  double _totalHoy = 0;
  double _efectivo = 0;
  double _transferencia = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final hoy = _hoyCorto();
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombres = <int, String>{
      for (final c in clientes)
        if (c['id'] is int) c['id'] as int: '${c['nombre'] ?? '—'}'
    };
    final fotos = <int, String?>{
      for (final c in clientes)
        if (c['id'] is int)
          c['id'] as int: c['foto_storage'] as String?,
    };
    final cobrados = <Map<String, dynamic>>[];
    double total = 0;
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final f = '${p['fecha'] ?? ''}';
      if (f.length < 10 || f.substring(0, 10) != hoy) continue;
      final monto = (p['monto'] as num?)?.toDouble() ?? 0;
      total += monto;
      cobrados.add({
        'nombre': nombres[p['cliente_id'] as int?] ?? '—',
        'monto': monto,
        'metodo': '${p['metodo'] ?? 'efectivo'}',
        'periodo': '${p['periodo'] ?? 'mensual'}',
        'foto_storage': fotos[p['cliente_id'] as int?],
      });
    }
    cobrados.sort((a, b) =>
        (b['monto'] as double).compareTo(a['monto'] as double));
    final porCobrar = await vencenHoy();
    final porMetodo = await cobradoHoyPorMetodo();
    if (mounted) {
      setState(() {
        _cobrados = cobrados;
        _porCobrar = porCobrar;
        _totalHoy = total;
        _efectivo = porMetodo['efectivo'] ?? 0;
        _transferencia = porMetodo['transferencia'] ?? 0;
        _cargando = false;
      });
    }
  }

  String _hoyCorto() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> _cerrarTurno() async {
    final faltan = _porCobrar.length;
    final sinMovimientos =
        _cobrados.isEmpty && _totalHoy == 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cierre del turno'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sinMovimientos) ...[
              const Text(
                'Turno sin cobros registrados.',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                'Si trabajaste el turno pero nadie pagó, '
                'queda registrado así.',
                style: TextStyle(
                    fontSize: 13,
                    color:
                        AppColores.textoSecundario(ctx)),
              ),
            ] else ...[
              Text('Cobrado hoy: ${fmtMonto(_totalHoy)} CUP',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('• ${_cobrados.length} cobros realizados'),
              Text('• Efectivo: ${fmtMonto(_efectivo)} CUP'),
              Text(
                  '• Transferencia: ${fmtMonto(_transferencia)} CUP'),
            ],
            const SizedBox(height: 6),
            Text(faltan == 0
                ? 'No quedó nadie por cobrar hoy.'
                : 'Quedaron $faltan por cobrar hoy.'),
            const SizedBox(height: 12),
            Text(
              'Recuerda: el pendiente a entregar solo se reinicia '
              'cuando Jc confirma que recibió el dinero.',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(ctx)),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi día'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SyncBanner(),
                  const SizedBox(height: 8),
                  Tarjeta(
                    color: AppColores.naranja,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Text('Cobrado hoy',
                            style: AppTexto.secundario.copyWith(
                                color: Colors.white.withValues(
                                    alpha: 0.85))),
                        Text('${fmtMonto(_totalHoy)} CUP',
                            style: AppTexto.display.copyWith(
                                color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(
                            '${_cobrados.length} cobros · '
                            '${fmtMonto(_efectivo)} · '
                            '${fmtMonto(_transferencia)}',
                            style: AppTexto.minuscula.copyWith(
                                color: Colors.white.withValues(
                                    alpha: 0.85))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Cobros realizados hoy',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  if (_cobrados.isEmpty)
                    Tarjeta(
                      child: Text(
                          'Aún no hay cobros registrados hoy.',
                          textAlign: TextAlign.center,
                          style: AppTexto.secundario.copyWith(
                              color: AppColores
                                  .textoSecundario(context))),
                    )
                  else
                    for (final c in _cobrados)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8),
                        child: Tarjeta(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: _FotoMini(
                              fotoStorage:
                                  c['foto_storage'] as String?,
                              fallback: Icon(
                                (c['metodo'] as String) ==
                                        'transferencia'
                                    ? Icons.smartphone
                                    : Icons.payments,
                                size: 22,
                                color: AppColores.naranja,
                              ),
                            ),
                            title: Text('${c['nombre']}'),
                            subtitle:
                                Text(etiquetaPeriodo(c)),
                            trailing: Text(
                              '${fmtMonto(c['monto'])} CUP',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColores.naranja),
                            ),
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  Text(
                      'Por cobrar hoy (${_porCobrar.length})',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  if (_porCobrar.isEmpty)
                    Tarjeta(
                      child: Text(
                          'Nadie vence hoy. Todo al día.',
                          textAlign: TextAlign.center,
                          style: AppTexto.secundario.copyWith(
                              color: AppColores
                                  .textoSecundario(context))),
                    )
                  else
                    for (final c in _porCobrar)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8),
                        child: Tarjeta(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: _FotoMini(
                              fotoStorage:
                                  c['foto_storage'] as String?,
                              fallback: const Icon(
                                  Icons.warning_amber,
                                  color: AppColores.alerta),
                            ),
                            title:
                                Text('${c['nombre'] ?? '—'}'),
                            subtitle: Text(
                                'Vence hoy · ${fmtFecha(c['pagado_hasta'] as String?)}'),
                          ),
                        ),
                      ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.flag),
                      label: const Text('Cerrar turno'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14),
                      ),
                      onPressed: _cerrarTurno,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}

/// Miniatura de foto del cliente (v1.0.13).
class _FotoMini extends StatefulWidget {
  final String? fotoStorage;
  final Widget fallback;
  const _FotoMini({required this.fotoStorage, required this.fallback});

  @override
  State<_FotoMini> createState() => _FotoMiniState();
}

class _FotoMiniState extends State<_FotoMini> {
  File? _foto;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final f = await FotoCache.instance.enCache(widget.fotoStorage);
    if (mounted) setState(() => _foto = f);
  }

  @override
  Widget build(BuildContext context) {
    if (_foto == null) return widget.fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Image.file(
        _foto!,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
      ),
    );
  }
}
