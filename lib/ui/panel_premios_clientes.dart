import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../premios_panel.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'logros_premio_ui.dart';
import 'panel_premios.dart';
import 'skeleton.dart';

/// Premios (1.27, S3/G3): pestaña «Clientes» del hub —
/// buscador sobre el espejo local y, por cliente, el
/// detalle del servidor (S3): progreso del ciclo con
/// barra, historial completo de vales, sesiones que
/// sumaron, sello de logros (S5) y reinicios (S6).
/// Acciones del dueño: conceder un vale manual (S4,
/// entra en la bandeja y se aprueba con el mismo
/// botón) y reiniciar el ciclo (S6). Todo por RPC
/// directa con timeout: no mueve dinero al momento.
/// Inyectables para los tests, como el resto del hub.
class PremiosClientesTab extends StatefulWidget {
  final Future<List<({int id, String nombre, String telefono})>>
      Function()? buscarClientes;
  final Future<Map<String, dynamic>> Function(int clienteId)?
      cargarDetalle;
  final Future<List<EntradaCatalogoPremio>> Function()?
      cargarCatalogo;
  final Future<Map<String, dynamic>> Function(int clienteId,
      String logroId, int premioDias, String nota)? concederVale;
  final Future<Map<String, dynamic>> Function(
      int clienteId, String nota)? reiniciarCiclo;

  /// S7: anular un vale canjeado (encola la op; el
  /// servidor recalcula y revierte el pago).
  final Future<void> Function(int clienteId, ValeHistorial vale,
      String modo, int diasQuitables, String nota)? anularVale;
  final Future<String?> Function(int clienteId)? pagadoHastaDe;
  final Future<bool> Function(int valeId)? anulacionEnCursoDe;

  const PremiosClientesTab(
      {super.key,
      this.buscarClientes,
      this.cargarDetalle,
      this.cargarCatalogo,
      this.concederVale,
      this.reiniciarCiclo,
      this.anularVale,
      this.pagadoHastaDe,
      this.anulacionEnCursoDe});

  @override
  State<PremiosClientesTab> createState() => _PremiosClientesTabState();
}

class _PremiosClientesTabState extends State<PremiosClientesTab> {
  final _busquedaCtrl = TextEditingController();
  List<({int id, String nombre, String telefono})> _todos = const [];
  bool _cargandoClientes = true;
  bool _falloClientes = false;
  int? _seleccionadoId;
  String _seleccionadoNombre = '';
  DetallePremiosCliente? _detalle;
  bool _cargandoDetalle = false;
  bool _falloDetalle = false;
  String? _pagadoHasta;
  Set<int> _anulacionesEnCurso = {};

  /// 1.28 (M5-B6): cuántos vales del historial se
  /// enseñan (el resto llega con «Ver más»).
  int _historialLimite = 15;

  // H-01 (Argón 1.27): candado anti doble-toque de las
  // acciones del detalle (patrón _resolviendo de la
  // Bandeja): check-and-set SÍNCRONO antes del primer
  // await; un doble toque apilaba dos diálogos.
  bool _operando = false;

  // 1.28 (M5-A4 ★/R2M5-H-02): token de secuencia del
  // detalle — abrir el detalle de B mientras la foto de
  // A aún viaja ya no puede pintar el detalle de A sobre
  // B (cada apertura/recarga captura su generación y el
  // id; un resultado cuya generación o id ya no mandan
  // se descarta).
  int _genDetalle = 0;

  @override
  void initState() {
    super.initState();
    _cargarClientes();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<List<({int id, String nombre, String telefono})>>
      _buscarReal() async {
    final filas = await LocalDb.instance.allMirror('clientes');
    final out = <({int id, String nombre, String telefono})>[];
    for (final m in filas) {
      // H-04 (Argón 1.27): las cáscaras de clientes
      // eliminados no son personas: fuera del buscador,
      // como en el resto de listas de la casa.
      if (esClienteEliminado(m)) continue;
      final id = (m['id'] as num?)?.toInt() ??
          int.tryParse('${m['id'] ?? ''}');
      if (id == null) continue;
      out.add((
        id: id,
        nombre: '${m['nombre'] ?? 'Cliente'}',
        telefono: '${m['telefono'] ?? ''}',
      ));
    }
    out.sort((a, b) => a.nombre.compareTo(b.nombre));
    return out;
  }

  Future<Map<String, dynamic>> _detalleReal(int clienteId) async {
    final res = await Supabase.instance.client.rpc(
      'admin_premios_cliente',
      params: {'p_cliente_id': clienteId},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<List<EntradaCatalogoPremio>> _catalogoReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_premios_catalogo')
        .timeout(const Duration(seconds: 12));
    return parseCatalogoPremios(res);
  }

  Future<Map<String, dynamic>> _concederReal(int clienteId,
      String logroId, int premioDias, String nota) async {
    final res = await Supabase.instance.client.rpc(
      'admin_crear_vale_manual',
      params: {
        'p_cliente_id': clienteId,
        'p_logro_id': logroId,
        'p_premio_dias': premioDias,
        'p_nota': nota,
      },
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<Map<String, dynamic>> _reiniciarReal(
      int clienteId, String nota) async {
    final res = await Supabase.instance.client.rpc(
      'admin_reiniciar_ciclo_premio',
      params: {'p_cliente_id': clienteId, 'p_nota': nota},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<void> _cargarClientes() async {
    try {
      final todos =
          await (widget.buscarClientes ?? _buscarReal)();
      if (!mounted) return;
      setState(() {
        _todos = todos;
        _cargandoClientes = false;
        _falloClientes = false;
      });
    } catch (e) {
      // Yunque de App 1.31 (C1-5): el fallo queda en bitácora
      // en vez de leerse como «no hay clientes con premios».
      AppLog.error('premios_clientes', 'cargar_clientes_fallo',
          d: '$e');
      // (1.36 H-B4 136-964) y se VE: error con reintento.
      if (mounted) {
        setState(() {
          _cargandoClientes = false;
          _falloClientes = true;
        });
      }
    }
  }

  Future<String?> _pagadoHastaReal(int clienteId) async {
    final filas =
        await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
    if (filas.isEmpty) return null;
    return filas.first['pagado_hasta'] as String?;
  }

  Future<bool> _enCursoReal(int valeId) async {
    final opUuid = await LocalDb.instance
        .getMeta('premio_vale_anulado_$valeId');
    if (opUuid == null) return false;
    // 1.28 (M5-A3 ★/C-R1M5-H1): la marca se RECONCILIA
    // con el estado real de su op (las dobles inyectadas
    // de los tests saltan esta vía: la reconciliación
    // vive solo en la real). Si el servidor RECHAZÓ la
    // anulación, la marca se borra y el vale vuelve a
    // ser anulable (antes quedaba «en curso» para
    // siempre en este teléfono). Si la op ya se APLICÓ,
    // la anulación se da por hecha: marca fuera y el
    // detalle fresco del servidor manda (ya no lo lista
    // como canjeado). En vuelo o en revisión: sigue en
    // curso — la revisión no libera la marca.
    final estado = await LocalDb.instance.estadoOp(opUuid);
    if (estado == 'rechazada' || estado == 'aplicada') {
      await LocalDb.instance
          .borrarMeta('premio_vale_anulado_$valeId');
      return false;
    }
    return true;
  }

  /// S7 real: encola la op de anulación (el servidor
  /// recalcula los días y revierte el pago), marca el
  /// vale como «en curso» en este teléfono y ajusta el
  /// espejo como avance (el pull lo confirma).
  Future<void> _anularReal(int clienteId, ValeHistorial vale,
      String modo, int diasQuitables, String nota) async {
    // H-01 (Argón 1.27): si este teléfono ya encoló la
    // anulación de este vale, no se encola otra: la
    // marca meta sobrevive a matar la app entre el
    // queueOp y el setMeta, y a que el detalle se
    // recargue con la foto vieja del servidor.
    if (await _enCursoReal(vale.id)) return;
    final opUuid = const Uuid().v4();
    // Nota (Argón, delta 1.27): en modo «completo»
    // el espejo resta premioDias lineal, aunque parte
    // del vale ya se hubiera consumido; el servidor
    // recalcula el vencimiento desde el último pago
    // real, así que la foto local puede diferir unos
    // días hasta que el pull inmediato la confirme.
    // Lo que manda es la op: k viaja en el payload y
    // el servidor lo verifica contra su propio cálculo.
    final k = modo == 'completo' ? vale.premioDias : diasQuitables;
    // 1.28 (M5-A3 ★/C-R2M5-H4): el avance del espejo se
    // calcula contra el pagado_hasta FRESCO del espejo,
    // no contra el de cuando se abrió el detalle (un
    // pago sincronizado en medio corría la resta sobre
    // una base vieja).
    String? hastaFresco;
    try {
      final filas = await LocalDb.instance
          .mirrorPorIds('clientes', [clienteId]);
      if (filas.isNotEmpty) {
        hastaFresco = filas.first['pagado_hasta'] as String?;
      }
    } catch (_) {}
    // 1.28 (M5-A3 ★): op + marca + avance del espejo en
    // UNA transacción (antes iban sueltos: morir entre
    // el queueOp y el setMeta dejaba la op sin marca —
    // solo la guarda H-01 de arriba salvaba el reintento
    // — y el espejo podía quedar corrido sin op). Dentro
    // de la transacción no se lee por LocalDb.db.
    final d = await LocalDb.instance.db;
    await d.transaction((txn) async {
      // Ajuste Argón 1.28 (hallazgo #1): dentro de la
      // transacción se opera SOLO contra txn vía los
      // núcleos con ejecutor explícito (queueOpEn /
      // setMetaEn / updateMirrorPagadoHastaEn), que no
      // conocen el getter db: la garantía anti-deadlock
      // es estructural, no de disciplina del llamador.
      await LocalDb.instance.queueOpEn(
        txn,
        opUuid: opUuid,
        tipo: 'anular_vale_premio',
        payload: {
          'cliente_id': clienteId,
          'vale_id': vale.id,
          'modo': modo,
          'dias_quitados': k,
          'nota': nota,
        },
      );
      await LocalDb.instance
          .setMetaEn(txn, 'premio_vale_anulado_${vale.id}', opUuid);
      if (k > 0 && hastaFresco != null) {
        // H-01 (Argón 1.27): aritmética UTC pura
        // (sumarDiasIso). Restar un Duration a un
        // DateTime en hora local cruza el cambio de
        // horario de Cuba y puede correr el espejo un
        // día de más que el servidor.
        if (DateTime.tryParse(hastaFresco) != null) {
          await LocalDb.instance.updateMirrorPagadoHastaEn(
            txn,
            clienteId,
            sumarDiasIso(hastaFresco, -k),
          );
        }
      }
    });
    unawaited(SyncEngine.instance.push());
  }

  /// Datos locales de apoyo del detalle (vencimiento
  /// del espejo y marcas de anulación en curso). Si el
  /// espejo local falla, el detalle del servidor se
  /// muestra igual, solo sin el botón de anular afinado.
  Future<({String? hasta, Set<int> enCurso})> _apoyosDe(
      int id, DetallePremiosCliente detalle) async {
    String? hasta;
    try {
      hasta = await (widget.pagadoHastaDe ?? _pagadoHastaReal)(id);
    } catch (_) {}
    final enCurso = <int>{};
    for (final v in detalle.vales) {
      if (!v.canjeado) continue;
      try {
        if (await (widget.anulacionEnCursoDe ?? _enCursoReal)(v.id)) {
          enCurso.add(v.id);
        }
      } catch (_) {}
    }
    return (hasta: hasta, enCurso: enCurso);
  }

  /// ¿Sigue mandando la apertura/recarga que capturó
  /// [gen] para el cliente [id]? (M5-A4/R2M5-H-02.)
  bool _detalleVigente(int gen, int id) =>
      mounted && gen == _genDetalle && _seleccionadoId == id;

  Future<void> _abrirDetalle(
      ({int id, String nombre, String telefono}) c) async {
    final gen = ++_genDetalle;
    setState(() {
      _seleccionadoId = c.id;
      _seleccionadoNombre = c.nombre;
      _cargandoDetalle = true;
      _falloDetalle = false;
      _detalle = null;
      _pagadoHasta = null;
      _anulacionesEnCurso = {};
      // 1.28 (M5-B6): el historial vuelve a su primera
      // página al abrir otro cliente.
      _historialLimite = 15;
    });
    try {
      final json =
          await (widget.cargarDetalle ?? _detalleReal)(c.id);
      if (!_detalleVigente(gen, c.id)) return;
      // 1.28 (M5-A2 ★/C-R1M5-H3): un {ok:false} del
      // servidor (p. ej. cliente_no_existe) NO es un
      // detalle vacío: el parser lo degradaba a «vacío»
      // y la pantalla ofrecía conceder/reiniciar sobre
      // un cliente fantasma. Es un fallo de carga.
      if (json['ok'] != true) {
        setState(() {
          _cargandoDetalle = false;
          _falloDetalle = true;
        });
        return;
      }
      final detalle = parseDetallePremiosCliente(json);
      final apoyos = await _apoyosDe(c.id, detalle);
      if (!_detalleVigente(gen, c.id)) return;
      setState(() {
        _detalle = detalle;
        _pagadoHasta = apoyos.hasta;
        _anulacionesEnCurso = apoyos.enCurso;
        _cargandoDetalle = false;
      });
    } catch (_) {
      if (_detalleVigente(gen, c.id)) {
        setState(() {
          _cargandoDetalle = false;
          _falloDetalle = true;
        });
      }
    }
  }

  Future<void> _recargarDetalle() async {
    final id = _seleccionadoId;
    if (id == null) return;
    // 1.28 (M5-A4): la recarga captura la generación
    // vigente (sin incrementarla: compite en igualdad
    // con la apertura que la trajo) y descarta su foto
    // si el dueño ya abrió otro cliente.
    final gen = _genDetalle;
    try {
      final json =
          await (widget.cargarDetalle ?? _detalleReal)(id);
      if (!_detalleVigente(gen, id)) return;
      if (json['ok'] != true) return;
      final detalle = parseDetallePremiosCliente(json);
      // 1.28 (M5-A3/C-R1M5-H2): la recarga refresca
      // TAMBIÉN los apoyos (vencimiento y anulaciones en
      // curso): un vale anulado desde otro teléfono
      // dejaba de ofrecer «Anular vale» sin salir del
      // detalle, y un pagado_hasta nuevo se usa fresco.
      final apoyos = await _apoyosDe(id, detalle);
      if (!_detalleVigente(gen, id)) return;
      setState(() {
        _detalle = detalle;
        _pagadoHasta = apoyos.hasta;
        _anulacionesEnCurso = apoyos.enCurso;
      });
    } catch (e) {
      // (1.36 H-B4 136-964) una recarga de detalle que
      // falla AVISA: el detalle en pantalla puede estar
      // viejo (antes el catch era mudo).
      AppLog.error('premios_clientes', 'recargar_detalle_fallo',
          d: '$e');
      if (_detalleVigente(gen, id)) {
        mostrarSnack(context,
            'No se pudo actualizar el detalle: se muestra '
            'la última foto cargada.',
            significado: SignificadoChip.alerta);
      }
    }
  }

  /// Corrección A4-D4 (auditorías 1.28): conceder con
  /// comprobación tras un fallo de transporte. Un
  /// timeout de la RPC puede esconder un vale YA creado
  /// en el servidor (la respuesta se perdió), y el
  /// diálogo abierto invitaba a reintentarlo y
  /// duplicarlo en la Bandeja. Ante la excepción se
  /// recarga el detalle del cliente:
  /// - apareció un vale NUEVO con el mismo logro y días
  ///   → se devuelve ok (el flujo sigue como éxito);
  /// - el detalle cargó y no hay vale nuevo → se
  ///   relanza la excepción (el «sin conexión» del
  ///   diálogo ya es honesto);
  /// - ni el detalle pudo cargar → se devuelve un
  ///   mensaje SIN_CONFIRMAR: el diálogo dice que no se
  ///   sabe y que se revise la Bandeja antes de repetir.
  Future<Map<String, dynamic>> _concederVerificado(int clienteId,
      String logroId, int premioDias, String nota) async {
    try {
      return await (widget.concederVale ?? _concederReal)(
          clienteId, logroId, premioDias, nota);
    } catch (_) {
      final previos = {
        for (final v in _detalle?.vales ?? const <ValeHistorial>[])
          v.id,
      };
      final DetallePremiosCliente detalle;
      try {
        final json =
            await (widget.cargarDetalle ?? _detalleReal)(clienteId);
        if (json['ok'] != true) {
          return {
            'ok': false,
            'mensaje': 'La respuesta del servidor se '
                'perdió y no se pudo comprobar si el vale '
                'se creó. Revisa la Bandeja: si ya está, '
                'no lo concedas otra vez.',
          };
        }
        detalle = parseDetallePremiosCliente(json);
      } catch (_) {
        return {
          'ok': false,
          'mensaje': 'La respuesta del servidor se '
              'perdió y no se pudo comprobar si el vale '
              'se creó. Revisa la Bandeja: si ya está, '
              'no lo concedas otra vez.',
        };
      }
      final nuevo = detalle.vales.any((v) =>
          !previos.contains(v.id) &&
          v.logroId == logroId &&
          v.premioDias == premioDias &&
          v.estado == 'reclamado');
      if (nuevo) return {'ok': true};
      rethrow;
    }
  }

  Future<void> _conceder() async {
    // H-01 (Argón 1.27): check-and-set síncrono ANTES
    // del primer await (patrón _resolviendo de la
    // Bandeja); sin él, un doble toque apilaba dos
    // diálogos de concesión.
    if (_operando) return;
    final id = _seleccionadoId;
    if (id == null) return;
    setState(() => _operando = true);
    try {
      List<EntradaCatalogoPremio> catalogo;
      try {
        catalogo = await (widget.cargarCatalogo ?? _catalogoReal)();
      } catch (_) {
        if (mounted) {
          mostrarSnack(context, 'Sin conexión con el servidor.',
              significado: SignificadoChip.error);
        }
        return;
      }
      if (!mounted) return;
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoConcederVale(
          nombreCliente: _seleccionadoNombre,
          catalogo: catalogo,
          conceder: (logroId, dias, nota) =>
              _concederVerificado(id, logroId, dias, nota),
        ),
      );
      if (hecho == true && mounted) {
        mostrarSnack(
            context,
            'Vale creado: está en la Bandeja, apruébalo ahí '
            'para aplicar los días.',
            significado: SignificadoChip.exito);
        // 1.28 (M5-A4/C-R2M5-H2): la Bandeja ya montada
        // se entera y recarga: el vale recién concedido
        // aparece sin salir y reentrar al hub.
        premiosAvisosExternos.value++;
        await _recargarDetalle();
      }
    } finally {
      if (mounted) setState(() => _operando = false);
    }
  }

  Future<void> _anular(ValeHistorial v) async {
    // H-01 (Argón 1.27): misma guarda síncrona que
    // _conceder — dos diálogos de anulación confirmados
    // encolarían DOS ops anular_vale_premio con uuid
    // distinto para el mismo vale.
    if (_operando) return;
    final id = _seleccionadoId;
    if (id == null) return;
    setState(() => _operando = true);
    try {
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoAnularVale(
          nombreCliente: _seleccionadoNombre,
          vale: v,
          pagadoHasta: _pagadoHasta,
          hoy: ahoraHabana(),
          anular: (modo, k, nota) =>
              (widget.anularVale ?? _anularReal)(id, v, modo, k, nota),
        ),
      );
      if (hecho == true && mounted) {
        setState(
            () => _anulacionesEnCurso = {..._anulacionesEnCurso, v.id});
        mostrarSnack(
            context,
            'Anulación encolada: se aplica al sincronizar.',
            significado: SignificadoChip.exito);
      }
    } finally {
      if (mounted) setState(() => _operando = false);
    }
  }

  Future<void> _reiniciar() async {
    // H-01 (Argón 1.27): misma guarda síncrona.
    if (_operando) return;
    final id = _seleccionadoId;
    if (id == null) return;
    setState(() => _operando = true);
    try {
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoReiniciarCiclo(
          nombreCliente: _seleccionadoNombre,
          reiniciar: (nota) =>
              (widget.reiniciarCiclo ?? _reiniciarReal)(id, nota),
        ),
      );
      if (hecho == true && mounted) {
        mostrarSnack(context, 'Ciclo reiniciado: el conteo parte de hoy.',
            significado: SignificadoChip.exito);
        await _recargarDetalle();
      }
    } finally {
      if (mounted) setState(() => _operando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_seleccionadoId != null) return _vistaDetalle();
    if (_cargandoClientes) {
      return const EstadoCargando(texto: 'Cargando clientes…');
    }
    if (_falloClientes) {
      return EstadoError(
        titulo: 'No se pudieron cargar los clientes',
        detalle: 'La lectura falló en este teléfono. '
            'Reinténtalo.',
        onReintentar: _cargarClientes,
      );
    }
    final q = _busquedaCtrl.text.trim().toLowerCase();
    final visibles = q.isEmpty
        ? _todos
        : _todos
            .where((c) =>
                c.nombre.toLowerCase().contains(q) ||
                c.telefono.contains(q))
            .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppEspacio.lg),
          child: CampoTexto(
            controller: _busquedaCtrl,
            etiqueta: 'Buscar cliente por nombre o teléfono',
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: visibles.isEmpty
              // (1.36 H-B4 136-964) el vacío distingue «sin
              // clientes» de «sin resultados para el filtro».
              ? EstadoVacio(
                  icono: Icons.person_search_rounded,
                  titulo: _todos.isEmpty
                      ? 'Sin clientes.'
                      : 'Sin clientes con ese criterio.',
                  subtitulo: _todos.isEmpty
                      ? 'Todavía no hay clientes en el espejo '
                          'de este teléfono.'
                      : 'Ningún cliente coincide con la '
                          'búsqueda.',
                )
              : ListView.builder(
                  itemCount: visibles.length,
                  itemBuilder: (_, i) {
                    final c = visibles[i];
                    return ListTile(
                      leading: const Icon(Icons.person_rounded),
                      title: Text(c.nombre),
                      subtitle:
                          c.telefono.isEmpty ? null : Text(c.telefono),
                      trailing:
                          const Icon(Icons.chevron_right_rounded),
                      onTap: () => _abrirDetalle(c),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _vistaDetalle() {
    return Column(
      children: [
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () {
              // 1.28 (M5-A4/C-R2M5-H6): al volver, la
              // lista de clientes se recarga (antes se
              // cargaba una sola vez en initState: un
              // cliente inscrito con el hub abierto no
              // aparecía en el buscador).
              _genDetalle++;
              setState(() {
                _seleccionadoId = null;
                _detalle = null;
              });
              _cargarClientes();
            },
          ),
          title: Text(_seleccionadoNombre,
              style: AppTexto.subtitulo),
          subtitle: const Text('Premios y logros'),
        ),
        // SL-10 G13-2 (sync-una-vez): sin banda de sync
        // en el detalle de Premios — el estado lo dice
        // una sola vez el icono de la cabecera de la app.
        Expanded(
          child: _cargandoDetalle
              // 1.28 (M5-C3): esqueleto con la forma del
              // detalle (cabecera, barra, tarjetas).
              ? const SkeletonPremiosDetalle()
              : _falloDetalle
                  ? EstadoVacio(
                      icono: Icons.cloud_off_rounded,
                      titulo: 'No se pudo cargar el detalle.',
                      subtitulo: 'El detalle vive en el '
                          'servidor: hace falta conexión.',
                      textoAccion: 'Reintentar',
                      onAccion: () => _abrirDetalle((
                        id: _seleccionadoId!,
                        nombre: _seleccionadoNombre,
                        telefono: '',
                      )),
                    )
                  : _cuerpoDetalle(_detalle!),
        ),
      ],
    );
  }

  Widget _cuerpoDetalle(DetallePremiosCliente d) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _operando ? null : _conceder,
                icon: const Icon(Icons.card_giftcard_rounded,
                    size: 18),
                label: const Text('Conceder vale'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _operando ? null : _reiniciar,
                icon: const Icon(Icons.restart_alt_rounded,
                    size: 18),
                label: const Text('Reiniciar ciclo'),
              ),
            ),
          ],
        ),
        const EncabezadoSeccion(titulo: 'Progreso del ciclo'),
        if (d.logroBarraId == null)
          const Text(
            'No hay ningún premio activo en el catálogo: '
            'actívalo en la pestaña Catálogo.',
            style: AppTexto.secundario,
          )
        else ...[
          Text(
            '${tituloLogroPremio(d.logroBarraId!)}: '
            '${d.dias} de ${d.metaDias} días verificados',
            style: AppTexto.cuerpo,
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: d.fraccionBarra,
            minHeight: 10,
            borderRadius: BorderRadius.circular(5),
          ),
          const SizedBox(height: 6),
          Text(
            d.faltan > 0
                ? 'Le faltan ${d.faltan} días para el premio '
                    'de ${d.premioDias} días gratis.'
                : 'Ya cumple la meta: puede reclamar su '
                    'premio de ${d.premioDias} días gratis.',
            style: AppTexto.secundario,
          ),
          if (d.cicloDesde != null)
            Text(
              'Ciclo desde: ${fmtFecha(d.cicloDesde!.length >= 10 ? d.cicloDesde!.substring(0, 10) : d.cicloDesde)}',
              style: AppTexto.secundario,
            ),
        ],
        if (d.sesionesQueSumaron.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Últimas fechas que sumaron: '
            '${d.sesionesQueSumaron.map(fmtFecha).join(' · ')}',
            style: AppTexto.secundario,
          ),
        ],
        const EncabezadoSeccion(titulo: 'Historial de vales'),
        if (d.vales.isEmpty)
          const Text('Sin vales todavía.',
              style: AppTexto.secundario)
        else ...[
          // 1.28 (M5-B6): el historial crece sin freno;
          // se enseñan los primeros y el resto llega con
          // «Ver más», sin cargar la pantalla entera.
          for (final v in d.vales.take(_historialLimite)) ...[
            _tarjetaValeHistorial(v),
            const SizedBox(height: 8),
          ],
          if (d.vales.length > _historialLimite)
            Center(
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _historialLimite += 15),
                icon: const Icon(Icons.expand_more_rounded,
                    size: 18),
                label: Text(
                    'Ver más (${d.vales.length - _historialLimite} restantes)'),
              ),
            ),
        ],
        const EncabezadoSeccion(titulo: 'Medallas (sello)'),
        if (d.sello.isEmpty)
          const Text(
            'La app del cliente aún no ha subido su sello '
            'de medallas.',
            style: AppTexto.secundario,
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // (1.36 H-B4 136-965) medallas en el orden
              // del catálogo, no en el orden del mapa del
              // servidor.
              for (final e in (d.sello.entries.toList()
                ..sort((a, b) {
                  int r(String k) {
                    final base = k.split('@').first;
                    final i = ordenCatalogoLogros.indexOf(base);
                    return i < 0 ? ordenCatalogoLogros.length : i;
                  }

                  final c = r(a.key).compareTo(r(b.key));
                  return c != 0 ? c : a.key.compareTo(b.key);
                })))
                // 1.28 (M5-C4): cada medalla con SU icono
                // y su nombre (las claves del reto llevan
                // «@<mes>»: tituloLogroPremio ya nombra
                // por la base).
                Chip(
                  avatar: Icon(iconoLogroPremio(e.key), size: 16),
                  label: Text(
                      '${tituloLogroPremio(e.key)} · ${fmtFecha(e.value.length >= 10 ? e.value.substring(0, 10) : e.value)}'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Evaluado en el teléfono del cliente.',
            style: AppTexto.secundario,
          ),
        ],
        if (d.marcas.isNotEmpty) ...[
          const EncabezadoSeccion(titulo: 'Reinicios de ciclo'),
          for (final m in d.marcas)
            ListTile(
              dense: true,
              leading:
                  const Icon(Icons.restart_alt_rounded, size: 20),
              title: Text(fmtFecha(
                  m.desde.length >= 10 ? m.desde.substring(0, 10) : m.desde)),
              subtitle: Text(m.nota),
            ),
        ],
      ],
    );
  }

  Widget _tarjetaValeHistorial(ValeHistorial v) {
    final (icono, color) = switch (v.estado) {
      'canjeado' => (Icons.done_all_rounded, AppColores.exito),
      'rechazado' => (Icons.block_rounded, AppColores.error),
      'anulado' => (Icons.undo_rounded, AppColores.alerta),
      _ => (Icons.hourglass_top_rounded, AppColores.naranja),
    };
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 1.28 (M5-C4): la medalla del logro junto
              // al icono de su estado.
              MedallaLogroPremio(logroId: v.logroId, tamano: 30),
              const SizedBox(width: 8),
              Icon(icono, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${tituloLogroPremio(v.logroId)} · '
                  '${v.premioDias} días gratis · ${v.estado}',
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Text(
            'Reclamado con ${v.diasAlReclamar} días verificados'
            '${v.creadoEn.isNotEmpty ? ' · ${fmtFechaDeInstanteServidor(v.creadoEn)}' : ''}'
            '${v.resueltoEn != null && v.resueltoEn!.isNotEmpty ? ' · Resuelto el ${fmtFechaDeInstanteServidor(v.resueltoEn)}' : ''}',
            style: AppTexto.secundario,
          ),
          if (v.creadoNota.isNotEmpty)
            Text('📝 ${v.creadoNota}', style: AppTexto.secundario),
          if (v.resueltoNota.isNotEmpty)
            Text('Resolución: ${v.resueltoNota}',
                style: AppTexto.secundario),
          if (v.estado == 'anulado' && v.anuladoEn != null)
            Text(
              'Anulado el ${fmtFechaDeInstanteServidor(v.anuladoEn)}',
              style: AppTexto.secundario,
            ),
          // S7: anular un vale canjeado con pago. El
          // botón solo vive con la foto FRESCA del
          // detalle (este historial viene de la RPC) y
          // se apaga en este teléfono al encolar la op.
          if (v.canjeado &&
              (v.pagoUuid ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            if (_anulacionesEnCurso.contains(v.id))
              const Text('⏳ Anulación en curso (sincronizando)',
                  style: AppTexto.secundario)
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _operando ? null : () => _anular(v),
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('Anular vale'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Diálogo «Conceder vale» (S4): el dueño elige el
/// logro (o «Vale manual» libre), los días de premio
/// y la nota OBLIGATORIA. El vale nace en la bandeja:
/// se aprueba allí con el mismo botón de siempre.
class _DialogoConcederVale extends StatefulWidget {
  final String nombreCliente;
  final List<EntradaCatalogoPremio> catalogo;
  final Future<Map<String, dynamic>> Function(
      String logroId, int premioDias, String nota) conceder;

  const _DialogoConcederVale(
      {required this.nombreCliente,
      required this.catalogo,
      required this.conceder});

  @override
  State<_DialogoConcederVale> createState() =>
      _DialogoConcederValeState();
}

class _DialogoConcederValeState extends State<_DialogoConcederVale> {
  late String _logroId;
  final _diasCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();
  String? _error;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _logroId = widget.catalogo.any((e) => e.logroId == 'manual')
        ? 'manual'
        : (widget.catalogo.isNotEmpty
            ? widget.catalogo.first.logroId
            : 'manual');
    final entrada = widget.catalogo
        .where((e) => e.logroId == _logroId)
        .firstOrNull;
    if (entrada != null && entrada.premioDias > 0) {
      _diasCtrl.text = '${entrada.premioDias}';
    }
  }

  @override
  void dispose() {
    _diasCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final dias = int.tryParse(_diasCtrl.text.trim());
    final nota = _notaCtrl.text.trim();
    String? error;
    if (dias == null || dias < 1 || dias > 365) {
      error = 'El premio debe estar entre 1 y 365 días.';
    } else if (nota.isEmpty) {
      error = 'La nota es obligatoria: explica el motivo del vale.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final res = await widget.conceder(_logroId, dias!, nota);
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _guardando = false;
        _error =
            '${res['mensaje'] ?? res['motivo'] ?? 'No se pudo crear el vale.'}';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Sin conexión con el servidor.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Conceder vale',
      iconoTitulo: Icons.card_giftcard_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Para ${widget.nombreCliente}. El vale queda '
            'en la Bandeja: lo apruebas allí y los días se '
            'aplican por la vía de siempre.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          // 1.28 (M5-A8/C-R1M5-H4): con el catálogo vacío
          // no hay desplegable (su valor inicial quedaba
          // fuera de los items) ni botón de crear: se
          // dice por qué y dónde se arregla.
          if (widget.catalogo.isEmpty)
            Text(
              'El catálogo de premios está vacío: no hay '
              'logros para conceder. Activa alguno en la '
              'pestaña Catálogo.',
              style: AppTexto.secundario
                  .copyWith(color: AppColores.error),
            )
          else
            SelectorIronForm<String>(
              valorInicial: _logroId,
              etiqueta: 'Logro',
              opciones: [
                for (final e in widget.catalogo)
                  OpcionSelector(
                    e.logroId,
                    // 1.28 (M5-A8/C-R1M5-H5): cada
                    // entrada dice su estado (la
                    // semántica de estadoTexto, en
                    // corto para que quepa): activo con
                    // sus días, apagado con sus días o
                    // sin premio. Conceder a ciegas con
                    // un logro apagado sorprendía.
                    e.activo
                        ? '${e.nombre} · ${e.premioDias} días'
                        : e.premioDias > 0
                            ? '${e.nombre} · apagado · '
                                '${e.premioDias} días'
                            : '${e.nombre} · sin premio',
                  ),
              ],
              alCambiar: _guardando
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() {
                        _logroId = v;
                        final entrada = widget.catalogo
                            .where((e) => e.logroId == v)
                            .firstOrNull;
                        // 1.28 (M5-A8/C-R1M5-H5): el
                        // campo de días se recarga
                        // SIEMPRE: con un logro sin
                        // premio queda VACÍO (a teclear),
                        // no con los días del anterior.
                        if (entrada != null) {
                          _diasCtrl.text = entrada.premioDias > 0
                              ? '${entrada.premioDias}'
                              : '';
                        }
                      });
                    },
            ),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _diasCtrl,
              etiqueta: 'Días de mensualidad gratis',
              teclado: TextInputType.number),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _notaCtrl,
              etiqueta: 'Nota (obligatoria)',
              maxLineas: 2),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed:
              _guardando || widget.catalogo.isEmpty ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Creando…' : 'Crear vale'),
        ),
      ],
    );
  }
}

/// Diálogo «Reiniciar ciclo» (S6): pone el contador
/// de días a cero desde hoy SIN tocar el candado
/// anual de canje. Nota obligatoria (D4).
class _DialogoReiniciarCiclo extends StatefulWidget {
  final String nombreCliente;
  final Future<Map<String, dynamic>> Function(String nota)
      reiniciar;

  const _DialogoReiniciarCiclo(
      {required this.nombreCliente, required this.reiniciar});

  @override
  State<_DialogoReiniciarCiclo> createState() =>
      _DialogoReiniciarCicloState();
}

class _DialogoReiniciarCicloState
    extends State<_DialogoReiniciarCiclo> {
  final _notaCtrl = TextEditingController();
  String? _error;
  bool _guardando = false;

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final nota = _notaCtrl.text.trim();
    if (nota.isEmpty) {
      setState(() => _error =
          'La nota es obligatoria: explica el motivo del reinicio.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final res = await widget.reiniciar(nota);
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _guardando = false;
        _error =
            '${res['mensaje'] ?? res['motivo'] ?? 'No se pudo reiniciar.'}';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Sin conexión con el servidor.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Reiniciar ciclo',
      iconoTitulo: Icons.restart_alt_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'El contador de días de ${widget.nombreCliente} '
            'vuelve a cero desde hoy. No cambia su '
            'vencimiento ni destraba el canje de un '
            'premio ya cobrado este año.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          CampoTexto(
              controller: _notaCtrl,
              etiqueta: 'Nota (obligatoria)',
              maxLineas: 2),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Reiniciando…' : 'Reiniciar'),
        ),
      ],
    );
  }
}

/// Diálogo «Anular vale» (S7, D2 de Jc): el dueño
/// elige EN EL MOMENTO entre quitar el pago completo
/// o solo los días no consumidos, viendo el efecto de
/// cada vía antes de confirmar. Nota obligatoria.
/// El servidor recalcula los días: lo que aquí se
/// muestra es la misma fórmula, y si el servidor no
/// coincide, la op se rechaza sin tocar nada.
class _DialogoAnularVale extends StatefulWidget {
  final String nombreCliente;
  final ValeHistorial vale;
  final String? pagadoHasta;
  final DateTime hoy;
  final Future<void> Function(String modo, int diasQuitables,
      String nota) anular;

  const _DialogoAnularVale(
      {required this.nombreCliente,
      required this.vale,
      required this.pagadoHasta,
      required this.hoy,
      required this.anular});

  @override
  State<_DialogoAnularVale> createState() =>
      _DialogoAnularValeState();
}

class _DialogoAnularValeState extends State<_DialogoAnularVale> {
  String _modo = 'no_consumidos';
  final _notaCtrl = TextEditingController();
  String? _error;
  bool _guardando = false;

  // 1.28 (M5-A3/C-R2M5-H7): la VISTA PREVIA usa el hoy
  // de la apertura (widget.hoy, inyectado); el valor
  // que VIAJA en la op se recalcula en _enviar con el
  // hoy real de ese momento — el diálogo podía quedar
  // abierto cruzando la medianoche y la resta salía
  // con un día de menos (y el servidor, que recalcula
  // con SU hoy, la rechazaba).
  int get _k => diasQuitablesVale(
        pagadoHasta: widget.pagadoHasta,
        resueltoEn: widget.vale.resueltoEn,
        premioDias: widget.vale.premioDias,
        hoy: widget.hoy,
      );

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  String _hastaTras(int diasMenos) {
    final hasta = widget.pagadoHasta;
    if (hasta == null) return '—';
    if (DateTime.tryParse(hasta) == null) return '—';
    // H-01 (Argón 1.27): aritmética UTC pura
    // (sumarDiasIso). La resta sobre un DateTime local
    // cruzaba el cambio de horario (marzo en Cuba) y
    // la vista previa se corría un día frente al
    // servidor.
    return fmtFecha(sumarDiasIso(hasta, -diasMenos));
  }

  Future<void> _enviar() async {
    final nota = _notaCtrl.text.trim();
    if (nota.isEmpty) {
      setState(() => _error =
          'La nota es obligatoria: explica el motivo de la anulación.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      // C-R2M5-H7: k recalculado al confirmar, con el
      // hoy de AHORA (no el de la apertura del diálogo).
      final kAhora = diasQuitablesVale(
        pagadoHasta: widget.pagadoHasta,
        resueltoEn: widget.vale.resueltoEn,
        premioDias: widget.vale.premioDias,
        hoy: ahoraHabana(),
      );
      await widget.anular(_modo, kAhora, nota);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'No se pudo encolar la anulación.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vale;
    return DialogoApp(
      titulo: 'Anular vale',
      iconoTitulo: Icons.undo_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'El vale de ${v.premioDias} días de '
            '${widget.nombreCliente} ya se aplicó. Elige '
            'cómo revertirlo:',
            style: AppTexto.secundario,
          ),
          RadioGroup<String>(
            groupValue: _modo,
            onChanged: _guardando
                ? (_) {}
                : (m) => setState(() => _modo = m ?? 'no_consumidos'),
            child: Column(
              children: [
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'no_consumidos',
                  title: const Text('Solo los días no consumidos'),
                  subtitle: Text(_k > 0
                      ? 'Se quitan $_k días: el vencimiento pasa '
                          'de ${fmtFecha(widget.pagadoHasta)} a '
                          '${_hastaTras(_k)}. Los ${v.premioDias - _k} '
                          'ya disfrutados se quedan.'
                      : 'Este vale ya se consumió entero: esta '
                          'vía resta 0 días, solo cierra el vale '
                          'como anulado.'),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'completo',
                  title: const Text('Quitar el pago completo'),
                  // H-03 (Argón 1.27): la fecha que sale
                  // de restar los días es solo la
                  // ESTIMACIÓN local: en modo completo el
                  // servidor borra el pago y recalcula el
                  // vencimiento sin él, y esa es la fecha
                  // que manda (con un hueco de por medio,
                  // la resta lineal puede no coincidir).
                  subtitle: Text(widget.pagadoHasta != null
                      ? 'Se quitan los ${v.premioDias} días '
                          'completos (también los ya '
                          'disfrutados): pasaría de '
                          '${fmtFecha(widget.pagadoHasta)} a '
                          '${_hastaTras(v.premioDias)}. Es una '
                          'estimación: la fecha exacta la '
                          'confirma el servidor al sincronizar.'
                      : 'Se quitan los ${v.premioDias} días '
                          'completos (también los ya '
                          'disfrutados). La fecha exacta la '
                          'confirma el servidor al sincronizar.'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _notaCtrl,
              etiqueta: 'Nota (obligatoria)',
              maxLineas: 2),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.error,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Anulando…' : 'Anular vale'),
        ),
      ],
    );
  }
}
