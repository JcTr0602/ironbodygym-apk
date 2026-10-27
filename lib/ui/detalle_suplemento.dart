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
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'suplementos.dart';
import 'venta_suplemento.dart';
import 'widgets.dart';

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
    [double? tasaUsd]) async {
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  if (stock <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Sin stock disponible para venta rápida')));
    return false;
  }
  if (!context.mounted) return false;
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => _DialogoVentaRapida(sup: s, stock: stock),
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

  const _DialogoVentaRapida({required this.sup, required this.stock});

  @override
  State<_DialogoVentaRapida> createState() =>
      _DialogoVentaRapidaState();
}

class _DialogoVentaRapidaState extends State<_DialogoVentaRapida> {
  int _cantidad = 1;
  final _precio = TextEditingController();
  final _notaPrecio = TextEditingController();
  final _busqueda = TextEditingController();
  final _permisos = Permisos();

  int? _clienteId;
  String _clienteNombre = '';
  bool _promoActiva = false;
  bool _aceptaSinPromo = false;
  bool _guardando = false;
  List<Map<String, dynamic>> _clientes = [];

  double get _precioOficial =>
      (widget.sup['precio_oficial'] as num?)?.toDouble() ??
      (widget.sup['precio'] as num?)?.toDouble() ??
      0;

  /// v1.4.6: la venta rápida se registra en la moneda del
  /// suplemento (antes 'USD' fijo: un suplemento en CUP habría
  /// quedado vendido como si fuera en USD).
  String get _monedaSup => LocalDb.monedaDe(widget.sup);

  double? get _precioVenta =>
      double.tryParse(_precio.text.trim().replaceAll(',', '.'));

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
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _confirmar() async {
    if (!_puedeConfirmar || _guardando) return;
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
        compradorTipo: _conCliente ? 'cliente' : 'externo',
        clienteId: _clienteId,
        compradorNombre:
            _conCliente ? _clienteNombre : 'Cliente externo',
        nota: 'venta rápida',
        notaPrecio:
            _precioDifiere && notaPrecio.isNotEmpty ? notaPrecio : null,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se registró la venta: $e')));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Vender ${widget.sup['nombre'] ?? 'suplemento'}',
      iconoTitulo: Icons.flash_on,
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
                icono: Icons.edit_note,
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
                icono: Icons.person_search,
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
                              ? Icons.lock_outline
                              : Icons.add_circle_outline,
                          color: AppColores.naranja),
                      onTap: () {
                        if (protegido) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content:
                                      Text(mensajeClienteProtegido)));
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

  Widget _stepperCantidad() {
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: _cantidad > 1 && !_guardando
                ? () => setState(() => _cantidad--)
                : null,
          ),
          Text('$_cantidad', style: AppTexto.displayPequeno),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
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
            const Icon(Icons.warning_amber,
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
          const Icon(Icons.person, color: AppColores.exito),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Text(_clienteNombre, style: AppTexto.cuerpo),
          ),
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: 'Quitar cliente',
            onPressed: _guardando
                ? null
                : () => setState(() {
                      _clienteId = null;
                      _clienteNombre = '';
                      _aceptaSinPromo = false;
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
          Icon(Icons.card_giftcard, color: AppColores.exito),
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
              const Icon(Icons.warning_amber,
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
  final cup = moneda == 'USD' && tasaUsd != null && tasaUsd > 1.0
      ? ' (≈ ${fmtMonto(precio * tasaUsd)} CUP)'
      : '';
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  final texto = 'Iron Body Gym — Suplementos\n\n'
      '$nombre\n'
      'Precio: ${precio.toStringAsFixed(2)} $moneda$cup\n'
      'Disponibles: $stock';
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No se pudo compartir')));
    }
  }
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
      MaterialPageRoute(
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Venta registrada (se sincronizará)')));
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
    // v1.4.6: el equivalente en CUP solo aplica si el precio
    // oficial está en USD (moneda del propio suplemento).
    final monedaSup = LocalDb.monedaDe(suplemento);
    final cup = monedaSup == 'USD' && tasaUsd != null && tasaUsd! > 1.0
        ? '≈ ${fmtMonto(precio * tasaUsd!)} CUP'
        : null;
    // v1.4.3: presentación del envase (la misma que ve el cliente
    // en su catálogo). Parseo tolerante: el espejo puede traer el
    // número como num o como texto.
    final pesoV = suplemento['peso_valor'] is num
        ? (suplemento['peso_valor'] as num).toDouble()
        : double.tryParse('${suplemento['peso_valor'] ?? ''}');
    final pesoU = '${suplemento['peso_unidad'] ?? ''}'.trim();
    final servD = suplemento['servicios_estandar'] is num
        ? (suplemento['servicios_estandar'] as num).toDouble()
        : double.tryParse('${suplemento['servicios_estandar'] ?? ''}');
    // Solo se muestra si es un entero positivo: redondear un
    // dato fraccionario legado (1.5 → «2 servicios») fabricaría
    // un dato que no existe (panel 2026-10-21).
    final serv = (servD != null &&
            servD > 0 &&
            servD == servD.roundToDouble())
        ? servD.toInt()
        : null;
    final presentacion = [
      if (pesoV != null && pesoV > 0 && pesoU.isNotEmpty)
        '${pesoV == pesoV.roundToDouble() ? pesoV.toInt() : pesoV} $pesoU',
      if (serv != null && serv > 0)
        '$serv servicio${serv == 1 ? '' : 's'}',
    ].join(' · ');

    return Scaffold(
      appBar: AppBar(
        title: Text(nombre,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Compartir por WhatsApp',
            onPressed: () =>
                compartirSuplemento(context, suplemento, tasaUsd),
          ),
          if (AuthService().isOwner)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Editar suplemento',
              onPressed: () async {
                final editado = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        EditarSuplementoScreen(suplemento: suplemento),
                  ),
                );
                if (editado == true && context.mounted) {
                  Navigator.pop(context, true);
                }
              },
            ),
          if (AuthService().isOwner)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Eliminar suplemento',
              onPressed: () =>
                  _eliminarSuplemento(context, suplemento),
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
          if (fotoLocal != null && fotoLocal.isNotEmpty && File(fotoLocal).existsSync())
            ClipRRect(
              borderRadius:
                  BorderRadius.circular(AppRadio.lg),
              child: Image.file(File(fotoLocal),
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 200,
                    decoration: BoxDecoration(
                      color: AppColores.fondo(context),
                      borderRadius:
                          BorderRadius.circular(AppRadio.lg),
                    ),
                    child: const Icon(
                        Icons.medication_outlined,
                        size: 72,
                        color: AppColores.naranja),
                  )),
            )
          else
            FutureBuilder(
              future: FotoCache.instance.obtener(foto),
              builder: (ctx, snap) {
                final f = snap.data;
                if (f == null) {
                  return Container(
                    height: 200,
                    decoration: BoxDecoration(
                      color: AppColores.fondo(context),
                      borderRadius:
                          BorderRadius.circular(AppRadio.lg),
                    ),
                    child: const Icon(
                        Icons.medication_outlined,
                        size: 72,
                        color: AppColores.naranja),
                  );
                }
                return ClipRRect(
                  borderRadius:
                      BorderRadius.circular(AppRadio.lg),
                child: Image.file(f,
                    height: 220,
                    width: double.infinity,
                    fit: BoxFit.cover),
              );
            },
          ),
          const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              Expanded(
                child: Text(nombre,
                    style: AppTexto.titulo),
              ),
              if (inactivo)
                const ChipEstado(
                    texto: 'Inactivo',
                    color: Colors.grey),
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
                const Icon(Icons.payments_outlined,
                    color: AppColores.naranja, size: 32),
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
                      Text('$stock disponibles',
                          style: AppTexto.secundario),
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
                return const SizedBox.shrink();
              }
              double? precioUsd;
              if (monedaSup == 'USD') {
                precioUsd = precio;
              } else if (tasaUsd != null && tasaUsd! > 1.0) {
                precioUsd = precio / tasaUsd!;
              }
              if (precioUsd == null) {
                return const SizedBox.shrink();
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
                        const Icon(Icons.trending_up_outlined,
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
          const SizedBox(height: AppEspacio.lg),
          BotonPrimario(
            texto: 'Vender',
            onPressed:
                stock > 0 ? () => _vender(context) : null,
          ),
          const SizedBox(height: AppEspacio.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.flash_on,
                  color: AppColores.naranja),
              label: const Text('Venta rápida (1 unidad)'),
              onPressed: stock > 0
                  ? () => _ventaRapida(context)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Elimina un suplemento (v1.3.1).
/// Pide confirmación, lo marca como eliminado localmente y encola la op.
Future<void> _eliminarSuplemento(
    BuildContext context, Map<String, dynamic> s) async {
  final db = LocalDb.instance;
  final d = await db.db;
  final id = s['id'];

  // Argón: verificar localmente que no tenga ventas antes de borrar.
  // La tabla local usa JSON (data TEXT), no columnas.
  final ventas = await d.rawQuery(
    "SELECT COUNT(*) as n FROM ventas_suplementos WHERE json_extract(data, '\$.suplemento_id') = ?",
    [id],
  );
  final nVentas = (ventas.first['n'] as int?) ?? 0;
  if (nVentas > 0) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'No se puede eliminar: tiene $nVentas venta(s) registrada(s).'),
      ),
    );
    return;
  }

  // Argón #9 (ALTO): el espejo solo trae ventas ya sincronizadas.
  // Una venta recién hecha vive en ops_queue (detrás del pull) y un
  // bote abierto vive en servicio_botes: borrar ahora dejaría la op
  // de eliminar detrás de la venta pendiente. Solo cuentan ops
  // vivas (pendiente/enviada/en revisión): aplicada ya está en el
  // espejo y rechazada no se aplicará.
  final pendientes = await d.rawQuery(
    "SELECT COUNT(*) as n FROM ops_queue WHERE tipo IN "
    "('venta_suplemento', 'inscripcion_venta_suplemento', "
    "'abrir_bote_servicio') AND estado NOT IN ('aplicada', 'rechazada') "
    "AND (json_extract(payload, '\$.suplemento_id') = ? "
    "OR json_extract(payload, '\$.venta.suplemento_id') = ?)",
    [id, id],
  );
  final nPendientes = (pendientes.first['n'] as int?) ?? 0;
  final botesAbiertos = await d.rawQuery(
    "SELECT COUNT(*) as n FROM servicio_botes WHERE "
    "json_extract(data, '\$.suplemento_id') = ? AND "
    "json_extract(data, '\$.estado') = 'abierto'",
    [id],
  );
  final nBotes = (botesAbiertos.first['n'] as int?) ?? 0;
  if (nPendientes > 0 || nBotes > 0) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'No se puede eliminar: tiene ventas pendientes o botes abiertos.'),
      ),
    );
    return;
  }

  if (!context.mounted) return;
  final nombre = '${s['nombre'] ?? 'suplemento'}';
  final ok = await DialogoApp.confirmar(
    context,
    titulo: 'Eliminar suplemento',
    mensaje: '¿Eliminar "$nombre" del catálogo? Esta acción no se puede deshacer.',
    aceptar: 'Eliminar',
  );
  if (ok != true || !context.mounted) return;

  // Marcar como eliminado localmente y encolar la op en UNA
  // transacción (panel 9/10 Luna): dos pasos separados dejaban el
  // borrado sin op si la app se cerraba entre ambos.
  await db.eliminarSuplementoLocal((id as num).toInt());
  AppLog.info('suplementos', 'eliminar', d: 'id=$id nombre=$nombre');

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Suplemento eliminado')));
  Navigator.of(context).pop();
  SyncEngine.instance.push();
}
