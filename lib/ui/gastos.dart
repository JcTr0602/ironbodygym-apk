import 'package:flutter/material.dart';

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
    final gastos = await gastosTodos();
    if (!mounted) return;
    setState(() {
      _gastos = gastos;
      _cargado = true;
    });
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
