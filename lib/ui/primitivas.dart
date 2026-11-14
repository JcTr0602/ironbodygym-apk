/// 1.32 «Mostrador Táctico» — PRIMITIVAS TRANSVERSALES del
/// mostrador (Oleada 2, Fase 0): el pad numérico empotrado,
/// la confirmación por deslizamiento y el motor de lenguaje
/// háptico, como componentes COMPARTIDOS reutilizables.
///
/// Nacieron al servicio de la hoja «Liquidar Arqueo»
/// (Oleada 1) y la Fase 0 de la Oleada 2 los promueve a
/// primitivas de toda la app SIN cambiar su comportamiento
/// probado: las fases siguientes (cobros, gastos, teléfonos,
/// adelantos y cierres críticos) los consumen desde aquí;
/// la hoja de Liquidar los sigue usando vía re-export.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diseno.dart';
import '../perfil.dart';

/// El LENGUAJE HÁPTICO del mostrador: un solo punto de
/// verdad para que toda la app responda al tacto con el
/// mismo vocabulario. Las pantallas y primitivas llaman a
/// estas intenciones, nunca a HapticFeedback directamente:
///
/// - [seleccion]: el clic sutil de elegir (chips, listas).
/// - [ligero]: toque leve de tecla (pad numérico, pasos).
/// - [confirmacion]: el golpe medio de cerrar un gesto
///   deliberado (el deslizamiento que confirma dinero).
/// - [exito]: el golpe firme de «operación terminada».
/// - [error]: la vibración de sistema de «eso no vale».
abstract final class Tacto {
  /// 1.35 (UI-02): el ajuste «Vibración» de Ajustes manda
  /// sobre TODA la capa háptica. La preferencia se lee una
  /// vez (perezosa) y queda en caché; el interruptor de
  /// Ajustes la fija al momento con [fijarHabilitado].
  static bool? _habilitado;

  static bool get _on {
    final h = _habilitado;
    if (h != null) return h;
    _habilitado = true; // provisional hasta que lea el ajuste
    PerfilService.instance
        .getVibracion()
        .then((v) => _habilitado = v, onError: (_) {});
    return true;
  }

  static void fijarHabilitado(bool v) => _habilitado = v;

  static void seleccion() {
    if (_on) HapticFeedback.selectionClick();
  }

  static void ligero() {
    if (_on) HapticFeedback.lightImpact();
  }

  static void confirmacion() {
    if (_on) HapticFeedback.mediumImpact();
  }

  static void exito() {
    if (_on) HapticFeedback.heavyImpact();
  }

  static void error() {
    if (_on) HapticFeedback.vibrate();
  }
}

/// 1.35 (UI-01): fundido corto con desplazamiento mínimo al
/// cambiar el [indice] visible de un IndexedStack (pilares
/// de la cáscara, segmentos de un pilar). El hijo NO se
/// remonta: el stack y sus hijos son la misma instancia y
/// solo se anima la entrada del que llega (opacidad +
/// 6 dp de subida) con los tokens de la casa
/// (AppMovimiento.media / curvaSuave). Con «reducir
/// movimiento» del sistema el cambio es instantáneo.
class FundidoAlCambiar extends StatefulWidget {
  final int indice;
  final Widget child;

  const FundidoAlCambiar({
    super.key,
    required this.indice,
    required this.child,
  });

  @override
  State<FundidoAlCambiar> createState() => _FundidoAlCambiarState();
}

class _FundidoAlCambiarState extends State<FundidoAlCambiar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppMovimiento.media,
    value: 1,
  );

  @override
  void didUpdateWidget(FundidoAlCambiar old) {
    super.didUpdateWidget(old);
    if (old.indice == widget.indice) return;
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.value = 1;
    } else {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // La estructura es CONSTANTE (Opacity + Transform
    // siempre, también en reposo con opacidad 1): si el
    // envoltorio apareciera y desapareciera al animar, el
    // elemento del hijo se remontaría y el stack perdería
    // el estado de los pilares — justo lo que UI-01
    // prohíbe.
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final t = AppMovimiento.curvaSuave.transform(_ctrl.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

/// Pad numérico empotrado del mostrador: edita un importe
/// como texto (dígitos y un punto decimal) sin abrir el
/// teclado del sistema. Reutilizable por los demás cobros
/// en la Oleada 2.
///
/// 1.32 (O2F2): [decimales] = false para importes ENTEROS
/// (los adelantos son «pesos enteros»): la tecla del punto
/// se pinta apagada y no compone nada.
class PadNumerico extends StatelessWidget {
  final String valor;
  final void Function(String nuevo) onCambia;
  final bool decimales;

  const PadNumerico({
    super.key,
    required this.valor,
    required this.onCambia,
    this.decimales = true,
  });

  void _tecla(String t) {
    Tacto.ligero();
    var v = valor;
    if (t == '⌫') {
      v = v.isEmpty ? v : v.substring(0, v.length - 1);
    } else if (t == 'C') {
      v = '';
    } else if (t == '.') {
      if (!decimales) return;
      if (!v.contains('.')) v = v.isEmpty ? '0.' : '$v.';
    } else {
      // Tope sano de mostrador: 9 enteros y 2 decimales.
      final partes = v.split('.');
      if (partes.length == 2 && partes[1].length >= 2) return;
      if (partes[0].length >= 9 && !v.contains('.')) return;
      v = '$v$t';
    }
    onCambia(v);
  }

  @override
  Widget build(BuildContext context) {
    Widget tecla(String t, {bool ancha = false}) {
      // Sin decimales, la tecla '.' queda apagada y muda.
      final apagada = t == '.' && !decimales;
      return Expanded(
        flex: ancha ? 2 : 1,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadio.sm),
            child: InkWell(
              key: ValueKey('pad-$t'),
              borderRadius: BorderRadius.circular(AppRadio.sm),
              onTap: apagada ? null : () => _tecla(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: Text(t,
                      style: AppTexto.conTabulares(AppTexto.subtitulo)
                          .copyWith(
                              color: apagada
                                  ? AppColores.textoSecundario(context)
                                      .withValues(alpha: 0.35)
                                  : null)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [tecla('1'), tecla('2'), tecla('3')]),
        Row(children: [tecla('4'), tecla('5'), tecla('6')]),
        Row(children: [tecla('7'), tecla('8'), tecla('9')]),
        Row(children: [tecla('C'), tecla('0'), tecla('.'), tecla('⌫')]),
      ],
    );
  }
}

/// Confirmación por deslizamiento para dinero crítico: hay
/// que arrastrar el pulgar hasta el final del carril; si se
/// suelta antes, vuelve solo. Un toque NO confirma nada.
class DeslizarConfirmar extends StatefulWidget {
  final String texto;
  final bool habilitado;
  final VoidCallback onConfirmar;

  /// 1.32 (O2F2): el rótulo mientras la confirmación viaja
  /// («Liquidando…» en la hoja de arqueo, la cuna de la
  /// primitiva; «Anulando…», «Cerrando…» en los demás
  /// flujos de dinero que la adoptan).
  final String textoConfirmando;

  const DeslizarConfirmar({
    super.key,
    required this.texto,
    required this.habilitado,
    required this.onConfirmar,
    this.textoConfirmando = 'Liquidando…',
  });

  @override
  State<DeslizarConfirmar> createState() => _DeslizarConfirmarState();
}

class _DeslizarConfirmarState extends State<DeslizarConfirmar> {
  double _progreso = 0; // 0..1
  bool _confirmado = false;

  /// 1.32 (Corte B, H-CB-2 — Argón): si la hoja ABORTA tras
  /// la confirmación (la guarda de reverificación D2-04 de
  /// Liquidar Arqueo pide revisar la cifra, o el intento
  /// lanzó) el padre deshabilita y luego REHABILITA el
  /// control sin cerrar la hoja: el carril debe nacer de
  /// nuevo. Sin esto quedaba clavado al final con el rótulo
  /// de «confirmando» y ningún arrastre volvía a confirmar.
  /// Cambiar el texto (p. ej. la hoja cambia de modo) tras
  /// confirmar también reinicia: aquella confirmación era
  /// para OTRO rótulo.
  @override
  void didUpdateWidget(DeslizarConfirmar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!oldWidget.habilitado && widget.habilitado) ||
        oldWidget.texto != widget.texto) {
      _confirmado = false;
      _progreso = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    const alto = 56.0;
    return LayoutBuilder(
      builder: (context, cons) {
        final ancho = cons.maxWidth;
        final recorrido = (ancho - alto).clamp(1.0, double.infinity);
        return Container(
          key: const ValueKey('deslizar-carril'),
          height: alto,
          decoration: BoxDecoration(
            color: widget.habilitado
                ? AppColores.naranja.withValues(alpha: 0.16)
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(alto / 2),
            border: Border.all(color: AppColores.naranja),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  _confirmado ? widget.textoConfirmando : widget.texto,
                  style: AppTexto.etiqueta.copyWith(
                    fontWeight: FontWeight.w700,
                    color: widget.habilitado
                        ? null
                        : AppColores.textoSecundario(context),
                  ),
                ),
              ),
              Positioned(
                left: _progreso * recorrido,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  key: const ValueKey('deslizar-pulgar'),
                  onHorizontalDragUpdate: widget.habilitado && !_confirmado
                      ? (d) => setState(() {
                            _progreso =
                                (_progreso + d.delta.dx / recorrido)
                                    .clamp(0.0, 1.0);
                          })
                      : null,
                  onHorizontalDragEnd: widget.habilitado && !_confirmado
                      ? (_) {
                          if (_progreso >= 0.92) {
                            setState(() {
                              _progreso = 1;
                              _confirmado = true;
                            });
                            Tacto.confirmacion();
                            widget.onConfirmar();
                          } else {
                            setState(() => _progreso = 0);
                          }
                        }
                      : null,
                  child: Container(
                    width: alto,
                    decoration: const BoxDecoration(
                      color: AppColores.naranja,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.chevron_right_rounded,
                        color: AppColores.sobreMarca, size: 30),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 1.32 (Oleada 2 Fase 2): HOJA DE IMPORTE con el pad del
/// mostrador — la puerta ÚNICA para teclear dinero sin el
/// teclado del sistema en los flujos que viven dentro de
/// otros diálogos o formularios (precio de suplemento, gasto,
/// adelanto, cobro personalizado, editar pago, entregado del
/// arqueo, compra). Muestra el importe en grande, los
/// atajos opcionales (los importes rápidos del plano:
/// 200/600/1200/1500/2000/2500 en los cobros) y el
/// [PadNumerico]; devuelve el texto compuesto o null si se
/// cancela. La validación del importe sigue siendo la de
/// cada flujo: la hoja solo captura.
Future<String?> mostrarHojaMontoPad(
  BuildContext context, {
  required String titulo,
  required String valorInicial,
  String? sufijo,
  bool decimales = true,
  List<({String etiqueta, String valor})>? rapidos,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _HojaMontoPad(
      titulo: titulo,
      valorInicial: valorInicial,
      sufijo: sufijo,
      decimales: decimales,
      rapidos: rapidos,
    ),
  );
}

class _HojaMontoPad extends StatefulWidget {
  final String titulo;
  final String valorInicial;
  final String? sufijo;
  final bool decimales;
  final List<({String etiqueta, String valor})>? rapidos;

  const _HojaMontoPad({
    required this.titulo,
    required this.valorInicial,
    this.sufijo,
    this.decimales = true,
    this.rapidos,
  });

  @override
  State<_HojaMontoPad> createState() => _HojaMontoPadState();
}

class _HojaMontoPadState extends State<_HojaMontoPad> {
  late String _valor = widget.valorInicial;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppEspacio.lg,
        right: AppEspacio.lg,
        top: AppEspacio.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom +
            AppEspacio.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.titulo, style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.md, vertical: AppEspacio.sm),
            decoration: BoxDecoration(
              border: Border.all(color: AppColores.borde(context)),
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
            child: Text(
              _valor.isEmpty ? '0' : _valor,
              style: AppTexto.display.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: _valor.isEmpty
                    ? AppColores.textoSecundario(context)
                    : null,
              ),
              textAlign: TextAlign.end,
            ),
          ),
          if (widget.sufijo != null)
            Align(
              alignment: Alignment.centerRight,
              child: Text(widget.sufijo!,
                  style: AppTexto.metadato),
            ),
          if (widget.rapidos != null && widget.rapidos!.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.sm),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                for (final r in widget.rapidos!)
                  ActionChip(
                    label: Text(r.etiqueta),
                    onPressed: () =>
                        setState(() => _valor = r.valor),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppEspacio.sm),
          PadNumerico(
            valor: _valor,
            decimales: widget.decimales,
            onCambia: (v) => setState(() => _valor = v),
          ),
          const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _valor),
                  child: const Text('Aceptar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Campo de importe SIN teclado: se ve como un campo de la
/// casa (misma decoración que CampoTexto) y al tocarlo abre
/// [mostrarHojaMontoPad]. El llamador guarda el texto
/// devuelto en su controlador de siempre y repinta; todas
/// las validaciones del flujo quedan donde estaban.
class CampoMontoPad extends StatelessWidget {
  final String etiqueta;
  final String valor;
  final String? sufijo;
  final IconData? icono;
  final VoidCallback onTap;

  const CampoMontoPad({
    super.key,
    required this.etiqueta,
    required this.valor,
    this.sufijo,
    this.icono,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: InputDecorator(
        isEmpty: valor.isEmpty,
        decoration: InputDecoration(
          labelText: etiqueta,
          suffixText: sufijo,
          prefixIcon: icono != null ? Icon(icono) : null,
          suffixIcon: const Icon(Icons.dialpad_rounded, size: 20),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadio.md),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadio.md),
            borderSide: BorderSide(color: AppColores.borde(context)),
          ),
          filled: true,
          fillColor: AppColores.superficie(context),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.lg, vertical: AppEspacio.md),
        ),
        child: Text(
          valor.isEmpty ? 'Toca para escribir el importe' : valor,
          style: AppTexto.cuerpo.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: valor.isEmpty
                ? AppColores.textoSecundario(context)
                : null,
          ),
        ),
      ),
    );
  }
}

/// Confirmación de dinero crítico por DESLIZAMIENTO (la
/// hermana de DialogoApp.confirmar para los cierres y
/// anulaciones del plano transversal): el mensaje se lee y
/// la confirmación exige arrastrar el pulgar — un toque
/// accidental no cierra una caja ni anula un pago. Devuelve
/// true SOLO si se deslizó hasta el final.
///
/// Es una HOJA modal, no un AlertDialog, a propósito:
/// DeslizarConfirmar usa LayoutBuilder, que no responde
/// dimensiones intrínsecas, y el AlertDialog las pide al
/// medir título/contenido (el diálogo no pinta); en la hoja
/// el carril ya vive probado desde la Fase 1.
Future<bool> confirmarDeslizando(
  BuildContext context, {
  required String titulo,
  required String mensaje,
  required String textoDeslizar,
  String textoConfirmando = 'Un momento…',
  IconData icono = Icons.help_outline_rounded,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, AppEspacio.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: AppColores.textoSecundario(ctx)),
              const SizedBox(width: AppEspacio.sm),
              Expanded(child: Text(titulo, style: AppTexto.titulo)),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          Text(mensaje, style: AppTexto.cuerpo),
          const SizedBox(height: AppEspacio.lg),
          DeslizarConfirmar(
            texto: textoDeslizar,
            textoConfirmando: textoConfirmando,
            habilitado: true,
            onConfirmar: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: AppEspacio.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}


/// 1.32 (integración, RD-8): scroll horizontal CON PISTA —
/// envuelve una fila desplazable (los segmentos de los
/// Pilares 2 y 4) con un degradado en el borde hacia el
/// que aún hay contenido. Sin la pista, con la fuente al
/// 130–200 % el último segmento quedaba fuera de pantalla
/// y la sección parecía no existir («¿dónde está Avisos
/// WhatsApp?»). El degradado va del color de fondo de la
/// cáscara a transparente, no tapa toques (IgnorePointer)
/// y desaparece al llegar al final (y aparece a la
/// izquierda al avanzar, si se pide con [pistaIzquierda]).
class ScrollHorizontalConPista extends StatefulWidget {
  final Widget child;
  final Color colorFondo;
  final bool pistaIzquierda;

  const ScrollHorizontalConPista({
    super.key,
    required this.child,
    required this.colorFondo,
    this.pistaIzquierda = true,
  });

  @override
  State<ScrollHorizontalConPista> createState() =>
      _ScrollHorizontalConPistaState();
}

class _ScrollHorizontalConPistaState
    extends State<ScrollHorizontalConPista> {
  final ScrollController _ctrl = ScrollController();
  bool _hayMasDerecha = false;
  bool _hayMasIzquierda = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_recalcular);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_recalcular);
    _ctrl.dispose();
    super.dispose();
  }

  void _recalcular() {
    if (!_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final derecha = pos.extentAfter > 1;
    final izquierda = pos.extentBefore > 1;
    if (derecha != _hayMasDerecha || izquierda != _hayMasIzquierda) {
      setState(() {
        _hayMasDerecha = derecha;
        _hayMasIzquierda = izquierda;
      });
    }
  }

  Widget _degradado(bool haciaDerecha) {
    return Positioned(
      top: 0,
      bottom: 0,
      right: haciaDerecha ? 0 : null,
      left: haciaDerecha ? null : 0,
      width: 28,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: haciaDerecha
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              end: haciaDerecha
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              colors: [
                widget.colorFondo.withValues(alpha: 0),
                widget.colorFondo,
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Tras el primer frame se sabe si el contenido desborda.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _recalcular());
    return Stack(
      children: [
        SingleChildScrollView(
          controller: _ctrl,
          scrollDirection: Axis.horizontal,
          child: widget.child,
        ),
        if (_hayMasDerecha) _degradado(true),
        if (widget.pistaIzquierda && _hayMasIzquierda)
          _degradado(false),
      ],
    );
  }
}
