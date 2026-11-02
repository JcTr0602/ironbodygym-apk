import 'package:flutter/material.dart';

import '../acceso_bloqueo.dart';
import '../tiempo.dart';
import 'diseno.dart';

/// 1.21 — Capa del candado de acceso (CD-03 de Argón): se monta
/// sobre el Navigator entero (main.dart la apila sobre la app),
/// gris semitransparente, candado grande y el mensaje del dueño.
/// Nada más: la sesión, la cola y los datos quedan intactos por
/// debajo, y la sync sigue corriendo para recibir el desbloqueo.
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
        color: const Color(0xD95A5A5A),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppEspacio.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_rounded,
                    size: 96,
                    color: Colors.white,
                  ),
                  const SizedBox(height: AppEspacio.xl),
                  Text(
                    b.mensaje,
                    textAlign: TextAlign.center,
                    style: AppTexto.titulo.copyWith(color: Colors.white),
                  ),
                  if (expiraHabana != null) ...[
                    const SizedBox(height: AppEspacio.md),
                    Text(
                      'Se reactiva solo el '
                      '${expiraHabana.day.toString().padLeft(2, '0')}/'
                      '${expiraHabana.month.toString().padLeft(2, '0')} '
                      'a las '
                      '${expiraHabana.hour.toString().padLeft(2, '0')}:'
                      '${expiraHabana.minute.toString().padLeft(2, '0')}.',
                      textAlign: TextAlign.center,
                      style: AppTexto.metadato
                          .copyWith(color: Colors.white70),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
