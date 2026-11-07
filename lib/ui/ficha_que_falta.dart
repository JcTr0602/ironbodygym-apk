// lib/ui/ficha_que_falta.dart
// 1.28 (M4-B4): «qué le falta» a este cliente, en una línea
// de pendientes ACCIONABLES bajo la cabecera de su ficha:
// sin foto · teléfono no válido · sin acceso a la app ·
// sin medición en 60 días. Cada chip lleva a la acción que
// lo resuelve (cambiar la foto, editar, la sección de
// acceso, Progreso). Hoy cada hueco vive en su sección y
// se descubre tarde (el PIN que viajó al número equivocado
// de A8 nació de un dato que nadie vio raro).
//
// Honestidad ante todo: un pendiente solo se afirma con el
// dato VERIFICADO. El acceso se lee del caché de accesos
// (solo el dueño puede cargarlo); mientras no está
// verificado, ese pendiente NO se pinta — la sección
// «Acceso App» de abajo es la que dice la verdad en vivo.
// El widget tiene estado propio (patrón de la ficha
// perezosa): verifica el acceso por su cuenta y se repinta
// solo, sin reconstruir la pantalla entera.
import 'package:flutter/material.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Pendientes posibles de la ficha (B4).
enum PendienteFicha {
  sinFoto,
  telefonoInvalido,
  sinAccesoApp,
  sinMedicionReciente,
}

/// PURO: los pendientes de un cliente según los datos que
/// la ficha ya conoce. [tieneAccesoApp] null = no
/// verificado: el pendiente de acceso NO se afirma.
/// [ultimaMedicionEn] null = nunca se midió: también es
/// pendiente. La ventana son 60 días de CALENDARIO (la
/// comparación se hace por días UTC, sin que el cambio de
/// hora robe o regale un día).
List<PendienteFicha> pendientesDeFicha({
  required bool tieneFoto,
  required bool telefonoValido,
  required bool? tieneAccesoApp,
  required DateTime? ultimaMedicionEn,
  required DateTime hoy,
  int diasSinMedicion = 60,
}) {
  final r = <PendienteFicha>[];
  if (!tieneFoto) r.add(PendienteFicha.sinFoto);
  if (!telefonoValido) r.add(PendienteFicha.telefonoInvalido);
  if (tieneAccesoApp == false) r.add(PendienteFicha.sinAccesoApp);
  if (ultimaMedicionEn == null) {
    r.add(PendienteFicha.sinMedicionReciente);
  } else {
    final hoyUtc =
        DateTime.utc(hoy.year, hoy.month, hoy.day);
    final medUtc = DateTime.utc(ultimaMedicionEn.year,
        ultimaMedicionEn.month, ultimaMedicionEn.day);
    if (hoyUtc.difference(medUtc).inDays > diasSinMedicion) {
      r.add(PendienteFicha.sinMedicionReciente);
    }
  }
  return r;
}

/// Sección «Qué le falta» de la ficha: chips accionables.
/// Sin pendientes verificados, no ocupa espacio.
class SeccionQueFaltaFicha extends StatefulWidget {
  final int clienteId;
  final bool tieneFoto;
  final bool telefonoValido;
  final DateTime? ultimaMedicionEn;

  /// Solo quien puede gestionar el acceso (dueño o permiso
  /// de generar PIN) ve el pendiente de acceso; para los
  /// demás ni se evalúa.
  final bool puedeGestionarAcceso;
  final VoidCallback onFoto;
  final VoidCallback onTelefono;
  final VoidCallback onAcceso;
  final VoidCallback onMedicion;

  const SeccionQueFaltaFicha({
    super.key,
    required this.clienteId,
    required this.tieneFoto,
    required this.telefonoValido,
    required this.ultimaMedicionEn,
    required this.puedeGestionarAcceso,
    required this.onFoto,
    required this.onTelefono,
    required this.onAcceso,
    required this.onMedicion,
  });

  @override
  State<SeccionQueFaltaFicha> createState() =>
      _SeccionQueFaltaFichaState();
}

class _SeccionQueFaltaFichaState extends State<SeccionQueFaltaFicha> {
  @override
  void initState() {
    super.initState();
    // Solo el dueño puede cargar el listado de accesos
    // (RPC solo-dueño): si falta, se pide y la sección se
    // repinta al aterrizar — mismo patrón que la sección
    // «Acceso App». El entrenador no puede verificar: su
    // pendiente de acceso no se afirma desde aquí.
    if (widget.puedeGestionarAcceso &&
        AuthService().isOwner &&
        !AccesoAppCache.instance.cargado) {
      AccesoAppCache.instance.cargar().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  bool? get _tieneAccesoApp {
    if (!widget.puedeGestionarAcceso) return null;
    final cache = AccesoAppCache.instance;
    if (!cache.cargado) return null;
    return cache.obtener(widget.clienteId) != null;
  }

  @override
  Widget build(BuildContext context) {
    final pendientes = pendientesDeFicha(
      tieneFoto: widget.tieneFoto,
      telefonoValido: widget.telefonoValido,
      tieneAccesoApp: _tieneAccesoApp,
      ultimaMedicionEn: widget.ultimaMedicionEn,
      hoy: ahoraHabana(),
    );
    if (pendientes.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.checklist_rounded,
                      size: 18,
                      color: AppColores.textoSecundario(context)),
                  const SizedBox(width: AppEspacio.sm),
                  const Text('Qué le falta',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              Wrap(
                spacing: AppEspacio.sm,
                runSpacing: AppEspacio.sm,
                children: [
                  for (final p in pendientes)
                    ActionChip(
                      avatar: Icon(_icono(p), size: 18),
                      label: Text(_etiqueta(p)),
                      onPressed: _accion(p),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppEspacio.md),
      ],
    );
  }

  IconData _icono(PendienteFicha p) => switch (p) {
        PendienteFicha.sinFoto => Icons.photo_camera_rounded,
        PendienteFicha.telefonoInvalido => Icons.phone_rounded,
        PendienteFicha.sinAccesoApp => Icons.key_rounded,
        PendienteFicha.sinMedicionReciente =>
          Icons.monitor_weight_rounded,
      };

  String _etiqueta(PendienteFicha p) => switch (p) {
        PendienteFicha.sinFoto => 'Sin foto',
        PendienteFicha.telefonoInvalido => 'Teléfono no válido',
        PendienteFicha.sinAccesoApp => 'Sin acceso a la app',
        PendienteFicha.sinMedicionReciente =>
          widget.ultimaMedicionEn == null
              ? 'Sin mediciones'
              : 'Sin medición en 60 días',
      };

  VoidCallback _accion(PendienteFicha p) => switch (p) {
        PendienteFicha.sinFoto => widget.onFoto,
        PendienteFicha.telefonoInvalido => widget.onTelefono,
        PendienteFicha.sinAccesoApp => widget.onAcceso,
        PendienteFicha.sinMedicionReciente => widget.onMedicion,
      };
}
