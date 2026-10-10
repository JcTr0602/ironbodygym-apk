// Registrar venta de suplemento (entrenadores y dueño).
//
// - Precio precargado con el oficial; si el entrenador lo cambia,
//   alerta ámbar visible ("precio diferente al oficial").
// - Moneda CUP/USD. Comprador: cliente del gym o externo (3 opciones).
// - Si la promo "mes gratis" está activa y el comprador es cliente,
//   la confirmación avisa que se le asignará 1 mes de mensualidad.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'venta_suplemento_inscripcion.dart';
import 'widgets.dart';

class VentaSuplementoScreen extends StatefulWidget {
  final Map<String, dynamic> suplemento;
  const VentaSuplementoScreen({super.key, required this.suplemento});

  @override
  State<VentaSuplementoScreen> createState() =>
      _VentaSuplementoScreenState();
}

class _VentaSuplementoScreenState
    extends State<VentaSuplementoScreen> {
  int _cantidad = 1;
  final _precio = TextEditingController();
  final _tasa = TextEditingController();
  final _compradorNombre = TextEditingController();
  String _moneda = 'CUP';
  String _tipoComprador = 'cliente'; // cliente | externo_nombre | externo_generico | inscribir_nuevo
  int? _clienteId;
  String _clienteNombre = '';
  bool _promoActiva = false;
  bool _guardando = false;

  double get _precioOficial =>
      (widget.suplemento['precio_oficial'] as num?)?.toDouble() ?? 0;

  bool get _precioDifiere {
    final p =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    return p != null && (p - _precioOficial).abs() > 0.009;
  }

  double? get _tasaUsd =>
      double.tryParse(_tasa.text.trim().replaceAll(',', '.'));

  double get _total {
    final p =
        double.tryParse(_precio.text.trim().replaceAll(',', '.')) ?? 0;
    return p * _cantidad;
  }

  @override
  void initState() {
    super.initState();
    _precio.text = _precioOficial.toStringAsFixed(2);
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
    _precio.dispose();
    _tasa.dispose();
    _compradorNombre.dispose();
    super.dispose();
  }

  Future<void> _elegirCliente() async {
    final clientes =
        await LocalDb.instance.allMirror('clientes');
    final activos = clientes
        .where((c) => (c['estado'] as String?) == 'activo')
        .toList()
      ..sort((a, b) => '${a['nombre']}'
          .compareTo('${b['nombre']}'));
    if (!mounted) return;
    final sel = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cliente del gym',
        iconoTitulo: Icons.person_search,
        contenido: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: activos.length,
            itemBuilder: (_, i) {
              final c = activos[i];
              return ListTile(
                title: Text('${c['nombre'] ?? ''}'),
                onTap: () => Navigator.pop(ctx, c),
              );
            },
          ),
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    if (sel != null && mounted) {
      setState(() {
        _clienteId = (sel['id'] as num?)?.toInt();
        _clienteNombre = '${sel['nombre'] ?? ''}';
        _tipoComprador = 'cliente';
      });
    }
  }

  Future<void> _confirmar() async {
    final precio =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    if (precio == null || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el precio',
          mensaje: 'Indica un precio de venta mayor que 0.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    final esUsd = _moneda == 'USD';
    final tasa = _tasaUsd;
    if (esUsd && (tasa == null || tasa <= 0)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa la valoración',
          mensaje:
              'Indica a cuántos CUP equivale 1 USD para esta venta.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    if (_tipoComprador == 'cliente' && _clienteId == null) {
      await DialogoApp.confirmar(context,
          titulo: 'Falta el comprador',
          mensaje: 'Elige el cliente del gym que compra.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    if (_tipoComprador == 'externo_nombre' &&
        _compradorNombre.text.trim().isEmpty) {
      await DialogoApp.confirmar(context,
          titulo: 'Falta el nombre',
          mensaje: 'Escribe el nombre del comprador externo.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }

    final nombreComprador = _tipoComprador == 'cliente'
        ? _clienteNombre
        : _tipoComprador == 'externo_nombre'
            ? _compradorNombre.text.trim()
            : 'Cliente externo';
    final total = _total;
    final conPromo =
        _promoActiva && _tipoComprador == 'cliente';
    final lineaMoneda = esUsd
        ? 'Precio: ${precio.toStringAsFixed(2)} USD'
            ' (tasa ${tasa!.toStringAsFixed(2)} CUP/USD)'
            '${_precioDifiere ? ' — difiere del oficial' : ''}\n'
            'Total: ${total.toStringAsFixed(2)} USD'
            ' (≈ ${(total * tasa).toStringAsFixed(0)} CUP)'
        : 'Precio: ${precio.toStringAsFixed(2)} $_moneda'
            '${_precioDifiere ? ' (difiere del oficial)' : ''}\n'
            'Total: ${total.toStringAsFixed(2)} $_moneda';

    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar venta',
      icono: Icons.point_of_sale,
      mensaje: '${widget.suplemento['nombre']}\n'
          'Cantidad: $_cantidad\n'
          '$lineaMoneda\n'
          'Comprador: $nombreComprador'
          '${conPromo ? '\n\nSe le asignará 1 mes de mensualidad gratis (promo activa).' : ''}',
      aceptar: 'Confirmar venta',
    );
    if (!ok) return;

    setState(() => _guardando = true);
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'venta_suplemento',
        payload: {
          'suplemento_id': widget.suplemento['id'],
          'cantidad': _cantidad,
          'precio': precio,
          'moneda': _moneda,
          if (esUsd) 'usd_tasa': tasa,
          'comprador_tipo': _tipoComprador,
          if (_tipoComprador == 'cliente')
            'cliente_id': _clienteId,
          'comprador_nombre': nombreComprador,
          'fecha': DateTime.now().toIso8601String().substring(0, 10),
        },
      );
      unawaited(SyncEngine.instance.push());
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Abre la pantalla combinada inscripción + venta con los datos
  /// ya elegidos. Si vuelve con éxito, cierra esta pantalla también.
  Future<void> _irAInscripcionVenta() async {
    final precio =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    if (precio == null || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el precio',
          mensaje: 'Indica un precio de venta mayor que 0.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    if (_moneda == 'USD') {
      final tasa = _tasaUsd;
      if (tasa == null || tasa <= 0) {
        await DialogoApp.confirmar(context,
            titulo: 'Revisa la valoración',
            mensaje:
                'Indica a cuántos CUP equivale 1 USD para esta venta.',
            aceptar: 'Entendido',
            cancelar: '');
        return;
      }
    }
    if (!mounted) return;
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VentaSuplementoInscripcionScreen(
          suplemento: widget.suplemento,
          cantidad: _cantidad,
          precio: precio,
          moneda: _moneda,
          usdTasa: _tasaUsd,
        ),
      ),
    );
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final stock =
        (widget.suplemento['stock'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar venta')),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
          Tarjeta(
            child: Row(
              children: [
                const Icon(Icons.medication,
                    color: AppColores.naranja, size: 32),
                const SizedBox(width: AppEspacio.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text('${widget.suplemento['nombre']}',
                          style: AppTexto.subtitulo),
                      Text(
                          'Oficial: ${_precioOficial.toStringAsFixed(2)} USD · $stock disp.',
                          style: AppTexto.secundario),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(titulo: 'Cantidad'),
          _stepperCantidad(stock),
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Precio de venta'),
          CampoTexto(
            controller: _precio,
            etiqueta: 'Precio por unidad',
            teclado: const TextInputType.numberWithOptions(
                decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          if (_precioDifiere) _alertaPrecio(),
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Moneda'),
          _chipsMoneda(),
          if (_moneda == 'USD') ...[
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _tasa,
              etiqueta: 'Valoración USD (CUP por 1 USD)',
              teclado: const TextInputType.numberWithOptions(
                  decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            if (_tasaUsd != null && _tasaUsd! > 0)
              Padding(
                padding: const EdgeInsets.only(
                    top: AppEspacio.sm),
                child: Text(
                  'Total: ${_total.toStringAsFixed(2)} USD'
                  ' (≈ ${(_total * _tasaUsd!).toStringAsFixed(0)} CUP)',
                  style: AppTexto.cuerpo,
                ),
              ),
          ],
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Comprador'),
          _selectorComprador(),
          const SizedBox(height: AppEspacio.lg),
          BotonPrimario(
            texto: _guardando ? 'Registrando…' : 'Confirmar venta',
            onPressed: _guardando ? null : _confirmar,
          ),
        ],
      ),
    );
  }

  Widget _stepperCantidad(int stock) {
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _cantidad > 1
                ? () => setState(() => _cantidad--)
                : null,
          ),
          Text('$_cantidad',
              style: AppTexto.displayPequeno),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: _cantidad < stock
                ? () => setState(() => _cantidad++)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _alertaPrecio() {
    return Padding(
      padding:
          const EdgeInsets.only(top: AppEspacio.sm),
      child: Container(
        padding: const EdgeInsets.all(AppEspacio.md),
        decoration: BoxDecoration(
          color: AppColores.alerta.withValues(alpha: 0.12),
          borderRadius:
              BorderRadius.circular(AppRadio.md),
          border: Border.all(
              color: AppColores.alerta.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber,
                color: AppColores.alerta),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Text(
                'Precio diferente al oficial (${_precioOficial.toStringAsFixed(2)} USD). Quedará marcado en el historial.',
                style: AppTexto.secundario,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chipsMoneda() {
    return Row(
      children: [
        for (final m in ['CUP', 'USD'])
          Padding(
            padding:
                const EdgeInsets.only(right: AppEspacio.sm),
            child: ChoiceChip(
              label: Text(m),
              selected: _moneda == m,
              selectedColor: AppColores.naranja.withValues(
                  alpha: 0.2),
              onSelected: (_) =>
                  setState(() => _moneda = m),
            ),
          ),
      ],
    );
  }

  Widget _selectorComprador() {
    return RadioGroup<String>(
      groupValue: _tipoComprador,
      onChanged: (v) {
        if (v == 'cliente') {
          _elegirCliente();
        } else if (v == 'inscribir_nuevo') {
          _irAInscripcionVenta();
        } else if (v != null) {
          setState(() => _tipoComprador = v);
        }
      },
      child: Column(
        children: [
          RadioListTile<String>(
            value: 'cliente',
            activeColor: AppColores.naranja,
            title: Text(
                _clienteId == null
                    ? 'Cliente del gym'
                    : 'Cliente: $_clienteNombre',
                style: AppTexto.cuerpo),
          ),
          const RadioListTile<String>(
            value: 'externo_nombre',
            activeColor: AppColores.naranja,
            title: Text('Externo (con nombre)',
                style: AppTexto.cuerpo),
          ),
          if (_tipoComprador == 'externo_nombre')
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg,
                  0,
                  AppEspacio.lg,
                  AppEspacio.sm),
              child: CampoTexto(
                controller: _compradorNombre,
                hint: 'Nombre del comprador',
                icono: Icons.person_outline,
              ),
            ),
          const RadioListTile<String>(
            value: 'externo_generico',
            activeColor: AppColores.naranja,
            title: Text('Cliente externo',
                style: AppTexto.cuerpo),
            subtitle: Text(
                'Venta rápida sin identificar',
                style: AppTexto.secundario),
          ),
          const RadioListTile<String>(
            value: 'inscribir_nuevo',
            activeColor: AppColores.naranja,
            title: Text('Inscribir como cliente nuevo',
                style: AppTexto.cuerpo),
            subtitle: Text(
                'Inscribe al comprador y registra la venta en una sola operación',
                style: AppTexto.secundario),
            secondary: Icon(Icons.person_add,
                color: AppColores.naranja),
          ),
        ],
      ),
    );
  }
}
