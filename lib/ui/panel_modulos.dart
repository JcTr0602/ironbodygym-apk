/// 1.28 (M5-C1 ★ ÍTEM FIJO): los 6 módulos del Panel con
/// sus NOMBRES CORTOS definitivos — «Caja y dinero»,
/// «Clientes e invitados», «Equipo y turnos»,
/// «Suplementos y contenido», «Configuración y datos» y
/// «Control y sistema». Decisión tomada: los módulos NO
/// se fusionan y ni las tarjetas ni los contadores se
/// mueven; solo cambian los títulos, y cada módulo
/// estrena ICONO y COLOR de identidad propios y una
/// LÍNEA DE ESTADO VIVA bajo el título (la cifra que
/// importa de ese módulo, derivada de la foto ya
/// cargada — no el catálogo estático de contenidos).
///
/// La lista de descriptores es una función PURA de los
/// conteos: la pantalla la pinta y los tests la
/// verifican sin montar el Panel entero.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../negocio.dart' show fmtMonto;
import 'componentes.dart';
import 'diseno.dart';
import 'panel_por_revisar.dart';

/// Un módulo del Panel: identidad + estado vivo +
/// contador (badge) en su sitio de siempre.
class DatoModuloPanel {
  final IconData icono;
  final Color tinte;
  final String titulo;
  final String estado;
  final int? badge;

  const DatoModuloPanel({
    required this.icono,
    required this.tinte,
    required this.titulo,
    required this.estado,
    required this.badge,
  });
}

String _conteo(int n, String uno, String varios) =>
    n == 1 ? '1 $uno' : '$n $varios';

/// Los 6 módulos, en su orden, con el badge de cada
/// contador EN SU MÓDULO (el de Caja sigue siendo
/// «entrenadores por liquidar»; el de Clientes suma
/// solicitudes + reportes + vales de Premios por
/// aprobar — M5-B2 —; el de Equipo, los cierres sin
/// reporte de hoy y ayer; el de Suplementos, las
/// reservas; el de Configuración, los precios sin
/// fijar; el de Control, las incidencias).
///
/// 1.29 (Oleada 5, D-23): los conteos ya no llegan como
/// enteros sueltos: llegan las LISTAS de ítems de
/// `pendientesPorModulo` (panel_por_revisar.dart) y cada
/// badge es `ítems.length` POR CONSTRUCCIÓN — el mismo
/// número que la franja «POR REVISAR» del módulo lista
/// al entrar. Las líneas de estado se derivan de esas
/// mismas listas.
List<DatoModuloPanel> modulosPanel({
  required Map<ModuloPanel, List<ItemPorRevisar>> items,
  required double pendCajaTotal,
  required double cajaHoyTotal,
  required int clientesActivos,
  required int stockCritico,
  required int pendientesSubir,
}) {
  int n(ModuloPanel m) => items[m]?.length ?? 0;
  int nDestino(ModuloPanel m, DestinoPorRevisar d) =>
      (items[m] ?? const <ItemPorRevisar>[])
          .where((i) => i.destino == d)
          .length;
  final pendCaja = n(ModuloPanel.caja);
  final valesPorAprobar =
      nDestino(ModuloPanel.clientes, DestinoPorRevisar.valesPremios);
  final sinReporte = n(ModuloPanel.equipo);
  final reservas = n(ModuloPanel.suplementos);
  final preciosSinFijar = n(ModuloPanel.configuracion);
  // GEN-06: las incidencias se cuentan por DESTINO,
  // no por módulo — la lista de Control también trae
  // el ítem de la Cola desde esta oleada.
  final incidencias = nDestino(
      ModuloPanel.control, DestinoPorRevisar.incidenciasSync);
  // 1.30 (Oleada D6, GEN-06): el distintivo de Control
  // suma incidencias + cambios por subir — y «cambios»
  // es el CONTEO de operaciones (el parámetro, que es
  // el mismo número con el que la foto armó su ítem de
  // la Cola), no la presencia del ítem: con 37 cambios
  // el distintivo enseña 37 + incidencias.
  final badgeControl = incidencias + pendientesSubir;
  final badgeClientes = n(ModuloPanel.clientes);
  return [
    DatoModuloPanel(
      icono: Icons.attach_money_rounded,
      // 1.29 D-05/P-07: Caja deja el verde de estado por el
      // dorado de módulo — el verde significa solo «al día».
      tinte: AppColores.moduloCaja,
      titulo: 'Caja y dinero',
      // 1.36 H-C2 (136-855): el estado y el distintivo
      // salen del MISMO conjunto (pendCaja): antes el
      // texto miraba los totales y el distintivo el
      // conteo, y podían discrepar.
      estado: cajaHoyTotal > 0 || pendCaja > 0
          ? 'Hoy \$${fmtMonto(cajaHoyTotal)} cobrado'
              '${pendCaja > 0 ? ' · \$${fmtMonto(pendCajaTotal)} por liquidar' : ''}'
          : 'Sin cobros registrados hoy',
      badge: pendCaja > 0 ? pendCaja : null,
    ),
    DatoModuloPanel(
      icono: Icons.people_rounded,
      tinte: AppColores.moduloClientes,
      titulo: 'Clientes e invitados',
      estado: '$clientesActivos clientes activos'
          '${valesPorAprobar > 0 ? ' · ${_conteo(valesPorAprobar, 'vale por aprobar', 'vales por aprobar')}' : ''}',
      badge: badgeClientes > 0 ? badgeClientes : null,
    ),
    DatoModuloPanel(
      icono: Icons.groups_rounded,
      tinte: AppColores.moduloEquipo,
      titulo: 'Equipo y turnos',
      estado: sinReporte > 0
          ? _conteo(sinReporte, 'cierre sin reporte',
              'cierres sin reporte')
          : 'Cierres de turno al día',
      badge: sinReporte > 0 ? sinReporte : null,
    ),
    DatoModuloPanel(
      icono: Icons.inventory_2_rounded,
      tinte: AppColores.moduloSuplementos,
      titulo: 'Suplementos y contenido',
      estado: [
        if (reservas > 0)
          _conteo(reservas, 'reserva por confirmar',
              'reservas por confirmar'),
        if (stockCritico > 0)
          _conteo(stockCritico, 'producto en stock crítico',
              'productos en stock crítico'),
      ].join(' · ').ifEmpty('Reservas y stock al día'),
      // 136-855: el distintivo suma el mismo conjunto
      // que el texto enseña (reservas + stock crítico).
      badge: (reservas + stockCritico) > 0
          ? reservas + stockCritico
          : null,
    ),
    DatoModuloPanel(
      // El icono pasa de «precios» a «ajustes»: el
      // módulo ya no se llama «Precios…» y su identidad
      // es la configuración (decisión de la oleada,
      // a revisión de Argón).
      icono: Icons.settings_rounded,
      tinte: AppColores.moduloConfiguracion,
      titulo: 'Configuración y datos',
      estado: preciosSinFijar > 0
          ? _conteo(preciosSinFijar, 'precio sin fijar',
              'precios sin fijar')
          : 'Precios y ajustes al día',
      badge: preciosSinFijar > 0 ? preciosSinFijar : null,
    ),
    DatoModuloPanel(
      icono: Icons.bar_chart_rounded,
      tinte: AppColores.moduloControl,
      titulo: 'Control y sistema',
      // G09-5 (desbloqueo lote 141): la línea de Control ya
      // no dice la sync — fuera el «N cambio(s) por subir»
      // (la sync se dice una sola vez, con el icono de
      // cabecera, como en el resto del Panel). El distintivo
      // sigue sumando incidencias + cambios (es contador de
      // Por Revisar, no línea de estado de sync).
      estado: incidencias > 0
          ? _conteo(incidencias, 'incidencia por revisar',
              'incidencias por revisar')
          : 'Sistema al día',
      badge: badgeControl > 0 ? badgeControl : null,
    ),
  ];
}

extension on String {
  String ifEmpty(String otro) => isEmpty ? otro : this;
}

/// La pastilla del contador de un módulo. Con [pulso],
/// late tres veces al montarse (el contador SUBIÓ
/// desde la última visita al Panel); respeta «reducir
/// movimiento».
class BadgeModuloPanel extends StatelessWidget {
  final int valor;
  final bool pulso;

  const BadgeModuloPanel({
    super.key,
    required this.valor,
    this.pulso = false,
  });

  @override
  Widget build(BuildContext context) {
    // La pastilla del contador, ahora sobre errorFondo
    // (1.29 D-05): el blanco sobre el error brillante daba
    // 3,76:1 y fallaba AA a 11 sp; sobre errorFondo da 6,54:1.
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColores.errorFondo,
        borderRadius: BorderRadius.circular(AppRadio.circular),
      ),
      child: Text(
        '$valor',
        style: AppTexto.minuscula
            .copyWith(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
    if (!pulso || MediaQuery.of(context).disableAnimations) {
      return chip;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      // 1.35 (UI-13): período del pulso de énfasis, no una
      // transición: fuera de los tokens a propósito.
      duration: const Duration(milliseconds: 1350),
      builder: (context, t, child) {
        final escala = 1 + 0.18 * math.sin(t * math.pi * 3).abs();
        return Transform.scale(scale: escala, child: child);
      },
      child: chip,
    );
  }
}

/// La fila de un módulo en la lista del Panel (y, con el
/// mismo dato, la cabecera de su pantalla): pastilla de
/// icono en su color, título corto, línea de estado
/// viva, contador y chevron.
class FilaModuloPanel extends StatelessWidget {
  final DatoModuloPanel dato;
  final bool pulso;
  final VoidCallback onTap;

  const FilaModuloPanel({
    super.key,
    required this.dato,
    this.pulso = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      // (1.36 H-B4 136-891) ripple y foco delimitados.
      borderRadius: BorderRadius.circular(AppRadio.md),
      splashColor: AppColores.naranja.withValues(alpha: 0.10),
      highlightColor: AppColores.naranja.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: AppEspacio.md),
        child: Row(
          children: [
            IconoModuloBadge(
              icono: dato.icono,
              tinte: dato.tinte,
              iconoOscuro: dato.tinte,
              iconoClaro: dato.tinte,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dato.titulo, style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    dato.estado,
                    style: AppTexto.secundario,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (dato.badge != null) ...[
              BadgeModuloPanel(valor: dato.badge!, pulso: pulso),
              const SizedBox(width: 8),
            ],
            Icon(Icons.chevron_right_rounded,
                color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }
}

/// 1.29 (Oleada 5, D-23): la franja «POR REVISAR» que
/// abre la pantalla de un módulo: una fila por ítem de
/// la MISMA lista de la que salió el distintivo del
/// módulo, cada una con su título, su detalle y su
/// destino al tacto. Sin ítems no pinta nada: la
/// pantalla del módulo queda como siempre.
class FranjaPorRevisar extends StatelessWidget {
  final List<ItemPorRevisar> items;
  final void Function(ItemPorRevisar item) onTapItem;

  const FranjaPorRevisar({
    super.key,
    required this.items,
    required this.onTapItem,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Container(
        decoration: BoxDecoration(
          color: AppColores.superficie(context),
          borderRadius: BorderRadius.circular(AppRadio.lg),
          border: Border.all(color: AppColores.borde(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: Text(
                'POR REVISAR',
                // 1.36 (136-306/313): rol cabeceraPanel.
                style: AppTexto.cabeceraPanel.copyWith(
                  color: AppColores.errorTexto(context),
                ),
              ),
            ),
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: AppColores.borde(context)),
              InkWell(
                onTap: () => onTapItem(items[i]),
                // (1.36 H-B4 136-891) ripple/foco delimitados.
                splashColor:
                    AppColores.naranja.withValues(alpha: 0.10),
                highlightColor:
                    AppColores.naranja.withValues(alpha: 0.06),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg,
                      vertical: AppEspacio.md),
                  child: Row(
                    children: [
                      IconoModuloBadge(
                        icono: items[i].icono,
                        tinte: items[i].tinte,
                        iconoOscuro: items[i].tinte,
                        iconoClaro: items[i].tinte,
                        tamanoIcono: 19,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(items[i].titulo,
                                style: AppTexto.subtitulo),
                            const SizedBox(height: 2),
                            Text(items[i].detalle,
                                style: AppTexto.secundario),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          color:
                              AppColores.textoSecundario(context)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppEspacio.xs),
          ],
        ),
      ),
    );
  }
}
