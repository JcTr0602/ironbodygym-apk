/// Widgets compartidos.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localdb.dart';
import '../sync.dart';

/// Franja de estado de sincronización (visible en todas las pantallas).
///
/// Cuando hay operaciones por subir, muestra el desglose discreto por tipo.
class SyncBanner extends StatelessWidget {
  const SyncBanner({super.key});

  String _etiqueta(String tipo, int n) {
    final plural = n == 1 ? '' : 'es';
    switch (tipo) {
      case 'inscribir':
        return '$n inscripción$plural';
      case 'pago_mensual':
        return '$n pago$plural';
      case 'pago_diario':
        return '$n diario$plural';
      case 'foto':
        return '$n foto$plural';
      default:
        return '$n $tipo';
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: SyncEngine.instance.statusStream,
      initialData: const SyncStatus(),
      builder: (ctx, snap) {
        final s = snap.data!;
        Color color;
        String texto;
        bool mostrarDesglose = false;
        switch (s.phase) {
          case SyncPhase.uploading:
            color = Colors.orange;
            texto = s.detalle ?? '⬆️ Subiendo operaciones…';
            break;
          case SyncPhase.downloading:
            color = Colors.orange;
            texto = s.detalle ?? '⬇️ Descargando cambios…';
            break;
          case SyncPhase.photos:
            color = Colors.orange;
            texto = s.detalle ?? '📷 Subiendo fotos…';
            break;
          case SyncPhase.error:
            color = Colors.red;
            texto = s.lastError?.isNotEmpty == true
                ? '⚠️ ${s.lastError}'
                : '⚠️ Error de sincronización';
            break;
          case SyncPhase.idle:
            if (s.pending > 0) {
              color = Colors.amber.shade700;
              texto = '⏳ ${s.pending} por subir';
              mostrarDesglose = true;
            } else {
              color = Colors.green;
              texto = '✅ Sincronizado';
            }
            break;
        }
        final enProgreso = s.phase == SyncPhase.uploading ||
            s.phase == SyncPhase.downloading ||
            s.phase == SyncPhase.photos;
        return InkWell(
          onTap: () => SyncEngine.instance.run(),
          child: Container(
            width: double.infinity,
            color: color,
            padding:
                const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                mostrarDesglose
                    ? FutureBuilder<Map<String, int>>(
                        future:
                            LocalDb.instance.pendingByType(),
                        builder: (c2, s2) {
                          final det = (s2.data ?? {})
                              .entries
                              .map((e) =>
                                  _etiqueta(e.key, e.value))
                              .join(' · ');
                          return Text(
                              det.isEmpty
                                  ? texto
                                  : '$texto: $det',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12),
                              textAlign: TextAlign.center);
                        },
                      )
                    : Text(texto,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        textAlign: TextAlign.center),
                if (enProgreso)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(
                      value: s.progreso,
                      backgroundColor: Colors.white30,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(
                              Colors.white),
                      minHeight: 4,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class Campo extends StatelessWidget {
  final TextEditingController ctrl;
  final String etiqueta;
  final TextInputType teclado;
  final List<TextInputFormatter>? formato;
  const Campo(
      {super.key,
      required this.ctrl,
      required this.etiqueta,
      this.teclado = TextInputType.text,
      this.formato});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctrl,
        keyboardType: teclado,
        inputFormatters: formato,
        decoration: InputDecoration(
            labelText: etiqueta, border: const OutlineInputBorder()),
      ),
    );
  }
}

Future<void> copiar(BuildContext context, String texto) async {
  await Clipboard.setData(ClipboardData(text: texto));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copiado')));
  }
}
