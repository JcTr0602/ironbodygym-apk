/// Pantalla de acceso: diseño v1.1 (sistema de diseño centralizado).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../config.dart';
import '../perfil.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
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

  /// v1.0.12: verifica si el dispositivo está vinculado al usuario.
  /// Devuelve true si no hay vinculación activa o si coincide.
  Future<bool> _verificarDispositivo(String username) async {
    try {
      final perfil = PerfilService.instance;
      if (!await perfil.getVincularDispositivo()) return true;
      final actual = await perfil.getDeviceId();
      final vinculado =
          await perfil.getDispositivoVinculado(username.toLowerCase());
      if (vinculado == null || vinculado.isEmpty) {
        // Primera vez: vincula automáticamente
        await perfil.setDispositivoVinculado(
            username.toLowerCase(), actual);
        return true;
      }
      return vinculado == actual;
    } catch (_) {
      return true;
    }
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
      // v1.0.12: verifica vinculación de dispositivo
      final vinculado = await _verificarDispositivo(u);
      if (!mounted) return;
      if (!vinculado) {
        // Dispositivo no vinculado: avisa pero permite entrar
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Entrando desde un dispositivo no vinculado'),
          duration: Duration(seconds: 4),
        ));
      }
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppColores.gradienteCarbon,
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.xl),
                child: Column(
                  children: [
                    const SizedBox(height: AppEspacio.xxl),
                    // Logo
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColores.naranja
                                .withValues(alpha: 0.3),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(75),
                        child: Image.asset('assets/logo.jpg',
                            height: 130,
                            width: 130,
                            fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(height: AppEspacio.lg),
                    RichText(
                      text: const TextSpan(
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1),
                        children: [
                          TextSpan(
                              text: 'IRON ',
                              style:
                                  TextStyle(color: Colors.white)),
                          TextSpan(
                              text: 'BODY',
                              style: TextStyle(
                                  color: AppColores.naranja)),
                          TextSpan(
                              text: ' GYM',
                              style:
                                  TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppEspacio.sm),
                    const Text('E N T R E N A D O R E S',
                        style: TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                            letterSpacing: 4)),
                    const SizedBox(height: AppEspacio.xxl),
                    // Campo usuario
                    _campoOscuro(
                      controller: _user,
                      focusNode: _userFocus,
                      hint: 'Usuario',
                      icono: Icons.person,
                      textCapitalization: TextCapitalization.words,
                      onSubmitted: (_) => _entrar(),
                    ),
                    const SizedBox(height: AppEspacio.md),
                    // Campo contraseña
                    _campoOscuro(
                      controller: _pass,
                      focusNode: _passFocus,
                      hint: 'Contraseña',
                      icono: Icons.lock,
                      obscure: !_verPass,
                      suffix: IconButton(
                        icon: Icon(
                            _verPass
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: Colors.white54),
                        onPressed: () => setState(
                            () => _verPass = !_verPass),
                      ),
                      onSubmitted: (_) => _entrar(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppEspacio.md),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppEspacio.md,
                            vertical: AppEspacio.sm),
                        decoration: BoxDecoration(
                          color: AppColores.error
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(
                              AppRadio.md),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline,
                                color: AppColores.error,
                                size: 18),
                            const SizedBox(
                                width: AppEspacio.sm),
                            Expanded(
                              child: Text(_error!,
                                  style: const TextStyle(
                                      color: AppColores.error,
                                      fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppEspacio.xl),
                    // Botón entrar
                    _cargando
                        ? const SizedBox(
                            height: 56,
                            child: Center(
                                child: CircularProgressIndicator(
                                    color:
                                        AppColores.naranja)),
                          )
                        : BotonPrimario(
                            texto: 'ENTRAR',
                            icono: Icons.login,
                            onPressed: _entrar,
                          ),
                    const SizedBox(height: AppEspacio.lg),
                    const Text(
                      'Sin conexión puedes entrar igual si ya lo hiciste antes.\n'
                      'Todo se guarda y sincroniza solo.',
                      style: TextStyle(
                          color: Colors.white54, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppEspacio.xxl),
                    const Text(
                      '© Creado por JcTr0602',
                      style: TextStyle(
                          color: Colors.white38, fontSize: 11),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'v${AppConfig.appVersion}',
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 10),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppEspacio.lg),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Campo de texto oscuro con borde naranja brillante al enfocar
  /// (estilo del mockup v1.1).
  Widget _campoOscuro({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required IconData icono,
    bool obscure = false,
    Widget? suffix,
    TextCapitalization textCapitalization =
        TextCapitalization.none,
    void Function(String)? onSubmitted,
  }) {
    final enfocado = focusNode.hasFocus;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadio.lg),
        boxShadow: enfocado
            ? [
                BoxShadow(
                  color: AppColores.naranja
                      .withValues(alpha: 0.4),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscure,
        textCapitalization: textCapitalization,
        style: const TextStyle(color: Colors.white),
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              const TextStyle(color: Colors.white38),
          prefixIcon:
              Icon(icono, color: AppColores.naranja),
          suffixIcon: suffix,
          filled: true,
          fillColor: const Color(0xFF2A2A2A),
          border: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(AppRadio.lg),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(AppRadio.lg),
            borderSide: const BorderSide(
                color: Color(0xFF3A3A3A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(AppRadio.lg),
            borderSide: const BorderSide(
                color: AppColores.naranja, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.lg,
              vertical: AppEspacio.lg),
        ),
      ),
    );
  }
}
