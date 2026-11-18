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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../fotos.dart';
import '../negocio.dart';
import '../localdb.dart';
import '../permisos_entrenador.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'permisos_ui.dart';
import 'widgets.dart';
import '../errores_sync.dart';
import '../app_log.dart';

/// Construye el payload de la op 'inscripcion_venta_suplemento'.
///
/// Función pura (testeable sin montar la pantalla): el método de pago
/// del tope ('metodo_pago') es SOLO de la inscripción. El suplemento
/// se cobra aparte (D-04, cierre 1.23, decisión de Jc 2026-11-04):
/// la venta NO hereda ese método — el servidor usa el método propio
/// del sub-payload 'venta' si algún día trae 'metodo' explícito, y
/// si no, 'efectivo' (cobro de mostrador). Por eso este constructor
/// no pone 'metodo' en 'venta'.
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
  // Lote 3 (BLOQUEANTE): USD sin tasa válida no se puede encolar
  // (antes se omitía usd_tasa en silencio y la venta quedaba en USD
  // sin conversión, igual que el bloqueo de la venta simple del
  // lote 1). La pantalla además avisa antes de confirmar.
  // Luna lote-3 MEDIO: NaN e infinito pasaban `<= 0` (NaN no es
  // menor ni mayor que 0; infinito tampoco es <= 0). Se exige
  // finito explícito.
  if (moneda == 'USD' &&
      (usdTasa == null || !usdTasa.isFinite || usdTasa <= 0)) {
    throw ArgumentError(
        'Venta en USD sin tasa válida (usdTasa requerido)');
  }
  // Yunque B (YB-CLI-09/10): FRONTERA del payload — lo que
  // viaja a clientes.telefono/carnet va limpio pase lo que
  // pase en la pantalla: el teléfono sanitizado a sus 8
  // dígitos (si no sanitiza a un móvil válido, se omite
  // antes que guardarlo sucio) y el carnet solo dígitos.
  // La pantalla valida antes de llegar aquí; esto es la red
  // que hace imposible el dato sucio en esta op.
  final telLimpio =
      telefono == null ? null : sanitizarTelefono(telefono);
  final carnetLimpio =
      carnet?.replaceAll(RegExp(r'[^0-9]'), '');
  return {
    'cliente': {
      'nombre': nombre,
      if (telLimpio != null && telLimpio.isNotEmpty)
        'telefono': telLimpio,
      if (sexo != null) 'sexo': sexo,
      if (carnetLimpio != null && carnetLimpio.isNotEmpty) 'carnet': carnetLimpio,
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
  // Fase A 1.9: método de pago real de la inscripción. Antes no se
  // elegía ni se enviaba y el servidor caía en 'efectivo' por
  // omisión, descuadrando la caja al pagar por transferencia. El
  // servidor ya acepta 'metodo_pago' (B2).
  // D-04 (cierre 1.23): es SOLO de la inscripción — el suplemento
  // se cobra aparte, en efectivo (ver el constructor del payload).
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
          // Yunque 3 (K6-3): lector tolerante de flags A2-D2.
          _promoActiva = flagAjusteTolerante(aj['promo_suplementos']);
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
    // Pieza añadida de la oleada (hermana de YB-SER-01): la
    // op compuesta inscripcion_venta_suplemento exige en el
    // servidor inscribir Y VENDER; la entrada de Inscribir
    // solo comprueba el permiso de inscribir. Sin esta
    // segunda guarda, un entrenador con inscribir pero sin
    // vender suplementos completaba el flujo, veía éxito y
    // el servidor rebotaba la op ENTERA (ni cliente ni
    // venta). Guarda dentro del flujo, antes de cualquier
    // diálogo, como en ventaRapidaSuplemento.
    if (!await permisoOperativoOkConRefresco(context,
        () => PermisosEntrenador().canVenderSuplementos,
        'vender suplementos')) {
      return;
    }
    if (!mounted) return;
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      await DialogoApp.confirmar(context,
          titulo: 'Falta el nombre',
          mensaje: 'Escribe el nombre del nuevo cliente.',
          aceptar: 'Entendido',
          cancelar: null);
      return;
    }
    final carnet = _carnet.text.trim();
    // Argón Clientes #1: el carnet sigue la regla ÚNICA de la
    // app (validarCarnet: 6 a 11 dígitos), no «exactamente 6»
    // como decía aquí — la ficha y el alta aceptan hasta 11.
    if (carnet.isNotEmpty && !validarCarnet(carnet)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el carnet',
          mensaje: 'El carnet debe tener de 6 a 11 dígitos '
              '(o déjalo vacío).',
          aceptar: 'Entendido',
          cancelar: null);
      return;
    }
    // Argón Clientes #1: teléfono con formato válido (el alta
    // normal SÍ lo exige) y chequeo de DUPLICADOS antes de
    // tocar el stock: sin esto, un comprador ya inscrito (o un
    // teléfono de 7 dígitos) creaba un cliente duplicado o la
    // op rebotaba en el servidor con el stock ya descontado
    // en el teléfono.
    // Yunque 2.34 (D-5): se valida el teléfono SANITIZADO
    // (la regla de la casa, como en Inscribir): teclear o
    // pegar «5358191577» es el mismo número que «58191577»
    // con prefijo, y la validación sobre el crudo lo
    // rechazaba. El payload de más abajo ya sanitizaba; la
    // validación y el chequeo de duplicados quedaban con el
    // valor sin limpiar.
    final telCrudo = _telefono.text.trim();
    final tel =
        telCrudo.isEmpty ? '' : (sanitizarTelefono(telCrudo) ?? '');
    if (telCrudo.isNotEmpty && !validarTelefono(tel)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa el teléfono',
          mensaje: 'El teléfono debe tener 8 dígitos empezando '
              'con 5 o 6 (o déjalo vacío).',
          aceptar: 'Entendido',
          cancelar: null);
      return;
    }
    final dups = await posiblesDuplicados(
        nombre: nombre,
        carnet: carnet.isEmpty ? null : carnet,
        telefono: tel.isEmpty ? null : tel,
        incluirNoActivos: true);
    if (!mounted) return;
    final carnetDigitos = carnet.replaceAll(RegExp(r'[^0-9]'), '');
    final carnetDuplicado = carnetDigitos.length == 11 &&
        dups.any((d) => d['_motivo'] == 'mismo carnet');
    if (carnetDuplicado) {
      final dueno = dups.firstWhere(
          (d) => d['_motivo'] == 'mismo carnet');
      await DialogoApp.confirmar(context,
          titulo: 'Carnet duplicado',
          mensaje: 'El carnet $carnet ya pertenece a '
              '"${dueno['nombre']}"${coletillaEstadoDuplicado(dueno)}. '
              'Cada carnet corresponde a '
              'un solo cliente: no se puede inscribir de nuevo.',
          aceptar: 'Entendido',
          cancelar: null);
      return;
    }
    if (dups.isNotEmpty) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Posible duplicado',
          iconoTitulo: Icons.person_search_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ya existe(n) cliente(s) parecido(s):'),
              const SizedBox(height: 8),
              for (final d in dups)
                Text('• ${d['nombre']} (${d['_motivo']}'
                    '${coletillaEstadoDuplicado(d)})'),
              const SizedBox(height: 8),
              const Text('¿Seguro que es un cliente nuevo?'),
            ],
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Revisar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  // 1.36 H-B3 (136-717): sobre el naranja
                  // manda el token de la casa, no Colors.white.
                  foregroundColor: AppColores.sobreMarca,
                ),
                child: const Text('Sí, es nuevo')),
          ],
        ),
      );
      if (seguir != true) return;
    }

    // Lote 3 (BLOQUEANTE, espejo del bloqueo USD de la venta simple):
    // sin tasa válida no se puede confirmar una venta en USD.
    // Luna lote-3 MEDIO: NaN e infinito también pasan `<= 0`.
    if (widget.moneda == 'USD' &&
        (widget.usdTasa == null ||
            !widget.usdTasa!.isFinite ||
            widget.usdTasa! <= 0)) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa la valoración',
          mensaje: 'Esta venta es en USD pero no hay una tasa válida. '
              'Vuelve a la pantalla anterior y revisa la valoración '
              'antes de inscribir.',
          aceptar: 'Entendido',
          cancelar: null);
      return;
    }

    // Argón P1#2-parte: pre-chequeo de stock antes del diálogo de
    // confirmación (la transacción ya lo valida, pero tarde).
    if (widget.cantidad < 1) {
      await DialogoApp.confirmar(context,
          titulo: 'Stock insuficiente',
          mensaje: 'Indica una cantidad mayor que 0.',
          aceptar: 'Entendido',
          cancelar: null);
      return;
    }
    {
      final sidPre =
          (widget.suplemento['id'] as num?)?.toInt();
      if (sidPre != null) {
        final dbPre = await LocalDb.instance.db;
        final rowsPre = await dbPre.query('suplementos',
            columns: ['data'], where: 'id = ?', whereArgs: [sidPre]);
        // 1.36 H-B3 (136-716): tras el await del pre-chequeo
        // se comprueba mounted antes de abrir el diálogo
        // siguiente (el contexto puede estar desmontado).
        if (!mounted) return;
        if (rowsPre.isNotEmpty) {
          final dataPre = jsonDecode(rowsPre.first['data'] as String)
              as Map<String, dynamic>;
          final stockPre = (dataPre['stock'] as num?)?.toInt() ?? 0;
          if (widget.cantidad > stockPre) {
            await DialogoApp.confirmar(context,
                titulo: 'Stock insuficiente',
                mensaje:
                    'Solo quedan $stockPre en stock.',
                aceptar: 'Entendido',
                cancelar: null);
            return;
          }
        }
      }
    }

    final totalTxt = textoTotalVenta(_total, widget.moneda, widget.usdTasa);
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar inscripción + venta',
      icono: Icons.person_add_rounded,
      mensaje: 'Cliente: $nombre\n'
          'Método de la inscripción: '
          '${_metodo == 'efectivo' ? 'Efectivo' : 'Transferencia'}\n'
          'Venta: ${widget.suplemento['nombre']} x${widget.cantidad}'
          ' = $totalTxt\n'
          'El suplemento se cobra aparte, en efectivo.'
          '${_promoActiva ? '\n\nSe le asignará 1 mes de mensualidad gratis (promo activa).' : ''}',
      aceptar: 'Confirmar',
    );
    if (!ok) return;

    setState(() => _guardando = true);
    try {
      final opUuid = const Uuid().v4();
      // v1.4.0 (Argón §8): fecha de negocio en hora de La Habana.
      final hoy = hoyHabanaIso();
      // Yunque B (YB-CLI-09/10): lo que se GUARDA va limpio —
      // la validación limpia solo para comprobar y el payload
      // recibía el texto crudo («5819 1577» nacía sucio en
      // clientes.telefono, contra la regla de la casa). El
      // teléfono se sanitiza a sus 8 dígitos y el carnet a
      // dígitos, como en Inscribir y en la ficha.
      // 1.36 H-B3 (136-718): el payload lleva el teléfono YA
      // validado arriba (`tel`, sanitizado y comprobado),
      // no una re-sanitización del texto crudo del campo.
      final telefono = tel;
      final carnetLimpio = carnet.replaceAll(RegExp(r'[^0-9]'), '');
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
              carnet: carnetLimpio,
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
          AppLog.error('venta_suplemento_inscripcion', 'registrar_fallo', d: '$e');
          mostrarSnack(context, 'No se registró: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
        }
        return;
      }
      // Lote 3 (MEDIO): sin conexión (o antes del pull) el cliente
      // recién inscrito aún no existe en el espejo local: no aparece
      // en la lista ni en Control de Acceso hasta sincronizar. Se
      // avisa antes de salir, en vez de dejarlo descubrirlo.
      // 1.36 H-B3 (136-718): el aviso va ANTES de lanzar el push
      // (antes el push salía primero y el aviso de «en cola»
      // llegaba cuando el envío ya estaba en marcha: el texto
      // ahora describe el estado real al confirmarse — encolado
      // y pendiente de sincronizar).
      if (mounted) {
        await DialogoApp.confirmar(context,
            titulo: 'Inscripción en cola',
            mensaje: 'Cliente, mes gratis y venta quedaron encolados. '
                'El cliente aparecerá en la lista de clientes, en '
                'Control de Acceso y en la gaveta del turno cuando el '
                'teléfono sincronice.',
            aceptar: 'Entendido',
            cancelar: null);
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
      appBar: appBarIron(context, 'Nuevo cliente y venta de suplemento'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
          // Rediseño 1.20 (§D, solo presentación): la banda
          // del producto va PRIMERA — qué se vende y por
          // cuánto se ve mientras se rellena el formulario.
          const EncabezadoSeccion(
              titulo: 'Venta del suplemento'),
          Tarjeta(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1.25 T120 (F4-19): la banda lleva la foto del
                // producto, como en el resto de pantallas de
                // venta (antes era solo texto).
                _FotoBandaVenta(sup: widget.suplemento),
                const SizedBox(width: AppEspacio.md),
                Expanded(
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
              ],
            ),
          ),
          const EncabezadoSeccion(
              titulo: 'Datos del cliente'),
          CampoTexto(
            controller: _nombre,
            etiqueta: 'Nombre completo *',
            icono: Icons.person_outline_rounded,
          ),
          const SizedBox(height: AppEspacio.sm),
          CampoTexto(
            controller: _telefono,
            etiqueta: 'Teléfono (opcional)',
            icono: Icons.phone_rounded,
            teclado: TextInputType.phone,
          ),
          const SizedBox(height: AppEspacio.sm),
          // SL-6 (G05-12): el sexo se elige con el
          // SelectorIron de la casa (antes, ChoiceChip a
          // pelo solo en esta pantalla).
          SelectorIron<String?>(
            valor: _sexo,
            etiqueta: 'Sexo',
            pista: 'Sin especificar',
            tituloPanel: 'Sexo',
            opciones: const [
              OpcionSelector<String?>(null, 'Sin especificar'),
              OpcionSelector<String?>('M', 'Masculino'),
              OpcionSelector<String?>('F', 'Femenino'),
            ],
            alCambiar: (v) => setState(() => _sexo = v),
          ),
          const SizedBox(height: AppEspacio.sm),
          CampoTexto(
            controller: _carnet,
            // 1.25 T120 (F4-05): la etiqueta prometía «6
            // dígitos» pero la validación acepta de 6 a 11
            // (los invitados traen 11): quien inscribía a un
            // invitado creía que su carnet no servía.
            etiqueta: 'Carnet (6 a 11 dígitos, opcional)',
            icono: Icons.badge_rounded,
            teclado: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          // v1.5.0 (Bloque G): aviso de fecha imposible (no bloquea).
          if (carnetFechaInvalida(_carnet.text))
            const AvisoFechaCarnet(),
          const EncabezadoSeccion(
              titulo: 'Método de pago'),
          const Text(
              'La inscripción se paga con este método; el suplemento '
              'se cobra aparte, en efectivo.',
              style: AppTexto.secundario),
          const SizedBox(height: 4),
          // SL-6 (G05-12): el método, también con
          // SelectorIron de la casa.
          SelectorIron<String>(
            valor: _metodo,
            etiqueta: 'Método de pago',
            tituloPanel: 'Método de pago',
            opciones: const [
              OpcionSelector<String>('efectivo', 'Efectivo'),
              OpcionSelector<String>(
                  'transferencia', 'Transferencia'),
            ],
            alCambiar: (v) {
              if (v != null) setState(() => _metodo = v);
            },
          ),
          const EncabezadoSeccion(
              titulo: 'Mensualidad inicial'),
          Tarjeta(
            child: Row(
              children: [
                Icon(Icons.payments_rounded,
                    color: AppColores.textoSecundario(context)),
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
          // 1.36 H-B3 (136-718): el banner de promo entra con
          // transición (antes aparecía de golpe tras getAjustes
          // y desplazaba el formulario). 136-717: icono y texto
          // con el token de marca sobre el tinte naranja (antes
          // textoSecundario, que no es color de marca).
          AnimatedSize(
            duration: AppMovimiento.media,
            alignment: Alignment.topCenter,
            child: !_promoActiva
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: AppEspacio.md),
                    child: Container(
                      padding: const EdgeInsets.all(AppEspacio.md),
                      decoration: BoxDecoration(
                        color: AppColores.naranja.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadio.md),
                        border: Border.all(
                            color: AppColores.naranja.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.card_giftcard_rounded,
                              color: AppColores.textoNaranja(context)),
                          const SizedBox(width: AppEspacio.sm),
                          Expanded(
                            child: Text(
                              'Se le asignará 1 mes gratis por la promo.',
                              style: AppTexto.cuerpo.copyWith(
                                  color: AppColores.textoNaranja(context)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          // 1.36 H-B3 (136-718): la tasa USD se valida EN LÍNEA
          // al pintar la pantalla, no recién al confirmar.
          if (widget.moneda == 'USD' &&
              (widget.usdTasa == null ||
                  !widget.usdTasa!.isFinite ||
                  widget.usdTasa! <= 0)) ...[
            const SizedBox(height: AppEspacio.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 20, color: AppColores.alertaTexto(context)),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                    'Venta en USD sin una tasa válida: vuelve a la '
                    'pantalla anterior y revisa la valoración antes '
                    'de inscribir.',
                    style: AppTexto.cuerpo.copyWith(
                        color: AppColores.alertaTexto(context)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      // 1.25 T120 (F4-19): el botón de confirmar va FIJO abajo,
      // como en el detalle y la venta completa — antes quedaba
      // al final del scroll y había que recorrer todo el
      // formulario para alcanzarlo.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
              AppEspacio.sm, AppEspacio.lg, AppEspacio.sm),
          child: Builder(builder: (context) {
            final stockSnap =
                (widget.suplemento['stock'] as num?)?.toInt() ?? 0;
            // 1.36 H-B3 (136-718): el botón deshabilitado por
            // stock EXPLICA el motivo junto al botón (antes se
            // apagaba en silencio).
            final motivoStock = _guardando
                ? null
                : stockSnap < 1
                    ? 'Sin stock disponible de este suplemento.'
                    : widget.cantidad > stockSnap
                        ? 'La cantidad (${widget.cantidad}) supera el '
                            'stock disponible ($stockSnap).'
                        : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (motivoStock != null) ...[
                  Text(
                    motivoStock,
                    textAlign: TextAlign.center,
                    style: AppTexto.secundario.copyWith(
                        color: AppColores.alertaTexto(context)),
                  ),
                  const SizedBox(height: AppEspacio.sm),
                ],
                BotonPrimario(
                  texto: _guardando
                      ? 'Registrando…'
                      : 'Confirmar inscripción + venta',
                  // 1.36 H-B3 (136-718): progreso visible al
                  // registrar (indicador del botón de la casa).
                  cargando: _guardando,
                  // Argón P1#2-parte: deshabilitado sin stock o si la
                  // cantidad supera el stock del snapshot (el pre-chequeo
                  // en _confirmar relee el stock vivo antes de confirmar).
                  onPressed:
                      (_guardando || motivoStock != null) ? null : _confirmar,
                ),
              ],
            );
          }),
        ),
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

/// F4-19: miniatura del producto en la banda de la venta —
/// mismo patrón de resolución que la del catálogo
/// (resolverFotoSuplemento, en fotos.dart).
class _FotoBandaVenta extends StatefulWidget {
  final Map<String, dynamic> sup;
  const _FotoBandaVenta({required this.sup});

  @override
  State<_FotoBandaVenta> createState() => _FotoBandaVentaState();
}

class _FotoBandaVentaState extends State<_FotoBandaVenta> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = resolverFotoSuplemento(widget.sup);
  }

  @override
  void didUpdateWidget(covariant _FotoBandaVenta oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sup['id'] != widget.sup['id'] ||
        oldWidget.sup['foto_local'] != widget.sup['foto_local'] ||
        oldWidget.sup['foto_storage'] != widget.sup['foto_storage']) {
      _futura = resolverFotoSuplemento(widget.sup);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        // 1.36 H-B3 (136-716): mientras carga NO se pinta
        // «sin foto» (parpadeo): hay un estado de carga propio
        // del mismo tamaño.
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 56,
            height: 56,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColores.naranja),
              ),
            ),
          );
        }
        final f = snap.data;
        if (f == null) {
          // SL-6 (G05-13): la marca de «sin foto» es la
          // única de la casa (PlaceholderSuplemento).
          return const SizedBox(
            width: 56,
            height: 56,
            child: PlaceholderSuplemento(alto: 56),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadio.md),
          child: Image(
            image: providerFotoAcotada(FileImage(f), ancho: 256),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            // 1.36 H-B3 (136-716): el error conserva el MISMO
            // tamaño 56×56 (antes el placeholder sin SizedBox
            // rompía el Row) y la imagen entra con crossfade.
            errorBuilder: (_, __, ___) => const SizedBox(
              width: 56,
              height: 56,
              child: PlaceholderSuplemento(alto: 56),
            ),
            frameBuilder: (ctx, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: AppMovimiento.corta,
                child: child,
              );
            },
          ),
        );
      },
    );
  }
}
