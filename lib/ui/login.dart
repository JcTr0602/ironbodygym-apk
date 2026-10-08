/// Pantalla de acceso: diseño C (hero con franja).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../sync.dart';
import 'home.dart';

class LoginScreen extends StatefulWidget {
  final String? aviso;
  const LoginScreen({super.key, this.aviso});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _userFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _cargando = false;
  bool _verPass = false;
  String? _error;
  final _auth = AuthService();
  late AnimationController _anim;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _error = widget.aviso;
    // Animación de entrada: fade + deslizamiento suave
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward();
    // Recupera el último usuario
    SharedPreferences.getInstance().then((p) {
      final u = p.getString('ultimo_usuario');
      if (u != null && u.isNotEmpty) {
        _user.text = u;
      }
    });
    // Resalta el campo activo
    _userFocus.addListener(() => setState(() {}));
    _passFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _anim.dispose();
    _user.dispose();
    _pass.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

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
      // Guarda el usuario para la próxima vez
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString('ultimo_usuario', u);
      });
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
    const naranja = Color(0xFFE8821A);
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: Column(
          children: [
            const SizedBox(height: 36),
            ClipRRect(
              borderRadius: BorderRadius.circular(90),
              child: Image.asset('assets/logo.jpg',
                  height: 150, width: 150, fit: BoxFit.cover),
            ),
            const SizedBox(height: 18),
            RichText(
              text: const TextSpan(
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1),
                children: [
                  TextSpan(
                      text: 'IRON ',
                      style: TextStyle(color: Colors.white)),
                  TextSpan(
                      text: 'BODY',
                      style: TextStyle(color: naranja)),
                  TextSpan(
                      text: ' GYM',
                      style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const Text('E N T R E N A D O R E S',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    letterSpacing: 4)),
            const SizedBox(height: 28),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                  child: Column(
                    children: [
                      TextField(
                        controller: _user,
                        focusNode: _userFocus,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          hintText: 'Usuario',
                          prefixIcon: const Icon(Icons.person,
                              color: Colors.grey),
                          filled: true,
                          fillColor: const Color(0xFFF1F1F1),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                                color: Color(0xFFE8821A), width: 2),
                          ),
                        ),
                        onSubmitted: (_) => _entrar(),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _pass,
                        focusNode: _passFocus,
                        obscureText: !_verPass,
                        decoration: InputDecoration(
                          hintText: 'Contraseña',
                          prefixIcon: const Icon(Icons.lock,
                              color: Colors.grey),
                          suffixIcon: IconButton(
                            icon: Icon(
                                _verPass
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.grey),
                            onPressed: () => setState(
                                () => _verPass = !_verPass),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF1F1F1),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                                color: Color(0xFFE8821A), width: 2),
                          ),
                        ),
                        onSubmitted: (_) => _entrar(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 13),
                            textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: naranja,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _cargando ? null : _entrar,
                          child: _cargando
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : const Text('Entrar',
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Sin conexión puedes entrar igual si ya lo hiciste antes.\n'
                        'Todo se guarda y sincroniza solo.',
                        style: TextStyle(
                            color: Colors.grey, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              color: Colors.white,
              width: double.infinity,
              padding: const EdgeInsets.only(bottom: 12),
              child: const Text(
                '© Creado por JcTr0602',
                style: TextStyle(color: Colors.grey, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'v1.0.4',
              style: TextStyle(color: Colors.white24, fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}
