// lib/ui/turnos_hub.dart
// v1.6.0 (pedido de Jc): UNA sola puerta para los turnos.
//
// Antes había dos entradas separadas y confusas — «Entrenadores
// por turno» (dentro de Horario del Gym) y «Turnos manuales»
// (acción de Usuarios) — y no se sabía cuál mandaba. Este hub las
// agrupa con etiquetas de tarea y la línea de precedencia visible.
// NO fusiona las pantallas ni toca su lógica ni su guardado: solo
// navegación, etiquetas y la explicación de qué manda.
import 'package:flutter/material.dart';

import '../auth.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'horario_turnos.dart';
import 'turnos_manuales.dart';

class TurnosHubScreen extends StatelessWidget {
  const TurnosHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Gate propio (defensa en profundidad, mismo patrón que
    // ControlAccesoScreen): la programación de turnos es del dueño
    // aunque se llegue al hub por cualquier ruta.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Turnos')),
        body: const Center(
          child: Text('Solo el dueño puede gestionar los turnos.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Turnos')),
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
                    'muestra a ese. El ajuste por fecha corrige lo '
                    'programado para un día concreto; el plan '
                    'semanal es la base que se repite.',
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
            'Plan semanal',
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
            'Ajustes por fecha',
            'Excepciones para un día concreto (intercambios, '
                'ausencias): corrigen lo programado de ese día.',
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const TurnosManualesScreen(),
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
