// lib/ui/turnos_hub.dart
// v1.6.0 (pedido de Jc): UNA sola puerta para los turnos.
// v1.8.0: el hub pasa a «Horario y turnos» (Editor único): el
// patrón semanal y el CALENDARIO de excepciones por fecha — los
// antiguos «Turnos manuales» fueron absorbidos como excepciones
// (ajuste horario_excepciones; migración T4 de Argón) y su
// pantalla desaparece.
import 'package:flutter/material.dart';

import '../auth.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'horario_turnos.dart';
import 'turnos_calendario.dart';

class TurnosHubScreen extends StatelessWidget {
  const TurnosHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Gate propio (defensa en profundidad, mismo patrón que
    // ControlAccesoScreen): la programación de turnos es del dueño
    // aunque se llegue al hub por cualquier ruta.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Horario y turnos')),
        body: const Center(
          child: Text('Solo el dueño puede gestionar los turnos.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Horario y turnos')),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          // Línea de precedencia: qué manda, visible en la puerta.
          const Tarjeta(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 20, color: AppColores.info),
                SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                    'La app muestra al entrenador programado desde '
                    'la hora de su turno, haya abierto o no. Si '
                    'abre otro entrenador, hubo un cambio y se '
                    'muestra a ese mientras su turno siga abierto. '
                    'La excepción por fecha corrige lo programado '
                    'para un día concreto; el plan semanal es la '
                    'base que se repite.',
                    style: AppTexto.cuerpo,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppEspacio.md),
          _entrada(
            context,
            Icons.calendar_view_week_rounded,
            'Patrón semanal',
            'Quién trabaja cada día de la semana (mañana y tarde). '
                'Es la base que anuncia la app de clientes.',
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const HorarioTurnosScreen(),
              ),
            ),
          ),
          _entrada(
            context,
            Icons.edit_calendar_rounded,
            'Calendario',
            'Excepciones para un día concreto (intercambios, '
                'ausencias): corrigen lo programado de ese día '
                'sin tocar el patrón.',
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CalendarioTurnosScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entrada(BuildContext context, IconData icono, String titulo,
      String resumen, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        onTap: onTap,
        child: Row(
          children: [
            IconoModuloBadge.naranja(icono),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo, style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    resumen,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColores.textoSecundario(context)),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }
}
