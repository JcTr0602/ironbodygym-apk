/// T24 (1.20): estado de cuenta del cliente — un resumen
/// único con vigencia, pagos, compras y deuda, listo para
/// copiar o enviar por WhatsApp. No incluye notas internas
/// ni datos de gestión: es el papel que el cliente puede
/// ver. Todo sale de los espejos locales (y del residuo
/// Plus, solo dueño, como en la ficha).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../plus_residual.dart';
import '../tiempo.dart';
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

  Future<void> _cargar() async {
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
    final servicios = (await LocalDb.instance
            .allMirror('servicio_ventas'))
        .where((s) =>
            (s['cliente_id'] as num?)?.toInt() == widget.clienteId)
        .toList();
    final fiado = await LocalDb.instance
        .fiadoPendienteDeCliente(widget.clienteId);
    // Residuo Plus: solo el dueño obtiene dato real de la
    // RPC (fail-closed, igual que en la ficha).
    String? plusTxt;
    if (AuthService().isOwner) {
      try {
        final res = await Supabase.instance.client.rpc(
          'cliente_plus_residual_staff',
          params: {'p_cliente_id': widget.clienteId},
        );
        final r = plusResidualDe(res);
        plusTxt = textoPlusResidual(
            activo: r.activo, hasta: r.hasta, hoyIso: hoyHabanaIso());
      } catch (_) {}
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
      appBar: AppBar(title: const Text('Estado de cuenta')),
      body: _cargando
          ? const EstadoCargando()
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
