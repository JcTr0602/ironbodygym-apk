/// Pantalla de confirmación de cobro a pantalla completa.
/// Muestra check grande, nombre del cliente, monto y nuevo vencimiento.
library;

import 'package:flutter/material.dart';

class ConfirmacionCobroScreen extends StatelessWidget {
  final String nombreCliente;
  final String monto;
  final String nuevoVencimiento;
  final String? fotoUrl;

  const ConfirmacionCobroScreen({
    super.key,
    required this.nombreCliente,
    required this.monto,
    required this.nuevoVencimiento,
    this.fotoUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Check grande animado
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle,
                size: 80,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              '¡Cobro registrado!',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            // Datos del cobro
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _fila('👤 Cliente', nombreCliente),
                    const Divider(),
                    _fila('💰 Monto', monto),
                    const Divider(),
                    _fila('📅 Nuevo vencimiento', nuevoVencimiento),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 48),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 48, vertical: 16),
              ),
              child: const Text(
                'Entendido',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fila(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: const TextStyle(color: Colors.grey)),
          Flexible(
            child: Text(
              valor,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
