/// Inscripción de cliente con foto (offline-first).
///
/// Solo se encola al confirmar el resumen: escribir el nombre no genera
/// ninguna operación (el "Pendiente a entregar" solo cuenta operaciones
/// confirmadas).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../invitados.dart';
import '../localdb.dart';
import '../fotos_cola.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'dialogo_confirmar_inscripcion.dart';
import 'diseno.dart';
import 'permisos_ui.dart';
import 'primitivas.dart';
import 'foto_elegir.dart';
import 'invitados.dart';
import 'widgets.dart';
import '../errores_sync.dart';
import '../app_log.dart';

class InscribirScreen extends StatefulWidget {
  /// v1.5.0 (Bloque G): conversión de un invitado — la pantalla se
  /// abre pre-llenada desde la bandeja de Invitados y la op
  /// `inscribir` lleva `invitado_id`, `conversion_uuid` y las
  /// medidas sincronizadas del invitado.
  final DatosConversionInvitado? conversion;

  /// 1.32 (Compuerta 5): foto recuperada al rehidratar — la
  /// cáscara raíz la ofrece tras un cierre de Android a mitad
  /// del selector y, si se acepta, Inscribir nace con ella
  /// puesta (la misma ranura que llena _tomarFoto).
  final File? fotoInicial;
  const InscribirScreen({super.key, this.conversion, this.fotoInicial});
  @override
  State<InscribirScreen> createState() => _InscribirScreenState();
}

class _InscribirScreenState extends State<InscribirScreen> {
  // 1.25 T61: claves de las tres secciones para que la
  // barra de pasos salte a cada una.
  final _claveDatos = GlobalKey();
  final _claveMembresia = GlobalKey();
  final _claveFoto = GlobalKey();

  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _carnet = TextEditingController();
  final _dias = TextEditingController();
  final _monto = TextEditingController();
  // 1.25 T117 (F1-66): notas opcionales de la inscripción; viajan
  // en la op y quedan guardadas en la ficha del cliente.
  final _notas = TextEditingController();
  // 1.25 T117 (F1-61): el futuro de precios se crea UNA sola vez;
  // antes se creaba dentro de build y el FutureBuilder se reiniciaba
  // (con su parpadeo) en cada reconstrucción.
  late Future<Map<String, double>> _preciosFut;
  String _sexo = 'M';
  String _periodo = 'mensual';
  int _meses = 1;
  List<TipoPago> _tiposCustom = [];
  TipoPago? _tipoCustomSel;
  // v1.3.9 (Bug 2): método de pago del período inicial (antes hardcodeado a 'efectivo').
  String _metodoPago = 'efectivo';
  // 1.35 (CAMPO-8): fecha de inicio elegida («Comenzó el»),
  // 'AAAA-MM-DD'. null = sin excepción: el inicio es HOY
  // y el pago se asienta hoy (el defecto que manda, por
  // decisión de Jc: la fecha distinta es la excepción).
  // Cuando se elige otra, esa fecha viaja como la
  // `fecha` de la op: el servidor asienta el pago en SU
  // día (su caja y su nómina) y la cobertura corre desde
  // ese día (la cadena canónica apila desde la fecha del
  // pago).
  String? _fechaInicioSel;

  /// La fecha de inicio efectiva de esta inscripción.
  String get _inicioIso => _fechaInicioSel ?? hoyHabanaIso();

  /// ¿Se eligió una fecha de inicio distinta de hoy?
  bool get _inicioEsExcepcion =>
      _fechaInicioSel != null && _fechaInicioSel != hoyHabanaIso();

  /// Selector «Comenzó el»: vale pasado y el día
  /// siguiente (un inicio de mañana se puede dejar
  /// asentado hoy).
  Future<void> _elegirFechaInicio() async {
    final hoy = ahoraHabana();
    final sel = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_inicioIso) ?? hoy,
      firstDate: DateTime(hoy.year - 1, hoy.month, hoy.day),
      lastDate: DateTime(hoy.year, hoy.month, hoy.day + 1),
      helpText: '¿Cuándo comenzó?',
    );
    if (sel == null || !mounted) return;
    String dos(int n) => n.toString().padLeft(2, '0');
    setState(() => _fechaInicioSel =
        '${sel.year}-${dos(sel.month)}-${dos(sel.day)}');
  }
  File? _foto;
  bool _guardando = false;
  // 1.36 H-B2 (136-696): el spinner del botón solo tras
  // CONFIRMAR (tras el diálogo de resumen): _guardando es
  // la guarda anti-doble-toque desde el primer toque
  // (Argón lote 4, bloqueante) y cubre también los
  // diálogos previos, donde el botón no debe fingir que
  // ya está guardando.
  bool _confirmandoGuardado = false;
  // 1.36 (136-689): identidad del intento de guardado. La
  // op de inscripción y la foto se encolan en dos pasos: si
  // el segundo falla (disco, compresión), el usuario
  // reintenta desde esta misma pantalla — y el reintento NO
  // puede generar otra op de inscripción para la misma
  // persona o el servidor la inscribe dos veces. El intento
  // vive en el State: opUuid + huella del payload + si la
  // op ya entró en la cola. Con el MISMO payload se reutiliza
  // el uuid y solo se reintenta lo que falta (la foto); con
  // un payload DISTINTO (el usuario corrigió los datos tras
  // el fallo) nace un intento nuevo. Al completar, se limpia.
  String? _opUuidIntento;
  String? _payloadIntentoJson;
  bool _opIntentoEncolada = false;
  String? _opUuidCasaIntento;
  String? _payloadCasaIntentoJson;
  bool _opCasaEncolada = false;
  bool _esMenor = false;
  // v1.5.0 (Bloque G): aviso de fecha de carnet imposible (no bloquea).
  bool _carnetFechaInvalida = false;
  bool _carnetPareceTelefono = false;
  // v1.4.0 Paso 2 (propuesta 11): crear acceso a la app de clientes al
  // inscribir. El servidor lo genera tras sincronizar y el PIN le llega
  // a Jc por Telegram (el cliente aún no existe en la nube al guardar).
  bool _crearAccesoApp = false;
  // 1.25 T19: validación en vivo — error bajo el campo y
  // foco al primer error al guardar (antes todo era un
  // aviso suelto al final, de uno en uno y sin señalar).
  final _focoNombre = FocusNode();
  final _focoTelefono = FocusNode();
  final _focoCarnet = FocusNode();
  String? _errNombre;
  String? _errTelefono;
  String? _errCarnet;

  void _fijarError(String campo, String? error) {
    setState(() {
      switch (campo) {
        case 'nombre':
          _errNombre = error;
        case 'telefono':
          _errTelefono = error;
        case 'carnet':
          _errCarnet = error;
      }
    });
    if (error != null) {
      final foco = switch (campo) {
        'nombre' => _focoNombre,
        'telefono' => _focoTelefono,
        _ => _focoCarnet,
      };
      foco.requestFocus();
      // 1.36 H-B2 (136-696): el campo con error se trae a
      // la vista (el formulario es largo: el foco sin
      // scroll dejaba el error fuera de pantalla).
      final ctxFoco = foco.context;
      if (ctxFoco != null) {
        Scrollable.ensureVisible(ctxFoco,
            duration: AppMovimiento.larga,
            curve: AppMovimiento.curvaSuave,
            alignment: 0.2);
      }
    }
  }
  // v1.7.0: inscribir directamente como Cuenta a la Casa (solo
  // dueño; el servidor revalida que el actor sea admin).
  bool _cuentaCasa = false;
  // 1.36 H-B2 (136-694): la confirmación de la Casa en
  // curso — el switch se deshabilita mientras el diálogo
  // está abierto (un segundo toque apilaba dos diálogos).
  bool _confirmandoCasa = false;
  // 1.32 (Disparador 2B): la caché LOCAL de invitados, leída
  // una vez al abrir (LocalDb meta; jamás red al teclear —
  // Compuerta 2). La coincidencia se calcula en build con la
  // función pura del servicio.
  List<InvitadoResumen> _cacheInvitados2B = const [];
  double _precioMenorVal = 1500;
  // 1.36 H-B2 (136-695): la tarifa del menor está
  // «cargando» hasta que llega la real (antes el selector
  // enseñaba 1500 como si fuera la vigente).
  bool _precioMenorCargado = false;
  // 136-695: la carga de tipos personalizados falló —
  // se avisa con reintento en la sección de membresía.
  bool _errorTipos = false;

  @override
  void initState() {
    super.initState();
    _preciosFut = _precios();
    // 1.25 T61: la barra de pasos y el resumen en vivo
    // (T60) se refrescan al teclear nombre/teléfono.
    _nombre.addListener(_refrescar);
    _telefono.addListener(_refrescar);
    // SL-3 (G02-1): días y monto del personalizado también
    // alimentan la barra de pasos (su estado sale de ellos).
    _dias.addListener(_refrescar);
    _monto.addListener(_refrescar);
    _carnet.addListener(_actualizarEsMenor);
    // Q5 (cola 1.20): el aviso «parece teléfono» depende de
    // AMBOS campos: también se recalcula al teclear el
    // teléfono.
    _telefono.addListener(_actualizarEsMenor);
    // v1.5.0 (Bloque G): pre-llenado de la conversión de invitado.
    final conv = widget.conversion;
    if (conv != null) {
      _nombre.text = conv.nombre;
      _telefono.text = conv.telefono;
      // Ronda 3-9 #9: el carnet real del invitado manda si es
      // válido; si no, se usa el derivado de su fecha de
      // nacimiento; sin derivado, queda el real para corregir.
      final carnet = (conv.carnet != null &&
              validarCarnetInvitado11(conv.carnet))
          ? conv.carnet
          : (conv.carnetSugerido ?? conv.carnet);
      if (carnet != null) _carnet.text = carnet;
    }
    // 1.32 (Compuerta 5): la foto recuperada entra por la
    // misma ranura que la del selector.
    if (widget.fotoInicial != null) _foto = widget.fotoInicial;
    _cargarCacheInvitados2B();
    _cargarPrecioMenor();
    _cargarTiposCustom();
  }

  /// 1.32 (Disparador 2B): lee la caché local de invitados
  /// una sola vez. Si nunca se abrió Invitados, la caché no
  /// existe y el disparador simplemente no se ofrece.
  Future<void> _cargarCacheInvitados2B() async {
    try {
      final cache = await InvitadosService().leerCacheInvitados();
      if (!mounted || cache == null) return;
      setState(() => _cacheInvitados2B = cache.lista);
    } catch (e) {
      // 1.36 H-B2 (136-692): sin caché no hay aviso de
      // duplicado por teléfono — el fallo queda en bitácora.
      AppLog.error('inscribir', 'cache_invitados_fallo', d: '$e');
    }
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
        setState(() {
          _tiposCustom = custom;
          _errorTipos = false;
        });
      }
    } catch (e) {
      // 136-695: sin tipos personalizados el selector solo
      // ofrece los estándar — se avisa con reintento.
      AppLog.error('inscribir', 'tipos_custom_fallo', d: '$e');
      if (mounted) setState(() => _errorTipos = true);
    }
  }

  Future<void> _cargarPrecioMenor() async {
    // 1.36 H-B2 (136-693): con red de seguridad — un fallo
    // aquí era una excepción async sin dueño y la tarifa
    // del menor quedaba en su valor inicial sin avisar.
    try {
      final p = await precioMenor();
      if (mounted) {
        setState(() {
          _precioMenorVal = p;
          _precioMenorCargado = true;
        });
      }
    } catch (e) {
      AppLog.error('inscribir', 'precio_menor_fallo', d: '$e');
    }
  }

  void _actualizarEsMenor() {
    // 1.36 H-B2 (136-692): la validación EN VIVO trabaja
    // sobre los dígitos sanitizados, igual que el guardado
    // (YB-CLI-10): con espacios/guiones tecleados, las
    // funciones sobre el texto crudo daban otro veredicto
    // que el guardado. Y un error de carnet ya fijado se
    // limpia en vivo cuando el carnet queda válido (o
    // vacío), no solo al reintentar el guardado.
    final digitos = _carnet.text.replaceAll(RegExp(r'[^0-9]'), '');
    final esMenorVal = esMenor(digitos);
    final fechaInvalida = carnetFechaInvalida(digitos);
    final pareceTel = carnetPareceTelefono(digitos,
        telefono: _telefono.text);
    final carnetYaValido =
        digitos.isEmpty || validarCarnet(digitos);
    if (esMenorVal != _esMenor ||
        fechaInvalida != _carnetFechaInvalida ||
        pareceTel != _carnetPareceTelefono ||
        (_errCarnet != null && carnetYaValido)) {
      setState(() {
        _esMenor = esMenorVal;
        _carnetFechaInvalida = fechaInvalida;
        _carnetPareceTelefono = pareceTel;
        if (carnetYaValido) _errCarnet = null;
      });
    }
  }

  @override
  void dispose() {
    _carnet.removeListener(_actualizarEsMenor);
    _telefono.removeListener(_actualizarEsMenor);
    _focoNombre.dispose();
    _focoTelefono.dispose();
    _focoCarnet.dispose();
    _nombre.dispose();
    _telefono.dispose();
    _carnet.dispose();
    _dias.dispose();
    _monto.dispose();
    _notas.dispose();
    // Pasada 2 de Argón (1.20): foto tomada y nunca entregada
    // (se canceló el diálogo o se salió con Atrás) → borrar el
    // archivo.
    // Argón Estadísticas (extra): el original TAMBIÉN se
    // borra cuando la inscripción SÍ se completó — verificado
    // que nadie lo lee después: encolarFoto ya copió sus
    // variantes a la cola de fotos (documents/fotos/) antes
    // de que _guardarAhora marcara completada, y el foto_path
    // de ops_queue no tiene lectores en la app. Sin este
    // borrado, cada inscripción con foto dejaba el original
    // del picker ocupando espacio para siempre.
    final foto = _foto;
    if (foto != null) {
      // Borrado en segundo plano: dispose no puede esperar.
      foto.delete().catchError((_) => foto);
    }
    super.dispose();
  }

  Future<void> _tomarFoto(ImageSource origen) async {
    // 1.29 (fijo de campo): el flujo vive en el helper compartido
    // elegirFotoEditada — antes esta copia no tenía try/catch y un
    // error del selector (already_active por una petición colgada)
    // mataba el toque en silencio, sin cámara ni editor.
    // 1.32 (Compuerta 5): la petición registra su contexto
    // (flujo de inscripción; el cliente aún no existe, sin
    // entidad) para el gancho de rehidratación.
    final editada = await elegirFotoEditada(context, origen,
        flujoFoto: 'inscribir');
    if (editada == null) return; // cancelado o error ya anunciado
    if (!mounted) {
      try {
        await editada.delete();
      } catch (_) {}
      return;
    }
    // Argón #7A-5: sin huérfanos: la foto anterior sustituida se
    // borra.
    final anterior = _foto;
    if (anterior != null && anterior.path != editada.path) {
      try {
        await anterior.delete();
      } catch (_) {}
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
      // Autoauditoría 1.22 #2 (clase N-2): NaN no es <= 0 y
      // pasaba la validación de «días y monto válidos» hasta el
      // payload de la inscripción (JSON no codifica NaN).
      final v = double.tryParse(_monto.text.trim().replaceAll(',', '.'));
      return (v != null && v.isFinite) ? v : 0;
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

  /// 1.25 T60: la línea-resumen anclada sobre el botón de
  /// guardar. En Casa no hay cobro: la línea lo dice en
  /// dorado. El vencimiento se calcula con los días del
  /// período elegido, como hará el guardado.
  Widget _resumenEnVivo() {
    if (_cuentaCasa) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        decoration: BoxDecoration(
          color: AppColores.casaFondo,
          borderRadius: BorderRadius.circular(AppRadio.md),
        ),
        // 1.36 H-B2 (136-697): el resumen en modo Casa con
        // su color de texto propio (casaTexto).
        child: Text('Cuenta a la Casa · sin cobro',
            style: AppTexto.secundario
                .copyWith(color: AppColores.casaTexto),
            textAlign: TextAlign.center),
      );
    }
    return FutureBuilder<Map<String, double>>(
      future: _preciosFut,
      builder: (ctx, snap) {
        final pr = snap.data ??
            const {
              'mensual': 2000.0,
              'semanal': 600.0,
              'quincenal': 1200.0,
              'transfer': 2500.0,
            };
        final dias = _diasPeriodo();
        // 1.35 (CAMPO-8): el vencimiento corre desde la
        // fecha de inicio efectiva (hoy salvo excepción
        // elegida), como hará el guardado.
        final vence = dias <= 0
            ? null
            : fmtFecha(sumarDiasIso(_inicioIso, dias));
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.md, vertical: AppEspacio.sm),
          decoration: BoxDecoration(
            color: AppColores.naranja.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppRadio.md),
          ),
          // 1.36 H-B2 (136-696): el resumen cruza al
          // cambiar período/método/monto, no salta.
          child: AnimatedSwitcher(
            duration: AppMovimiento.corta,
            child: Text(
              '${_etiquetaPeriodo()} · '
              '${fmtMonto(_montoPeriodo(pr))} CUP · '
              '${_metodoPago == 'transferencia' ? 'Transferencia' : 'Efectivo'}'
              '${_inicioEsExcepcion ? ' · comenzó el ${fmtFecha(_inicioIso)}' : ''}'
              '${vence != null ? ' · vence el $vence' : ''}',
              key: ValueKey(
                  '${_etiquetaPeriodo()}|${_montoPeriodo(pr)}|$_metodoPago|$_inicioIso|$vence'),
              style: AppTexto.secundario
                  .copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }

  String _etiquetaPeriodo() {
    if (_periodo == 'semanal') return 'Semana';
    if (_periodo == 'quincenal') return 'Quincena';
    // Argón #7A-1: el tipo personalizado muestra su nombre, no los
    // meses residuales de una selección mensual anterior.
    if (_periodo.startsWith('tipo:')) {
      return _tipoCustomSel?.nombre ?? 'Personalizado';
    }
    if (_periodo == 'personalizado') {
      return '${_dias.text.trim()} días (personalizado)';
    }
    return '$_meses mes${_meses == 1 ? '' : 'es'}';
  }

  Future<void> _guardar() async {
    // 1.24 Bloque 3: sin can_inscribir_clientes, aviso al tocar
    // y no se abre el flujo de guardado (el servidor rebotaría
    // la op con PERMISO_DENEGADO tras inscribir «de mentira»).
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canInscribirClientes, 'inscribir clientes')) {
      return;
    }
    // Argón lote 4 BLOQUEANTE: la bandera se activaba DESPUÉS de los
    // awaits y los diálogos; un doble toque rápido abría dos
    // diálogos y encolaba dos veces al mismo cliente. Ahora se
    // activa antes del primer await y el finally del envoltorio la
    // limpia en TODAS las salidas (validaciones, diálogos, errores).
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      await _guardarAhora();
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _guardarAhora() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      _fijarError('nombre', 'Escribe el nombre');
      return;
    }
    // 1.29 (FB-07): lo tecleado o PEGADO se sanitiza a los 8
    // dígitos limpios ANTES de validar y de cualquier payload
    // («+53 5819 1577» y «5819 1577» acaban guardando
    // 58191577; el 53 nunca se almacena: es solo para enlaces
    // wa.me y la UI). Lo que no sanitiza a un móvil válido se
    // rechaza con el aviso de siempre.
    final telCrudo = _telefono.text.trim();
    final tel =
        telCrudo.isEmpty ? '' : (sanitizarTelefono(telCrudo) ?? '');
    if (telCrudo.isNotEmpty && tel.isEmpty) {
      _fijarError(
          'telefono', 'Teléfono inválido: 8 dígitos empezando con 5 o 6');
      return;
    }
    // Argón lote 4 MEDIO: con 'crear acceso' activo, el subtítulo
    // exige teléfono de 8 dígitos, pero se podía inscribir con
    // telefono null y el servidor fallaba en silencio al crear la
    // cuenta. Se exige aquí, antes de cualquier await.
    if (_crearAccesoApp && !validarTelefono(tel)) {
      _fijarError('telefono',
          'Para crear el acceso de la app hace falta un teléfono válido de 8 dígitos.');
      return;
    }
    // Yunque B (YB-CLI-10): el carnet se guarda LIMPIO de
    // no-dígitos (la validación limpia solo para comprobar y
    // el texto crudo — «950220 12345» — llegaba tal cual al
    // payload y a clientes.carnet). La comprobación y el
    // aviso de fecha dudosa trabajan sobre los dígitos, que
    // es lo que esas funciones ya hacían por dentro.
    final carnet = _carnet.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (carnet.isNotEmpty && !validarCarnet(carnet)) {
      _fijarError('carnet', 'Carnet inválido: 6 a 11 dígitos');
      return;
    }
    // Argón lote 4 MEDIO: la fecha inválida solo avisaba en la UI y
    // pasaba en silencio. Decisión de Jc 2026-10-22: NO bloquear
    // (un tecleo invertido no puede impedir inscribir); se pide
    // confirmación explícita para que no pase inadvertido.
    if (carnet.isNotEmpty && carnetFechaInvalida(carnet)) {
      final seguir = await DialogoApp.confirmar(
        context,
        titulo: 'Fecha del carnet dudosa',
        mensaje:
            'Los 6 primeros dígitos del carnet no forman una fecha '
            'real (ej. mes 23). Puede ser día/mes invertidos. '
            '¿Guardarlo así de todos modos?',
        aceptar: 'Guardar así',
        icono: Icons.warning_amber_rounded,
      );
      if (seguir != true) return;
      if (!mounted) return;
    }
    // Argón #7A-2: el precio de menor no puede depender de la carga
    // lanzada sin await en initState; refrescarlo antes de calcular.
    await _cargarPrecioMenor();
    final precios0 = await _precios();
    if (!mounted) return;
    if (!_cuentaCasa &&
        _periodo == 'personalizado' &&
        (_diasPeriodo() <= 0 || _montoPeriodo(precios0) <= 0)) {
      mostrarSnack(context, 'Indica días y monto válidos', significado: SignificadoChip.alerta);
      return;
    }

    // Anti-duplicado: el carnet de 11 dígitos no se repite (bloqueo);
    // sin carnet, aviso por nombre parecido pero se permite.
    final dups = await posiblesDuplicados(
        nombre: nombre,
        carnet: carnet.isEmpty ? null : carnet,
        telefono: tel.isEmpty ? null : tel,
        incluirNoActivos: true);
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
          iconoTitulo: Icons.badge_rounded,
          contenido: Text(
              'El carnet $carnet ya pertenece a "${dueno['nombre']}"'
              '${coletillaEstadoDuplicado(dueno)}.\n'
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
          iconoTitulo: Icons.person_search_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Ya existe(n) cliente(s) parecido(s):'),
              const SizedBox(height: 8),
              for (final d in dups)
                Text('• ${d['nombre']} (${d['_motivo']}'
                    '${coletillaEstadoDuplicado(d)})'),
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
    // v1.7.0: una Cuenta a la Casa no cobra — confirmación simple
    // y payload SIN campos de pago: pagado_hasta nace NULL en el
    // servidor y el flag viaja como `cuenta_casa: 1` (el puente
    // rechaza la op si el actor no es admin).
    if (_cuentaCasa) {
      if (!mounted) return;
      // 1.25 T117 (F1-78): la Casa confirma con el MISMO
      // diálogo de resumen que la inscripción normal (foto,
      // carnet, teléfono, sexo), en su modo sin cobro — antes
      // era un aviso genérico sin los datos de la persona.
      final okCasa = await DialogoConfirmarInscripcion.mostrar(
        context,
        nombre: nombre,
        esCasa: true,
        sexo: _sexo == 'F' ? 'Femenino' : 'Masculino',
        telefono: tel,
        carnet: carnet,
        fotoPath: _foto?.path,
      );
      if (okCasa != true || !mounted) return;
      setState(() => _confirmandoGuardado = true);
      try {
        final payloadCasa = <String, dynamic>{
          'nombre': nombre,
          'sexo': _sexo,
          'telefono': tel.isEmpty ? null : tel,
          'carnet': carnet.isEmpty ? null : carnet,
          // Fecha de negocio en hora de La Habana (regla de la casa).
          'fecha': hoyHabanaIso(),
          if (_esMenor) 'es_menor': true,
          if (_notas.text.trim().isNotEmpty)
            'notas': _notas.text.trim(),
          'cuenta_casa': 1,
          if (_crearAccesoApp) 'crear_acceso_app': true,
        };
        // 136-689: reintento del MISMO payload = mismo uuid
        // y la op no se vuelve a encolar (solo la foto).
        final payloadCasaJson = jsonEncode(payloadCasa);
        if (_opUuidCasaIntento == null ||
            _payloadCasaIntentoJson != payloadCasaJson) {
          _opUuidCasaIntento = const Uuid().v4();
          _payloadCasaIntentoJson = payloadCasaJson;
          _opCasaEncolada = false;
        }
        final opUuidCasa = _opUuidCasaIntento!;
        if (!_opCasaEncolada) {
          await LocalDb.instance.queueOp(
            opUuid: opUuidCasa,
            tipo: 'inscribir',
            payload: payloadCasa,
            fotoPath: _foto?.path,
          );
          _opCasaEncolada = true;
        }
        if (_foto?.path != null) {
          await FotosColaService.instance.encolarFoto(
            opUuid: opUuidCasa,
            rutaOriginal: _foto!.path,
          );
        }
        // Guardado completo: el intento se cierra.
        _opUuidCasaIntento = null;
        _payloadCasaIntentoJson = null;
        _opCasaEncolada = false;
        if (!mounted) return;
        // 1.35 (UI-02): la inscripción guardada se siente.
        Tacto.confirmacion();
        mostrarSnack(context, 'Cuenta a la Casa guardada (se sincronizará)', significado: SignificadoChip.exito);
        Navigator.of(context).pop();
        SyncEngine.instance.push();
      } catch (e) {
        if (!mounted) return;
        AppLog.error('inscribir', 'guardar_casa_fallo', d: '$e');
        mostrarSnack(context, 'Error: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
      } finally {
        if (mounted) {
          setState(() {
            _guardando = false;
            _confirmandoGuardado = false;
          });
        }
      }
      return;
    }
    final precios = await _precios();
    final monto = _montoPeriodo(precios);
    final dias = _diasPeriodo();
    // 1.35 (CAMPO-8): la cobertura corre desde la fecha
    // de inicio efectiva (la cadena del servidor apila
    // desde la fecha del pago, que será esta misma).
    final hasta = previewHastaDias(null, dias, fechaPago: _inicioIso);
    if (!mounted) return;
    // v1.3.5: diálogo rediseñado (widget dedicado, luz verde de Argón).
    final ok = await DialogoConfirmarInscripcion.mostrar(
      context,
      nombre: nombre,
      periodoEtiqueta: _etiquetaPeriodo(),
      montoTxt: '${fmtMonto(monto)} CUP',
      // 1.25 T117 (F1-80): con varios meses, el desglose
      // «N × unitario CUP» bajo el total.
      desgloseTxt: (_periodo == 'mensual' && _meses > 1)
          ? '$_meses × ${fmtMonto(monto / _meses)} CUP'
          : null,
      metodoPago: _metodoPago,
      validoHastaTxt: fmtFecha(hasta),
      desdeTxt: _inicioEsExcepcion
          ? 'Desde el ${fmtFecha(_inicioIso)}'
          : 'Desde hoy, ${fmtFecha(hoyHabanaIso())}',
      telefono: tel,
      carnet: carnet,
      fotoPath: _foto?.path,
    );
    if (ok != true || !mounted) return;

    setState(() => _confirmandoGuardado = true);
    try {
      String? fotoPath = _foto?.path;
      final payload = <String, dynamic>{
        'nombre': nombre,
        'sexo': _sexo,
        'periodo': _periodo,
        'meses': _meses,
        // Argón P1#5-parte: `dias` también cuando el periodo es
        // un tipo personalizado (`tipo:...`), no solo `personalizado`.
        if (_periodo == 'personalizado' ||
            _periodo.startsWith('tipo:')) 'dias': dias,
        // v1.3.9: guardar monto también para tipos personalizados
        // (ej. "Oferta 50%") — se usa en el cálculo del pendiente.
        if (_periodo == 'personalizado' ||
            _periodo.startsWith('tipo:'))
          'monto': monto,
        'telefono': tel.isEmpty ? null : tel,
        'carnet': carnet.isEmpty ? null : carnet,
        // v1.4.0 (Argón §8): fecha de negocio en hora de La Habana.
        // 1.35 (CAMPO-8): la fecha de INICIO efectiva —
        // hoy por defecto (el pago se asienta hoy); si se
        // eligió otra en «Comenzó el», el servidor asienta
        // el pago en ese día y la cobertura corre desde él.
        'fecha': _inicioIso,
        // v1.3.9 (Bug 2): método de pago elegido (antes hardcodeado a 'efectivo').
        'metodo_pago': _metodoPago,
        // v1.2.2: guardar si es menor y el precio aplicado (histórico)
        if (_esMenor) 'es_menor': true,
        // Argón P1#5-parte: tipo mensual de menor.
        if (_esMenor && _periodo == 'mensual') 'tipo_id': 'menores',
        'precio_aplicado': monto,
        // v1.4.0 Paso 2 (propuesta 11): el puente genera el acceso a
        // la app de clientes tras aplicar la inscripción.
        if (_crearAccesoApp) 'crear_acceso_app': true,
        if (_notas.text.trim().isNotEmpty)
          'notas': _notas.text.trim(),
        // v1.5.0 (Bloque G): conversión de invitado — el servidor
        // (Bloque B) verifica las medidas contra el detalle
        // autoritativo de ESTE invitado antes de importarlas.
        if (widget.conversion != null)
          'invitado_id': widget.conversion!.invitadoId,
        if (widget.conversion != null)
          'conversion_uuid': widget.conversion!.conversionUuid,
        // 1.35 (corrección E3, C10-01): si la conversión
        // nació sin conexión, la op lo declara: es la única
        // forma de que una reconstrucción del registro local
        // desde la cola conserve la marca `nacidaOffline`
        // (el servidor ignora la clave; no es de su contrato).
        if (widget.conversion != null &&
            widget.conversion!.nacidaOffline)
          'conversion_nacida_offline': true,
        if (widget.conversion != null &&
            widget.conversion!.medidas.isNotEmpty)
          'medidas_invitado': widget.conversion!.medidasPayload,
      };
      // 1.36 (136-689): el uuid del intento se decide con el
      // payload YA construido: mismo payload que el intento
      // vivo = mismo uuid (y abajo la op no se re-encola);
      // payload distinto = intento nuevo.
      final payloadIntentoJson = jsonEncode(payload);
      if (_opUuidIntento == null ||
          _payloadIntentoJson != payloadIntentoJson) {
        _opUuidIntento = const Uuid().v4();
        _payloadIntentoJson = payloadIntentoJson;
        _opIntentoEncolada = false;
      }
      final opUuid = _opUuidIntento!;
      if (!_opIntentoEncolada) {
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
        _opIntentoEncolada = true;
      }
      if (fotoPath != null) {
        // v1.2.9: usar la cola persistente (no fotos_pendientes).
        await FotosColaService.instance.encolarFoto(
          opUuid: opUuid,
          rutaOriginal: fotoPath,
        );
      }
      // Guardado completo: el intento se cierra.
      _opUuidIntento = null;
      _payloadIntentoJson = null;
      _opIntentoEncolada = false;
      if (!mounted) return;
      // 1.35 (UI-02): la inscripción guardada se siente.
      Tacto.confirmacion();
      mostrarSnack(context, 'Guardado (se sincronizará)', significado: SignificadoChip.exito);
      Navigator.of(context).pop();
      SyncEngine.instance.push();
    } catch (e) {
      if (!mounted) return;
      AppLog.error('inscribir', 'guardar_fallo', d: '$e');
      mostrarSnack(context, 'Error: ${mensajeErrorAmable(e)}', significado: SignificadoChip.error);
    } finally {
      if (mounted) {
        setState(() {
          _guardando = false;
          _confirmandoGuardado = false;
        });
      }
    }
  }

  Future<Map<String, double>> _precios() async {
    final aj = await LocalDb.instance.getAjustes();
    // Yunque B (YB-DIN-02): lector tolerante (ver
    // dialogo_pago): un importe como texto no puede tumbar
    // el alta con un TypeError.
    return {
      'mensual': montoAjusteTolerante(aj['mensualidad']) ?? 2000,
      'semanal': montoAjusteTolerante(aj['pago_semanal']) ?? 600,
      'quincenal': montoAjusteTolerante(aj['pago_quincenal']) ?? 1200,
      // v1.3.9 (Bug 2): tarifa por transferencia (difiere del efectivo).
      'transfer': montoAjusteTolerante(aj['transferencia']) ?? 2500,
    };
  }

  /// 1.25 T61: refresco ligero de la barra de pasos y
  /// el resumen al teclear (los controladores no llaman
  /// setState por sí solos).
  void _refrescar() {
    if (mounted) setState(() {});
  }

  /// SL-3 (G02-1): ¿la membresía pasaría el guardado? La
  /// MISMA regla de _guardarAhora: en Casa no hay cobro
  /// (completa sin pago); con período personalizado hacen
  /// falta días y monto válidos (el guardado rechaza
  /// «Indica días y monto válidos»); con cualquier otro
  /// período, la selección siempre trae un período válido.
  /// Antes la barra copiaba el estado de «Datos» y daba la
  /// membresía por completa con datos que el guardado
  /// rechazaba.
  bool get _membresiaOkSegunGuardado {
    if (_cuentaCasa) return true;
    if (_periodo != 'personalizado') return true;
    final v = double.tryParse(_monto.text.trim().replaceAll(',', '.'));
    return _diasPeriodo() > 0 && v != null && v.isFinite && v > 0;
  }

  /// 1.25 T61: barra de pasos «Datos → Membresía →
  /// Foto» con su progreso. El paso activo es el primero
  /// incompleto; tocar un paso salta a su sección.
  /// SL-3 (G02-1): cada paso deriva su estado de las
  /// MISMAS validaciones del guardado — Datos: nombre,
  /// teléfono vacío o sanitizable, carnet vacío o válido
  /// y, con «crear acceso», teléfono válido de 8 dígitos;
  /// Membresía: [_membresiaOkSegunGuardado]. Foto es
  /// OPCIONAL: se marca «opcional», nunca «pendiente», y
  /// no bloquea el progreso ni el paso activo.
  Widget _barraPasos() {
    final tel = _telefono.text.trim();
    // 1.29 (FB-07): el paso «Datos» valida lo mismo que el
    // guardado: vacío o sanitizable a 8 dígitos.
    final telSano = tel.isEmpty ? '' : (sanitizarTelefono(tel) ?? '');
    final carnetDigitos = _carnet.text.replaceAll(RegExp(r'[^0-9]'), '');
    final datosOk = _nombre.text.trim().isNotEmpty &&
        (tel.isEmpty || sanitizarTelefono(tel) != null) &&
        (carnetDigitos.isEmpty || validarCarnet(carnetDigitos)) &&
        (!_crearAccesoApp || validarTelefono(telSano));
    final pasos = <({String etiqueta, bool ok, bool opcional, GlobalKey clave})>[
      (etiqueta: 'Datos', ok: datosOk, opcional: false, clave: _claveDatos),
      (
        etiqueta: 'Membresía',
        ok: _membresiaOkSegunGuardado,
        opcional: false,
        clave: _claveMembresia
      ),
      (
        etiqueta: 'Foto',
        ok: _foto != null,
        opcional: true,
        clave: _claveFoto
      ),
    ];
    final activo = pasos.indexWhere((p) => !p.ok && !p.opcional);
    final completos = pasos.where((p) => p.ok || p.opcional).length;
    return Material(
      color: AppColores.superficie(context),
      child: Padding(
        // Cierre del lote 1.35: la barra respira a md en los
        // lados — con la etiqueta «Foto · opcional» de G02-1
        // la fila desbordaba 11 px en el arnés de la oleada 5
        // (y en teléfonos estrechos); el contenido no cambia.
        padding: const EdgeInsets.fromLTRB(AppEspacio.md,
            AppEspacio.sm, AppEspacio.md, AppEspacio.sm),
        child: Column(
          children: [
            Row(
              children: [
                for (var i = 0; i < pasos.length; i++) ...[
                  if (i > 0)
                    Expanded(
                      child: Container(
                        height: 2,
                        color: pasos[i].ok || i <= activo
                            ? AppColores.naranja
                            : AppColores.borde(context),
                      ),
                    ),
                  InkWell(
                    borderRadius:
                        BorderRadius.circular(AppRadio.md),
                    onTap: () {
                      final ctx = pasos[i].clave.currentContext;
                      if (ctx != null) {
                        Scrollable.ensureVisible(ctx,
                            duration: AppMovimiento.larga,
                            curve: AppMovimiento.curvaSuave,
                            alignment: 0.05);
                      }
                    },
                    // 1.30 (Oleada D6, UI130-22): el paso
                    // se anuncia como botón y su objetivo
                    // táctil mide al menos 48 dp de alto
                    // (antes ~30: círculo de 22 + 4 y 4).
                    child: Semantics(
                      button: true,
                      label: 'Ir al paso ${pasos[i].etiqueta}',
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(minHeight: 48),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: AppEspacio.xs),
                            child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 11,
                            backgroundColor: pasos[i].ok
                                ? AppColores.exito
                                : i == activo
                                    ? AppColores.naranja
                                    : AppColores.borde(context),
                            child: Icon(
                              // SL-3 (G02-1): el paso
                              // opcional sin completar no
                              // es un «pendiente»: lleva su
                              // icono propio, no el punto
                              // de paso incompleto.
                              pasos[i].ok
                                  ? Icons.check_rounded
                                  : pasos[i].opcional
                                      ? Icons.photo_camera_rounded
                                      : Icons.circle,
                              size: pasos[i].ok || pasos[i].opcional
                                  ? 13
                                  : 6,
                              // 136-697: el paso incompleto
                              // lleva su icono en el color de
                              // texto secundario sobre el borde
                              // (blanco sobre borde era
                              // invisible).
                              color: pasos[i].ok
                                  ? Colors.white
                                  : AppColores.textoSecundario(
                                      context),
                            ),
                          ),
                          const SizedBox(width: AppEspacio.xs),
                          Text(
                              pasos[i].opcional
                                  ? '${pasos[i].etiqueta} · opcional'
                                  : pasos[i].etiqueta,
                              style: AppTexto.etiqueta.copyWith(
                                  // 1.30 D1 (UI130-03): el paso
                                  // activo es TEXTO de marca:
                                  // va por textoNaranja, no la
                                  // marca a pelo.
                                  color: i == activo
                                      ? AppColores.textoNaranja(context)
                                      : null,
                                  fontWeight: i == activo
                                      ? FontWeight.w700
                                      : null)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadio.sm),
              child: LinearProgressIndicator(
                value: completos / pasos.length,
                minHeight: 3,
                backgroundColor: AppColores.borde(context),
                color: AppColores.naranja,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(
        context,
        widget.conversion != null ? 'Convertir invitado en cliente' : 'Inscribir cliente',
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          _barraPasos(),
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
                          // 1.25 T117 (F1-68): el aviso va en
                          // viñetas cortas, no en un párrafo único.
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Estás convirtiendo a un invitado '
                                'registrado desde la app de clientes.',
                                style: AppTexto.secundario,
                              ),
                              const Text(
                                '• Al guardar, pasa a ser cliente '
                                'con los datos de este formulario.',
                                style: AppTexto.secundario,
                              ),
                              if (widget
                                  .conversion!.medidas.isNotEmpty)
                                Text(
                                  '• Trae ${widget.conversion!.medidas.length} '
                                  'medida(s) autodeclaradas: el '
                                  'servidor verifica cuáles son de '
                                  'este invitado y solo importa las '
                                  'confirmadas.',
                                  style: AppTexto.secundario,
                                ),
                              const Text(
                                '• El resultado de la verificación '
                                'se ve al confirmarse la conversión.',
                                style: AppTexto.secundario,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.md),
                ],
                // Bloque 1: información personal
                Tarjeta(
                  key: _claveDatos,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.person_rounded,
                              color: AppColores.textoSecundario(context)),
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
                          focusNode: _focoNombre,
                          errorText: _errNombre,
                          onChanged: (v) {
                            if (_errNombre != null &&
                                v.trim().isNotEmpty) {
                              setState(() => _errNombre = null);
                            }
                          },
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
                                  Icons.male_rounded,
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
                                  Icons.female_rounded,
                                  size: 18),
                              selected: _sexo == 'F',
                              onSelected: (_) =>
                                  setState(
                                      () => _sexo = 'F')),
                        ],
                      ),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTelefono(
                          controller: _telefono,
                          focusNode: _focoTelefono,
                          errorText: _errTelefono,
                          onChanged: (v) {
                            final t = v.trim();
                            // 1.29 (FB-07) + 1.30 (D3, UI130-14):
                            // CampoTelefono limpia los dígitos al
                            // teclear (el internacional pegado colapsa
                            // a los 8 locales y el +53 es solo el
                            // prefijo visual); el aviso en vivo sigue
                            // aceptando lo que el guardado sanitiza.
                            setState(() => _errTelefono =
                                (t.isEmpty || sanitizarTelefono(t) != null)
                                    ? null
                                    : 'Teléfono inválido: 8 dígitos empezando con 5 o 6');
                          },
                          etiqueta: 'Teléfono (8 dígitos)',
                          icono: Icons.phone_rounded),
                      // 1.32 (Disparador 2B · Compuerta 2):
                      // si el número tecleado pertenece a un
                      // invitado de la caché LOCAL, se ofrece
                      // su ficha para convertirlo en vez de
                      // duplicarlo. Sin caché o sin
                      // coincidencia, no ocupa espacio.
                      if (widget.conversion == null)
                        Builder(builder: (context) {
                          final coincide =
                              InvitadosService.invitadoPorTelefonoEnCache(
                                  _cacheInvitados2B, _telefono.text);
                          if (coincide == null) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(
                                top: AppEspacio.md),
                            child: Tarjeta(
                              color: AppColores.alerta
                                  .withValues(alpha: 0.12),
                              child: Row(
                                children: [
                                  const Icon(
                                      Icons.person_search_rounded,
                                      color: AppColores.alerta),
                                  const SizedBox(
                                      width: AppEspacio.sm),
                                  Expanded(
                                    child: Text(
                                      'Este número pertenece al '
                                      'invitado ${coincide.nombre}. '
                                      'Si es la misma persona, '
                                      'conviértelo desde su ficha '
                                      'para no duplicarlo.',
                                      style: AppTexto.secundario,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.of(
                                            context)
                                        .push(RutaIron(
                                            builder: (_) =>
                                                InvitadoDetalleScreen(
                                                    invitadoId:
                                                        coincide.id))),
                                    child: const Text('Su ficha'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      const SizedBox(
                          height: AppEspacio.md),
                      CampoTexto(
                          controller: _carnet,
                          focusNode: _focoCarnet,
                          errorText: _errCarnet,
                          onChanged: (v) {
                            final t = v.trim();
                            setState(() => _errCarnet =
                                (t.isEmpty || validarCarnet(t))
                                    ? null
                                    : 'Carnet inválido: 6 a 11 dígitos');
                          },
                          etiqueta:
                              'Carnet (6–11 dígitos)',
                          icono: Icons.badge_rounded,
                          teclado:
                              TextInputType.number),
                      // v1.5.0 (Bloque G): aviso de fecha
                      // imposible; NO bloquea el guardado.
                      if (_carnetFechaInvalida)
                        const AvisoFechaCarnet(),
                      // Q5 (cola 1.20): aviso de carnet que
                      // parece teléfono; tampoco bloquea.
                      if (_carnetPareceTelefono)
                        const AvisoCarnetTelefono(),
                      // 1.25 T117 (F1-65): en cuanto el carnet dice
                      // que es menor, su tarifa se anuncia aquí,
                      // junto al dato que la decide (antes solo se
                      // veía dentro del desplegable de meses).
                      if (_esMenor) ...[
                        const SizedBox(height: AppEspacio.sm),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ChipEstado.semantico(
                            texto: 'Menor de edad · tarifa '
                                '${fmtMonto(_precioMenorVal)} CUP/mes',
                            significado: SignificadoChip.info,
                            icono: Icons.child_care_rounded,
                          ),
                        ),
                      ],
                      // 1.25 T117 (F1-66): notas opcionales de la
                      // inscripción; viajan en la op y quedan en la
                      // ficha del cliente.
                      const SizedBox(height: AppEspacio.md),
                      CampoTexto(
                          controller: _notas,
                          etiqueta: 'Notas (opcional)',
                          icono: Icons.note_alt_rounded,
                          maxLineas: 2),
                    ],
                  ),
                ),
                const SizedBox(
                    height: AppEspacio.md),
                // 1.25 T19: las decisiones junto al dato del que
                // dependen (antes vivían al final del formulario):
                // el acceso, junto al teléfono que lo exige; la
                // Casa, justo antes de la membresía que descarta.
                // v1.4.0 Paso 2 (propuesta 11): acceso a la app de
                // clientes al inscribir (solo dueño; el PIN llega por
                // Telegram a Jc cuando el cliente sincroniza).
                if (AuthService().isOwner) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                        'Crear acceso a la app de clientes'),
                    subtitle: const Text(
                        'Requiere el teléfono de arriba, de 8 '
                        'dígitos. El PIN se genera al sincronizar '
                        'y le llega a Jc por Telegram para '
                        'entregarlo al cliente.',
                        style: AppTexto.secundario),
                    value: _crearAccesoApp,
                    onChanged: (v) {
                      setState(() => _crearAccesoApp = v);
                      // 136-696: al ACTIVAR «Crear acceso»,
                      // el teléfono se valida en el acto (no
                      // recién al guardar).
                      if (v) {
                        final tel = _telefono.text.trim();
                        final sano = tel.isEmpty
                            ? ''
                            : (sanitizarTelefono(tel) ?? '');
                        if (!validarTelefono(sano)) {
                          _fijarError('telefono',
                              'Para crear el acceso de la app '
                              'hace falta un teléfono válido de '
                              '8 dígitos.');
                        }
                      }
                    },
                  ),
                  const SizedBox(height: AppEspacio.md),
                ],
                // v1.7.0: inscribir como Cuenta a la Casa (solo
                // dueño; no aplica en una conversión de invitado,
                // que sigue su flujo con pago).
                if (AuthService().isOwner &&
                    widget.conversion == null) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Cuenta a la Casa'),
                    subtitle: const Text(
                        'Sin cobro y sin vencimiento: acceso '
                        'permanente. No cuenta en nómina ni en '
                        'avisos. Solo el dueño puede otorgarla.',
                        style: AppTexto.secundario),
                    value: _cuentaCasa,
                    onChanged: _confirmandoCasa
                        ? null
                        : (v) async {
                      if (!v) {
                        setState(() => _cuentaCasa = false);
                        return;
                      }
                      setState(() => _confirmandoCasa = true);
                      // T19: activar la Casa DESCARTA la
                      // membresía elegida abajo; se dice antes
                      // de que ocurra, no después.
                      final ok = await DialogoApp.confirmar(
                        context,
                        titulo: '¿Inscribir como Cuenta a la Casa?',
                        mensaje:
                            'La Casa no cobra: la sección de '
                            'membresía se descarta y el cliente '
                            'queda con acceso permanente, sin '
                            'vencimiento.',
                        aceptar: 'Sí, es Casa',
                        icono: Icons.home_rounded,
                      );
                      if (ok == true && mounted) {
                        setState(() => _cuentaCasa = true);
                      }
                      if (mounted) {
                        setState(() => _confirmandoCasa = false);
                      }
                    },
                  ),
                  const SizedBox(height: AppEspacio.md),
                ],
                // Bloque 2: membresía (con Cuenta a la Casa no hay
                // cobro: se sustituye por el aviso dorado).
                if (!_cuentaCasa)
                Tarjeta(
                  key: _claveMembresia,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                              Icons.card_membership_rounded,
                              color: AppColores.textoSecundario(context)),
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
                        future: _preciosFut,
                        builder: (ctx, snap) {
                          final pr = snap.data ??
                              {
                                'mensual': 2000.0,
                                'semanal': 600.0,
                                'quincenal': 1200.0,
                                // Argón #7A-2: el mapa de respaldo debe
                                // traer 'transfer' o el chip de
                                // transferencia rompe el primer frame
                                // con pr['transfer']!.
                                'transfer': 2500.0,
                              };
                          // 1.36 H-B2 (136-694): si los
                          // precios no cargaron, se DICE (las
                          // etiquetas salen de los de
                          // referencia, no de los vigentes).
                          if (snap.hasError) {
                            AppLog.error('inscribir',
                                'precios_fallo',
                                d: '${snap.error}');
                          }
                          return Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                            children: [
                              if (snap.hasError)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      bottom: AppEspacio.sm),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'No se pudieron cargar '
                                          'los precios actuales: '
                                          'las etiquetas muestran '
                                          'los de referencia.',
                                          style: AppTexto.metadato
                                              .copyWith(
                                                  color: AppColores
                                                      .errorTexto(
                                                          context)),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () => setState(
                                            () => _preciosFut =
                                                _precios()),
                                        child:
                                            const Text('Reintentar'),
                                      ),
                                    ],
                                  ),
                                ),
                              if (_errorTipos)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      bottom: AppEspacio.sm),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'No se pudieron cargar '
                                          'los tipos de pago '
                                          'personalizados.',
                                          style: AppTexto.metadato
                                              .copyWith(
                                                  color: AppColores
                                                      .errorTexto(
                                                          context)),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed:
                                            _cargarTiposCustom,
                                        child:
                                            const Text('Reintentar'),
                                      ),
                                    ],
                                  ),
                                ),
                              SelectorIronForm<String>(
                                valorInicial: _periodo ==
                                        'mensual'
                                    ? 'mensual:$_meses'
                                    : _periodo,
                                tituloPanel: 'Período',
                                opciones: [
                                  OpcionSelector(
                                      'semanal',
                                      'Semana (${fmtMonto(pr['semanal'])} CUP)'),
                                  OpcionSelector(
                                      'quincenal',
                                      'Quincena (${fmtMonto(pr['quincenal'])} CUP)'),
                                  for (final m
                                      in [1, 2, 3])
                                    OpcionSelector(
                                        'mensual:$m',
                                        _esMenor &&
                                                !_precioMenorCargado
                                            ? '$m mes${m == 1 ? '' : 'es'} (cargando tarifa de menor…)'
                                            : _esMenor
                                            ? '$m mes${m == 1 ? '' : 'es'} (${fmtMonto(_precioMenorVal * m)} CUP) — Menor de edad'
                                            // v1.3.9 (Bug 2): mostrar tarifa según método de pago elegido.
                                            : '$m mes${m == 1 ? '' : 'es'} (${fmtMonto((_metodoPago == 'transferencia' ? pr['transfer']! : pr['mensual']!) * m)} CUP)'),
                                  // v1.3.9: tipos personalizados (ej. "Oferta 50%")
                                  for (final t
                                      in _tiposCustom)
                                    OpcionSelector(
                                        'tipo:${t.id}',
                                        // 1.25 T117 (F1-62): los días
                                        // del tipo van en la etiqueta:
                                        // dos ofertas con igual monto
                                        // y distinta duración ya no se
                                        // confunden.
                                        '${t.nombre} · ${t.dias} días · ${fmtMonto(t.monto)} CUP'),
                                  const OpcionSelector(
                                      'personalizado',
                                      'Personalizado…'),
                                ],
                                alCambiar: (v) =>
                                    setState(() {
                                  if (v ==
                                          'semanal' ||
                                      v ==
                                          'quincenal' ||
                                      v ==
                                          'personalizado') {
                                    _periodo = v!;
                                    _tipoCustomSel = null;
                                    // Argón #7A-1: sin meses residuales.
                                    _meses = 1;
                                  } else if (v!
                                      .startsWith(
                                          'tipo:')) {
                                    // v1.3.9: tipo personalizado
                                    _periodo = v;
                                    // Argón #7A-1: sin meses residuales.
                                    _meses = 1;
                                    final id = v
                                        .substring(5);
                                    // Pasada 2 de Argón (#4.2,
                                    // 1.20): búsqueda sin
                                    // firstWhere/orElse-first —
                                    // si la lista se recargó
                                    // vacía entre el build y el
                                    // toque, .first lanzaba
                                    // StateError. Sin hallazgo,
                                    // la selección queda null.
                                    _tipoCustomSel = null;
                                    for (final t
                                        in _tiposCustom) {
                                      if (t.id == id) {
                                        _tipoCustomSel = t;
                                        break;
                                      }
                                    }
                                  } else {
                                    _periodo =
                                        'mensual';
                                    _tipoCustomSel =
                                        null;
                                    _meses = int.parse(
                                        v.split(
                                            ':')[1]);
                                  }
                                }),
                              ),
                              // 1.36 H-B2 (136-695): los
                              // campos de «Personalizado»
                              // entran con AnimatedSize.
                              AnimatedSize(
                                duration: AppMovimiento.corta,
                                alignment: Alignment.topCenter,
                                child: _periodo == 'personalizado'
                                    ? Padding(
                                        padding: const EdgeInsets
                                            .only(
                                            top: AppEspacio.md),
                                        child: Row(
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
                                      )
                                    : const SizedBox.shrink(),
                              ),
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
                              avatar: const Icon(Icons.payments_rounded, size: 18),
                              selected: _metodoPago == 'efectivo',
                              onSelected: (_) => setState(
                                  () => _metodoPago = 'efectivo')),
                          const SizedBox(width: 8),
                          ChoiceChip(
                              label: const Text('Transferencia'),
                              avatar: const Icon(Icons.smartphone_rounded, size: 18),
                              selected: _metodoPago == 'transferencia',
                              onSelected: (_) => setState(
                                  () => _metodoPago = 'transferencia')),
                        ],
                      ),
                      // 1.35 (CAMPO-8): selector «Comenzó el».
                      // Por defecto HOY (el pago se asienta
                      // hoy); elegir otra fecha es la
                      // excepción: el pago se asienta en ESA
                      // fecha y la cobertura corre desde ella.
                      const SizedBox(height: AppEspacio.md),
                      const Text('Comenzó el:',
                          style: AppTexto.cuerpo),
                      const SizedBox(height: AppEspacio.sm),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.calendar_month_rounded,
                                  size: 18),
                              label: Text(_inicioEsExcepcion
                                  ? fmtFecha(_inicioIso)
                                  : 'Hoy (${fmtFecha(hoyHabanaIso())})'),
                              onPressed: _elegirFechaInicio,
                            ),
                          ),
                          if (_inicioEsExcepcion)
                            TextButton(
                              onPressed: () => setState(
                                  () => _fechaInicioSel = null),
                              child: const Text('Volver a hoy'),
                            ),
                        ],
                      ),
                      if (_inicioEsExcepcion) ...[
                        const SizedBox(height: AppEspacio.sm),
                        Text(
                          'El pago se asentará el '
                          '${fmtFecha(_inicioIso)} (en la caja y '
                          'la nómina de ese día) y la cobertura '
                          'corre desde ese día.',
                          style: AppTexto.secundario,
                        ),
                      ],
                    ],
                  ),
                ),
                if (_cuentaCasa) ...[
                  Tarjeta(
                    color: AppColores.casaFondo,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.home_rounded,
                            color: AppColores.casaIcono),
                        const SizedBox(width: AppEspacio.sm),
                        Expanded(
                          child: Text(
                            'Cuenta a la Casa: sin cobro y sin '
                            'vencimiento. Esta persona usa el gym '
                            'como cliente activo siempre; no entra '
                            'en nómina ni en avisos de vencimiento.',
                            style: AppTexto.secundario.copyWith(
                                color: AppColores.casaTexto),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.md),
                ],
                const SizedBox(
                    height: AppEspacio.md),
                // Bloque 3: fotografía
                Tarjeta(
                  key: _claveFoto,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 1.29 (D-15): icono canónico de foto
                          // de la tabla D-07 (photo_camera_rounded).
                          Icon(Icons.photo_camera_rounded,
                              color: AppColores.textoSecundario(context)),
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
                                  Icons.photo_camera_rounded),
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
                                  Icons.photo_library_rounded),
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
                      // 1.25 T117 (F1-64): una foto equivocada se
                      // puede quitar sin salir de la pantalla.
                      if (_foto != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18),
                            label: const Text('Quitar foto'),
                            // 1.36 H-B2 (136-693): quitar la
                            // foto BORRA el archivo descartado
                            // en segundo plano (antes solo se
                            // soltaba la referencia y el
                            // original quedaba huérfano).
                            onPressed: () {
                              final descartada = _foto;
                              setState(() => _foto = null);
                              if (descartada != null) {
                                unawaited(() async {
                                  try {
                                    await descartada.delete();
                                  } catch (_) {}
                                }());
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppEspacio.lg),
              ],
            ),
          ),
          // V33: la acción de guardar vive en una barra fija
          // inferior, separada del contenido — siempre visible
          // sin bajar al final del formulario. Con el teclado
          // abierto la barra sube con él y el formulario sigue
          // desplazable en su Expanded (ningún campo queda
          // atrapado debajo).
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.sm, AppEspacio.lg, AppEspacio.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1.25 T60: resumen EN VIVO sobre el botón
                  // — monto, período, método y vencimiento
                  // se ven mientras se rellena, no solo en
                  // el diálogo final. Sale de los mismos
                  // cálculos del guardado (_montoPeriodo).
                  _resumenEnVivo(),
                  const SizedBox(height: AppEspacio.sm),
                  // 1.36 H-B2 (136-697): el botón conserva
                  // su rótulo y enseña el progreso (antes lo
                  // sustituía un spinner sin texto).
                  BotonPrimario(
                    // 1.25 T117 (F1-67): en modo conversión el
                    // botón dice la acción real, no la genérica.
                    texto: widget.conversion != null
                        ? 'Convertir en cliente'
                        : 'Guardar inscripción',
                    icono: Icons.check_rounded,
                    cargando: _confirmandoGuardado,
                    onPressed: _guardando ? null : _guardar,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
