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
import 'servicios_precios.dart';
import 'skeleton.dart';

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
    return 'Suplemento #$id';
  }

  String _nombrePersona(int? id) =>
      _personas[id] ?? 'Persona #$id';

  Future<void> _cargar() async {
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
      _categorias = mapaCategoriasSuplemento(categorias);
      _personas = personas;
      _cargando = false;
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
    try {
      // Clase N-2 (#2): lo no finito cae al 0 «inválido» que el
      // servicio ya rechaza (NaN pasaba su validación <= 0).
      final costoCrudo =
          double.tryParse(datos.costo.trim().replaceAll(',', '.'));
      await reponerAguaServicio(
        cantidad: int.tryParse(datos.cantidad.trim()) ?? 0,
        costoUnitario:
            (costoCrudo != null && costoCrudo.isFinite) ? costoCrudo : 0,
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
    try {
      final costo =
          double.tryParse(datos.costo.trim().replaceAll(',', '.'));
      await abrirBoteServicio(
        suplementoId: datos.supId,
        dosisRendimiento: int.tryParse(datos.rendimiento.trim()) ?? 0,
        costoBote: (costo != null && costo > 0) ? costo : null,
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
    // 1.29 (Oleada 4, barrido de diálogos): StatefulWidget
    // dueño de sus controladores (antes se creaban en el
    // método y NUNCA se disponían). Devuelve los valores por
    // Navigator.pop; cancelar devuelve null.
    final res = await showDialog<({int dosis, String motivo, String? nota})>(
      context: context,
      builder: (_) => _DialogoSalidaPomo(
        nombreTitular: _nombrePersona(
            (pomo['titular_telegram_id'] as num?)?.toInt()),
        saldoActual: pomo['saldo_local'],
      ),
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
          const IconoModuloBadge(
            icono: Icons.payments_rounded,
            tinte: Colors.green,
            iconoOscuro: Colors.green,
            iconoClaro: Colors.lightGreen,
          ),
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
            const IconoModuloBadge(
              icono: Icons.water_drop_rounded,
              tinte: Colors.blue,
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
          Text('Sin botes abiertos todavía.',
              style: AppTexto.cuerpo
                  .copyWith(color: AppColores.textoSecundario(context)))
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
            texto: '${b['estado'] ?? ''}',
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
                border: Border.all(color: Colors.white, width: 1.5),
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
      // 1.31 (Mejoras · Inventario): la bandeja es FIJA — sin
      // peticiones también se ve (antes la sección entera
      // desaparecía y «¿dónde caen los pedidos?» no tenía
      // respuesta en la pantalla).
      return Column(
        children: [
          Tarjeta(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: Row(
              children: [
                IconoPomo(
                    tamano: 24, color: AppColores.texto(context)),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Solicitudes de relleno',
                          style: AppTexto.titulo),
                      Text('Sin solicitudes de relleno',
                          style: AppTexto.secundario),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppEspacio.md),
        ],
      );
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
                      'Pidió relleno${s.creadoEn != null ? ' · ${s.creadoEn!.split('T').first}' : ''}'),
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
          Text('Sin pomos todavía: abre un bote para tener principal.',
              style: AppTexto.cuerpo
                  .copyWith(color: AppColores.textoSecundario(context)))
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

  @override
  void dispose() {
    _dosisCtrl.dispose();
    super.dispose();
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
            decoration:
                const InputDecoration(labelText: 'Dosis a rellenar'),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, int.tryParse(_dosisCtrl.text.trim()) ?? 0),
          child: const Text('Rellenar'),
        ),
      ],
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): diálogo de salida
/// sin venta como StatefulWidget dueño de sus controladores
/// (antes se creaban en el método llamador y nunca se
/// disponían). Devuelve (dosis, motivo, nota) por
/// Navigator.pop; cancelar devuelve null.
class _DialogoSalidaPomo extends StatefulWidget {
  final String nombreTitular;
  final Object? saldoActual;

  const _DialogoSalidaPomo({
    required this.nombreTitular,
    required this.saldoActual,
  });

  @override
  State<_DialogoSalidaPomo> createState() => _DialogoSalidaPomoState();
}

class _DialogoSalidaPomoState extends State<_DialogoSalidaPomo> {
  final _dosisCtrl = TextEditingController(text: '1');
  final _notaCtrl = TextEditingController();
  String _motivo = 'merma';

  @override
  void dispose() {
    _dosisCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Salida sin venta · ${widget.nombreTitular}',
      iconoTitulo: Icons.outbox_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Saldo del pomo: ${widget.saldoActual ?? '—'} dosis.',
            style: AppTexto.cuerpo,
          ),
          DropdownButtonFormField<String>(
            value: _motivo,
            decoration: const InputDecoration(labelText: 'Motivo'),
            items: const [
              DropdownMenuItem(
                  value: 'merma', child: Text('Merma / rotura')),
              DropdownMenuItem(
                  value: 'cortesia', child: Text('Cortesía')),
              DropdownMenuItem(
                  value: 'consumo_staff',
                  child: Text('Consumo del staff')),
              DropdownMenuItem(
                  value: 'ajuste', child: Text('Ajuste')),
            ],
            onChanged: (v) => setState(() => _motivo = v ?? 'merma'),
          ),
          TextField(
            controller: _dosisCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Dosis'),
          ),
          TextField(
            controller: _notaCtrl,
            decoration:
                const InputDecoration(labelText: 'Nota (opcional)'),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
                dosis: int.tryParse(_dosisCtrl.text.trim()) ?? 0,
                motivo: _motivo,
                nota: _notaCtrl.text.trim().isEmpty
                    ? null
                    : _notaCtrl.text.trim(),
              )),
          child: const Text('Registrar salida'),
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

  @override
  void dispose() {
    _cantCtrl.dispose();
    _costoCtrl.dispose();
    super.dispose();
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
            decoration: const InputDecoration(
                labelText: 'Pomos que entraron'),
          ),
          TextField(
            controller: _costoCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Costo por pomo (CUP)'),
          ),
          const SizedBox(height: 8),
          Text(
            'El costo alimenta el costo promedio (CPP) con el que '
            'se valoriza cada venta con agua.',
            style: AppTexto.metadato.copyWith(color: Colors.grey),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context,
              (cantidad: _cantCtrl.text, costo: _costoCtrl.text)),
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
          DropdownButtonFormField<String>(
            value: _motivo,
            decoration: const InputDecoration(labelText: 'Motivo'),
            items: const [
              DropdownMenuItem(
                  value: 'merma', child: Text('Merma / rotura')),
              DropdownMenuItem(
                  value: 'cortesia', child: Text('Cortesía')),
              DropdownMenuItem(
                  value: 'consumo_staff',
                  child: Text('Consumo del staff')),
              DropdownMenuItem(
                  value: 'ajuste', child: Text('Ajuste')),
            ],
            onChanged: (v) =>
                setState(() => _motivo = v ?? 'merma'),
          ),
          TextField(
            controller: _cantCtrl,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Pomos'),
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
          onPressed: () => Navigator.pop(context, (
                cantidad: _cantCtrl.text,
                motivo: _motivo,
                nota: _notaCtrl.text,
              )),
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
          DropdownButtonFormField<int>(
            value: _supId,
            decoration: const InputDecoration(labelText: 'Producto'),
            items: [
              for (final s in widget.suplementos)
                DropdownMenuItem(
                  value: (s['id'] as num).toInt(),
                  child:
                      Text(etiquetaDeSuplemento(s, widget.categorias)),
                ),
            ],
            onChanged: (v) => setState(() => _supId = v ?? _supId),
          ),
          TextField(
            controller: _rendCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Rendimiento (dosis del bote)'),
          ),
          TextField(
            controller: _costoCtrl,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            decoration: const InputDecoration(
                labelText:
                    'Costo del bote (CUP, opcional si el producto ya tiene costo)'),
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
                supId: _supId,
                rendimiento: _rendCtrl.text,
                costo: _costoCtrl.text,
              )),
          child: const Text('Abrir bote'),
        ),
      ],
    );
  }
}
