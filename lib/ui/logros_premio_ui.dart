/// 1.28 (M5-C4): la cara visual de cada logro de Premios
/// en Gestión — icono por familia y medalla con gradiente.
/// El NOMBRE humano vive en premios_panel.dart
/// (nombresLogrosPremio); aquí solo el dibujo, para que
/// la bandeja, el historial y el sello de medallas del
/// cliente enseñen el mismo logro con la misma cara.
library;

import 'package:flutter/material.dart';

import '../premios_panel.dart';
import 'diseno.dart';

/// Icono de un logro por su id (acepta las claves del
/// sello con sufijo «@<mes>»: se resuelve por la base).
IconData iconoLogroPremio(String logroId) {
  switch (logroBasePremio(logroId)) {
    // Constancia: fuego.
    case 'primer_paso':
    case 'semana_completa':
    case 'imparable':
    case 'leyenda':
    case 'constancia_real':
      return Icons.local_fire_department_rounded;
    // Sesiones acumuladas.
    case 'sesiones_hito':
    case 'veterano':
      return Icons.fitness_center_rounded;
    // Volumen total levantado.
    case 'toneladas':
      return Icons.monitor_weight_rounded;
    // Horario del entreno.
    case 'mananero':
    case 'madrugador':
      return Icons.wb_sunny_rounded;
    case 'dueno_tarde':
      return Icons.wb_twilight_rounded;
    case 'nocturno':
      return Icons.nightlight_round;
    // Conocer el cuerpo.
    case 'primera_medicion':
      return Icons.straighten_rounded;
    case 'control_total':
      return Icons.monitor_heart_rounded;
    // Marcas de fuerza (el Club 100 es trofeo).
    case 'primera_marca':
    case 'cinco_marcas':
      return Icons.military_tech_rounded;
    case 'club100_press':
    case 'club100_sentadilla':
    case 'club100_muerto':
      return Icons.emoji_events_rounded;
    // Explorar y planificar.
    case 'diez_ejercicios':
      return Icons.explore_rounded;
    case 'primera_rutina':
      return Icons.event_note_rounded;
    case 'arquitecto':
      return Icons.architecture_rounded;
    case 'semana_planificada':
      return Icons.calendar_month_rounded;
    case 'alumno_gym':
      return Icons.school_rounded;
    // Secretos: se descubren, no se anuncian.
    case 'secreto_alba':
    case 'secreto_trasnochador':
      return Icons.visibility_off_rounded;
    // El reto del mes.
    case 'reto_del_mes':
      return Icons.flag_rounded;
    case 'manual':
      return Icons.card_giftcard_rounded;
    default:
      return Icons.emoji_events_rounded;
  }
}

/// Medalla circular con el gradiente de la casa y el
/// icono del logro en blanco: la misma pieza en la
/// bandeja, el historial y el sello del cliente.
class MedallaLogroPremio extends StatelessWidget {
  final String logroId;
  final double tamano;

  const MedallaLogroPremio({
    super.key,
    required this.logroId,
    this.tamano = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: tamano,
      height: tamano,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColores.naranja, AppColores.naranjaOscuro],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColores.naranja.withValues(alpha: 0.30),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Icon(iconoLogroPremio(logroId),
          color: Colors.white, size: tamano * 0.55),
    );
  }
}
