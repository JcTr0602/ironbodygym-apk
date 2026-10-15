import 'package:flutter/material.dart';
import '../../../modelos/incidencia.dart';
import '../../diseno.dart';

/// Tarjeta de incidencia con SLA visual, prioridad y estado.
/// v1.3.0
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

  Color get _colorPrioridad {
    switch (incidencia.prioridad) {
      case 'alta':
        return Colors.redAccent;
      case 'media':
        return Colors.orangeAccent;
      default:
        return Colors.grey;
    }
  }

  Color get _colorEstado {
    switch (incidencia.estado) {
      case 'pendiente':
        return Colors.orange;
      case 'en_proceso':
        return Colors.blue;
      case 'bloqueada':
        return Colors.red;
      case 'resuelta':
        return Colors.green;
      default:
        return Colors.grey;
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
          horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: seleccionada
                ? Theme.of(context)
                    .colorScheme
                    .primaryContainer
                : AppColores.fondo(context),
            borderRadius:
                BorderRadius.circular(12),
            border: seleccionada
                ? Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .primary,
                    width: 2.5)
                : Border(
                    left: BorderSide(
                      color: _colorPrioridad,
                      width: 3.5,
                    ),
                  ),
          ),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Icono del tipo
                  if (tipo != null)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: tipo!.colorData
                            .withOpacity(0.15),
                        borderRadius:
                            BorderRadius.circular(
                                8),
                      ),
                      child: Icon(
                        tipo!.iconoData,
                        color: tipo!.colorData,
                        size: 20,
                      ),
                    ),
                  if (tipo != null)
                    const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          incidencia.descripcion,
                          maxLines: 2,
                          overflow: TextOverflow
                              .ellipsis,
                          style: const TextStyle(
                            fontWeight:
                                FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        if (tipo != null ||
                            incidencia
                                    .ubicacion !=
                                null)
                          Text(
                            [
                              if (tipo != null)
                                tipo!.nombre,
                              if (incidencia
                                      .ubicacion !=
                                  null)
                                '📍 ${incidencia.ubicacion}',
                            ].join(' · '),
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Colors.grey[500],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Badge de estado
                  Container(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4),
                    decoration: BoxDecoration(
                      color: _colorEstado
                          .withOpacity(0.15),
                      borderRadius:
                          BorderRadius.circular(
                              20),
                    ),
                    child: Text(
                      _etiquetaEstado,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            FontWeight.w600,
                        color: _colorEstado,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // SLA
                  Icon(
                    Icons.schedule,
                    size: 14,
                    color: incidencia.vencida
                        ? Colors.redAccent
                        : Colors.grey[500],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    slaTexto,
                    style: TextStyle(
                      fontSize: 12,
                      color: incidencia.vencida
                          ? Colors.redAccent
                          : Colors.grey[500],
                      fontWeight:
                          incidencia.vencida
                              ? FontWeight.bold
                              : null,
                    ),
                  ),
                  const Spacer(),
                  // Prioridad
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _colorPrioridad,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    // Fix #24 (Sol): mapa seguro, sin [0] directo.
                    _etiquetaPrioridad(
                        incidencia.prioridad),
                    style: const TextStyle(
                        fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
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
