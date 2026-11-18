/// Pantalla de acceso: diseño v1.1 (sistema de diseño centralizado).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import '../auth.dart';
import '../config.dart';
import '../perfil.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Yunque R5-M5-2: clasifica el fallo de entrada para no
/// mezclar credenciales con red (el mensaje único anterior
/// hacía creer que la contraseña estaba mal cuando era la
/// cobertura, y al revés). PURO, por el texto del error:
/// la autenticación de Supabase llega como AuthException
/// («Invalid login credentials») y la red como excepción
/// de socket/timeout/AuthRetryableFetchException.
String mensajeErrorLogin(Object e) {
  final s = e.toString();
  if (s.contains('Invalid login credentials') ||
      s.contains('invalid_credentials')) {
    return 'Usuario o contraseña incorrectos.';
  }
  final esRed = s.contains('SocketException') ||
      s.contains('TimeoutException') ||
      s.contains('timed out') ||
      s.contains('RetryableFetch') ||
      s.contains('Failed host lookup') ||
      s.contains('NetworkException');
  if (esRed) {
    return 'Sin conexión con el servidor. Revisa tu conexión e inténtalo de nuevo.';
  }
  return 'No se pudo entrar. Revisa usuario, contraseña y conexión.';
}

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

  /// 1.36 H-B1 (136-436): el aviso de SESIÓN (widget.aviso)
  /// no es un error de tecleo: lleva significado de alerta
  /// y su propio anuncio, separado del error de login.
  bool _errorEsAviso = false;
  final _auth = AuthService();
  late AnimationController _anim;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _error = widget.aviso;
    _errorEsAviso = widget.aviso != null;
    // Animación de entrada: fade + deslizamiento suave.
    // 1.35 (UI-13): la duración pasa al token largo
    // (antes 600 ms escritos a mano).
    _anim = AnimationController(
      vsync: this,
      duration: AppMovimiento.larga,
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward();
    // Recupera el último usuario
    SharedPreferences.getInstance().then((p) {
      // 1.36 H-B1 (136-432): si la pantalla ya murió, no se
      // escribe sobre un controlador desechado.
      if (!mounted) return;
      final u = p.getString('ultimo_usuario');
      if (u != null && u.isNotEmpty) {
        _user.text = u;
      }
      // 1.36 H-B1 (136-437): enganchar la limpieza del
      // error DESPUÉS de la recuperación, para que el
      // relleno automático no borre el aviso de sesión.
      _user.addListener(_limpiarErrorAlTeclear);
      _pass.addListener(_limpiarErrorAlTeclear);
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

  /// 136-437: al primer cambio de texto, el error/aviso
  /// anterior deja de mandar sobre el formulario.
  void _limpiarErrorAlTeclear() {
    if (_error != null && mounted) {
      setState(() {
        _error = null;
        _errorEsAviso = false;
      });
    }
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
    } catch (e) {
      // v1.4.0 (Argón §8): prohibido el fail-open SILENCIOSO. La
      // vinculación es 100% local (SharedPreferences), sin respuesta
      // de servidor que pueda negar el acceso: bloquear la entrada
      // por un fallo local dejaría fuera a un entrenador legítimo
      // sin ganar seguridad real. Se registra el fallo en la
      // bitácora (visible para el dueño) y se permite entrar.
      AppLog.error('login', 'verificar_dispositivo_fallo', d: '$e');
      return true;
    }
  }

  Future<void> _entrar() async {
    // 1.36 H-C1 (136-433): guarda de reentrada — el botón
    // se sustituye por el spinner, pero el Enter del campo
    // de contraseña seguía llamando y podía duplicar el
    // signIn.
    if (_cargando) return;
    final u = _user.text.trim();
    final p = _pass.text;
    // 1.36 H-C1 (136-462): si teclea un «@», el alias se
    // convertiría en OTRO usuario en silencio y el fallo
    // se leería como credenciales malas: se avisa de que
    // basta el nombre, sin dominio, y no se intenta.
    if (u.contains('@')) {
      setState(() {
        _error = 'Escribe solo tu nombre de usuario, sin '
            'el @ ni el dominio.';
        _errorEsAviso = false;
      });
      return;
    }
    if (u.isEmpty || p.isEmpty) {
      setState(() {
        _error = 'Escribe usuario y contraseña';
        _errorEsAviso = false;
      });
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
      _errorEsAviso = false;
    });
    // v1.4.4: el messenger se captura ANTES de entrar: en cuanto
    // nazca la sesión, la raíz puede desmontar esta pantalla y el
    // contexto dejaría de ser válido para mostrar avisos.
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _auth.signIn(u, p);
      // v1.2.2: descarga perfil (móvil/carnet) si lo local está vacío
      // (sobrevive reinstalaciones)
      try {
        await PerfilService.instance.descargarPerfilSiVacio();
      } catch (_) {}
      // Guarda el usuario para la próxima vez
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString('ultimo_usuario', u);
      });
      // v1.4.4: ya NO se navega a Inicio a mano: la raíz
      // (RaizSesion) detecta la sesión nueva y muestra Inicio.
      // (El pushReplacement anterior reemplazaba la ruta raíz y
      // dejaba la app sin raíz reactiva: un cierre de sesión
      // posterior no volvía a Login.)
      // v1.0.12: verifica vinculación de dispositivo (100% local;
      // avisa pero NUNCA bloquea la entrada — decisión Argón
      // v1.4.0 §8). Va antes de arrancar la sincronización, como
      // en el flujo original, y su aviso usa el messenger
      // capturado al inicio (panel v1.4.4).
      final vinculado = await _verificarDispositivo(u);
      if (!vinculado) {
        // Gramática de avisos (1.23, B6/H-04): sobre el
        // messenger capturado antes de navegar, vía el helper
        // sin contexto (el de esta pantalla ya no es válido
        // tras el await); el helper limpia la cola igual.
        mostrarSnackEnMessenger(
          messenger,
          'Entrando desde un dispositivo no vinculado',
          significado: SignificadoChip.alerta,
        );
      }
      // sincroniza al entrar
      SyncEngine.instance.run();
    } catch (e) {
      setState(() {
        _cargando = false;
        // Yunque R5-M5-2: credenciales ≠ red. Sin esto, un
        // entrenador sin cobertura creía que su contraseña
        // estaba mal (y pedía reseteos innecesarios), y una
        // contraseña mala se atribuía a «la conexión».
        _error = mensajeErrorLogin(e);
        _errorEsAviso = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 1.35 (UX-06): UNA sola puerta con la del PIN —
      // el arte del rayo a pantalla completa como
      // escenario y el velo grafito calculado para que
      // los campos se lean igual que sobre el degradado
      // carbón de antes (más denso al pie, donde viven
      // los campos). Si el activo fallara, el velo solo
      // sigue siendo la puerta oscura de siempre.
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/arte_marca_rayo.jpg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // El velo respira arriba (la zona del
                // logo: el arte se reconoce) y se cierra
                // donde viven los campos (su contraste
                // es el de siempre: cristal grafito
                // sobre velo denso).
                colors: [
                  AppColores.pizarra.withValues(alpha: 0.78),
                  AppColores.pizarra.withValues(alpha: 0.90),
                  AppColores.pizarra.withValues(alpha: 0.95),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          SafeArea(
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
                    // 1.35 (UX-06): sin recorte circular —
                    // el logo se apoya sobre el arte en su
                    // cuadrado redondeado, con su resplandor.
                    Container(
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppRadio.xl),
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
                        borderRadius:
                            BorderRadius.circular(AppRadio.xl),
                        child: Image.asset('assets/logo.jpg',
                            height: 130,
                            width: 130,
                            fit: BoxFit.cover,
                            // 1.36 H-C1 (136-434): como el
                            // fondo — si el logo faltara, un
                            // rayo de marca, no un error
                            // crudo sobre la puerta.
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.bolt_rounded,
                                    size: 64,
                                    color: AppColores.naranja)),
                      ),
                    ),
                    const SizedBox(height: AppEspacio.lg),
                    RichText(
                      text: TextSpan(
                        style: AppTexto.display.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1),
                        children: [
                          TextSpan(
                              text: 'IRON ',
                              style:
                                  TextStyle(color: AppColores.textoSobreOscuro)),
                          TextSpan(
                              text: 'BODY',
                              style: TextStyle(
                                  color: AppColores.naranja)),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppEspacio.sm),
                    Text('G E S T I Ó N',
                        style: AppTexto.etiqueta.copyWith(
                            color: AppColores.textoSobreOscuroSuave,
                            fontWeight: FontWeight.normal,
                            letterSpacing: 4)),
                    const SizedBox(height: AppEspacio.xxl),
                    // Campo usuario.
                    // 1.35 (UI-16): teclado de correo, sin
                    // corrector ni sugerencias, con su pista
                    // de autorrelleno y «siguiente» hacia la
                    // contraseña.
                    _campoOscuro(
                      controller: _user,
                      focusNode: _userFocus,
                      hint: 'Usuario',
                      icono: Icons.person_rounded,
                      textCapitalization: TextCapitalization.none,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) =>
                          _passFocus.requestFocus(),
                    ),
                    const SizedBox(height: AppEspacio.md),
                    // Campo contraseña.
                    // 1.35 (UI-16): pista de autorrelleno de
                    // contraseña y «Entrar» desde su teclado.
                    _campoOscuro(
                      controller: _pass,
                      focusNode: _passFocus,
                      hint: 'Contraseña',
                      icono: Icons.lock_rounded,
                      obscure: !_verPass,
                      autofillHints: const [AutofillHints.password],
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      suffix: IconButton(
                        icon: Icon(
                            _verPass
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            color: AppColores.textoSobreOscuroMedio),
                        onPressed: () => setState(
                            () => _verPass = !_verPass),
                      ),
                      onSubmitted: (_) => _entrar(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppEspacio.md),
                      // 1.36 H-B1 (136-436): aviso de sesión
                      // (alerta, región viva que lo anuncia)
                      // separado del error de login (error).
                      Semantics(
                        container: true,
                        liveRegion: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppEspacio.md,
                              vertical: AppEspacio.sm),
                          decoration: BoxDecoration(
                            color: (_errorEsAviso
                                    ? AppColores.alerta
                                    : AppColores.error)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(
                                AppRadio.md),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                  _errorEsAviso
                                      ? Icons.warning_amber_rounded
                                      : Icons.error_outline_rounded,
                                  color: _errorEsAviso
                                      ? AppColores.alerta
                                      : AppColores.error,
                                  size: 18),
                              const SizedBox(
                                  width: AppEspacio.sm),
                              Expanded(
                                child: Text(_error!,
                                    // 1.36 (136-290): papel de texto de error (errorTextoOscuro), no el brillante crudo (3,94–4,21)
                                    style: AppTexto.secundario.copyWith(color: AppColores.errorTextoOscuro)),
                              ),
                            ],
                          ),
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
                            texto: 'Entrar',
                            icono: Icons.login_rounded,
                            onPressed: _entrar,
                          ),
                    const SizedBox(height: AppEspacio.lg),
                    Text(
                      'Sin conexión puedes entrar igual si ya lo hiciste antes.\n'
                      'Todo se guarda y sincroniza solo.',
                      style: AppTexto.metadato.copyWith(color: AppColores.textoSobreOscuroMedio),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppEspacio.xxl),
                    Text(
                      '© Creado por JcTr0602',
                      style: AppTexto.metadato.copyWith(color: AppColores.textoSobreOscuroTenue),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'v${AppConfig.appVersion}',
                      style: AppTexto.minuscula.copyWith(color: AppColores.textoSobreOscuroMinimo),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppEspacio.lg),
                  ],
                ),
              ),
            ),
          ),
          ),
        ],
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
    TextInputType? keyboardType,
    Iterable<String>? autofillHints,
    bool autocorrect = true,
    bool enableSuggestions = true,
    TextInputAction? textInputAction,
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
        keyboardType: keyboardType,
        autofillHints: autofillHints,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        textInputAction: textInputAction,
        style: const TextStyle(color: AppColores.textoSobreOscuro),
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          hintText: hint,
          // 1.36 (136-290): la pista es texto FUNCIONAL —
          // peldaño Medio (6,0:1), no Tenue (3,56).
          hintStyle:
              const TextStyle(color: AppColores.textoSobreOscuroMedio),
          // 1.36 H-B1 (136-435): la familia sobreOscuro es
          // UNA — texto, pista e icono salen de sus tokens
          // (el icono iba con textoSecundario del tema, que
          // en tema claro es gris oscuro sobre el grafito).
          prefixIcon: Icon(icono,
              color: AppColores.textoSobreOscuroMedio),
          suffixIcon: suffix,
          filled: true,
          // 1.35 (UX-06): cristal grafito — el relleno
          // se vuelve translúcido sobre el velo y el
          // arte se insinúa tras el campo sin pelear
          // con el texto (el velo mantiene el contraste
          // de siempre).
          fillColor:
              AppColores.grafitoTactico.withValues(alpha: 0.78),
          border: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(AppRadio.lg),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(AppRadio.lg),
            borderSide: const BorderSide(
                color: AppColores.bordeOscuro),
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
