import 'package:flutter/material.dart';

import '../acceso_bloqueo.dart';
import '../tiempo.dart';
import 'diseno.dart';

/// 1.21 — Capa del candado de acceso (CD-03 de Argón): se monta
/// sobre el Navigator entero (main.dart la apila sobre la app)
/// y anuncia la pausa con una tarjeta opaca centrada: medallón
/// con el candado, título, el mensaje del dueño y la hora de
/// reactivación. Nada más: la sesión, la cola y los datos
/// quedan intactos por debajo, y la sync sigue corriendo para
/// recibir el desbloqueo.
///
/// 1.23 (campo, 2026-11-03): la primera versión pintaba el
/// mensaje en texto blanco sobre el velo gris translúcido —
/// «se ve feo y poco legible» (Jc, con captura desde la app de
/// Clientes). Ahora el velo es casi opaco y el anuncio vive en
/// una tarjeta oscura con contraste pleno, igual en las dos
/// apps.
///
/// - [AbsorbPointer] sobre todo el Navigator: ningún toque
///   llega a las pantallas ni a los diálogos abiertos.
/// - Al caer el candado se suelta el foco: con el teclado abierto
///   se podría seguir tecleando y enviar con «Done» por debajo.
/// - Desviación documentada de CD-03: el PopScope pedido no
///   puede vivir aquí — PopScope y BackButtonListener exigen un
///   ancestro Router/ruta y esta capa va en el builder de
///   MaterialApp, SOBRE el Navigator (probado: lanzan
///   «Router operation requested with a context that does not
///   include a Router» en el test de la capa). El botón atrás
///   del sistema solo puede navegar o salir por debajo de una
///   pantalla opaca y absorbente: nada es operable, y al volver
///   a entrar la capa sigue puesta.
class CapaCandado extends StatefulWidget {
  final BloqueoVigente bloqueo;

  const CapaCandado({super.key, required this.bloqueo});

  @override
  State<CapaCandado> createState() => _CapaCandadoState();
}

class _CapaCandadoState extends State<CapaCandado> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bloqueo;
    final expira = b.expiraEn;
    final expiraHabana = expira == null ? null : aHabana(expira);
    return AbsorbPointer(
      child: ColoredBox(
        color: const Color(0xF0141414),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppEspacio.xl),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                decoration: BoxDecoration(
                  color: AppColores.carbon,
                  borderRadius: BorderRadius.circular(AppRadio.xl),
                  border: Border.all(color: Colors.white12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 32,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(
                    AppEspacio.xl, AppEspacio.xxl, AppEspacio.xl,
                    AppEspacio.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppColores.gradienteNaranja,
                      ),
                      child: const Icon(
                        Icons.lock_rounded,
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: AppEspacio.lg),
                    Text(
                      'Acceso pausado',
                      textAlign: TextAlign.center,
                      style: AppTexto.tituloPagina
                          .copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: AppEspacio.sm),
                    Text(
                      b.mensaje,
                      textAlign: TextAlign.center,
                      style: AppTexto.cuerpo.copyWith(
                        color: Colors.white,
                        fontSize: 16,
                        height: 1.45,
                      ),
                    ),
                    if (expiraHabana != null) ...[
                      const SizedBox(height: AppEspacio.lg),
                      const Divider(color: Colors.white10, height: 1),
                      const SizedBox(height: AppEspacio.md),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: AppColores.naranja,
                          ),
                          const SizedBox(width: AppEspacio.xs),
                          Flexible(
                            child: Text(
                              'Se reactiva solo el '
                              '${expiraHabana.day.toString().padLeft(2, '0')}/'
                              '${expiraHabana.month.toString().padLeft(2, '0')} '
                              'a las '
                              '${expiraHabana.hour.toString().padLeft(2, '0')}:'
                              '${expiraHabana.minute.toString().padLeft(2, '0')}.',
                              textAlign: TextAlign.center,
                              style: AppTexto.metadato.copyWith(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppEspacio.lg),
                    Text(
                      'IRON BODY GYM',
                      style: AppTexto.metadato.copyWith(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
