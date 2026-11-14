import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth.dart';
import '../../fotos.dart';
import '../../localdb.dart';
import '../../tiempo.dart';
import '../../modelos/incidencia.dart';
import '../app_bar.dart';
import '../diseno.dart';
import '../componentes.dart';
import '../foto_elegir.dart';
import '../ficha.dart';
import 'widgets/dialogo_resolver_incidencia.dart';
import 'editar_incidencia.dart';
import '../../errores_sync.dart';
import '../../app_log.dart';

/// Detalle de incidencia: info + comentarios + fotos + historial.
/// v1.3.0
class DetalleIncidenciaScreen extends StatefulWidget {
  final String incidenciaId;
  const DetalleIncidenciaScreen(
      {super.key, required this.incidenciaId});

  @override
  State<DetalleIncidenciaScreen> createState() =>
      _DetalleIncidenciaScreenState();
}

class _DetalleIncidenciaScreenState
    extends State<DetalleIncidenciaScreen> {
  Incidencia? _inc;
  TipoIncidencia? _tipo;
  // 22/25: creada_por del espejo (nombre real del servidor), solo
  // para mostrar cuando el autor local no es fiable.
  String? _creadaPorEspejo;
  List<IncidenciaComentario> _comentarios = [];
  List<IncidenciaFoto> _fotos = [];
  // Auditoría Definitiva (C-12): existencia en disco de cada
  // foto y futures de descarga remota MEMOIZADOS, resueltos
  // en _cargarDatos — el build no hace IO síncrona
  // (existsSync por foto y rebuild) ni crea un future nuevo
  // en cada repintado (el FutureBuilder reiniciaba la
  // descarga).
  Map<String, bool> _fotosLocales = {};
  final Map<String, Future<File?>> _futurasRemotas = {};
  List<IncidenciaHistorial> _historial = [];
  bool _cargando = true;
  // Auditoría Definitiva (B-15): error de carga VISIBLE — un
  // fallo de lectura dejaba _inc en null y el build decía
  // «No encontrada», que es falso: la incidencia existe, lo
  // que falló fue leerla.
  String? _errorCarga;
  final _ctrlComentario = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _ctrlComentario.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
      if (mounted && _errorCarga != null) {
        setState(() => _errorCarga = null);
      }
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      // B-15: y se VE como error con Reintentar, no como
      // «No encontrada».
      if (mounted) {
        setState(() => _errorCarga = mensajeErrorAmable(e));
      }
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final d = await LocalDb.instance.db;
    // Incidencia (local primero)
    var rows = await d.query('incidencias_local',
        where: 'id = ?', whereArgs: [widget.incidenciaId]);
    rows = rows.isEmpty
        ? await d.query('incidencias_mirror',
            where: 'id = ?',
            whereArgs: [widget.incidenciaId])
        : rows;
    if (rows.isEmpty) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    final inc = Incidencia.fromMap(rows.first);

    // 22/25: el espejo trae el nombre real del servidor
    // (dev["nombre"]); si el autor local no es fiable
    // ('desconocido' o UUID viejo), el detalle muestra el del
    // espejo. Solo se consulta cuando hace falta.
    String? creadaPorEspejo;
    if (!autorIncidenciaFiable(inc.creadaPor)) {
      final mr = await d.query('incidencias_mirror',
          columns: ['creada_por'],
          where: 'id = ?', whereArgs: [widget.incidenciaId]);
      if (mr.isNotEmpty) {
        creadaPorEspejo = mr.first['creada_por'] as String?;
      }
    }

    // Tipo
    TipoIncidencia? tipo;
    if (inc.tipoId != null) {
      final tr = await d.query('incidencias_tipos',
          where: 'id = ?', whereArgs: [inc.tipoId]);
      if (tr.isNotEmpty) {
        tipo = TipoIncidencia.fromMap(tr.first);
      }
    }

    // Comentarios, fotos, historial
    final cr = await d.query('incidencias_comentarios',
        where: 'incidencia_id = ?',
        whereArgs: [widget.incidenciaId],
        orderBy: 'creado_en ASC');
    final fr = await d.query('incidencias_fotos',
        where: 'incidencia_id = ?',
        whereArgs: [widget.incidenciaId],
        orderBy: 'creado_en ASC');
    final hr = await d.query('incidencias_historial',
        where: 'incidencia_id = ?',
        whereArgs: [widget.incidenciaId],
        orderBy: 'cambiado_en DESC');

    // C-12: existencia local y descargas remotas se resuelven
    // AQUÍ (fuera del build), una sola vez por carga.
    final fotosLista =
        fr.map((m) => IncidenciaFoto.fromMap(m)).toList();
    final locales = <String, bool>{};
    for (final f in fotosLista) {
      locales[f.id] = await File(f.localPath).exists();
      final sp = f.storagePath;
      if (locales[f.id] == false && sp != null && sp.isNotEmpty) {
        _futurasRemotas.putIfAbsent(
            sp, () => FotoCache.instance.obtener(sp));
      }
    }

    if (mounted) {
      setState(() {
        _inc = inc;
        _tipo = tipo;
        _creadaPorEspejo = creadaPorEspejo;
        _comentarios = cr
            .map((m) =>
                IncidenciaComentario.fromMap(m))
            .toList();
        _fotos = fotosLista;
        _fotosLocales = locales;
        _historial = hr
            .map((m) =>
                IncidenciaHistorial.fromMap(m))
            .toList();
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inc = _inc;
    return Scaffold(
      appBar: appBarIron(
        context,
        inc?.descripcion ?? 'Incidencia',
        acciones: [
          if (inc != null)
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              tooltip: 'Editar',
              onPressed: () async {
                await Navigator.push(
                  context,
                  RutaIron(
                    builder: (_) =>
                        EditarIncidenciaScreen(
                            existente: inc),
                  ),
                );
                _cargar();
              },
            ),
          if (inc != null &&
              (!inc.estaResuelta ||
                  AuthService().isOwner))
            PopupMenuButton<String>(
              popUpAnimationStyle: estiloAparicionMenu,
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: _cambiarEstado,
              itemBuilder: (ctx) {
                final items = <PopupMenuItem<String>>[];
                if (inc.puedeTransicionarAConRol(
                    'pendiente',
                    esDueno: AuthService().isOwner)) {
                  items.add(const PopupMenuItem(
                    value: 'pendiente',
                    child: Text('Pendiente'),
                  ));
                }
                if (inc.puedeTransicionarAConRol(
                    'en_proceso',
                    esDueno: AuthService().isOwner)) {
                  items.add(const PopupMenuItem(
                    value: 'en_proceso',
                    child: Text('En proceso'),
                  ));
                }
                if (inc.puedeTransicionarAConRol(
                    'bloqueada',
                    esDueno: AuthService().isOwner)) {
                  items.add(const PopupMenuItem(
                    value: 'bloqueada',
                    child: Text('Bloqueada'),
                  ));
                }
                if (inc.puedeTransicionarAConRol(
                    'resuelta',
                    esDueno: AuthService().isOwner)) {
                  items.add(const PopupMenuItem(
                    value: 'resuelta',
                    child: Text('Resolver'),
                  ));
                }
                return items;
              },
            ),
        ],
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudo cargar la incidencia',
                  detalle: _errorCarga,
                  onReintentar: _cargar,
                )
              : inc == null
              ? const Center(
                  child:
                      Text('No encontrada'))
              : ListView(
                  padding:
                      const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    _seccionInfo(inc),
                    const SizedBox(height: 16),
                    _seccionFotos(),
                    const SizedBox(height: 16),
                    _seccionComentarios(),
                    const SizedBox(height: 16),
                    _seccionHistorial(),
                  ],
                ),
    );
  }

  Widget _seccionInfo(Incidencia inc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            if (_tipo != null)
              Chip(
                avatar: Icon(_tipo!.iconoData,
                    size: 16),
                label:
                    Text(_tipo!.nombre),
              ),
            const SizedBox(height: 8),
            Text(inc.descripcion,
                style: AppTexto.titulo),
            if (inc.detalle != null) ...[
              const SizedBox(height: 8),
              Text(inc.detalle!),
            ],
            const SizedBox(height: 12),
            _filaInfo('Creada por', _creadaPorMostrada),
            _filaInfo('Estado',
                inc.estado),
            _filaInfo('Prioridad',
                inc.prioridad),
            if (inc.ubicacion != null)
              _filaInfo(
                  'Ubicación', inc.ubicacion!),
            // v1.3.3: responsable (tocable si es cliente).
            if (_nombreResponsable(inc) !=
                null)
              _filaResponsable(inc),
            if (inc.fechaLimite != null)
              _filaInfo('Límite',
                  '${inc.fechaLimite!.day}/${inc.fechaLimite!.month}'),
            _filaInfo('Abierta hace',
                '${inc.diasAbierta} días'),
            if (inc.estaResuelta) ...[
              _filaInfo('Resuelta por',
                  inc.resueltaPor == null
                      ? '-'
                      : _nombreAutor(inc.resueltaPor)),
              if (inc.notaResolucion !=
                  null)
                _filaInfo('Nota',
                    inc.notaResolucion!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filaInfo(String label, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: AppTexto.secundario.copyWith(color: Colors.grey[500])),
          ),
          Expanded(child: Text(valor)),
        ],
      ),
    );
  }

  /// v1.3.3: extrae el nombre del responsable del formato compuesto.
  String? _nombreResponsable(Incidencia inc) {
    final a = inc.asignadoA;
    if (a == null || a.isEmpty) return null;
    final partes = a.split(':');
    if (partes.length < 3) return null;
    final nombre = partes.skip(2).join(':').trim();
    return nombre.isEmpty ? null : nombre;
  }

  /// v1.3.3: fila de responsable; si es cliente, abre su ficha al tocar.
  Widget _filaResponsable(Incidencia inc) {
    final a = inc.asignadoA ?? '';
    final nombre = _nombreResponsable(inc) ?? '-';
    final esCliente = a.startsWith('cliente:');
    final clienteId = esCliente
        ? int.tryParse(a.split(':').elementAtOrNull(1) ?? '')
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text('Responsable',
                style: AppTexto.secundario.copyWith(color: Colors.grey[500])),
          ),
          Expanded(
            child: esCliente && clienteId != null
                ? InkWell(
                    onTap: () {
                      Navigator.push(
                        context,
                        RutaIron(
                          builder: (_) => FichaScreen(
                              clienteId: clienteId),
                        ),
                      );
                    },
                    child: Text(
                      '👤 $nombre',
                      // 1.33 (diseño): el enlace a la ficha
                      // se lee en la marca, no en el azul
                      // plano de hipervínculo web; el
                      // subrayado conserva la señal de
                      // «esto se toca».
                      style: TextStyle(
                        color: AppColores.textoNaranja(context),
                        decoration:
                            TextDecoration.underline,
                      ),
                    ),
                  )
                : Text('👤 $nombre'),
          ),
        ],
      ),
    );
  }

  Widget _seccionFotos() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Fotos',
                style: TextStyle(
                    fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(
                  Icons.add_a_photo_rounded,
                  size: 18),
              label: const Text('Agregar'),
              onPressed: _agregarFoto,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_fotos.isEmpty)
          const Text('Sin fotos',
              style: TextStyle(
                  color: Colors.grey))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _fotos.map((f) {
              final file = File(f.localPath);
              // v1.3.2 (Argón #21): si el archivo local no existe pero hay
              // storage_path (foto de otro móvil), descargarla vía FotoCache.
              // C-12: existencia y future vienen de _cargarDatos.
              final Widget imagen = (_fotosLocales[f.id] ?? false)
                  ? Image.file(
                      file,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      // 1.34 Campo 2 (P-1): acotada a su
                      // hueco de 100 dp.
                      cacheWidth: (100 *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                    )
                  : (f.storagePath != null && f.storagePath!.isNotEmpty)
                      ? FutureBuilder<File?>(
                          future: _futurasRemotas[f.storagePath],
                          builder: (ctx, snap) {
                            if (snap.hasData && snap.data != null) {
                              return Image.file(
                                snap.data!,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                                cacheWidth: (100 *
                                        MediaQuery.devicePixelRatioOf(
                                            ctx))
                                    .round(),
                              );
                            }
                            return Container(
                              width: 100,
                              height: 100,
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              child: snap.connectionState ==
                                      ConnectionState.waiting
                                  ? const Center(
                                      child:
                                          CircularProgressIndicator())
                                  : const Icon(
                                      Icons.broken_image_rounded),
                            );
                          },
                        )
                      : Container(
                          width: 100,
                          height: 100,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(
                              Icons.broken_image_rounded),
                        );
              return ClipRRect(
                borderRadius:
                    BorderRadius.circular(AppRadio.sm),
                child: imagen,
              );
            }).toList(),
          ),
      ],
    );
  }

  /// Agrega una foto a la incidencia (Argón A4).
  Future<void> _agregarFoto() async {
    try {
      // Cierre §17 (×10): por la vía segura de la casa
      // (foto_elegir.dart): suma la recuperación con
      // retrieveLostData y la guarda anti-doble-toque a
      // este handler, que ya tenía su try/catch con aviso.
      // Si devuelve null (cancelación o fallo ya avisado
      // por la propia vía), no hay nada que agregar.
      final xfile = await elegirFotoSegura(
        context,
        origen: ImageSource.camera,
        maxWidth: 1280,
      );
      if (xfile == null) return;
      final db = LocalDb.instance;
      final d = await db.db;
      final id = const Uuid().v4();
      final ahora =
          isoHabana(ahoraHabana());
      // Auditoría Definitiva (B-14): la ruta del selector es
      // caché temporal que Android purga; se copia a documentos
      // gestionados ANTES de crear la fila. Si la copia falla,
      // el catch de esta función avisa y NO queda una fila
      // 'pending' apuntando a un archivo que ya no existe.
      final rutaGestionada = await copiarFotoGestionada(
        subdirectorio: 'incidencias_fotos',
        nombreBase: id,
        rutaOrigen: xfile.path,
      );
      // v1.3.2 (Argón #8): la incidencia puede venir de otro móvil
      // (solo en mirror); copiarla a local antes del hijo (FK).
      await db.asegurarIncidenciaLocal(_inc!.id);
      await d.insert('incidencias_fotos', {
        'id': id,
        'incidencia_id': _inc!.id,
        'local_path': rutaGestionada,
        'tipo': 'evidencia',
        'sync_estado': 'pending',
        'creado_en': ahora,
      });
      // Argón: no encolar aquí. subirFotosIncidencias() lo hace
      // tras subir el archivo a Storage (con storage_path).
      await _cargar();
      if (mounted) {
        mostrarSnack(context, 'Foto agregada', significado: SignificadoChip.exito);
      }
    } catch (e) {
      if (mounted) {
        AppLog.error('detalle_incidencia', 'agregar_foto_fallo', d: '$e');
        mostrarSnack(context, 'Error: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      }
    }
  }

  Widget _seccionComentarios() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        const Text('Comentarios',
            style: TextStyle(
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final c in _comentarios)
          ListTile(
            dense: true,
            title: Text(c.texto),
            subtitle: Text(
                '${_nombreAutor(c.creadoPor)} · ${_fechaCorta(c.creadoEn)}'),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrlComentario,
                decoration:
                    const InputDecoration(
                  hintText:
                      'Agregar comentario...',
                  border:
                      OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send_rounded),
              onPressed: _enviarComentario,
            ),
          ],
        ),
      ],
    );
  }

  Widget _seccionHistorial() {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        const Text('Historial',
            style: TextStyle(
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final h in _historial)
          ListTile(
            dense: true,
            leading: const Icon(
                Icons.history_rounded,
                size: 18),
            title: Text(
                '${h.campo}: ${h.valorAnterior ?? '-'} → ${h.valorNuevo ?? '-'}'),
            subtitle: Text(
                '${_nombreAutor(h.cambiadoPor)} · ${_fechaCorta(h.cambiadoEn)}'),
          ),
      ],
    );
  }

  String _fechaCorta(DateTime d) =>
      '${d.day}/${d.month} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';

  /// 22/25: autor a guardar en filas nuevas (nombre de sesión,
  /// nunca UUID ni 'desconocido').
  String _autorActual() => autorIncidenciaActual(
        displayName: AuthService().displayName,
        telegramId: AuthService().telegramId,
      );

  /// 22/25: nombre a mostrar para un autor guardado.
  String _nombreAutor(String? valor) => nombreAutorIncidencia(
        valor,
        userIdActual: AuthService().userId,
        displayNameActual: AuthService().displayName,
      );

  /// 22/25: autor de la incidencia a mostrar: el local si es
  /// fiable; si no, el del espejo (nombre real del servidor); si
  /// tampoco, la etiqueta honesta.
  String get _creadaPorMostrada {
    final inc = _inc;
    if (inc == null) return 'Sin autor registrado';
    if (autorIncidenciaFiable(inc.creadaPor)) return inc.creadaPor;
    if (autorIncidenciaFiable(_creadaPorEspejo)) {
      return _creadaPorEspejo!;
    }
    return _nombreAutor(inc.creadaPor);
  }

  Future<void> _enviarComentario() async {
    final texto = _ctrlComentario.text.trim();
    if (texto.isEmpty) return;
    // Yunque de App 1.31 (familia B-15, rama escritura): un
    // fallo de la mutación se DICE (bitácora + snack); el
    // texto se conserva en el campo para reintentar.
    try {
      await _enviarComentarioDatos(texto);
    } catch (e) {
      AppLog.error('incidencias', 'comentario_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(
            context, 'No se pudo enviar el comentario: '
            '${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _enviarComentarioDatos(String texto) async {
    final comId = const Uuid().v4();
    final ahora =
        isoHabana(ahoraHabana());
    // v1.3.2 (Argón #8): asegurar la incidencia en local antes del hijo.
    await LocalDb.instance.asegurarIncidenciaLocal(widget.incidenciaId);
    // Fix #9 (Sol): insert + encolado en una transacción.
    await LocalDb.instance.mutarYEncolar(
      tabla: 'incidencias_comentarios',
      datos: {
        'id': comId,
        'incidencia_id': widget.incidenciaId,
        'texto': texto,
        'creado_por': _autorActual(),
        'creado_en': ahora,
        'sync_estado': 'pending',
      },
      whereId: comId,
      opUuid: const Uuid().v4(),
      opTipo: 'agregar_comentario_incidencia',
      opPayload: {
        'id': comId,
        'incidencia_id': widget.incidenciaId,
        'texto': texto,
        'creado_por': _autorActual(),
        'creado_en': ahora,
      },
      esInsert: true,
    );
    _ctrlComentario.clear();
    _cargar();
  }

  Future<void> _cambiarEstado(String nuevo) async {
    // Yunque de App 1.31 (familia B-15, rama escritura): la
    // mutación no puede fallar en silencio — bitácora + snack.
    // (El diálogo de resolver y su foto gestionada llevan su
    // propio aviso dentro de _cambiarEstadoDatos.)
    try {
      await _cambiarEstadoDatos(nuevo);
    } catch (e) {
      AppLog.error('incidencias', 'cambiar_estado_fallo',
          d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudo cambiar el estado: '
            '${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _cambiarEstadoDatos(String nuevo) async {
    final d = await LocalDb.instance.db;
    final ahora =
        isoHabana(ahoraHabana());
    final anterior = _inc!.estado;
    // v1.3.2 (Argón #8): puede venir de otro móvil (solo mirror).
    await LocalDb.instance.asegurarIncidenciaLocal(_inc!.id);

    if (nuevo == 'resuelta') {
      final res =
          await mostrarDialogoResolver(
              context, _inc!);
      if (res == null || !mounted) return;

      final nota = res['nota'] as String;
      final fotoPath =
          res['foto'] as String?;

      // Auditoría Definitiva (B-14): la foto de resolución
      // viene de la caché temporal del selector; se copia a
      // documentos gestionados ANTES de la transacción (la IO
      // no va dentro). Si la copia falla se avisa y la
      // incidencia NO cambia de estado: mejor repetir la
      // resolución que perder su foto en silencio.
      String? fotoIdResolucion;
      String? fotoRutaGestionada;
      if (fotoPath != null) {
        fotoIdResolucion = const Uuid().v4();
        try {
          fotoRutaGestionada = await copiarFotoGestionada(
            subdirectorio: 'incidencias_fotos',
            nombreBase: fotoIdResolucion,
            rutaOrigen: fotoPath,
          );
        } catch (e) {
          AppLog.error('detalle_incidencia',
              'resolver_foto_copia_fallo',
              d: '$e');
          if (mounted) {
            mostrarSnack(context,
                'No se pudo guardar la foto de resolución. '
                'Inténtalo de nuevo.',
                significado: SignificadoChip.error);
          }
          return;
        }
      }

      await d.transaction((txn) async {
        // v1.3.2 (Argón post-fix): generar el op_uuid antes para
        // guardarlo también en la fila local.
        final opUuidEstado = const Uuid().v4();
        // 1. Actualizar incidencia
        await txn.update(
          'incidencias_local',
          {
            'estado': 'resuelta',
            'nota_resolucion': nota,
            'resuelta_por': _autorActual(),
            'resuelta_en': ahora,
            'actualizado_en': ahora,
            'sync_estado': 'pending',
            'sincronizada': 0,
            'op_uuid': opUuidEstado,
            // Argón B4: incrementar versión para OCC.
            'version': _inc!.version + 1,
          },
          where: 'id = ?',
          whereArgs: [_inc!.id],
        );

        // 2. Si tomó foto, registrarla (con la copia
        // gestionada de B-14, no la ruta temporal).
        if (fotoRutaGestionada != null) {
          await txn.insert(
              'incidencias_fotos', {
            'id': fotoIdResolucion,
            'incidencia_id': _inc!.id,
            'local_path': fotoRutaGestionada,
            'tipo': 'resolucion',
            'sync_estado': 'pending',
            'creado_en': ahora,
          });
        }

        // 3. Registrar en historial
        await txn.insert(
            'incidencias_historial', {
          'id': const Uuid().v4(),
          'incidencia_id': _inc!.id,
          'campo': 'estado',
          'valor_anterior': anterior,
          'valor_nuevo': 'resuelta',
          'cambiado_por': _autorActual(),
          'cambiado_en': ahora,
        });

        // 4. Fix #9 (Sol): encolar dentro de la transacción.
        await txn.insert('ops_queue', {
          'op_uuid': opUuidEstado,
          'tipo': 'cambiar_estado_incidencia',
          'payload': jsonEncode({
            'id': _inc!.id,
            'estado_anterior': anterior,
            'estado_nuevo': 'resuelta',
            'nota_resolucion': nota,
            'resuelta_por': _autorActual(),
            'resuelta_en': ahora,
            'version': _inc!.version + 1,
            // Auditoría Definitiva (C-5): precondición OCC,
            // como el editor — sin version_base el servidor
            // no puede detectar que la fila cambió en otro
            // teléfono entre la lectura y esta op.
            'version_base': _inc!.version,
          }),
          'estado': 'pendiente',
          'creada_ts': ahora,
          'user_id': AuthService().userId,
          'telegram_id': AuthService().telegramId,
        });
      });
      _cargar();
      return;
    }

    // Transición directa (en_proceso, bloqueada, etc.)
    await d.transaction((txn) async {
      // v1.3.2 (Argón post-fix): op_uuid en la fila local también.
      final opUuidDirecto = const Uuid().v4();
      await txn.update(
        'incidencias_local',
        {
          'estado': nuevo,
          'actualizado_en': ahora,
          'sync_estado': 'pending',
          'sincronizada': 0,
          'op_uuid': opUuidDirecto,
          // Argón B4: incrementar versión para OCC.
          'version': _inc!.version + 1,
        },
        where: 'id = ?',
        whereArgs: [_inc!.id],
      );

      await txn.insert(
          'incidencias_historial', {
        'id': const Uuid().v4(),
        'incidencia_id': _inc!.id,
        'campo': 'estado',
        'valor_anterior': anterior,
        'valor_nuevo': nuevo,
        'cambiado_por': _autorActual(),
        'cambiado_en': ahora,
      });

      // Fix #9 (Sol): encolar dentro de la transacción.
      await txn.insert('ops_queue', {
        'op_uuid': opUuidDirecto,
        'tipo': 'cambiar_estado_incidencia',
        'payload': jsonEncode({
          'id': _inc!.id,
          'estado_anterior': anterior,
          'estado_nuevo': nuevo,
          'version': _inc!.version + 1,
          // Auditoría Definitiva (C-5): version_base OCC.
          'version_base': _inc!.version,
        }),
        'estado': 'pendiente',
        'creada_ts': ahora,
        'user_id': AuthService().userId,
        'telegram_id': AuthService().telegramId,
      });
    });
    _cargar();
  }
}
