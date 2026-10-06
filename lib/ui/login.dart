/// Pantalla de acceso: nombre de usuario + contraseña.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../sync.dart';
import 'home.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _cargando = false;
  String? _error;
  final _auth = AuthService();

  Future<void> _entrar() async {
    final u = _user.text.trim();
    final p = _pass.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => _error = 'Escribe usuario y contraseña');
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await _auth.signIn(u, p);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()));
      // sincroniza al entrar
      SyncEngine.instance.run();
    } catch (e) {
      setState(() {
        _cargando = false;
        _error = 'No se pudo entrar. Revisa usuario, contraseña y conexión.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💪 Iron Body Gym')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
            Image.asset('assets/logo.jpg', height: 140),
            const SizedBox(height: 16),
            const Text('Entrenadores',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            TextField(
              controller: _user,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Usuario (ej. Gabriel)',
                  border: OutlineInputBorder()),
              onSubmitted: (_) => _entrar(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Contraseña', border: OutlineInputBorder()),
              onSubmitted: (_) => _entrar(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _cargando ? null : _entrar,
                child: _cargando
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Entrar', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Sin conexión puedes entrar igual si ya lo hiciste antes; '
              'todo se guarda y sincroniza solo.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '© Creado por JcTr0602',
                style: TextStyle(color: Colors.grey, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
