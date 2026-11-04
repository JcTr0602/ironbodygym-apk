// Registrar venta de suplemento (entrenadores y dueño).
//
// - Precio precargado SIEMPRE con precio_oficial (jamás ultimo_precio);
//   referencia fija "Precio oficial: X".
// - Si el precio difiere del oficial (comparación en centavos): advertencia
//   clara + confirmación explícita + nota_precio obligatoria si no es dueño.
// - Moneda CUP/USD (chips). v1.4.6: la moneda de la venta arranca
//   en la moneda del suplemento (su precio oficial está expresado
//   en ella); en USD se oculta el campo "Tasa (CUP por 1 USD)" y el
//   equivalente en CUP (pedido Jc 2026-10-16); solo aparecen si se
//   elige CUP.
// - Comprador: cliente del gym o externo.
// - Venta por el camino único registrarVentaSuplemento (transacción
//   atómica: stock JSON + op en ops_queue; nunca inserta en
//   ventas_suplementos, espejo puro por pull).
// - Si la promo "mes gratis" está activa y el comprador es cliente,
//   la confirmación avisa que se le asignará 1 mes de mensualidad.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../fotos.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../auth.dart';
import '../permisos.dart';
import '../tiempo.dart';
import '../cliente_protegido.dart';
import 'componentes.dart';
import 'aviso_duplicado.dart';
import 'confirmacion_cobro.dart';
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

/// 1.15 V1: el fiado solo existe en CUP y solo con cliente del gym.
/// El switch se muestra solo si ambas condiciones se cumplen.
bool mostrarSwitchFiadoVenta(
        {required String tipoComprador, required String moneda}) =>
    tipoComprador == 'cliente' && moneda == 'CUP';

/// 1.15 V1: al pasar a USD el fiado se apaga (un fiado en USD no
/// existe); en cualquier otro cambio se conserva el valor actual.
bool fiadoTrasCambiarMonedaVenta(
        String monedaNueva, bool esFiadoActual) =>
    monedaNueva == 'USD' ? false : esFiadoActual;

/// 1.15 V1: la promo «mes gratis» nunca se promete a un fiado:
/// ni la vista previa ni el comprobante la anuncian si la venta
/// es a fiado (el fiado no es un cobro y no genera el mes).
bool conPromoVentaSuplemento(
        {required bool promoActiva,
        required String tipoComprador,
        required bool esFiado}) =>
    promoActiva &&
    (tipoComprador == 'cliente' || tipoComprador == 'inscribir_nuevo') &&
    !esFiado;

/// 1.15 V3: precio oficial convertido a la moneda de la venta,
/// para el camino inscripción+venta. null = referencia no
/// convertible (falta tasa válida): ese camino se BLOQUEA, no
/// se cae al crudo en silencio (un oficial CUP guardado como si
/// fuera USD falsearía el precio).
double? oficialConvertidoSuplemento(
    {required String monedaSuplemento,
    required double precioOficial,
    required String monedaVenta,
    required double? tasaUsd}) {
  if (monedaSuplemento == 'USD') {
    return precioOficialEn(monedaVenta, precioOficial, tasaUsd);
  }
  if (monedaVenta == 'CUP') return precioOficial;
  if (tasaUsd == null || tasaUsd <= 0 || !tasaUsd.isFinite) return null;
  return precioOficial / tasaUsd;
}

class _VentaSuplementoScreenState
    extends State<VentaSuplementoScreen> {
  int _cantidad = 1;
  final _precio = TextEditingController();
  final _tasa = TextEditingController();
  final _compradorNombre = TextEditingController();
  // v1.2.1: nota opcional de la venta (ej: "apartado").
  final _nota = TextEditingController();
  // v1.3.4 (B3/C-Auditoría, candado b): motivo del precio distinto al
  // oficial. Obligatorio (mín. 5 caracteres) si quien vende NO es el dueño.
  final _notaPrecio = TextEditingController();
  final _permisos = Permisos();
  // v1.4.6: la moneda inicial es la del suplemento (se asigna en
  // initState desde widget.suplemento); este valor es solo el
  // respaldo antes de initState.
  String _moneda = 'CUP';
  String _tipoComprador = 'cliente'; // cliente | externo_nombre | externo_generico | inscribir_nuevo
  int? _clienteId;
  String _clienteNombre = '';
  bool _promoActiva = false;
  bool _guardando = false;
  // v1.3.7 (Fase B §6.2): venta a fiado (solo con cliente).
  bool _esFiado = false;

  double get _precioOficial =>
      (widget.suplemento['precio_oficial'] as num?)?.toDouble() ?? 0;

  /// v1.4.6: moneda en la que está expresado el precio oficial
  /// del suplemento (fallback 'CUP').
  String get _monedaSuplemento => LocalDb.monedaDe(widget.suplemento);

  /// v1.4.6: precio oficial convertido a la moneda [m] de la venta.
  /// El oficial vive en la moneda del suplemento: si esta es USD se
  /// conserva EXACTAMENTE el comportamiento histórico (v1.2.4:
  /// [precioOficialEn], con redondeo a decenas al pasar a CUP); si
  /// es CUP, a CUP va tal cual y a USD se divide por la tasa.
  /// 1.15 V3: la conversión vive en oficialConvertidoSuplemento
  /// (testeable); este método solo la aplica al estado actual.
  double? _oficialEn(String m) => oficialConvertidoSuplemento(
        monedaSuplemento: _monedaSuplemento,
        precioOficial: _precioOficial,
        monedaVenta: m,
        tasaUsd: _tasaUsd,
      );

  /// v1.2.4: precio oficial en la moneda elegida (CUP = oficial × tasa).
  double? get _oficialEnMoneda => _oficialEn(_moneda);

  /// v1.3.4 (candado a de auditoría): la comparación se hace en centavos
  /// enteros, nunca con double directamente.
  bool get _precioDifiere {
    final p =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    final ref = _oficialEnMoneda;
    if (p == null || ref == null) return false;
    return precioDifiereEnCentavos(p, ref);
  }

  /// v1.2.4: al cambiar de moneda, si el precio no se tocó a mano,
  /// se rellena con el oficial convertido (evita cobrar 50 CUP por 50 USD).
  void _cambiarMoneda(String m) {
    final anterior = _oficialEn(_moneda);
    final actual =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    final sinTocar = actual == null ||
        (anterior != null && (actual - anterior).abs() < 0.01);
    setState(() {
      _moneda = m;
      // 1.15 V1: al pasar a USD el fiado se apaga (no hay fiado USD).
      _esFiado = fiadoTrasCambiarMonedaVenta(m, _esFiado);
      final nuevo = _oficialEn(m);
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

  // Autoauditoría 1.22 #2 (clase N-2): la tasa no finita no es
  // una tasa (NaN pasaba las validaciones <= 0 de las dos rutas
  // de venta y viajaba en el payload).
  double? get _tasaUsd {
    final v = double.tryParse(_tasa.text.trim().replaceAll(',', '.'));
    return (v != null && v.isFinite) ? v : null;
  }

  double get _total {
    final p =
        double.tryParse(_precio.text.trim().replaceAll(',', '.')) ?? 0;
    return p * _cantidad;
  }

  @override
  void initState() {
    super.initState();
    // v1.4.6: el selector de moneda arranca en la moneda del
    // suplemento (el precio oficial está expresado en ella).
    _moneda = _monedaSuplemento;
    // v1.3.4 (B3-Invariante): el campo se inicializa SIEMPRE y ÚNICAMENTE
    // con precio_oficial. Jamás se lee ultimo_precio para pre-llenar.
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
    _notaPrecio.dispose();
    super.dispose();
  }

  Future<void> _elegirCliente() async {
    final clientes =
        await LocalDb.instance.allMirror('clientes');
    final activos = clientes
        .where((c) => (c['estado'] as String?) == 'activo')
        .toList()
      ..sort(compararPorNombre);
    if (!mounted) return;
    final sel = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _DialogoBuscarCliente(clientes: activos),
    );
    if (sel != null && mounted) {
      setState(() {
        _clienteId = (sel['id'] as num?)?.toInt();
        _clienteNombre = '${sel['nombre'] ?? ''}';
        _tipoComprador = 'cliente';
      });
    }
  }

  /// 1.23 S-7 (Argón H-06): stock VIGENTE del suplemento,
  /// releído del espejo en el momento de confirmar. El mapa
  /// del widget es una foto de cuando se abrió la pantalla:
  /// un pull puede haber bajado el stock (hasta 0) con la
  /// pantalla abierta, y el pre-chequeo contra la foto dejaba
  /// confirmar una venta que el espejo ya no respalda.
  Future<int> _stockVigente() async {
    final sid = (widget.suplemento['id'] as num?)?.toInt();
    if (sid == null) {
      return (widget.suplemento['stock'] as num?)?.toInt() ?? 0;
    }
    final filas =
        await LocalDb.instance.mirrorPorIds('suplementos', [sid]);
    if (filas.isEmpty) {
      return (widget.suplemento['stock'] as num?)?.toInt() ?? 0;
    }
    return (filas.first['stock'] as num?)?.toInt() ?? 0;
  }

  Future<void> _confirmar() async {
    // v1.3.1: guarda de reentrada (evita venta duplicada).
    // Argón (regresión 1): _guardando solo se activa DESPUÉS de pasar todas
    // las validaciones y el diálogo de confirmación. Activarlo antes dejaba
    // el botón muerto si una validación fallaba.
    if (_guardando) return;
    // Argón P1#2-parte: pre-chequeo de stock antes de confirmar
    // (la transacción ya lanza «Stock insuficiente», pero sin esto
    // el usuario llegaba al final para enterarse).
    // 1.23 S-7: contra el espejo VIGENTE, no contra la foto
    // del widget (ver _stockVigente).
    final stockActual = await _stockVigente();
    if (_cantidad < 1 || _cantidad > stockActual) {
      await DialogoApp.confirmar(context,
          titulo: 'Stock insuficiente',
          mensaje: _cantidad < 1
              ? 'Indica una cantidad mayor que 0.'
              : 'Solo quedan $stockActual en stock.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    final precio =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    if (precio == null || !precio.isFinite || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el precio',
          mensaje: 'Indica un precio de venta mayor que 0.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    // 1.23 AT-15: la tasa viaja siempre que haya una válida.
    // En CUP convierte el oficial; en USD el servidor la
    // EXIGE para valorar la venta (con el centinela 1.0 de
    // antes, una venta de 30 USD quedaba valorada a 30 CUP y
    // el aviso al dueño decía «tasa 1»). El campo sigue oculto
    // en USD (pedido de Jc 2026-10-16): el valor es la tasa
    // del día precargada desde Admin; sin ella no se vende.
    final tasa = _tasaUsd;
    if (tasa == null || tasa <= 0 || !tasa.isFinite) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa la valoración',
          mensaje: _moneda == 'CUP'
              ? 'Indica a cuántos CUP equivale 1 USD para esta venta.'
              : 'Falta la tasa del día para valorar la venta en '
                  'USD. Jc la configura en Admin (tasa USD).',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    // Lote 1 Argón (bloqueante): sin conversión válida NO se vende.
    // Antes el fallback caía al precio crudo etiquetado con la moneda
    // de la venta (15000 CUP guardados como 15000 USD) y _precioDifiere
    // devolvía false (ref null), así que ni siquiera pedía nota.
    // El camino inscripción+venta ya se bloqueaba así desde 1.15 V3;
    // la venta simple queda igual.
    final oficialConvertido = _oficialEnMoneda;
    if (oficialConvertido == null) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa la valoración',
          mensaje: 'No se pudo convertir el precio oficial a '
              '$_moneda sin una tasa válida. Revisa la tasa del '
              'día antes de vender.',
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
    // v1.3.4 (B3/C-Auditoría, candado b): si el precio difiere del oficial
    // y quien vende NO es el dueño, la nota de precio es obligatoria
    // (mín. 5 caracteres). Sin nota no se puede confirmar.
    final difiere = _precioDifiere;
    final notaPrecio = _notaPrecio.text.trim();
    if (difiere && !_permisos.esDueno && notaPrecio.length < 5) {
      await DialogoApp.confirmar(context,
          titulo: 'Falta la nota de precio',
          mensaje: 'Vas a vender a un precio distinto al oficial. '
              'Escribe el motivo (mín. 5 caracteres, '
              'ej. "Autorizado por Jc por compra de 2 botes").',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    final sid = (widget.suplemento['id'] as num?)?.toInt();
    if (sid == null) {
      await DialogoApp.confirmar(context,
          titulo: 'No se registró la venta',
          mensaje: 'Suplemento sin identificador válido.',
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
    final conPromo = conPromoVentaSuplemento(
      promoActiva: _promoActiva,
      tipoComprador: _tipoComprador,
      esFiado: _esFiado,
    );
    final oficialRef = oficialConvertido;

    // v1.8.1 (pedido de Jc tras la venta duplicada del 2026-10-23):
    // la confirmación es la VISTA PREVIA del comprobante completo,
    // tal cual saldrá por WhatsApp. Antes el resumen era genérico y
    // el comprobante solo se veía DESPUÉS de registrar: Jc entró dos
    // veces «solo a ver el mensaje» y registró la venta dos veces.
    final ok = await _confirmarConVistaPrevia(
      nombreComprador: nombreComprador,
      total: total,
      conPromo: conPromo,
      precio: precio,
      difiere: difiere,
      oficialRef: oficialRef,
    );
    if (!ok) {
      return;
    }

    // T16 (1.20): aviso si ya hay una venta igual en la cola
    // (la vista previa ya evitó el caso de 2026-10-23; esto
    // cubre el doble toque y el reintento con mala conexión).
    final centavosUnit = (precio * 100).round();
    final sigueVenta = await confirmarSiPareceDuplicado(
      context,
      tipo: 'venta_suplemento',
      coincide: (p) =>
          (p['suplemento_id'] as num?)?.toInt() == sid &&
          (p['cantidad'] as num?)?.toInt() == _cantidad &&
          (p['precio_venta_centavos'] as num?)?.toInt() ==
              centavosUnit,
      descripcion: 'una venta de '
          '${widget.suplemento['nombre']} x$_cantidad',
    );
    if (!sigueVenta) return;

    // v1.3.1 (Argón regresión 1): activar _guardando solo aquí, después de
    // validaciones y confirmación. El finally lo restaura siempre.
    setState(() => _guardando = true);
    try {
      // v1.3.4 (B1-Unificación): ÚNICO camino de venta — transacción
      // atómica (descuento de stock en el JSON + op en ops_queue).
      // NUNCA inserta en ventas_suplementos (espejo puro por pull) ni
      // toca ultimo_precio (telemetría muerta de v18).
      await registrarVentaSuplemento(
        suplementoId: sid,
        cantidad: _cantidad,
        precioOficial: oficialRef,
        precioVenta: precio,
        moneda: _moneda,
        usdTasa: tasa,
        // ChatGPT CRÍTICO 2: el servidor solo acepta 'cliente'|'externo'.
        // 'externo_nombre' y 'externo_generico' se mapean a 'externo'.
        compradorTipo:
            _tipoComprador == 'cliente' ? 'cliente' : 'externo',
        clienteId: _clienteId,
        compradorNombre: nombreComprador,
        // v1.2.1: nota opcional.
        nota: _nota.text.trim().isEmpty ? null : _nota.text.trim(),
        // v1.3.4 (candado b): solo viaja si el precio difiere.
        notaPrecio:
            difiere && notaPrecio.isNotEmpty ? notaPrecio : null,
        // v1.3.7 (Fase B §6.2): fiado.
        esFiado: _esFiado && _tipoComprador == 'cliente',
      );
      // v1.3.1 (Argón): pop solo si el registro tuvo éxito.
      // v1.3.7: antes de cerrar, muestra el comprobante con opción
      // de enviarlo por WhatsApp (pedido de Jc).
      if (mounted) {
        await _mostrarComprobante(
          nombreComprador: nombreComprador,
          total: total,
          conPromo: conPromo,
          precio: precio,
        );
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      // v1.3.1: si falla el registro, avisar y NO cerrar (evita duplicado).
      if (mounted) {
        await DialogoApp.confirmar(context,
            titulo: 'No se registró la venta',
            mensaje: 'Inténtalo de nuevo. ($e)',
            aceptar: 'Entendido',
            cancelar: '');
      }
    } finally {
      // v1.3.1 (Argón regresión 1): restaura _guardando siempre.
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// v1.8.1: arma el comprobante de la venta — lo usan la VISTA
  /// PREVIA (antes de registrar) y la pantalla de éxito
  /// «¡Venta registrada!» (Bloque 4, T5).
  /// Devuelve el texto y, si el cliente tiene móvil, el número
  /// listo para wa.me. Con promo, la nueva fecha de vencimiento
  /// sale de previewHasta sobre la ficha local: la MISMA regla
  /// que el servidor aplica al insertar el pago promo
  /// (max(vencimiento, hoy) + 30 días).
  Future<({String texto, String? waNum})> _construirComprobante({
    required String nombreComprador,
    required double total,
    required bool conPromo,
    required double precio,
  }) async {
    final nombreProd = '${widget.suplemento['nombre'] ?? ''}';
    final fecha = hoyHabanaIso();
    String? waNum;
    String? nuevoVencimiento;
    if (_tipoComprador == 'cliente' && _clienteId != null) {
      final clientes = await LocalDb.instance.allMirror('clientes');
      final cli = clientes.cast<Map<String, dynamic>?>().firstWhere(
            (c) => (c?['id'] as num?)?.toInt() == _clienteId,
            orElse: () => null,
          );
      final tel = '${cli?['telefono'] ?? ''}'.trim();
      if (tel.isNotEmpty) waNum = normalizarTelefonoWaMe(tel);
      if (conPromo) {
        final hastaActual = '${cli?['pagado_hasta'] ?? ''}'.trim();
        nuevoVencimiento =
            previewHasta(hastaActual.isEmpty ? null : hastaActual, 1);
      }
    }
    final texto = textoComprobanteCompra(
      nombreProducto: nombreProd,
      cantidad: _cantidad,
      precio: precio,
      moneda: _moneda,
      total: total,
      nombreComprador: nombreComprador,
      fechaIso: fecha,
      conPromo: conPromo,
      nuevoVencimientoIso: nuevoVencimiento,
      esFiado: _esFiado && _tipoComprador == 'cliente',
      // 13/25: el vendedor es quien vende (la venta de
      // suplementos no lleva método en la app: se registra sin
      // método y lo pone el servidor al sincronizar, así que el
      // comprobante en pantalla no inventa ninguno; el método sí
      // sale en el recibo del historial, que lee la fila espejo).
      vendedor: AuthService().displayName,
    );
    return (texto: texto, waNum: waNum);
  }

  /// v1.8.1 (pedido de Jc tras la venta duplicada del 2026-10-23):
  /// ventana de revisión ANTES de registrar — muestra el
  /// comprobante completo en una burbuja estilo WhatsApp y solo
  /// al tocar «Confirmar venta» se encola la operación. Tras
  /// registrar, el botón de WhatsApp solo abre el chat (no
  /// registra nada), así que revisar el mensaje nunca duplica.
  Future<bool> _confirmarConVistaPrevia({
    required String nombreComprador,
    required double total,
    required bool conPromo,
    required double precio,
    required bool difiere,
    required double oficialRef,
  }) async {
    final c = await _construirComprobante(
      nombreComprador: nombreComprador,
      total: total,
      conPromo: conPromo,
      precio: precio,
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
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE7F6EC),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(c.texto.replaceAll('*', '')),
            ),
            if (difiere) ...[
              const SizedBox(height: 12),
              Text(
                '⚠️ Precio distinto al oficial '
                '(${oficialRef.toStringAsFixed(2)} $_moneda).',
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

  /// v1.3.7: muestra el comprobante de la venta con opción de enviarlo
  /// por WhatsApp al cliente (si tiene móvil en su ficha).
  /// Pedido de Jc: comprobante + detalles de la promo (mes gratis).
  /// 1.23 Bloque 4 (T5/T6): el éxito deja de ser un diálogo y pasa
  /// a la pantalla compartida de confirmación (la misma gramática
  /// del cobro): marca animada, total que cuenta con MontoAnimado,
  /// comprobante y el botón de WhatsApp como acción extra de la
  /// pantalla. Al cerrar («Entendido») se vuelve a esta pantalla,
  /// igual que al cerrar el diálogo.
  Future<void> _mostrarComprobante({
    required String nombreComprador,
    required double total,
    required bool conPromo,
    required double precio,
  }) async {
    final c = await _construirComprobante(
      nombreComprador: nombreComprador,
      total: total,
      conPromo: conPromo,
      precio: precio,
    );
    final textoComprobante = c.texto;
    final waNum = c.waNum;
    if (!mounted) return;
    await Navigator.of(context).push(
      RutaIron(
        builder: (_) => ConfirmacionOperacionScreen(
          titulo: '¡Venta registrada!',
          etiquetaMonto: 'Total',
          monto: textoTotalVenta(
              total, _moneda, _moneda == 'CUP' ? _tasaUsd : null),
          montoValor: total,
          montoFormato: (v) => textoTotalVenta(
              v, _moneda, _moneda == 'CUP' ? _tasaUsd : null),
          detalles: [
            (
              etiqueta: 'Producto',
              valor: '${widget.suplemento['nombre']} ×$_cantidad'
            ),
            (etiqueta: 'Comprador', valor: nombreComprador),
          ],
          comprobanteTitulo: 'Comprobante',
          comprobanteTexto: textoComprobante.replaceAll('*', ''),
          accionExtra: waNum == null
              ? null
              : AccionExtraConfirmacion(
                  texto: 'Enviar por WhatsApp',
                  icono: Icons.send_rounded,
                  alPulsar: () async {
                    final url = Uri.parse(
                        'https://wa.me/$waNum?text=${Uri.encodeComponent(textoComprobante)}');
                    try {
                      await launchUrl(url,
                          mode: LaunchMode.externalApplication);
                    } catch (_) {
                      if (mounted) {
                        mostrarSnack(
                            context, 'No se pudo abrir WhatsApp',
                            significado: SignificadoChip.error);
                      }
                    }
                  },
                ),
        ),
      ),
    );
  }

  /// Abre la pantalla combinada inscripción + venta con los datos
  /// ya elegidos. Si vuelve con éxito, cierra esta pantalla también.
  Future<void> _irAInscripcionVenta() async {
    // Argón P1#2-parte: mismo pre-chequeo de stock que _confirmar.
    // 1.23 S-7: contra el espejo VIGENTE (ver _stockVigente).
    final stockActual = await _stockVigente();
    if (_cantidad < 1 || _cantidad > stockActual) {
      await DialogoApp.confirmar(context,
          titulo: 'Stock insuficiente',
          mensaje: _cantidad < 1
              ? 'Indica una cantidad mayor que 0.'
              : 'Solo quedan $stockActual en stock.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    final precio =
        double.tryParse(_precio.text.trim().replaceAll(',', '.'));
    if (precio == null || !precio.isFinite || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el precio',
          mensaje: 'Indica un precio de venta mayor que 0.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    {
      // v1.3.4 (pedido Jc 2026-10-16): tasa solo obligatoria en CUP;
      // en USD el campo está oculto y viaja null.
      final tasa = _moneda == 'CUP' ? _tasaUsd : null;
      if (_moneda == 'CUP' && (tasa == null || tasa <= 0)) {
        await DialogoApp.confirmar(context,
            titulo: 'Revisa la valoración',
            mensaje:
                'Indica a cuántos CUP equivale 1 USD para esta venta.',
            aceptar: 'Entendido',
            cancelar: '');
        return;
      }
    }
    // Auditoría (Argón): el flujo inscribir_nuevo no puede bypassear
    // el candado de nota_precio. Misma validación que _guardar().
    final difiere = _precioDifiere;
    final notaPrecio = _notaPrecio.text.trim();
    if (difiere && !_permisos.esDueno && notaPrecio.length < 5) {
      await DialogoApp.confirmar(context,
          titulo: 'Falta la nota de precio',
          mensaje: 'Vas a vender a un precio distinto al oficial. '
              'Escribe el motivo (mín. 5 caracteres, '
              'ej. "Autorizado por Jc por compra de 2 botes").',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    if (!mounted) return;
    // 1.15 V3: el camino inscripción+venta envía el oficial
    // CONVERTIDO a la moneda de la venta, nunca el crudo. Si no
    // hay conversión válida (falta tasa para USD): BLOQUEAR la
    // navegación y pedir una valoración válida; NO caer al
    // crudo en silencio (hoy el fallback a _precioOficial vive
    // en la venta simple y en el texto de referencia, y ahí se
    // queda: este camino es el único que cambia).
    final oficialConvertido = _oficialEnMoneda;
    if (oficialConvertido == null) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa la valoración',
          mensaje: 'No se pudo convertir el precio oficial a '
              '$_moneda sin una tasa válida. Revisa la tasa del '
              'día antes de inscribir.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    final ok = await Navigator.push<bool>(
      context,
      RutaIron(
        builder: (_) => VentaSuplementoInscripcionScreen(
          suplemento: widget.suplemento,
          cantidad: _cantidad,
          precio: precio,
          moneda: _moneda,
          usdTasa: _tasaUsd,
          precioOficial: oficialConvertido,
          notaPrecio:
              difiere && notaPrecio.isNotEmpty ? notaPrecio : null,
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
                _miniFotoVenta(),
                const SizedBox(width: AppEspacio.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text('${widget.suplemento['nombre']}',
                          style: AppTexto.subtitulo),
                      Text(
                          'Oficial: ${_precioOficial.toStringAsFixed(2)} '
                          '$_monedaSuplemento · $stock disp.',
                          style: AppTexto.secundario),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppEspacio.md),
          const EncabezadoSeccion(titulo: 'Cantidad y cobro'),
          _stepperCantidad(stock),
          const SizedBox(height: AppEspacio.sm),
          // v1.3.4 (B3-Invariante): referencia fija del oficial, siempre
          // visible. El campo propone el oficial; jamás ultimo_precio.
          Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: Text(
              // Lote 1 Argón: sin conversión, el oficial se muestra en
              // SU moneda (antes se mostraba el crudo etiquetado con
              // la moneda de la venta).
              'Precio oficial: ${(_oficialEnMoneda ?? _precioOficial).toStringAsFixed(2)} ${_oficialEnMoneda != null ? _moneda : _monedaSuplemento}',
              style: AppTexto.secundario,
            ),
          ),
          CampoTexto(
            controller: _precio,
            etiqueta: 'Precio por unidad',
            teclado: const TextInputType.numberWithOptions(
                decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          if (_precioDifiere) _alertaPrecio(),
          // v1.3.4 (candado b): motivo del precio distinto. Obligatorio
          // (mín. 5 caracteres) si quien vende NO es el dueño.
          if (_precioDifiere) ...[
            const SizedBox(height: AppEspacio.sm),
            const EncabezadoSeccion(titulo: 'Nota de precio'),
            CampoTexto(
              controller: _notaPrecio,
              etiqueta: _permisos.esDueno
                  ? 'Motivo (opcional para el dueño)'
                  : 'Motivo (obligatorio, mín. 5 caracteres)',
              hint: 'Ej: Autorizado por Jc por compra de 2 botes',
              icono: Icons.edit_note_rounded,
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: AppEspacio.sm),
          _chipsMoneda(),
          // v1.3.4 (pedido Jc 2026-10-16): en USD no se muestra el
          // equivalente en CUP ni el campo de tasa — solo tienen sentido
          // si la moneda es CUP.
          if (_moneda == 'CUP') ...[
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _tasa,
              etiqueta: 'Tasa (CUP por 1 USD) — obligatoria',
              teclado: const TextInputType.numberWithOptions(
                  decimal: true),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Comprador'),
          _selectorComprador(),
          const SizedBox(height: AppEspacio.xs),
          Row(
            children: [
              Icon(Icons.person_rounded,
                  size: 18,
                  color: AppColores.textoSecundario(context)),
              const SizedBox(width: AppEspacio.xs),
              Expanded(
                child: Text(_resumenComprador,
                    style: AppTexto.secundario
                        .copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          // v1.3.7 (Fase B §6.2): fiado solo con cliente del gym.
          // 1.15 V1: y solo en CUP (en USD el switch ni se muestra
          // y _cambiarMoneda ya apagó el fiado al pasar a USD).
          if (mostrarSwitchFiadoVenta(
              tipoComprador: _tipoComprador, moneda: _moneda)) ...[
            const SizedBox(height: AppEspacio.sm),
            SwitchListTile(
              value: _esFiado,
              activeThumbColor: AppColores.naranja,
              title: const Text('Vender a fiado',
                  style: AppTexto.cuerpo),
              subtitle: const Text(
                  'Se cobra después; no suma a la caja de hoy',
                  style: AppTexto.secundario),
              onChanged: (v) =>
                  setState(() => _esFiado = v),
            ),
            if (_esFiado)
              Padding(
                padding:
                    const EdgeInsets.only(top: AppEspacio.xs),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 16, color: AppColores.alerta),
                    const SizedBox(width: AppEspacio.xs),
                    Expanded(
                      child: Text(
                          'Quedará registrada como deuda del cliente',
                          style: AppTexto.secundario.copyWith(
                              color: AppColores.alerta,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
          ],
          // v1.2.1: nota opcional de la venta.
          const SizedBox(height: AppEspacio.sm),
          const EncabezadoSeccion(titulo: 'Nota (opcional)'),
          CampoTexto(
            controller: _nota,
            hint: 'Ej: apartado…',
            icono: Icons.sticky_note_2_rounded,
          ),
          const SizedBox(height: AppEspacio.sm),
        ],
      ),
      // Rediseño 1.20: barra fija con el TOTAL siempre visible
      // (en cualquier moneda; antes solo salía en CUP) y la
      // confirmación con las mismas condiciones de habilitado.
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
              AppEspacio.sm, AppEspacio.lg, AppEspacio.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total',
                        style: AppTexto.minuscula.copyWith(
                            color: AppColores.textoSecundario(
                                context))),
                    Text(
                      textoTotalVenta(_total, _moneda,
                          _moneda == 'CUP' ? _tasaUsd : null),
                      style: AppTexto.subtitulo.copyWith(
                        fontWeight: FontWeight.bold,
                        fontFeatures: const [
                          FontFeature.tabularFigures()
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppEspacio.md),
              BotonPrimario(
                texto:
                    _guardando ? 'Registrando…' : 'Confirmar venta',
                expandido: false,
                // Argón P1#2-parte: deshabilitado sin stock o si
                // la cantidad supera el stock (el pre-chequeo en
                // _confirmar cubre el mismo caso si el stock
                // cambia en caliente).
                onPressed: (_guardando ||
                        stock < 1 ||
                        _cantidad > stock)
                    ? null
                    : _confirmar,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Rediseño 1.20: resumen visible del comprador elegido
  /// («Comprador: María Pérez» / «Externo — Carlos» /
  /// «Cliente externo»), para no venderle a la persona
  /// equivocada por no revisar el selector.
  String get _resumenComprador {
    switch (_tipoComprador) {
      case 'cliente':
        return _clienteId == null
            ? 'Comprador: sin seleccionar'
            : 'Comprador: $_clienteNombre';
      case 'externo_nombre':
        final n = _compradorNombre.text.trim();
        return n.isEmpty
            ? 'Comprador: externo (sin nombre aún)'
            : 'Comprador: Externo — $n';
      case 'inscribir_nuevo':
        return 'Comprador: se inscribe como cliente nuevo';
      default:
        return 'Comprador: Cliente externo';
    }
  }

  /// Rediseño 1.20: miniatura del producto en la cabecera —
  /// mismo triestado que la lista (local → caché →
  /// placeholder), a 56 px.
  Widget _miniFotoVenta() {
    final sup = widget.suplemento;
    final fotoLocal = sup['foto_local'] as String?;
    final fotoStorage = sup['foto_storage'] as String?;
    Widget placeholder() => Container(
          width: 56,
          height: 56,
          color: AppColores.fondo(context),
          child: Icon(Icons.medication_rounded,
              color: AppColores.textoSecundario(context)),
        );
    return SizedBox(
      width: 56,
      height: 56,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadio.sm),
        child: (fotoLocal != null &&
                fotoLocal.isNotEmpty &&
                File(fotoLocal).existsSync())
            ? Image.file(File(fotoLocal),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder())
            : FutureBuilder(
                future: FotoCache.instance.obtener(fotoStorage),
                builder: (ctx, snap) {
                  final f = snap.data;
                  if (f == null) return placeholder();
                  return Image.file(f, fit: BoxFit.cover);
                },
              ),
      ),
    );
  }

  Widget _stepperCantidad(int stock) {
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon:
                    const Icon(Icons.remove_circle_outline_rounded),
                onPressed: _cantidad > 1
                    ? () => setState(() => _cantidad--)
                    : null,
              ),
              Text('$_cantidad',
                  style: AppTexto.displayPequeno),
              IconButton(
                icon: const Icon(Icons.add_circle_outline_rounded),
                onPressed: _cantidad < stock
                    ? () => setState(() => _cantidad++)
                    : null,
              ),
            ],
          ),
          Text(
            'Quedan ${stock - _cantidad} unidades tras esta venta',
            style: AppTexto.minuscula.copyWith(
                color: AppColores.textoSecundario(context)),
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
            const Icon(Icons.warning_amber_rounded,
                color: AppColores.alerta),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Text(
                // Lote 1 Argón: el oficial convertido a la moneda de la
                // venta (antes mostraba el crudo con la moneda fija
                // del suplemento).
                'Vas a vender a un precio distinto al oficial '
                '(${(_oficialEnMoneda ?? _precioOficial).toStringAsFixed(2)} $_moneda). '
                'Quedarán registrados ambos precios para auditoría.',
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
                    icon: Icon(Icons.person_search_rounded,
                        color: AppColores.textoSecundario(context)),
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
                icono: Icons.person_outline_rounded,
                onChanged: (_) => setState(() {}),
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
          RadioListTile<String>(
            value: 'inscribir_nuevo',
            activeColor: AppColores.naranja,
            title: Text('Inscribir como cliente nuevo',
                style: AppTexto.cuerpo),
            subtitle: Text(
                'Inscribe al comprador y registra la venta en una sola operación',
                style: AppTexto.secundario),
            secondary: Icon(Icons.person_add_rounded,
                color: AppColores.textoSecundario(context)),
          ),
        ],
      ),
    );
  }
}

/// v1.3.7: diálogo de selección de cliente con búsqueda.
/// Pedido de Jc: no solo el listado fijo, poder buscar por nombre.
class _DialogoBuscarCliente extends StatefulWidget {
  final List<Map<String, dynamic>> clientes;
  const _DialogoBuscarCliente({required this.clientes});

  @override
  State<_DialogoBuscarCliente> createState() => _DialogoBuscarClienteState();
}

class _DialogoBuscarClienteState extends State<_DialogoBuscarCliente> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _ctrl.text.trim().toLowerCase();
    final filtrados = q.isEmpty
        ? widget.clientes
        : widget.clientes.where((c) {
            final n = '${c['nombre'] ?? ''}'.toLowerCase();
            return n.contains(q);
          }).toList();
    return DialogoApp(
      titulo: 'Cliente del gym',
      iconoTitulo: Icons.person_search_rounded,
      contenido: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Buscar por nombre…',
                prefixIcon: Icon(Icons.search_rounded),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtrados.isEmpty
                  ? const Center(child: Text('Sin resultados'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtrados.length,
                      itemBuilder: (_, i) {
                        final c = filtrados[i];
                        // Cliente protegido (2026-10-26, A3):
                        // candado junto al nombre y la selección se
                        // intercepta en el acto (el diálogo queda
                        // abierto); el servidor rechazaría la venta
                        // de todos modos.
                        return ListTile(
                          title: Text('${c['nombre'] ?? ''}'),
                          trailing: esVistaProtegida(c)
                              ? const Icon(Icons.lock_rounded,
                                  color: AppColores.naranja)
                              : null,
                          onTap: () {
                            if (esVistaProtegida(c)) {
                              mostrarSnack(context, mensajeClienteProtegido, significado: SignificadoChip.alerta);
                              return;
                            }
                            Navigator.pop(context, c);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
