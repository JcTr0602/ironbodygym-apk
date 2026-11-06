import 'package:flutter/material.dart';

import '../negocio.dart';
import 'admin_secciones.dart';
import 'dialogo_gasto.dart';

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
    if (await agregarGastoFlow(context)) {
      await _recargar();
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
