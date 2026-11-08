// Ficha del suplemento (v1.2.1).
//
// Al tocar un producto del catálogo se abre su detalle: foto grande,
// descripción, precio en su moneda (CUP o USD según el suplemento) y,
// si es USD, su equivalente en CUP según la tasa del
// día, categoría y stock. Acciones: Vender, Venta rápida y Compartir.
//
// También expone los helpers reutilizables [ventaRapidaSuplemento] y
// [compartirSuplemento] para usarlos desde la lista.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_log.dart';
import '../auth.dart';
import '../cliente_protegido.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../permisos.dart';
import '../servicios.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'aviso_duplicado.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'suplementos.dart';
import 'venta_suplemento.dart';
import 'widgets.dart';
import '../errores_sync.dart';

/// Venta rápida rediseñada (v1.3.4, pedido Jc 2026-10-16).
///
/// Diálogo "Vender <producto>" con cantidad y precio (oficial por defecto)
/// + buscador de cliente del gym:
/// - CON cliente seleccionado y promo `promo_suplementos` activa: la venta
///   queda asociada (`comprador_tipo: 'cliente'`, `cliente_id`) y SÍ aplica
///   la promo de 1 mes gratis (el servidor la procesa en
///   `_op_venta_suplemento`).
/// - SIN cliente: advertencia imposible de pasar por alto + aceptación
///   explícita (checkbox); la venta sale como `externo`, sin promo.
///
/// Devuelve true si se registró la venta. Usa el camino único
/// `registrarVentaSuplemento` (transacción atómica: stock JSON + op).
Future<bool> ventaRapidaSuplemento(
    BuildContext context, Map<String, dynamic> s,
    [double? tasaUsd, int? clienteId, String? clienteNombre]) async {
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  if (stock <= 0) {
    mostrarSnack(context, 'Sin stock disponible para venta rápida', significado: SignificadoChip.alerta);
    return false;
  }
  if (!context.mounted) return false;
  final res = await showDialog<bool>(
    context: context,
    // 1.23 AT-15: la tasa que los llamadores ya pasaban se
    // perdía aquí y la venta rápida en USD viajaba sin ella
    // (el servidor la exige para valorar la venta).
    builder: (ctx) => _DialogoVentaRapida(
        sup: s,
        stock: stock,
        tasaUsd: tasaUsd,
        clienteInicialId: clienteId,
        clienteInicialNombre: clienteNombre),
  );
  return res == true;
}

/// Diálogo de venta rápida: cantidad + precio + selector de cliente.
///
/// Diseñado para que el vendedor no pierda la promo por accidente: el
/// selector de cliente es visible y, sin cliente, la advertencia de
/// "sin promo" exige aceptación explícita antes de confirmar.
class _DialogoVentaRapida extends StatefulWidget {
  final Map<String, dynamic> sup;
  final int stock;
  // 1.23 AT-15: tasa del día para valorar la venta en USD.
  final double? tasaUsd;
  // 1.25 T12: cliente preseleccionado (desde Buscar: el
  // deslizable «Venta» actúa sobre ESE cliente).
  final int? clienteInicialId;
  final String? clienteInicialNombre;

  const _DialogoVentaRapida(
      {required this.sup,
      required this.stock,
      this.tasaUsd,
      this.clienteInicialId,
      this.clienteInicialNombre});

  @override
  State<_DialogoVentaRapida> createState() =>
      _DialogoVentaRapidaState();
}

class _DialogoVentaRapidaState extends State<_DialogoVentaRapida> {
  int _cantidad = 1;
  final _precio = TextEditingController();
  final _notaPrecio = TextEditingController();
  // 1.25 T91: la venta rápida converge con la completa:
  // nota libre y fiado (la función de negocio ya los
  // soportaba; solo la completa los ofrecía).
  final _nota = TextEditingController();
  bool _esFiado = false;
  final _busqueda = TextEditingController();
  final _permisos = Permisos();

  int? _clienteId;
  String _clienteNombre = '';
  bool _promoActiva = false;
  bool _aceptaSinPromo = false;
  bool _guardando = false;
  // Panel Luna P2 (lote 3): la confirmación de precio tiene un await
  // antes de activar _guardando; sin esta bandera, dos toques
  // rápidos podían abrir dos confirmaciones y vender dos veces.
  bool _confirmandoPrecio = false;
  List<Map<String, dynamic>> _clientes = [];

  // Lote 1 Argón: lectura estricta del oficial, igual que la pantalla
  // de venta. Antes caía al campo legado `precio` y la venta rápida
  // precargaba un valor distinto al que muestra el detalle.
  double get _precioOficial =>
      (widget.sup['precio_oficial'] as num?)?.toDouble() ?? 0;

  /// v1.4.6: la venta rápida se registra en la moneda del
  /// suplemento (antes 'USD' fijo: un suplemento en CUP habría
  /// quedado vendido como si fuera en USD).
  String get _monedaSup => LocalDb.monedaDe(widget.sup);

  // Autoauditoría 1.22 #2 (clase N-2): precio no finito = sin
  // precio (NaN hacía _puedeVender true y la venta rápida
  // operaba con NaN hasta reventar en los centavos).
  double? get _precioVenta {
    final v = double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    return (v != null && v.isFinite) ? v : null;
  }

  /// v1.3.4 (candado a): comparación en centavos enteros.
  bool get _precioDifiere {
    final p = _precioVenta;
    if (p == null) return false;
    return precioDifiereEnCentavos(p, _precioOficial);
  }

  bool get _conCliente => _clienteId != null;

  List<Map<String, dynamic>> get _coincidencias {
    final q = _busqueda.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _clientes
        .where(
            (c) => '${c['nombre'] ?? ''}'.toLowerCase().contains(q))
        .take(5)
        .toList();
  }

  bool get _puedeConfirmar {
    if (_guardando) return false;
    final p = _precioVenta;
    if (p == null || p <= 0) return false;
    if (_cantidad < 1 || _cantidad > widget.stock) return false;
    // Sin cliente: la advertencia debe aceptarse explícitamente.
    if (!_conCliente && !_aceptaSinPromo) return false;
    // Candado b: precio distinto + no dueño → nota_precio obligatoria.
    if (_precioDifiere &&
        !_permisos.esDueno &&
        _notaPrecio.text.trim().length < 5) {
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    // B3-Invariante: el precio propone SIEMPRE el oficial, jamás
    // ultimo_precio.
    _precio.text = _precioOficial.toStringAsFixed(2);
    // 1.25 T12: si la venta viene de la fila de un cliente
    // (Buscar), ese cliente nace elegido; cambiarlo sigue
    // siendo posible en el selector de siempre.
    _clienteId = widget.clienteInicialId;
    _clienteNombre = widget.clienteInicialNombre ?? '';
    _cargar();
  }

  Future<void> _cargar() async {
    final aj = await LocalDb.instance.getAjustes();
    final clientes = await LocalDb.instance.allMirror('clientes');
    if (!mounted) return;
    setState(() {
      _promoActiva =
          (aj['promo_suplementos'] as num?)?.toInt() != 0;
      _clientes = clientes
          .where((c) => (c['estado'] as String?) == 'activo')
          .toList()
        ..sort(compararPorNombre);
    });
  }

  @override
  void dispose() {
    _precio.dispose();
    _notaPrecio.dispose();
    _nota.dispose();
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _confirmar() async {
    if (!_puedeConfirmar || _guardando || _confirmandoPrecio) return;
    // 1.25 T91: la confirmación ES la vista previa del
    // comprobante, como en la venta completa (v1.8.1):
    // el mismo texto que recibirá el cliente, con el
    // aviso de precio distinto dentro si lo hay. Antes
    // la rápida solo confirmaba aparte cuando el precio
    // difería, y sin comprobante.
    _confirmandoPrecio = true;
    bool ok;
    try {
      ok = await _confirmarConVistaPrevia();
    } finally {
      _confirmandoPrecio = false;
    }
    if (!ok || !mounted) return;
    // T16 (1.20, FIN-16 de Argón): la venta rápida también pasa
    // por el detector de duplicados, con la misma huella que la
    // venta completa (suplemento + cantidad + precio unitario).
    final sidPre = (widget.sup['id'] as num?)?.toInt();
    if (sidPre != null) {
      final centavosUnit = (_precioVenta! * 100).round();
      final sigue = await confirmarSiPareceDuplicado(
        context,
        tipo: 'venta_suplemento',
        coincide: (p) =>
            (p['suplemento_id'] as num?)?.toInt() == sidPre &&
            (p['cantidad'] as num?)?.toInt() == _cantidad &&
            (p['precio_venta_centavos'] as num?)?.toInt() ==
                centavosUnit,
        descripcion:
            'una venta de ${widget.sup['nombre']} x$_cantidad',
      );
      if (!sigue || !mounted) return;
    }
    setState(() => _guardando = true);
    try {
      final sid = (widget.sup['id'] as num?)?.toInt();
      if (sid == null) throw Exception('Suplemento sin identificador');
      final notaPrecio = _notaPrecio.text.trim();
      await registrarVentaSuplemento(
        suplementoId: sid,
        cantidad: _cantidad,
        precioOficial: _precioOficial,
        precioVenta: _precioVenta!,
        moneda: _monedaSup,
        // 1.23 AT-15: sin esto, la venta rápida en USD caía al
        // centinela 1.0 (registrarVentaSuplemento ahora la
        // exige y lanza si falta: el catch de abajo lo muestra).
        usdTasa: widget.tasaUsd,
        compradorTipo: _conCliente ? 'cliente' : 'externo',
        clienteId: _clienteId,
        compradorNombre:
            _conCliente ? _clienteNombre : 'Cliente externo',
        // T91: la nota del vendedor viaja con la marca
        // del camino (la trazabilidad del extracto no
        // cambia); sin nota, la marca a secas.
        nota: _nota.text.trim().isEmpty
            ? 'venta rápida'
            : 'venta rápida · ${_nota.text.trim()}',
        notaPrecio:
            _precioDifiere && notaPrecio.isNotEmpty ? notaPrecio : null,
        // T91: fiado como en la completa (solo con
        // cliente; la función de negocio lo exige).
        esFiado: _esFiado && _conCliente,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        AppLog.error('detalle_suplemento', 'registrar_venta_fallo', d: '$e');
        mostrarSnack(context, 'No se registró la venta: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// 1.25 T91: ventana de revisión con el comprobante
  /// tal y como lo recibirá el cliente (la misma
  /// función pura y la misma burbuja que la venta
  /// completa, v1.8.1). Devuelve true solo si el
  /// vendedor confirma.
  Future<bool> _confirmarConVistaPrevia() async {
    final precio = _precioVenta!;
    final total = precio * _cantidad;
    final esFiado = _esFiado && _conCliente;
    final conPromo = conPromoVentaSuplemento(
      promoActiva: _promoActiva,
      tipoComprador: _conCliente ? 'cliente' : 'externo',
      esFiado: esFiado,
    );
    String? nuevoVencimiento;
    if (conPromo) {
      final cli = _clientes.cast<Map<String, dynamic>?>()
          .firstWhere(
            (c) => (c?['id'] as num?)?.toInt() == _clienteId,
            orElse: () => null,
          );
      final hasta = '${cli?['pagado_hasta'] ?? ''}'.trim();
      nuevoVencimiento =
          previewHasta(hasta.isEmpty ? null : hasta, 1);
    }
    final texto = textoComprobanteCompra(
      nombreProducto: '${widget.sup['nombre'] ?? ''}',
      cantidad: _cantidad,
      precio: precio,
      moneda: _monedaSup,
      total: total,
      nombreComprador:
          _conCliente ? _clienteNombre : 'Cliente externo',
      fechaIso: hoyHabanaIso(),
      conPromo: conPromo,
      nuevoVencimientoIso: nuevoVencimiento,
      esFiado: esFiado,
      vendedor: AuthService().displayName,
    );
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Confirma la venta',
        iconoTitulo: Icons.point_of_sale_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Revisa el comprobante tal y como lo recibirá el cliente:',
              style: AppTexto.cuerpo
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppEspacio.md),
              decoration: BoxDecoration(
                color: AppColores.comprobanteFondo,
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
              ),
              child: Text(texto.replaceAll('*', '')),
            ),
            if (_precioDifiere) ...[
              const SizedBox(height: 12),
              Text(
                '⚠️ Precio distinto al oficial '
                '(${_precioOficial.toStringAsFixed(2)} $_monedaSup).',
                style: AppTexto.cuerpo
                    .copyWith(color: AppColores.error),
              ),
            ],
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          BotonPrimario(
            texto: 'Confirmar venta',
            onPressed: () => Navigator.pop(ctx, true),
            expandido: false,
          ),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Vender ${widget.sup['nombre'] ?? 'suplemento'}',
      iconoTitulo: Icons.flash_on_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Precio oficial: ${_precioOficial.toStringAsFixed(2)} $_monedaSup',
              style: AppTexto.secundario,
            ),
            const SizedBox(height: AppEspacio.md),
            _stepperCantidad(),
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _precio,
              etiqueta: 'Precio por unidad ($_monedaSup)',
              teclado: const TextInputType.numberWithOptions(
                  decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            if (_precioDifiere) _alertaPrecio(),
            if (_precioDifiere) ...[
              const SizedBox(height: AppEspacio.sm),
              CampoTexto(
                controller: _notaPrecio,
                etiqueta: _permisos.esDueno
                    ? 'Motivo del precio (opcional para el dueño)'
                    : 'Motivo del precio (obligatorio, mín. 5 caracteres)',
                hint: 'Ej: Autorizado por Jc',
                icono: Icons.edit_note_rounded,
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: AppEspacio.md),
            const EncabezadoSeccion(
                titulo: 'Cliente del gym (opcional)'),
            if (!_conCliente) ...[
              CampoTexto(
                controller: _busqueda,
                hint: 'Buscar cliente por nombre…',
                icono: Icons.person_search_rounded,
                onChanged: (_) => setState(() {}),
              ),
              ..._coincidencias.map((c) {
                    // Argón #9 (ALTO): venta rápida sin candado A3:
                    // un cliente protegido se podía asociar aquí y
                    // el servidor rechazaba la venta en el sync, con
                    // el stock ya descontado. Igual que
                    // venta_suplemento.dart: candado + aviso, sin
                    // seleccionar.
                    final protegido = esVistaProtegida(c);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${c['nombre'] ?? ''}'),
                      trailing: Icon(
                          protegido
                              ? Icons.lock_rounded
                              : Icons.add_circle_outline_rounded,
                          color: AppColores.naranja),
                      onTap: () {
                        if (protegido) {
                          mostrarSnack(context, mensajeClienteProtegido, significado: SignificadoChip.alerta);
                          return;
                        }
                        setState(() {
                          _clienteId =
                              (c['id'] as num?)?.toInt();
                          _clienteNombre = '${c['nombre'] ?? ''}';
                          _busqueda.clear();
                        });
                      },
                    );
                  }),
            ] else
              _clienteSeleccionado(),
            const SizedBox(height: AppEspacio.sm),
            // La promo solo aplica con cliente asociado.
            if (_conCliente && _promoActiva)
              _infoPromo()
            else if (!_conCliente)
              _advertenciaSinPromo(),
            // 1.25 T91: fiado y nota, como en la venta
            // completa (el fiado exige cliente y apaga
            // la promo, misma regla de negocio).
            if (_conCliente) ...[
              const SizedBox(height: AppEspacio.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fiado (se cobra después)'),
                subtitle: const Text(
                    'No cuenta como cobrado hasta saldarse y no aplica la promo.'),
                value: _esFiado,
                onChanged: _guardando
                    ? null
                    : (v) => setState(() => _esFiado = v),
              ),
            ],
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _nota,
              etiqueta: 'Nota (opcional)',
              hint: 'Ej: lo recoge el viernes',
              icono: Icons.sticky_note_2_rounded,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppEspacio.md),
            _barraTotal(),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed:
              _guardando ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _puedeConfirmar ? _confirmar : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
          ),
          child: Text(_guardando ? 'Registrando…' : 'Confirmar venta'),
        ),
      ],
    );
  }

  /// 1.25 T91: el total SIEMPRE visible y en vivo
  /// (cantidad × precio), como pide el diseño de la
  /// venta única: antes la rápida no mostraba ningún
  /// total hasta registrar.
  Widget _barraTotal() {
    final p = _precioVenta;
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Row(
        children: [
          const Text('Total', style: AppTexto.subtitulo),
          const Spacer(),
          if (p != null)
            Text(
              '$_cantidad × ${p.toStringAsFixed(2)} = ',
              style: AppTexto.secundario,
            ),
          Text(
            p == null
                ? '—'
                : '${(p * _cantidad).toStringAsFixed(2)} $_monedaSup',
            style: AppTexto.subtitulo
                .copyWith(color: AppColores.naranja),
          ),
        ],
      ),
    );
  }

  Widget _stepperCantidad() {
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline_rounded),
            onPressed: _cantidad > 1 && !_guardando
                ? () => setState(() => _cantidad--)
                : null,
          ),
          Text('$_cantidad', style: AppTexto.displayPequeno),
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: _cantidad < widget.stock && !_guardando
                ? () => setState(() => _cantidad++)
                : null,
          ),
          const SizedBox(width: AppEspacio.sm),
          Text('de ${widget.stock} disp.', style: AppTexto.secundario),
        ],
      ),
    );
  }

  Widget _alertaPrecio() {
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.sm),
      child: Container(
        padding: const EdgeInsets.all(AppEspacio.md),
        decoration: BoxDecoration(
          color: AppColores.alerta.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadio.md),
          border: Border.all(
              color: AppColores.alerta.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppColores.alerta),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Text(
                'Vas a vender a un precio distinto al oficial '
                '(${_precioOficial.toStringAsFixed(2)} $_monedaSup). '
                'Quedarán registrados ambos precios para auditoría.',
                style: AppTexto.secundario,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _clienteSeleccionado() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      decoration: BoxDecoration(
        color: AppColores.exito.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border: Border.all(
            color: AppColores.exito.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.person_rounded, color: AppColores.exito),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Text(_clienteNombre, style: AppTexto.cuerpo),
          ),
          IconButton(
            icon: const Icon(Icons.clear_rounded),
            tooltip: 'Quitar cliente',
            onPressed: _guardando
                ? null
                : () => setState(() {
                      _clienteId = null;
                      _clienteNombre = '';
                      _aceptaSinPromo = false;
                      _esFiado = false;
                    }),
          ),
        ],
      ),
    );
  }

  Widget _infoPromo() {
    return Container(
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.exito.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border: Border.all(
            color: AppColores.exito.withValues(alpha: 0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.card_giftcard_rounded, color: AppColores.exito),
          SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Text(
              'Se le asignará 1 mes de mensualidad gratis (promo activa).',
              style: AppTexto.secundario,
            ),
          ),
        ],
      ),
    );
  }

  /// Advertencia imposible de pasar por alto: sin cliente no hay promo,
  /// y hay que aceptarlo explícitamente para poder confirmar.
  Widget _advertenciaSinPromo() {
    return Container(
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border: Border.all(
            color: AppColores.alerta.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColores.alerta),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                  'Venta rápida: no se asocia ningún cliente del gym, '
                  'por lo que NO aplica la promo de 1 mes gratis por compra.',
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          CheckboxListTile(
            value: _aceptaSinPromo,
            onChanged: _guardando
                ? null
                : (v) =>
                    setState(() => _aceptaSinPromo = v == true),
            title: const Text(
              'Entiendo: esta venta no aplica la promo',
              style: AppTexto.secundario,
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
    );
  }
}

/// Comparte la info del suplemento (foto + precio) por WhatsApp
/// u otra app mediante la hoja de compartir del sistema.
Future<void> compartirSuplemento(BuildContext context,
    Map<String, dynamic> s, double? tasaUsd) async {
  final nombre = '${s['nombre'] ?? 'Suplemento'}';
  final precio =
      (s['precio_oficial'] as num?)?.toDouble() ?? 0;
  // v1.4.6: la etiqueta es la moneda del propio suplemento;
  // el equivalente en CUP solo existe si el precio está en USD.
  final moneda = LocalDb.monedaDe(s);
  // Argón menos auditados MEDIO: el equivalente CUP debe usar el
  // mismo redondeo a decenas que la venta (precioOficialEn), o el
  // catálogo y la caja muestran números distintos.
  final cup = moneda == 'USD' && tasaUsd != null && tasaUsd > 1.0
      ? ' (≈ ${fmtMonto(precioOficialEn('CUP', precio, tasaUsd)!)} CUP)'
      : '';
  // 1.25 T120 (F4-13): SIN stock, como el catálogo compartido
  // (criterio de Jc 2026-10-17: el cliente no necesita verlo).
  // Este compartir incluía «Disponibles: N» — dos criterios
  // opuestos para el mismo gesto.
  final texto = 'Iron Body Gym — Suplementos\n\n'
      '$nombre\n'
      'Precio: ${precio.toStringAsFixed(2)} $moneda$cup';
  try {
    // v1.3.3: preferir la foto local recién tomada (offline) si existe.
    File? archivo;
    final fotoLocal = s['foto_local'] as String?;
    if (fotoLocal != null && fotoLocal.isNotEmpty) {
      final f = File(fotoLocal);
      if (await f.exists()) archivo = f;
    }
    archivo ??=
        await FotoCache.instance.obtener(s['foto_storage'] as String?);
    if (archivo != null) {
      await Share.shareXFiles([XFile(archivo.path)],
          text: texto);
    } else {
      await Share.share(texto);
    }
  } catch (_) {
    if (context.mounted) {
      mostrarSnack(context, 'No se pudo compartir', significado: SignificadoChip.error);
    }
  }
}

/// 1.25 T120 (F4-06): visor de la foto a pantalla completa
/// (mismo patrón que el de la ficha del cliente, con zoom).
void _verFotoGrande(BuildContext context, File f) {
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppEspacio.lg),
      child: GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadio.lg),
          child: InteractiveViewer(
            child: Image.file(f, fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  );
}

class DetalleSuplementoScreen extends StatelessWidget {
  final Map<String, dynamic> suplemento;
  final String categoriaNombre;
  final double? tasaUsd;

  const DetalleSuplementoScreen({
    super.key,
    required this.suplemento,
    required this.categoriaNombre,
    this.tasaUsd,
  });

  Future<void> _vender(BuildContext context) async {
    final vendido = await Navigator.push<bool>(
      context,
      RutaIron(
        builder: (_) =>
            VentaSuplementoScreen(suplemento: suplemento),
      ),
    );
    if (vendido == true && context.mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _ventaRapida(BuildContext context) async {
    // v1.3.1: un solo diálogo (el de ventaRapidaSuplemento).
    final ok =
        await ventaRapidaSuplemento(context, suplemento, tasaUsd);
    if (!context.mounted) return;
    if (ok) {
      mostrarSnack(context, 'Venta registrada (se sincronizará)', significado: SignificadoChip.exito);
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nombre = '${suplemento['nombre'] ?? 'Sin nombre'}';
    final descripcion =
        '${suplemento['descripcion'] ?? ''}'.trim();
    final precio =
        (suplemento['precio_oficial'] as num?)?.toDouble() ?? 0;
    final stock =
        (suplemento['stock'] as num?)?.toInt() ?? 0;
    final inactivo = (suplemento['activo'] as int?) != 1;
    final foto = suplemento['foto_storage'] as String?;
    // v1.3.3: foto local recién tomada (offline) tiene prioridad.
    final fotoLocal = suplemento['foto_local'] as String?;
    // Fuente única (fotos.dart): el MISMO archivo que
    // resuelve la tarjeta — el Hero vuela sin parpadeo.
    final archivoLocal = archivoFotoLocalSuplemento(suplemento);
    // v1.4.6: el equivalente en CUP solo aplica si el precio
    // oficial está en USD (moneda del propio suplemento).
    final monedaSup = LocalDb.monedaDe(suplemento);
    final cup = monedaSup == 'USD' && tasaUsd != null && tasaUsd! > 1.0
        ? '≈ ${fmtMonto(precioOficialEn('CUP', precio, tasaUsd)!)} CUP'
        : null;
    // v1.4.3: presentación del envase (la misma que ve el
    // cliente en su catálogo). Rediseño 1.20: el cálculo vive
    // en textoPresentacion (negocio.dart), compartido con las
    // tarjetas de la lista.
    final presentacion = textoPresentacion(suplemento);

    return Scaffold(
      appBar: AppBar(
        title: Text(nombre,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded),
            tooltip: 'Compartir por WhatsApp',
            onPressed: () =>
                compartirSuplemento(context, suplemento, tasaUsd),
          ),
          // Rediseño 1.20: Editar y Eliminar viven en el
          // menú ⋮ (solo dueño); Compartir queda visible.
          if (AuthService().isOwner)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              tooltip: 'Más opciones',
              onSelected: (v) async {
                if (v == 'duplicar') {
                  // F12: crear desde plantilla (sin id ni foto).
                  final creado = await Navigator.push<bool>(
                    context,
                    RutaIron(
                      builder: (_) => EditarSuplementoScreen(
                          plantilla: suplemento),
                    ),
                  );
                  if (creado == true && context.mounted) {
                    Navigator.pop(context, true);
                  }
                } else if (v == 'editar') {
                  final editado = await Navigator.push<bool>(
                    context,
                    RutaIron(
                      builder: (_) => EditarSuplementoScreen(
                          suplemento: suplemento),
                    ),
                  );
                  if (editado == true && context.mounted) {
                    Navigator.pop(context, true);
                  }
                } else if (v == 'ajustar') {
                  // F5: ajuste de stock con motivo.
                  final ajustado = await _ajustarStock(
                      context, suplemento);
                  if (ajustado == true && context.mounted) {
                    Navigator.pop(context, true);
                  }
                } else if (v == 'eliminar') {
                  _eliminarSuplemento(context, suplemento);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'duplicar',
                  child: Row(
                    children: [
                      Icon(Icons.copy_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Duplicar suplemento'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'ajustar',
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Ajustar stock'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'editar',
                  child: Row(
                    children: [
                      Icon(Icons.edit_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Editar suplemento'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'eliminar',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline_rounded,
                          size: 20, color: AppColores.error),
                      const SizedBox(width: 12),
                      Text('Eliminar suplemento',
                          style: AppTexto.cuerpo
                              .copyWith(color: AppColores.error)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
          // Foto grande.
          // v1.3.3: foto local recién tomada (offline) tiene prioridad
          // sobre la remota (aún no subida o sin descargar).
          if (archivoLocal != null)
            Hero(
              tag: tagHeroSuplemento(suplemento['id']),
              flightShuttleBuilder: shuttleHeroFoto,
              child: ClipRRect(
              borderRadius:
                  BorderRadius.circular(AppRadio.lg),
              // 1.25 T120 (F4-06): la foto del escaparate crece
              // (200 → 264) y se amplía al toque.
              child: GestureDetector(
                onTap: () => _verFotoGrande(context, archivoLocal),
                child: Image(
                  image: providerFotoAcotada(
                      FileImage(archivoLocal),
                      ancho: 1080),
                  height: 264,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 264,
                    decoration: BoxDecoration(
                      color: AppColores.fondo(context),
                      borderRadius:
                          BorderRadius.circular(AppRadio.lg),
                    ),
                    child: Icon(
                        Icons.medication_rounded,
                        size: 72,
                        color: AppColores.textoSecundario(context)),
                  )),
                ),
              ),
            )
          else
            // Panel Bloque 2 Paso 2 (Media): el Hero envuelve
            // al FutureBuilder, NO a su resultado — el
            // HeroController empareja origen y destino al
            // INICIAR la transición; si el Hero solo existe
            // cuando la foto ya bajó, el vuelo nunca arranca
            // en la rama FotoCache (la habitual). Montado
            // siempre, durante la carga pinta el marcador.
            Hero(
              tag: tagHeroSuplemento(suplemento['id']),
              flightShuttleBuilder: shuttleHeroFoto,
              child: FutureBuilder(
                future: FotoCache.instance.obtener(foto),
                builder: (ctx, snap) {
                  final f = snap.data;
                  if (f == null) {
                    return Container(
                      height: 264,
                      decoration: BoxDecoration(
                        color: AppColores.fondo(context),
                        borderRadius:
                            BorderRadius.circular(AppRadio.lg),
                      ),
                      child: Icon(
                          Icons.medication_rounded,
                          size: 72,
                          color: AppColores.textoSecundario(context)),
                    );
                  }
                  return ClipRRect(
                    borderRadius:
                        BorderRadius.circular(AppRadio.lg),
                    child: GestureDetector(
                      onTap: () => _verFotoGrande(context, f),
                      child: Image(
                          image: providerFotoAcotada(FileImage(f),
                              ancho: 1080),
                          height: 264,
                          width: double.infinity,
                          fit: BoxFit.cover),
                    ),
                  );
                },
              ),
            ),
          // Rediseño 1.20: foto_local presente = foto nueva
          // aún no confirmada por el servidor (el pull la
          // limpia); se avisa sin bloquear nada.
          if (fotoLocal != null && fotoLocal.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.sm),
            const ChipEstado.semantico(
                texto: 'Foto pendiente de sincronizar',
                significado: SignificadoChip.alerta),
          ],
          const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              Expanded(
                child: Text(nombre,
                    style: AppTexto.titulo),
              ),
              if (inactivo)
                const ChipEstado.semantico(
                    texto: 'Inactivo',
                    significado: SignificadoChip.neutral),
            ],
          ),
          const SizedBox(height: AppEspacio.xs),
          ChipEstado(
              texto: categoriaNombre,
              color: AppColores.naranja),
          if (descripcion.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.md),
            Text(descripcion, style: AppTexto.cuerpo),
          ],
          if (presentacion.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.xs),
            Text('Presentación: $presentacion', style: AppTexto.cuerpo),
          ],
          const SizedBox(height: AppEspacio.md),
          // Precio (moneda del suplemento) + equivalente CUP
          // si es USD + stock.
          Tarjeta(
            child: Row(
              children: [
                Icon(Icons.payments_rounded,
                    color: AppColores.textoSecundario(context), size: 32),
                const SizedBox(width: AppEspacio.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${precio.toStringAsFixed(2)} $monedaSup',
                          style: AppTexto.displayPequeno),
                      if (cup != null)
                        Text(cup,
                            style: AppTexto.cuerpo.copyWith(
                                color: AppColores.naranja,
                                fontWeight:
                                    FontWeight.bold)),
                      ChipEstado.semantico(
                        texto: textoEstadoStock(suplemento),
                        significado:
                            switch (estadoStockSuplemento(suplemento)) {
                          EstadoStockSuplemento.agotado =>
                            SignificadoChip.error,
                          EstadoStockSuplemento.bajo =>
                            SignificadoChip.alerta,
                          EstadoStockSuplemento.disponible =>
                            SignificadoChip.exito,
                          EstadoStockSuplemento.inactivo =>
                            SignificadoChip.neutral,
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // v1.3.7 (Fase B §6.2): margen por bote, SOLO dueño.
          // Argón #9 (MEDIO): el costo es USD y el precio está en
          // la moneda del suplemento. En CUP se convierte con la
          // tasa; sin tasa válida no se muestra (un margen CUP-USD
          // sería un número falso etiquetado USD).
          if (AuthService().isOwner)
            Builder(builder: (ctx) {
              final costo =
                  (suplemento['costo'] as num?)?.toDouble() ?? 0;
              if (costo <= 0 || precio <= 0) {
                // 1.25 T120 (F4-06): antes el bloque desaparecía
                // en silencio y «sin margen calculable» se leía
                // como margen cero.
                return const Padding(
                  padding: EdgeInsets.only(top: AppEspacio.md),
                  child: Text(
                    'Sin costo registrado: el margen no se puede '
                    'calcular.',
                    style: AppTexto.secundario,
                  ),
                );
              }
              double? precioUsd;
              if (monedaSup == 'USD') {
                precioUsd = precio;
              } else if (tasaUsd != null && tasaUsd! > 1.0) {
                precioUsd = precio / tasaUsd!;
              }
              if (precioUsd == null) {
                return const Padding(
                  padding: EdgeInsets.only(top: AppEspacio.md),
                  child: Text(
                    'Sin tasa USD válida: el margen no se puede '
                    'calcular.',
                    style: AppTexto.secundario,
                  ),
                );
              }
              final margen = precioUsd - costo;
              final pct =
                  costo > 0 ? (margen / costo * 100) : 0.0;
              return Column(
                children: [
                  const SizedBox(height: AppEspacio.md),
                  Tarjeta(
                    child: Row(
                      children: [
                        const Icon(Icons.trending_up_rounded,
                            color: AppColores.exito, size: 32),
                        const SizedBox(width: AppEspacio.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Margen: ${margen.toStringAsFixed(2)} USD '
                                  '(${pct.toStringAsFixed(0)}%)',
                                  style: AppTexto.cuerpo.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: AppColores.exito)),
                              Text(
                                  'Costo: ${costo.toStringAsFixed(2)} USD',
                                  style: AppTexto.secundario),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          // F5 (1.20): historial de ajustes de stock.
          const SizedBox(height: AppEspacio.lg),
          const EncabezadoSeccion(titulo: 'Movimientos de stock'),
          _MovimientosStock(
              suplementoId:
                  (suplemento['id'] as num?)?.toInt() ?? 0),
        ],
      ),
      // Rediseño 1.20: barra de venta FIJA — la acción
      // dominante es la venta rápida de 1 unidad (la misma
      // del botón de la tarjeta); la completa queda como
      // secundaria visible.
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
              AppEspacio.sm, AppEspacio.lg, AppEspacio.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BotonPrimario(
                texto: stock > 0 ? 'Vender 1 unidad' : 'Sin stock',
                icono: Icons.flash_on_rounded,
                onPressed:
                    stock > 0 ? () => _ventaRapida(context) : null,
              ),
              const SizedBox(height: AppEspacio.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: Icon(Icons.receipt_long_rounded,
                      color: AppColores.textoSecundario(context)),
                  label: const Text('Registrar venta completa'),
                  onPressed:
                      stock > 0 ? () => _vender(context) : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// F5 (1.20): diálogo de ajuste de stock con motivo.
/// Devuelve true si se ajustó.
Future<bool> _ajustarStock(BuildContext context,
    Map<String, dynamic> suplemento) async {
  final stockActual =
      (suplemento['stock'] as num?)?.toInt() ?? 0;
  // 1.29 (Oleada 4, barrido): el diálogo vive en un
  // StatefulWidget dueño de sus controladores
  // (_DialogoAjustarStock); antes se disponían nada más
  // resolver el showDialog, con la animación de salida aún
  // reconstruyendo los campos (defecto D-B1-08).
  final r = await showDialog<
      ({String stockTexto, String nota, String motivo})>(
    context: context,
    builder: (_) => _DialogoAjustarStock(stockActual: stockActual),
  );
  if (r == null) return false;
  final nuevo = int.tryParse(r.stockTexto.trim());
  final notaTexto = r.nota;
  final motivo = r.motivo;
  if (nuevo == null || nuevo < 0) {
    if (context.mounted) {
      mostrarSnack(context, 'Escribe un stock válido (0 o más).',
          significado: SignificadoChip.alerta);
    }
    return false;
  }
  if (nuevo == stockActual) {
    if (context.mounted) {
      mostrarSnack(context, 'El stock no cambió.');
    }
    return false;
  }
  try {
    await ajustarStockSuplemento(
      suplementoId: (suplemento['id'] as num?)!.toInt(),
      nuevoStock: nuevo,
      motivo: motivo,
      nota: notaTexto,
    );
    if (context.mounted) {
      mostrarSnack(
          context, 'Stock ajustado: $stockActual → $nuevo',
          significado: SignificadoChip.exito);
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      AppLog.error('detalle_suplemento', 'ajustar_fallo', d: '$e');
      mostrarSnack(context, 'No se pudo ajustar: ${mensajeErrorAmable(e)}',
          significado: SignificadoChip.error);
    }
    return false;
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Ajustar stock»
/// como StatefulWidget DUEÑO de sus controladores,
/// dispuestos en dispose() — el patrón de la casa. Devuelve
/// los textos y el motivo elegidos; null al cancelar. El
/// parseo, las validaciones y el ajuste siguen en
/// _ajustarStock, como siempre.
class _DialogoAjustarStock extends StatefulWidget {
  const _DialogoAjustarStock({required this.stockActual});

  final int stockActual;

  @override
  State<_DialogoAjustarStock> createState() =>
      _DialogoAjustarStockState();
}

class _DialogoAjustarStockState extends State<_DialogoAjustarStock> {
  late final TextEditingController _ctrl;
  final _notaCtrl = TextEditingController();
  String _motivo = 'merma';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.stockActual}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Ajustar stock',
      iconoTitulo: Icons.inventory_2_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Stock actual: ${widget.stockActual}',
              style: AppTexto.cuerpo),
          const SizedBox(height: AppEspacio.md),
          CampoTexto(
            controller: _ctrl,
            etiqueta: 'Nuevo stock',
            teclado: TextInputType.number,
          ),
          const SizedBox(height: AppEspacio.md),
          DropdownButton<String>(
            value: _motivo,
            isExpanded: true,
            items: [
              for (final m in kMotivosAjusteStock)
                DropdownMenuItem(
                    value: m, child: Text(etiquetaMotivoAjuste(m))),
            ],
            onChanged: (v) => setState(() => _motivo = v ?? 'merma'),
          ),
          const SizedBox(height: AppEspacio.md),
          CampoTexto(
            controller: _notaCtrl,
            etiqueta: 'Nota (opcional)',
          ),
        ],
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () => Navigator.pop(context, (
                  stockTexto: _ctrl.text,
                  nota: _notaCtrl.text,
                  motivo: _motivo,
                )),
            child: const Text('Ajustar')),
      ],
    );
  }
}

/// F5 (1.20): movimientos de stock del suplemento desde el
/// espejo de ajustes (antes → después, motivo y autor).
class _MovimientosStock extends StatefulWidget {
  final int suplementoId;
  const _MovimientosStock({required this.suplementoId});

  @override
  State<_MovimientosStock> createState() =>
      _MovimientosStockState();
}

class _MovimientosStockState extends State<_MovimientosStock> {
  List<Map<String, dynamic>> _movs = [];
  bool _listo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    List<Map<String, dynamic>> filas = const [];
    try {
      filas = (await LocalDb.instance
              .allMirror('suplemento_ajustes'))
          .where((a) =>
              (a['suplemento_id'] as num?)?.toInt() ==
              widget.suplementoId)
          .toList()
        ..sort((a, b) =>
            '${b['fecha'] ?? ''}'.compareTo('${a['fecha'] ?? ''}'));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _movs = filas;
      _listo = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_listo) return const SizedBox.shrink();
    if (_movs.isEmpty) {
      return const Text('Sin movimientos registrados.',
          style: AppTexto.secundario);
    }
    return Column(
      children: [
        for (final a in _movs)
          Padding(
            padding:
                const EdgeInsets.symmetric(vertical: AppEspacio.xs),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${a['stock_antes']} → ${a['stock_despues']} · '
                        '${etiquetaMotivoAjuste('${a['motivo'] ?? 'otro'}')}',
                        style: AppTexto.cuerpo,
                      ),
                      Text(
                        '${fmtFecha(a['fecha'] as String?)} · '
                        '${a['registrado_por_nombre'] ?? ''}'
                        '${(a['nota'] as String?)?.isNotEmpty == true ? ' · ${a['nota']}' : ''}',
                        style: AppTexto.secundario,
                      ),
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

/// 1.30 (Oleada 4, §5.3 punto 1): ventas del suplemento en el
/// espejo local. La tabla local usa JSON (data TEXT), no
/// columnas. Si es > 0, la confirmación de eliminar ni se
/// ofrece: la cascada no toca las ventas (historia de dinero
/// con pagos promo enlazados) y el servidor rechaza con el
/// mismo criterio.
Future<int> ventasEspejoDeSuplemento(int suplementoId) async {
  final d = await LocalDb.instance.db;
  final ventas = await d.rawQuery(
    "SELECT COUNT(*) as n FROM ventas_suplementos WHERE json_extract(data, '\$.suplemento_id') = ?",
    [suplementoId],
  );
  return (ventas.first['n'] as int?) ?? 0;
}

/// Las cuentas de lo que se va al eliminar un suplemento
/// (1.30, Oleada 4, §5.3 punto 2).
typedef CuentasCascada = ({
  int pomos,
  int dosis,
  int botes,
  int botesAbiertos,
  int reservasVivas,
});

/// 1.30 (Oleada 4, §5.3 punto 2): cuentas desde los espejos
/// locales, calculadas ANTES de encolar la op: pomos con el Σ
/// de sus saldos derivados (la misma fórmula del servidor vía
/// saldoPomoLocal: asignadas − repartidas − ventas − salidas),
/// botes (abiertos y cerrados) y reservas vivas
/// (solicitada/reservada: las que la cascada borra; las no
/// vivas se desvinculan y no cuentan como pérdida).
Future<CuentasCascada> cuentasCascadaSuplemento(int suplementoId) async {
  final db = LocalDb.instance;
  final pomos = (await db.allMirror('servicio_pomos'))
      .where((p) => (p['suplemento_id'] as num?)?.toInt() == suplementoId)
      .toList();
  var dosis = 0;
  for (final p in pomos) {
    final pid = (p['id'] as num?)?.toInt();
    if (pid != null) dosis += await saldoPomoLocal(pid);
  }
  final botes = (await db.allMirror('servicio_botes'))
      .where((b) => (b['suplemento_id'] as num?)?.toInt() == suplementoId)
      .toList();
  final reservasVivas = (await db.allMirror('reservas'))
      .where((r) =>
          (r['suplemento_id'] as num?)?.toInt() == suplementoId &&
          (r['estado']?.toString() == 'solicitada' ||
              r['estado']?.toString() == 'reservada'))
      .length;
  return (
    pomos: pomos.length,
    dosis: dosis,
    botes: botes.length,
    botesAbiertos:
        botes.where((b) => b['estado']?.toString() == 'abierto').length,
    reservasVivas: reservasVivas,
  );
}

/// PURO (1.30, Oleada 4, §5.3 punto 2): la frase de cuentas de
/// la confirmación, en lenguaje llano. Sin nada que se vaya,
/// cadena vacía.
String textoCuentasCascada(CuentasCascada c) {
  final partes = <String>[];
  if (c.pomos > 0) {
    partes.add('${c.pomos} pomo(s) con ${c.dosis} dosis en total');
  }
  if (c.botes > 0) partes.add('${c.botes} bote(s)');
  if (c.reservasVivas > 0) {
    partes.add('${c.reservasVivas} reserva(s) pendiente(s)');
  }
  if (partes.isEmpty) return '';
  final lista = partes.length == 1
      ? partes.first
      : '${partes.sublist(0, partes.length - 1).join(', ')} y ${partes.last}';
  return 'Se eliminan $lista. '
      'El historial de dosis vendidas se conserva.';
}

/// PURO: el mensaje completo de la confirmación de eliminar
/// (la pregunta de siempre + las cuentas de lo que se va).
String mensajeConfirmacionCascada(String nombre, CuentasCascada c) {
  final cuentas = textoCuentasCascada(c);
  return '¿Eliminar "$nombre" del catálogo? '
      'Esta acción no se puede deshacer.'
      '${cuentas.isEmpty ? '' : '\n\n$cuentas'}';
}

/// Elimina un suplemento (v1.3.1).
/// Pide confirmación (1.30, Oleada 4: enseñando antes las
/// cuentas de lo que se va, §5.3 punto 2), aplica la purga
/// local en cascada y encola la op en una transacción.
/// Suplementos con borrado en curso (candado de exclusión, Argón
/// menos auditados MENOR: sin él, un doble toque encolaba dos borrados).
final _eliminandoSuplementos = <int>{};

Future<void> _eliminarSuplemento(
    BuildContext context, Map<String, dynamic> s) async {
  // Argón menos auditados MENOR: guarda de dueño en el método (el
  // botón ya es solo-dueño) + id parseado seguro antes del cast final.
  if (!AuthService().isOwner) return;
  final id = (s['id'] as num?)?.toInt();
  if (id == null) return;
  final db = LocalDb.instance;
  final d = await db.db;

  // Argón: verificar localmente que no tenga ventas antes de
  // borrar (guarda de ventas de §5.3 punto 1, vía helper).
  final nVentas = await ventasEspejoDeSuplemento(id);
  if (nVentas > 0) {
    if (!context.mounted) return;
    mostrarSnack(context, 'No se puede eliminar: tiene $nVentas venta(s) registrada(s).', significado: SignificadoChip.alerta);
    return;
  }

  // Argón #9 (ALTO): el espejo solo trae ventas ya sincronizadas.
  // Una venta recién hecha vive en ops_queue (detrás del pull):
  // borrar ahora dejaría la op de eliminar detrás de la venta
  // pendiente y el servidor la rebotaría por su guarda de
  // ventas. Solo cuentan ops vivas (pendiente/enviada/en
  // revisión): aplicada ya está en el espejo y rechazada no se
  // aplicará.
  // 1.30 (Oleada 4): los botes abiertos YA NO bloquean — la
  // cascada los borra con el suplemento (§5.2 paso 5) y la
  // confirmación enseña antes sus cuentas (§5.3 punto 2).
  final pendientes = await d.rawQuery(
    "SELECT COUNT(*) as n FROM ops_queue WHERE tipo IN "
    "('venta_suplemento', 'inscripcion_venta_suplemento', "
    "'abrir_bote_servicio') AND estado NOT IN ('aplicada', 'rechazada') "
    "AND (json_extract(payload, '\$.suplemento_id') = ? "
    "OR json_extract(payload, '\$.venta.suplemento_id') = ?)",
    [id, id],
  );
  final nPendientes = (pendientes.first['n'] as int?) ?? 0;
  if (nPendientes > 0) {
    if (!context.mounted) return;
    mostrarSnack(context, 'No se puede eliminar: tiene operaciones pendientes de sincronizar.', significado: SignificadoChip.alerta);
    return;
  }

  if (!context.mounted) return;
  final nombre = '${s['nombre'] ?? 'suplemento'}';
  // 1.30 (Oleada 4, §5.3 punto 2): las cuentas de lo que se va,
  // desde los espejos, ANTES de que el dueño confirme.
  final cuentas = await cuentasCascadaSuplemento(id);
  if (!context.mounted) return;
  final ok = await DialogoApp.confirmar(
    context,
    titulo: 'Eliminar suplemento',
    mensaje: mensajeConfirmacionCascada(nombre, cuentas),
    aceptar: 'Eliminar',
  );
  if (ok != true || !context.mounted) return;

  // Argón menos auditados MENOR: candado de exclusión por suplemento.
  if (!_eliminandoSuplementos.add(id)) return;
  try {
    // Marcar como eliminado localmente y encolar la op en UNA
    // transacción (panel 9/10 Luna): dos pasos separados dejaban el
    // borrado sin op si la app se cerraba entre ambos.
    await db.eliminarSuplementoLocal(id);
    AppLog.info('suplementos', 'eliminar', d: 'id=$id nombre=$nombre');

    if (!context.mounted) return;
    mostrarSnack(context, 'Suplemento eliminado', significado: SignificadoChip.exito);
    Navigator.of(context).pop();
    SyncEngine.instance.push();
  } finally {
    _eliminandoSuplementos.remove(id);
  }
}
