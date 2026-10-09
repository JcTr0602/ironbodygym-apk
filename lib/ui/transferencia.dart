/// Datos de transferencia (solo lectura, con copiar).
library;

import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💳 Datos de transferencia')),
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
                _tarjeta(context, '💳 Bandec', _bandec),
                _tarjeta(context, '💳 BPA', _bpa),
                _tarjeta(context, '📱 Móvil para confirmar', _movil),
                const Divider(),
                Text(
                    '💰 Mensualidad por transferencia: ${fmtMonto(_transfer)} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
                Text('(En efectivo: ${fmtMonto(_efectivo)} CUP)'),
                const SizedBox(height: 12),
                const Text(
                  '⚠️ IMPORTANTE: tienes que habilitar la opción para que '
                  'se vea el móvil del cual hiciste la transferencia. Así '
                  'verificamos tu pago y activamos tu mensualidad.',
                ),
                const SizedBox(height: 12),
                const Text('✈️ Telegram: ${AppConfig.telegramContacto}'),
                const Text('💬 WhatsApp: ${AppConfig.whatsappContacto}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tarjeta(BuildContext context, String etiqueta, String valor) {
    return Card(
      child: ListTile(
        title: Text(etiqueta),
        subtitle: Text(valor,
            style: const TextStyle(
                fontSize: 18, fontFamily: 'monospace')),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          onPressed: () => copiar(context, valor.replaceAll(' ', '')),
        ),
      ),
    );
  }
}
