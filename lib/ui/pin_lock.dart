/// Bloqueo automático con PIN (item 14 de Ajustes).
///
/// Se muestra al volver a la app si pasó más tiempo del configurado
/// en "Bloqueo automático" y el usuario tiene PIN configurado.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../perfil.dart';
import 'cierre_sesion.dart';
import 'componentes.dart';
import 'diseno.dart';

/// 1.28 (M5-C6): la cuenta atrás del bloqueo en texto
/// «M:SS» (o «H:MM:SS» si pasa de la hora). Redondea
/// HACIA ARRIBA: con 400 ms restantes enseña «0:01»,
/// nunca un «0:00» que prometa un desbloqueo que aún
/// no llegó. PURO, testeable.
String formatoCuentaAtrasPin(Duration d) {
  if (d <= Duration.zero) return '0:00';
  final totalSeg = (d.inMilliseconds / 1000).ceil();
  final h = totalSeg ~/ 3600;
  final m = (totalSeg % 3600) ~/ 60;
  final s = totalSeg % 60;
  String dos(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${dos(m)}:${dos(s)}' : '$m:${dos(s)}';
}

class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  String _pin = '';
  String? _error;
  bool _verificando = false;

  // 1.28 (M5-C6): la cuenta atrás VIVA del bloqueo: el
  // tiempo restante se relee del servicio cada segundo
  // (su ancla monotónica manda) y al llegar a cero la
  // pantalla se desbloquea sola.
  Duration _restante = Duration.zero;
  Timer? _temporizador;

  bool get _bloqueado => _restante > Duration.zero;

  @override
  void initState() {
    super.initState();
    // 1.28 (M5-A7/R1M5-4): si el PIN ya está en tiempo de
    // espera al abrir la pantalla, se dice desde el
    // principio (antes había que fallar una vez para
    // «descubrirlo», y el aviso mentía: «PIN incorrecto»).
    _avisarSiBloqueado();
  }

  @override
  void dispose() {
    _temporizador?.cancel();
    super.dispose();
  }

  void _arrancarTemporizador() {
    _temporizador?.cancel();
    _temporizador =
        Timer.periodic(const Duration(seconds: 1), (_) async {
      final r = await PerfilService.instance.pinBloqueoRestante();
      if (!mounted) return;
      setState(() => _restante = r);
      if (r <= Duration.zero) {
        _temporizador?.cancel();
        setState(() => _error = null);
      }
    });
  }

  /// Muestra la cuenta atrás honesta si hay un bloqueo
  /// por intentos vigente; devuelve si lo había.
  Future<bool> _avisarSiBloqueado() async {
    final r = await PerfilService.instance.pinBloqueoRestante();
    if (!mounted || r <= Duration.zero) return false;
    setState(() {
      _restante = r;
      _error = null;
    });
    _arrancarTemporizador();
    return true;
  }

  Future<void> _tecla(String d) async {
    if (_verificando || _bloqueado || _pin.length >= 4) return;
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
          _pin = '';
        });
        // 1.28 (M5-A7/R1M5-4): verificarPin devuelve el
        // mismo false por PIN erróneo y por bloqueo de
        // intentos; la pantalla distingue preguntando el
        // tiempo restante: si hay espera, ESE es el
        // mensaje (con sus minutos), no «PIN incorrecto».
        if (!await _avisarSiBloqueado() && mounted) {
          setState(() => _error = 'PIN incorrecto');
        }
      }
    }
  }

  void _borrar() {
    if (_pin.isEmpty || _verificando) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  /// Cierra la sesión si el usuario olvidó su PIN.
  /// No es un bypass: para volver a entrar necesita la contraseña
  /// de su cuenta, y el PIN se puede reconfigurar en Ajustes.
  Future<void> _olvidePin() async {
    // 1.23 (auditoría extra #3): mismo aviso previo a la purga
    // que en Home: si hay material sin subir que la purga
    // destruiría, el mensaje de confirmación lo advierte.
    final aviso = await avisoPerdidaAlCerrarSesion();
    if (!mounted) return;
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Olvidé mi PIN',
      mensaje: 'Se cerrará tu sesión en este teléfono. Para volver a entrar '
          'necesitarás tu contraseña de la cuenta. ¿Continuar?'
          '${aviso == null ? '' : '\n\n⚠️ $aviso'}',
      aceptar: 'Cerrar sesión',
      icono: Icons.lock_open_rounded,
    );
    if (ok != true || !mounted) return;
    // v1.2.5: purga de datos sensibles antes de cerrar sesión.
    await LocalDb.purgaAlCerrarSesion();
    // Yunque R5-M2-1 (ALTA): el hash del PIN vive bajo la
    // clave DEL USUARIO (seg_pin_hash_<usuario>) y
    // setPinHash la deriva de la sesión VIVA: hay que
    // borrarlo ANTES de signOut — después, el username es
    // '' y se borraba una clave sin sufijo que no existe,
    // dejando el PIN «olvidado» intacto y al usuario
    // atrapado con él al volver a entrar.
    await PerfilService.instance.setPinHash(null);
    await AuthService().signOut();
    if (!mounted) return;
    // v1.4.4: basta replegar hasta la raíz: al desaparecer la
    // sesión, RaizSesion muestra Login. (Antes se empujaba una
    // LoginScreen suelta que reemplazaba la raíz y la dejaba
    // muerta para futuros cierres.)
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    // No se puede salir con el botón Atrás ni el gesto del sistema:
    // solo el PIN correcto cierra esta pantalla.
    return PopScope(
      canPop: false,
      child: Scaffold(
      // 1.30 D1 (UI130-29): SOLO el arte de marca del rayo
      // como fondo decorativo de ESTA pantalla; la lógica
      // del PIN (4 dígitos, hash+salt, bloqueo por
      // inactividad) no se toca. El arte vive tras una
      // cortina del color de fondo al 86 %: se insinúa sin
      // pelear en contraste con el teclado ni con el
      // candado. Si el activo fallara, la pantalla se
      // pinta como siempre (errorBuilder vacío).
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/arte_marca_rayo.jpg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
          Container(
            color: AppColores.fondo(context).withValues(alpha: 0.86),
          ),
          SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 1.28 (M5-C6): el candado con la identidad
              // del gym, no un icono gris suelto.
              // 1.30 D1 (UI130-01): fuera el frente blanco
              // sobre el gradiente de marca (2,75/3,49): el
              // círculo pasa a carbonProfundo con el icono
              // en naranja de marca (el par que la
              // auditoría ya dejó tokenizado).
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColores.carbonProfundo,
                  border: Border.all(
                      color: AppColores.naranja.withValues(alpha: 0.45)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(Icons.lock_rounded,
                    size: 40, color: AppColores.naranja),
              ),
              const SizedBox(height: 16),
              const Text('App bloqueada',
                  style: AppTexto.displayPequeno),
              const SizedBox(height: 8),
              Text(
                  _bloqueado
                      ? 'Demasiados intentos fallidos'
                      : 'Escribe tu PIN para continuar',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context))),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final lleno = i < _pin.length;
                  return Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: AppEspacio.sm),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: lleno
                          ? AppColores.naranja
                          : AppColores.borde(context),
                    ),
                  );
                }),
              ),
              if (_bloqueado) ...[
                // 1.28 (M5-C6): la cuenta atrás, grande y
                // honesta, en vez del «espera N min»
                // congelado.
                const SizedBox(height: 4),
                Text(
                  formatoCuentaAtrasPin(_restante),
                  style: AppTexto.displayPequeno.copyWith(
                    color: AppColores.naranja,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Podrás intentarlo de nuevo cuando llegue a cero.',
                  textAlign: TextAlign.center,
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
              ] else if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(color: AppColores.error)),
              ],
              const SizedBox(height: 24),
              if (_verificando)
                const CircularProgressIndicator()
              else
                // Durante la espera el teclado se ve
                // atenuado y no responde.
                Opacity(
                  opacity: _bloqueado ? 0.35 : 1,
                  child: IgnorePointer(
                    ignoring: _bloqueado,
                    child: _teclado(),
                  ),
                ),
              const SizedBox(height: 16),
              // Recuperación: si olvidó el PIN, cerrar sesión.
              // Para volver a entrar necesita su contraseña de la cuenta.
              TextButton(
                onPressed: _olvidePin,
                child: const Text('Olvidé mi PIN'),
              ),
            ],
          ),
        ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _teclado() {
    Widget tecla(String d, {IconData? icono, VoidCallback? fn}) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadio.circular),
            onTap: fn ?? () => _tecla(d),
            child: Container(
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppColores.borde(context)),
              ),
              child: icono != null
                  ? Icon(icono, size: 24)
                  : Text(d,
                      style: AppTexto.displayPequeno.copyWith(
                          fontWeight: FontWeight.normal)),
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
          tecla('', icono: Icons.backspace_rounded, fn: _borrar),
        ]),
      ],
    );
  }
}
