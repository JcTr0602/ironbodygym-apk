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
    // Yunque B (cierre de la oleada): la evaluación es un
    // diagnóstico en segundo plano lanzado sin esperar desde
    // initState — si la BD se cierra o se reinicia en mitad
    // de la lectura (cierre de la app, recarga), el error NO
    // puede quedar como excepción sin atrapar: la tarjeta
    // simplemente no sale. La suite lo cazó al alargarse la
    // carga de Home (YB-FLU-01): la evaluación aterrizaba
    // tras el reinicio de la BD del siguiente test.
    try {
      final d = await evaluarEspejoVacio();
      if (!mounted) return;
      setState(() {
        _diag = d;
        _cargado = true;
      });
    } catch (_) {}
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
    // Yunque R4-M3-5: apagar la alarma de espejo vacío es
    // decisión del dueño y queda en bitácora con actor —
    // antes cualquier usuario del teléfono compartido la
    // silenciaba para siempre sin dejar constancia, y el
    // próximo vacío real ya no tendría tarjeta.
    final auth = AuthService();
    if (!auth.isOwner) return;
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
    AppLog.info('sync', 'espejo_vacio_marcado_correcto',
        d: 'actor=${auth.userId ?? 'sin_uid'} '
            'previos=${_diag?.clientesPrevios ?? 0}');
    if (!mounted) return;
    setState(() => _diag = null);
  }

  /// 1.28 (M1-C4): cifra destacada de la tarjeta (el dato
  /// grande arriba, su etiqueta pequeña debajo).
  Widget _cifra(BuildContext context, String valor, String etiqueta) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      decoration: BoxDecoration(
        color: AppColores.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadio.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            valor,
            style: AppTexto.titulo.copyWith(color: AppColores.error),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(etiqueta, style: AppTexto.metadato),
        ],
      ),
    );
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
            // 1.28 (M1-C4): la tarjeta se lee de un vistazo —
            // causa en UNA frase primero, los dos datos como
            // CIFRAS destacadas y las acciones separadas por
            // importancia. Antes todo era texto corrido y el
            // «es correcto» era un botón más entre los demás.
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppEspacio.sm),
                  decoration: BoxDecoration(
                    color:
                        AppColores.error.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.warning_amber_rounded,
                      color: AppColores.error, size: 22),
                ),
                const SizedBox(width: AppEspacio.md),
                Expanded(
                  child: Text(
                    'Los clientes aparecen en cero',
                    style: AppTexto.titulo
                        .copyWith(color: AppColores.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.md),
            // La causa probable, primero y en una frase.
            Text(
              d.causaProbable,
              style: AppTexto.cuerpo
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppEspacio.md),
            // Los dos datos que importan, como cifras.
            Row(
              children: [
                Expanded(
                  child: _cifra(
                    context,
                    '${d.clientesPrevios}',
                    'clientes que había',
                  ),
                ),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: _cifra(
                    context,
                    textoUltimaSyncOk(d.ultimaSyncOk),
                    'última bajada buena',
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(
              'Pendientes por subir en este teléfono: '
              '${d.opsPendientes}.',
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
              ],
            ),
            // Acción discreta y APARTE: declarar el vacío
            // legítimo no compite con las acciones de
            // rescate. Yunque R4-M3-5: solo el dueño la ve
            // (como Exportar bitácora): es su decisión y
            // queda en bitácora.
            if (esDueno) ...[
              const SizedBox(height: AppEspacio.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _marcarCorrecto,
                  style: TextButton.styleFrom(
                    foregroundColor:
                        AppColores.textoSecundario(context),
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.sm),
                    minimumSize: const Size(0, 36),
                  ),
                  child: const Text(
                      'Es correcto, se borraron a propósito'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
