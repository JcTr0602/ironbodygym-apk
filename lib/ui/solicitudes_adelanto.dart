/// Solicitudes de adelanto (v1.12.0, Bloque 3 F3 — SOLO dueño).
/// Lista del espejo `solicitudes_adelanto`: pendientes primero.
/// Al aprobar, el dueño ELIGE el destino ANTES de confirmar
/// (contrato a7556fd): «Nómina» (por defecto: solo descuenta de
/// la nómina del mes) o «Pendiente a entregar» (descuenta del
/// pendiente a entregar de la gaveta del entrenador y ADEMÁS
/// aparece en su libro de nómina). Al rechazar, el motivo es
/// obligatorio. Todo viaja por sync_ops (la decisión sube cuando
/// haya red); la fila optimista deja de ofrecerse como pendiente
/// sin esperar al pull.
library;

import 'package:flutter/material.dart';

import '../bloque3.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class SolicitudesAdelantoScreen extends StatefulWidget {
  const SolicitudesAdelantoScreen({super.key});
  @override
  State<SolicitudesAdelantoScreen> createState() =>
      _SolicitudesAdelantoScreenState();
}

class _SolicitudesAdelantoScreenState
    extends State<SolicitudesAdelantoScreen> {
  bool _cargando = true;
  bool _actuando = false;
  List<SolicitudAdelanto> _lista = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final lista =
        await SolicitudesAdelantoService.instance.todasParaDueno();
    lista.sort((a, b) {
      final pa = a.pendiente ? 0 : 1;
      final pb = b.pendiente ? 0 : 1;
      if (pa != pb) return pa - pb;
      return (b.creadoEn ?? '').compareTo(a.creadoEn ?? '');
    });
    if (!mounted) return;
    setState(() {
      _lista = lista;
      _cargando = false;
    });
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  /// Diálogo de aprobación con el selector de destino OBLIGATORIO
  /// antes de confirmar (el dueño ve qué significa cada destino).
  /// Fase A 2026-10-25 (B1): también se elige CÓMO se paga el
  /// adelanto; por transferencia, «Pendiente a entregar» no está
  /// disponible (una transferencia no sale de la gaveta) y el
  /// destino se fuerza a «Nómina» antes de enviar.
  Future<void> _aprobar(SolicitudAdelanto s) async {
    var destino = 'nomina';
    var metodo = 'efectivo';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Aprobar adelanto'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${s.entrenadorNombre ?? s.entrenador ?? 'Entrenador'}'
                ' · ${fmtMonto(s.monto)} CUP'
                '${s.motivo.isNotEmpty ? ' · «${s.motivo}»' : ''}',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              const Text('¿Cómo se paga?',
                  style: AppTexto.subtitulo),
              RadioListTile<String>(
                value: 'efectivo',
                groupValue: metodo,
                onChanged: (v) => setS(() => metodo = v ?? 'efectivo'),
                title: const Text('Efectivo'),
                subtitle: const Text(
                  'Sale de la caja del turno.',
                  style: AppTexto.secundario,
                ),
              ),
              RadioListTile<String>(
                value: 'transferencia',
                groupValue: metodo,
                onChanged: (v) => setS(() {
                  metodo = v ?? 'efectivo';
                  // B1: por transferencia no hay gaveta de donde
                  // descontar: el destino vuelve a Nómina solo.
                  if (metodo == 'transferencia') destino = 'nomina';
                }),
                title: const Text('Transferencia'),
                subtitle: const Text(
                  'Va directo a su cuenta; no descuenta del '
                  'pendiente a entregar.',
                  style: AppTexto.secundario,
                ),
              ),
              const SizedBox(height: AppEspacio.md),
              const Text('¿De dónde sale el dinero?',
                  style: AppTexto.subtitulo),
              RadioListTile<String>(
                value: 'nomina',
                groupValue: destino,
                onChanged: (v) => setS(() => destino = v ?? 'nomina'),
                title: const Text('Nómina'),
                subtitle: const Text(
                  'Solo descuenta de la nómina del mes.',
                  style: AppTexto.secundario,
                ),
              ),
              RadioListTile<String>(
                value: 'pendiente',
                groupValue: destino,
                // B1: deshabilitado por transferencia (el destino
                // efectivo sería Nómina de todos modos).
                onChanged: metodo == 'transferencia'
                    ? null
                    : (v) => setS(() => destino = v ?? 'nomina'),
                title: const Text('Pendiente a entregar'),
                subtitle: const Text(
                  'Descuenta del pendiente a entregar de su '
                  'gaveta y además aparece en su libro de nómina.',
                  style: AppTexto.secundario,
                ),
              ),
              if (metodo == 'transferencia')
                const Text(
                  'Por transferencia el destino es Nómina: el '
                  'pendiente a entregar es efectivo en mano.',
                  style: AppTexto.secundario,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Aprobar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // B1: el destino efectivo (forzado) es el que se muestra.
    final destinoFinal =
        destinoEfectivoF3(metodo: metodo, destino: destino);
    setState(() => _actuando = true);
    try {
      await SolicitudesAdelantoService.instance.resolver(
          solicitud: s,
          aprobar: true,
          destino: destino,
          metodo: metodo);
      _snack('Adelanto aprobado '
          '(${destinoFinal == 'nomina' ? 'Nómina' : 'Pendiente a entregar'}).');
      await _cargar();
    } catch (e) {
      _snack('No se pudo aprobar: $e');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _rechazar(SolicitudAdelanto s) async {
    final motivoCtrl = TextEditingController();
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rechazar solicitud'),
        content: TextField(
          controller: motivoCtrl,
          decoration: const InputDecoration(
            labelText: 'Motivo del rechazo',
            border: OutlineInputBorder(),
          ),
          maxLength: 120,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(motivoCtrl.text.trim()),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );
    if (motivo == null || motivo.isEmpty || !mounted) return;
    setState(() => _actuando = true);
    try {
      await SolicitudesAdelantoService.instance
          .resolver(solicitud: s, aprobar: false, motivo: motivo);
      _snack('Solicitud rechazada.');
      await _cargar();
    } catch (e) {
      _snack('No se pudo rechazar: $e');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Solicitudes de adelanto')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_lista.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppEspacio.xl),
          child: Text(
            'No hay solicitudes de adelanto.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario,
          ),
        ),
      );
    }
    return FadeEntrada(
      child: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView.builder(
          padding: const EdgeInsets.all(AppEspacio.lg),
          itemCount: _lista.length,
          itemBuilder: (ctx, i) {
            final s = _lista[i];
            final nombre =
                s.entrenadorNombre ?? s.entrenador ?? 'Entrenador';
            return Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.md),
              child: Tarjeta(
                color: s.pendiente
                    ? AppColores.alerta.withValues(alpha: 0.10)
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$nombre · ${fmtMonto(s.monto)} CUP',
                            style: AppTexto.subtitulo,
                          ),
                        ),
                        _chipEstado(s.estado),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (s.motivo.isNotEmpty)
                      Text('«${s.motivo}»', style: AppTexto.cuerpo),
                    if (s.creadoEn != null)
                      Text('Pedida el ${s.creadoEn!.substring(0, 10)}',
                          style: AppTexto.secundario),
                    if (s.destinoEtiqueta != null)
                      Text('Destino: ${s.destinoEtiqueta}',
                          style: AppTexto.secundario),
                    if (s.estado == 'rechazado' &&
                        (s.motivoResolucion ?? '').isNotEmpty)
                      Text('Motivo: «${s.motivoResolucion}»',
                          style: AppTexto.secundario),
                    if (s.resueltoEn != null)
                      Text(
                        'Resuelta el ${s.resueltoEn!.substring(0, 10)}'
                        '${(s.resueltoPorNombre ?? '').isNotEmpty ? ' por ${s.resueltoPorNombre}' : ''}',
                        style: AppTexto.secundario,
                      ),
                    if (s.pendiente) ...[
                      const SizedBox(height: AppEspacio.md),
                      Wrap(
                        spacing: AppEspacio.sm,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.check_rounded,
                                size: 18),
                            label: const Text('Aprobar'),
                            onPressed:
                                _actuando ? null : () => _aprobar(s),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.block_rounded,
                                size: 18),
                            label: const Text('Rechazar'),
                            onPressed:
                                _actuando ? null : () => _rechazar(s),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chipEstado(String estado) {
    final color = switch (estado) {
      'aprobado' => AppColores.exitoOscuro,
      'rechazado' => AppColores.error,
      _ => AppColores.alertaOscuro,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        switch (estado) {
          'aprobado' => 'Aprobada',
          'rechazado' => 'Rechazada',
          _ => 'Pendiente',
        },
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
