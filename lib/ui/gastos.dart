import 'package:flutter/material.dart';

import '../app_log.dart';
import '../errores_sync.dart' show mensajeErrorAmable;
import '../negocio.dart';
import '../permisos_entrenador.dart';
import 'admin_secciones.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';
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
  // Yunque de App 1.31 (C1-1): el fallo de lectura se PINTA
  // como error, no como «sin gastos» con totales en cero.
  String? _errorCarga;

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
      final gastos = await gastosTodos();
      // (M2-A A7, decisión de Jc vía delegación 2026-11-06)
      // el entrenador ve SOLO SUS gastos; el dueño, todos.
      // 1.29 (Oleada 2, D-A1): el filtro vive SOLO en
      // gastosTodos (predicado único de negocio.dart: el
      // autor del espejo se compara contra el nombre
      // canónico que el directorio asocia al telegram_id
      // de la sesión). Aquí había una segunda copia que
      // comparaba contra el nombre de EXHIBICIÓN de la
      // sesión (displayName, editable por el propio
      // usuario): además de duplicar, permitía ver los
      // gastos de otro poniéndose su nombre. Retirada.
      if (!mounted) return;
      setState(() {
        _gastos = gastos;
        _errorCarga = null;
        _cargado = true;
      });
    } catch (e) {
      // Yunque de App 1.31 (C1-1): bitácora + error visible.
      // Antes el catch dejaba la lista vacía y la pantalla
      // decía «Sin gastos registrados» con totales en cero:
      // un fallo de lectura del espejo se leía como un día
      // sin gastos.
      AppLog.error('gastos', 'carga_fallo', d: '$e');
      if (!mounted) return;
      setState(() {
        _gastos = const [];
        // 1.36 H-B2 (136-683): el error se muestra AMABLE,
        // no la excepción cruda.
        _errorCarga = mensajeErrorAmable(e);
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
      // 1.36 H-B2 (136-683): esqueleto y AppBar de la casa
      // también en los estados previos de esta pantalla.
      return Scaffold(
        appBar: appBarIron(context, 'Gastos'),
        body: const Padding(
          padding: EdgeInsets.all(AppEspacio.lg),
          child: SkeletonLista(items: 4),
        ),
      );
    }
    if (_errorCarga != null) {
      return Scaffold(
        appBar: appBarIron(context, 'Gastos'),
        body: EstadoError(
          detalle: _errorCarga,
          onReintentar: _recargar,
        ),
      );
    }
    // 136-683/684: la recarga por gesto (RefreshIndicator)
    // la aporta esta pantalla vía la sección compartida, y
    // los estados cruzan con AnimatedSwitcher.
    return AnimatedSwitcher(
      duration: AppMovimiento.media,
      child: KeyedSubtree(
        key: const ValueKey('contenido'),
        child: SeccionGastosScreen(
          getGastos: () => _gastos,
          onAgregarGasto: _agregar,
          onRecargar: _recargar,
        ),
      ),
    );
  }
}
