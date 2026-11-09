import 'package:flutter/material.dart';
import '../../../modelos/incidencia.dart';
import '../../componentes.dart';
import '../../diseno.dart';

/// Tarjeta de incidencia con SLA visual, prioridad y estado.
/// v1.3.0
/// 1.30 D5 (UI130-19): la tarjeta adopta la anatomía común
/// [TarjetaDecision] que comparte con la cola de incidencias
/// de sincronización: cabecera (icono del tipo + título +
/// chip de estado del vocabulario), contexto (SLA +
/// responsable) y prioridad como punto + palabra. Salen la
/// insignia artesanal y los bordes de acento hechos a mano
/// (la selección se lee por el fondo, como en el resto de
/// listas); el significado y las acciones no cambian.
class TarjetaIncidencia extends StatelessWidget {
  final Incidencia incidencia;
  final TipoIncidencia? tipo;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool seleccionada;

  const TarjetaIncidencia({
    super.key,
    required this.incidencia,
    this.tipo,
    required this.onTap,
    this.onLongPress,
    this.seleccionada = false,
  });

  Color _colorPrioridad(BuildContext context) {
    switch (incidencia.prioridad) {
      case 'alta':
        return AppColores.error;
      case 'media':
        return AppColores.alerta;
      default:
        return AppColores.textoSecundario(context);
    }
  }

  SignificadoChip get _significadoEstado {
    switch (incidencia.estado) {
      case 'pendiente':
        return SignificadoChip.alerta;
      case 'en_proceso':
        return SignificadoChip.info;
      case 'bloqueada':
        return SignificadoChip.error;
      case 'resuelta':
        return SignificadoChip.exito;
      default:
        return SignificadoChip.neutral;
    }
  }

  String get _etiquetaEstado {
    switch (incidencia.estado) {
      case 'pendiente':
        return 'Pendiente';
      case 'en_proceso':
        return 'En proceso';
      case 'bloqueada':
        return 'Bloqueada';
      case 'resuelta':
        return 'Resuelta';
      default:
        return incidencia.estado;
    }
  }

  /// v1.3.3: nombre del responsable desde el formato compuesto
  /// 'entrenador:<username>:<Nombre>' | 'cliente:<id>:<Nombre>'.
  /// Usa skip(2).join(':') por seguridad (el nombre podría llevar ':').
  String? get _nombreResponsable {
    final a = incidencia.asignadoA;
    if (a == null || a.isEmpty) return null;
    final partes = a.split(':');
    if (partes.length < 3) return null;
    final nombre = partes.skip(2).join(':').trim();
    return nombre.isEmpty ? null : nombre;
  }

  @override
  Widget build(BuildContext context) {
    final dias = incidencia.diasAbierta;
    final slaTexto = incidencia.estaResuelta
        ? 'Resuelta en $dias día${dias == 1 ? '' : 's'}'
        : dias == 0
            ? 'Hoy'
            : 'Lleva $dias día${dias == 1 ? '' : 's'}';

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.xs),
      child: TarjetaDecision(
        // Sin tipo conocido, el icono genérico del modelo.
        icono: tipo?.iconoData ?? Icons.label_rounded,
        colorIcono: tipo?.colorData,
        titulo: incidencia.descripcion,
        subtitulo: (tipo != null || incidencia.ubicacion != null)
            ? [
                if (tipo != null) tipo!.nombre,
                if (incidencia.ubicacion != null)
                  '📍 ${incidencia.ubicacion}',
              ].join(' · ')
            : null,
        chipEstado: ChipEstado.semantico(
          texto: _etiquetaEstado,
          significado: _significadoEstado,
        ),
        contexto: slaTexto,
        iconoContexto: Icons.schedule_rounded,
        colorContexto: incidencia.vencida ? AppColores.error : null,
        contextoDestacado: incidencia.vencida,
        contextoSecundario: _nombreResponsable != null
            ? '👤 $_nombreResponsable'
            : null,
        iconoContextoSecundario: Icons.person_rounded,
        prioridadTexto: _etiquetaPrioridad(incidencia.prioridad),
        colorPrioridad: _colorPrioridad(context),
        onTap: onTap,
        onLongPress: onLongPress,
        seleccionada: seleccionada,
      ),
    );
  }
}

/// Fix #24 (Sol): etiqueta segura para prioridad.
/// Evita RangeError con strings vacíos.
String _etiquetaPrioridad(String p) {
  const mapa = {
    'alta': 'Alta',
    'media': 'Media',
    'baja': 'Baja',
  };
  final v = mapa[p.toLowerCase()];
  if (v != null) return v;
  if (p.isEmpty) return 'Sin prioridad';
  return p[0].toUpperCase() + p.substring(1);
}
