// Inscripción + venta de suplemento en una sola operación.
//
// Para el comprador externo que quiere inscribirse en el gym al momento
// de comprar: crea el cliente (con su mensualidad inicial) y registra
// la venta en una única op 'inscripcion_venta_suplemento'. El servidor
// aplica la promo "mes gratis" si está activa y marca la venta con
// via_inscripcion=1.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../negocio.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

/// Construye el payload de la op 'inscripcion_venta_suplemento'.
///
/// Función pura (testeable sin montar la pantalla): el método de pago
/// viaja en el tope del payload y el servidor lo aplica a la
/// inscripción y, por defecto, también a la venta.
Map<String, dynamic> payloadInscripcionVentaSuplemento({
  required String nombre,
  String? telefono,
  String? sexo,
  String? carnet,
  required int suplementoId,
  required int cantidad,
  required double precio,
  required String moneda,
  required double precioOficial,
  String? notaPrecio,
  double? usdTasa,
  required String fecha,
  required String metodoPago,
}) {
  return {
    'cliente': {
      'nombre': nombre,
      if (telefono != null && telefono.isNotEmpty)
        'telefono': telefono,
      if (sexo != null) 'sexo': sexo,
      if (carnet != null && carnet.isNotEmpty) 'carnet': carnet,
    },
    'venta': {
      'suplemento_id': suplementoId,
      'cantidad': cantidad,
      'precio': precio,
      'moneda': moneda,
      'precio_oficial': precioOficial,
      if (notaPrecio != null && notaPrecio.isNotEmpty)
        'nota_precio': notaPrecio,
      if (usdTasa != null && usdTasa > 0) 'usd_tasa': usdTasa,
    },
    'fecha': fecha,
    'metodo_pago': metodoPago,
  };
}

/// 'entregado' optimista de la fila espejo de la venta: la
/// transferencia va directo a la cuenta del dueño y nunca queda
/// pendiente, la registre quien la registre.
int entregadoOptimistaInscripcionVenta({
  required bool esDueno,
  required String metodoPago,
}) =>
    (esDueno || metodoPago == 'transferencia') ? 1 : 0;

class VentaSuplementoInscripcionScreen extends StatefulWidget {
  final Map<String, dynamic> suplemento;
  final int cantidad;
  final double precio;
  final String moneda;
  final double? usdTasa;
  final double precioOficial;
  final String? notaPrecio;

  const VentaSuplementoInscripcionScreen({
    super.key,
    required this.suplemento,
    required this.cantidad,
    required this.precio,
    required this.moneda,
    this.usdTasa,
    required this.precioOficial,
    this.notaPrecio,
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
  // Fase A 1.9: método de pago real de la inscripción + venta.
  // Antes no se elegía ni se enviaba y el servidor caía en
  // 'efectivo' por omisión, descuadrando la caja al pagar por
  // transferencia. El servidor ya acepta 'metodo_pago' (B2).
  String _metodo = 'efectivo'; // 'efectivo' | 'transferencia'
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

    final totalTxt = textoTotalVenta(_total, widget.moneda, widget.usdTasa);
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar inscripción + venta',
      icono: Icons.person_add,
      mensaje: 'Cliente: $nombre\n'
          'Método: ${_metodo == 'efectivo' ? 'Efectivo' : 'Transferencia'}\n'
          'Venta: ${widget.suplemento['nombre']} x${widget.cantidad}'
          ' = $totalTxt'
          '${_promoActiva ? '\n\nSe le asignará 1 mes de mensualidad gratis (promo activa).' : ''}',
      aceptar: 'Confirmar',
    );
    if (!ok) return;

    setState(() => _guardando = true);
    try {
      final opUuid = const Uuid().v4();
      // v1.4.0 (Argón §8): fecha de negocio en hora de La Habana.
      final hoy = hoyHabanaIso();
      final telefono = _telefono.text.trim();
      // Argón #9 (ALTO): verificación de stock + descuento + encolado
      // en UNA sola transacción, igual que registrarVentaSuplemento.
      // Antes eran tres pasos sueltos sin validar stock: una venta
      // con cantidad > stock se encolaba igual y el stock quedaba
      // clampado a 0. Y NO se inserta fila optimista en
      // ventas_suplementos: ese espejo es puro (lo puebla el pull);
      // las lectoras de caja (ventasSuplementosCup/Usd) no filtraban
      // optimista == 1, así que la fila optimista contaba doble
      // mientras la op seguía en cola. La venta aparece en el
      // historial al sincronizar, igual que una venta normal.
      // (limpiarOptimista sigue limpiando filas optimistas viejas.)
      try {
        final sid = (widget.suplemento['id'] as num?)?.toInt();
        if (sid == null) throw Exception('Suplemento sin identificador');
        final db = await LocalDb.instance.db;
        await db.transaction((txn) async {
          final rows = await txn.query('suplementos',
              columns: ['data'], where: 'id = ?', whereArgs: [sid]);
          if (rows.isEmpty) throw Exception('Suplemento no encontrado');
          final data =
              jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
          final stockActual = (data['stock'] as num?)?.toInt() ?? 0;
          if (widget.cantidad > stockActual) {
            throw Exception(
                'Stock insuficiente (quedan $stockActual)');
          }
          data['stock'] = stockActual - widget.cantidad;
          await txn.update('suplementos', {'data': jsonEncode(data)},
              where: 'id = ?', whereArgs: [sid]);
          await LocalDb.instance.queueOp(
            opUuid: opUuid,
            tipo: 'inscripcion_venta_suplemento',
            payload: payloadInscripcionVentaSuplemento(
              nombre: nombre,
              telefono: telefono,
              sexo: _sexo,
              carnet: carnet,
              suplementoId: widget.suplemento['id'],
              cantidad: widget.cantidad,
              precio: widget.precio,
              moneda: widget.moneda,
              precioOficial: widget.precioOficial,
              notaPrecio: widget.notaPrecio,
              usdTasa: widget.usdTasa,
              fecha: hoy,
              metodoPago: _metodo,
            ),
            txn: txn,
          );
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('No se registró: $e')));
        }
        return;
      }
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
            onChanged: (_) => setState(() {}),
          ),
          // v1.5.0 (Bloque G): aviso de fecha imposible (no bloquea).
          if (carnetFechaInvalida(_carnet.text))
            const AvisoFechaCarnet(),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(
              titulo: 'Método de pago'),
          const Text('Inscripción y venta se pagan con el mismo método.',
              style: AppTexto.secundario),
          const SizedBox(height: 4),
          Wrap(
            spacing: AppEspacio.sm,
            children: [
              ChoiceChip(
                label: const Text('Efectivo'),
                selected: _metodo == 'efectivo',
                selectedColor: AppColores.naranja
                    .withValues(alpha: 0.2),
                onSelected: (_) =>
                    setState(() => _metodo = 'efectivo'),
              ),
              ChoiceChip(
                label: const Text('Transferencia'),
                selected: _metodo == 'transferencia',
                selectedColor: AppColores.naranja
                    .withValues(alpha: 0.2),
                onSelected: (_) =>
                    setState(() => _metodo = 'transferencia'),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(
              titulo: 'Mensualidad inicial'),
          Tarjeta(
            child: Row(
              children: [
                const Icon(Icons.payments_outlined,
                    color: AppColores.naranja),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                    'Se cobrará la mensualidad vigente '
                    '${_metodo == 'efectivo' ? 'en efectivo' : 'por transferencia'} al inscribir.',
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
    final t = widget.usdTasa;
    final tasaTxt = (t != null && t > 0) ? ' (tasa ${t.toStringAsFixed(2)})' : '';
    return '$base$tasaTxt\n'
        'Total: ${textoTotalVenta(_total, widget.moneda, widget.usdTasa)}';
  }
}
