import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../perfil.dart';
import 'home.dart';
import 'login.dart';

/// Pantalla de bloqueo biométrico (v1.0.14).
///
/// Se muestra al abrir la app cuando hay sesión activa y el usuario
/// activó "Entrar con huella digital" en ajustes.
class BloqueoScreen extends StatefulWidget {
  const BloqueoScreen({super.key});

  @override
  State<BloqueoScreen> createState() => _BloqueoScreenState();
}

class _BloqueoScreenState extends State<BloqueoScreen> {
  bool _verificando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pide la huella automáticamente al abrir
    WidgetsBinding.instance.addPostFrameCallback((_) => _autenticar());
  }

  Future<void> _autenticar() async {
    if (_verificando) return;
    setState(() {
      _verificando = true;
      _error = null;
    });
    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Confirma tu identidad para entrar',
      );
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      } else {
        setState(() {
          _verificando = false;
          _error = 'No se pudo verificar. Inténtalo de nuevo.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verificando = false;
        _error = 'Error: $e';
      });
    }
  }

  /// Salir y volver al login (cierra la sesión).
  Future<void> _salir() async {
    // No cerramos la sesión de Supabase, solo volvemos al login.
    // El usuario tendrá que escribir su contraseña de nuevo.
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => const LoginScreen(
              aviso: 'Sesión bloqueada. Entra de nuevo.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.fingerprint,
                  size: 80, color: Colors.orange),
              const SizedBox(height: 24),
              const Text(
                'App bloqueada',
                style:
                    TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Confirma tu huella para continuar.',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (_verificando)
                const CircularProgressIndicator()
              else
                ElevatedButton.icon(
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Verificar huella'),
                  onPressed: _autenticar,
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center),
              ],
              const SizedBox(height: 32),
              TextButton(
                onPressed: _salir,
                child: const Text('Usar contraseña en su lugar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Decide la pantalla inicial según sesión y configuración de huella.
Future<Widget> pantallaInicial(dynamic auth) async {
  if (!auth.loggedIn) return const LoginScreen();
  try {
    final huella = await PerfilService.instance.getHuella();
    if (huella) return const BloqueoScreen();
  } catch (_) {}
  return const HomeScreen();
}
