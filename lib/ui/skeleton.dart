/// v1.2.5 (3.1): skeletons de carga.
///
/// Formas cercanas al contenido real, en carbón/naranja.
/// Respetan "reducir movimiento" (sin animación si está activo).
///
/// REGLA DE LA CASA (1.35, UI-09): una pantalla COMPLETA
/// carga con el esqueleto de su forma (lista, ficha,
/// panel…); el spinner queda solo dentro de botones y
/// acciones puntuales, nunca como cuerpo de una pantalla.
library;
import 'dart:math' as math;

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
    // 1.32 (integración, RD-6): el ancho pedido se acota al
    // disponible — una línea de 240 dp dentro de una tarjeta
    // estrecha (360 dp con paddings dobles) desbordaba en
    // horizontal en vez de encogerse.
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? math.min(ancho, c.maxWidth) : ancho;
      final barra = Container(
        width: w,
        height: alto,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(alto / 2),
        ),
      );
      if (reducir) return barra;
      // Pulso sutil (no rotación) para no marear.
      return _Pulso(child: barra);
    });
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

  /// Alto de una tarjeta del esqueleto con su separación:
  /// 92 de tarjeta (60 de líneas + 2×16 de padding de
  /// Tarjeta) + 8 de separación.
  static const double altoRanura = 100;

  @override
  Widget build(BuildContext context) {
    // 1.32 (integración, RD-6): la columna NO era
    // desplazable y con items: 5 desbordaba ≈30 px a
    // 420×800 donde el padre acota el alto (confirmado en
    // Actividad; la pieza se usa en ~18 pantallas). Un
    // esqueleto no necesita enseñarlos todos: se pintan
    // los que CABEN en el alto disponible (mínimo 1); con
    // alto infinito (dentro de un scroll) salen todos,
    // como antes.
    return LayoutBuilder(builder: (context, c) {
      var n = items;
      if (c.maxHeight.isFinite) {
        n = ((c.maxHeight + 8) / altoRanura).floor().clamp(1, items);
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < n; i++) ...[
            const SkeletonTarjeta(),
            const SizedBox(height: 8),
          ],
        ],
      );
    });
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
        // 1.35 (UX-12): la fila de ingresos es UNA banda
        // segmentada — el esqueleto enseña una sola pieza
        // ancha con sus tres huecos, no tres tarjetas.
        Tarjeta(
          child: Row(
            children: [
              Expanded(child: SkeletonLinea(ancho: 70, alto: 26)),
              SizedBox(width: 16),
              Expanded(child: SkeletonLinea(ancho: 70, alto: 26)),
              SizedBox(width: 16),
              Expanded(child: SkeletonLinea(ancho: 70, alto: 26)),
            ],
          ),
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

/// 1.28 (M4-C1): esqueleto de Listas con la FORMA EXACTA
/// de sus filas reales (FilaCliente): avatar de 56, dos
/// líneas (nombre y chip) y los dos botones redondos del
/// final (avisar y cobrar), con el mismo padding y los
/// divisores en su sitio — la pantalla de cobro diario se
/// siente instantánea y nada salta cuando llegan los datos.
class SkeletonFilasListas extends StatelessWidget {
  final int items;
  const SkeletonFilasListas({super.key, this.items = 6});

  @override
  Widget build(BuildContext context) {
    final reducir = MediaQuery.of(context).disableAnimations;
    final color =
        AppColores.textoSecundario(context).withValues(alpha: 0.15);
    Widget circulo(double d) => Container(
          width: d,
          height: d,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );
    Widget fila() => Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
          child: Row(
            children: [
              circulo(56),
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonLinea(ancho: 150, alto: 16),
                    const SizedBox(height: 8),
                    SkeletonLinea(ancho: 110, alto: 13),
                  ],
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              circulo(40),
              const SizedBox(width: AppEspacio.sm),
              // 1.36 (136-243): el círculo del cobro en la
              // silueta es el botón real: 48 dp.
              circulo(48),
            ],
          ),
        );
    final contenido = ListView.separated(
      itemCount: items,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 84,
          color: AppColores.borde(context)),
      itemBuilder: (_, __) => fila(),
    );
    if (reducir) return contenido;
    return _Pulso(child: contenido);
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
        // 1.35 (UI-13): período del pulso del esqueleto,
        // no una transición: fuera de los tokens.
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

/// 1.28 (M3-C6): esqueleto de la pantalla de Servicios —
/// espejo estructural de su contenido (tarjeta del pomo con
/// su medidor, botones de venta, cuadre y primeras filas de
/// ventas), con el mismo padding de la lista real para que
/// la llegada del dato no mueva nada bajo el dedo.
class SkeletonServicios extends StatelessWidget {
  const SkeletonServicios({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: const [
        // Tarjeta del pomo: etiqueta, nombre, saldo y medidor.
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLinea(ancho: 90, alto: 12),
              SizedBox(height: 8),
              SkeletonLinea(ancho: 190, alto: 24),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 130, alto: 30),
              SizedBox(height: 8),
              SkeletonLinea(alto: 8),
              SizedBox(height: 6),
              SkeletonLinea(ancho: 150, alto: 13),
            ],
          ),
        ),
        SizedBox(height: AppEspacio.md),
        // Botones de venta.
        Row(
          children: [
            Expanded(child: SkeletonLinea(alto: 42)),
            SizedBox(width: AppEspacio.sm),
            Expanded(child: SkeletonLinea(alto: 42)),
            SizedBox(width: AppEspacio.sm),
            Expanded(child: SkeletonLinea(alto: 42)),
          ],
        ),
        SizedBox(height: AppEspacio.md),
        // Cuadre de hoy.
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLinea(ancho: 120, alto: 18),
              SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: SkeletonLinea(ancho: 110, alto: 26)),
                  SizedBox(width: AppEspacio.md),
                  Expanded(child: SkeletonLinea(ancho: 110, alto: 26)),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: AppEspacio.md),
        SkeletonLinea(ancho: 140, alto: 18),
        SizedBox(height: AppEspacio.sm),
        Tarjeta(
          child: Row(
            children: [
              SkeletonLinea(ancho: 36, alto: 36),
              SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonLinea(ancho: 150, alto: 15),
                    SizedBox(height: 6),
                    SkeletonLinea(ancho: 210, alto: 13),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: AppEspacio.sm),
        Tarjeta(
          child: Row(
            children: [
              SkeletonLinea(ancho: 36, alto: 36),
              SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonLinea(ancho: 130, alto: 15),
                    SizedBox(height: 6),
                    SkeletonLinea(ancho: 190, alto: 13),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 1.28 (M3-C6): esqueleto de la pantalla de Nómina —
/// espejo de su estructura (tarjeta del cierre, cabecera del
/// mes y las tarjetas de cada entrenador), mismo padding
/// que la lista real.
class SkeletonNomina extends StatelessWidget {
  const SkeletonNomina({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: const [
        Tarjeta(
          child: Row(
            children: [
              SkeletonLinea(ancho: 42, alto: 42),
              SizedBox(width: AppEspacio.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonLinea(ancho: 170, alto: 17),
                    SizedBox(height: 6),
                    SkeletonLinea(ancho: 230, alto: 13),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: AppEspacio.md),
        SkeletonLinea(ancho: 150, alto: 20),
        SizedBox(height: 6),
        SkeletonLinea(ancho: 210, alto: 14),
        SizedBox(height: AppEspacio.md),
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLinea(ancho: 130, alto: 18),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 240, alto: 14),
              SizedBox(height: 6),
              SkeletonLinea(ancho: 200, alto: 14),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 160, alto: 24),
            ],
          ),
        ),
        SizedBox(height: AppEspacio.md),
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLinea(ancho: 130, alto: 18),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 240, alto: 14),
              SizedBox(height: 6),
              SkeletonLinea(ancho: 200, alto: 14),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 160, alto: 24),
            ],
          ),
        ),
      ],
    );
  }
}

/// (M5-BC C3) Esqueleto estructural del Panel: espejo de
/// AdminScreen — cabecera con avatar, tarjeta de
/// atención, la estación diaria en 2×2, el pulso del mes
/// con sus 3 cifras y las 6 filas de módulo con su
/// pastilla de icono. Sustituye al «Cargando
/// administración…» genérico para que nada salte cuando
/// llegan las cifras.
class SkeletonPanel extends StatelessWidget {
  const SkeletonPanel({super.key});

  Widget _filaModulo() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SkeletonLinea(ancho: 38, alto: 38),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLinea(ancho: 150, alto: 16),
                SizedBox(height: 6),
                SkeletonLinea(ancho: 210, alto: 13),
              ],
            ),
          ),
          SizedBox(width: 8),
          SkeletonLinea(ancho: 16, alto: 16),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        // Cabecera: avatar + nombre + chip.
        const Row(
          children: [
            SkeletonLinea(ancho: 52, alto: 52),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLinea(ancho: 170, alto: 18),
                  SizedBox(height: 6),
                  SkeletonLinea(ancho: 120, alto: 13),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Tarjeta de atención.
        const SkeletonTarjeta(),
        const SizedBox(height: 20),
        // Estación diaria: encabezado + rejilla 2×2.
        const SkeletonLinea(ancho: 140, alto: 16),
        const SizedBox(height: 8),
        const Row(
          children: [
            Expanded(child: SkeletonTarjeta()),
            SizedBox(width: 8),
            Expanded(child: SkeletonTarjeta()),
          ],
        ),
        const SizedBox(height: 8),
        const Row(
          children: [
            Expanded(child: SkeletonTarjeta()),
            SizedBox(width: 8),
            Expanded(child: SkeletonTarjeta()),
          ],
        ),
        const SizedBox(height: 20),
        // Pulso del mes: encabezado + 3 cifras.
        const SkeletonLinea(ancho: 150, alto: 16),
        const SizedBox(height: 8),
        const Row(
          children: [
            Expanded(child: SkeletonTarjeta()),
            SizedBox(width: 8),
            Expanded(child: SkeletonTarjeta()),
            SizedBox(width: 8),
            Expanded(child: SkeletonTarjeta()),
          ],
        ),
        const SizedBox(height: 20),
        // Los 6 módulos.
        for (var i = 0; i < 6; i++) _filaModulo(),
      ],
    );
  }
}

/// (M5-BC C3) Esqueleto de la Bandeja de Premios: el
/// texto de intro y dos tarjetas de vale con su fila de
/// botones, como las reales.
class SkeletonPremiosBandeja extends StatelessWidget {
  const SkeletonPremiosBandeja({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: const [
        SkeletonLinea(ancho: double.infinity, alto: 13),
        SizedBox(height: 6),
        SkeletonLinea(ancho: 280, alto: 13),
        SizedBox(height: 6),
        SkeletonLinea(ancho: 240, alto: 13),
        SizedBox(height: 16),
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkeletonLinea(ancho: 40, alto: 40),
                  SizedBox(width: 10),
                  SkeletonLinea(ancho: 150, alto: 16),
                ],
              ),
              SizedBox(height: 10),
              SkeletonLinea(ancho: 230),
              SizedBox(height: 6),
              SkeletonLinea(ancho: 190),
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SkeletonLinea(ancho: 80, alto: 36),
                  SizedBox(width: 8),
                  SkeletonLinea(ancho: 130, alto: 36),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        SkeletonTarjeta(),
      ],
    );
  }
}

/// (M5-BC C3) Esqueleto del detalle de Premios por
/// cliente: botones de acción, bloque de progreso con su
/// barra y dos tarjetas de historial.
class SkeletonPremiosDetalle extends StatelessWidget {
  const SkeletonPremiosDetalle({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: const [
        Row(
          children: [
            Expanded(child: SkeletonLinea(alto: 40)),
            SizedBox(width: 8),
            Expanded(child: SkeletonLinea(alto: 40)),
          ],
        ),
        SizedBox(height: 16),
        SkeletonLinea(ancho: 150, alto: 16),
        SizedBox(height: 10),
        SkeletonLinea(ancho: 230),
        SizedBox(height: 8),
        SkeletonLinea(alto: 10),
        SizedBox(height: 8),
        SkeletonLinea(ancho: 200),
        SizedBox(height: 16),
        SkeletonLinea(ancho: 150, alto: 16),
        SizedBox(height: 8),
        SkeletonTarjeta(),
        SizedBox(height: 8),
        SkeletonTarjeta(),
      ],
    );
  }
}

/// Esqueleto genérico de AJUSTES (1.30 D6, UI130-22):
/// grupos de filas con su interruptor — la forma de las
/// pantallas de configuración y administración (Servicios
/// Admin lo adopta al cerrar D6). Variante genérica: no
/// espeja una pantalla concreta, espeja el PATRÓN.
class SkeletonAjustes extends StatelessWidget {
  final int grupos;
  const SkeletonAjustes({super.key, this.grupos = 2});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        for (var g = 0; g < grupos; g++) ...[
          if (g > 0) const SizedBox(height: AppEspacio.lg),
          const SkeletonLinea(ancho: 130, alto: 14),
          const SizedBox(height: AppEspacio.sm),
          const Tarjeta(
            child: Column(
              children: [
                _FilaAjusteEsqueleto(),
                SizedBox(height: AppEspacio.md),
                _FilaAjusteEsqueleto(),
                SizedBox(height: AppEspacio.md),
                _FilaAjusteEsqueleto(),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Una fila de ajuste del esqueleto: línea + pastilla de
/// interruptor a la derecha.
class _FilaAjusteEsqueleto extends StatelessWidget {
  const _FilaAjusteEsqueleto();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: SkeletonLinea(ancho: 170)),
        SizedBox(width: AppEspacio.md),
        SkeletonLinea(ancho: 46, alto: 26),
      ],
    );
  }
}

/// Esqueleto genérico de FICHA (1.30 D6, UI130-22):
/// cabecera con el avatar grande y el nombre, y las
/// tarjetas de sección debajo — la forma de la ficha del
/// cliente en su primera carga.
class SkeletonFicha extends StatelessWidget {
  const SkeletonFicha({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1.36 FICHA (136-216): el esqueleto dibuja
              // la silueta REAL de la ficha — banda de la
              // credencial de 196 dp a ancho completo y
              // su tira — no el avatar circular de la
              // cabecera antigua: al cargar, el primer
              // pantallazo ya no salta de forma.
              // Sin Hero en el esqueleto: durante el
              // vuelo el Hero recibe ancho NO acotado y
              // la línea de ancho infinito revienta el
              // layout (cazado por Jornada S14). El
              // destino del vuelo lo monta la credencial
              // en el primer frame con datos (136-214).
              const SkeletonLinea(alto: 196),
              const SizedBox(height: AppEspacio.sm),
              const SkeletonLinea(ancho: 180, alto: 14),
              const SizedBox(height: AppEspacio.xs),
              const SkeletonLinea(ancho: 120, alto: 14),
            ],
          ),
        ),
        SizedBox(height: AppEspacio.md),
        SkeletonTarjeta(),
        SizedBox(height: AppEspacio.md),
        SkeletonTarjeta(),
      ],
    );
  }
}
