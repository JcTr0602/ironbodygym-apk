// Registrar venta de suplemento (entrenadores y dueño).
//
// - Precio precargado con el oficial; si el entrenador lo cambia,
//   alerta ámbar visible ("precio diferente al oficial").
// - Moneda CUP/USD. Comprador: cliente del gym o externo (3 opciones).
// - Si la promo "mes gratis" está activa y el comprador es cliente,
//   la confirmación avisa que se le asignará 1 mes de mensualidad.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../negocio.dart';
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
  // v1.2.1: nota opcional de la venta (ej: "apartado").
  final _nota = TextEditingController();
  // v1.2.4: USD por defecto (precio oficial en USD).
  String _moneda = 'USD';
  String _tipoComprador = 'cliente'; // cliente | externo_nombre | externo_generico | inscribir_nuevo
  int? _clienteId;
  String _clienteNombre = '';
  bool _promoActiva = false;
  bool _guardando = false;

  double get _precioOficial =>
      (widget.suplemento['precio_oficial'] as num?)?.toDouble() ?? 0;

  /// v1.2.4: precio oficial en la moneda elegida (CUP = oficial × tasa).
  double? get _oficialEnMoneda =>
      precioOficialEn(_moneda, _precioOficial, _tasaUsd);

  bool get _precioDifiere {
    final p =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    final ref = _oficialEnMoneda;
    if (p == null || ref == null) return false;
    return (p - ref).abs() > 0.009;
  }

  /// v1.2.4: al cambiar de moneda, si el precio no se tocó a mano,
  /// se rellena con el oficial convertido (evita cobrar 50 CUP por 50 USD).
  void _cambiarMoneda(String m) {
    final anterior = precioOficialEn(_moneda, _precioOficial, _tasaUsd);
    final actual =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    final sinTocar = actual == null ||
        (anterior != null && (actual - anterior).abs() < 0.01);
    setState(() {
      _moneda = m;
      final nuevo = precioOficialEn(m, _precioOficial, _tasaUsd);
      if (sinTocar || nuevo == null) {
        // v1.3.1: sin conversión posible, no arrastrar el importe
        // de la otra moneda (evita 50 USD -> 50 CUP).
        _precio.text = nuevo == null
            ? ''
            : (m == 'USD'
                ? nuevo.toStringAsFixed(2)
                : nuevo.toStringAsFixed(0));
      }
    });
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
          // v1.2.4: tasa del día (Admin) como valor inicial editable.
          final t = (aj['tasa_usd'] as num?)?.toDouble();
          if (t != null && t > 0 && _tasa.text.trim().isEmpty) {
            _tasa.text = t.toStringAsFixed(0);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _precio.dispose();
    _tasa.dispose();
    _compradorNombre.dispose();
    _nota.dispose();
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
    // v1.3.1: guarda de reentrada (evita venta duplicada).
    if (_guardando) return;
    setState(() => _guardando = true);
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
    final tasa = _tasaUsd;
    // v1.3.1: tasa obligatoria en CUP. En USD es opcional, pero si el
    // usuario escribió algo debe ser > 0 (el servidor exige usd_tasa > 0).
    if ((_moneda == 'CUP' && (tasa == null || tasa <= 0)) ||
        (tasa != null && tasa <= 0)) {
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
    final conPromo = _promoActiva &&
        (_tipoComprador == 'cliente' ||
            _tipoComprador == 'inscribir_nuevo');
    final lineaMoneda = 'Precio: ${precio.toStringAsFixed(2)} $_moneda'
        '${tasa != null ? ' (tasa ${tasa.toStringAsFixed(2)} CUP/USD)' : ''}'
        '${_precioDifiere ? ' — difiere del oficial' : ''}\n'
        'Total: ${textoTotalVenta(total, _moneda, tasa)}';

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
    if (!ok) {
      setState(() => _guardando = false);
      return;
    }

    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'venta_suplemento',
        payload: {
          'suplemento_id': widget.suplemento['id'],
          'cantidad': _cantidad,
          'precio': precio,
          'moneda': _moneda,
          // v1.3.1: en USD la tasa es irrelevante; se normaliza a 1.0 si
          // no hay o es inválida. En CUP es obligatoria (validada arriba).
          'usd_tasa': (tasa != null && tasa > 0) ? tasa : 1.0,
          // ChatGPT CRÍTICO 2: el servidor solo acepta 'cliente'|'externo'.
          // 'externo_nombre' y 'externo_generico' se mapean a 'externo'.
          'comprador_tipo':
              _tipoComprador == 'cliente' ? 'cliente' : 'externo',
          if (_tipoComprador == 'cliente')
            'cliente_id': _clienteId,
          'comprador_nombre': nombreComprador,
          'fecha': DateTime.now().toIso8601String().substring(0, 10),
          // v1.2.1: nota opcional.
          if (_nota.text.trim().isNotEmpty)
            'nota': _nota.text.trim(),
        },
      );
    } catch (e) {
      // v1.3.1: si falla el encolado, avisar y NO cerrar (evita duplicado).
      if (mounted) {
        setState(() => _guardando = false);
        await DialogoApp.confirmar(context,
            titulo: 'No se registró la venta',
            mensaje: 'Inténtalo de nuevo. ($e)',
            aceptar: 'Entendido',
            cancelar: '');
      }
      return;
    }
    // v1.3.1: stock optimista aislado (no crítico, el pull corrige).
    try {
      final db = await LocalDb.instance.db;
      final sid = widget.suplemento['id'] as int?;
      if (sid != null) {
        final rows = await db.query('suplementos',
            columns: ['data'], where: 'id = ?', whereArgs: [sid]);
        if (rows.isNotEmpty) {
          final data =
              jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
          final stockActual = (data['stock'] as num?)?.toInt() ?? 0;
          data['stock'] = (stockActual - _cantidad).clamp(0, 999999);
          await db.update('suplementos', {'data': jsonEncode(data)},
              where: 'id = ?', whereArgs: [sid]);
        }
      }
    } catch (_) {
      // El pull sincronizará el valor canónico.
    }
    unawaited(SyncEngine.instance.push().catchError((_) {}));
    if (mounted) Navigator.pop(context, true);
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
    {
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
          ...[
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _tasa,
              etiqueta: _moneda == 'CUP'
                  ? 'Tasa (CUP por 1 USD) — obligatoria'
                  : 'Tasa (CUP por 1 USD) — opcional',
              teclado: const TextInputType.numberWithOptions(
                  decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            if (_tasaUsd != null && _tasaUsd! > 0)
              Padding(
                padding: const EdgeInsets.only(
                    top: AppEspacio.sm),
                child: Text(
                  'Total: ${textoTotalVenta(_total, _moneda, _tasaUsd)}',
                  style: AppTexto.cuerpo,
                ),
              ),
          ],
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Comprador'),
          _selectorComprador(),
          // v1.2.1: nota opcional de la venta.
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Nota (opcional)'),
          CampoTexto(
            controller: _nota,
            hint: 'Ej: apartado, fiado…',
            icono: Icons.sticky_note_2_outlined,
          ),
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
              onSelected: (_) => _cambiarMoneda(m),
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
            title: GestureDetector(
              onTap: _elegirCliente,
              child: Text(
                  _clienteId == null
                      ? 'Cliente del gym — toca para seleccionar'
                      : 'Cliente: $_clienteNombre — toca para cambiar',
                  style: AppTexto.cuerpo),
            ),
            secondary: _clienteId == null
                ? IconButton(
                    icon: const Icon(Icons.person_search,
                        color: AppColores.naranja),
                    onPressed: _elegirCliente,
                    tooltip: 'Seleccionar cliente',
                  )
                : null,
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
