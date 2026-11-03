/// 1.23 (B3 Paso 2, diseño de Argón): el bloque «Necesita tu
/// atención» del Panel del dueño como FUNCIÓN PURA.
///
/// Antes, las 13 filas se armaban inline en el State de
/// admin.dart, mezcladas con la navegación: imposible probar el
/// orden, los textos y la regla de «primario» sin montar la
/// pantalla entera. Aquí la foto del estado entra por
/// [FotoAtencion] y sale la lista de [PendienteAtencionDato]
/// con un [DestinoAtencion] por fila; admin.dart solo mapea
/// destino → acción (navegar o reintentar la bandeja).
library;

import 'package:flutter/material.dart';

import '../invitados.dart' as invitados_svc;
import '../negocio.dart';
import '../plus_reportes.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'diseno.dart';
import 'panel_dueno_swr.dart';

/// A dónde lleva tocar una fila de atención (o qué reintenta).
enum DestinoAtencion {
  solicitudes,
  reintentarSolicitudes,
  reservas,
  reportes,
  reintentarReportes,
  arqueo,
  cierre,
  incidencias,
  diagnostico,
  suplementos,
}

/// Una fila del bloque de atención, ya redactada y sin acción:
/// la acción la resuelve el panel según [destino].
class PendienteAtencionDato {
  final DestinoAtencion destino;
  final IconData icono;
  final Color tinte;
  final String titulo;
  final String detalle;
  final String boton;
  final bool primario;

  const PendienteAtencionDato({
    required this.destino,
    required this.icono,
    required this.tinte,
    required this.titulo,
    required this.detalle,
    required this.boton,
    required this.primario,
  });
}

/// La foto del estado del panel que alimenta el bloque.
class FotoAtencion {
  final BandejaSwr<invitados_svc.InvitadoResumen> solicitudes;
  final BandejaSwr<ReportePlus> reportes;
  final List<Map<String, dynamic>> reservasSolicitadas;
  final Map<String, String> nombreSupl;
  final List<Map<String, dynamic>> pendienteEntrenadores;
  final List<String> sinReporteAyer;
  final List<String> sinReporteHoy;
  final int incidenciasPend;
  final String? syncError;
  final List<Map<String, dynamic>> stockCritico;

  const FotoAtencion({
    required this.solicitudes,
    required this.reportes,
    required this.reservasSolicitadas,
    required this.nombreSupl,
    required this.pendienteEntrenadores,
    required this.sinReporteAyer,
    required this.sinReporteHoy,
    required this.incidenciasPend,
    required this.syncError,
    required this.stockCritico,
  });
}

/// Deriva las filas de atención en su orden canónico. Las
/// reglas (incluidas las de Argón para el SWR: «sin cargar» se
/// mide por el sello, jamás se afirma «todo en orden» sobre un
/// fallo) viven aquí y solo aquí.
List<PendienteAtencionDato> pendientesAtencion(FotoAtencion f) {
  final pendientes = <PendienteAtencionDato>[];

  // Solicitudes de inscripción de invitados (pedido de Jc,
  // 2026-10-22): decisión del dueño con acción en 1 toque; el
  // botón abre la bandeja YA filtrada en solicitudes. Misma
  // fuente que la pantalla de Invitados (InvitadosService).
  if (f.solicitudes.datos.isNotEmpty) {
    final n = f.solicitudes.datos.length;
    final s = f.solicitudes.datos.first;
    var detalle = s.nombre;
    if (s.solicitudDesde != null) {
      detalle += ' · ${hace(s.solicitudDesde)}';
    }
    // B3: si son caché por fallo de red, se dice con su hora.
    if (f.solicitudes.notaSinRed.isNotEmpty) {
      detalle += ' · ${f.solicitudes.notaSinRed}';
    }
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.solicitudes,
      icono: Icons.mark_email_unread_rounded,
      tinte: AppColores.naranja,
      titulo: n == 1
          ? '1 solicitud de inscripción por atender'
          : '$n solicitudes de inscripción por atender',
      detalle: detalle,
      boton: 'Atender',
      primario: true,
    ));
  }

  // B3: fallo de red SIN caché — la bandeja se declara sin
  // cargar, con reintento; jamás «todo en orden» a ciegas.
  // (Panel B3: «sin caché» se mide por el sello — un éxito
  // vacío anterior ES caché, no ausencia de carga.)
  if (f.solicitudes.sinCargar) {
    pendientes.add(const PendienteAtencionDato(
      destino: DestinoAtencion.reintentarSolicitudes,
      icono: Icons.cloud_off_rounded,
      tinte: AppColores.error,
      titulo: 'Solicitudes de inscripción sin cargar',
      detalle: 'Sin conexión para consultar la bandeja',
      boton: 'Reintentar',
      primario: true,
    ));
  }

  // B3: vacío confirmado que no se pudo revalidar — no se
  // afirma «todo en orden» sin decir que el dato es de antes.
  if (f.solicitudes.vacioSinRevalidar) {
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.reintentarSolicitudes,
      icono: Icons.cloud_off_rounded,
      tinte: AppColores.alerta,
      titulo: 'Solicitudes sin revalidar',
      detalle: f.solicitudes.notaSinRed,
      boton: 'Reintentar',
      primario: false,
    ));
  }

  // Reservas por confirmar (bandeja FIFO; la primera manda el detalle).
  if (f.reservasSolicitadas.isNotEmpty) {
    final n = f.reservasSolicitadas.length;
    final r = f.reservasSolicitadas.first;
    final nombreSupl = f.nombreSupl['${r['suplemento_id']}'] ?? 'Suplemento';
    var detalle = '$nombreSupl ×${(r['cantidad'] as num?)?.toInt() ?? 1}';
    final exp = r['expira_en'] as String?;
    if (exp != null && exp.isNotEmpty) {
      detalle += ' · vence ${fmtFecha(exp)}';
    }
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.reservas,
      icono: Icons.inventory_2_rounded,
      tinte: AppColores.naranja,
      titulo: n == 1 ? '1 reserva por confirmar' : '$n reservas por confirmar',
      detalle: detalle,
      boton: 'Revisar',
      // Botón lleno solo si es la primera fila (sin solicitudes
      // y ya sin su carga en curso).
      primario: f.solicitudes.datos.isEmpty &&
          !f.solicitudes.cargando &&
          !f.solicitudes.error,
    ));
  }

  // G2 (v1.7.0): reportes de pago App Plus por confirmar. Solo
  // aparece con pendientes CONOCIDOS. 1.23 (B3): con caché de
  // un éxito anterior, un fallo de red ya no la hace
  // desaparecer: se pinta con la nota «Sin red · datos de…».
  if (f.reportes.datos.isNotEmpty) {
    final n = f.reportes.datos.length;
    final r = f.reportes.datos.first;
    var detalle = '${r.nombre} · ${fmtMonto(r.monto)} CUP · '
        'ref. ${r.referencia}';
    if (f.reportes.notaSinRed.isNotEmpty) {
      detalle += ' · ${f.reportes.notaSinRed}';
    }
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.reportes,
      icono: Icons.star_rounded,
      tinte: AppColores.naranja,
      titulo: n == 1
          ? '1 reporte App Plus por confirmar'
          : '$n reportes App Plus por confirmar',
      detalle: detalle,
      boton: 'Revisar',
      primario: false,
    ));
  }

  // B3: fallo de red sin caché en la bandeja del Plus.
  if (f.reportes.sinCargar) {
    pendientes.add(const PendienteAtencionDato(
      destino: DestinoAtencion.reintentarReportes,
      icono: Icons.cloud_off_rounded,
      tinte: AppColores.error,
      titulo: 'Reportes App Plus sin cargar',
      detalle: 'Sin conexión para consultar la bandeja',
      boton: 'Reintentar',
      primario: false,
    ));
  }

  // B3: vacío del Plus confirmado sin revalidar.
  if (f.reportes.vacioSinRevalidar) {
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.reintentarReportes,
      icono: Icons.cloud_off_rounded,
      tinte: AppColores.alerta,
      titulo: 'Reportes App Plus sin revalidar',
      detalle: f.reportes.notaSinRed,
      boton: 'Reintentar',
      primario: false,
    ));
  }

  // Efectivo por liquidar (pendiente a entregar, por entrenador).
  final pendTotal = f.pendienteEntrenadores
      .fold<double>(0, (s, e) => s + (e['total'] as double? ?? 0));
  if (pendTotal > 0) {
    final detalle = [
          for (final t in f.pendienteEntrenadores.take(2))
            '${t['nombre']} \$${fmtMonto(t['total'])}',
        ].join(' · ') +
        (f.pendienteEntrenadores.length > 2 ? ' · …' : '');
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.arqueo,
      icono: Icons.payments_rounded,
      tinte: AppColores.alerta,
      titulo: 'Efectivo por liquidar',
      detalle: detalle,
      boton: 'Arqueo',
      primario: false,
    ));
  }

  // Cierre de caja pendiente: ayer ya es exigible completo;
  // hoy solo tras el cierre + gracia (regla de turnosSinReporte).
  if (f.sinReporteAyer.isNotEmpty) {
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.cierre,
      icono: Icons.task_alt_rounded,
      tinte: AppColores.info,
      titulo: 'Cierre de caja pendiente',
      detalle: 'Ayer · turno ${f.sinReporteAyer.join(' y ')}',
      boton: 'Cerrar',
      primario: false,
    ));
  }
  if (f.sinReporteHoy.isNotEmpty) {
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.cierre,
      icono: Icons.task_alt_rounded,
      tinte: AppColores.info,
      titulo: 'Sin reporte de caja',
      detalle: 'Hoy · turno ${f.sinReporteHoy.join(' y ')}',
      boton: 'Cerrar',
      primario: false,
    ));
  }

  // Incidencias de sync por revisar (aprobar/descartar, solo dueño).
  if (f.incidenciasPend > 0) {
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.incidencias,
      icono: Icons.sync_problem_rounded,
      tinte: AppColores.error,
      titulo: f.incidenciasPend == 1
          ? '1 incidencia de sync por revisar'
          : '${f.incidenciasPend} incidencias de sync por revisar',
      detalle: 'Operaciones rechazadas o en revisión',
      boton: 'Revisar',
      primario: false,
    ));
  }

  // Error de sincronización (último error, en lenguaje común).
  if (f.syncError != null && f.syncError!.isNotEmpty) {
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.diagnostico,
      icono: Icons.error_outline_rounded,
      tinte: AppColores.error,
      titulo: 'Problema de sincronización',
      detalle: errorSyncLegible(f.syncError!),
      boton: 'Ver',
      primario: false,
    ));
  }

  // Stock crítico (mismo criterio que el chip de Suplementos).
  if (f.stockCritico.isNotEmpty) {
    final s = f.stockCritico.first;
    final stock = (s['stock'] as num?)?.toInt() ?? 0;
    pendientes.add(PendienteAtencionDato(
      destino: DestinoAtencion.suplementos,
      icono: Icons.warning_amber_rounded,
      tinte: AppColores.alerta,
      titulo: 'Stock crítico',
      detalle: f.stockCritico.length == 1
          ? '${s['nombre']} · queda $stock'
          : '${f.stockCritico.length} productos bajo el mínimo · '
              '${s['nombre']} queda $stock',
      boton: 'Ver',
      primario: false,
    ));
  }

  return pendientes;
}
