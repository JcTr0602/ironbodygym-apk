/// Bloqueo automático con PIN (item 14 de Ajustes).
///
/// Se muestra al volver a la app si pasó más tiempo del configurado
/// en "Bloqueo automático" y el usuario tiene PIN configurado.
library;

import 'package:flutter/material.dart';

import '../perfil.dart';
import 'diseno.dart';

class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  String _pin = '';
  String? _error;
  bool _verificando = false;

  Future<void> _tecla(String d) async {
    if (_verificando || _pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 4) {
      setState(() => _verificando = true);
      final ok =
          await PerfilService.instance.verificarPin(_pin);
      if (!mounted) return;
      if (ok) {
        await PerfilService.instance.setUltimaActividad(
            DateTime.now().millisecondsSinceEpoch);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _verificando = false;
          _error = 'PIN incorrecto';
          _pin = '';
        });
      }
    }
  }

  void _borrar() {
    if (_pin.isEmpty || _verificando) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    // No se puede salir con el botón Atrás ni el gesto del sistema:
    // solo el PIN correcto cierra esta pantalla.
    return PopScope(
      canPop: false,
      child: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline,
                  size: 64, color: AppColores.naranja),
              const SizedBox(height: 16),
              const Text('App bloqueada',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Escribe tu PIN para continuar',
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final lleno = i < _pin.length;
                  return Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 8),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: lleno
                          ? AppColores.naranja
                          : Colors.grey.shade400,
                    ),
                  );
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              if (_verificando)
                const CircularProgressIndicator()
              else
                _teclado(),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _teclado() {
    Widget tecla(String d, {IconData? icono, VoidCallback? fn}) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(48),
            onTap: fn ?? () => _tecla(d),
            child: Container(
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.grey.shade400),
              ),
              child: icono != null
                  ? Icon(icono, size: 26)
                  : Text(d,
                      style: const TextStyle(fontSize: 26)),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(children: [tecla('1'), tecla('2'), tecla('3')]),
        Row(children: [tecla('4'), tecla('5'), tecla('6')]),
        Row(children: [tecla('7'), tecla('8'), tecla('9')]),
        Row(children: [
          const Expanded(child: SizedBox()),
          tecla('0'),
          tecla('', icono: Icons.backspace_outlined, fn: _borrar),
        ]),
      ],
    );
  }
}
