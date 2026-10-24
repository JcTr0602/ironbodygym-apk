/// Ficha del cliente: foto, datos, edad del carnet, notas,
/// estado de pago, edición y registro de pagos.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../permisos_entrenador.dart';
import '../app_log.dart';
import '../tiempo.dart';
import '../fotos.dart';
import '../fotos_cola.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../servicios.dart' as servicios_svc;
import '../sync.dart';
import '../acceso_app_cache.dart';
import 'componentes.dart';
import 'dialogo_pago.dart';
import 'confirmacion_cobro.dart';
import 'diseno.dart';
import 'editor_foto.dart';
import 'modal_pin_acceso.dart';
import 'pestana_progreso.dart';
import 'vista_previa_cliente.dart';
import 'widgets.dart';

class FichaScreen extends StatefulWidget {
  final int clienteId;
  const FichaScreen({super.key, required this.clienteId});
  @override
  State<FichaScreen> createState() => _FichaScreenState();
}

class _FichaScreenState extends State<FichaScreen> {
  Map<String, dynamic>? _c;
  List<Map<String, dynamic>> _pagos = [];
  List<Map<String, dynamic>> _suplementos = [];
  // v1.2.5 (#10): incidencias relacionadas con el cliente.
  List<Map<String, dynamic>> _incidencias = [];
  File? _foto;

  /// Etapa 4 · F2: generación de la foto mostrada. La carga en
  /// segundo plano captura el valor y solo aplica su resultado si
  /// no cambió: eliminar o reemplazar la foto lo incrementa y una
  /// descarga vieja ya no puede resucitar la foto anterior.
  int _fotoGen = 0;
  bool _verificando = false;
  // v1.3.3 (Argón spec 2): regalo de cumpleaños del año en curso, si ya
  // se otorgó. Candado anual + botón "Reenviar WhatsApp".
  Map<String, dynamic>? _regaloAnio;
  // v1.3.9 (F1): estado del acceso a la App de Clientes.
  // null = sin acceso o caché no cargado; _accesoSinConexion = true si
  // no se pudo verificar por falta de red.
  bool _accesoSinConexion = false;
  // v1.8.0: historial de servicios por dosis del cliente.
  List<Map<String, dynamic>> _serviciosHist = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final c = await clientePorId(widget.clienteId);
    final pagos = await pagosDe(widget.clienteId);
    final suplementos = await _suplementosDe(widget.clienteId);
    final serviciosHist = await servicios_svc
        .historialServiciosCliente(widget.clienteId);
    // v1.2.5 (#10): incidencias relacionadas (respeta visibilidad).
    final incidencias = await LocalDb.instance.incidenciasRelacionadas(
        'cliente', widget.clienteId,
        soloCompartidas: !AuthService().isAdmin);
    // v1.3.3 (Argón spec 2): ¿ya se regaló este año?
    final regaloAnio = await _regaloDelAnio(widget.clienteId);
    // v1.3.9 (F1): cargar caché de accesos (solo dueño, tolerante a offline).
    bool accesoSinConexion = false;
    if (AuthService().isOwner && !AccesoAppCache.instance.cargado) {
      final ok = await AccesoAppCache.instance.cargar();
      if (!ok) accesoSinConexion = true;
    }
    if (mounted) {
      setState(() {
        _c = c;
        _pagos = pagos;
        _suplementos = suplementos;
        _serviciosHist = serviciosHist;
        _incidencias = incidencias;
        _foto = null;
        _regaloAnio = regaloAnio;
        _accesoSinConexion = accesoSinConexion;
      });
    }
    // v1.3.6 (reporte de campo): la foto carga en SEGUNDO PLANO sin
    // bloquear la ficha. Con red lenta, el await de FotoCache.obtener
    // (descarga) dejaba la pantalla en spinner indefinido. Ahora los
    // datos se muestran de inmediato con el avatar de iniciales y,
    // al llegar la foto, solo se actualiza ese widget.
    if (c != null) {
      // Si hay una eliminación local pendiente, el espejo aún
      // trae foto_storage hasta sincronizar: la foto NO se
      // muestra ni se descarga (etapa 4 · F2: la intención
      // pendiente manda también al pintar; corrección del
      // panel — una carga NUEVA, no solo una en vuelo, podía
      // resucitar la foto eliminada al reabrir la ficha).
      final intencion = await LocalDb.instance
          .ultimaIntencionFoto(widget.clienteId);
      if (intencion != 'eliminar') {
        final gen = _fotoGen;
        final foto = await FotoCache.instance
            .obtener(c['foto_storage'] as String?);
        // Si mientras descargaba se eliminó o se puso otra foto,
        // el resultado ya es viejo: no resucitarla.
        if (mounted && gen == _fotoGen && foto != null) {
          setState(() => _foto = foto);
        }
      }
    }
  }

  /// Regalo de cumpleaños del año en curso (Argón spec 2): candado anual.
  /// Retorna {'anterior': ..., 'nuevo': ...} o null si no se ha regalado.
  /// Fuentes: 1) meta local (inmediata, offline); 2) espejo de pagos con
  /// metodo='cortesia' del año actual, hora de La Habana (autoritativo
  /// tras sincronizar).
  Future<Map<String, dynamic>?> _regaloDelAnio(int clienteId) async {
    final anio = '${ahoraHabana().year}';
    try {
      final meta = await LocalDb.instance
          .getMeta('regalo_cumple_${clienteId}_$anio');
      if (meta != null) {
        final m = jsonDecode(meta) as Map<String, dynamic>;
        return {'anterior': m['anterior'], 'nuevo': m['nuevo']};
      }
    } catch (_) {}
    try {
      Map<String, dynamic>? mejor;
      // v1.3.4 (ítem 2): lectura indexada (cliente_id, fecha) + metodo,
      // en vez de allMirror('pagos') + filtro en Dart. Incluye fallback
      // para filas con columnas NULL.
      for (final p in await LocalDb.instance
          .pagosCortesiaClienteAnio(clienteId, anio)) {
        if (mejor == null ||
            '${p['fecha']}'.compareTo('${mejor['fecha']}') > 0) {
          mejor = p;
        }
      }
      if (mejor != null) {
        final nuevo = '${mejor['pagado_hasta'] ?? ''}';
        String? anterior;
        try {
          final d = DateTime.parse(nuevo.substring(0, 10))
              .subtract(const Duration(days: 30));
          anterior = '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
        } catch (_) {}
        return {'anterior': anterior, 'nuevo': nuevo};
      }
    } catch (_) {}
    return null;
  }

  /// v1.2.2: historial de suplementos comprados por el cliente.
  /// La tabla usa columna data (JSON), se filtra con json_extract.
  Future<List<Map<String, dynamic>>> _suplementosDe(int clienteId) async {
    try {
      final db = await LocalDb.instance.db;
      final rows = await db.rawQuery('''
        SELECT id, data FROM ventas_suplementos
        WHERE json_extract(data, '\$.cliente_id') = ?
          AND json_extract(data, '\$.anulado') IS NULL
        ORDER BY json_extract(data, '\$.fecha') DESC
        LIMIT 20
      ''', [clienteId]);
      return rows.map((r) {
        try {
          final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
          return {
            'id': r['id'],
            ...data,
          };
        } catch (_) {
          return <String, dynamic>{};
        }
      }).where((m) => m.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// Verifica los datos del cliente contra el servidor (v1.0.10).
  /// Descarga la versión actual y compara con la local.
  /// v1.2.8 (E1): verifica un solo cliente vía RPC, sin pull completo.
  /// El RPC obtener_estado_cliente está en Supabase (SECURITY INVOKER).
  Future<void> _verificarServidor() async {
    if (_verificando) return;
    setState(() => _verificando = true);
    try {
      final messenger = ScaffoldMessenger.of(context);
      final antes = _c;
      // Llamada RPC puntual (no dispara el pipeline de sync).
      final res = await Supabase.instance.client
          .rpc('obtener_estado_cliente', params: {'p_id': widget.clienteId});
      if (res != null) {
        // Actualizar solo este cliente en el mirror local.
        final data = res is String ? jsonDecode(res) : Map<String, dynamic>.from(res as Map);
        final dataJson = jsonEncode(data['data'] ?? data);
        final db = await LocalDb.instance.db;
        await db.insert(
          'clientes',
          {
            'id': widget.clienteId,
            'data': dataJson,
            'sync_seq': (data['sync_seq'] as int?) ?? 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        // Actualizar FTS también.
        try {
          await LocalDb.instance.actualizarFtsCliente(widget.clienteId, dataJson, null);
        } catch (_) {}
      }
      await _cargar();
      if (!mounted) return;
      final despues = _c;
      // Comparar campos clave
      final cambios = <String>[];
      if (antes != null && despues != null) {
        for (final k in [
          'pagado_hasta',
          'estado',
          'telefono',
          'foto_storage',
          'nombre'
        ]) {
          if ('${antes[k]}' != '${despues[k]}') {
            cambios.add(k);
          }
        }
      }
      if (cambios.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Datos al día con el servidor'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
                'Actualizado desde el servidor: ${cambios.join(', ')}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al verificar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  /// v1.7.0: pasa el cliente a Cuenta a la Casa o se la quita
  /// (solo dueño — el menú que la invoca ya es solo del dueño).
  /// Confirma con motivo opcional, encola la op `cuenta_casa`
  /// (contrato en negocio.dart: payloadOpCuentaCasa) y refleja el
  /// cambio en el espejo local de forma optimista. El servidor
  /// revalida que el actor sea admin (blindaje de Argón).
  Future<void> _cambiarCuentaCasa(bool activar) async {
    final c = _c;
    if (c == null || !AuthService().isOwner) return;
    final nombre = '${c['nombre'] ?? ''}';
    final ctrl = TextEditingController();
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: activar
            ? 'Pasar a Cuenta a la Casa'
            : 'Quitar Cuenta a la Casa',
        iconoTitulo: Icons.home_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(activar
                ? '$nombre tendrá acceso permanente sin pagar ni '
                    'vencer. No contará en nómina, vencimientos ni '
                    'ingresos.'
                : '$nombre volverá a ser un cliente normal: regirá '
                    'su «pagado hasta» actual.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej.: hermana del dueño, cortesía…',
                border: OutlineInputBorder(),
              ),
              maxLength: 120,
            ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(activar ? 'Pasar a la Casa' : 'Quitar'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (motivo == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cuenta_casa',
      payload: payloadOpCuentaCasa(
          clienteId: widget.clienteId,
          activar: activar,
          motivo: motivo),
    );
    // Reflejo optimista en el espejo (JSON + columnas dedicadas).
    await LocalDb.instance.updateMirrorCuentaCasa(
      widget.clienteId,
      activar: activar,
      motivo: motivo.isEmpty ? null : motivo,
      enIso: isoHabana(ahoraHabana()),
      por: AuthService().displayName,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(activar
            ? 'Cuenta a la Casa activada (se sincronizará)'
            : 'Cuenta a la Casa retirada (se sincronizará)')));
    SyncEngine.instance.push();
    _cargar();
  }

  Future<void> _pagar() async {
    final c = _c;
    if (c == null) return;
    // v1.7.0: cobrar a una Cuenta a la Casa es permitido pero
    // inútil (nunca vence y no necesita pagar): aviso previo.
    if (esCuentaCasa(c)) {
      final seguir = await DialogoApp.confirmar(
        context,
        titulo: 'Cuenta a la Casa',
        mensaje: 'Esta cuenta no necesita pagar: tiene acceso '
            'permanente sin vencimiento. Cobrarle un mes no cambia '
            'nada.\n\n¿Cobrar igual?',
        aceptar: 'Cobrar igual',
        icono: Icons.home_rounded,
      );
      if (seguir != true || !mounted) return;
    }
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    // v1.0.11: si es el dueño quien cobra, se marca entregado automáticamente
    // (no tiene sentido que se deba dinero a sí mismo)
    if (AuthService().isOwner) {
      payload['entregado'] = 1;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    // Pantalla de confirmación fullscreen (v1.0.6)
    final monto = '${payload['monto'] ?? ''} CUP';
    final venc = '${payload['pagado_hasta'] ?? ''}'.substring(0, 10);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfirmacionCobroScreen(
          nombreCliente: '${c['nombre'] ?? ''}',
          monto: monto,
          nuevoVencimiento: venc,
        ),
      ),
    );
    if (!mounted) return;
    _cargar();
    SyncEngine.instance.push();
  }

  /// v1.3.3: Regala 1 mes de membresía por cumpleaños (solo dueño).
  /// Offline-first: actualiza el espejo local de forma optimista, encola
  /// la operación y muestra el diálogo de WhatsApp INMEDIATAMENTE sin
  /// esperar a la sincronización.
  /// Regala 1 mes de membresía por cumpleaños (solo dueño).
  /// Offline-first: actualiza el espejo local de forma optimista, encola
  /// la operación y muestra el diálogo de WhatsApp INMEDIATAMENTE sin
  /// esperar a la sincronización.
  ///
  /// v1.3.3 (Argón specs):
  /// - spec 2: candado anual — un regalo por año. Si ya se otorgó este
  ///   año, se va directo al reenvío del mensaje (sin regalar de nuevo).
  /// - spec 6: 1 mes = 30 días (regla del gym, igual que previewHasta
  ///   para las renovaciones normales; NO mes calendario).
  /// - spec 3: prioriza c['movil'] sobre c['telefono'] — muchos clientes
  ///   tienen el carnet (11 dígitos) en 'telefono'.
  Future<void> _regalarMes() async {
    final c = _c;
    if (c == null || !mounted) return;
    // Candado anual: si ya se regaló este año, solo reenviar el mensaje.
    if (_regaloAnio != null) {
      await _reenviarWhatsApp();
      return;
    }
    final nombre = '${c['nombre'] ?? ''}';
    final pagadoHastaActual = c['pagado_hasta'] as String?;
    // Calcula el nuevo vencimiento localmente (30 días desde lo vigente).
    final nuevoHasta = previewHastaDias(pagadoHastaActual, 30);
    final hastaFmt = fmtFecha(nuevoHasta);
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🎁 Regalar mensualidad'),
        content: Text('¿Regalar 1 mes a $nombre?\nVálido hasta $hastaFmt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Regalar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    // a) Actualización optimista en el espejo local.
    await LocalDb.instance
        .updateMirrorPagadoHasta(widget.clienteId, nuevoHasta);
    // b) Encolar la operación para el servidor.
    // v1.3.3 (Argón): incluir 'fecha' para que el servidor use el día del
    // regalo, no el día de la sincronización (desfase si se regala offline).
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'regalar_mes_cumpleanos',
      payload: {
        'cliente_id': widget.clienteId,
        'fecha': isoHabana(ahoraHabana()).substring(0, 10), // v1.3.3 (Argón): fecha de negocio en hora de La Habana, no DateTime.now() crudo
      },
    );
    // b2) Guardar datos del mensaje para reenvíos futuros (candado local).
    final anio = '${ahoraHabana().year}';
    await LocalDb.instance.setMeta(
        'regalo_cumple_${widget.clienteId}_$anio',
        jsonEncode(
            {'anterior': pagadoHastaActual, 'nuevo': nuevoHasta}));
    // c) Disparar sincronización sin esperar.
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    _cargar();
    // d) Mostrar INMEDIATAMENTE el diálogo de WhatsApp.
    await _mostrarDialogoWhatsApp(
      nombre: nombre,
      hastaFmt: _fmtFechaLarga(nuevoHasta),
      anteriorFmt: (pagadoHastaActual != null &&
              pagadoHastaActual.length >= 10)
          ? _fmtFechaLarga(pagadoHastaActual)
          : null,
    );
  }

  /// Reenvía el mensaje de WhatsApp del regalo ya otorgado este año
  /// (Argón spec 2): no aplica otro mes, solo reabre el diálogo.
  Future<void> _reenviarWhatsApp() async {
    final c = _c;
    if (c == null || !mounted) return;
    final r = _regaloAnio;
    String? anterior = r?['anterior'] as String?;
    var nuevo = r?['nuevo'] as String?;
    nuevo ??= c['pagado_hasta'] as String?;
    if (nuevo == null || nuevo.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay datos del regalo para reenviar')));
      return;
    }
    await _mostrarDialogoWhatsApp(
      nombre: '${c['nombre'] ?? ''}',
      hastaFmt: _fmtFechaLarga(nuevo),
      anteriorFmt:
          (anterior != null && anterior.length >= 10) ? _fmtFechaLarga(anterior) : null,
    );
  }

  /// Diálogo de WhatsApp para el regalo (nuevo o reenvío).
  /// Argón spec 4: incluye campo de teléfono editable; si no hay número
  /// válido, permite escribirlo, guardarlo en la ficha y abrir WhatsApp.
  Future<void> _mostrarDialogoWhatsApp({
    required String nombre,
    required String hastaFmt,
    required String? anteriorFmt,
  }) async {
    final c = _c;
    String telefono = '';
    for (final raw in ['${c?['movil'] ?? ''}', '${c?['telefono'] ?? ''}']) {
      final norm = _normalizarTelefono(raw);
      if (norm.isNotEmpty) {
        telefono = norm;
        break;
      }
    }
    final telCtrl = TextEditingController(text: telefono);
    final mensaje = _mensajeRegalo(
        nombre: nombre, hastaFmt: hastaFmt, anteriorFmt: anteriorFmt);
    if (!mounted) return;
    final outerContext = context;
    await showDialog<void>(
      context: outerContext,
      builder: (ctx) => AlertDialog(
        title: const Text('📱 Notificar por WhatsApp'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(mensaje),
              const SizedBox(height: 12),
              TextField(
                controller: telCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Teléfono',
                  hintText: 'Ej. 58123456',
                  prefixText: '+',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: mensaje));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(outerContext).showSnackBar(
                const SnackBar(content: Text('Mensaje copiado')),
              );
            },
            child: const Text('Copiar mensaje'),
          ),
          ElevatedButton(
            onPressed: () async {
              final tel = _normalizarTelefono(telCtrl.text);
              if (tel.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text(
                        'Teléfono inválido: 8 dígitos empezando con 5 o 6')));
                return;
              }
              // Guardar el teléfono en la ficha si cambió (Argón spec 4).
              // Veredicto de Argón: guardar SIEMPRE los 8 dígitos (sin el
              // 53), porque validarTelefono() en el resto de la app exige
              // d.length == 8; 10 dígitos romperían el formulario normal.
              final actual = _normalizarTelefono('${c?['telefono'] ?? ''}');
              if (tel != actual) {
                final tel8 = tel.length == 10 ? tel.substring(2) : tel;
                await LocalDb.instance.updateMirrorTelefono(
                    widget.clienteId, tel8);
                await LocalDb.instance.queueOp(
                  opUuid: const Uuid().v4(),
                  tipo: 'editar_cliente',
                  payload: {
                    'cliente_id': widget.clienteId,
                    'telefono': tel8,
                  },
                );
                unawaited(SyncEngine.instance.push());
              }
              final url = Uri.parse(
                  'https://wa.me/$tel?text=${Uri.encodeComponent(mensaje)}');
              await launchUrl(url, mode: LaunchMode.externalApplication);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Abrir WhatsApp'),
          ),
        ],
      ),
    );
  }

  /// Mensaje de felicitación con formato WhatsApp (Argón spec 5):
  /// fechas anterior/nueva, saltos de línea y *negritas*.
  String _mensajeRegalo({
    required String nombre,
    required String hastaFmt,
    required String? anteriorFmt,
  }) {
    final b = StringBuffer();
    b.writeln('📩 Mensaje enviado por el sistema de gestión de Iron Body Gym:');
    b.writeln('¡Feliz cumpleaños, *$nombre*! 🎂🎉');
    b.writeln('Te hemos regalado 1 mensualidad por tu día.');
    if (anteriorFmt != null) {
      b.writeln('📅 Vencía el: *$anteriorFmt*');
      b.writeln('✅ Nuevo vencimiento: *$hastaFmt*');
      b.writeln('¡A seguir dándole duro! — Iron Body Gym 💪🔥');
    } else {
      b.writeln('✅ Válida hasta el: *$hastaFmt*');
      b.writeln('¡Te esperamos para entrenar! — Iron Body Gym 💪🔥');
    }
    return b.toString();
  }

  /// "2026-12-05" → "5 de diciembre".
  String _fmtFechaLarga(String? iso) {
    if (iso == null || iso.length < 10) return '—';
    const meses = [
      '',
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre'
    ];
    final p = iso.substring(0, 10).split('-');
    final m = int.tryParse(p[1]) ?? 0;
    return '${int.tryParse(p[2]) ?? p[2]} de ${m >= 1 && m <= 12 ? meses[m] : p[1]}';
  }

  /// Normaliza un teléfono cubano para wa.me (Argón spec 3).
  /// Implementación en negocio.dart (probada).
  String _normalizarTelefono(String tel) => normalizarTelefonoWaMe(tel);

  Future<void> _editar() async {
    final c = _c;
    if (c == null) return;
    final nombre = TextEditingController(text: '${c['nombre'] ?? ''}');
    final telefono =
        TextEditingController(text: '${c['telefono'] ?? ''}');
    final carnet =
        TextEditingController(text: '${c['carnet'] ?? ''}');
    // v0.6.0 (Pieza A): tarifa especial por transferencia (vacío = sin
    // especial; rige el precio general por transferencia).
    final tarifaActual = (c['tarifa_especial_transferencia'] as num?)
        ?.toDouble();
    final tarifa = TextEditingController(
        text: tarifaActual == null
            ? ''
            : (tarifaActual == tarifaActual.roundToDouble()
                ? '${tarifaActual.toInt()}'
                : '$tarifaActual'));
    String sexo = '${c['sexo'] ?? 'M'}';
    // v1.5.0 (Bloque G): aviso de fecha de carnet imposible (no bloquea).
    var carnetInvalido = carnetFechaInvalida(carnet.text);
    // Fecha de vencimiento vigente (v1.0.11)
    DateTime? pagadoHasta;
    final phRaw = c['pagado_hasta'] as String?;
    if (phRaw != null && phRaw.isNotEmpty) {
      pagadoHasta = DateTime.tryParse(phRaw);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Editar cliente',
          iconoTitulo: Icons.edit,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nombre,
                    decoration: const InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                          controller: telefono,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                              labelText: 'Teléfono (8 dígitos)',
                              border: OutlineInputBorder())),
                    ),
                    const SizedBox(width: 8),
                    // Elegir de los contactos del teléfono (v1.0.11)
                    IconButton(
                      tooltip: 'Elegir de contactos',
                      icon: const Icon(Icons.contacts,
                          color: AppColores.naranja),
                      onPressed: () async {
                        final tel =
                            await _elegirDeContactos(ctx);
                        if (tel != null && tel.isNotEmpty) {
                          setS(() =>
                              telefono.text = tel);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                    controller: carnet,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    onChanged: (v) => setS(() =>
                        carnetInvalido = carnetFechaInvalida(v)),
                    decoration: const InputDecoration(
                        labelText: 'Carnet (6–11 dígitos)',
                        border: OutlineInputBorder())),
                // v1.5.0 (Bloque G): aviso sin bloquear el guardado.
                if (carnetInvalido) const AvisoFechaCarnet(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Sexo: '),
                    ChoiceChip(
                        label: const Text('M'),
                        selected: sexo == 'M',
                        onSelected: (_) =>
                            setS(() => sexo = 'M')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('F'),
                        selected: sexo == 'F',
                        onSelected: (_) =>
                            setS(() => sexo = 'F')),
                  ],
                ),
                const SizedBox(height: 8),
                // Selector de vencimiento vigente (v1.0.11)
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: pagadoHasta ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                      helpText: 'Pagado hasta',
                    );
                    if (picked != null) {
                      setS(() => pagadoHasta = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: AppColores.borde(context)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          pagadoHasta == null
                              ? 'Pagado hasta: —'
                              : 'Pagado hasta: ${pagadoHasta!.day.toString().padLeft(2, '0')}/'
                                  '${pagadoHasta!.month.toString().padLeft(2, '0')}/'
                                  '${pagadoHasta!.year}',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const Spacer(),
                        Icon(Icons.edit,
                            size: 16,
                            color: AppColores.textoSecundario(context)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                    controller: tarifa,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      // Panel v0.6.0 (BAJO): como máximo un punto
                      // decimal y dos decimales (antes «1.2.3»
                      // pasaba el filtro y reventaba al guardar).
                      FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,2}$'))
                    ],
                    decoration: const InputDecoration(
                        labelText:
                            'Tarifa especial por transferencia (CUP)',
                        helperText:
                            'Vacío = precio general por transferencia',
                        border: OutlineInputBorder())),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      // v1.3.1 (Argón regresión 2): sin dispose. Son controllers locales de
      // _editar(); el GC los recoge. El dispose tras showDialog causaba
      // "TextEditingController was used after being disposed".
      return;
    }
    final tel = telefono.text.trim();
    final car = carnet.text.trim();
    if (tel.isNotEmpty && !validarTelefono(tel)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Teléfono inválido: 8 dígitos empezando con 5 o 6')));
      return;
    }
    if (car.isNotEmpty && !validarCarnet(car)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Carnet inválido: 6 a 11 dígitos')));
      return;
    }
    if (nombre.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('El nombre no puede estar vacío')));
      return;
    }
    final phStr = pagadoHasta == null
        ? null
        : '${pagadoHasta!.year.toString().padLeft(4, '0')}-'
            '${pagadoHasta!.month.toString().padLeft(2, '0')}-'
            '${pagadoHasta!.day.toString().padLeft(2, '0')}';
    // v0.6.0 (Pieza A): tarifa especial por transferencia.
    final tarifaTxt = tarifa.text.trim();
    double? nuevaTarifa;
    if (tarifaTxt.isNotEmpty) {
      nuevaTarifa = double.tryParse(tarifaTxt);
      // Panel v0.6.0: mismo rango que el servidor (0, 1000000];
      // sin el tope, el espejo optimista mostraba un valor que el
      // servidor iba a rechazar.
      if (nuevaTarifa == null ||
          nuevaTarifa <= 0 ||
          nuevaTarifa > 1000000) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Tarifa especial inválida: monto mayor que 0 o vacío')));
        return;
      }
    }
    final tarifaOrig =
        (c['tarifa_especial_transferencia'] as num?)?.toDouble();
    // Argón B7: enviar SIEMPRE todos los campos (como v1.2.9) para
    // no depender de que el backend maneje payload parcial.
    final orig = _c ?? {};
    final nuevoNombre = nombre.text.trim();
    final nuevoTel = tel.isEmpty ? null : tel;
    final nuevoCar = car.isEmpty ? null : car;
    // Si no cambió nada, no encolar.
    final huboCambios = nuevoNombre != '${orig['nombre'] ?? ''}' ||
        nuevoTel != (orig['telefono'] as String?) ||
        nuevoCar != (orig['carnet'] as String?) ||
        sexo != orig['sexo'] ||
        phStr != (orig['pagado_hasta'] as String?) ||
        nuevaTarifa != tarifaOrig;
    if (!huboCambios) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sin cambios')));
      return;
    }
    final payload = <String, dynamic>{
      'cliente_id': widget.clienteId,
      'nombre': nuevoNombre,
      'telefono': nuevoTel,
      'carnet': nuevoCar,
      'sexo': sexo,
      'pagado_hasta': phStr,
      // v0.6.0: siempre presente desde este diálogo (null = quitar la
      // tarifa especial; el servidor distingue clave ausente en ops
      // parciales de otros flujos).
      'tarifa_especial_transferencia': nuevaTarifa,
    };
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: payload,
    );
    // Panel v0.6.0: el parche optimista va DESPUÉS de encolar (si
    // queueOp falla, el espejo no debe mostrar una tarifa que
    // nunca salió del teléfono).
    if (nuevaTarifa != tarifaOrig) {
      await LocalDb.instance
          .updateMirrorTarifaTransferencia(widget.clienteId, nuevaTarifa);
    }
    // v1.3.1 (Argón regresión 2): sin dispose. Controllers locales de _editar().
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cambios guardados (se sincronizarán)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _editarNotas() async {
    final c = _c;
    if (c == null) return;
    final ctrl =
        TextEditingController(text: '${c['notas'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Notas del cliente',
        iconoTitulo: Icons.note,
        contenido: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
              hintText: 'Ej: lesionado, viene solo mañanas…',
              border: OutlineInputBorder()),
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: {
        'cliente_id': widget.clienteId,
        'notas': ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nota guardada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Elige un teléfono de los contactos del teléfono (v1.0.11).
  /// Devuelve el número en formato cubano (8 dígitos) o null.
  Future<String?> _elegirDeContactos(BuildContext ctx) async {
    // Pedir permiso
    if (!await FlutterContacts.requestPermission(readonly: true)) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text(
                'Sin permiso de contactos no se puede elegir')));
      }
      return null;
    }
    // Abrir el selector nativo de contactos
    final contacto =
        await FlutterContacts.openExternalPick();
    if (contacto == null) return null;
    // Tomar el primer número móvil válido
    for (final tel in contacto.phones) {
      var d = tel.number.replaceAll(RegExp(r'\D'), '');
      if (d.startsWith('53') && d.length > 8) {
        d = d.substring(2);
      }
      if (d.length == 8 && d.startsWith('5')) {
        return d;
      }
    }
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text(
              'El contacto "${contacto.displayName}" no tiene un móvil cubano válido')));
    }
    return null;
  }

  /// Muestra la foto en grande al tocarla (v1.0.11).
  void _verFotoGrande() {    final f = _foto;
    if (f == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(f, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  /// ¿El cliente tiene foto? (v1.0.15; etapa 4 · F2)
  ///
  /// Antes solo miraba el caché local de ESTE teléfono: si la
  /// foto no estaba cacheada en ese momento, la opción «Eliminar
  /// foto» no aparecía aunque el cliente tuviera foto (reporte
  /// de campo con Yunieski Garrido). Ahora, en orden:
  /// 1) La intención local pendiente manda (deriva de las colas
  ///    persistentes): eliminar encolado -> no tiene; foto en la
  ///    cola de subida -> sí tiene. Sobrevive a cerrar la ficha.
  /// 2) El espejo: foto_storage no vacío (la misma fuente que usa
  ///    la ficha para mostrarla; cubre fotos del bot y de la APK).
  /// 3) La foto en pantalla (_foto), p. ej. recién puesta.
  /// La caché sola ya no prueba existencia (puede ser huérfana).
  /// Semántica offline: «hay una foto efectiva conocida que se
  /// puede eliminar»; la op del servidor tolera que ya no haya.
  Future<bool> _tieneFoto() async {
    try {
      final intencion =
          await LocalDb.instance.ultimaIntencionFoto(widget.clienteId);
      if (intencion == 'eliminar') return false;
      if (intencion == 'poner') return true;
      final storage = _c?['foto_storage'] as String?;
      if (storage != null && storage.isNotEmpty) return true;
      return _foto != null;
    } catch (_) {
      // Ni siquiera el respaldo omite el espejo (panel).
      final storage = _c?['foto_storage'] as String?;
      return (storage != null && storage.isNotEmpty) ||
          _foto != null;
    }
  }

  /// Elimina la foto del cliente (v1.0.15).
  Future<void> _eliminarFoto() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Eliminar foto',
        iconoTitulo: Icons.delete,
        contenido: const Text(
            '¿Eliminar la foto de este cliente? Esta acción se sincronizará.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.error,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Invalida cualquier descarga en vuelo y quita la foto de
    // pantalla YA (etapa 4 · F2): feedback inmediato, ANTES de
    // los await de caché y BD (corrección del panel).
    _fotoGen++;
    setState(() => _foto = null);
    // Limpia el caché local
    await FotoCache.instance.invalidar('bot/${widget.clienteId}.jpg');
    await FotoCache.instance.invalidar('apk/${widget.clienteId}.jpg');
    // Encola la operación para el servidor
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'eliminar_foto',
      payload: {'cliente_id': widget.clienteId},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Foto eliminada (se sincronizará)')),
    );
    SyncEngine.instance.push();
  }

  /// Cambia la foto del cliente: cámara, galería o eliminar (v1.0.15).
  Future<void> _cambiarFoto() async {
    final tieneFoto = await _tieneFoto();
    if (!mounted) return;
    final origen = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Foto del cliente',
        iconoTitulo: Icons.photo_camera,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera, size: 24),
              title: const Text('Tomar foto'),
              onTap: () =>
                  Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, size: 24),
              title: const Text('Elegir de la galería'),
              onTap: () =>
                  Navigator.pop(ctx, 'gallery'),
            ),
            if (tieneFoto)
              ListTile(
                leading: const Icon(Icons.delete,
                    size: 24, color: AppColores.error),
                title: const Text('Eliminar foto',
                    style: TextStyle(color: AppColores.error)),
                onTap: () =>
                    Navigator.pop(ctx, 'eliminar'),
              ),
          ],
        ),
      ),
    );
    if (origen == null || !mounted) return;
    if (origen == 'eliminar') {
      await _eliminarFoto();
      return;
    }
    final src = origen == 'camera'
        ? ImageSource.camera
        : ImageSource.gallery;
    final img = await ImagePicker().pickImage(
        source: src,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 75); // Gemini: compresión obligatoria para Cuba
    if (img == null || !mounted) return;
    final dir = await getApplicationDocumentsDirectory();
    final destino = File('${dir.path}/foto_${widget.clienteId}_'
        '${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(img.path).copy(destino.path);
    if (!mounted) return;
    // Editor simple: permite zoom/mover para centrar la cara
    final editada = await mostrarEditorFoto(context, destino);
    if (editada == null || !mounted) {
      try { await destino.delete(); } catch (_) {}
      return;
    }
    // v1.2.9: usar la cola persistente (no fotos_pendientes).
    final opUuid = const Uuid().v4();
    await FotosColaService.instance.encolarFoto(
      opUuid: opUuid,
      clienteId: widget.clienteId,
      rutaOriginal: editada.path,
    );
    if (!mounted) return;
    _fotoGen++;
    setState(() => _foto = editada);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Foto actualizada (se sincronizará)')));
    SyncEngine.instance.push();
  }

  /// Renovación rápida con un toque: 1 mes en efectivo (punto 30).
  Future<void> _renovar() async {
    final c = _c;
    if (c == null) return;
    final aj = await LocalDb.instance.getAjustes();
    final mensual = (aj['mensualidad'] as num?)?.toDouble() ?? 2000;
    final nuevo =
        previewHastaDias(c['pagado_hasta'] as String?, 30);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Renovación rápida',
        iconoTitulo: Icons.autorenew,
        contenido: Text('${c['nombre']}\n'
            '1 mes — ${fmtMonto(mensual)} CUP en efectivo\n'
            'Nuevo vencimiento: ${fmtFecha(nuevo)}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Renovar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: {
        'cliente_id': widget.clienteId,
        'periodo': 'mensual',
        'meses': 1,
        'metodo': 'efectivo',
        'fecha':
            isoHabana(ahoraHabana()).substring(0, 10), // v1.3.3 (Argón): hora de La Habana
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Renovado (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  Future<void> _aPapelera() async {    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Enviar a papelera',
        iconoTitulo: Icons.delete,
        contenido: const Text(
            'El cliente quedará inactivo y no aparecerá en las listas. '
            'Podrás recuperarlo desde la Papelera.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Enviar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {'cliente_id': widget.clienteId, 'estado': 'inactivo'},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enviado a la papelera')));
    Navigator.of(context).pop();
    SyncEngine.instance.push();
  }

  /// Elimina definitivamente sin pasar por papelera (solo dueño).
  /// v1.8.0: primero se elige el MODO (todo | conservando
  /// estadísticas, diseño de Argón) y después la confirmación
  /// fuerte de siempre: escribir "ELIMINAR".
  /// Revisado por Gemini 2026-10-13. Backend lo maneja directo.
  Future<void> _eliminarDefinitivo() async {
    final nombre = '${_c?['nombre'] ?? ''}';
    // Candado 3: si debe un fiado, el modo conservar lo da por
    // incobrable; el diálogo lo avisa antes de elegir.
    String? avisoFiado;
    try {
      final fiado = await LocalDb.instance
          .fiadoPendienteDeCliente(widget.clienteId);
      final partes = <String>[
        if ((fiado['CUP'] ?? 0) > 0)
          '${fmtMonto(fiado['CUP']!)} CUP',
        if ((fiado['USD'] ?? 0) > 0)
          '${fmtMonto(fiado['USD']!)} USD',
      ];
      if (partes.isNotEmpty) {
        avisoFiado = '⚠️ Tiene un fiado pendiente de '
            '${partes.join(' y ')}: al eliminar conservando, la '
            'deuda se dará por incobrable.';
      }
    } catch (_) {
      // Sin lectura de fiados no se bloquea la baja: el servidor
      // cierra el fiado igualmente en la misma op.
    }
    if (!mounted) return;
    final modo = await elegirModoEliminacion(
      context,
      titulo: 'Eliminar definitivamente',
      avisoFiado: avisoFiado,
    );
    if (modo == null || !mounted) return;

    // Segunda confirmación: escribir ELIMINAR
    // (Gemini: palabra fija evita problemas de acentos/mayúsculas)
    final ctrl = TextEditingController();
    var coincide = false;
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Confirmación final'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Escribe ELIMINAR en mayúsculas para confirmar.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                textCapitalization:
                    TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'ELIMINAR',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(
                    () => coincide = v.trim() == 'ELIMINAR'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                // Gemini: deshabilitar hasta que coincida
                onPressed: coincide
                    ? () => Navigator.pop(ctx, true)
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Eliminar')),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (ok2 != true || !mounted) return;

    if (modo == 'conservar') {
      // Optimista ATÓMICO (corrección del panel, v1.8.0): la op y
      // el marcado de la cáscara local (estado='eliminado', que lo
      // saca de todas las listas al momento) van en UNA
      // transacción; si el proceso muere a mitad, no puede quedar
      // la op encolada con la persona visible. El pull traerá la
      // fila anonimizada completa.
      await LocalDb.instance.queueOpYMarcarEliminado(
        opUuid: const Uuid().v4(),
        payload: payloadOpEliminarCliente(
            clienteId: widget.clienteId, modo: modo),
        clienteId: widget.clienteId,
      );
    } else {
      // En modo 'todo' no se toca el espejo: el borrado baja por
      // su tombstone, como siempre.
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'eliminar_cliente',
        payload: payloadOpEliminarCliente(
            clienteId: widget.clienteId, modo: modo),
      );
    }
    AppLog.info('clientes', 'eliminar_definitivo',
        d: 'id=${widget.clienteId} nombre=$nombre modo=$modo');

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(modo == 'conservar'
            ? 'Cliente eliminado conservando estadísticas'
            : 'Cliente eliminado definitivamente')));
    Navigator.of(context).pop();
    SyncEngine.instance.push();
  }

  /// Congelar/descongelar membresía (v1.0.9).
  /// El cliente congelado no aparece en vencidos.
  Future<void> _congelar() async {
    final esCongelado = (_c?['estado'] as String?) == 'congelado';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: esCongelado ? 'Descongelar' : 'Congelar membresía',
        iconoTitulo: Icons.ac_unit,
        contenido: Text(esCongelado
            ? '¿Reactivar la membresía de ${_c?['nombre']}? Volverá a contar el vencimiento.'
            : '¿Congelar la membresía de ${_c?['nombre']}? No aparecerá en vencidos mientras esté congelada.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: Text(esCongelado ? 'Descongelar' : 'Congelar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'cambiar_estado',
      payload: {
        'cliente_id': widget.clienteId,
        'estado': esCongelado ? 'activo' : 'congelado'
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(esCongelado
            ? 'Membresía descongelada'
            : 'Membresía congelada')));
    _cargar();
    SyncEngine.instance.push();
  }

  /// Corregir pago (solo admin): editar monto/fecha o anular, con doble
  /// confirmación. Encola 'editar_pago' / 'anular_pago'.
  Future<void> _corregirPago(Map<String, dynamic> p) async {
    final pagoId = p['id'] as int?;
    if (pagoId == null) return;
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Corregir pago',
        iconoTitulo: Icons.edit,
        contenido: Text(
            '${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'editar'),
              child: const Text('Editar monto/fecha')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'anular'),
              child: const Text('Anular pago',
                  style: TextStyle(color: AppColores.error))),
        ],
      ),
    );
    if (accion == null || !mounted) return;

    if (accion == 'anular') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Anular pago',
          iconoTitulo: Icons.cancel,
          contenido: const Text(
              '¿Seguro? El pago quedará anulado en el sistema. '
              'Esta acción se sincronizará.'),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColores.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, anular')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago',
        payload: {'pago_id': pagoId},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Pago anulado (se sincronizará)')));
      _cargar();
      SyncEngine.instance.push();
      return;
    }

    // editar monto/fecha/método (v1.0.12: método incluido)
    final montoCtrl = TextEditingController(
        text: fmtMonto(p['monto']));
    final fechaCtrl = TextEditingController(
        text: (p['fecha'] as String? ?? '').substring(0, 10));
    String metodo = '${p['metodo'] ?? 'efectivo'}';
    final datos = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Editar pago',
          iconoTitulo: Icons.edit,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: montoCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Monto (CUP)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: fechaCtrl,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                  labelText: 'Fecha (AAAA-MM-DD)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Método: '),
                ChoiceChip(
                  label: const Text('Efectivo'),
                  selected: metodo == 'efectivo',
                  onSelected: (_) => setS(() => metodo = 'efectivo'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Transferencia'),
                  selected: metodo == 'transferencia',
                  onSelected: (_) =>
                      setS(() => metodo = 'transferencia'),
                ),
              ],
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {
                    'monto': montoCtrl.text,
                    'fecha': fechaCtrl.text,
                    'metodo': metodo,
                  }),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Continuar')),
        ],
      ),
      ),
    );
    // v1.3.1 (Argón regresión 2): sin dispose tras showDialog. Son controllers
    // locales del método; el GC los recoge. El dispose síncrono causaba
    // "TextEditingController was used after being disposed" durante la
    // animación de cierre del diálogo.
    if (datos == null || !mounted) return;
    final monto =
        double.tryParse(datos['monto']!.replaceAll(',', '.'));
    final fecha = datos['fecha']!.trim();
    final fechaOk = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(fecha);
    if (monto == null || monto <= 0 || !fechaOk) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Monto o fecha inválidos')));
      return;
    }
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Confirmar corrección',
        iconoTitulo: Icons.check_circle,
        contenido: Text(
            'De: ${fmtMonto(p['monto'])} CUP — ${fmtFecha(p['fecha'] as String?)} — ${p['metodo'] ?? ''}\n'
            'A: ${fmtMonto(monto)} CUP — $fecha — ${datos['metodo']}'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_pago',
      payload: {
        'pago_id': pagoId,
        'monto': monto,
        'fecha': fecha,
        'metodo': datos['metodo'],
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Corrección guardada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final dias =
        diasRestantes(c?['pagado_hasta'] as String?) ?? 999999;
    final vencido = c != null && dias < 0;
    // v1.7.0: Cuenta a la Casa (distintivo dorado; el predicado
    // vive en negocio.dart/LocalDb).
    final esCasa = c != null && esCuentaCasa(c);
    final nombre = c == null ? '…' : '${c['nombre']}';
    return Scaffold(
      appBar: AppBar(
        title: Text(nombre),
        actions: [
          if (c != null) ...[
            // v1.2.9+47: menú overflow con eliminar definitivo (solo dueño)
            if (AuthService().isOwner)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  if (v == 'eliminar') {
                    _eliminarDefinitivo();
                  } else if (v == 'casa_on') {
                    _cambiarCuentaCasa(true);
                  } else if (v == 'casa_off') {
                    _cambiarCuentaCasa(false);
                  }
                },
                itemBuilder: (ctx) => [
                  // v1.7.0: Cuenta a la Casa (solo dueño; el menú
                  // ya es solo del dueño).
                  PopupMenuItem(
                    value: esCasa ? 'casa_off' : 'casa_on',
                    child: Row(
                      children: [
                        const Icon(Icons.home_rounded,
                            color: Color(0xFFB8860B), size: 20),
                        const SizedBox(width: 8),
                        Text(esCasa
                            ? 'Quitar Cuenta a la Casa'
                            : 'Pasar a Cuenta a la Casa'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'eliminar',
                    child: Row(
                      children: [
                        Icon(Icons.delete_forever,
                            color: Colors.red, size: 20),
                        SizedBox(width: 8),
                        Text('Eliminar definitivamente',
                            style:
                                TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            IconButton(
                tooltip: 'Verificar con servidor',
                icon: _verificando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white))
                    : const Icon(Icons.cloud_sync),
                onPressed:
                    _verificando ? null : _verificarServidor),
          ],
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: c == null
                ? const Center(
                    child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(
                        AppEspacio.lg),
                    children: [
                      // Cabecera: foto + nombre + badge (etapa 4 ·
                      // F3: banda con gradiente sutil naranja).
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            vertical: AppEspacio.md),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              AppColores.naranja
                                  .withValues(alpha: 0.10),
                              AppColores.naranja
                                  .withValues(alpha: 0.0),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(
                              AppRadio.lg),
                        ),
                        child: Column(
                          children: [
                      Center(
                        child: _foto != null
                            ? GestureDetector(
                                onTap: () =>
                                    _verFotoGrande(),
                                child: Container(
                                  padding:
                                      const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color:
                                            AppColores.naranja,
                                        width: 2),
                                  ),
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(
                                            57),
                                    child: Image.file(_foto!,
                                        width: 114,
                                        height: 114,
                                        fit: BoxFit.cover),
                                  ),
                                ),
                              )
                            : Container(
                                padding:
                                    const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: AppColores.naranja,
                                      width: 2),
                                ),
                                child: CircleAvatar(
                                radius: 57,
                                backgroundColor: AppColores
                                    .naranja
                                    .withValues(alpha: 0.15),
                                child: Text(
                                    _iniciales(nombre),
                                    style: const TextStyle(
                                        fontSize: 40,
                                        fontWeight:
                                            FontWeight.bold,
                                        color: AppColores
                                            .naranja)),
                                ),
                              ),
                      ),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Center(
                        child: TextButton.icon(
                          icon: const Icon(
                              Icons.camera_alt,
                              size: 18),
                          label:
                              const Text('Cambiar foto'),
                          onPressed: _cambiarFoto,
                        ),
                      ),
                      Center(
                        child: Text(nombre,
                            style: AppTexto.displayPequeno),
                      ),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Center(
                          child: BadgeEstado.desdeDias(
                              dias)),
                      // v1.7.0: distintivo DORADO de Cuenta a la Casa.
                      if (esCasa) ...[
                        const SizedBox(height: AppEspacio.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3CD),
                            borderRadius:
                                BorderRadius.circular(999),
                            border: Border.all(
                                color: const Color(0xFFB8860B)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.home_rounded,
                                  size: 15,
                                  color: Color(0xFFB8860B)),
                              SizedBox(width: 6),
                              Text('Cuenta a la Casa',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF7A5A00))),
                            ],
                          ),
                        ),
                      ],
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // Acciones principales
                      Row(
                        children: [
                          Expanded(
                            child: BotonPrimario(
                              texto: 'Registrar pago',
                              icono: Icons.payments,
                              onPressed: _pagar,
                            ),
                          ),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: BotonSecundario(
                              texto: 'Editar',
                              icono: Icons.edit,
                              onPressed: _editar,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // v1.3.3: regalar mensualidad de cumpleaños (solo dueño).
                      // Argón spec 2: si ya se regaló este año, el botón
                      // pasa a "Reenviar WhatsApp" (no aplica otro mes).
                      // v1.7.0 (regla firme de Argón): en una Cuenta a
                      // la Casa la celebración NO ofrece «regalo de
                      // mes» — el botón no aparece.
                      if (AuthService().isOwner && !esCasa)
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                          child: SizedBox(
                            width: double.infinity,
                            child: BotonSecundario(
                              texto: _regaloAnio != null
                                  ? '📲 Reenviar WhatsApp'
                                  : '🎁 Regalar mensualidad',
                              icono: _regaloAnio != null
                                  ? Icons.send
                                  : Icons.card_giftcard,
                              onPressed: _regalarMes,
                            ),
                          ),
                        ),
                      const SizedBox(
                          height: AppEspacio.lg),
                      // Información personal
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    color: AppColores.naranja
                                        .withValues(alpha: 0.12),
                                    borderRadius:
                                        BorderRadius.circular(
                                            AppRadio.sm),
                                  ),
                                  child: const Icon(
                                      Icons.person_outline,
                                      size: 18,
                                      color:
                                          AppColores.naranja),
                                ),
                                const SizedBox(
                                    width: AppEspacio.sm),
                                const Text(
                                    'Información personal',
                                    style: AppTexto.titulo),
                              ],
                            ),
                            const SizedBox(
                                height: AppEspacio.sm),
                            _filaInfo(
                                Icons.badge,
                                'Carnet',
                                '${c['carnet'] ?? '—'}'),
                            if (edadDeCarnet(
                                    '${c['carnet'] ?? ''}') !=
                                null)
                              _filaInfo(
                                  Icons.cake,
                                  'Edad',
                                  '${edadDeCarnet('${c['carnet']}')} años'),
                            _filaInfo(
                                Icons.person,
                                'Sexo',
                                '${c['sexo'] ?? '—'}'),
                            _filaInfo(
                                Icons.phone,
                                'Teléfono',
                                '${c['telefono'] ?? '—'}'),
                            _filaInfo(
                                Icons.person_add,
                                'Inscrito por',
                                _textoInscritoPor(c[
                                        'registrado_por_nombre']
                                    as String?)),
                            InkWell(
                              onTap: _editarNotas,
                              borderRadius:
                                  BorderRadius.circular(
                                      AppRadio.sm),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                        vertical:
                                            AppEspacio.sm),
                                child: Row(
                                  children: [
                                    const Icon(
                                        Icons.note,
                                        color: AppColores
                                            .naranja,
                                        size: 20),
                                    const SizedBox(
                                        width:
                                            AppEspacio.md),
                                    const Expanded(
                                        child: Text(
                                            'Notas',
                                            style: AppTexto
                                                .cuerpo)),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        (c['notas']
                                                        as String?)
                                                    ?.isNotEmpty ==
                                                true
                                            ? '${c['notas']}'
                                            : 'Toca para agregar…',
                                        style: AppTexto.cuerpo
                                            .copyWith(
                                                fontWeight:
                                                    FontWeight
                                                        .w600),
                                        textAlign:
                                            TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // Membresía
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text('Membresía',
                                style: AppTexto.titulo),
                            const SizedBox(
                                height: AppEspacio.sm),
                            _filaInfo(
                                Icons.calendar_today,
                                'Pagado hasta',
                                esCasa
                                    ? 'Sin vencimiento'
                                    : fmtFecha(c['pagado_hasta']
                                        as String?)),
                            _filaInfo(
                                Icons.event,
                                'Estado',
                                esCasa
                                    ? 'Cuenta a la Casa'
                                    : textoEstado(c['pagado_hasta']
                                        as String?)),
                            _filaInfo(
                                Icons.payments_outlined,
                                'Último pago',
                                _pagos.isEmpty
                                    ? '—'
                                    : fmtFecha(_pagos.first['fecha']
                                        as String?)),
                            _filaInfo(
                                Icons.repeat,
                                'Tipo',
                                _pagos.isEmpty
                                    ? '—'
                                    : etiquetaPeriodo(_pagos.first)),
                            _filaInfo(
                                Icons.date_range,
                                'Inscripción',
                                fmtFecha(c[
                                        'fecha_inscripcion']
                                    as String?)),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // Resumen 360
                      if (_pagos.isNotEmpty)
                        _resumen360(),
                      // Historial de pagos
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'Historial de pagos',
                                style: AppTexto.titulo),
                            const SizedBox(
                                height: AppEspacio.sm),
                            if (_pagos.isEmpty)
                              Text(
                                  'Sin pagos registrados',
                                  style: TextStyle(
                                      color:
                                          AppColores.textoSecundario(context))),
                            for (final p in _pagos)
                              ListTile(
                                dense: true,
                                contentPadding:
                                    EdgeInsets.zero,
                                title: Text(
                                    '${fmtMonto(p['monto'])} CUP — ${p['metodo'] ?? ''}',
                                    style:
                                        AppTexto.cuerpo),
                                subtitle: Text(
                                    '${fmtFecha(p['fecha'] as String?)} · ${p['periodo'] ?? 'mensual'}\n'
                                    '${textoCobradoPor(p['registrado_por'])}',
                                    style: AppTexto
                                        .secundario),
                                trailing:
                                    AuthService().isAdmin
                                        ? IconButton(
                                            tooltip:
                                                'Corregir pago',
                                            icon: const Icon(
                                                Icons.tune,
                                                size: 20),
                                            onPressed: () =>
                                                _corregirPago(
                                                    p),
                                          )
                                        : null,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      // v1.2.2: Historial de suplementos comprados
                      if (_suplementos.isNotEmpty)
                        Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Text(
                                  'Suplementos comprados',
                                  style: AppTexto.titulo),
                              const SizedBox(
                                  height: AppEspacio.sm),
                              for (final s in _suplementos)
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  title: Text(
                                      '${s['suplemento_nombre'] ?? s['nombre'] ?? 'Suplemento'} x${s['cantidad'] ?? 1}',
                                      style:
                                          AppTexto.cuerpo),
                                  subtitle: Text(
                                      '${fmtFecha(s['fecha'] as String?)} · ${(s['moneda'] ?? 'CUP')}',
                                      style: AppTexto
                                          .secundario),
                                  trailing: Text(
                                      '${fmtMonto((s['precio'] as num?)?.toDouble() ?? 0)} ${(s['moneda'] ?? 'CUP')}',
                                      style: AppTexto.cuerpo.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: AppColores.naranja)),
                                ),
                            ],
                          ),
                        ),
                      if (_suplementos.isNotEmpty)
                        const SizedBox(
                            height: AppEspacio.md),
                      // v1.8.0: Historial de servicios por dosis
                      if (_serviciosHist.isNotEmpty)
                        Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Text(
                                  'Servicios (dosis y agua)',
                                  style: AppTexto.titulo),
                              // v1.8.1 (idea de Jc): acumulado del
                              // cliente para detectar frecuentes.
                              Builder(builder: (_) {
                                final r = servicios_svc
                                    .resumenServiciosDeCliente(
                                        _serviciosHist);
                                final partes = <String>[
                                  if (r.dosis > 0) '${r.dosis} dosis',
                                  if (r.pomos > 0)
                                    '${r.pomos} pomos de agua',
                                  if (r.importe > 0)
                                    '${fmtMonto(r.importe)} CUP en compras',
                                ];
                                if (partes.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Acumulado: ${partes.join(' · ')}',
                                    style: AppTexto.secundario,
                                  ),
                                );
                              }),
                              const SizedBox(
                                  height: AppEspacio.sm),
                              for (final s in _serviciosHist)
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  leading: Icon(
                                    (s['reverso_de'] as num?) != null
                                        ? Icons.undo
                                        : Icons.bolt,
                                    size: 20,
                                    color: AppColores.naranja,
                                  ),
                                  title: Text(
                                      switch ('${s['tipo']}') {
                                        'dosis_sin_agua' =>
                                          'Dosis sin agua',
                                        'dosis_con_agua' =>
                                          'Dosis con agua',
                                        'agua_suelta' =>
                                          'Pomo de agua',
                                        _ => 'Servicio',
                                      },
                                      style:
                                          AppTexto.cuerpo),
                                  subtitle: Text(
                                      '${fmtFecha(s['fecha'] as String?)} · '
                                      '${(s['casa'] as num?)?.toInt() == 1 ? 'Cuenta a la Casa' : (s['metodo'] ?? '')}'
                                      ' · ${s['registrado_por_nombre'] ?? ''}',
                                      style: AppTexto
                                          .secundario),
                                  trailing: Text(
                                      (s['casa'] as num?)?.toInt() == 1
                                          ? 'Casa'
                                          : '${fmtMonto(((s['precio_unitario'] as num?)?.toDouble() ?? 0) * ((s['cantidad'] as num?)?.toDouble() ?? 0))} CUP',
                                      style: AppTexto.cuerpo.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: AppColores.naranja)),
                                ),
                            ],
                          ),
                        ),
                      if (_serviciosHist.isNotEmpty)
                        const SizedBox(
                            height: AppEspacio.md),
                      // v1.2.5 (#10): incidencias relacionadas con el cliente.
                      if (_incidencias.isNotEmpty) ...[
                        Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Text(
                                  'Incidencias',
                                  style: AppTexto.titulo),
                              const SizedBox(
                                  height: AppEspacio.sm),
                              for (final i in _incidencias)
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  leading: Icon(
                                    i['visibilidad'] == 'privada'
                                        ? Icons.lock_outline
                                        : Icons.report_problem_outlined,
                                    size: 20,
                                    color: AppColores.naranja,
                                  ),
                                  title: Text(
                                      '${i['descripcion'] ?? ''}',
                                      style:
                                          AppTexto.cuerpo,
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow.ellipsis),
                                  subtitle: Text(
                                      '${_estadoIncidencia(i['estado'])} · ${fmtFecha((i['creada_en'] as String?)?.substring(0, 10))}',
                                      style: AppTexto
                                          .secundario),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(
                            height: AppEspacio.md),
                      ],
                      // v1.3.9 (F1): acceso a la App de Clientes.
                      // v1.3.9 Sprint 1 (#14): también si tiene permiso can_generate_pin.
                      if (AuthService().isOwner ||
                          PermisosEntrenador().canGeneratePin)
                        _seccionAccesoApp(),
                      // Etapa 4 · F3: tarjeta «Acciones» (antes
                      // botones sueltos): mismas acciones, mismas
                      // condiciones y mismos callbacks.
                      // (Progreso: Argón, archivo separado para no
                      // saturar ficha.dart.)
                      TarjetaAccionesCliente(
                        vencido: vencido,
                        congelado: (_c?['estado'] as String?) ==
                            'congelado',
                        onProgreso: () {
                          final cli = _c;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PestanaProgreso(
                                clienteId: '${widget.clienteId}',
                                nombreCliente:
                                    '${cli?['nombre'] ?? ''}',
                              ),
                            ),
                          );
                        },
                        onRenovar: _renovar,
                        onCongelar: _congelar,
                        onPapelera: _aPapelera,
                      ),
                      const SizedBox(
                          height: AppEspacio.lg),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Iniciales para el placeholder de foto.
  /// v1.2.5: etiqueta legible del estado de incidencia.
  String _estadoIncidencia(Object? estado) {
    return switch (estado) {
      'pendiente' => 'Pendiente',
      'en_revision' => 'En revisión',
      'resuelta' => 'Resuelta',
      _ => '${estado ?? ''}',
    };
  }

  String _iniciales(String nombre) {    final partes =
        nombre.trim().split(RegExp(r'\s+'));
    var ini = '';
    if (partes.isNotEmpty && partes[0].isNotEmpty) {
      ini = partes[0][0].toUpperCase();
      if (partes.length > 1 &&
          partes.last.isNotEmpty) {
        ini += partes.last[0].toUpperCase();
      }
    }
    return ini.isEmpty ? '?' : ini;
  }

  /// Fila de información con icono.
  Widget _filaInfo(
      IconData icono, String etiqueta, String valor) {
    // Etapa 4 · F3: hairline inferior sutil entre filas.
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: AppColores.borde(context)
                  .withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.symmetric(
          vertical: AppEspacio.sm),
      child: Row(
        children: [
          Icon(icono,
              color: AppColores.naranja, size: 20),
          const SizedBox(width: AppEspacio.md),
          Expanded(
              child: Text(etiqueta,
                  style: AppTexto.cuerpo)),
          Text(valor,
              style: AppTexto.cuerpo.copyWith(
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.right),
        ],
      ),
    );
  }

  // ============================================================
  // v1.3.9 (F1): Acceso a la App de Clientes
  // ============================================================

  /// Sección "Acceso App" en la ficha (solo dueño).
  /// 4 estados: sin acceso, activo, revocado, bloqueado.
  Widget _seccionAccesoApp() {
    final acceso =
        AccesoAppCache.instance.obtener(widget.clienteId);

    Widget contenido;
    if (_accesoSinConexion && !AccesoAppCache.instance.cargado) {
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acceso App',
              style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.sm),
          const Text(
              'Sin conexión para verificar acceso.',
              style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reintentar'),
            onPressed: _reintentarCargaAcceso,
          ),
        ],
      );
    } else if (acceso == null) {
      // Sin acceso.
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acceso App',
              style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.sm),
          const Text(
              'Este cliente aún no tiene acceso a la app.',
              style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          FilledButton.icon(
            icon: const Icon(Icons.key, size: 18),
            label: const Text('Generar PIN para App'),
            onPressed: () => _generarPin(esRegeneracion: false),
          ),
        ],
      );
    } else if (!acceso.activo) {
      // Revocado.
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acceso App',
              style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.sm),
          Chip(
            avatar: const Icon(Icons.block,
                size: 16, color: Colors.white),
            label: const Text('Revocado',
                style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.grey[600],
          ),
          const SizedBox(height: AppEspacio.sm),
          FilledButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reactivar / Generar PIN'),
            onPressed: () => _generarPin(esRegeneracion: true),
          ),
        ],
      );
    } else if (acceso.estaBloqueado) {
      // Bloqueado por intentos fallidos.
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acceso App',
              style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.sm),
          Chip(
            avatar: const Icon(Icons.lock,
                size: 16, color: Colors.white),
            label: const Text('Bloqueado',
                style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.amber[700],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
              'Intentos fallidos: ${acceso.intentosFallidos}',
              style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          FilledButton.icon(
            icon: const Icon(Icons.lock_open, size: 18),
            label: const Text('Desbloquear (Nuevo PIN)'),
            onPressed: () => _generarPin(esRegeneracion: true),
          ),
        ],
      );
    } else {
      // Activo.
      final ultimo = acceso.ultimoAccesoEn == null
          ? 'Nunca ha entrado'
          : 'Último acceso: ${fmtFecha(acceso.ultimoAccesoEn!.toIso8601String().substring(0, 10))}';
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acceso App',
              style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.sm),
          Chip(
            avatar: const Icon(Icons.check_circle,
                size: 16, color: Colors.white),
            label: const Text('Activo',
                style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.green[600],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(ultimo, style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Regenerar PIN'),
                  onPressed: () =>
                      _confirmarRegenerar(acceso),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.block,
                      size: 18, color: Colors.red),
                  label: const Text('Revocar',
                      style: TextStyle(color: Colors.red)),
                  onPressed: () =>
                      _confirmarRevocar(acceso),
                ),
              ),
            ],
          ),
        ],
      );
    }

    // Etapa 4 · F3: «Vista previa» y «Avisar» van DENTRO de la
    // tarjeta, al final y FUERA de las ramas de estado: se siguen
    // mostrando exactamente en los estados de hoy (v1.3.9: la
    // vista previa en TODOS, el RPC no requiere PIN activo).
    return Column(
      children: [
        Tarjeta(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              contenido,
              const SizedBox(height: AppEspacio.md),
              const Divider(height: 1),
              const SizedBox(height: AppEspacio.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.preview, size: 18),
                  label: const Text('Vista previa App'),
                  onPressed: _abrirVistaPrevia,
                ),
              ),
              const SizedBox(height: AppEspacio.sm),
              // v1.3.9 Sprint 1 (#2): avisar por WhatsApp
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.chat,
                      size: 18, color: Colors.green),
                  label: const Text('Avisar por WhatsApp'),
                  onPressed: () =>
                      _mostrarAvisosWhatsApp(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppEspacio.md),
      ],
    );
  }

  /// Limpia un teléfono cubano para wa.me (Argón).
  String _limpiarTelefonoCuba(String raw) {
    final digitos = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitos.length == 8 &&
        (digitos.startsWith('5') || digitos.startsWith('6'))) {
      return '53$digitos';
    }
    return digitos;
  }

  /// v1.3.9 Sprint 1 (#2): avisos por WhatsApp con plantillas editables.
  Future<void> _mostrarAvisosWhatsApp(BuildContext context) async {
    final cli = _c;
    final String nombre = '${cli?['nombre'] ?? 'atleta'}';
    final String telefonoRaw = '${cli?['telefono'] ?? ''}';
    final String fechaVenc = '${cli?['pagado_hasta'] ?? 'próximamente'}';

    final telLimpio = _limpiarTelefonoCuba(telefonoRaw);
    if (telLimpio.length < 8) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Este cliente no tiene un teléfono válido registrado.')),
        );
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final ultimaPromo = prefs.getString('ultima_plantilla_promo') ??
        'Hola $nombre, tenemos una promoción especial para ti en Iron Body Gym: ';

    if (!context.mounted) return;

    final plantillas = {
      'vencimiento':
          'Hola $nombre, te recordamos que tu membresía en Iron Body Gym vence el $fechaVenc. ¡Te esperamos para renovar!',
      'recordatorio':
          'Hola $nombre, ¡hace días no te vemos por Iron Body Gym! Recuerda que la constancia es la clave. ¡Te esperamos hoy!',
      'promo': ultimaPromo,
      'libre': 'Hola $nombre, ',
    };

    final tipoSeleccionado = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Avisar por WhatsApp',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  'Selecciona una plantilla para editar antes de enviar'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.schedule, color: Colors.orange),
              title: const Text('Vencimiento próximo'),
              onTap: () => Navigator.pop(ctx, 'vencimiento'),
            ),
            ListTile(
              leading: const Icon(Icons.fitness_center,
                  color: Colors.blue),
              title: const Text('Recordatorio de asistencia'),
              onTap: () => Navigator.pop(ctx, 'recordatorio'),
            ),
            ListTile(
              leading: const Icon(Icons.local_offer,
                  color: Colors.purple),
              title:
                  const Text('Promoción (guarda último texto)'),
              onTap: () => Navigator.pop(ctx, 'promo'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.edit, color: Colors.teal),
              title: const Text('Texto libre'),
              onTap: () => Navigator.pop(ctx, 'libre'),
            ),
          ],
        ),
      ),
    );

    if (tipoSeleccionado == null || !context.mounted) return;

    final ctrl =
        TextEditingController(text: plantillas[tipoSeleccionado]);

    final textoFinal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar mensaje'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Escribe el mensaje...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.send, size: 16),
            label: const Text('ABRIR WHATSAPP'),
            onPressed: () =>
                Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );

    if (textoFinal == null || textoFinal.isEmpty) return;

    // Si usó la plantilla promo, guardar para el próximo cliente
    if (tipoSeleccionado == 'promo') {
      await prefs.setString('ultima_plantilla_promo', textoFinal);
    }

    final uri = Uri.parse(
      'https://wa.me/$telLimpio?text=${Uri.encodeComponent(textoFinal)}',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _reintentarCargaAcceso() async {
    final ok = await AccesoAppCache.instance.cargar();
    if (mounted) {
      setState(() => _accesoSinConexion = !ok);
    }
  }

  Future<void> _confirmarRegenerar(AccesoCliente acceso) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerar PIN'),
        content: const Text(
            'Se invalidará el PIN anterior y se cerrará la sesión del cliente en su app. ¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Regenerar')),
        ],
      ),
    );
    if (ok == true && mounted) {
      _generarPin(esRegeneracion: true);
    }
  }

  Future<void> _confirmarRevocar(AccesoCliente acceso) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revocar acceso'),
        content: Text(
            'Se desactivará el acceso de ${acceso.nombre} a la app y se cerrará su sesión. ¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Revocar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Supabase.instance.client
          .rpc('revocar_acceso_cliente', params: {
        'p_cliente_id': widget.clienteId,
      });
      // v1.3.9 (ajuste Argón): recargar en vez de eliminar del caché —
      // el servidor pone activo=false, no borra el registro.
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Acceso revocado')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error al revocar: $e')));
      }
    }
  }

  /// Genera (o regenera) el PIN vía RPC y muestra el modal.
  Future<void> _generarPin({required bool esRegeneracion}) async {
    final nombre = '${_c?['nombre'] ?? 'Cliente'}';
    final telefono = '${_c?['telefono'] ?? ''}';
    try {
      final res = await Supabase.instance.client
          .rpc('generar_acceso_cliente', params: {
        'p_cliente_id': widget.clienteId,
        'p_creado_por': AuthService().username,
      });
      final data = Map<String, dynamic>.from(res as Map);
      final pin = '${data['pin_temporal'] ?? ''}';
      if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
      // Invalidación inmediata: recargar el caché para reflejar el cambio.
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        setState(() => _accesoSinConexion = false);
        mostrarModalPin(context, pin, telefono, nombre);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error al generar PIN: $e')));
      }
    }
  }

  /// Abre la vista previa de la app del cliente (F6).
  void _abrirVistaPrevia() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VistaPreviaClienteScreen(
          clienteId: widget.clienteId,
          nombreCliente: '${_c?['nombre'] ?? ''}',
        ),
      ),
    );
  }

  /// Resumen 360: totales del cliente.
  Widget _resumen360() {    final total = _pagos.fold<double>(
        0,
        (s, p) =>
            s +
            ((p['monto'] as num?)?.toDouble() ??
                0));
    final metodos = <String, int>{};
    for (final p in _pagos) {
      final m = (p['metodo'] as String?) ?? 'efectivo';
      metodos[m] = (metodos[m] ?? 0) + 1;
    }
    final metodoTop = metodos.entries.isEmpty
        ? ''
        : metodos.entries
            .reduce(
                (a, b) => a.value >= b.value ? a : b)
            .key;
    return Padding(
      padding:
          const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        color:
            AppColores.naranja.withValues(alpha: 0.08),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                Text('${_pagos.length}',
                    style: AppTexto.displayPequeno
                        .copyWith(
                            color:
                                AppColores.naranja)),
                const Text('pagos',
                    style: AppTexto.secundario),
              ],
            ),
            Column(
              children: [
                Text(total.toStringAsFixed(0),
                    style: AppTexto.displayPequeno
                        .copyWith(
                            color:
                                AppColores.naranja)),
                const Text('CUP total',
                    style: AppTexto.secundario),
              ],
            ),
            if (metodoTop.isNotEmpty)
              Column(
                children: [
                  Icon(
                      metodoTop == 'efectivo'
                          ? Icons.payments
                          : Icons.smartphone,
                      color: AppColores.naranja,
                      size: 28),
                  const Text('prefiere',
                      style: AppTexto.secundario),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Texto amigable para "Inscrito por" (v1.1).
  /// Los importados del Excel muestran "Migración del sistema anterior".
  String _textoInscritoPor(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    if (raw.startsWith('Excel')) {
      return 'Migración del sistema anterior';
    }
    return raw;
  }
}
