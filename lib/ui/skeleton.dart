/// v1.2.5 (3.1): skeletons de carga.
///
/// Formas cercanas al contenido real, en carbón/naranja.
/// Respetan "reducir movimiento" (sin animación si está activo).
library;
import 'package:flutter/material.dart';

import 'componentes.dart';
import 'diseno.dart';

/// Una línea de skeleton con ancho configurable.
class SkeletonLinea extends StatelessWidget {
  final double ancho;
  final double alto;
  const SkeletonLinea(
      {super.key, this.ancho = double.infinity, this.alto = 14});

  @override
  Widget build(BuildContext context) {
    final reducir = MediaQuery.of(context).disableAnimations;
    final color = AppColores.textoSecundario(context)
        .withValues(alpha: 0.15);
    final barra = Container(
      width: ancho,
      height: alto,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(alto / 2),
      ),
    );
    if (reducir) return barra;
    // Pulso sutil (no rotación) para no marear.
    return _Pulso(child: barra);
  }
}

/// Skeleton para una tarjeta de lista (título + 2 líneas).
class SkeletonTarjeta extends StatelessWidget {
  const SkeletonTarjeta({super.key});

  @override
  Widget build(BuildContext context) {
    return const Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonLinea(ancho: 160, alto: 16),
          SizedBox(height: 8),
          SkeletonLinea(ancho: 240),
          SizedBox(height: 8),
          SkeletonLinea(ancho: 200),
        ],
      ),
    );
  }
}

/// Lista de skeletons (para usar mientras carga).
class SkeletonLista extends StatelessWidget {
  final int items;
  const SkeletonLista({super.key, this.items = 3});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < items; i++) ...[
          const SkeletonTarjeta(),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// (M2-BC C5) Esqueleto estructural del Dashboard del dueño:
/// espejo de la pantalla real (tarjeta héroe + bloque de
/// urgencias + fila de ingresos + tarjeta de balance) con las
/// mismas alturas aproximadas, para que nada «salte» cuando
/// llegan las cifras. Sustituye al spinner genérico.
class SkeletonDashboard extends StatelessWidget {
  const SkeletonDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: const [
        // Héroe del mes.
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLinea(ancho: 120, alto: 12),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 200, alto: 30),
              SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: SkeletonLinea(ancho: 90)),
                  SizedBox(width: 16),
                  Expanded(child: SkeletonLinea(ancho: 90)),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: 16),
        SkeletonLinea(ancho: 140, alto: 16),
        SizedBox(height: 8),
        SkeletonTarjeta(),
        SizedBox(height: 16),
        SkeletonLinea(ancho: 100, alto: 16),
        SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: SkeletonTarjeta()),
            SizedBox(width: 8),
            Expanded(child: SkeletonTarjeta()),
            SizedBox(width: 8),
            Expanded(child: SkeletonTarjeta()),
          ],
        ),
        SizedBox(height: 16),
        SkeletonTarjeta(),
      ],
    );
  }
}

/// (M2-BC C5) Esqueleto estructural de Pendiente: la tarjeta
/// de total y dos tarjetas de entrenador con su forma real
/// (avatar + nombre + monto).
class SkeletonPendiente extends StatelessWidget {
  const SkeletonPendiente({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(AppEspacio.md),
          child: Tarjeta(
            padding: EdgeInsets.all(AppEspacio.lg),
            child: Column(
              children: [
                SkeletonLinea(ancho: 220, alto: 30),
                SizedBox(height: 8),
                SkeletonLinea(ancho: 160),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg),
            children: const [
              SkeletonTarjeta(),
              SizedBox(height: 8),
              SkeletonTarjeta(),
            ],
          ),
        ),
      ],
    );
  }
}

/// (M2-BC C5) Esqueleto estructural del Arqueo: filas de
/// entrenador (avatar + nombre + montos) con la forma de la
/// lista real.
class SkeletonArqueo extends StatelessWidget {
  const SkeletonArqueo({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: const [
        SkeletonTarjeta(),
        SizedBox(height: 8),
        SkeletonTarjeta(),
        SizedBox(height: 8),
        SkeletonTarjeta(),
      ],
    );
  }
}

/// Pulso de opacidad (respeta reducir movimiento vía el padre).
class _Pulso extends StatefulWidget {
  final Widget child;
  const _Pulso({required this.child});

  @override
  State<_Pulso> createState() => _PulsoState();
}

class _PulsoState extends State<_Pulso>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.5, end: 1.0).animate(_c),
      child: widget.child,
    );
  }
}
