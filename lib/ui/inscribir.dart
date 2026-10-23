/// Inscripción de cliente con foto (offline-first).
///
/// Solo se encola al confirmar el resumen: escribir el nombre no genera
/// ninguna operación (el "Pendiente a entregar" solo cuenta operaciones
/// confirmadas).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../invitados.dart';
import '../localdb.dart';
import '../fotos_cola.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'dialogo_confirmar_inscripcion.dart';
import 'diseno.dart';
import 'editor_foto.dart';
import 'widgets.dart';

class InscribirScreen extends StatefulWidget {
  /// v1.5.0 (Bloque G): conversión de un invitado — la pantalla se
  /// abre pre-llenada desde la bandeja de Invitados y la op
  /// `inscribir` lleva `invitado_id`, `conversion_uuid` y las
  /// medidas sincronizadas del invitado.
  final DatosConversionInvitado? conversion;
  const InscribirScreen({super.key, this.conversion});
  @override
  State<InscribirScreen> createState() => _InscribirScreenState();
}

class _InscribirScreenState extends State<InscribirScreen> {
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _carnet = TextEditingController();
  final _dias = TextEditingController();
  final _monto = TextEditingController();
  String _sexo = 'M';
  String _periodo = 'mensual';
  int _meses = 1;
  List<TipoPago> _tiposCustom = [];
  TipoPago? _tipoCustomSel;
  // v1.3.9 (Bug 2): método de pago del período inicial (antes hardcodeado a 'efectivo').
  String _metodoPago = 'efectivo';
  File? _foto;
  bool _guardando = false;
  bool _esMenor = false;
  // v1.5.0 (Bloque G): aviso de fecha de carnet imposible (no bloquea).
  bool _carnetFechaInvalida = false;
  // v1.4.0 Paso 2 (propuesta 11): crear acceso a la app de clientes al
  // inscribir. El servidor lo genera tras sincronizar y el PIN le llega
  // a Jc por Telegram (el cliente aún no existe en la nube al guardar).
  bool _crearAccesoApp = false;
  double _precioMenorVal = 1500;

  @override
  void initState() {
    super.initState();
    _carnet.addListener(_actualizarEsMenor);
    // v1.5.0 (Bloque G): pre-llenado de la conversión de invitado.
    final conv = widget.conversion;
    if (conv != null) {
      _nombre.text = conv.nombre;
      _telefono.text = conv.telefono;
      final carnet = conv.carnetSugerido;
      if (carnet != null) _carnet.text = carnet;
    }
    _cargarPrecioMenor();
    _cargarTiposCustom();
  }

  /// v1.3.9: cargar tipos de pago personalizados (ej. "Oferta 50%").
  Future<void> _cargarTiposCustom() async {
    try {
      final tipos = await getTiposPago();
      // Filtrar los que no son los estándar (semanal, quincenal, mensual, menores)
      final custom = tipos
          .where((t) =>
              t.activo &&
              !['semanal', 'quincenal', 'mensual', 'menores']
                  .contains(t.id))
          .toList();
      if (mounted) {
        setState(() => _tiposCustom = custom);
      }
    } catch (_) {}
  }

  Future<void> _cargarPrecioMenor() async {
    final p = await precioMenor();
    if (mounted) setState(() => _precioMenorVal = p);
  }

  void _actualizarEsMenor() {
    final esMenorVal = esMenor(_carnet.text.trim());
    final fechaInvalida = carnetFechaInvalida(_carnet.text);
    if (esMenorVal != _esMenor ||
        fechaInvalida != _carnetFechaInvalida) {
      setState(() {
        _esMenor = esMenorVal;
        _carnetFechaInvalida = fechaInvalida;
      });
    }
  }

  @override
  void dispose() {
    _carnet.removeListener(_actualizarEsMenor);
    _nombre.dispose();
    _telefono.dispose();
    _carnet.dispose();
    _dias.dispose();
    _monto.dispose();
    super.dispose();
  }

  Future<void> _tomarFoto(ImageSource origen) async {
    final img =
        await ImagePicker().pickImage(
          source: origen,
          maxWidth: 800,
          maxHeight: 800,
          imageQuality: 75); // Gemini: compresión obligatoria para Cuba
    if (img == null) return;
    // copia a almacenamiento propio (el temporal del picker puede borrarse)
    final dir = await getApplicationDocumentsDirectory();
    final destino =
        File('${dir.path}/foto_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(img.path).copy(destino.path);
    // Editor simple: permite zoom/mover para centrar la cara
    if (!mounted) return;
    final editada = await mostrarEditorFoto(context, destino);
    if (editada == null) {
      // usuario canceló: borra la copia temporal
      try { await destino.delete(); } catch (_) {}
      return;
    }
    setState(() => _foto = editada);
  }

  double _montoPeriodo(Map<String, double> precios) {
    if (_periodo == 'semanal') return precios['semanal']!;
    if (_periodo == 'quincenal') return precios['quincenal']!;
    // v1.3.9: tipo de pago personalizado (ej. "Oferta 50%")
    if (_periodo.startsWith('tipo:')) {
      return _tipoCustomSel?.monto ?? 0;
    }
    if (_periodo == 'personalizado') {
      return double.tryParse(_monto.text.trim().replaceAll(',', '.')) ??
          0;
    }
    // v1.2.2: menores pagan precio reducido
    // v1.3.9 (Bug 2, Argón): respetar el método de pago elegido —
    // la tarifa por transferencia difiere del efectivo.
    final precioMensual = _esMenor
        ? _precioMenorVal
        : (_metodoPago == 'transferencia'
            ? precios['transfer']!
            : precios['mensual']!);
    return precioMensual * _meses;
  }

  int _diasPeriodo() {
    if (_periodo == 'semanal') return 7;
    if (_periodo == 'quincenal') return 15;
    // v1.3.9: tipo personalizado usa sus días configurados
    if (_periodo.startsWith('tipo:')) {
      return _tipoCustomSel?.dias ?? 30;
    }
    if (_periodo == 'personalizado') {
      return int.tryParse(_dias.text.trim()) ?? 0;
    }
    return 30 * _meses;
  }

  String _etiquetaPeriodo() {
    if (_periodo == 'semanal') return 'Semana';
    if (_periodo == 'quincenal') return 'Quincena';
    if (_periodo == 'personalizado') {
      return '${_dias.text.trim()} días (personalizado)';
    }
    return '$_meses mes${_meses == 1 ? '' : 'es'}';
  }

  Future<void> _guardar() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribe el nombre')));
      return;
    }
    final tel = _telefono.text.trim();
    if (tel.isNotEmpty && !validarTelefono(tel)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Teléfono inválido: 8 dígitos empezando con 5 o 6')));
      return;
    }
    final carnet = _carnet.text.trim();
    if (carnet.isNotEmpty && !validarCarnet(carnet)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Carnet inválido: 6 a 11 dígitos')));
      return;
    }
    final precios0 = await _precios();
    if (!mounted) return;
    if (_periodo == 'personalizado' &&
        (_diasPeriodo() <= 0 || _montoPeriodo(precios0) <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Indica días y monto válidos')));
      return;
    }

    // Anti-duplicado: el carnet de 11 dígitos no se repite (bloqueo);
    // sin carnet, aviso por nombre parecido pero se permite.
    final dups = await posiblesDuplicados(
        nombre: nombre,
        carnet: carnet.isEmpty ? null : carnet,
        telefono: tel.isEmpty ? null : tel);
    final carnetDigitos = carnet.replaceAll(RegExp(r'[^0-9]'), '');
    final carnetDuplicado = carnetDigitos.length == 11 &&
        dups.any((d) => d['_motivo'] == 'mismo carnet');
    if (carnetDuplicado && mounted) {
      final dueno = dups.firstWhere(
          (d) => d['_motivo'] == 'mismo carnet');
      await showDialog<void>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Carnet duplicado',
          iconoTitulo: Icons.badge,
          contenido: Text(
              'El carnet $carnet ya pertenece a "${dueno['nombre']}".\n'
              'Cada carnet corresponde a un solo cliente: no se puede '
              'inscribir de nuevo.'),
          acciones: [
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Entendido')),
          ],
        ),
      );
      return;
    }
    if (dups.isNotEmpty && mounted) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Posible duplicado',
          iconoTitulo: Icons.person_search,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Ya existe(n) cliente(s) parecido(s):'),
              const SizedBox(height: 8),
              for (final d in dups)
                Text('• ${d['nombre']} (${d['_motivo']})'),
              const SizedBox(height: 8),
              const Text('¿Seguro que es un cliente nuevo?'),
            ],
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Revisar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Sí, es nuevo')),
          ],
        ),
      );
      if (seguir != true) return;
    }

    // Confirmación con resumen (la operación solo se crea aquí).
    final precios = await _precios();
    final monto = _montoPeriodo(precios);
    final dias = _diasPeriodo();
    final hasta = previewHastaDias(null, dias);
    if (!mounted) return;
    // v1.3.5: diálogo rediseñado (widget dedicado, luz verde de Argón).
    final ok = await DialogoConfirmarInscripcion.mostrar(
      context,
      nombre: nombre,
      periodoEtiqueta: _etiquetaPeriodo(),
      montoTxt: '${fmtMonto(monto)} CUP',
      metodoPago: _metodoPago,
      validoHastaTxt: fmtFecha(hasta),
      telefono: tel,
      carnet: carnet,
      fotoPath: _foto?.path,
    );
    if (ok != true || !mounted) return;

    setState(() => _guardando = true);
    try {
      final opUuid = const Uuid().v4();
      String? fotoPath = _foto?.path;
      final payload = <String, dynamic>{
        'nombre': nombre,
        'sexo': _sexo,
        'periodo': _periodo,
        'meses': _meses,
        if (_periodo == 'personalizado') 'dias': dias,
        // v1.3.9: guardar monto también para tipos personalizados
        // (ej. "Oferta 50%") — se usa en el cálculo del pendiente.
        if (_periodo == 'personalizado' ||
            _periodo.startsWith('tipo:'))
          'monto': monto,
        'telefono': tel.isEmpty ? null : tel,
        'carnet': carnet.isEmpty ? null : carnet,
        // v1.4.0 (Argón §8): fecha de negocio en hora de La Habana.
        'fecha': hoyHabanaIso(),
        // v1.3.9 (Bug 2): método de pago elegido (antes hardcodeado a 'efectivo').
        'metodo_pago': _metodoPago,
        // v1.2.2: guardar si es menor y el precio aplicado (histórico)
        if (_esMenor) 'es_menor': true,
        'precio_aplicado': monto,
        // v1.4.0 Paso 2 (propuesta 11): el puente genera el acceso a
        // la app de clientes tras aplicar la inscripción.
        if (_crearAccesoApp) 'crear_acceso_app': true,
        // v1.5.0 (Bloque G): conversión de invitado — el servidor
        // (Bloque B) verifica las medidas contra el detalle
        // autoritativo de ESTE invitado antes de importarlas.
        if (widget.conversion != null)
          'invitado_id': widget.conversion!.invitadoId,
        if (widget.conversion != null)
          'conversion_uuid': widget.conversion!.conversionUuid,
        if (widget.conversion != null &&
            widget.conversion!.medidas.isNotEmpty)
          'medidas_invitado': widget.conversion!.medidasPayload,
      };
      // v1.5.0 (Bloque G, G1): en una conversión, el registro
      // local durable `opEncolada` con ESTE op_uuid se persiste
      // ANTES de encolar la op, y la op se encola con ese mismo
      // uuid: ninguna op de conversión puede quedar huérfana por
      // un cierre de la app (ver encolarInscripcionConversion).
      final conv = widget.conversion;
      if (conv != null) {
        await encolarInscripcionConversion(
          invitadoId: conv.invitadoId,
          conversionUuid: conv.conversionUuid,
          opUuid: opUuid,
          encolar: (uuid) => LocalDb.instance.queueOp(
            opUuid: uuid,
            tipo: 'inscribir',
            payload: payload,
            fotoPath: fotoPath,
          ),
        );
      } else {
        await LocalDb.instance.queueOp(
          opUuid: opUuid,
          tipo: 'inscribir',
          payload: payload,
          fotoPath: fotoPath,
        );
      }
      if (fotoPath != null) {
        // v1.2.9: usar la cola persistente (no fotos_pendientes).
        await FotosColaService.instance.encolarFoto(
          opUuid: opUuid,
          rutaOriginal: fotoPath,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Guardado (se sincronizará)')));
      Navigator.of(context).pop();
      SyncEngine.instance.push();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<Map<String, double>> _precios() async {
    final aj = await LocalDb.instance.getAjustes();
    return {
      'mensual': (aj['mensualidad'] as num?)?.toDouble() ?? 2000,
      'semanal': (aj['pago_semanal'] as num?)?.toDouble() ?? 600,
      'quincenal': (aj['pago_quincenal'] as num?)?.toDouble() ?? 1200,
      // v1.3.9 (Bug 2): tarifa por transferencia (difiere del efectivo).
      'transfer': (aj['transferencia'] as num?)?.toDouble() ?? 2500,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.conversion != null
              ? 'Convertir invitado en cliente'
              : 'Inscribir cliente')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // v1.5.0 (Bloque G): aviso de conversión en curso.
                if (widget.conversion != null) ...[
                  Tarjeta(
                    color:
                        AppColores.info.withValues(alpha: 0.10),
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.swap_horiz_rounded,
                            color: AppColores.info),
                        const SizedBox(width: AppEspacio.sm),
                        Expanded(
                          child: Text(
                            'Estás convirtiendo a un invitado '
                            'registrado desde la app de clientes.'
                            '${widget.conversion!.medidas.isNotEmpty ? ' Al guardar, sus ${widget.conversion!.medidas.length} medida(s) sincronizadas (autodeclaradas) se enviarán al servidor para verificarlas: solo se importarán las que el servidor confirme como de este invitado, y el resultado se verá al confirmarse la conversión.' : ''}',
                            style: AppTexto.secundario,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.md),
                ],
                // Bloque 1: información personal
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.person,
                              color:
                                  AppColores.naranja),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Información personal',
                              style: AppTexto.titulo),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _nombre,
                          etiqueta:
                              'Nombre completo *'),
                      const SizedBox(
                          height: AppEspacio.md),
                      const Text('Sexo:',
                          style: AppTexto.cuerpo),
                      const SizedBox(
                          height: AppEspacio.sm),
                      Row(
                        children: [
                          ChoiceChip(
                              label:
                                  const Text('Masculino'),
                              avatar: const Icon(
                                  Icons.male,
                                  size: 18),
                              selected: _sexo == 'M',
                              onSelected: (_) =>
                                  setState(
                                      () => _sexo = 'M')),
                          const SizedBox(
                              width: AppEspacio.sm),
                          ChoiceChip(
                              label:
                                  const Text('Femenino'),
                              avatar: const Icon(
                                  Icons.female,
                                  size: 18),
                              selected: _sexo == 'F',
                              onSelected: (_) =>
                                  setState(
                                      () => _sexo = 'F')),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _telefono,
                          etiqueta:
                              'Teléfono (8 dígitos)',
                          icono: Icons.phone,
                          teclado:
                              TextInputType.phone),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _carnet,
                          etiqueta:
                              'Carnet (6–11 dígitos)',
                          icono: Icons.badge,
                          teclado:
                              TextInputType.number),
                      // v1.5.0 (Bloque G): aviso de fecha
                      // imposible; NO bloquea el guardado.
                      if (_carnetFechaInvalida)
                        const AvisoFechaCarnet(),
                    ],
                  ),
                ),
                const SizedBox(
                    height: AppEspacio.md),
                // Bloque 2: membresía
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                              Icons.card_membership,
                              color:
                                  AppColores.naranja),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Membresía',
                              style: AppTexto.titulo),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      const Text('Período inicial:',
                          style: AppTexto.cuerpo),
                      const SizedBox(
                          height: AppEspacio.sm),
                      FutureBuilder<
                          Map<String, double>>(
                        future: _precios(),
                        builder: (ctx, snap) {
                          final pr = snap.data ??
                              {
                                'mensual': 2000.0,
                                'semanal': 600.0,
                                'quincenal': 1200.0
                              };
                          return Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                            children: [
                              DropdownButtonFormField<
                                  String>(
                                initialValue: _periodo ==
                                        'mensual'
                                    ? 'mensual:$_meses'
                                    : _periodo,
                                isExpanded: true,
                                decoration:
                                    InputDecoration(
                                  border:
                                      OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(
                                            AppRadio
                                                .md),
                                  ),
                                  contentPadding:
                                      const EdgeInsets
                                          .symmetric(
                                          horizontal:
                                              AppEspacio
                                                  .lg,
                                          vertical:
                                              AppEspacio
                                                  .md),
                                ),
                                items: [
                                  DropdownMenuItem(
                                      value: 'semanal',
                                      child: Text(
                                          'Semana (${fmtMonto(pr['semanal'])} CUP)')),
                                  DropdownMenuItem(
                                      value:
                                          'quincenal',
                                      child: Text(
                                          'Quincena (${fmtMonto(pr['quincenal'])} CUP)')),
                                  for (final m
                                      in [1, 2, 3])
                                    DropdownMenuItem(
                                        value:
                                            'mensual:$m',
                                        child: Text(
                                            _esMenor
                                                ? '$m mes${m == 1 ? '' : 'es'} (${fmtMonto(_precioMenorVal * m)} CUP) — Menor de edad'
                                                // v1.3.9 (Bug 2): mostrar tarifa según método de pago elegido.
                                                : '$m mes${m == 1 ? '' : 'es'} (${fmtMonto((_metodoPago == 'transferencia' ? pr['transfer']! : pr['mensual']!) * m)} CUP)')),
                                  // v1.3.9: tipos personalizados (ej. "Oferta 50%")
                                  for (final t
                                      in _tiposCustom)
                                    DropdownMenuItem(
                                        value:
                                            'tipo:${t.id}',
                                        child: Text(
                                            '${t.nombre} (${fmtMonto(t.monto)} CUP)')),
                                  const DropdownMenuItem(
                                      value:
                                          'personalizado',
                                      child: Text(
                                          'Personalizado…')),
                                ],
                                onChanged: (v) =>
                                    setState(() {
                                  if (v ==
                                          'semanal' ||
                                      v ==
                                          'quincenal' ||
                                      v ==
                                          'personalizado') {
                                    _periodo = v!;
                                    _tipoCustomSel = null;
                                  } else if (v!
                                      .startsWith(
                                          'tipo:')) {
                                    // v1.3.9: tipo personalizado
                                    _periodo = v;
                                    final id = v
                                        .substring(5);
                                    _tipoCustomSel =
                                        _tiposCustom
                                            .firstWhere(
                                      (t) =>
                                          t.id ==
                                          id,
                                      orElse: () =>
                                          _tiposCustom
                                              .first,
                                    );
                                  } else {
                                    _periodo =
                                        'mensual';
                                    _tipoCustomSel =
                                        null;
                                    _meses = int.parse(
                                        v!.split(
                                            ':')[1]);
                                  }
                                }),
                              ),
                              if (_periodo ==
                                  'personalizado') ...[
                                const SizedBox(
                                    height:
                                        AppEspacio
                                            .md),
                                Row(
                                  children: [
                                    Expanded(
                                      child:
                                          CampoTexto(
                                              controller:
                                                  _dias,
                                              etiqueta:
                                                  'Días',
                                              teclado:
                                                  TextInputType
                                                      .number),
                                    ),
                                    const SizedBox(
                                        width: AppEspacio
                                            .sm),
                                    Expanded(
                                      child:
                                          CampoTexto(
                                              controller:
                                                  _monto,
                                              etiqueta:
                                                  'Monto (CUP)',
                                              teclado: const TextInputType
                                                  .numberWithOptions(
                                                  decimal:
                                                      true)),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      // v1.3.9 (Bug 2): selector de método de pago del período
                      // inicial. Patrón visual de dialogo_pago.dart.
                      const SizedBox(height: AppEspacio.md),
                      const Text('Método de pago:',
                          style: AppTexto.cuerpo),
                      const SizedBox(height: AppEspacio.sm),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ChoiceChip(
                              label: const Text('Efectivo'),
                              avatar: const Icon(Icons.payments, size: 18),
                              selected: _metodoPago == 'efectivo',
                              onSelected: (_) => setState(
                                  () => _metodoPago = 'efectivo')),
                          const SizedBox(width: 8),
                          ChoiceChip(
                              label: const Text('Transfer.'),
                              avatar: const Icon(Icons.smartphone, size: 18),
                              selected: _metodoPago == 'transferencia',
                              onSelected: (_) => setState(
                                  () => _metodoPago = 'transferencia')),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                    height: AppEspacio.md),
                // Bloque 3: fotografía
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.camera_alt,
                              color:
                                  AppColores.naranja),
                          SizedBox(
                              width: AppEspacio.sm),
                          Text('Fotografía',
                              style: AppTexto.titulo),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      if (_foto != null)
                        ClipRRect(
                          borderRadius:
                              BorderRadius.circular(
                                  AppRadio.md),
                          child: Image.file(_foto!,
                              height: 200,
                              width: double.infinity,
                              fit: BoxFit.cover),
                        ),
                      if (_foto != null)
                        const SizedBox(
                            height: AppEspacio.sm),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.photo_camera),
                              label: const Text(
                                  'Cámara'),
                              onPressed: () =>
                                  _tomarFoto(
                                      ImageSource
                                          .camera),
                            ),
                          ),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.photo_library),
                              label: const Text(
                                  'Galería'),
                              onPressed: () =>
                                  _tomarFoto(
                                      ImageSource
                                          .gallery),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // v1.4.0 Paso 2 (propuesta 11): acceso a la app de
                // clientes al inscribir (solo dueño; el PIN llega por
                // Telegram a Jc cuando el cliente sincroniza).
                if (AuthService().isOwner) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                        'Crear acceso a la app de clientes'),
                    subtitle: const Text(
                        'Requiere teléfono de 8 dígitos. El PIN se '
                        'genera al sincronizar y le llega a Jc por '
                        'Telegram para entregarlo al cliente.',
                        style: AppTexto.secundario),
                    value: _crearAccesoApp,
                    onChanged: (v) =>
                        setState(() => _crearAccesoApp = v),
                  ),
                  const SizedBox(height: AppEspacio.md),
                ],
                const SizedBox(
                    height: AppEspacio.xl),
                _guardando
                    ? const Center(
                        child:
                            CircularProgressIndicator(
                                color: AppColores
                                    .naranja))
                    : BotonPrimario(
                        texto: 'Guardar inscripción',
                        icono: Icons.check,
                        onPressed: _guardar,
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
}
