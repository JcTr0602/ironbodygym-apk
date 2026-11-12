// lib/ui/pestana_progreso.dart
// v1.3.9 Sprint 2 (#3 + #13): pestaña de progreso con mediciones.
// Gráfico de peso + lista + formulario de registro.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_log.dart';
import '../auth.dart';
import '../mediciones_cliente.dart';
import '../tiempo.dart';
import '../permisos_entrenador.dart';
import 'app_bar.dart';
import 'editor_plan_nutricional.dart';
import 'grafico_peso.dart';
import 'grafico_metrica.dart';
import 'componentes.dart';
import 'diseno.dart';

/// 1.28 (M4-A12): número tolerante para el modelo — un
/// número como texto no tumba la pestaña.
double? _numTol(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
  return null;
}

class Medicion {
  final int id;
  // 1.28 (M4-A12/R1M4-M16): el id CRUDO de la medición. Las
  // filas nacidas de la vía de ops llevan un UUID por
  // medicion_id y el `int.tryParse` de la reconstrucción
  // offline lo dejaba en 0.
  // 1.32 (H-RPC-2): OJO al contrato real — ese UUID es la
  // identidad de la VÍA DE OPS, no la de las RPC de staff:
  // guardar_medicion_staff/eliminar_medicion declaran
  // p_medicion_id BIGINT y la tabla viva
  // (sync_progreso_mediciones) ni siquiera tiene columna
  // medicion_id; su identidad es la columna `id`. Enviar el
  // UUID a la RPC rebotaba con 400 disfrazado de «revisa la
  // conexión». Para las RPC manda [idServidor]; el UUID solo
  // sirve para localizar la op pendiente local.
  final String? idCrudo;
  final String clienteId;
  // 1.28 (M4-A12/R1M4-B19): nullable — una medición sin peso
  // (solo cintura, p. ej.) se pintaba «0.0 kg» inventado.
  final double? pesoKg;
  final double? grasaPct;
  final double? pechoCm;
  final double? cinturaCm;
  final double? caderaCm;
  final double? brazoCm;
  final double? musloCm;
  final String? notas;
  final String registradoPor;
  final DateTime createdAt;

  Medicion({
    required this.id,
    this.idCrudo,
    required this.clienteId,
    required this.pesoKg,
    this.grasaPct,
    this.pechoCm,
    this.cinturaCm,
    this.caderaCm,
    this.brazoCm,
    this.musloCm,
    this.notas,
    required this.registradoPor,
    required this.createdAt,
  });

  /// 1.32 (H-RPC-2): el id NUMÉRICO de servidor de la medición
  /// (la identidad que aceptan guardar_medicion_staff y
  /// eliminar_medicion, `p_medicion_id bigint`), o null si la
  /// fila solo tiene identidad local (UUID de la vía de ops):
  /// en ese caso NO se llama a la RPC con id — se edita/borra
  /// por la vía de ops. El entero del modelo manda; el crudo
  /// solo vale si también es numérico.
  int? get idServidor =>
      id > 0 ? id : int.tryParse((idCrudo ?? '').trim());

  factory Medicion.fromJson(Map<String, dynamic> j) {
    return Medicion(
      id: (j['id'] as num?)?.toInt() ??
          int.tryParse('${j['id'] ?? ''}') ??
          0,
      idCrudo: (j['medicion_id'] is String &&
              (j['medicion_id'] as String).isNotEmpty)
          ? j['medicion_id'] as String
          : (j['id'] is String && (j['id'] as String).isNotEmpty)
              ? j['id'] as String
              : null,
      clienteId: '${j['cliente_id'] ?? ''}',
      pesoKg: _numTol(j['peso_kg']),
      grasaPct: _numTol(j['grasa_pct']),
      pechoCm: _numTol(j['pecho_cm']),
      cinturaCm: _numTol(j['cintura_cm']),
      caderaCm: _numTol(j['cadera_cm']),
      brazoCm: _numTol(j['brazo_cm']),
      // La clave canónica es muslo_cm; 'pierna_cm' solo es lectura
      // defensiva por si un origen futuro la renombra (nunca se
      // escribe: el RPC sigue recibiendo p_muslo_cm).
      musloCm: _numTol(j['muslo_cm'] ?? j['pierna_cm']),
      notas: j['notas']?.toString(),
      registradoPor: '${j['registrado_por'] ?? ''}',
      // Autoauditoría 1.22 #2 (D-1): el respaldo NO puede ser
      // «ahora»: una medición con created_at corrupto se volvía
      // la más reciente (orden descendente) y, peor, EDITABLE
      // dentro de la ventana de 24 h. Respaldo neutro (época):
      // queda la última y fuera de la ventana de edición.
      createdAt: DateTime.tryParse('${j['created_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Parsea números aceptando coma decimal (teclados en español).
double? _parseNum(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

class PestanaProgreso extends StatefulWidget {
  final String clienteId;
  final String nombreCliente;

  const PestanaProgreso({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
  });

  @override
  State<PestanaProgreso> createState() => _PestanaProgresoState();
}

class _PestanaProgresoState extends State<PestanaProgreso> {
  List<Medicion> _mediciones = [];
  bool _cargando = true;
  String? _error;
  // 1.28 (M4-A12): diálogos de medición en curso — dos
  // toques apilaban dos formularios/confirmaciones.
  bool _dialogoMedicionAbierto = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// Reconstruye el modelo del RPC desde las filas planas
  /// del espejo local (medidas: peso_kg, grasa_pct, ...;
  /// fecha_medicion). Era el cuerpo del respaldo del catch.
  List<Medicion> _desdeEspejoLocal(
      List<Map<String, dynamic>> locales) {
    return locales.map((r) {
      final m = (r['medidas'] as Map?) ?? {};
      return Medicion.fromJson({
        // 1.28 (M4-A12): el medicion_id viaja CRUDO
        // (puede ser UUID de la vía de ops): el modelo
        // lo conserva en idCrudo; el int queda solo como
        // respaldo de orden. 1.32 (H-RPC-2): ese UUID
        // localiza la op pendiente para editar/borrar por
        // la vía de ops — a las RPC de staff solo va el id
        // numérico de servidor (Medicion.idServidor).
        'id': int.tryParse('${r['medicion_id'] ?? ''}') ?? 0,
        'medicion_id': '${r['medicion_id'] ?? ''}',
        'cliente_id': widget.clienteId,
        'peso_kg': m['peso_kg'],
        'grasa_pct': m['grasa_pct'],
        'pecho_cm': m['pecho_cm'],
        'cintura_cm': m['cintura_cm'],
        'cadera_cm': m['cadera_cm'],
        'brazo_cm': m['brazo_cm'],
        'muslo_cm': m['muslo_cm'],
        'notas': null,
        'registrado_por': '',
        // 1.23 AT-03: created_at = el instante real de
        // creación (creada_ts de la op / created_at del
        // espejo) si viene; la fecha plana solo como
        // último recurso de filas viejas sin instante.
        'created_at': ('${r['creado_en'] ?? ''}'.isNotEmpty)
            ? r['creado_en']
            : r['fecha_medicion'],
      });
    }).toList();
  }

  Future<void> _cargar() async {
    // Yunque B (YB-CLI-12): offline-first, como la ficha —
    // se pinta PRIMERO con el espejo local y la RPC
    // enriquece en segundo plano (con su timeout de 12 s).
    // Antes la pestaña esperaba la RPC y el espejo solo
    // entraba si esta FALLABA: sin conexión, «Cargando
    // progreso…» hasta 12 s con las mediciones ya en el
    // teléfono (la lección de la ficha del 2026-11-02).
    final cid = int.tryParse(widget.clienteId);
    var pintoLocal = false;
    try {
      final locales = cid == null
          ? <Map<String, dynamic>>[]
          : await medicionesClienteLocal(cid);
      if (mounted && locales.isNotEmpty) {
        setState(() {
          _mediciones = _desdeEspejoLocal(locales);
          _cargando = false;
          _error = null;
          pintoLocal = true;
        });
      }
    } catch (_) {
      // Espejo ilegible: no bloquea; la RPC sigue su curso.
    }
    if (!pintoLocal && mounted) {
      setState(() {
        _cargando = true;
        _error = null;
      });
    }
    try {
      final res = await Supabase.instance.client
          .rpc(
            'listar_mediciones_cliente',
            params: {'p_cliente_id': widget.clienteId},
          )
          .timeout(const Duration(seconds: 12));
      final lista = ((res as List?) ?? [])
          .map((e) =>
              Medicion.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (mounted) {
        setState(() {
          _mediciones = lista;
          _cargando = false;
          _error = null;
        });
      }
    } catch (e) {
      if (pintoLocal) {
        // Lo pintado manda: sin red se queda el espejo y el
        // fallo del refresco solo va a la bitácora.
        AppLog.error('progreso', 'refresco_fallo', d: '$e');
        return;
      }
      AppLog.error('progreso', 'cargar_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _error = 'Sin conexión y sin mediciones guardadas '
              'en este teléfono.';
          _cargando = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Progreso: ${widget.nombreCliente}'),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // Verificar permiso de visualización
    if (!PermisosEntrenador().canViewProgress &&
        !AuthService().isOwner) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xxl),
          child: Text(
            'No tienes permisos para visualizar el progreso.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ),
      );
    }

    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando progreso…');
    }

    if (_error != null) {
      // F6-06: antes se pintaba la excepción de PostgREST
      // íntegra; ahora EstadoError en claro con Reintentar.
      return EstadoError(
        titulo: 'No se pudo cargar el progreso',
        detalle: _error,
        onReintentar: _cargar,
      );
    }

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          // Botón de plan nutricional
          Card(
            child: ListTile(
              leading: const Icon(Icons.restaurant_menu_rounded,
                  color: AppColores.exito),
              title: const Text('Plan Nutricional'),
              subtitle: const Text(
                  'Ver o editar el plan del cliente'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.push(
                  context,
                  RutaIron(
                    builder: (_) => EditorPlanNutricional(
                      clienteId: widget.clienteId,
                      nombreCliente: widget.nombreCliente,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // Gráfico de peso (2+) o tarjeta resumen (1 medición).
          // Yunque R5-M9-4: la puerta cuenta PUNTOS DE PESO
          // VÁLIDOS, no mediciones: con 2 mediciones pero un
          // solo peso válido, antes no salía ni gráfica ni
          // tarjeta — un vacío mudo.
          if (puntosPesoValidos(_mediciones).length >= 2) ...[
            GraficoPesoEntrenador(mediciones: _mediciones),
            const SizedBox(height: 16),
            // 1.25 T109: el gráfico deja de ser solo del
            // peso — cintura, brazo y muslo ganan el suyo
            // cuando hay 2+ mediciones con ese dato.
            for (final (titulo, serie) in [
              ('Evolución de cintura',
                  serieMetricaOpcional(_mediciones, (m) => m.cinturaCm)),
              ('Evolución de brazo',
                  serieMetricaOpcional(_mediciones, (m) => m.brazoCm)),
              ('Evolución de muslo',
                  serieMetricaOpcional(_mediciones, (m) => m.musloCm)),
            ])
              if (serie.length >= 2) ...[
                GraficoMetricaGestion(
                    titulo: titulo, unidad: 'cm', puntos: serie),
                const SizedBox(height: 16),
              ],
          ] else if (puntosPesoValidos(_mediciones).length == 1 ||
              _mediciones.length == 1) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppEspacio.lg),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Evolución de peso',
                      style: AppTexto.titulo,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      // R5-M9-4: «último» = el último peso
                      // VÁLIDO (la lista llega recientes
                      // primero), no el de la primera
                      // medición de la lista.
                      () {
                        final validos = [
                          for (final m in _mediciones)
                            if (m.pesoKg != null &&
                                m.pesoKg! > 0 &&
                                m.createdAt.year >= 2000)
                              m.pesoKg!,
                        ];
                        return validos.isEmpty
                            ? 'Último: sin peso registrado'
                            : 'Último: ${validos.first.toStringAsFixed(1)} kg';
                      }(),
                      style:
                          AppTexto.displayPequeno,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Botón registrar (solo con permiso). Con la
          // lista vacía no se pinta: la acción vive en el
          // EstadoVacio (F6-08), para no duplicar botones.
          if (_mediciones.isNotEmpty &&
              (PermisosEntrenador().canRecordMeasurements ||
                  AuthService().isOwner))
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Registrar medición'),
                onPressed: () =>
                    _mostrarFormulario(context, null),
              ),
            ),
          const SizedBox(height: 16),

          // Lista de mediciones
          if (_mediciones.isEmpty)
            EstadoVacio(
              icono: Icons.monitor_weight_rounded,
              titulo: 'Sin mediciones registradas',
              subtitulo: 'Registra la primera medición para '
                  'empezar a ver la evolución del peso.',
              textoAccion: (PermisosEntrenador()
                          .canRecordMeasurements ||
                      AuthService().isOwner)
                  ? 'Registrar medición'
                  : null,
              onAccion: () => _mostrarFormulario(context, null),
            )
          else ...[
            ..._mediciones
                .take(20)
                .map((m) => _buildMedicionCard(m)),
            // F6-08/F6-21: el corte a 20 se decía en
            // silencio; ahora se cuenta.
            if (_mediciones.length > 20)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Mostrando las 20 más recientes de '
                  '${_mediciones.length} mediciones.',
                  textAlign: TextAlign.center,
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildMedicionCard(Medicion m) {
    // 1.23 AT-03: la ventana de 24 h se mide entre INSTANTES
    // (ahora UTC real contra el created_at llevado a UTC):
    // con DateTime.now() del dispositivo y un created_at
    // reconstruido desde la fecha plana, la ventana se cerraba
    // horas antes de tiempo (o se abría de más, según la zona
    // del teléfono).
    // 1.28 (M4-A12/R1M4-B21): la ventana exige diferencia
    // NO negativa — un created_at FUTURO (reloj corrido)
    // daba diferencia negativa < 24 y la fila quedaba
    // editable «para siempre» para el entrenador.
    final difHorasVentana =
        ahoraUtcReal().difference(m.createdAt.toUtc()).inHours;
    final puedeEditar = AuthService().isOwner ||
        (PermisosEntrenador().canRecordMeasurements &&
            difHorasVentana >= 0 &&
            difHorasVentana < 24);

    return Card(
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: ListTile(
        title: Text(
          m.pesoKg == null
              ? 'Sin peso registrado'
              : '${m.pesoKg!.toStringAsFixed(1)} kg',
          style: AppTexto.titulo,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${fmtFechaHabana(m.createdAt)} • Por: ${m.registradoPor}',
              style: AppTexto.metadato,
            ),
            // 1.25 T123 (F6-21): las notas ya venían en el
            // modelo y solo se veían abriendo el detalle.
            if (m.notas != null && m.notas!.isNotEmpty)
              Text(
                m.notas!,
                style: AppTexto.secundario,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            // v1.4.0: solo medidas visibles (sin % grasa/pecho/cadera).
            if (m.cinturaCm != null || m.brazoCm != null || m.musloCm != null)
              Text(
                [
                  if (m.cinturaCm != null)
                    'Cintura ${m.cinturaCm!.toStringAsFixed(1)}',
                  if (m.brazoCm != null)
                    'Brazo ${m.brazoCm!.toStringAsFixed(1)}',
                  if (m.musloCm != null)
                    'Pierna ${m.musloCm!.toStringAsFixed(1)}',
                ].join(' · '),
                style: AppTexto.metadato,
              ),
          ],
        ),
        trailing: puedeEditar
            ? PopupMenuButton<String>(
                popUpAnimationStyle: estiloAparicionMenu,
                onSelected: (v) {
                  if (v == 'editar') {
                    _mostrarFormulario(context, m);
                  } else if (v == 'eliminar') {
                    _confirmarEliminar(m);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'editar',
                      child: Text('Editar')),
                  const PopupMenuItem(
                      value: 'eliminar',
                      child: Text('Eliminar',
                          style:
                              TextStyle(color: AppColores.error))),
                ],
              )
            : null,
        onTap: () => _verDetalle(m),
      ),
    );
  }

  void _verDetalle(Medicion m) {
    // F6-08: DialogoApp compartido (antes AlertDialog crudo).
    showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: m.pesoKg == null
            ? 'Medición sin peso'
            : '${m.pesoKg!.toStringAsFixed(1)} kg',
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Fecha: ${fmtFechaHabana(m.createdAt)}'),
            Text('Registrado por: ${m.registradoPor}'),
            // v1.4.0: el detalle solo muestra las medidas visibles.
            if (m.cinturaCm != null)
              Text(
                  'Cintura: ${m.cinturaCm!.toStringAsFixed(1)} cm'),
            if (m.brazoCm != null)
              Text(
                  'Brazo: ${m.brazoCm!.toStringAsFixed(1)} cm'),
            if (m.musloCm != null)
              Text(
                  'Pierna: ${m.musloCm!.toStringAsFixed(1)} cm'),
            if (m.notas != null && m.notas!.isNotEmpty)
              Text('Notas: ${m.notas}'),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarFormulario(
      BuildContext context, Medicion? existente) async {
    if (_dialogoMedicionAbierto) return;
    _dialogoMedicionAbierto = true;
    try {
      await _mostrarFormularioFlujo(context, existente);
    } finally {
      _dialogoMedicionAbierto = false;
    }
  }

  Future<void> _mostrarFormularioFlujo(
      BuildContext context, Medicion? existente) async {
    // v1.4.0 (Paso 3, diseño de Argón): el formulario solo muestra
    // Peso, Cintura, Brazo y Pierna. % grasa, pecho y cadera quedan
    // en la BD: al EDITAR se reenvían los valores previos de la
    // medición (el RPC es de reemplazo completo y no puede cambiar
    // de firma); al CREAR van en null, como hasta ahora.
    // 1.29 (Oleada 4, barrido): el formulario vive en un
    // StatefulWidget dueño de sus controladores
    // (_DialogoMedicion). Antes se creaban aquí y se
    // disponían nada más resolver el showDialog, con la
    // animación de salida aún reconstruyendo los campos:
    // el «used after being disposed» que Jc cazó en campo
    // en «Registrar medida» (el FIX 2 anterior solo evitaba
    // perder los valores, no el uso tras el dispose).
    final valores = await showDialog<
        ({
          String peso,
          String cintura,
          String brazo,
          String muslo,
          String notas
        })>(
      context: context,
      builder: (_) => _DialogoMedicion(existente: existente),
    );
    if (valores == null || !mounted) return;
    final pesoStr = valores.peso;
    final cinturaStr = valores.cintura;
    final brazoStr = valores.brazo;
    final musloStr = valores.muslo;
    final notasStr = valores.notas;

    final peso = _parseNum(pesoStr);
    if (peso == null) {
      if (mounted) {
        mostrarSnack(context, 'El peso es requerido', significado: SignificadoChip.alerta);
      }
      return;
    }
    // 1.28 (M4-A12/R1M4-M17): el formulario aplica los
    // RANGOS cerrados de la casa (kMetricasMedicion) antes
    // de llamar a la RPC — antes solo exigía peso > 0 y un
    // peso de 900 kg o una cintura de 3 cm viajaban al
    // servidor y reventaban allí (o quedaban guardados).
    final medidasForm = <String, double>{
      'peso_kg': peso,
      if (_parseNum(cinturaStr) != null)
        'cintura_cm': _parseNum(cinturaStr)!,
      if (_parseNum(brazoStr) != null) 'brazo_cm': _parseNum(brazoStr)!,
      if (_parseNum(musloStr) != null) 'muslo_cm': _parseNum(musloStr)!,
    };
    final errorRango = validarMedicion(medidasForm);
    if (errorRango != null) {
      if (mounted) {
        mostrarSnack(context, errorRango,
            significado: SignificadoChip.alerta);
      }
      return;
    }

    // 1.32 (H-RPC-2): editar una medición que solo tiene
    // identidad local (UUID de la vía de ops) NO va a la RPC
    // de staff: p_medicion_id es bigint y el UUID rebotaba
    // con 400 disfrazado de fallo de conexión. Va por la vía
    // de ops: si su op aún está pendiente en este teléfono se
    // cancela y se encola la corregida (la fila nunca salió);
    // si ya se sincronizó, la corrección entra como fila
    // nueva — el modelo de mediciones es inmutable: una
    // corrección es una fila posterior.
    if (existente != null && existente.idServidor == null) {
      final cidOps = int.tryParse(widget.clienteId);
      if (cidOps == null) {
        if (mounted) {
          mostrarSnack(context,
              'No se pudo guardar la medición.',
              significado: SignificadoChip.error);
        }
        return;
      }
      final eraPendiente = await cancelarMedicionPendienteSiExiste(
          existente.idCrudo ?? '');
      try {
        await registrarMedicionCliente(
          clienteId: cidOps,
          medidas: {
            ...medidasForm,
            if (existente.grasaPct != null)
              'grasa_pct': existente.grasaPct!,
            if (existente.pechoCm != null)
              'pecho_cm': existente.pechoCm!,
            if (existente.caderaCm != null)
              'cadera_cm': existente.caderaCm!,
          },
        );
      } catch (e) {
        AppLog.error('progreso', 'guardar_medicion_ops_fallo',
            d: '$e');
        if (mounted) {
          mostrarSnack(context,
              'No se pudo guardar la medición: $e',
              significado: SignificadoChip.error);
        }
        return;
      }
      if (mounted) {
        mostrarSnack(
            context,
            eraPendiente
                ? 'Medición actualizada'
                : 'La medición ya estaba sincronizada: la '
                    'corrección quedó registrada como una '
                    'medición nueva.',
            significado: SignificadoChip.exito);
        _cargar();
      }
      return;
    }

    try {
      await Supabase.instance.client
          .rpc('guardar_medicion_staff', params: {
        'p_cliente_id': widget.clienteId,
        'p_peso_kg': peso,
        // v1.4.0: campos ocultos en la UI. Al editar se conservan los
        // valores previos; al crear van en null (igual que antes).
        'p_grasa_pct': existente?.grasaPct,
        'p_pecho_cm': existente?.pechoCm,
        'p_cintura_cm': _parseNum(cinturaStr),
        'p_cadera_cm': existente?.caderaCm,
        'p_brazo_cm': _parseNum(brazoStr),
        'p_muslo_cm': _parseNum(musloStr),
        'p_notas': notasStr.trim().isEmpty ? null : notasStr.trim(),
        // 1.32 (H-RPC-2): SOLO el id numérico de servidor
        // (idServidor), null al crear. El UUID de la vía de
        // ops jamás viaja aquí: la RPC declara bigint y la
        // tabla viva no tiene columna medicion_id (el
        // comentario de la 1.28 afirmaba el contrato al
        // revés y el UUID rebotaba con 400).
        'p_medicion_id': existente?.idServidor,
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        mostrarSnack(context, 'Medición guardada', significado: SignificadoChip.exito);
        _cargar();
      }
    } catch (e) {
      AppLog.error('progreso', 'guardar_medicion_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudo guardar la medición. Revisa la '
            'conexión e inténtalo de nuevo.',
            significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _confirmarEliminar(Medicion m) async {
    if (_dialogoMedicionAbierto) return;
    _dialogoMedicionAbierto = true;
    try {
      await _confirmarEliminarFlujo(m);
    } finally {
      _dialogoMedicionAbierto = false;
    }
  }

  Future<void> _confirmarEliminarFlujo(Medicion m) async {
    // F6-08: confirmación compartida (antes AlertDialog
    // crudo con el botón en Colors.red).
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Eliminar medición',
      mensaje: m.pesoKg == null
          ? 'Se elimina esta medición. No se puede deshacer.'
          : 'Se elimina la medición de '
              '${m.pesoKg!.toStringAsFixed(1)} kg. No se puede '
              'deshacer.',
      aceptar: 'Eliminar',
      peligro: true,
    );
    if (!ok || !mounted) return;
    // 1.32 (H-RPC-2): borrar una medición que solo tiene
    // identidad local (UUID de la vía de ops) tampoco va a la
    // RPC (bigint): si su op aún está pendiente aquí, se
    // cancela y la fila desaparece; si ya se sincronizó, aquí
    // aún no tiene su número de servidor y se dice con
    // claridad en vez de disparar una RPC condenada al 400 —
    // con conexión, la lista se repone desde el servidor ya
    // con el id numérico y el borrado sale por la RPC.
    if (m.idServidor == null) {
      final cancelada =
          await cancelarMedicionPendienteSiExiste(m.idCrudo ?? '');
      if (mounted) {
        if (cancelada) {
          mostrarSnack(context, 'Medición eliminada',
              significado: SignificadoChip.exito);
          _cargar();
        } else {
          mostrarSnack(context,
              'Esta medición ya está en el servidor y en este '
              'teléfono aún no tiene su número: conéctate, '
              'actualiza la lista y vuelve a intentarlo.',
              significado: SignificadoChip.alerta);
        }
      }
      return;
    }
    try {
      // 1.32 (B1-H7): la RPC devuelve un BOOLEAN (¿borró de
      // verdad?): un false significa «ya no estaba» (otra
      // sesión la borró) y no puede anunciarse como si se
      // hubiera borrado ahora — la lista se recarga igual
      // para que la fila desaparezca de pantalla.
      final res = await Supabase.instance.client
          .rpc('eliminar_medicion', params: {
            // 1.32 (H-RPC-2): solo el id numérico de servidor.
            'p_medicion_id': m.idServidor,
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        if (res == true) {
          mostrarSnack(context, 'Medición eliminada',
              significado: SignificadoChip.exito);
        } else {
          mostrarSnack(context,
              'Esa medición ya no estaba en el servidor',
              significado: SignificadoChip.alerta);
        }
        _cargar();
      }
    } catch (e) {
      AppLog.error('progreso', 'eliminar_medicion_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudo eliminar la medición. Revisa la '
            'conexión e inténtalo de nuevo.',
            significado: SignificadoChip.error);
      }
    }
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): formulario de
/// medición como StatefulWidget DUEÑO de sus cinco
/// controladores, dispuestos en dispose() — el patrón de la
/// casa. Devuelve los textos tecleados por Navigator.pop;
/// cancelar devuelve null. El parseo, los rangos y la RPC
/// siguen en la pestaña, como siempre.
class _DialogoMedicion extends StatefulWidget {
  const _DialogoMedicion({required this.existente});

  final Medicion? existente;

  @override
  State<_DialogoMedicion> createState() => _DialogoMedicionState();
}

class _DialogoMedicionState extends State<_DialogoMedicion> {
  late final TextEditingController _pesoCtrl;
  late final TextEditingController _cinturaCtrl;
  late final TextEditingController _brazoCtrl;
  late final TextEditingController _musloCtrl;
  late final TextEditingController _notasCtrl;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _pesoCtrl =
        TextEditingController(text: e?.pesoKg?.toString() ?? '');
    _cinturaCtrl =
        TextEditingController(text: e?.cinturaCm?.toString() ?? '');
    _brazoCtrl =
        TextEditingController(text: e?.brazoCm?.toString() ?? '');
    _musloCtrl =
        TextEditingController(text: e?.musloCm?.toString() ?? '');
    _notasCtrl = TextEditingController(text: e?.notas ?? '');
  }

  @override
  void dispose() {
    _pesoCtrl.dispose();
    _cinturaCtrl.dispose();
    _brazoCtrl.dispose();
    _musloCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  void _guardar() {
    Navigator.pop(
        context,
        (
          peso: _pesoCtrl.text,
          cintura: _cinturaCtrl.text,
          brazo: _brazoCtrl.text,
          muslo: _musloCtrl.text,
          notas: _notasCtrl.text,
        ));
  }

  @override
  Widget build(BuildContext context) {
    // F6-08: DialogoApp compartido.
    return DialogoApp(
      titulo:
          widget.existente == null ? 'Nueva medición' : 'Editar medición',
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _pesoCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Peso (kg) *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cinturaCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Cintura (cm)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _brazoCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Brazo (cm)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _musloCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Pierna (cm)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notasCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notas',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        BotonPrimario(
          texto: 'Guardar',
          onPressed: _guardar,
          expandido: false,
        ),
      ],
    );
  }
}
