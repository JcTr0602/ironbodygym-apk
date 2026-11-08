/// 1.29 (Oleada 5, D-23) · «POR REVISAR»: la derivación
/// ÚNICA de ítems pendientes por módulo del Panel.
///
/// La queja de campo: los distintivos anunciaban
/// pendientes (Equipo 1, Control 2) pero al entrar no se
/// sabía QUÉ revisar — Equipo sumaba los turnos sin
/// reporte de hoy y de ayer sin decir día ni entrenador,
/// y el ítem de Equipo ni siquiera tenía puerta dentro
/// de su módulo. Aquí cada contador del Panel nace como
/// una LISTA de ítems con título, detalle y destino: el
/// distintivo es `ítems.length` POR CONSTRUCCIÓN (lo
/// calcula `modulosPanel` desde estas listas) y la
/// pantalla del módulo abre con la franja «POR REVISAR»
/// de exactamente esos ítems. Una sola derivación por
/// carga, compartida por distintivo y franja: pueden
/// rezagarse juntos un ciclo de sync, jamás divergir.
///
/// Hermana de `pendientesAtencion`
/// (panel_dueno_atencion.dart, la bandeja raíz, que NO
/// se toca: puede agregar con otra granularidad, nunca
/// divergir en total) y de `modulosPanel`.
library;

import 'package:flutter/material.dart';

import '../negocio.dart' show fmtMonto;
import '../tiempo.dart' show hace;
import 'auditoria.dart' show descripcionOp;
import 'config_precios_bancarios.dart' show etiquetaMonto;
import 'diseno.dart';

/// Los seis módulos del Panel, en su orden de siempre.
enum ModuloPanel {
  caja,
  clientes,
  equipo,
  suplementos,
  configuracion,
  control,
}

/// A dónde lleva un ítem al tocarlo. Lo resuelve
/// admin.dart (como hace con DestinoAtencion).
enum DestinoPorRevisar {
  liquidacion,
  solicitudesInvitados,
  reportesPlus,
  valesPremios,
  cierreCaja,
  reservas,
  precios,
  incidenciasSync,
}

/// Un pendiente concreto y accionable de un módulo:
/// qué es, de quién / desde cuándo, y a dónde ir.
class ItemPorRevisar {
  final ModuloPanel modulo;
  final DestinoPorRevisar destino;
  final IconData icono;
  final Color tinte;
  final String titulo;
  final String detalle;

  const ItemPorRevisar({
    required this.modulo,
    required this.destino,
    required this.icono,
    required this.tinte,
    required this.titulo,
    required this.detalle,
  });
}

/// La foto que alimenta la derivación: solo datos ya
/// cargados por el Panel (espejo local y bandejas SWR),
/// en registros ligeros. Los nombres de Equipo llegan
/// RESUELTOS por quien carga (cruce con el plan de
/// turnos); null = sin asignación, y el ítem enseña
/// solo el día — nunca un nombre inventado.
class FotoPendientesModulos {
  /// Caja: entrenadores con efectivo por entregar (> 0).
  final List<({String nombre, double total})> pendientesLiquidar;

  /// Clientes: solicitudes de invitado por atender.
  final List<({String nombre, DateTime? desde})> solicitudes;

  /// Clientes: reportes de pago App Plus por confirmar.
  final List<({String nombre, double monto, String referencia})>
      reportes;

  /// Clientes: vales de Premios por aprobar.
  final List<({String nombre, int dias})> vales;

  /// Equipo: turnos sin reporte de caja de HOY, por
  /// turno ('mañana'/'tarde'), con el entrenador
  /// asignado si el plan lo resuelve.
  final List<({String turno, String? entrenador})> sinReporteHoy;

  /// Equipo: los de AYER, como fuente SEPARADA (la suma
  /// hoy+ayer era el defecto: destruía el día).
  final List<({String turno, String? entrenador})> sinReporteAyer;

  /// Suplementos: reservas en estado 'solicitada'.
  final List<({String suplemento, String cliente, int cantidad})>
      reservas;

  /// Configuración: claves de precio C6 sin fijar.
  final List<String> preciosSinFijar;

  /// Control: filas pendientes del espejo
  /// incidencias_sync, con el cliente ya resuelto por
  /// quien carga (payload o padrón) cuando se pudo.
  final List<
      ({
        String tipo,
        String? cliente,
        String? dispositivo,
        DateTime? creadaEn
      })> incidencias;

  const FotoPendientesModulos({
    this.pendientesLiquidar = const [],
    this.solicitudes = const [],
    this.reportes = const [],
    this.vales = const [],
    this.sinReporteHoy = const [],
    this.sinReporteAyer = const [],
    this.reservas = const [],
    this.preciosSinFijar = const [],
    this.incidencias = const [],
  });
}

/// Etiquetas de las claves C6 que `clavesMontoConfig`
/// no cubre (su etiquetaMonto caería a la clave cruda).
const _etiquetasPrecioExtra = <String, String>{
  'mensualidad': 'Mensualidad en efectivo',
  'pago_semanal': 'Pago semanal',
  'pago_quincenal': 'Pago quincenal',
};

String _etiquetaPrecio(String clave) =>
    _etiquetasPrecioExtra[clave] ?? etiquetaMonto(clave);

/// PURO (D-23): los ítems por revisar de cada módulo
/// desde la foto. Devuelve SIEMPRE las seis claves
/// (listas vacías incluidas): el distintivo de un
/// módulo es la longitud de SU lista y la franja del
/// módulo pinta ESA lista.
Map<ModuloPanel, List<ItemPorRevisar>> pendientesPorModulo(
    FotoPendientesModulos foto) {
  final caja = <ItemPorRevisar>[
    for (final p in foto.pendientesLiquidar)
      ItemPorRevisar(
        modulo: ModuloPanel.caja,
        destino: DestinoPorRevisar.liquidacion,
        icono: Icons.handshake_rounded,
        tinte: AppColores.moduloCaja,
        titulo: 'Liquidar a ${p.nombre}',
        detalle: '${fmtMonto(p.total)} CUP por entregar',
      ),
  ];

  final clientes = <ItemPorRevisar>[
    for (final s in foto.solicitudes)
      ItemPorRevisar(
        modulo: ModuloPanel.clientes,
        destino: DestinoPorRevisar.solicitudesInvitados,
        icono: Icons.group_rounded,
        tinte: AppColores.moduloClientes,
        titulo: 'Solicitud de ${s.nombre}',
        detalle: s.desde == null
            ? 'Quiere sumarse como invitado'
            : 'Quiere sumarse como invitado · ${hace(s.desde)}',
      ),
    for (final r in foto.reportes)
      ItemPorRevisar(
        modulo: ModuloPanel.clientes,
        destino: DestinoPorRevisar.reportesPlus,
        icono: Icons.star_rounded,
        tinte: AppColores.moduloClientes,
        titulo: 'Reporte Plus de ${r.nombre}',
        detalle: r.referencia.isEmpty
            ? '${fmtMonto(r.monto)} CUP por confirmar'
            : '${fmtMonto(r.monto)} CUP por confirmar · '
                'Ref: ${r.referencia}',
      ),
    for (final v in foto.vales)
      ItemPorRevisar(
        modulo: ModuloPanel.clientes,
        destino: DestinoPorRevisar.valesPremios,
        icono: Icons.emoji_events_rounded,
        tinte: AppColores.moduloClientes,
        titulo: 'Vale de ${v.nombre}',
        detalle: v.dias == 1
            ? 'Premio de 1 día por aprobar'
            : 'Premio de ${v.dias} días por aprobar',
      ),
  ];

  ItemPorRevisar itemSinReporte(
      ({String turno, String? entrenador}) t, String dia) {
    return ItemPorRevisar(
      modulo: ModuloPanel.equipo,
      destino: DestinoPorRevisar.cierreCaja,
      icono: Icons.point_of_sale_rounded,
      tinte: AppColores.moduloEquipo,
      titulo: 'Turno de ${t.turno} sin reporte de caja',
      detalle: t.entrenador == null
          ? dia
          : '$dia · ${t.entrenador}',
    );
  }

  final equipo = <ItemPorRevisar>[
    for (final t in foto.sinReporteHoy) itemSinReporte(t, 'Hoy'),
    for (final t in foto.sinReporteAyer) itemSinReporte(t, 'Ayer'),
  ];

  final suplementos = <ItemPorRevisar>[
    for (final r in foto.reservas)
      ItemPorRevisar(
        modulo: ModuloPanel.suplementos,
        destino: DestinoPorRevisar.reservas,
        icono: Icons.inventory_2_rounded,
        tinte: AppColores.moduloSuplementos,
        titulo: 'Reserva de ${r.suplemento}',
        detalle: '${r.cliente} · ${r.cantidad} uds',
      ),
  ];

  final configuracion = <ItemPorRevisar>[
    for (final clave in foto.preciosSinFijar)
      ItemPorRevisar(
        modulo: ModuloPanel.configuracion,
        destino: DestinoPorRevisar.precios,
        icono: Icons.price_change_rounded,
        tinte: AppColores.moduloConfiguracion,
        titulo: 'Precio sin fijar',
        detalle: _etiquetaPrecio(clave),
      ),
  ];

  final control = <ItemPorRevisar>[
    for (final inc in foto.incidencias)
      ItemPorRevisar(
        modulo: ModuloPanel.control,
        destino: DestinoPorRevisar.incidenciasSync,
        icono: Icons.sync_problem_rounded,
        tinte: AppColores.moduloControl,
        // La misma redacción que la lista de la pantalla
        // destino (descripcionOp sobre el tipo de la op).
        titulo: 'Operación rechazada: ${descripcionOp(inc.tipo)}',
        detalle: [
          if (inc.cliente != null && inc.cliente!.isNotEmpty)
            'Cliente: ${inc.cliente}',
          if (inc.dispositivo != null &&
              inc.dispositivo!.isNotEmpty)
            inc.dispositivo!,
          hace(inc.creadaEn),
        ].join(' · '),
      ),
  ];

  return {
    ModuloPanel.caja: caja,
    ModuloPanel.clientes: clientes,
    ModuloPanel.equipo: equipo,
    ModuloPanel.suplementos: suplementos,
    ModuloPanel.configuracion: configuracion,
    ModuloPanel.control: control,
  };
}
