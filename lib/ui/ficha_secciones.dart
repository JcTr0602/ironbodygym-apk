/// 1.22 Diseño Bloque 2 Paso 1 (mandato de Argón):
/// secciones de la Ficha extraídas como vistas tontas —
/// reciben datos inmutables (y callbacks donde aplica) y
/// no tocan estado, controladores ni servicios de
/// escritura. La extracción es PURA: mismo árbol de
/// widgets que los métodos privados originales de
/// FichaScreen; el layout nuevo llega en el Paso 2.
library;

import 'dart:async';
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

/// Diseño Bloque 2 Paso 2 (B1): la cabecera de la ficha.
/// 1.35 (UX-04): la cabecera se recompone como
/// CREDENCIAL del gym — la foto manda en una banda
/// superior de ancho completo con el nombre y la
/// insignia de estado sobre el velo grafito del pie, y
/// una tira de datos clave (pagado hasta · días que
/// quedan) cerrando la credencial. Sin foto, la banda es
/// el arte del rayo con las iniciales grandes. Se
/// conserva TODO lo que la cabecera hacía: el Hero de la
/// foto, el toque para verla en grande, la insignia con
/// sus textos exactos, el botón de foto con sus tres
/// estados (sin permiso con candado, en curso con
/// indicador) y el progreso del período — que deja de
/// ser el anillo del avatar y pasa a ser la barra del
/// pie de la banda, con la misma animación y el mismo
/// color de estado (gris en pausa). La forma plegada al
/// bajar, las pestañas y el orden de secciones no
/// cambian (viven en la ficha, no aquí).
class CabeceraFicha extends StatelessWidget {
  final String nombre;
  final File? foto;

  /// Color de estado (verde al día, ámbar por vencer o
  /// Casa, rojo vencido) — lo calcula la ficha. En la
  /// credencial tiñe la barra del período y la línea de
  /// estado del pie de la banda.
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

  /// 1.34 (G-1): el flujo de foto de la ficha está en
  /// curso (la guarda de reentrada vive): el botón se
  /// pinta deshabilitado y con un indicador breve, para
  /// que el usuario VEA que su toque entró durante la
  /// espera de apertura del diálogo.
  final bool fotoOcupada;

  /// 1.25 T53: fracción transcurrida del período pagado
  /// (0–1) para la barra de progreso del pie de la banda,
  /// que hereda el papel del anillo del avatar (que a su
  /// vez absorbió la barra del mes). Null = sin período
  /// (el pie enseña la línea plana del color de estado).
  final double? fraccionPeriodo;

  /// 1.25 T53: período en pausa (congelado): la barra se
  /// pinta en gris, como hacía el anillo.
  final bool periodoPausado;

  /// 1.35 (UX-04): el «pagado hasta» ya formateado para
  /// la tira de datos clave («05/12/2026»; la ficha pasa
  /// «Sin vencimiento» para la Casa). Null = «—».
  final String? pagadoHastaTexto;

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
      this.fotoOcupada = false,
      this.fraccionPeriodo,
      this.periodoPausado = false,
      this.pagadoHastaTexto});

  String get _iniciales {
    final partes =
        nombre.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (partes.isEmpty) return '?';
    var ini = partes.first[0].toUpperCase();
    if (partes.length > 1) ini += partes.last[0].toUpperCase();
    return ini;
  }

  /// La insignia de estado, con los textos de siempre.
  Widget _insignia(BuildContext context) {
    // Argón Clientes #3: con Casa manda el chip dorado;
    // la insignia de días no se pinta. Yunque de cambios
    // 1.31 (M1): `congelado` aquí es la fusión que pasa
    // la ficha (congelado viejo O pausa nueva en curso):
    // la insignia sigue diciendo «CONGELADO».
    if (!esCasa && congelado) {
      return const BadgeEstado(
          estado: EstadoMembresia.congelado, texto: 'CONGELADO');
    }
    if (!esCasa && dias == null) {
      return const BadgeEstado(
          estado: EstadoMembresia.sinPagos, texto: 'SIN PAGOS');
    }
    if (!esCasa) return BadgeEstado.desdeDias(dias!);
    // Casa en dorado SOBRE el velo grafito de la banda:
    // el ámbar brillante (en la cabecera vieja, sobre
    // superficie clara, mandaba el par de tinta de D-15;
    // sobre el velo oscuro el brillante es el que lee).
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: 5),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppRadio.circular),
        border: Border.all(
            color: AppColores.alerta.withValues(alpha: 0.75)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.home_rounded,
              size: 15, color: AppColores.alerta),
          const SizedBox(width: 8),
          Text('Cuenta a la Casa',
              style: AppTexto.etiqueta.copyWith(
                  color: AppColores.alerta,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  /// El botón de la foto, como pastilla sobre la banda:
  /// mismo texto («Añadir foto» / «Cambiar foto»), mismo
  /// candado sin permiso y mismo indicador en curso.
  Widget _botonFoto() {
    return Material(
      color: AppColores.grafitoTactico.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(AppRadio.circular),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadio.circular),
        onTap: (puedeCambiarFoto && !fotoOcupada)
            ? onCambiarFoto
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.md, vertical: AppEspacio.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fotoOcupada)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColores.textoSobreOscuro),
                )
              else
                Icon(
                    puedeCambiarFoto
                        ? Icons.photo_camera_rounded
                        : Icons.lock_rounded,
                    size: 18,
                    color: AppColores.textoSobreOscuro),
              const SizedBox(width: 8),
              Text(foto == null ? 'Añadir foto' : 'Cambiar foto',
                  style: AppTexto.etiqueta.copyWith(
                      color: AppColores.textoSobreOscuro,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  /// Una celda de la tira de datos clave.
  Widget _datoTira(BuildContext context, String etiqueta, String valor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta,
            style: AppTexto.metadato.copyWith(
                color: AppColores.textoSecundario(context))),
        const SizedBox(height: 2),
        Text(valor,
            style: AppTexto.cuerpo
                .copyWith(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
    );
  }

  String get _diasTexto {
    if (esCasa) return 'Sin vencimiento';
    if (congelado) return 'En pausa';
    final d = dias;
    if (d == null) return 'Sin pagos';
    if (d == 0) return 'Vence hoy';
    if (d > 0) return d == 1 ? 'Queda 1 día' : 'Quedan $d días';
    return d == -1 ? 'Vencido hace 1 día' : 'Vencido hace ${-d} días';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(color: AppColores.borde(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // La banda de la credencial.
          SizedBox(
            height: 196,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (foto != null)
                  GestureDetector(
                    onTap: onFotoTap,
                    child: heroTag == null
                        ? Image(
                            image: providerFotoAcotada(
                                FileImage(foto!), ancho: 720),
                            fit: BoxFit.cover)
                        : Hero(
                            tag: heroTag!,
                            child: Image(
                                image: providerFotoAcotada(
                                    FileImage(foto!), ancho: 720),
                                fit: BoxFit.cover),
                          ),
                  )
                else ...[
                  Image.asset('assets/arte_marca_rayo.jpg',
                      fit: BoxFit.cover),
                  Container(
                      color: AppColores.grafitoTactico
                          .withValues(alpha: 0.45)),
                  Center(
                    child: Text(_iniciales,
                        style: AppTexto.display.copyWith(
                            fontSize: 64,
                            color: AppColores.textoSobreOscuro)),
                  ),
                ],
                // El velo grafito del pie: nombre e insignia
                // se leen sobre él, no sobre la foto cruda.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 118,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppColores.grafitoTactico
                              .withValues(alpha: 0),
                          AppColores.grafitoTactico
                              .withValues(alpha: 0.88),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: AppEspacio.md,
                  right: AppEspacio.md,
                  bottom: AppEspacio.md,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nombre,
                          style: AppTexto.displayPequeno.copyWith(
                              color: AppColores.textoSobreOscuro),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: AppEspacio.sm),
                      _insignia(context),
                    ],
                  ),
                ),
                Positioned(
                  top: AppEspacio.sm,
                  right: AppEspacio.sm,
                  child: _botonFoto(),
                ),
                // El progreso del período, al pie de la
                // banda (hereda el anillo): animado hasta
                // su valor, como el anillo al volver de un
                // cobro. Sin período, la línea plana del
                // color de estado (el viejo anillo plano).
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: fraccionPeriodo == null
                      ? Container(height: 3, color: colorMarco)
                      : TweenAnimationBuilder<double>(
                          duration: AppMovimiento.larga,
                          curve: AppMovimiento.curvaSuave,
                          tween: Tween<double>(
                              end: fraccionPeriodo!.clamp(0.0, 1.0)),
                          builder: (context, valor, _) => SizedBox(
                            height: 4,
                            child: LinearProgressIndicator(
                              value: valor,
                              backgroundColor: AppColores
                                  .grafitoTactico
                                  .withValues(alpha: 0.35),
                              valueColor: AlwaysStoppedAnimation(
                                  periodoPausado
                                      ? AppColores.bannerGrisB
                                      : colorMarco),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
          // La tira de datos clave que cierra la
          // credencial.
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.md, vertical: AppEspacio.sm),
            child: Row(
              children: [
                Expanded(
                    child: _datoTira(context, 'Pagado hasta',
                        pagadoHastaTexto ?? '—')),
                Expanded(
                    child: _datoTira(
                        context, 'Días que quedan', _diasTexto)),
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

  /// 1.30 FICHA-05: comprado de por vida (suplementos +
  /// servicios), precalculado por la ficha. Sin compras
  /// (ambos en 0), la línea no se pinta.
  final ({double cup, double usd}) compradoVida;

  const Resumen360Ficha(
      {super.key,
      required this.resumen,
      this.serieMontos = const [],
      this.compradoVida = const (cup: 0, usd: 0)});

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
            // 1.30 FICHA-05: lo comprado de por vida, en
            // una línea — el Resumen contaba lo PAGADO de
            // mensualidad y las compras no salían en
            // ningún total de la ficha.
            if (compradoVida.cup > 0 || compradoVida.usd > 0)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Comprado en total: ${fmtMonto(compradoVida.cup)} CUP'
                  '${compradoVida.usd > 0 ? ' · ${fmtMonto(compradoVida.usd)} USD' : ''}',
                  style: AppTexto.secundario,
                  textAlign: TextAlign.center,
                ),
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

/// 1.30 (Oleada 10, FICHA-09): normaliza un texto para
/// buscar en el historial: minúsculas y sin tildes (la
/// ñ se pliega a n). Pura.
String normalizarBusquedaFicha(String s) {
  var r = s.toLowerCase();
  const mapa = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  mapa.forEach((k, v) => r = r.replaceAll(k, v));
  return r;
}

/// 1.30 (Oleada 10, FICHA-09): ¿coincide una entrada del
/// historial con la consulta? Todos los términos de
/// texto deben aparecer en el título, el subtítulo o el
/// trailing de la entrada — o, si es un pago, en su
/// método, su período o su estado de conciliación (así
/// «transferencia» y «por comprobar» encuentran sus
/// pagos). Los dígitos de la consulta (un monto) se
/// comprueban aparte contra los dígitos del trailing y
/// del monto: buscar «2500» encuentra el cobro de
/// 2 500 aunque el texto lo separa con espacio. Pura.
bool entradaCoincideBusquedaHistorial(
    Map<String, dynamic> e, String consulta) {
  final q = normalizarBusquedaFicha(consulta).trim();
  if (q.isEmpty) return true;
  final pago = e['pago'] as Map<String, dynamic>?;
  final pajar = normalizarBusquedaFicha(<String>[
    '${e['titulo'] ?? ''}',
    '${e['subtitulo'] ?? ''}',
    '${e['trailing'] ?? ''}',
    if (pago != null) ...[
      '${pago['metodo'] ?? ''}',
      '${pago['periodo'] ?? ''}',
      etiquetaConciliacion(estadoConciliacion(pago)),
    ],
  ].join(' '));
  for (final t in q.split(RegExp(r'\s+'))) {
    if (t.isEmpty) continue;
    // Los términos de solo dígitos los juzga la
    // comparación de montos de abajo.
    if (RegExp(r'^\d+$').hasMatch(t)) continue;
    if (!pajar.contains(t)) return false;
  }
  final digitosQ = q.replaceAll(RegExp(r'\D'), '');
  if (digitosQ.isNotEmpty) {
    final digitosPajar = <String>[
      '${e['trailing'] ?? ''}',
      if (pago != null) '${pago['monto'] ?? ''}',
      if (e['montoVenta'] != null) '${e['montoVenta']}',
    ].join(' ').replaceAll(RegExp(r'\D'), '');
    if (!digitosPajar.contains(digitosQ)) return false;
  }
  return true;
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

  /// 1.29 (FB-03 · D-B1-04): pie «Ver pagos anteriores». No
  /// nulo SOLO mientras la tarjeta enseña la muestra reciente
  /// (10 pagos / 20 ventas): el pie lo dice y el botón pide a
  /// la ficha la historia completa del espejo local.
  final VoidCallback? onVerAnteriores;

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
      required this.onConciliar,
      this.onVerAnteriores});

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

  // 1.30 (Oleada 10, FICHA-09): el buscador del historial
  // (controlador propio de la tarjeta, con su dispose).
  final _busquedaCtrl = TextEditingController();
  String _busqueda = '';

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TarjetaHistorialFicha old) {
    super.didUpdateWidget(old);
    if (old.filtro != widget.filtro ||
        old.clienteId != widget.clienteId) {
      _mesesAbiertos = {};
    }
    if (old.clienteId != widget.clienteId) {
      // Otra ficha: la búsqueda anterior no era suya.
      _busqueda = '';
      _busquedaCtrl.clear();
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
    // 1.30 (Oleada 10, FICHA-09): con búsqueda activa la
    // lista deja de agruparse por meses: salen las
    // coincidencias en plano, dentro del filtro activo
    // (`todas` ya lo respeta; con «Todo» incluye los
    // fiados fijados si coinciden).
    final buscando = _busqueda.trim().isNotEmpty;
    final coincidencias = buscando
        ? todas
            .where((e) =>
                entradaCoincideBusquedaHistorial(e, _busqueda))
            .toList()
        : const <Map<String, dynamic>>[];
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
          const SizedBox(height: AppEspacio.sm),
          // 1.30 (Oleada 10, FICHA-09): buscar dentro del
          // historial — por texto (concepto, método,
          // «transferencia», «por comprobar»…) o por
          // monto. No bloquea nada: es un filtro más.
          TextField(
            controller: _busquedaCtrl,
            decoration: InputDecoration(
              hintText: 'Buscar en el historial…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _busqueda.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _busquedaCtrl.clear();
                        setState(() => _busqueda = '');
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _busqueda = v),
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
          if (!buscando && visibles.isEmpty && grupos.isEmpty)
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
          for (var i = 0; !buscando && i < visibles.length; i++)
            FilaTimelineFicha(
                e: visibles[i],
                esUltima: false,
                esAdmin: widget.esAdmin,
                esOwner: widget.esOwner,
                onReenviarRecibo: widget.onReenviarRecibo,
                onVerComprobante: widget.onVerComprobante,
                onCorregirPago: widget.onCorregirPago,
                onConciliar: widget.onConciliar),
          // 1.30 (Oleada 10, FICHA-09): los resultados de
          // la búsqueda, en plano y con su conteo.
          if (buscando) ...[
            const SizedBox(height: AppEspacio.sm),
            if (coincidencias.isEmpty)
              EstadoVacio(
                icono: Icons.search_off_rounded,
                titulo:
                    'Sin resultados para «${_busqueda.trim()}»',
                subtitulo: 'Prueba con otro texto o un monto.',
              )
            else ...[
              Text(
                '${coincidencias.length} '
                'resultado${coincidencias.length == 1 ? '' : 's'} '
                'para «${_busqueda.trim()}»',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: AppEspacio.xs),
              for (var i = 0; i < coincidencias.length; i++)
                FilaTimelineFicha(
                    e: coincidencias[i],
                    esUltima: i == coincidencias.length - 1,
                    esAdmin: widget.esAdmin,
                    esOwner: widget.esOwner,
                    onReenviarRecibo: widget.onReenviarRecibo,
                    onVerComprobante: widget.onVerComprobante,
                    onCorregirPago: widget.onCorregirPago,
                    onConciliar: widget.onConciliar),
            ],
          ],
          // 1.25 T56: los meses, plegables. La cabecera
          // resume el mes (pagos y su suma) sin abrirlo.
          for (var g = 0; !buscando && g < grupos.length; g++) ...[
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
                            textoResumenMesFicha(
                              nPagos: grupos[g].nPagos,
                              sumaPagos: grupos[g].sumaPagos,
                              nVentas: grupos[g].nVentas,
                              sumaVentasCup: grupos[g].sumaVentasCup,
                              sumaVentasUsd: grupos[g].sumaVentasUsd,
                              nMovimientos: grupos[g].entradas.length,
                            ),
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
          // 1.29 (FB-03): el pie de la muestra — la tarjeta
          // declara que enseña una muestra y ofrece la
          // historia completa sin salir de la ficha.
          if (!buscando && widget.onVerAnteriores != null) ...[
            const SizedBox(height: AppEspacio.sm),
            const Divider(height: 1),
            const SizedBox(height: AppEspacio.sm),
            const Text(
              'Se muestran los últimos 10 pagos y las últimas '
              '20 ventas de suplementos.',
              style: AppTexto.secundario,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.history_rounded, size: 18),
                label: const Text('Ver pagos anteriores'),
                onPressed: widget.onVerAnteriores,
              ),
            ),
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
                          popUpAnimationStyle: estiloAparicionMenu,
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
                          style: AppTexto.metadato.copyWith(
                              color: AppColores.errorTexto(context)),
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
  // 1.28 (M4-A3/R3M4-H4): fechas por el parser estricto y
  // conteo en UTC. tryParse normalizaba fechas inventadas y
  // el hoy LOCAL hacía que la barra discrepara un día de
  // diasRestantes/Plus en los días de cambio de hora.
  final ini = fechaIsoEstricta(fechaInicioRaw);
  final fin = fechaIsoEstricta(pagadoHastaRaw);
  if (ini == null || fin == null || !fin.isAfter(ini)) return null;
  final hoy = ahoraHabana();
  final hoyDia = DateTime.utc(hoy.year, hoy.month, hoy.day);
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


/// 1.25 T56: agrupa las entradas del historial por mes
/// (clave AAAA-MM de su fecha), en el orden en que llegan
/// (descendente). Cada grupo resume sus pagos: conteo y
/// suma de montos (las cortesías suman su 0). Sin fecha
/// válida: grupo final «Sin fecha».
/// 1.30 FICHA-05: cada grupo suma TAMBIÉN sus ventas
/// (conteo y monto por moneda) desde los campos
/// estructurados de la entrada ('montoVenta'/'monedaVenta'
/// que pone _construirEntradas; un montoVenta null — el
/// servicio de Cuenta a la Casa — no es venta y no cuenta).
List<
    ({
      String clave,
      String titulo,
      int nPagos,
      double sumaPagos,
      int nVentas,
      double sumaVentasCup,
      double sumaVentasUsd,
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
        nVentas: porClave[clave]!
            .where((e) => e['tipo'] == 'venta' && e['montoVenta'] != null)
            .length,
        sumaVentasCup: porClave[clave]!
            .where((e) =>
                e['tipo'] == 'venta' &&
                e['montoVenta'] != null &&
                '${e['monedaVenta'] ?? 'CUP'}' != 'USD')
            .fold<double>(
                0, (s, e) => s + ((e['montoVenta'] as num?)?.toDouble() ?? 0)),
        sumaVentasUsd: porClave[clave]!
            .where((e) =>
                e['tipo'] == 'venta' &&
                e['montoVenta'] != null &&
                '${e['monedaVenta'] ?? 'CUP'}' == 'USD')
            .fold<double>(
                0, (s, e) => s + ((e['montoVenta'] as num?)?.toDouble() ?? 0)),
        entradas: porClave[clave]!,
      ),
  ];
}

/// 1.30 FICHA-05: lo comprado DE POR VIDA por el cliente
/// (suplementos + servicios), por moneda — la línea
/// «Comprado en total» del Resumen 360. Los servicios
/// suman con el agregado de la casa
/// (resumenServiciosDeCliente: Cuenta a la Casa fuera y
/// reversos neteados por su signo).
({double cup, double usd}) totalesCompradoVida(
    List<Map<String, dynamic>> suplementos,
    List<Map<String, dynamic>> serviciosHist) {
  var cup = 0.0;
  var usd = 0.0;
  for (final s in suplementos) {
    // G#15 (Hy4): el total REGISTRADO de la venta (la
    // columna `total` si la fila la trae; si no,
    // precio×cantidad), no el precio unitario suelto:
    // con el unitario, «Comprado en total» mentía en
    // toda venta de más de una unidad.
    final m = totalVentaRegistrado(s);
    if ('${s['moneda'] ?? 'CUP'}' == 'USD') {
      usd += m;
    } else {
      cup += m;
    }
  }
  cup += servicios_svc.resumenServiciosDeCliente(serviciosHist).importe;
  return (cup: cup, usd: usd);
}

/// Texto de la cabecera de un mes del historial (1.25 T56
/// + 1.30 FICHA-05): «3 pagos · 7500 CUP — 5 ventas ·
/// 2900 CUP» cuando hay de ambos; solo la parte que tenga
/// dato; sin pagos ni ventas, el conteo de movimientos.
String textoResumenMesFicha({
  required int nPagos,
  required double sumaPagos,
  required int nVentas,
  required double sumaVentasCup,
  required double sumaVentasUsd,
  required int nMovimientos,
}) {
  final partes = <String>[
    if (nPagos > 0)
      '$nPagos pago${nPagos == 1 ? '' : 's'} · ${fmtMonto(sumaPagos)} CUP',
    if (nVentas > 0)
      '$nVentas venta${nVentas == 1 ? '' : 's'} · ${fmtMonto(sumaVentasCup)} CUP'
          '${sumaVentasUsd > 0 ? ' · ${fmtMonto(sumaVentasUsd)} USD' : ''}',
  ];
  if (partes.isEmpty) {
    return '$nMovimientos movimiento${nMovimientos == 1 ? '' : 's'}';
  }
  return partes.join(' — ');
}

/// 1.28 (M4-C2): entrada de UNA sección de la ficha
/// perezosa — fundido corto con un levante mínimo,
/// escalonado por posición, SOLO la primera vez que la
/// sección entra en pantalla en esta visita. La ficha
/// guarda las claves ya animadas ([yaAnimadas]): al
/// desmontarse y volver a montarse haciendo scroll, la
/// sección entra DIRECTA, sin re-animar (la ficha deja de
/// sentirse una página que «carga» en cada vaivén).
/// Respeta «reducir movimiento» del sistema: con la
/// opción activa no hay animación alguna. El único estado
/// que guarda es el de esta animación de presentación.
class EntradaSeccionFicha extends StatefulWidget {
  final String claveSeccion;
  final int indice;
  final Set<String> yaAnimadas;
  final Widget child;

  const EntradaSeccionFicha({
    super.key,
    required this.claveSeccion,
    required this.indice,
    required this.yaAnimadas,
    required this.child,
  });

  @override
  State<EntradaSeccionFicha> createState() =>
      _EntradaSeccionFichaState();
}

class _EntradaSeccionFichaState extends State<EntradaSeccionFicha> {
  bool _animar = false;
  bool _visible = false;
  // El retardo de la escalera de entrada vive en un Timer
  // con dueño (este State): antes era un Future.delayed
  // sin handle — si la sección salía del árbol antes de
  // vencer (scroll rápido, cerrar la ficha), el temporizador
  // quedaba huérfano y sobrevivía a su pantalla.
  Timer? _temporizadorEntrada;

  @override
  void initState() {
    super.initState();
    // Set.add devuelve false si la clave ya estaba: esa
    // sección ya animó en esta visita y entra directa.
    if (widget.yaAnimadas.add(widget.claveSeccion)) {
      _animar = true;
      final ms = (widget.indice * 45).clamp(0, 270);
      if (ms == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _visible = true);
        });
      } else {
        _temporizadorEntrada = Timer(Duration(milliseconds: ms), () {
          _temporizadorEntrada = null;
          if (mounted) setState(() => _visible = true);
        });
      }
    }
  }

  @override
  void dispose() {
    _temporizadorEntrada?.cancel();
    _temporizadorEntrada = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animar || MediaQuery.of(context).disableAnimations) {
      return widget.child;
    }
    return AnimatedSlide(
      offset: _visible ? Offset.zero : const Offset(0, 0.05),
      duration: AppMovimiento.media,
      curve: AppMovimiento.curvaSuave,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: AppMovimiento.media,
        curve: AppMovimiento.curvaSuave,
        child: widget.child,
      ),
    );
  }
}
