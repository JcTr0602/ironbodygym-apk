/// Pantalla de confirmación de cobro a pantalla completa.
/// Muestra check grande, nombre del cliente, monto y nuevo vencimiento.
library;

import 'package:flutter/material.dart';

import 'componentes.dart';
import 'diseno.dart';

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
      backgroundColor: AppColores.fondo(context),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Check grande animado
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color:
                    AppColores.exito.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle,
                size: 80,
                color: AppColores.exito,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '¡Cobro registrado!',
              style: AppTexto.displayPequeno.copyWith(
                  color: AppColores.texto(context)),
            ),
            const SizedBox(height: 24),
            // Datos del cobro
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 32),
              child: Tarjeta(
                child: Column(
                  children: [
                    _fila(context, 'Cliente', nombreCliente),
                    const Divider(),
                    _fila(context, 'Monto', monto),
                    const Divider(),
                    _fila(context, 'Nuevo vencimiento',
                        nuevoVencimiento),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 48),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 48),
              child: BotonPrimario(
                texto: 'Entendido',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fila(BuildContext context, String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta,
              style: TextStyle(
                  color: AppColores.textoSecundario(context))),
          Flexible(
            child: Text(
              valor,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: AppColores.texto(context),
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
