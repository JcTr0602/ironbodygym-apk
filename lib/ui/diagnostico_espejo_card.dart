import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_log.dart';
import '../auth.dart';
import '../config.dart';
import '../diagnostico_espejo.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// 1.23 (W1): tarjeta de diagnóstico ante un espejo de
/// clientes vacío. Se coloca en Home y en Buscar; se evalúa
/// sola al montarse y NO pinta nada cuando el espejo está
/// sano (el caso normal: un conteo + dos lecturas de meta).
///
/// Acciones:
/// - Sincronizar ahora: reintenta la bajada en el momento.
/// - Exportar bitácora: SOLO el dueño, como en Ajustes (la
///   bitácora es material de diagnóstico sensible); exporta
///   la completa del momento, que es la evidencia del fallo.
/// - Reportar por WhatsApp: cualquier usuario; manda al dueño
///   el resumen del diagnóstico (versión, testigo, última
///   sync buena, pendientes), el mismo canal del «Reportar
///   problema» de Ajustes.
/// - Es correcto: el vacío es legítimo (se borraron todos los
///   clientes a propósito); pone el testigo a 0 con
///   confirmación y la tarjeta no vuelve.
class TarjetaDiagnosticoEspejo extends StatefulWidget {
  const TarjetaDiagnosticoEspejo({super.key});

  @override
  State<TarjetaDiagnosticoEspejo> createState() =>
      _TarjetaDiagnosticoEspejoState();
}

class _TarjetaDiagnosticoEspejoState
    extends State<TarjetaDiagnosticoEspejo> {
  DiagnosticoEspejo? _diag;
  bool _cargado = false;
  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _evaluar();
  }

  Future<void> _evaluar() async {
    final d = await evaluarEspejoVacio();
    if (!mounted) return;
    setState(() {
      _diag = d;
      _cargado = true;
    });
  }

  Future<void> _sincronizar() async {
    setState(() => _sincronizando = true);
    try {
      await SyncEngine.instance.push();
    } catch (_) {
      // El motor ya registra y clasifica sus fallos; aquí solo
      // importa re-evaluar el espejo tras el intento.
    }
    if (!mounted) return;
    setState(() => _sincronizando = false);
    await _evaluar();
    if (!mounted) return;
    if (_diag == null) {
      mostrarSnack(context, 'Datos recuperados. Ya se ven los clientes.',
          significado: SignificadoChip.exito);
    }
  }

  Future<void> _exportarBitacora() async {
    try {
      final (path, _) =
          await AppLog.exportar(versionApp: AppConfig.appVersion);
      await Share.shareXFiles([XFile(path)],
          text: 'Bitácora Iron Body Gym (espejo vacío)');
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo exportar la bitácora: $e',
          significado: SignificadoChip.error);
    }
  }

  Future<void> _reportarWhatsApp() async {
    final d = _diag;
    if (d == null) return;
    final texto = 'Hola, la app Iron Body Gestión muestra los '
        'clientes en cero:\n\n'
        '• Versión: ${AppConfig.appVersion}\n'
        '• Usuario: ${AuthService().username}\n'
        '• Clientes que había: ${d.clientesPrevios}\n'
        '• Última sincronización buena: '
        '${textoUltimaSyncOk(d.ultimaSyncOk)}\n'
        '• Pendientes por subir: ${d.opsPendientes}\n'
        '• Fecha: ${isoHabana(ahoraHabana()).substring(0, 16)}\n';
    final url = Uri.parse(
        'https://wa.me/5358191577?text=${Uri.encodeComponent(texto)}');
    final ok =
        await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    if (!ok) {
      mostrarSnack(context, 'No se pudo abrir WhatsApp',
          significado: SignificadoChip.error);
    }
  }

  Future<void> _marcarCorrecto() async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: '¿De verdad no hay clientes?',
      mensaje: 'Solo confirma si TODOS los clientes se '
          'borraron a propósito. La app dejará de avisar de '
          'este vacío y tomará el cero como el estado bueno.',
      aceptar: 'Es correcto',
    );
    if (ok != true) return;
    await LocalDb.instance.setMeta('clientes_previos_buenos', '0');
    if (!mounted) return;
    setState(() => _diag = null);
  }

  @override
  Widget build(BuildContext context) {
    final d = _diag;
    if (!_cargado || d == null) return const SizedBox.shrink();
    final esDueno = AuthService().isOwner;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
      child: Container(
        decoration: BoxDecoration(
          color: AppColores.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadio.lg),
          border: Border.all(
              color: AppColores.error.withValues(alpha: 0.45)),
        ),
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: AppColores.error),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                    'Los clientes aparecen en cero',
                    style: AppTexto.titulo
                        .copyWith(color: AppColores.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(
              'Este teléfono tenía ${d.clientesPrevios} clientes '
              'tras su última bajada buena '
              '(${textoUltimaSyncOk(d.ultimaSyncOk)}) y ahora el '
              'espejo está vacío. No es un estado normal: puede '
              'que la bajada haya llegado incompleta.',
              style: AppTexto.cuerpo,
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(
              'Pendientes por subir: ${d.opsPendientes}. '
              '${d.causaProbable}',
              style: AppTexto.secundario,
            ),
            const SizedBox(height: AppEspacio.md),
            Wrap(
              spacing: AppEspacio.sm,
              runSpacing: AppEspacio.sm,
              children: [
                FilledButton.icon(
                  onPressed: _sincronizando ? null : _sincronizar,
                  icon: _sincronizando
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                  label: const Text('Sincronizar ahora'),
                ),
                if (esDueno)
                  OutlinedButton.icon(
                    onPressed: _exportarBitacora,
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Exportar bitácora'),
                  ),
                OutlinedButton.icon(
                  onPressed: _reportarWhatsApp,
                  icon: const Icon(Icons.chat_outlined),
                  label: const Text('Reportar al dueño'),
                ),
                TextButton(
                  onPressed: _marcarCorrecto,
                  child: const Text('Es correcto, no hay clientes'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
