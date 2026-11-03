/// 1.22 Diseño Bloque 2 Paso 1 (mandato de Argón):
/// secciones de la Ficha extraídas como vistas tontas —
/// reciben datos inmutables (y callbacks donde aplica) y
/// no tocan estado, controladores ni servicios de
/// escritura. La extracción es PURA: mismo árbol de
/// widgets que los métodos privados originales de
/// FichaScreen; el layout nuevo llega en el Paso 2.
library;

import 'package:flutter/material.dart';

import '../conciliacion.dart';
import '../negocio.dart';
import '../servicios.dart' as servicios_svc;
import '../tiempo.dart';
import 'componentes.dart';
import 'conciliacion.dart';
import 'diseno.dart';
import 'estado_cuenta.dart';

class FilaInfoFicha extends StatelessWidget {
  final IconData icono;
  final String etiqueta;
  final String valor;

  const FilaInfoFicha(
      {super.key,
      required this.icono,
      required this.etiqueta,
      required this.valor});

  @override
  Widget build(BuildContext context) {
    // Etapa 4 · F3: hairline inferior sutil entre filas.
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: AppColores.borde(context)
                  .withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.sm),
      child: Row(
        children: [
          Icon(icono,
              color: AppColores.textoSecundario(context), size: 20),
          const SizedBox(width: AppEspacio.md),
          Expanded(
              child: Text(etiqueta,
                  style: AppTexto.cuerpo)),
          Text(valor,
              style: AppTexto.cuerpo.copyWith(
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.right),
        ],
      ),
    );
  }
}

class BarraMesFicha extends StatelessWidget {
  /// Fecha (cruda) del primer pago del período; null si
  /// no hay pagos.
  final String? fechaInicioRaw;

  /// pagado_hasta crudo del cliente.
  final String? pagadoHastaRaw;

  const BarraMesFicha(
      {super.key, this.fechaInicioRaw, this.pagadoHastaRaw});

  @override
  Widget build(BuildContext context) {
    if (fechaInicioRaw == null) {
      return const SizedBox.shrink();
    }
    final iniRaw = fechaInicioRaw ?? '';
    final finRaw = pagadoHastaRaw ?? '';
    if (iniRaw.length < 10 || finRaw.length < 10) {
      return const SizedBox.shrink();
    }
    final ini = DateTime.tryParse(iniRaw.substring(0, 10));
    final fin = DateTime.tryParse(finRaw.substring(0, 10));
    if (ini == null || fin == null || !fin.isAfter(ini)) {
      return const SizedBox.shrink();
    }
    final hoy = ahoraHabana();
    final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
    final total = fin.difference(ini).inDays;
    var usado = hoyDia.difference(ini).inDays;
    if (usado < 0) usado = 0;
    if (usado > total) usado = total;
    final frac = total == 0 ? 1.0 : usado / total;
    final diasRest = fin.difference(hoyDia).inDays;
    final color = diasRest < 0
        ? AppColores.error
        : diasRest <= 7
            ? AppColores.alerta
            : AppColores.exito;
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor:
                  AppColores.borde(context).withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            diasRest < 0
                ? 'Vencido hace ${-diasRest} día${-diasRest == 1 ? '' : 's'}'
                : diasRest == 0
                    ? 'Vence hoy'
                    : 'Quedan $diasRest días del mes pagado',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }
}

class Resumen360Ficha extends StatelessWidget {
  /// Agregados precalculados por la ficha (D-13).
  final ({int n, double total, String metodoTop}) resumen;

  const Resumen360Ficha({super.key, required this.resumen});

  @override
  Widget build(BuildContext context) {
    // Argón #7B-7: la cortesía (regalo, monto 0) no es un pago ni
    // un método preferido. D-13 (1.21): los agregados vienen
    // precalculados de _cargar (_resumenPagos), no se recorren
    // en cada build.
    final total = resumen.total;
    final metodoTop = resumen.metodoTop;
    return Padding(
      padding:
          const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        color:
            AppColores.naranja.withValues(alpha: 0.08),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                Text('${resumen.n}',
                    style: AppTexto.displayPequeno
                        .copyWith(
                            color:
                                AppColores.naranja)),
                const Text('pagos',
                    style: AppTexto.secundario),
              ],
            ),
            Column(
              children: [
                Text(total.toStringAsFixed(0),
                    style: AppTexto.displayPequeno
                        .copyWith(
                            color:
                                AppColores.naranja)),
                const Text('CUP total',
                    style: AppTexto.secundario),
              ],
            ),
            if (metodoTop.isNotEmpty)
              Column(
                children: [
                  Icon(
                      metodoTop == 'efectivo'
                          ? Icons.payments_rounded
                          : Icons.smartphone_rounded,
                      color: AppColores.textoSecundario(context),
                      size: 28),
                  const Text('prefiere',
                      style: AppTexto.secundario),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class TarjetaHistorialFicha extends StatelessWidget {
  final List<Map<String, dynamic>> entradas;
  final String filtro;
  final ValueChanged<String> onFiltro;
  final List<Map<String, dynamic>> serviciosHist;
  final int clienteId;
  final bool esAdmin;
  final bool esOwner;
  final void Function(Map<String, dynamic>) onReenviarRecibo;
  final void Function(String) onVerComprobante;
  final void Function(Map<String, dynamic>) onCorregirPago;
  final void Function(Map<String, dynamic>) onConciliar;

  const TarjetaHistorialFicha(
      {super.key,
      required this.entradas,
      required this.filtro,
      required this.onFiltro,
      required this.serviciosHist,
      required this.clienteId,
      required this.esAdmin,
      required this.esOwner,
      required this.onReenviarRecibo,
      required this.onVerComprobante,
      required this.onCorregirPago,
      required this.onConciliar});

  @override
  Widget build(BuildContext context) {
    final entradas = this.entradas;
    final visibles = switch (filtro) {
      'pagos' => entradas.where((e) => e['tipo'] == 'pago').toList(),
      'ventas' => entradas.where((e) => e['tipo'] == 'venta').toList(),
      _ => entradas,
    };
    Widget chipFiltro(String valor, String texto) {
      final activo = filtro == valor;
      return ChoiceChip(
        label: Text(texto),
        selected: activo,
        onSelected: (_) => onFiltro(valor),
      );
    }

    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child:
                    Text('Historial', style: AppTexto.titulo),
              ),
              // T24 (1.20): estado de cuenta del cliente.
              IconButton(
                tooltip: 'Estado de cuenta',
                icon: const Icon(
                    Icons.receipt_long_rounded, size: 22),
                onPressed: () => Navigator.push(
                  context,
                  RutaIron(
                    builder: (_) => EstadoCuentaScreen(
                        clienteId: clienteId),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Wrap(
            spacing: 8,
            children: [
              chipFiltro('todo', 'Todo'),
              chipFiltro('pagos', 'Solo pagos'),
              chipFiltro('ventas', 'Solo ventas'),
            ],
          ),
          // v1.8.1 (idea de Jc): acumulado de servicios, solo
          // cuando se ven ventas.
          if (serviciosHist.isNotEmpty && filtro != 'pagos')
            Builder(builder: (_) {
              final r = servicios_svc
                  .resumenServiciosDeCliente(serviciosHist);
              final partes = <String>[
                if (r.dosis > 0) '${r.dosis} dosis',
                if (r.pomos > 0) '${r.pomos} pomos de agua',
                if (r.importe > 0)
                  '${fmtMonto(r.importe)} CUP en compras',
              ];
              if (partes.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Acumulado: ${partes.join(' · ')}',
                  style: AppTexto.secundario,
                ),
              );
            }),
          const SizedBox(height: AppEspacio.sm),
          if (visibles.isEmpty)
            const EstadoVacio(
              icono: Icons.history_rounded,
              titulo: 'Sin movimientos en este filtro',
              subtitulo: 'Prueba con otro filtro.',
            ),
          for (var i = 0; i < visibles.length; i++)
            FilaTimelineFicha(
                e: visibles[i],
                esUltima: i == visibles.length - 1,
                esAdmin: esAdmin,
                esOwner: esOwner,
                onReenviarRecibo: onReenviarRecibo,
                onVerComprobante: onVerComprobante,
                onCorregirPago: onCorregirPago,
                onConciliar: onConciliar),
        ],
      ),
    );
  }
}

class FilaTimelineFicha extends StatelessWidget {
  final Map<String, dynamic> e;
  final bool esUltima;
  final bool esAdmin;
  final bool esOwner;
  final void Function(Map<String, dynamic>) onReenviarRecibo;
  final void Function(String) onVerComprobante;
  final void Function(Map<String, dynamic>) onCorregirPago;
  final void Function(Map<String, dynamic>) onConciliar;

  const FilaTimelineFicha(
      {super.key,
      required this.e,
      required this.esUltima,
      required this.esAdmin,
      required this.esOwner,
      required this.onReenviarRecibo,
      required this.onVerComprobante,
      required this.onCorregirPago,
      required this.onConciliar});

  @override
  Widget build(BuildContext context) {
    final color = e['color'] as Color;
    // W8: el recibo se puede reenviar en pagos reales (no
    // en cortesías ni en pagos en cero).
    final pagoFila = e['pago'] as Map<String, dynamic>?;
    final puedeRecibo = e['tipo'] == 'pago' &&
        pagoFila != null &&
        '${pagoFila['metodo'] ?? ''}' != 'cortesia' &&
        ((pagoFila['monto'] as num?) ?? 0) > 0;
    // F1 (1.20): comprobante adjunto a un pago por
    // transferencia (el uuid baja con el espejo del pago).
    final uuidComprobante = (pagoFila != null &&
            '${pagoFila['metodo'] ?? ''}' == 'transferencia')
        ? '${pagoFila['comprobante_uuid'] ?? ''}'
        : '';
    // T4 (1.20): estado de conciliación del pago (solo
    // tiene sentido en transferencias; en el resto da
    // 'no_aplica' y no se muestra nada).
    final estadoConcil = pagoFila == null
        ? 'no_aplica'
        : estadoConciliacion(pagoFila);
    final notaConcil =
        '${pagoFila?['conciliacion_nota'] ?? ''}'.trim();
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(e['icono'] as IconData,
                    size: 18, color: color),
              ),
              if (!esUltima)
                Expanded(
                  child: Container(
                      width: 2, color: AppColores.borde(context)),
                ),
            ],
          ),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Padding(
              padding:
                  EdgeInsets.only(bottom: esUltima ? 0 : AppEspacio.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${e['titulo']}',
                            style: AppTexto.cuerpo),
                      ),
                      Text('${e['trailing'] ?? ''}',
                          style: AppTexto.cuerpo.copyWith(
                              fontWeight: FontWeight.bold,
                              color: AppColores.naranja)),
                      if (puedeRecibo)
                        IconButton(
                          tooltip: 'Reenviar recibo',
                          icon: const Icon(
                              Icons.share_rounded, size: 20),
                          onPressed: () =>
                              onReenviarRecibo(pagoFila),
                        ),
                      if (uuidComprobante.isNotEmpty)
                        IconButton(
                          tooltip: 'Ver comprobante',
                          icon: const Icon(
                              Icons.image_rounded, size: 20),
                          onPressed: () =>
                              onVerComprobante(uuidComprobante),
                        ),
                      if (e['tipo'] == 'pago' &&
                          esAdmin)
                        IconButton(
                          tooltip: 'Corregir pago',
                          icon:
                              const Icon(Icons.tune_rounded, size: 20),
                          onPressed: () => onCorregirPago(
                              e['pago'] as Map<String, dynamic>),
                        ),
                      // T4 (1.20): conciliar la transferencia
                      // (solo el dueño; el servidor lo exige).
                      if (e['tipo'] == 'pago' &&
                          pagoFila != null &&
                          '${pagoFila['metodo'] ?? ''}' ==
                              'transferencia' &&
                          esOwner)
                        IconButton(
                          tooltip: 'Conciliar transferencia',
                          icon: const Icon(
                              Icons.fact_check_rounded, size: 20),
                          onPressed: () =>
                              onConciliar(pagoFila),
                        ),
                    ],
                  ),
                  Text('${e['subtitulo']}',
                      style: AppTexto.secundario),
                  // T4 (1.20): chip de conciliación en pagos
                  // por transferencia (el histórico también se
                  // muestra: señala que nunca se comprobó; la
                  // bandeja del dueño lo excluye).
                  if (e['tipo'] == 'pago' &&
                      pagoFila != null &&
                      '${pagoFila['metodo'] ?? ''}' ==
                          'transferencia') ...[
                    const SizedBox(height: AppEspacio.xs),
                    ChipEstado.semantico(
                      texto: etiquetaConciliacion(estadoConcil),
                      significado:
                          significadoConciliacion(estadoConcil),
                    ),
                    if ((estadoConcil == 'problema' ||
                            estadoConcil == 'rechazada') &&
                        notaConcil.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                            top: AppEspacio.xs),
                        child: Text(
                          'Nota: $notaConcil',
                          style: AppTexto.metadato
                              .copyWith(color: AppColores.error),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
