// lib/ui/arranque_marca.dart
// 1.35 (UX-14): momento de marca al abrir. El rayo y el
// wordmark sobre grafito se montan SOBRE la carga que la
// app ya hace al arrancar (la raíz pinta la pantalla real
// desde el primer frame, debajo): no se añade ni un
// milisegundo de espera, la capa es IgnorePointer (jamás
// bloquea un toque) y se retira sola tras una pausa breve
// y un fundido corto. Con «reducir movimiento» (sistema o
// preferencia de la app, que ya viaja en MediaQuery) el
// fundido es instantáneo. Solo vive en el arranque en
// frío: la raíz lo monta una vez por proceso.
import 'dart:async';

import 'package:flutter/material.dart';

import 'diseno.dart';

/// Cuánto se queda la marca tras el primer frame antes de
/// fundirse. Es pausa de LECTURA sobre la carga existente,
/// no una espera añadida: la pantalla de debajo ya es la
/// real y recibe los toques desde el primer instante.
const duracionMarcaArranque = Duration(milliseconds: 450);

class EnvoltorioArranqueMarca extends StatefulWidget {
  final Widget child;
  const EnvoltorioArranqueMarca({super.key, required this.child});

  @override
  State<EnvoltorioArranqueMarca> createState() =>
      _EnvoltorioArranqueMarcaState();
}

class _EnvoltorioArranqueMarcaState
    extends State<EnvoltorioArranqueMarca> {
  /// 0 = marca visible · 1 = fundiéndose · 2 = fuera.
  int _fase = 0;
  Timer? _temporizador;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _temporizador = Timer(duracionMarcaArranque, () {
        if (mounted) setState(() => _fase = 1);
      });
    });
  }

  @override
  void dispose() {
    _temporizador?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fase == 2) return widget.child;
    final sinMovimiento = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _fase == 0 ? 1 : 0,
              duration: sinMovimiento
                  ? Duration.zero
                  : const Duration(milliseconds: 250),
              onEnd: () {
                // Con duración cero (reducir movimiento) el
                // fin llega DURANTE el build: el setState se
                // difiere al post-frame o explota.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _fase == 1) {
                    setState(() => _fase = 2);
                  }
                });
              },
              child: const _MarcaArranque(),
            ),
          ),
        ),
      ],
    );
  }
}

/// La composición de marca: arte del rayo a pantalla
/// completa con velo grafito y el wordmark al pie.
class _MarcaArranque extends StatelessWidget {
  const _MarcaArranque();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColores.pizarra,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/arte_marca_rayo.jpg',
            fit: BoxFit.cover,
            // Si el arte fallara, la marca sigue siendo el
            // wordmark sobre grafito: nunca una caja rota.
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColores.pizarra.withValues(alpha: 0.35),
                  AppColores.pizarra.withValues(alpha: 0.15),
                  AppColores.pizarra.withValues(alpha: 0.90),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: const Alignment(0, 0.62),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'IRON BODY',
                    style: AppTexto.display.copyWith(
                      color: Colors.white,
                      fontSize: 44,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: AppEspacio.xs),
                  Container(
                    width: 56,
                    height: 3,
                    decoration: BoxDecoration(
                      color: AppColores.naranja,
                      borderRadius:
                          BorderRadius.circular(AppRadio.circular),
                    ),
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'G Y M',
                    style: AppTexto.etiqueta.copyWith(
                      color: Colors.white70,
                      letterSpacing: 6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
