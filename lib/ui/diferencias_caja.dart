/// T5 (1.20): bandeja «Diferencias de caja» del dueño —
/// expedientes abiertos por diferencias al liquidar que no
/// eran el arrastre normal, y su resolución.
///
/// El entrenador no entra aquí: ve SUS expedientes en el
/// detalle de su arqueo (transparencia sin castigo; nada
/// se descuenta automáticamente).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../diferencias_caja.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Diálogo para resolver un expediente: clasificación
/// cerrada + nota (obligatoria para «Otro», el servidor
/// lo vuelve a validar). Devuelve true si se encoló.
Future<bool> mostrarDialogoResolverDiferencia(
  BuildContext context, {
  required Map<String, dynamic> expediente,
}) async {
  var resolucion = 'vuelto';
  final notaCtrl = TextEditingController();
  var errorNota = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final notaObligatoria = resolucion == 'otro';
        return DialogoApp(
          titulo: 'Resolver diferencia',
          iconoTitulo: Icons.task_alt_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${expediente['entrenador_nombre'] ?? ''}',
                  style: AppTexto.subtitulo,
                ),
                Text(
                  'Faltan ${fmtMonto(expediente['monto'])} '
                  '${expediente['moneda'] ?? 'CUP'} · '
                  '${fmtFecha('${expediente['fecha'] ?? ''}')}',
                  style: AppTexto.secundario,
                ),
                if ('${expediente['explicacion'] ?? ''}'
                    .trim()
                    .isNotEmpty) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text('Explicación: ${expediente['explicacion']}',
                      style: AppTexto.secundario),
                ],
                const SizedBox(height: AppEspacio.lg),
                const Text('¿Qué pasó con ese dinero?',
                    style: AppTexto.etiqueta),
                const SizedBox(height: AppEspacio.sm),
                Wrap(
                  spacing: AppEspacio.sm,
                  runSpacing: AppEspacio.sm,
                  children: [
                    for (final r in kResolucionesDiferencia)
                      ChoiceChip(
                        label: Text(
                            etiquetaResolucionDiferencia(r)),
                        selected: resolucion == r,
                        onSelected: (_) => setState(() {
                          resolucion = r;
                          errorNota = false;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppEspacio.lg),
                CampoTexto(
                  controller: notaCtrl,
                  etiqueta: notaObligatoria
                      ? 'Nota (obligatoria)'
                      : 'Nota (opcional)',
                  maxLineas: 3,
                  onChanged: (_) {
                    if (errorNota) setState(() => errorNota = false);
                  },
                ),
                if (errorNota) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'Para «Otro» hay que escribir la nota.',
                    style: AppTexto.metadato
                        .copyWith(color: AppColores.error),
                  ),
                ],
              ],
            ),
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (notaObligatoria &&
                    notaCtrl.text.trim().isEmpty) {
                  setState(() => errorNota = true);
                  return;
                }
                await DiferenciasCajaService.instance.resolver(
                  expedienteId: '${expediente['id']}',
                  resolucion: resolucion,
                  nota: notaCtrl.text,
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Resolver'),
            ),
          ],
        );
      },
    ),
  );
  // 1.23 AT-09: sin dispose aquí — el TextField sigue montado
  // durante la animación de salida del diálogo y disponerlo
  // revienta con «used after being disposed» (patrón v1.3.1).
  if (ok == true && context.mounted) {
    mostrarSnack(context, 'Diferencia resuelta (se sincronizará)',
        significado: SignificadoChip.exito);
  }
  return ok == true;
}

/// Chip de estado de un expediente (abierto / resuelto con
/// su clasificación), compartido con el historial de
/// liquidaciones del arqueo.
Widget chipExpedienteDiferencia(Map<String, dynamic> exp) {
  final resuelta = '${exp['estado']}' == 'resuelta';
  return ChipEstado.semantico(
    texto: resuelta
        ? 'Expediente resuelto · '
            '${etiquetaResolucionDiferencia('${exp['resolucion'] ?? ''}')}'
        : 'Expediente abierto',
    significado:
        resuelta ? SignificadoChip.exito : SignificadoChip.alerta,
  );
}

class DiferenciasCajaScreen extends StatefulWidget {
  const DiferenciasCajaScreen({super.key});

  @override
  State<DiferenciasCajaScreen> createState() =>
      _DiferenciasCajaScreenState();
}

class _DiferenciasCajaScreenState
    extends State<DiferenciasCajaScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _abiertas = [];
  List<Map<String, dynamic>> _resueltas = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final filas = await DiferenciasCajaService.instance.todas();
      if (mounted) {
        setState(() {
          _abiertas = filas
              .where((r) => '${r['estado']}' == 'abierta')
              .toList();
          _resueltas = filas
              .where((r) => '${r['estado']}' == 'resuelta')
              .take(20)
              .toList();
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Widget _fila(Map<String, dynamic> e) {
    final resuelta = '${e['estado']}' == 'resuelta';
    final notaRes = '${e['resolucion_nota'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${e['entrenador_nombre'] ?? ''}',
                      style: AppTexto.subtitulo),
                ),
                chipExpedienteDiferencia(e),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(
              'Faltan ${fmtMonto(e['monto'])} '
              '${e['moneda'] ?? 'CUP'} · liquidación del '
              '${fmtFecha('${e['fecha'] ?? ''}')}',
              style: AppTexto.secundario,
            ),
            if ('${e['explicacion'] ?? ''}'.trim().isNotEmpty)
              Text('Explicación: ${e['explicacion']}',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            if (resuelta && notaRes.isNotEmpty)
              Text('Nota: $notaRes',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            if (!resuelta) ...[
              const SizedBox(height: AppEspacio.sm),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.task_alt_rounded,
                      size: 18),
                  label: const Text('Resolver'),
                  onPressed: () async {
                    final ok = await mostrarDialogoResolverDiferencia(
                        context,
                        expediente: e);
                    if (ok) _cargar();
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Diferencias de caja')),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño lleva las diferencias de caja',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diferencias de caja'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      // 1.23 T7: cruce por tipo de estado (sin estado vacío de
      // pantalla: el «sin abiertas» es una tarjeta de sección).
      body: CruceEstados(
        estado: _cargando ? 'cargando' : 'contenido',
        child: _cargando
            ? const EstadoCargando(texto: 'Cargando diferencias…')
            : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  EncabezadoSeccion(
                      titulo: 'Abiertas (${_abiertas.length})'),
                  if (_abiertas.isEmpty)
                    const Tarjeta(
                      child: Text(
                          'No hay diferencias de caja abiertas.'),
                    )
                  else
                    for (final e in _abiertas) _fila(e),
                  if (_resueltas.isNotEmpty) ...[
                    const SizedBox(height: AppEspacio.lg),
                    const EncabezadoSeccion(titulo: 'Resueltas'),
                    for (final e in _resueltas) _fila(e),
                  ],
                ],
              ),
            ),
        ),
    );
  }
}
