/// 💸 Cuentas por cobrar: clientes vencidos ordenados por monto
/// adeudado (mayor primero). El dinero dormido, visible.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../fotos.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
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
    final hoy = DateTime.now();
    final todos = <Map<String, dynamic>>[
      ...await atrasados(masDe30: false),
      ...await atrasados(masDe30: true),
    ];
    final res = <Map<String, dynamic>>[];
    double total = 0;
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
      // Monto mensual del cliente (si el espejo lo trae).
      final monto =
          (c['monto_mensualidad'] as num?)?.toDouble() ??
              (c['monto'] as num?)?.toDouble() ??
              0;
      total += monto;
      res.add({
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
      appBar: AppBar(
        title: const Text('Cuentas por cobrar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding:
                    const EdgeInsets.all(AppEspacio.lg),
                children: [
                  const SyncBanner(),
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
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.md),
                  if (_cuentas.isEmpty)
                    const EstadoVacio(
                      icono: Icons.check_circle,
                      titulo: 'Sin cuentas por cobrar',
                      subtitulo:
                          'Todos los clientes activos están al día.',
                    )
                  else
                    for (final c in _cuentas)
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
                              (c['dias'] as int) == 0
                                  ? 'Vence hoy'
                                  : 'Vencido hace ${c['dias']} días\n'
                                      'Vence: ${fmtFecha(c['pagado_hasta'] as String?)}',
                            ),
                            isThreeLine: true,
                            trailing: Text(
                              '${fmtMonto(c['monto'])} CUP',
                              style:
                                  AppTexto.subtitulo.copyWith(
                                      color:
                                          AppColores.naranja),
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
    );
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

  Future<void> _cargar() async {
    final f =
        await FotoCache.instance.enCache(widget.fotoStorage);
    if (mounted) setState(() => _foto = f);
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
