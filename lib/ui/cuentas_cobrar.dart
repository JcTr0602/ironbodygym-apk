/// 💸 Vencidos por cobrar: clientes vencidos ordenados por monto
/// adeudado (mayor primero). El dinero dormido, visible.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../cliente_protegido.dart';
import '../fotos.dart';
import '../negocio.dart';
import '../precio_cobro.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class CuentasCobrarScreen extends StatefulWidget {
  const CuentasCobrarScreen({super.key});

  @override
  State<CuentasCobrarScreen> createState() =>
      _CuentasCobrarScreenState();
}

class _CuentasCobrarScreenState
    extends State<CuentasCobrarScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _cuentas = [];
  double _total = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final hoy = ahoraHabana();
    final todos = <Map<String, dynamic>>[
      ...await atrasados(masDe30: false),
      ...await atrasados(masDe30: true),
    ]
        // P2#5: los protegidos no aparecen para un no-dueño.
        .where((c) => !esVistaProtegida(c))
        .toList();
    final res = <Map<String, dynamic>>[];
    double total = 0;
    // v1.3.2 (Argón #16): tarifa vigente una sola vez (fuera del loop).
    final pr = await preciosVigentes();
    for (final c in todos) {
      final ph = '${c['pagado_hasta'] ?? ''}';
      int dias = 0;
      if (ph.length >= 10) {
        final f = DateTime.tryParse(ph.substring(0, 10));
        if (f != null) {
          dias = hoy
              .difference(
                  DateTime(f.year, f.month, f.day))
              .inDays;
          if (dias < 0) dias = 0;
        }
      }
      // P2#5: precioCobroParaCliente respeta tarifas especiales
      // (el esMenor?menores:mensual viejo las ignoraba). Casa ya
      // queda fuera en atrasados(); si aun así llegara, su precio
      // es 0 y no infla el total.
      final precio = await precioCobroParaCliente(
        cliente: c,
        periodo: 'mensual',
        metodo: 'efectivo',
        precios: pr,
      );
      final monto = precio.monto;
      total += monto;
      res.add({
        'cliente_id': (c['id'] as num?)?.toInt(),
        'nombre': '${c['nombre'] ?? '—'}',
        'dias': dias,
        'monto': monto,
        'pagado_hasta': ph.length >= 10
            ? ph.substring(0, 10)
            : ph,
        'foto_storage': c['foto_storage'] as String?,
      });
    }
    // Mayor monto primero: el dinero más gordo arriba.
    res.sort((a, b) =>
        (b['monto'] as double).compareTo(a['monto'] as double));
    if (mounted) {
      setState(() {
        _cuentas = res;
        _total = total;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(
        context,
        'Vencidos por cobrar',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando cuentas por cobrar…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding:
                    const EdgeInsets.all(AppEspacio.lg),
                children: [
                  const SyncBanner(alcance: 'pagos'),
                  const SizedBox(height: AppEspacio.sm),
                  // Hero: tarjeta carbón con el total
                  // (texto claro legible en ambos temas).
                  Tarjeta(
                    color: AppColores.carbon,
                    child: Column(
                      children: [
                        Text(
                          'Dinero dormido en vencidos',
                          style: AppTexto.secundario.copyWith(
                              color: Colors.white70),
                        ),
                        Text(
                          '${fmtMonto(_total)} CUP',
                          style: AppTexto.display.copyWith(
                              color: AppColores.naranja),
                        ),
                        Text(
                          '${_cuentas.length} clientes vencidos',
                          style: AppTexto.minuscula.copyWith(
                              color: Colors.white70),
                        ),
                        // 1.25 T28: la regla, dicha: cada
                        // monto es UNA mensualidad (la tarifa
                        // del cliente), no su deuda acumulada
                        // — uno de hace 60 días no «debe» el
                        // doble en esta pantalla.
                        Text(
                          'Una mensualidad por cliente '
                          '(su tarifa), no la deuda acumulada',
                          textAlign: TextAlign.center,
                          style: AppTexto.minuscula.copyWith(
                              color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.md),
                  if (_cuentas.isEmpty)
                    const EstadoVacio(
                      icono: Icons.check_circle_rounded,
                      titulo: 'Sin vencidos por cobrar',
                      subtitulo:
                          'Todos los clientes activos están al día.',
                    )
                  else
                    // 1.25 T28: agrupado por antigüedad con
                    // subtotal por grupo (antes una sola
                    // lista por monto: el de 5 días y el de
                    // 60 se veían iguales).
                    for (final grupo in _gruposAntiguedad()) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                            top: AppEspacio.sm,
                            bottom: AppEspacio.xs),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(grupo.$1,
                                style: AppTexto.subtitulo),
                            Text(
                              '${fmtMonto(grupo.$3)} CUP',
                              style:
                                  AppTexto.secundario.copyWith(
                                      fontWeight:
                                          FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      for (final c in grupo.$2)
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppEspacio.sm),
                        child: Tarjeta(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: _FotoConDias(
                              fotoStorage: c['foto_storage']
                                  as String?,
                              dias: c['dias'] as int,
                            ),
                            title:
                                Text('${c['nombre']}'),
                            subtitle: Text(
                              (c['pagado_hasta'] as String).isEmpty
                                  ? 'Sin fecha de vencimiento'
                                  : (c['dias'] as int) == 0
                                      ? 'Vence hoy'
                                      : 'Vencido hace ${c['dias']} días\n'
                                          'Venció: ${fmtFecha(c['pagado_hasta'] as String?)}',
                            ),
                            isThreeLine: true,
                            trailing: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              crossAxisAlignment:
                                  CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${fmtMonto(c['monto'])} CUP',
                                  style: AppTexto.subtitulo
                                      .copyWith(
                                          color: AppColores
                                              .naranja),
                                ),
                                Text('tarifa mensual',
                                    style: AppTexto.minuscula
                                        .copyWith(
                                            color: AppColores
                                                .textoSecundario(
                                                    context))),
                              ],
                            ),
                            // P2#5: tocar abre la ficha (desde donde
                            // se cobra); antes la fila no tenía onTap.
                            onTap: () {
                              final cid = c['cliente_id'] as int?;
                              if (cid == null || cid == 0) return;
                              Navigator.of(context).push(
                                  RutaIron(
                                      builder: (_) => FichaScreen(
                                          clienteId: cid)));
                            },
                          ),
                        ),
                      ),
                    ],
                ],
              ),
            ),
    );
  }

  /// 1.25 T28: grupos por antigüedad del vencimiento, con
  /// subtotal (cada monto sigue siendo UNA mensualidad).
  /// Dentro de cada grupo se conserva el orden por monto
  /// descendente de _cargar.
  List<(String, List<Map<String, dynamic>>, double)>
      _gruposAntiguedad() {
    bool sinFecha(Map<String, dynamic> c) =>
        (c['pagado_hasta'] as String).isEmpty;
    final bandas =
        <(String, bool Function(Map<String, dynamic>))>[
      (
        'De 1 a 30 días',
        (c) => !sinFecha(c) && (c['dias'] as int) <= 30
      ),
      (
        'Más de 30 días',
        (c) => !sinFecha(c) && (c['dias'] as int) > 30
      ),
      ('Sin fecha de vencimiento', sinFecha),
    ];
    final res = <(String, List<Map<String, dynamic>>, double)>[];
    for (final (titulo, test) in bandas) {
      final filas = _cuentas.where(test).toList();
      if (filas.isEmpty) continue;
      final subtotal = filas.fold<double>(
          0, (s, c) => s + ((c['monto'] as num?)?.toDouble() ?? 0));
      res.add((titulo, filas, subtotal));
    }
    return res;
  }
}

/// Miniatura de foto con insignia de días de atraso (v1.0.11).
class _FotoConDias extends StatefulWidget {
  final String? fotoStorage;
  final int dias;
  const _FotoConDias(
      {required this.fotoStorage, required this.dias});

  @override
  State<_FotoConDias> createState() => _FotoConDiasState();
}

class _FotoConDiasState extends State<_FotoConDias> {
  File? _foto;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void didUpdateWidget(covariant _FotoConDias oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fotoStorage != widget.fotoStorage) {
      setState(() => _foto = null);
      _cargar();
    }
  }

  Future<void> _cargar() async {
    final rutaObjetivo = widget.fotoStorage;
    final f = await FotoCache.instance.enCache(rutaObjetivo);
    if (mounted && widget.fotoStorage == rutaObjetivo) {
      setState(() => _foto = f);
    }
  }

  @override
  Widget build(BuildContext context) {
    final oscuro =
        Theme.of(context).brightness == Brightness.dark;
    final base = widget.dias > 30
        ? AppColores.errorOscuro
        : AppColores.alertaOscuro;
    // En modo oscuro se aclara el frente para mantener contraste.
    final frente = oscuro
        ? (Color.lerp(base, Colors.white, 0.35) ?? base)
        : base;
    final insignia =
        widget.dias > 30 ? AppColores.error : AppColores.alerta;
    return Stack(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor:
              frente.withValues(alpha: 0.15),
          backgroundImage:
              _foto != null ? FileImage(_foto!) : null,
          child: _foto == null
              ? Text(
                  '${widget.dias}d',
                  style: AppTexto.etiqueta
                      .copyWith(color: frente),
                )
              : null,
        ),
        // Insignia con días
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: insignia,
              borderRadius:
                  BorderRadius.circular(AppRadio.sm),
            ),
            child: Text(
              '${widget.dias}d',
              style: AppTexto.minuscula.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
