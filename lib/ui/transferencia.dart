/// Datos de transferencia: muestra las tarjetas y permite enviar los datos
/// por SMS o WhatsApp al móvil de un cliente (v1.1.1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'widgets.dart';

class TransferenciaScreen extends StatefulWidget {
  const TransferenciaScreen({super.key});
  @override
  State<TransferenciaScreen> createState() => _TransferenciaScreenState();
}

class _TransferenciaScreenState extends State<TransferenciaScreen> {
  double _efectivo = 2000;
  double _transfer = 2500;
  // v1.0.16: datos bancarios desde ajustes remotos (fallback a constantes)
  String _bandec = AppConfig.tarjetaBandec;
  String _bpa = AppConfig.tarjetaBpa;
  String _movil = AppConfig.movilConfirmacion;

  // v1.1.1: un campo de móvil por tarjeta para el envío
  final _movilBandec = TextEditingController();
  final _movilBpa = TextEditingController();
  final _movilConfirmar = TextEditingController();

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        final banc = AppConfig.datosBancarios(aj);
        setState(() {
          _efectivo = (aj['mensualidad'] as num?)?.toDouble() ?? 2000;
          _transfer = (aj['transferencia'] as num?)?.toDouble() ?? 2500;
          _bandec = banc['bandec']!;
          _bpa = banc['bpa']!;
          _movil = banc['movil']!;
        });
      }
    });
  }

  @override
  void dispose() {
    _movilBandec.dispose();
    _movilBpa.dispose();
    _movilConfirmar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Datos de transferencia')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                    'Puedes pagar tu mensualidad con Transfermóvil o Enzona '
                    'a cualquiera de estas tarjetas:'),
                const SizedBox(height: 16),
                _tarjeta(context, 'Bandec', _bandec, _movilBandec),
                _tarjeta(context, 'BPA', _bpa, _movilBpa),
                _tarjeta(context, 'Móvil para confirmar', _movil,
                    _movilConfirmar),
                const Divider(),
                Text(
                    'Mensualidad por transferencia: ${fmtMonto(_transfer)} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
                Text('(En efectivo: ${fmtMonto(_efectivo)} CUP)'),
                const SizedBox(height: 12),
                const Text(
                  'IMPORTANTE: tienes que habilitar la opción para que '
                  'se vea el móvil del cual hiciste la transferencia. Así '
                  'verificamos tu pago y activamos tu mensualidad.',
                ),
                const SizedBox(height: 12),
                const Text(' Telegram: ${AppConfig.telegramContacto}'),
                const Text('WhatsApp: ${AppConfig.whatsappContacto}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta con número copiable + envío por SMS/WhatsApp a un cliente.
  Widget _tarjeta(BuildContext context, String etiqueta, String valor,
      TextEditingController movilCtrl) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(etiqueta,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(valor,
                          style: const TextStyle(
                              fontSize: 18,
                              fontFamily: 'monospace')),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copiar',
                  onPressed: () =>
                      copiar(context, valor.replaceAll(' ', '')),
                ),
              ],
            ),
            const Divider(height: 20),
            const Text('Enviar a un cliente:',
                style: TextStyle(
                    fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              controller: movilCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 8,
              decoration: InputDecoration(
                hintText: 'Móvil del cliente',
                prefixIcon: const Icon(Icons.phone, size: 20),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.contacts),
                  tooltip: 'Elegir de contactos',
                  onPressed: () =>
                      _elegirContacto(context, movilCtrl),
                ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.sms, size: 18),
                    label: const Text('SMS'),
                    onPressed: () => _enviar(
                        context, etiqueta, valor,
                        movilCtrl.text, porWhatsapp: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('WhatsApp'),
                    onPressed: () => _enviar(
                        context, etiqueta, valor,
                        movilCtrl.text, porWhatsapp: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Elige un móvil cubano de los contactos del teléfono.
  Future<void> _elegirContacto(
      BuildContext ctx, TextEditingController ctrl) async {
    if (!await FlutterContacts.requestPermission(
        readonly: true)) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text(
                'Sin permiso de contactos no se puede elegir')));
      }
      return;
    }
    final contacto = await FlutterContacts.openExternalPick();
    if (contacto == null) return;
    for (final tel in contacto.phones) {
      var d = tel.number.replaceAll(RegExp(r'\D'), '');
      if (d.startsWith('53') && d.length > 8) {
        d = d.substring(2);
      }
      if (d.length == 8 && d.startsWith('5')) {
        ctrl.text = d;
        return;
      }
    }
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(
              'El contacto "${contacto.displayName}" no tiene un móvil cubano válido')));
    }
  }

  /// Abre SMS o WhatsApp con el mensaje de la tarjeta ya escrito.
  Future<void> _enviar(BuildContext ctx, String etiqueta,
      String valor, String movilRaw,
      {required bool porWhatsapp}) async {
    var movil = movilRaw.replaceAll(RegExp(r'\D'), '');
    if (movil.startsWith('53') && movil.length > 8) {
      movil = movil.substring(2);
    }
    if (movil.length != 8 || !movil.startsWith('5')) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
          content:
              Text('Escribe un móvil cubano válido (8 dígitos)')));
      return;
    }
    final mensaje = 'Iron Body Gym: paga tu mensualidad '
        '(${fmtMonto(_transfer)} CUP) por Transfermóvil/Enzona a la '
        'tarjeta $etiqueta $valor. IMPORTANTE: activa la opción para '
        'que se vea tu número y así verificamos el pago. '
        'Dudas: WhatsApp ${AppConfig.whatsappContacto}';
    final uri = porWhatsapp
        ? Uri.parse(
            'https://wa.me/53$movil?text=${Uri.encodeComponent(mensaje)}')
        : Uri.parse(
            'sms:$movil?body=${Uri.encodeComponent(mensaje)}');
    final ok = await launchUrl(uri,
        mode: LaunchMode.externalApplication);
    if (!ok && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(
              'No se pudo abrir ${porWhatsapp ? 'WhatsApp' : 'SMS'}')));
    }
  }
}
