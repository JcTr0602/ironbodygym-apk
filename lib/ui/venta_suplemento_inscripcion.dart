// Inscripción + venta de suplemento en una sola operación.
//
// Para el comprador externo que quiere inscribirse en el gym al momento
// de comprar: crea el cliente (con su mensualidad inicial) y registra
// la venta en una única op 'inscripcion_venta_suplemento'. El servidor
// aplica la promo "mes gratis" si está activa y marca la venta con
// via_inscripcion=1.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class VentaSuplementoInscripcionScreen extends StatefulWidget {
  final Map<String, dynamic> suplemento;
  final int cantidad;
  final double precio;
  final String moneda;
  final double? usdTasa;

  const VentaSuplementoInscripcionScreen({
    super.key,
    required this.suplemento,
    required this.cantidad,
    required this.precio,
    required this.moneda,
    this.usdTasa,
  });

  @override
  State<VentaSuplementoInscripcionScreen> createState() =>
      _VentaSuplementoInscripcionScreenState();
}

class _VentaSuplementoInscripcionScreenState
    extends State<VentaSuplementoInscripcionScreen> {
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _carnet = TextEditingController();
  String? _sexo; // 'M' | 'F' | null (sin especificar)
  bool _promoActiva = false;
  bool _guardando = false;

  double get _total => widget.precio * widget.cantidad;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        setState(() {
          _promoActiva =
              (aj['promo_suplementos'] as num?)?.toInt() != 0;
        });
      }
    });
  }

  @override
  void dispose() {
    _nombre.dispose();
    _telefono.dispose();
    _carnet.dispose();
    super.dispose();
  }

  Future<void> _confirmar() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      await DialogoApp.confirmar(context,
          titulo: 'Falta el nombre',
          mensaje: 'Escribe el nombre del nuevo cliente.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    final carnet = _carnet.text.trim();
    if (carnet.isNotEmpty && !RegExp(r'^\d{6}$').hasMatch(carnet)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el carnet',
          mensaje: 'El carnet debe tener 6 dígitos (o déjalo vacío).',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }

    final totalTxt = widget.moneda == 'USD'
        ? '${_total.toStringAsFixed(2)} USD'
            ' (≈ ${(_total * (widget.usdTasa ?? 0)).toStringAsFixed(0)} CUP)'
        : '${_total.toStringAsFixed(0)} CUP';
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar inscripción + venta',
      icono: Icons.person_add,
      mensaje: 'Cliente: $nombre\n'
          'Venta: ${widget.suplemento['nombre']} x${widget.cantidad}'
          ' = $totalTxt'
          '${_promoActiva ? '\n\nSe le asignará 1 mes de mensualidad gratis (promo activa).' : ''}',
      aceptar: 'Confirmar',
    );
    if (!ok) return;

    setState(() => _guardando = true);
    try {
      final opUuid = const Uuid().v4();
      final hoy =
          DateTime.now().toIso8601String().substring(0, 10);
      final telefono = _telefono.text.trim();
      await LocalDb.instance.queueOp(
        opUuid: opUuid,
        tipo: 'inscripcion_venta_suplemento',
        payload: {
          'cliente': {
            'nombre': nombre,
            if (telefono.isNotEmpty) 'telefono': telefono,
            if (_sexo != null) 'sexo': _sexo,
            if (carnet.isNotEmpty) 'carnet': carnet,
          },
          'venta': {
            'suplemento_id': widget.suplemento['id'],
            'cantidad': widget.cantidad,
            'precio': widget.precio,
            'moneda': widget.moneda,
            if (widget.moneda == 'USD' && widget.usdTasa != null)
              'usd_tasa': widget.usdTasa,
          },
          'fecha': hoy,
        },
      );
      // Actualización optimista: la venta aparece en el historial
      // sin esperar al sync. Id temporal negativo; se elimina cuando
      // la op queda aplicada (limpiarOptimista en el push).
      final auth = AuthService();
      final tempId = -DateTime.now().millisecondsSinceEpoch;
      await LocalDb.instance.upsertMirror(
        'ventas_suplementos',
        tempId,
        {
          'id': tempId,
          'op_uuid': opUuid,
          'optimista': 1,
          'suplemento_id': widget.suplemento['id'],
          'cantidad': widget.cantidad,
          'precio': widget.precio,
          'moneda': widget.moneda,
          if (widget.moneda == 'USD' && widget.usdTasa != null)
            'usd_tasa': widget.usdTasa,
          'total': _total,
          'comprador_tipo': 'cliente',
          'comprador_nombre': nombre,
          'cliente_id': null,
          'registrado_por': auth.telegramId,
          'registrado_por_nombre': auth.displayName,
          'fecha': hoy,
          'via_inscripcion': 1,
          'promo_mes': _promoActiva ? 1 : 0,
          // Regla de Jc: el efectivo (CUP o USD) del entrenador
          // queda pendiente; lo del dueño queda entregado.
          'entregado': auth.isOwner ? 1 : 0,
        },
        0,
      );
      unawaited(SyncEngine.instance.push());
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: const Text('Inscripción + venta')),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(
              titulo: 'Datos del cliente'),
          CampoTexto(
            controller: _nombre,
            etiqueta: 'Nombre completo *',
            icono: Icons.person_outline,
          ),
          const SizedBox(height: AppEspacio.sm),
          CampoTexto(
            controller: _telefono,
            etiqueta: 'Teléfono (opcional)',
            icono: Icons.phone_outlined,
            teclado: TextInputType.phone,
          ),
          const SizedBox(height: AppEspacio.sm),
          const Text('Sexo', style: AppTexto.secundario),
          const SizedBox(height: 4),
          Wrap(
            spacing: AppEspacio.sm,
            children: [
              ChoiceChip(
                label: const Text('Sin especificar'),
                selected: _sexo == null,
                selectedColor: AppColores.naranja
                    .withValues(alpha: 0.2),
                onSelected: (_) =>
                    setState(() => _sexo = null),
              ),
              ChoiceChip(
                label: const Text('Masculino'),
                selected: _sexo == 'M',
                selectedColor: AppColores.naranja
                    .withValues(alpha: 0.2),
                onSelected: (_) =>
                    setState(() => _sexo = 'M'),
              ),
              ChoiceChip(
                label: const Text('Femenino'),
                selected: _sexo == 'F',
                selectedColor: AppColores.naranja
                    .withValues(alpha: 0.2),
                onSelected: (_) =>
                    setState(() => _sexo = 'F'),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          CampoTexto(
            controller: _carnet,
            etiqueta: 'Carnet (6 dígitos, opcional)',
            icono: Icons.badge_outlined,
            teclado: TextInputType.number,
          ),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(
              titulo: 'Mensualidad inicial'),
          const Tarjeta(
            child: Row(
              children: [
                Icon(Icons.payments_outlined,
                    color: AppColores.naranja),
                SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                    'Se cobrará la mensualidad vigente en efectivo al inscribir.',
                    style: AppTexto.cuerpo,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(
              titulo: 'Venta del suplemento'),
          Tarjeta(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text('${widget.suplemento['nombre']}',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 4),
                Text(
                  _lineaVenta(),
                  style: AppTexto.cuerpo,
                ),
              ],
            ),
          ),
          if (_promoActiva) ...[
            const SizedBox(height: AppEspacio.md),
            Container(
              padding:
                  const EdgeInsets.all(AppEspacio.md),
              decoration: BoxDecoration(
                color: AppColores.naranja
                    .withValues(alpha: 0.12),
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
                border: Border.all(
                    color: AppColores.naranja
                        .withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.card_giftcard,
                      color: AppColores.naranja),
                  SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: Text(
                      'Se le asignará 1 mes gratis por la promo.',
                      style: AppTexto.cuerpo,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppEspacio.lg),
          BotonPrimario(
            texto: _guardando
                ? 'Registrando…'
                : 'Confirmar inscripción + venta',
            onPressed:
                _guardando ? null : _confirmar,
          ),
        ],
      ),
    );
  }

  String _lineaVenta() {
    final base =
        '${widget.cantidad} x ${widget.precio.toStringAsFixed(2)} ${widget.moneda}';
    if (widget.moneda == 'USD' && widget.usdTasa != null) {
      return '$base (tasa ${widget.usdTasa!.toStringAsFixed(2)})\n'
          'Total: ${_total.toStringAsFixed(2)} USD'
          ' (≈ ${(_total * widget.usdTasa!).toStringAsFixed(0)} CUP)';
    }
    return '$base\nTotal: ${_total.toStringAsFixed(0)} ${widget.moneda}';
  }
}
