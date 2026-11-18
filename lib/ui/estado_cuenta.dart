/// T24 (1.20): estado de cuenta del cliente — un resumen
/// único con vigencia, pagos, compras y deuda, listo para
/// copiar o enviar por WhatsApp. No incluye notas internas
/// ni datos de gestión: es el papel que el cliente puede
/// ver. Todo sale de los espejos locales (y del residuo
/// Plus, consultado por todo el staff como en la ficha).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../plus_residual.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class EstadoCuentaScreen extends StatefulWidget {
  final int clienteId;
  const EstadoCuentaScreen({super.key, required this.clienteId});

  @override
  State<EstadoCuentaScreen> createState() =>
      _EstadoCuentaScreenState();
}

class _EstadoCuentaScreenState extends State<EstadoCuentaScreen> {
  bool _cargando = true;
  bool _protegido = false;
  Map<String, dynamic>? _cliente;
  String _texto = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String? _falloCarga;

  Future<void> _cargar() async {
    // 1.36 H-C3 (136-1036, GF-072): un fallo de las lecturas
    // locales ya no deja el spinner eterno: se dice con
    // EstadoError y Reintentar.
    try {
      await _cargarDatos();
    } catch (e) {
      AppLog.error('ui', 'estado_cuenta_carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _falloCarga = mensajeErrorAmable(e);
          _cargando = false;
        });
      }
    }
  }

  Future<void> _cargarDatos() async {
    final filas = await LocalDb.instance
        .mirrorPorIds('clientes', [widget.clienteId]);
    if (filas.isEmpty) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    final cliente = filas.first;
    // §7 autoauditoría 1.20: la pantalla se defiende sola. La
    // ficha protegida ya no ofrece el botón, pero si se llega
    // aquí con un cliente protegido y sesión de entrenador, no
    // se compone ningún texto (ni se leen sus movimientos).
    if (esVistaProtegida(cliente)) {
      if (mounted) {
        setState(() {
          _protegido = true;
          _cargando = false;
        });
      }
      return;
    }
    final pagos = await LocalDb.instance
        .mirrorFiltrado('pagos', {'cliente_id': widget.clienteId});
    final ventas = (await LocalDb.instance
            .allMirror('ventas_suplementos'))
        .where((v) =>
            ((v['cliente_id'] as num?)?.toInt() ??
                (v['fiado_cliente_id'] as num?)?.toInt()) ==
            widget.clienteId)
        .toList();
    // Yunque R4-M10-3: servicios por la vía FILTRADA por
    // cliente_id (columna indexada v61), no el espejo
    // completo decodificado para un solo cliente — el
    // predicado es el mismo (cliente_id de la fila).
    // Las ventas de suplementos NO se mueven: su
    // predicado incluye fiado_cliente_id como clave
    // alternativa del deudor y ventasSuplementosPorFiltro
    // no lo reproduce (quedan especificadas en la ronda).
    final servicios = await LocalDb.instance
        .servicioVentasPorFiltro(clienteId: widget.clienteId);
    final fiado = await LocalDb.instance
        .fiadoPendienteDeCliente(widget.clienteId);
    // Yunque R3-M6-2: PRIMER PINTADO con lo local ya
    // computado y el Plus «sin verificar». Antes el primer
    // setState esperaba la RPC del Plus: sin red, la
    // pantalla giraba hasta 12 s con el estado de cuenta
    // entero listo en el teléfono (la clase de la ficha
    // del 2026-11-02). Ahora se pinta ya y la RPC de abajo
    // enriquece en segundo plano recomponiendo el texto.
    if (!mounted) return;
    setState(() {
      _cliente = cliente;
      _texto = textoEstadoCuenta(
        cliente: cliente,
        pagos: pagos,
        ventas: ventas,
        servicios: servicios,
        fiadoPendiente: fiado,
        plusResidualTexto:
            AuthService().session != null ? 'sin verificar' : null,
        hoyIso: hoyHabanaIso(),
      );
      _cargando = false;
    });
    // Residuo Plus (plu06_ H5a): todo el staff autenticado
    // obtiene dato real de la RPC — su guarda es
    // es_staff() desde IMP-14 — con el mismo fail-closed
    // que en la ficha («sin verificar» ante el fallo).
    String? plusTxt;
    if (AuthService().session != null) {
      try {
        // Autoauditoría 1.22 #2: con timeout (12 s). Todo lo
        // demás de esta pantalla sale del espejo LOCAL y ya está
        // computado, pero el primer setState esperaba esta RPC:
        // con la conexión colgada, spinner eterno con el estado
        // de cuenta listo en el teléfono (la clase del Dashboard
        // 1C). Con el corte, el catch la omite y se pinta sin la
        // línea Plus, como ya estaba previsto.
        final res = await Supabase.instance.client
            .rpc(
              'cliente_plus_residual_staff',
              params: {'p_cliente_id': widget.clienteId},
            )
            .timeout(const Duration(seconds: 12));
        // Yunque B (YB-FLU-04): una respuesta null SIN lanzar
        // tampoco es «sin Plus»: es «no se pudo verificar»,
        // como ya distingue la ficha (R1M4-B7).
        if (res == null) {
          plusTxt = 'sin verificar';
        } else {
          final r = plusResidualDe(res);
          plusTxt = textoPlusResidual(
              activo: r.activo, hasta: r.hasta, hoyIso: hoyHabanaIso());
        }
      } catch (_) {
        // Yunque B (YB-FLU-04): el fallo de la RPC ya no omite
        // la línea en silencio: el texto que sale por WhatsApp
        // dice «Plus: sin verificar», el mismo criterio que la
        // ficha («Sin verificar en esta visita»). Omitirla
        // dejaba al cliente con un estado de cuenta que parece
        // completo y no lo es.
        plusTxt = 'sin verificar';
      }
    }
    final texto = textoEstadoCuenta(
      cliente: cliente,
      pagos: pagos,
      ventas: ventas,
      servicios: servicios,
      fiadoPendiente: fiado,
      plusResidualTexto: plusTxt,
      hoyIso: hoyHabanaIso(),
    );
    if (!mounted) return;
    setState(() {
      _cliente = cliente;
      _texto = texto;
      _cargando = false;
    });
  }

  Future<void> _enviarWhatsapp() async {
    final tel =
        normalizarTelefonoWaMe('${_cliente?['telefono'] ?? ''}');
    if (tel.isEmpty) {
      mostrarSnack(
          context, 'Este cliente no tiene teléfono registrado.',
          significado: SignificadoChip.alerta);
      return;
    }
    final ok = await launchUrl(
      Uri.parse(
          'https://wa.me/$tel?text=${Uri.encodeComponent(_texto)}'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      mostrarSnack(context, 'No se pudo abrir WhatsApp',
          significado: SignificadoChip.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Estado de cuenta'),
      body: _cargando
          ? const EstadoCargando()
          : _falloCarga != null && _cliente == null
              ? EstadoError(
                  titulo: 'No se pudo cargar el estado de cuenta',
                  detalle: _falloCarga,
                  onReintentar: () {
                    setState(() {
                      _falloCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
              : _protegido
              ? const EstadoVacio(
                  icono: Icons.lock_rounded,
                  titulo: 'Cliente protegido',
                  subtitulo:
                      'Su estado de cuenta no está disponible '
                      'para tu usuario.',
                )
              : _cliente == null
              ? const EstadoVacio(
                  icono: Icons.person_off_rounded,
                  titulo: 'Cliente no encontrado',
                  subtitulo:
                      'Este cliente ya no está en el teléfono.',
                )
              : ListView(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    Tarjeta(
                      child: SelectableText(_texto,
                          style: AppTexto.cuerpo),
                    ),
                    const SizedBox(height: AppEspacio.lg),
                    BotonPrimario(
                      texto: 'Enviar por WhatsApp',
                      icono: Icons.chat_rounded,
                      onPressed: _enviarWhatsapp,
                    ),
                    const SizedBox(height: AppEspacio.sm),
                    BotonSecundario(
                      texto: 'Copiar texto',
                      icono: Icons.copy_rounded,
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: _texto));
                        if (context.mounted) {
                          mostrarSnack(context,
                              'Estado de cuenta copiado',
                              significado: SignificadoChip.exito);
                        }
                      },
                    ),
                  ],
                ),
    );
  }
}
