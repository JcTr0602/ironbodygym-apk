import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque3.dart';
import '../entrenador_identidad.dart';
import '../fotos.dart';
import '../etiqueta_producto.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto, fmtFecha;
import '../servicios.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'iconos_propios.dart';
import 'servicios_detalle.dart';
import 'servicios_precios.dart';
import 'skeleton.dart';
import '../app_log.dart';

/// v1.8.0: Administración de Servicios por dosis (SOLO DUEÑO):
/// precios y comisión, stock común de agua (CPP), pomos y botes.
/// 1.15: los LOTES salen de la UI (P4) y «cerrar bote» también
/// (P3); el stock vivo son los pomos. Todas las acciones encolan
/// su op; el servidor re-impone los permisos (estas ops son
/// solo-admin en el candado).
class ServiciosAdminScreen extends StatefulWidget {
  /// 1.31 (Mejoras · Inventario): embebida = sin Scaffold ni
  /// AppBar propios (la monta el hub «Servicios» en su zona
  /// Inventario); suelta, es la pantalla «Inventario».
  final bool embebida;
  const ServiciosAdminScreen({super.key, this.embebida = false});

  @override
  State<ServiciosAdminScreen> createState() =>
      _ServiciosAdminScreenState();
}

class _ServiciosAdminScreenState extends State<ServiciosAdminScreen> {
  bool _cargando = true;
  // 1.36 H-B3 (136-727): guarda de reentrada de _cargar.
  bool _enCurso = false;
  // SL-7 (G06-1): el fallo de carga se VE (EstadoError con
  // Reintentar, el patrón de la pantalla principal); antes la
  // pantalla caía en el inventario vacío en silencio.
  bool _errorCarga = false;
  // 1.28 (M3-A6): guarda de reentrada de los diálogos que
  // MUEVEN dosis/pomos/agua. Un doble toque apilaba dos
  // diálogos idénticos y confirmar ambos movía el doble
  // (rellenar 10 dos veces = 20). Patrón de la casa
  // (_ventaEnCurso en Servicios, _operando en Nómina):
  // check-and-set síncrono antes del primer await.
  bool _operando = false;
  ({double sinAgua, double conAgua, double agua, double comision})?
      _precios;
  ({int saldo, double cpp}) _agua = (saldo: 0, cpp: 0);

  /// 1.31 (Mejoras · Inventario): últimos movimientos del
  /// agua común, para la mini-lista del bloque Agua.
  List<Map<String, dynamic>> _movsAgua = [];
  List<Map<String, dynamic>> _botes = [];
  List<Map<String, dynamic>> _pomos = [];
  // 1.29 (Oleada 4, FB-09): peticiones de relleno pendientes
  // del espejo + las atendidas EN ESTA pantalla (la fila del
  // espejo sigue 'pendiente' hasta que la op sube, el
  // servidor cierra y el pull baja: sin esta memoria, un
  // segundo toque rellenaría dos veces por la misma
  // petición).
  List<SolicitudRelleno> _solicitudesRelleno = [];
  final Set<String> _rellenoAtendidasLocal = {};
  // 1.29 (Oleada 4, D-11): telegram_id → posición en la
  // lista canónica de entrenadores (color categórico).
  Map<int, int> _indiceEntrenador = {};
  List<Map<String, dynamic>> _suplementos = [];
  Map<int, String> _categorias = {};
  Map<int, String> _personas = {}; // telegram_id → nombre
  @override
  void initState() {
    super.initState();
    _cargar();
  }


  Map<String, dynamic>? _supPorIdLocal(int? id) {
    for (final s in _suplementos) {
      if ((s['id'] as num?)?.toInt() == id) return s;
    }
    return null;
  }

  /// 1.25 T120 (F4-17): semáforo del saldo de un pomo — un pomo
  /// a punto de agotarse se veía igual que uno lleno (el saldo
  /// iba en texto gris). Verde > 10, ámbar 5-10, rojo ≤ 4; sin
  /// saldo numérico, sin punto.
  Color? _colorSaldoPomo(dynamic saldo) {
    final n = (saldo as num?)?.toInt();
    if (n == null) return null;
    if (n > 10) return AppColores.exito;
    if (n > 4) return AppColores.alerta;
    return AppColores.error;
  }

  /// Ítem 13: «Nombre · Categoría» en toda identificación de producto
  /// de esta pantalla (selector de Abrir bote, pomos y botes).
  String _nombreSup(int? id) {
    for (final s in _suplementos) {
      if ((s['id'] as num?)?.toInt() == id) {
        return etiquetaDeSuplemento(s, _categorias);
      }
    }
    return 'Suplemento sin nombre';
  }

  String _nombrePersona(int? id) =>
      _personas[id] ?? 'Persona sin nombre';

  Future<void> _cargar() async {
    // 1.36 H-B3 (136-727): el reintento REACTIVA la carga —
    // antes _cargar nunca subía _cargando, el EstadoError
    // seguía visible durante la recarga y dos toques
    // solapaban cargas. La reentrada se bloquea con una
    // guarda propia (_enCurso: _cargando ya nace en true
    // para la primera carga de initState).
    if (_enCurso) return;
    _enCurso = true;
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = false;
      });
    } else {
      _cargando = true;
    }
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = true);
    } finally {
      _enCurso = false;
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final precios = await preciosServicios();
    final agua = await stockAguaLocal();
    final movsAgua =
        await LocalDb.instance.allMirror('servicio_agua_movimientos');
    final botes = await LocalDb.instance.allMirror('servicio_botes');
    // 1.15: pomos activos con su saldo local (el espejo ya trae
    // asignadas/repartidas; el saldo deriva espejo + pendientes).
    final pomos = await pomosActivosLocal();
    final suplementos =
        await LocalDb.instance.allMirror('suplementos');
    final categorias =
        await LocalDb.instance.allMirror('categorias_suplemento');
    // Personas conocidas (para titulares y nombres).
    // Argón Servicios #9: misma fuente que la pantalla
    // principal (meta usuarios_apk + respaldo indexado por
    // telegram_id). Antes esto escaneaba `pagos` y
    // `ventas_suplementos` COMPLETOS, y un entrenador sin
    // movimientos en esas tablas salía como «Entrenador»
    // genérico teniendo pomo asignado.
    final personas = <int, String>{};
    final miTid = AuthService().telegramId;
    if (miTid != null) personas[miTid] = 'Yo (dueño)';
    try {
      final rawApk = await LocalDb.instance.getMeta('usuarios_apk');
      if (rawApk != null && rawApk.isNotEmpty) {
        for (final u in jsonDecode(rawApk) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          final utid = LocalDb.normalizarTelegramId(m['telegram_id']);
          final nombre = '${m['nombre'] ?? ''}'.trim();
          if (utid != null && nombre.isNotEmpty) {
            personas.putIfAbsent(utid, () => nombre);
          }
        }
      }
    } catch (_) {}
    final titularesSinNombre = <int>{};
    for (final l in pomos) {
      final rt = LocalDb.normalizarTelegramId(l['titular_telegram_id']);
      if (rt != null && !personas.containsKey(rt)) {
        titularesSinNombre.add(rt);
      }
    }
    if (titularesSinNombre.isNotEmpty) {
      personas.addAll(await LocalDb.instance
          .nombresPorTelegramIds(titularesSinNombre));
    }
    // 1.29 (Oleada 4, FB-09 + D-11): peticiones de relleno
    // pendientes del espejo y la posición canónica de cada
    // entrenador para su color.
    final solicitudes =
        await SolicitudesRellenoService.instance.pendientesParaDueno();
    final indices = await indicesEntrenadores();
    if (!mounted) return;
    setState(() {
      _solicitudesRelleno = solicitudes;
      _indiceEntrenador = indices;
      _precios = precios;
      _agua = agua;
      _movsAgua = movsAgua;
      _botes = botes;
      _pomos = pomos;
      _suplementos = suplementos;
      // 1.36 H-B3 (136-760): selectores con la categoría
      // inactiva marcada.
      _categorias = mapaCategoriasSuplemento(categorias,
          marcarInactivas: true);
      _personas = personas;
      _cargando = false;
      _errorCarga = false;
    });
  }

  void _aviso(String msg, {bool error = false}) {
    if (!mounted) return;
    mostrarSnack(context, msg,
        significado:
            error ? SignificadoChip.error : SignificadoChip.neutral);
  }

  String _limpio(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  // ---------------------------------------------------------------
  // Precios
  // ---------------------------------------------------------------

  // ---------------------------------------------------------------
  // Agua
  // ---------------------------------------------------------------

  Future<void> _reponerAgua() async {
    if (_operando) return;
    _operando = true;
    try {
      await _reponerAguaInterno();
    } finally {
      _operando = false;
    }
  }

  Future<void> _reponerAguaInterno() async {
    // Ronda 3-9 #10: solo el dueño (ver _guardarGrupoPrecios).
    if (!AuthService().isOwner) return;
    final datos =
        await showDialog<({String cantidad, String costo})>(
      context: context,
      builder: (ctx) => const _DialogoReponerAgua(),
    );
    if (datos == null) return;
    // (1.36 H-A2 136-731) el costo se valida ANTES de encolar:
    // un costo no numérico, no finito o negativo se dice aquí
    // en vez de encolar un 0 que el servicio rechaza después.
    final costoCrudo =
        double.tryParse(datos.costo.trim().replaceAll(',', '.'));
    if (costoCrudo == null || !costoCrudo.isFinite || costoCrudo <= 0) {
      _aviso('El costo del agua no es válido: escribe un importe '
          'mayor que 0.', error: true);
      return;
    }
    try {
      await reponerAguaServicio(
        cantidad: int.tryParse(datos.cantidad.trim()) ?? 0,
        costoUnitario: costoCrudo,
      );
      _aviso('Entrada de agua registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  /// Ítem 11: salida sin venta del stock común de agua (solo el
  /// dueño la ve; el servidor la exige). Para pomos rotos, regalados
  /// o consumidos sin pasar por una venta.
  Future<void> _salidaAgua() async {
    if (_operando) return;
    _operando = true;
    try {
      await _salidaAguaInterno();
    } finally {
      _operando = false;
    }
  }

  Future<void> _salidaAguaInterno() async {
    // Ronda 3-9 #10: solo el dueño (ver _guardarGrupoPrecios).
    if (!AuthService().isOwner) return;
    final datos = await showDialog<
        ({String cantidad, String motivo, String nota})>(
      context: context,
      builder: (ctx) => _DialogoSalidaAgua(saldo: _agua.saldo),
    );
    if (datos == null) return;
    try {
      await registrarSalidaAguaServicio(
        cantidad: int.tryParse(datos.cantidad.trim()) ?? 0,
        motivo: datos.motivo,
        nota: datos.nota.trim().isEmpty ? null : datos.nota.trim(),
      );
      _aviso('Salida de agua registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  // ---------------------------------------------------------------
  // Pomos y botes (1.15)
  // ---------------------------------------------------------------

  Future<void> _abrirBote() async {
    if (_operando) return;
    _operando = true;
    try {
      await _abrirBoteInterno();
    } finally {
      _operando = false;
    }
  }

  Future<void> _abrirBoteInterno() async {
    // Ronda 3-9 #10: solo el dueño (ver _guardarGrupoPrecios).
    if (!AuthService().isOwner) return;
    if (_suplementos.isEmpty) {
      _aviso('No hay suplementos en el catálogo', error: true);
      return;
    }
    final datos = await showDialog<
        ({int supId, String rendimiento, String costo})>(
      context: context,
      builder: (ctx) => _DialogoAbrirBote(
        suplementos: _suplementos,
        categorias: _categorias,
      ),
    );
    if (datos == null) return;
    // (136-731) costo del bote: vacío = «sin costo nuevo»
    // (opcional legítimo); con texto, debe ser finito y > 0 —
    // antes un texto inválido se volvía null en silencio y el
    // bote se abría con el costo viejo sin que nadie lo supiera.
    final costoTexto = datos.costo.trim();
    final costo = costoTexto.isEmpty
        ? null
        : double.tryParse(costoTexto.replaceAll(',', '.'));
    if (costoTexto.isNotEmpty &&
        (costo == null || !costo.isFinite || costo <= 0)) {
      _aviso('El costo del bote no es válido: déjalo vacío o '
          'escribe un importe mayor que 0.', error: true);
      return;
    }
    try {
      await abrirBoteServicio(
        suplementoId: datos.supId,
        dosisRendimiento: int.tryParse(datos.rendimiento.trim()) ?? 0,
        costoBote: costo,
      );
      _aviso('Bote abierto: sus dosis van al pomo principal '
          '(se sincronizará)');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  /// 1.15 (pomos): rellenar el pomo de un entrenador desde el
  /// principal. Atajos 4/5 (pocas al inicio; 4-5 más cuando baja)
  /// + cantidad libre. El servidor mueve las dosis en una
  /// transacción y rechaza si el principal no alcanza.
  /// Devuelve true si el relleno quedó ENCOLADO (la op
  /// reponer_pomo se creó): la sección de solicitudes FB-09
  /// lo usa para ocultar al momento la petición atendida.
  Future<bool> _reponerPomo(Map<String, dynamic> pomo) async {
    if (_operando) return false;
    _operando = true;
    try {
      return await _reponerPomoInterno(pomo);
    } finally {
      _operando = false;
    }
  }

  Future<bool> _reponerPomoInterno(Map<String, dynamic> pomo) async {
    // Ronda 3-9 #10: solo el dueño (ver _guardarGrupoPrecios).
    if (!AuthService().isOwner) return false;
    final supId = (pomo['suplemento_id'] as num?)?.toInt();
    final principal = _pomos.where((l) =>
        (l['es_principal'] as num?)?.toInt() == 1 &&
        (l['suplemento_id'] as num?)?.toInt() == supId).toList();
    if (principal.isEmpty) {
      _aviso('No hay pomo principal para este producto', error: true);
      return false;
    }
    final saldoPrincipal = (principal.first['saldo_local'] as num?)?.toInt() ?? 0;
    // 1.29 (Oleada 4, barrido de diálogos): el diálogo es un
    // StatefulWidget dueño de su controlador (antes se creaba
    // en el método y NUNCA se disponía). Devuelve las dosis
    // por Navigator.pop; cancelar devuelve null.
    final dosis = await showDialog<int>(
      context: context,
      builder: (_) => _DialogoRellenarPomo(
        nombreTitular: _nombrePersona(
            (pomo['titular_telegram_id'] as num?)?.toInt()),
        saldoPrincipal: saldoPrincipal,
        saldoActual: pomo['saldo_local'],
      ),
    );
    if (dosis == null) return false;
    try {
      await reponerPomoServicio(
        pomoDestinoId: (pomo['id'] as num).toInt(),
        dosis: dosis,
      );
      _aviso('Pomo rellenado (se sincronizará)');
      await _cargar();
      return true;
    } catch (e) {
      _aviso(_limpio(e), error: true);
      return false;
    }
  }

  /// 1.15 (pomos): salida sin venta contra un pomo (merma,
  /// cortesía, consumo del staff, ajuste). Solo dueño.
  Future<void> _salidaPomo(Map<String, dynamic> pomo) async {
    if (_operando) return;
    _operando = true;
    try {
      await _salidaPomoInterno(pomo);
    } finally {
      _operando = false;
    }
  }

  Future<void> _salidaPomoInterno(Map<String, dynamic> pomo) async {
    // Ronda 3-9 #10: solo el dueño (ver _guardarGrupoPrecios).
    if (!AuthService().isOwner) return;
    // SL-7 (G06-2): UNA sola superficie de salida sin venta —
    // la hoja validada que usa Vender (HojaSalidaSinVenta).
    // El diálogo propio de Inventario aceptaba la cantidad
    // con tryParse ?? 0 y cerraba perdiendo lo tecleado si el
    // servicio rechazaba; la hoja valida dentro y no cierra.
    final res = await showModalBottomSheet<
        ({String motivo, int dosis, String? nota})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const HojaSalidaSinVenta(esDueno: true),
    );
    if (res == null) return;
    try {
      await registrarSalidaServicio(
        pomoId: (pomo['id'] as num).toInt(),
        dosis: res.dosis,
        motivo: res.motivo,
        nota: res.nota,
      );
      _aviso('Salida registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  // ---------------------------------------------------------------
  // Vista
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 1.31 (Mejoras · Inventario): esta pantalla ES la zona
    // Inventario del hub. Suelta conserva su Scaffold con el
    // título «Inventario» (antes «Servicios · Admin»); embebida
    // devuelve solo el cuerpo. Los precios ya no viven aquí:
    // son su propia pantalla («Precios y comisión»).
    if (!AuthService().isOwner) {
      const cuerpo = Center(
          child: Text('Solo el dueño administra los servicios.'));
      if (widget.embebida) return cuerpo;
      return Scaffold(
        appBar: appBarIron(context, 'Inventario'),
        body: cuerpo,
      );
    }
    final cuerpo = _cargando
        // 1.30 (Oleada D6, UI130-22): la carga de una
        // pantalla de ajustes enseña SU esqueleto
        // (grupos con filas), no el rótulo genérico.
        ? const SkeletonAjustes(grupos: 4)
        : _errorCarga
            ? EstadoError(
                titulo: 'No se pudo cargar el inventario',
                detalle: 'Revisa la conexión o vuelve a intentarlo.',
                onReintentar: _cargar,
              )
            : ListView(
            padding: const EdgeInsets.all(AppEspacio.lg),
            children: [
              _tarjetaIrPrecios(),
              const SizedBox(height: AppEspacio.md),
              _seccionSolicitudesRelleno(),
              _seccionAgua(),
              const SizedBox(height: AppEspacio.md),
              _seccionPomos(),
              const SizedBox(height: AppEspacio.md),
              _seccionBotes(),
            ],
          );
    if (widget.embebida) return cuerpo;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Inventario',
        acciones: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: cuerpo,
    );
  }

  /// 1.31 (Mejoras): tarjeta-puerta a «Precios y comisión»
  /// con los valores vigentes de un vistazo (sin abrirla se
  /// sabe cuánto cuesta todo hoy).
  Widget _tarjetaIrPrecios() {
    final p = _precios;
    return Tarjeta(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => const ServiciosPreciosScreen()),
        );
        if (mounted) await _cargar();
      },
      child: Row(
        children: [
          // Pasada (Argón): el atajo verde de la casa, no
          // Colors.green/lightGreen crudos.
          IconoModuloBadge.verde(Icons.payments_rounded),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Precios y comisión', style: AppTexto.titulo),
                Text(
                  p == null
                      ? '—'
                      : 'Dosis ${fmtMonto(p.sinAgua)} · '
                          'Dosis con agua ${fmtMonto(p.conAgua)} · '
                          'Agua ${fmtMonto(p.agua)} · '
                          'Comisión ${fmtMonto(p.comision)}',
                  style: AppTexto.secundario,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded,
              color: AppColores.textoSecundario(context)),
        ],
      ),
    );
  }

  /// 1.31 (Mejoras · Inventario): el agua es un BLOQUE
  /// propio con la anatomía de un pomo (antes una tarjeta
  /// compacta perdida entre secciones): saldo en métrica,
  /// costo promedio, precio de venta vigente, sus dos
  /// acciones y los últimos movimientos.
  Widget _seccionAgua() {
    final recientes = [..._movsAgua]
      ..sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
    final ultimos = recientes.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // 1.33 (diseño): este azul SE QUEDA — es el
            // azul semántico del AGUA de la casa (el del
            // gradiente dosis+agua y los tokens azulAgua),
            // contenido en su chip; solo se tokeniza el
            // tinte (era Colors.blue crudo) al token
            // exacto de la familia.
            const IconoModuloBadge(
              icono: Icons.water_drop_rounded,
              tinte: AppColores.azulAgua,
              iconoOscuro: AppColores.azulAguaOscuro,
              iconoClaro: AppColores.azulAguaClaro,
            ),
            const SizedBox(width: AppEspacio.sm),
            Text('Agua', style: AppTexto.titulo),
          ],
        ),
        const SizedBox(height: AppEspacio.sm),
        Tarjeta(
          padding: const EdgeInsets.all(AppEspacio.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${_agua.saldo}', style: AppTexto.metrica),
                  const SizedBox(width: AppEspacio.xs),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('pomos en stock',
                        style: AppTexto.secundario),
                  ),
                ],
              ),
              Text(
                'Costo promedio: ${fmtMonto(_agua.cpp)} CUP/pomo'
                '${_precios != null ? ' · Precio de venta: ${fmtMonto(_precios!.agua)} CUP' : ''}',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.sm),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _reponerAgua,
                      child: const Text('Reponer'),
                    ),
                  ),
                  const SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _salidaAgua,
                      child: const Text('Salida sin venta'),
                    ),
                  ),
                ],
              ),
              // 1.36 H-B3 (136-728): sin movimientos, la
              // sección lo DICE (antes quedaba muda).
              if (ultimos.isEmpty) ...[
                const SizedBox(height: AppEspacio.sm),
                Text('Sin movimientos de agua todavía.',
                    style: AppTexto.secundario.copyWith(
                        color: AppColores.textoSecundario(context))),
              ],
              if (ultimos.isNotEmpty) ...[
                const Divider(height: 24),
                Text('Últimos movimientos', style: AppTexto.metadato),
                const SizedBox(height: AppEspacio.xs),
                for (final m in ultimos)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: AppEspacio.xs),
                    child: Row(
                      children: [
                        Icon(
                          '${m['tipo']}' == 'entrada'
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          size: 14,
                          color: AppColores.textoSecundario(context),
                        ),
                        const SizedBox(width: AppEspacio.xs),
                        Expanded(
                          child: Text(
                            '${m['tipo']}' == 'entrada'
                                ? 'Reposición · ${m['cantidad']} pomos'
                                : 'Salida · ${m['cantidad']} pomos',
                            style: AppTexto.secundario,
                          ),
                        ),
                        Text(
                          () {
                            final f = '${m['fecha'] ?? ''}';
                            return f.length >= 10
                                ? fmtFecha(f.substring(0, 10))
                                : f;
                          }(),
                          style: AppTexto.metadato,
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // 1.30 D5 (UI130-17): el encabezado sale de la tarjeta y
  // cada bote es su propia fila-tarjeta con foto, estado
  // (chip) y acción. Siguen siendo historial, sin acciones
  // por fila (P3/P4).
  Widget _seccionBotes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Botes', style: AppTexto.titulo),
            ),
            FilledButton.icon(
              onPressed: _abrirBote,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Abrir bote'),
            ),
          ],
        ),
        const SizedBox(height: AppEspacio.sm),
        if (_botes.isEmpty)
          // 1.35 (UI-10): vacío de la casa en su forma de
          // sección; la acción («Abrir bote») ya vive en la
          // cabecera de la sección.
          const EstadoVacio(
            sinMarco: true,
            icono: Icons.science_rounded,
            titulo: 'Sin botes abiertos todavía',
            subtitulo:
                'Abre el primer bote con el botón de arriba para '
                'empezar a vender dosis de él.',
          )
        else
          for (var i = 0; i < _botes.length; i++) ...[
            _filaBote(_botes[i]),
            if (i < _botes.length - 1)
              const SizedBox(height: AppEspacio.sm),
          ],
      ],
    );
  }

  Widget _filaBote(Map<String, dynamic> b) {
    final sup = _supPorIdLocal((b['suplemento_id'] as num?)?.toInt());
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sup != null) ...[
            _FotoPomoAdmin(sup: sup),
            const SizedBox(width: AppEspacio.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_nombreSup((b['suplemento_id'] as num?)?.toInt()),
                    style: AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.w600)),
                Text(
                  'Rendimiento: ${b['dosis_rendimiento']} dosis · '
                  'Costo: ${fmtMonto(b['costo_bote'])} CUP'
                  '${b['diferencia_rendimiento_bote'] != null ? ' · Diferencia: ${b['diferencia_rendimiento_bote']}' : ''}',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppEspacio.sm),
          // 1.15 (P3/P4): los botes son historial; sin
          // «Crear lote» ni «Cerrar bote». El stock vivo está
          // en la sección Pomos; abrir un bote alimenta al
          // principal. El estado va como chip (D5).
          ChipEstado.semantico(
            // 1.36 H-B3 (136-728): sin estado, el chip dice
            // «—» en vez de quedar con el texto vacío.
            texto: '${b['estado'] ?? ''}'.trim().isEmpty
                ? '—'
                : '${b['estado']}',
            significado: b['estado'] == 'abierto'
                ? SignificadoChip.exito
                : SignificadoChip.neutral,
          ),
        ],
      ),
    );
  }

  /// F4-17: foto del producto del pomo con el punto semáforo
  /// del saldo en la esquina; sin suplemento, el icono de
  /// siempre.
  Widget _leadingPomo(Map<String, dynamic> l) {
    final sup =
        _supPorIdLocal((l['suplemento_id'] as num?)?.toInt());
    final color = _colorSaldoPomo(l['saldo_local']);
    if (sup == null) {
      return Icon(
        (l['es_principal'] as num?)?.toInt() == 1
            ? Icons.science_rounded
            : Icons.local_drink_rounded,
        color: AppColores.textoSecundario(context),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _FotoPomoAdmin(sup: sup),
        if (color != null)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                // 1.36 H-B3 (136-728): borde con el token de
                // superficie del tema, no Colors.white fijo.
                border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5),
              ),
            ),
          ),
      ],
    );
  }

  /// 1.29 (Oleada 4, FB-09): peticiones de relleno
  /// pendientes. Un toque en «Rellenar» abre el diálogo de
  /// relleno de ESE pomo; al encolar el relleno, la petición
  /// se oculta en esta pantalla (el espejo la seguirá
  /// mostrando pendiente hasta que el cierre baje por el
  /// pull). Sin peticiones, la sección no existe.
  Widget _seccionSolicitudesRelleno() {
    final visibles = [
      for (final s in _solicitudesRelleno)
        if (!_rellenoAtendidasLocal.contains(s.id)) s,
    ];
    if (visibles.isEmpty) {
      // G06-3 (desbloqueo lote 141): la regla de cero de Jc
      // (posterior a la decisión 1.31 de bandeja fija) manda
      // — sin solicitudes, la bandeja NO se dibuja: una fila
      // en cero no ocupa sitio permanente.
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        Tarjeta(
          padding: const EdgeInsets.all(AppEspacio.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconoPomo(
                      tamano: 24, color: AppColores.texto(context)),
                  const SizedBox(width: AppEspacio.sm),
                  Text('Solicitudes de relleno',
                      style: AppTexto.titulo),
                ],
              ),
              for (final s in visibles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      '${s.entrenadorNombre ?? _nombrePersona(s.entrenadorTelegramId)}'
                      ' · ${s.suplementoNombre ?? _nombreSup(s.suplementoId)}'),
                  subtitle: Text(
                      'Pidió relleno${s.creadoEn != null ? ' · ${fmtFecha(s.creadoEn)}' : ''}'),
                  trailing: FilledButton.tonal(
                    onPressed: () => _rellenarDesdeSolicitud(s),
                    child: const Text('Rellenar'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppEspacio.md),
      ],
    );
  }

  Future<void> _rellenarDesdeSolicitud(SolicitudRelleno s) async {
    final pomo = _pomos.where((l) =>
        (l['es_principal'] as num?)?.toInt() != 1 &&
        LocalDb.normalizarTelegramId(l['titular_telegram_id']) ==
            s.entrenadorTelegramId &&
        (l['suplemento_id'] as num?)?.toInt() == s.suplementoId);
    if (pomo.isEmpty) {
      _aviso('Ese pomo ya no está activo', error: true);
      return;
    }
    final ok = await _reponerPomo(pomo.first);
    if (ok && mounted) {
      setState(() => _rellenoAtendidasLocal.add(s.id));
    }
  }

  // 1.30 D5 (UI130-17): el encabezado sale de la tarjeta y
  // cada pomo es su propia fila-tarjeta (foto, estado y
  // acción), como los botes. El contenido de la fila — punto
  // del entrenador, saldo, medidor y acciones — no cambia.
  Widget _seccionPomos() {
    // Principal primero, luego entrenadores por nombre.
    final pomos = [..._pomos]
      ..sort((a, b) {
        final pa = (a['es_principal'] as num?)?.toInt() ?? 0;
        final pb = (b['es_principal'] as num?)?.toInt() ?? 0;
        if (pa != pb) return pb.compareTo(pa);
        return '${_nombrePersona((a['titular_telegram_id'] as num?)?.toInt())}'
            .compareTo(
                _nombrePersona((b['titular_telegram_id'] as num?)?.toInt()));
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1.29 (Oleada 4, D-10): el stock se encabeza con el
        // icono propio del pomo, no con la metáfora genérica.
        Row(
          children: [
            IconoPomo(tamano: 24, color: AppColores.texto(context)),
            const SizedBox(width: AppEspacio.sm),
            Text('Pomos', style: AppTexto.titulo),
          ],
        ),
        // 1.31 (Mejoras · Inventario): el encabezado resume
        // cuántos pomos hay y cuántos andan bajos (≤4, el
        // rojo del semáforo), sin abrir fila por fila.
        if (pomos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: Text(
              '${pomos.length} pomos · '
              '${pomos.where((l) => ((l['saldo_local'] as num?)?.toInt() ?? 99) <= 4).length} con pocas dosis',
              style: AppTexto.secundario,
            ),
          ),
        if (pomos.isEmpty)
          // 1.36 H-B3 (136-728): el vacío de pomos es el
          // EstadoVacio de la casa, no un Text plano.
          const EstadoVacio(
            sinMarco: true,
            icono: Icons.science_rounded,
            titulo: 'Sin pomos todavía',
            subtitulo: 'Abre un bote para tener el pomo principal.',
          )
        else
          for (var i = 0; i < pomos.length; i++) ...[
            _filaPomo(pomos[i]),
            if (i < pomos.length - 1)
              const SizedBox(height: AppEspacio.sm),
          ],
      ],
    );
  }

  Widget _filaPomo(Map<String, dynamic> l) {
    return Tarjeta(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // F4-17: la fila lleva la foto del producto y
          // el punto semáforo de su saldo.
          _leadingPomo(l),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1.29 (Oleada 4, D-11): el punto de color del
                // entrenador junto a su nombre (categórica por
                // posición en la lista canónica, siempre con
                // la palabra al lado: el color solo no dice
                // nada).
                Row(
                  children: [
                    if (_indiceEntrenador[LocalDb.normalizarTelegramId(
                            l['titular_telegram_id'])] !=
                        null) ...[
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColores.colorEntrenador(
                              context,
                              _indiceEntrenador[
                                  LocalDb.normalizarTelegramId(
                                      l['titular_telegram_id'])]!),
                        ),
                      ),
                      const SizedBox(width: AppEspacio.xs),
                    ],
                    Expanded(
                      child: Text(
                          '${(l['es_principal'] as num?)?.toInt() == 1 ? 'Principal' : _nombrePersona((l['titular_telegram_id'] as num?)?.toInt())} '
                          '· ${_nombreSup((l['suplemento_id'] as num?)?.toInt())}'),
                    ),
                  ],
                ),
                Text(
                  'Saldo: ${l['saldo_local'] ?? '—'} dosis · '
                  'Asignadas: ${l['dosis_asignadas'] ?? '—'}'
                  '${(l['es_principal'] as num?)?.toInt() == 1 ? ' · Repartidas: ${l['dosis_repartidas'] ?? 0}' : ''}',
                  // 1.36 H-B3 (136-728): métricas con el
                  // estilo de la casa y cifras TABULARES (antes
                  // estilo por defecto del Text).
                  style: AppTexto.conTabulares(AppTexto.cuerpo),
                ),
                // 1.25 T95: el medidor del pomo para el
                // dueño (saldo sobre asignadas, con el
                // color semáforo de T120): un pomo a
                // punto de agotarse ya no se ve igual
                // que uno lleno.
                if ((l['saldo_local'] as num?) != null &&
                    (l['dosis_asignadas'] as num?) != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppEspacio.xs),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadio.sm),
                      child: LinearProgressIndicator(
                        value: fraccionSaldoPomo(
                          saldo: (l['saldo_local'] as num?)?.toInt(),
                          asignadas:
                              (l['dosis_asignadas'] as num?)?.toInt(),
                        ),
                        minHeight: 6,
                        color: _colorSaldoPomo(l['saldo_local']) ??
                            AppColores.naranja,
                        backgroundColor:
                            AppColores.naranja.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if ((l['es_principal'] as num?)?.toInt() != 1)
                TextButton(
                  onPressed: () => _reponerPomo(l),
                  child: const Text('Rellenar'),
                ),
              TextButton(
                onPressed: () => _salidaPomo(l),
                child: const Text('Salida'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// F4-17: miniatura del producto de un pomo (mismo patrón de
/// resolución que la del catálogo: resolverFotoSuplemento).
class _FotoPomoAdmin extends StatefulWidget {
  final Map<String, dynamic> sup;
  const _FotoPomoAdmin({required this.sup});

  @override
  State<_FotoPomoAdmin> createState() => _FotoPomoAdminState();
}

class _FotoPomoAdminState extends State<_FotoPomoAdmin> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = resolverFotoSuplemento(widget.sup);
  }

  @override
  void didUpdateWidget(covariant _FotoPomoAdmin oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sup['id'] != widget.sup['id'] ||
        oldWidget.sup['foto_local'] != widget.sup['foto_local'] ||
        oldWidget.sup['foto_storage'] != widget.sup['foto_storage']) {
      _futura = resolverFotoSuplemento(widget.sup);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        final f = snap.data;
        if (f == null) {
          return Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColores.fondo(ctx),
              borderRadius: BorderRadius.circular(AppRadio.sm),
            ),
            child: Icon(Icons.medication_rounded,
                size: 20, color: AppColores.textoSecundario(ctx)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadio.sm),
          child: Image(
            image: providerFotoAcotada(FileImage(f), ancho: 128),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 40,
              height: 40,
              color: AppColores.fondo(ctx),
              child: Icon(Icons.medication_rounded,
                  size: 20, color: AppColores.textoSecundario(ctx)),
            ),
          ),
        );
      },
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): diálogo de rellenar
/// pomo como StatefulWidget DUEÑO de su controlador (patrón
/// de la casa: antes el controlador se creaba en el método
/// llamador y nunca se disponía). Devuelve las dosis por
/// Navigator.pop; cancelar devuelve null. Una dosis no
/// numérica devuelve 0 y la validación de siempre
/// (reponerPomoServicio) la rechaza con su aviso, igual que
/// antes.
class _DialogoRellenarPomo extends StatefulWidget {
  final String nombreTitular;
  final int saldoPrincipal;
  final Object? saldoActual;

  const _DialogoRellenarPomo({
    required this.nombreTitular,
    required this.saldoPrincipal,
    required this.saldoActual,
  });

  @override
  State<_DialogoRellenarPomo> createState() =>
      _DialogoRellenarPomoState();
}

class _DialogoRellenarPomoState extends State<_DialogoRellenarPomo> {
  final _dosisCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _dosisCtrl.dispose();
    super.dispose();
  }

  // 1.36 H-B1 (136-321): validación DENTRO del diálogo —
  // antes salía un 0 silencioso y el error caía fuera.
  void _rellenar() {
    final d = int.tryParse(_dosisCtrl.text.trim());
    if (d == null || d <= 0) {
      setState(() =>
          _error = 'Escribe las dosis: un número mayor que 0.');
      return;
    }
    if (d > widget.saldoPrincipal) {
      setState(() => _error =
          'El principal solo tiene ${widget.saldoPrincipal} dosis.');
      return;
    }
    Navigator.pop(context, d);
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Rellenar pomo · ${widget.nombreTitular}',
      iconoTitulo: Icons.add_circle_outline_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Principal: ${widget.saldoPrincipal} dosis · '
            'Pomo actual: ${widget.saldoActual ?? '—'} dosis. '
            'Se mueven del principal al pomo.',
            style: AppTexto.cuerpo,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final atajo in const [4, 5])
                Padding(
                  padding: const EdgeInsets.only(right: AppEspacio.sm),
                  child: OutlinedButton(
                    onPressed: () =>
                        setState(() => _dosisCtrl.text = '$atajo'),
                    child: Text('$atajo dosis'),
                  ),
                ),
            ],
          ),
          TextField(
            controller: _dosisCtrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
                labelText: 'Dosis a rellenar', errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _rellenar,
          child: const Text('Rellenar'),
        ),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Reponer agua» como
/// StatefulWidget propio: posee y dispone sus controladores
/// (antes se creaban en el método y nunca se liberaban).
/// Devuelve los textos al registrar o null si se cancela.
class _DialogoReponerAgua extends StatefulWidget {
  const _DialogoReponerAgua();

  @override
  State<_DialogoReponerAgua> createState() =>
      _DialogoReponerAguaState();
}

class _DialogoReponerAguaState extends State<_DialogoReponerAgua> {
  final _cantCtrl = TextEditingController();
  final _costoCtrl = TextEditingController();
  String? _errorCant;
  String? _errorCosto;

  @override
  void dispose() {
    _cantCtrl.dispose();
    _costoCtrl.dispose();
    super.dispose();
  }

  // 1.36 H-B1 (136-321): validación dentro del diálogo.
  void _registrar() {
    final cant = int.tryParse(_cantCtrl.text.trim());
    final costo =
        double.tryParse(_costoCtrl.text.trim().replaceAll(',', '.'));
    setState(() {
      _errorCant = (cant == null || cant <= 0)
          ? 'Escribe los pomos que entraron (mayor que 0).'
          : null;
      _errorCosto =
          (costo == null || !costo.isFinite || costo <= 0)
              ? 'Escribe el costo por pomo (mayor que 0).'
              : null;
    });
    if (_errorCant != null || _errorCosto != null) return;
    Navigator.pop(context,
        (cantidad: _cantCtrl.text, costo: _costoCtrl.text));
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Reponer agua',
      iconoTitulo: Icons.water_drop_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _cantCtrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
                labelText: 'Pomos que entraron',
                errorText: _errorCant),
          ),
          TextField(
            controller: _costoCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Costo por pomo (CUP)',
                errorText: _errorCosto),
          ),
          const SizedBox(height: 8),
          Text(
            'El costo alimenta el costo promedio (CPP) con el que '
            'se valoriza cada venta con agua.',
            // 1.36 H-B3 (136-728): token de texto de la casa,
            // no Colors.grey crudo.
            style: AppTexto.metadato.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _registrar,
          child: const Text('Registrar entrada'),
        ),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Salida de agua sin
/// venta» como StatefulWidget propio: posee y dispone sus
/// controladores y el motivo (antes vivían en el método y
/// los controladores nunca se liberaban). Devuelve los
/// datos al registrar o null si se cancela.
class _DialogoSalidaAgua extends StatefulWidget {
  final int saldo;
  const _DialogoSalidaAgua({required this.saldo});

  @override
  State<_DialogoSalidaAgua> createState() =>
      _DialogoSalidaAguaState();
}

class _DialogoSalidaAguaState extends State<_DialogoSalidaAgua> {
  var _motivo = 'merma';
  final _cantCtrl = TextEditingController(text: '1');
  final _notaCtrl = TextEditingController();
  String? _errorCant;

  // 1.36 H-B1 (136-321): validación dentro del diálogo.
  void _registrar() {
    final cant = int.tryParse(_cantCtrl.text.trim());
    if (cant == null || cant <= 0) {
      setState(() =>
          _errorCant = 'Escribe los pomos (mayor que 0).');
      return;
    }
    if (cant > widget.saldo) {
      setState(() => _errorCant =
          'Solo hay ${widget.saldo} pomos en stock.');
      return;
    }
    Navigator.pop(context, (
      cantidad: _cantCtrl.text,
      motivo: _motivo,
      nota: _notaCtrl.text,
    ));
  }

  @override
  void dispose() {
    _cantCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Salida de agua sin venta',
      iconoTitulo: Icons.water_drop_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Stock actual: ${widget.saldo} pomos. La salida queda '
            'registrada con su motivo y descuenta del inventario.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 8),
          SelectorIronForm<String>(
            valorInicial: _motivo,
            etiqueta: 'Motivo',
            opciones: const [
              OpcionSelector('merma', 'Merma / rotura'),
              OpcionSelector('cortesia', 'Cortesía'),
              OpcionSelector('consumo_staff', 'Consumo del staff'),
              OpcionSelector('ajuste', 'Ajuste'),
            ],
            alCambiar: (v) =>
                setState(() => _motivo = v ?? 'merma'),
          ),
          TextField(
            controller: _cantCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'Pomos', errorText: _errorCant),
          ),
          TextField(
            controller: _notaCtrl,
            decoration: const InputDecoration(
                labelText: 'Nota (opcional)'),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _registrar,
          child: const Text('Registrar salida'),
        ),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Abrir bote de
/// servicio» como StatefulWidget propio: posee y dispone
/// sus controladores y el producto elegido (antes vivían en
/// el método y los controladores nunca se liberaban).
/// Devuelve los datos al abrir o null si se cancela.
class _DialogoAbrirBote extends StatefulWidget {
  final List<Map<String, dynamic>> suplementos;
  final Map<int, String> categorias;
  const _DialogoAbrirBote(
      {required this.suplementos, required this.categorias});

  @override
  State<_DialogoAbrirBote> createState() =>
      _DialogoAbrirBoteState();
}

class _DialogoAbrirBoteState extends State<_DialogoAbrirBote> {
  late int _supId;
  final _rendCtrl = TextEditingController(text: '30');
  final _costoCtrl = TextEditingController();
  String? _errorRend;
  String? _errorCosto;

  // 1.36 H-B1 (136-321): validación dentro del diálogo
  // (el costo vacío sigue siendo «sin costo nuevo»).
  void _abrir() {
    final rend = int.tryParse(_rendCtrl.text.trim());
    final costoTexto = _costoCtrl.text.trim();
    final costo = costoTexto.isEmpty
        ? null
        : double.tryParse(costoTexto.replaceAll(',', '.'));
    setState(() {
      _errorRend = (rend == null || rend <= 0)
          ? 'Escribe el rendimiento (dosis mayor que 0).'
          : null;
      _errorCosto = (costoTexto.isNotEmpty &&
              (costo == null || !costo.isFinite || costo <= 0))
          ? 'Costo no válido: déjalo vacío o mayor que 0.'
          : null;
    });
    if (_errorRend != null || _errorCosto != null) return;
    Navigator.pop(context, (
      supId: _supId,
      rendimiento: _rendCtrl.text,
      costo: _costoCtrl.text,
    ));
  }

  @override
  void initState() {
    super.initState();
    _supId = (widget.suplementos.first['id'] as num).toInt();
  }

  @override
  void dispose() {
    _rendCtrl.dispose();
    _costoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Abrir bote de servicio',
      iconoTitulo: Icons.science_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectorIronForm<int>(
            valorInicial: _supId,
            etiqueta: 'Producto',
            opciones: [
              for (final s in widget.suplementos)
                OpcionSelector(
                  (s['id'] as num).toInt(),
                  etiquetaDeSuplemento(s, widget.categorias),
                ),
            ],
            alCambiar: (v) => setState(() => _supId = v ?? _supId),
          ),
          TextField(
            controller: _rendCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'Rendimiento (dosis del bote)',
                errorText: _errorRend),
          ),
          TextField(
            controller: _costoCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            decoration: InputDecoration(
                labelText:
                    'Costo del bote (CUP, opcional si el producto ya tiene costo)',
                errorText: _errorCosto),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _abrir,
          child: const Text('Abrir bote'),
        ),
      ],
    );
  }
}
