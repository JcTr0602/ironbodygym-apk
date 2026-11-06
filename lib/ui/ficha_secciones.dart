/// 1.22 Diseño Bloque 2 Paso 1 (mandato de Argón):
/// secciones de la Ficha extraídas como vistas tontas —
/// reciben datos inmutables (y callbacks donde aplica) y
/// no tocan estado, controladores ni servicios de
/// escritura. La extracción es PURA: mismo árbol de
/// widgets que los métodos privados originales de
/// FichaScreen; el layout nuevo llega en el Paso 2.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../conciliacion.dart';
import '../negocio.dart';
import '../servicios.dart' as servicios_svc;
import '../tiempo.dart';
import 'componentes.dart';
import 'conciliacion.dart';
import 'diseno.dart';
import 'estado_cuenta.dart';

/// Diseño Bloque 2 Paso 2 (B1): la cabecera NUEVA de la
/// ficha — foto grande a la izquierda con su anillo de
/// estado, y a la derecha la jerarquía que importa: nombre,
/// insignia de estado (o el distintivo dorado de Casa) y el
/// acceso a cambiar la foto. El botón de cobrar NO va aquí:
/// sigue fijo abajo, siempre visible. Vista tonta: la
/// ficha calcula color/días y pasa los callbacks.
class CabeceraFicha extends StatelessWidget {
  final String nombre;
  final File? foto;

  /// Color del anillo de estado (verde al día, ámbar por
  /// vencer o Casa, rojo vencido) — lo calcula la ficha.
  final Color colorMarco;
  final bool esCasa;

  /// Días restantes (para la insignia; ignorado si esCasa).
  /// null = el cliente nunca pagó (1.25 T04): la insignia
  /// es «SIN PAGOS», nunca «AL DÍA».
  final int? dias;

  /// 1.25 T13: membresía congelada — la insignia manda
  /// («CONGELADO») sobre la de días.
  final bool congelado;
  final String? heroTag;
  final VoidCallback? onFotoTap;
  final VoidCallback onCambiarFoto;

  /// 1.25 T117 (F1-47): sin permiso de editar fichas, el
  /// botón de foto se enseña DESHABILITADO con candado
  /// (regla de Argón para edición secundaria) en vez de
  /// prometer y denegar tras el toque.
  final bool puedeCambiarFoto;

  /// 1.25 T53: fracción transcurrida del período pagado
  /// (0–1) para el anillo de progreso del avatar, que
  /// absorbe la barra del mes. Null = sin período (el
  /// anillo queda el plano del semáforo, como siempre).
  final double? fraccionPeriodo;

  /// 1.25 T53: período en pausa (congelado): el anillo se
  /// pinta en gris, como hacía la barra.
  final bool periodoPausado;

  const CabeceraFicha(
      {super.key,
      required this.nombre,
      required this.foto,
      required this.colorMarco,
      required this.esCasa,
      required this.dias,
      this.congelado = false,
      required this.heroTag,
      required this.onFotoTap,
      required this.onCambiarFoto,
      this.puedeCambiarFoto = true,
      this.fraccionPeriodo,
      this.periodoPausado = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        // 1.25 T54: el degradado se tiñe del color del
        // estado (el marco que la ficha ya calcula): el
        // estado se lee antes que el nombre. Casa conserva
        // su dorado vía colorMarco.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colorMarco.withValues(alpha: 0.13),
            colorMarco.withValues(alpha: 0.0),
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadio.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: onFotoTap,
            child: fraccionPeriodo == null
                ? AvatarCliente(
                    nombre: nombre,
                    foto: foto,
                    tamano: TamanoAvatar.perfil,
                    colorBorde: colorMarco,
                    grosorBorde: 3,
                    heroTag: heroTag,
                  )
                : SizedBox(
                    width: 128,
                    height: 128,
                    // 1.25 T59: el anillo se ANIMA hasta su
                    // valor — al abrir la ficha y, sobre
                    // todo, al volver de un cobro: el arco
                    // crece hasta el nuevo período y la
                    // insignia ya pinta el estado nuevo; es
                    // la confirmación visual de que el cobro
                    // cuajó, sin un diálogo más.
                    child: TweenAnimationBuilder<double>(
                      duration: const Duration(milliseconds: 650),
                      curve: Curves.easeOut,
                      tween: Tween<double>(
                          end: fraccionPeriodo!.clamp(0.0, 1.0)),
                      builder: (context, valor, hijo) => CustomPaint(
                        painter: _AnilloPeriodoPainter(
                          fraccion: valor,
                          color: periodoPausado
                              ? AppColores.bannerGrisB
                              : colorMarco,
                        ),
                        child: hijo,
                      ),
                      child: Center(
                        child: AvatarCliente(
                          nombre: nombre,
                          foto: foto,
                          tamano: TamanoAvatar.perfil,
                          heroTag: heroTag,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nombre,
                    style: AppTexto.displayPequeno,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppEspacio.sm),
                // Argón Clientes #3: con Casa manda el chip
                // dorado; la insignia de días no se pinta.
                if (!esCasa && congelado)
                  const BadgeEstado(
                      estado: EstadoMembresia.congelado,
                      texto: 'CONGELADO')
                else if (!esCasa && dias == null)
                  const BadgeEstado(
                      estado: EstadoMembresia.sinPagos,
                      texto: 'SIN PAGOS')
                else if (!esCasa)
                  BadgeEstado.desdeDias(dias!)
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.md, vertical: 5),
                    decoration: BoxDecoration(
                      color:
                          AppColores.alerta.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppRadio.circular),
                      border: Border.all(color: AppColores.alerta),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.home_rounded,
                            size: 15, color: AppColores.alerta),
                        const SizedBox(width: 8),
                        Text('Cuenta a la Casa',
                            style: AppTexto.etiqueta.copyWith(
                                color: AppColores.alerta,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                const SizedBox(height: AppEspacio.xs),
                // 1.25 T117 (F1-47): sin foto, el botón dice
                // «Añadir foto» (la pista que faltaba); sin
                // permiso, candado y deshabilitado.
                TextButton.icon(
                  icon: Icon(
                      puedeCambiarFoto
                          ? Icons.camera_alt_rounded
                          : Icons.lock_rounded,
                      size: 18),
                  label: Text(
                      foto == null ? 'Añadir foto' : 'Cambiar foto'),
                  onPressed: puedeCambiarFoto ? onCambiarFoto : null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.sm),
                    minimumSize: Size.zero,
                    tapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
          // 1.25 T16: el valor tiene su propio espacio
          // (flex 2) y envuelve en vez de apretar la
          // etiqueta o desbordar con la letra grande del
          // sistema (tarifa especial y Plus son largos).
          Expanded(
            flex: 2,
            child: Text(valor,
                style: AppTexto.cuerpo.copyWith(
                    fontWeight: FontWeight.w600),
                textAlign: TextAlign.right),
          ),
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

  /// 1.25 T13: membresía congelada — la barra se pinta en
  /// pausa (gris) y el texto lo explica: el vencimiento no
  /// está corriendo.
  final bool pausada;

  const BarraMesFicha(
      {super.key,
      this.fechaInicioRaw,
      this.pagadoHastaRaw,
      this.pausada = false});

  @override
  Widget build(BuildContext context) {
    // 1.25 T53: el cálculo vive en progresoPeriodoFicha
    // (lo comparten la barra, el anillo del avatar y la
    // línea de texto de la ficha).
    final prog = progresoPeriodoFicha(
        fechaInicioRaw: fechaInicioRaw,
        pagadoHastaRaw: pagadoHastaRaw);
    if (prog == null) {
      return const SizedBox.shrink();
    }
    final frac = prog.frac;
    final diasRest = prog.diasRest;
    final total = prog.totalDias;
    final color = pausada
        ? AppColores.bannerGrisB
        : diasRest < 0
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
            borderRadius: BorderRadius.circular(AppRadio.circular),
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
            pausada
                ? 'Período en pausa: membresía congelada '
                    '(el vencimiento no corre)'
                : diasRest < 0
                    ? 'Vencido hace ${-diasRest} día${-diasRest == 1 ? '' : 's'}'
                    : diasRest == 0
                        ? 'Vence hoy'
                        // 1.25 T117 (F1-31): el texto dice
                        // el período REAL por su duración
                        // (la barra también sirve a la
                        // semana de 7 y la quincena de 15:
                        // antes todo era «del mes pagado»).
                        : 'Quedan $diasRest días '
                            '${total <= 7 ? 'de la semana pagada' : total <= 15 ? 'de la quincena pagada' : total <= 31 ? 'del mes pagado' : 'del período pagado'}',
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

  /// 1.25 T55: montos de los últimos cobros en orden
  /// cronológico para el mini-gráfico de regularidad.
  /// Vacía o con un solo pago: no se pinta gráfico.
  final List<double> serieMontos;

  const Resumen360Ficha(
      {super.key, required this.resumen, this.serieMontos = const []});

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
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
            // 1.25 T55: con menos de 2 cobros no hay
            // regularidad que enseñar.
            if (serieMontos.length >= 2) _miniGrafico(context),
          ],
        ),
      ),
    );
  }

  /// 1.25 T55: las barritas de los últimos cobros bajo las
  /// cifras — la regularidad del pago se ve de un vistazo.
  Widget _miniGrafico(BuildContext context) {
    final maximo = serieMontos.fold<double>(
        0, (m, v) => v > m ? v : m);
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 30,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < serieMontos.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 2),
                      child: Container(
                        height: maximo > 0
                            ? 4 + 26 * (serieMontos[i] / maximo)
                            : 4,
                        decoration: BoxDecoration(
                          color: i == serieMontos.length - 1
                              ? AppColores.naranja
                              : AppColores.naranja
                                  .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(
                              AppRadio.sm),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
              'Últimos ${serieMontos.length} cobros · '
              'el más reciente, a la derecha',
              style: AppTexto.metadato.copyWith(
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }
}

class TarjetaHistorialFicha extends StatefulWidget {
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
  State<TarjetaHistorialFicha> createState() =>
      _TarjetaHistorialFichaState();
}

class _TarjetaHistorialFichaState extends State<TarjetaHistorialFicha> {
  // 1.25 T117 (F1-38): el historial ya no se pinta entero.
  // 1.25 T56: el tope con «Ver todo» lo sustituye el
  // plegado por meses — cada mes es una sección con su
  // cabecera (conteo y suma de pagos) que se abre y se
  // cierra; el mes más reciente empieza abierto.
  Set<String> _mesesAbiertos = {};

  @override
  void didUpdateWidget(TarjetaHistorialFicha old) {
    super.didUpdateWidget(old);
    if (old.filtro != widget.filtro ||
        old.clienteId != widget.clienteId) {
      _mesesAbiertos = {};
    }
  }

  @override
  Widget build(BuildContext context) {
    final entradas = widget.entradas;
    final filtro = widget.filtro;
    final todas = switch (filtro) {
      'pagos' => entradas.where((e) => e['tipo'] == 'pago').toList(),
      'ventas' => entradas.where((e) => e['tipo'] == 'venta').toList(),
      _ => entradas,
    };
    // 1.25 T117 (F1-37): la deuda de fiado NO es un evento
    // más del historial: va FIJADA arriba con cualquier
    // filtro (antes se hundía al final por no tener fecha
    // y desaparecía al filtrar por pagos o ventas). OJO: los
    // fiados salen de `entradas`, NO de `todas` — extraerlos
    // tras el filtro los volvía a esconder con «pagos» o
    // «ventas» activos (lo cazó el test de T117).
    final fiados = entradas.where((e) => e['tipo'] == 'fiado').toList();
    final resto =
        todas.where((e) => e['tipo'] != 'fiado').toList();
    // 1.25 T56: el resto va agrupado por mes (los fiados
    // siguen fijados arriba, fuera de los grupos).
    final grupos = gruposHistorialPorMes(resto);
    if (_mesesAbiertos.isEmpty && grupos.isNotEmpty) {
      _mesesAbiertos = {grupos.first.clave};
    }
    final visibles = fiados;
    Widget chipFiltro(String valor, String texto) {
      final activo = filtro == valor;
      return ChoiceChip(
        label: Text(texto),
        selected: activo,
        onSelected: (_) => widget.onFiltro(valor),
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
                        clienteId: widget.clienteId),
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
          if (widget.serviciosHist.isNotEmpty && filtro != 'pagos')
            Builder(builder: (_) {
              final r = servicios_svc
                  .resumenServiciosDeCliente(widget.serviciosHist);
              final partes = <String>[
                if (r.dosis > 0) '${r.dosis} dosis',
                if (r.pomos > 0) '${r.pomos} pomos de agua',
                if (r.importe > 0)
                  '${fmtMonto(r.importe)} CUP en compras',
              ];
              if (partes.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Acumulado: ${partes.join(' · ')}',
                  style: AppTexto.secundario,
                ),
              );
            }),
          const SizedBox(height: AppEspacio.sm),
          // 1.25 T56: el vacío es de la tarjeta entera (sin
          // fiados fijados y sin ningún mes).
          if (visibles.isEmpty && grupos.isEmpty)
            EstadoVacio(
              icono: Icons.history_rounded,
              // F1-38: en «Todo» no hay «otro filtro» que
              // probar: el vacío dice lo que es.
              titulo: filtro == 'todo'
                  ? 'Sin movimientos todavía'
                  : 'Sin movimientos en este filtro',
              subtitulo: filtro == 'todo'
                  ? 'Cuando haya pagos o ventas, salen aquí.'
                  : 'Prueba con otro filtro.',
            ),
          for (var i = 0; i < visibles.length; i++)
            FilaTimelineFicha(
                e: visibles[i],
                esUltima: false,
                esAdmin: widget.esAdmin,
                esOwner: widget.esOwner,
                onReenviarRecibo: widget.onReenviarRecibo,
                onVerComprobante: widget.onVerComprobante,
                onCorregirPago: widget.onCorregirPago,
                onConciliar: widget.onConciliar),
          // 1.25 T56: los meses, plegables. La cabecera
          // resume el mes (pagos y su suma) sin abrirlo.
          for (var g = 0; g < grupos.length; g++) ...[
            InkWell(
              onTap: () => setState(() {
                if (_mesesAbiertos.contains(grupos[g].clave)) {
                  _mesesAbiertos.remove(grupos[g].clave);
                } else {
                  _mesesAbiertos.add(grupos[g].clave);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: AppEspacio.sm),
                child: Row(
                  children: [
                    Icon(
                        _mesesAbiertos.contains(grupos[g].clave)
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        size: 20,
                        color: AppColores.textoSecundario(context)),
                    const SizedBox(width: AppEspacio.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(grupos[g].titulo,
                              style: AppTexto.subtitulo),
                          Text(
                            grupos[g].nPagos > 0
                                ? '${grupos[g].nPagos} pago${grupos[g].nPagos == 1 ? '' : 's'} · '
                                    '${fmtMonto(grupos[g].sumaPagos)} CUP'
                                : '${grupos[g].entradas.length} movimiento${grupos[g].entradas.length == 1 ? '' : 's'}',
                            style: AppTexto.metadato.copyWith(
                                color: AppColores.textoSecundario(
                                    context)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_mesesAbiertos.contains(grupos[g].clave))
              for (var i = 0; i < grupos[g].entradas.length; i++)
                FilaTimelineFicha(
                    e: grupos[g].entradas[i],
                    esUltima: g == grupos.length - 1 &&
                        i == grupos[g].entradas.length - 1,
                    esAdmin: widget.esAdmin,
                    esOwner: widget.esOwner,
                    onReenviarRecibo: widget.onReenviarRecibo,
                    onVerComprobante: widget.onVerComprobante,
                    onCorregirPago: widget.onCorregirPago,
                    onConciliar: widget.onConciliar),
          ],
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
                      // 1.25 T16: las acciones SECUNDARIAS de
                      // la fila viven en un menú «⋮» (antes
                      // hasta 4 botones en la misma línea
                      // aplastaban el título con letra grande).
                      if (uuidComprobante.isNotEmpty ||
                          (e['tipo'] == 'pago' && esAdmin) ||
                          (e['tipo'] == 'pago' &&
                              pagoFila != null &&
                              '${pagoFila['metodo'] ?? ''}' ==
                                  'transferencia' &&
                              esOwner))
                        PopupMenuButton<String>(
                          tooltip: 'Más acciones',
                          icon: const Icon(
                              Icons.more_vert_rounded, size: 20),
                          onSelected: (accion) {
                            switch (accion) {
                              case 'comprobante':
                                onVerComprobante(uuidComprobante);
                              case 'corregir':
                                onCorregirPago(e['pago']
                                    as Map<String, dynamic>);
                              case 'conciliar':
                                onConciliar(pagoFila!);
                            }
                          },
                          itemBuilder: (ctx) => [
                            if (uuidComprobante.isNotEmpty)
                              const PopupMenuItem(
                                value: 'comprobante',
                                child: Text('Ver comprobante'),
                              ),
                            if (e['tipo'] == 'pago' && esAdmin)
                              const PopupMenuItem(
                                value: 'corregir',
                                child: Text('Corregir pago'),
                              ),
                            // T4 (1.20): conciliar (solo el
                            // dueño; el servidor lo exige).
                            if (e['tipo'] == 'pago' &&
                                pagoFila != null &&
                                '${pagoFila['metodo'] ?? ''}' ==
                                    'transferencia' &&
                                esOwner)
                              const PopupMenuItem(
                                value: 'conciliar',
                                child:
                                    Text('Conciliar transferencia'),
                              ),
                          ],
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

/// 1.25 T53: el progreso del período pagado, calculado una
/// sola vez y compartido por la barra (BarraMesFicha), el
/// anillo del avatar de la cabecera y la línea de texto.
/// Null si no hay período válido (sin pagos, fechas cortas
/// o vencimiento no posterior al inicio).
({double frac, int diasRest, int totalDias})? progresoPeriodoFicha({
  required String? fechaInicioRaw,
  required String? pagadoHastaRaw,
}) {
  final iniRaw = fechaInicioRaw ?? '';
  final finRaw = pagadoHastaRaw ?? '';
  if (iniRaw.length < 10 || finRaw.length < 10) return null;
  final ini = DateTime.tryParse(iniRaw.substring(0, 10));
  final fin = DateTime.tryParse(finRaw.substring(0, 10));
  if (ini == null || fin == null || !fin.isAfter(ini)) return null;
  final hoy = ahoraHabana();
  final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
  final total = fin.difference(ini).inDays;
  var usado = hoyDia.difference(ini).inDays;
  if (usado < 0) usado = 0;
  if (usado > total) usado = total;
  return (
    frac: total == 0 ? 1.0 : usado / total,
    diasRest: fin.difference(hoyDia).inDays,
    totalDias: total,
  );
}

/// 1.25 T53: SOLO el texto del período (la barra la absorbió
/// el anillo del avatar de la cabecera): en pausa, vencido,
/// vence hoy o «Quedan N días de la semana/quincena/mes».
class LineaPeriodoFicha extends StatelessWidget {
  final String? fechaInicioRaw;
  final String? pagadoHastaRaw;
  final bool pausada;

  const LineaPeriodoFicha(
      {super.key,
      this.fechaInicioRaw,
      this.pagadoHastaRaw,
      this.pausada = false});

  @override
  Widget build(BuildContext context) {
    final prog = progresoPeriodoFicha(
        fechaInicioRaw: fechaInicioRaw,
        pagadoHastaRaw: pagadoHastaRaw);
    if (prog == null) return const SizedBox.shrink();
    final diasRest = prog.diasRest;
    final total = prog.totalDias;
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.xs),
      child: Text(
        pausada
            ? 'Período en pausa: membresía congelada '
                '(el vencimiento no corre)'
            : diasRest < 0
                ? 'Vencido hace ${-diasRest} día${-diasRest == 1 ? '' : 's'}'
                : diasRest == 0
                    ? 'Vence hoy'
                    : 'Quedan $diasRest días '
                        '${total <= 7 ? 'de la semana pagada' : total <= 15 ? 'de la quincena pagada' : total <= 31 ? 'del mes pagado' : 'del período pagado'}',
        style: AppTexto.secundario,
      ),
    );
  }
}

/// 1.25 T53: pintor del anillo de progreso del avatar —
/// arco de fondo completo y arco de avance desde arriba,
/// en el color del estado (o gris en pausa).
class _AnilloPeriodoPainter extends CustomPainter {
  final double fraccion;
  final Color color;

  const _AnilloPeriodoPainter(
      {required this.fraccion, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final centro = Offset(size.width / 2, size.height / 2);
    final radio = (size.shortestSide / 2) - 3;
    final trazo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    trazo.color = color.withValues(alpha: 0.22);
    canvas.drawCircle(centro, radio, trazo);
    if (fraccion > 0) {
      trazo.color = color;
      canvas.drawArc(
        Rect.fromCircle(center: centro, radius: radio),
        -1.5708,
        6.2832 * fraccion,
        false,
        trazo,
      );
    }
  }

  @override
  bool shouldRepaint(_AnilloPeriodoPainter old) =>
      old.fraccion != fraccion || old.color != color;
}

/// 1.25 T56: agrupa las entradas del historial por mes
/// (clave AAAA-MM de su fecha), en el orden en que llegan
/// (descendente). Cada grupo resume sus pagos: conteo y
/// suma de montos (las cortesías suman su 0). Sin fecha
/// válida: grupo final «Sin fecha».
List<
    ({
      String clave,
      String titulo,
      int nPagos,
      double sumaPagos,
      List<Map<String, dynamic>> entradas
    })> gruposHistorialPorMes(List<Map<String, dynamic>> entradas) {
  const meses = [
    '',
    'Enero',
    'Febrero',
    'Marzo',
    'Abril',
    'Mayo',
    'Junio',
    'Julio',
    'Agosto',
    'Septiembre',
    'Octubre',
    'Noviembre',
    'Diciembre',
  ];
  final orden = <String>[];
  final porClave = <String, List<Map<String, dynamic>>>{};
  for (final e in entradas) {
    final fecha = '${e['fecha'] ?? ''}';
    final clave = fecha.length >= 7 ? fecha.substring(0, 7) : '';
    if (!porClave.containsKey(clave)) {
      porClave[clave] = [];
      orden.add(clave);
    }
    porClave[clave]!.add(e);
  }
  return [
    for (final clave in orden)
      (
        clave: clave,
        titulo: clave.isEmpty
            ? 'Sin fecha'
            : '${meses[int.tryParse(clave.substring(5, 7)) ?? 0]} '
                '${clave.substring(0, 4)}',
        nPagos: porClave[clave]!
            .where((e) => e['tipo'] == 'pago')
            .length,
        sumaPagos: porClave[clave]!
            .where((e) => e['tipo'] == 'pago')
            .fold<double>(
                0,
                (s, e) =>
                    s +
                    (((e['pago'] as Map<String, dynamic>?)?['monto']
                            as num?)
                        ?.toDouble() ??
                    0)),
        entradas: porClave[clave]!,
      ),
  ];
}
