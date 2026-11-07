import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import 'admin_secciones.dart';
import 'dialogo_gasto.dart';
import 'permisos_ui.dart';

/// 1.27: pantalla de Gastos fuera del Panel del dueño,
/// para el entrenador con el permiso can_registrar_gastos
/// (conectado de verdad a petición de Jc). Reutiliza la
/// sección del Panel (SeccionGastosScreen: últimos gastos
/// + botón de agregar) alimentada del espejo local
/// (gastosTodos: espejo + ops pendientes fusionados).
/// La entrada vive en Home → «Más» → Gastos, con el
/// permiso operativo verificado al tocar; el flujo de
/// captura es el compartido (dialogo_gasto.dart) y el
/// servidor verifica la op contra el mismo permiso.
class GastosScreen extends StatefulWidget {
  const GastosScreen({super.key});

  @override
  State<GastosScreen> createState() => _GastosScreenState();
}

class _GastosScreenState extends State<GastosScreen> {
  List<Map<String, dynamic>> _gastos = const [];
  bool _cargado = false;

  // H-01 (Argón 1.27): candado anti doble-toque
  // (patrón _operacionEnCurso de admin.dart):
  // check-and-set síncrono antes del primer await.
  bool _operando = false;

  @override
  void initState() {
    super.initState();
    _recargar();
  }

  Future<void> _recargar() async {
    // (M2-A A7) con red de seguridad: una fila sucia del
    // espejo dejaba la pantalla en spinner eterno (no había
    // try/catch y _cargado nunca pasaba a true).
    try {
      var gastos = await gastosTodos();
      // (M2-A A7, decisión de Jc vía delegación 2026-11-06)
      // el entrenador ve SOLO SUS gastos; el dueño, todos.
      // El espejo trae registrado_por (el nombre con el que
      // el servidor guarda al autor); las ops pendientes de
      // ESTE teléfono son suyas por definición. Sin nombre
      // de sesión, el entrenador solo ve sus pendientes.
      final auth = AuthService();
      if (!auth.isOwner) {
        final nombre = auth.displayName.trim();
        gastos = [
          for (final g in gastos)
            if (g['pendiente_sync'] == 1 ||
                (nombre.isNotEmpty &&
                    '${g['registrado_por'] ?? ''}'.trim() == nombre))
              g,
        ];
      }
      if (!mounted) return;
      setState(() {
        _gastos = gastos;
        _cargado = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _gastos = const [];
        _cargado = true;
      });
    }
  }

  Future<void> _agregar() async {
    if (_operando) return;
    _operando = true;
    try {
      // H-02 (Argón 1.27): permiso operativo con
      // refresco antes de abrir el flujo — el mismo
      // patrón del azulejo de Gastos en Home (la foto
      // de permisos vieja no deniega sin preguntar a
      // la red: el caso Duany). El getter ya deja
      // pasar al dueño; el flujo compartido re-verifica
      // permiso/dueño justo antes de encolar.
      if (!await permisoOperativoOkConRefresco(
          context,
          () => PermisosEntrenador().canRegistrarGastos,
          'registrar gastos')) {
        return;
      }
      if (!mounted) return;
      if (await agregarGastoFlow(context)) {
        await _recargar();
      }
    } finally {
      _operando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cargado) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return SeccionGastosScreen(
      getGastos: () => _gastos,
      onAgregarGasto: _agregar,
    );
  }
}
