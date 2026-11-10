import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../servicios.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';
import '../app_log.dart';

/// 1.31 (Oleada de Mejoras · «Precios y comisión» como zona
/// propia): los precios de la dosis, la dosis con agua y el
/// agua, con la comisión, salen de la antigua pantalla de
/// Administración de Servicios a su propia pantalla — es la
/// quinta zona del hub «Servicios» y donde el aviso del
/// diálogo de venta manda («Servicios → Precios y comisión»).
/// El guardado POR GRUPO (1.30 D5, UI130-17) se conserva
/// intacto: mismas claves, misma validación, misma clave
/// legacy que sigue al efectivo, mismo estado por grupo.
class ServiciosPreciosScreen extends StatefulWidget {
  const ServiciosPreciosScreen({super.key});

  @override
  State<ServiciosPreciosScreen> createState() =>
      _ServiciosPreciosScreenState();
}

class _ServiciosPreciosScreenState
    extends State<ServiciosPreciosScreen> {
  bool _cargando = true;
  ({double sinAgua, double conAgua, double agua, double comision})?
      _precios;
  // Ítem 7: un controlador por clave precio_<producto>_<método> y el
  // estado de cada interruptor activo_<producto>_<método>.
  static const _stemsPrecio = ['racion', 'combo', 'agua'];
  final _precioCtrl = <String, TextEditingController>{
    for (final s in _stemsPrecio)
      for (final m in const ['efectivo', 'transferencia'])
        '${s}_$m': TextEditingController(),
  };
  final _activoMet = <String, bool>{
    for (final s in _stemsPrecio)
      for (final m in const ['efectivo', 'transferencia'])
        '${s}_$m': true,
  };
  final _comisionCtrl = TextEditingController();
  // 1.30 D5 (UI130-17): foto base de cada grupo de precios al
  // cargar (para el estado «Cambios sin guardar» en vivo) y la
  // hora del último guardado por grupo («Guardado · hh:mm»).
  // El guardado es POR GRUPO: cada tarjeta de producto guarda
  // solo sus claves, con la semántica del guardado único de
  // antes (diff contra lo vigente resuelto; la legacy sigue
  // al efectivo).
  final _basePrecio = <String, double>{};
  final _baseActivo = <String, bool>{};
  double? _baseComision;
  final _guardadoEn = <String, String>{};


  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _precioCtrl.values) {
      c.dispose();
    }
    _comisionCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final precios = await preciosServicios();
    final ajustes = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    setState(() {
      _precios = precios;
      // Ítem 7: los campos nacen con los valores RESUELTOS
      // vigentes (lo que publica el servidor), no con claves
      // sueltas — como nacían en la pantalla de Administración.
      for (final s in _stemsPrecio) {
        final tipo = s == 'racion'
            ? 'dosis_sin_agua'
            : s == 'combo'
                ? 'dosis_con_agua'
                : 'agua_suelta';
        for (final m in const ['efectivo', 'transferencia']) {
          _precioCtrl['${s}_$m']!.text =
              precioServicioMetodo(ajustes, tipo, m).toStringAsFixed(0);
          _activoMet['${s}_$m'] = metodoServicioActivo(ajustes, tipo, m);
        }
      }
      _comisionCtrl.text = precios.comision.toStringAsFixed(0);
      // 1.30 D5 (UI130-17): la foto base del estado por grupo
      // es lo recién cargado (lo vigente resuelto).
      for (final s in _stemsPrecio) {
        final tipo = _tipoDeStem(s);
        for (final m in const ['efectivo', 'transferencia']) {
          _basePrecio['${s}_$m'] = precioServicioMetodo(ajustes, tipo, m);
          _baseActivo['${s}_$m'] = metodoServicioActivo(ajustes, tipo, m);
        }
      }
      _baseComision = precios.comision;
      _cargando = false;
    });
  }

  void _aviso(String msg, {bool error = false}) {
    if (!mounted) return;
    mostrarSnack(context, msg,
        significado:
            error ? SignificadoChip.error : SignificadoChip.neutral);
  }

  String _tipoDeStem(String stem) => stem == 'racion'
      ? 'dosis_sin_agua'
      : stem == 'combo'
          ? 'dosis_con_agua'
          : 'agua_suelta';

  String _horaHabana() {
    final h = ahoraHabana();
    return '${h.hour.toString().padLeft(2, '0')}:'
        '${h.minute.toString().padLeft(2, '0')}';
  }

  /// ¿El grupo [stem] difiere de su foto base (lo cargado)?
  /// Un texto no numérico cuenta como cambio (al guardar,
  /// caerá en la validación de siempre).
  bool _grupoSucio(String stem) {
    for (final m in const ['efectivo', 'transferencia']) {
      final v = double.tryParse(
          _precioCtrl['${stem}_$m']!.text.trim().replaceAll(',', '.'));
      if (v == null || !v.isFinite || v != _basePrecio['${stem}_$m']) {
        return true;
      }
      if (_activoMet['${stem}_$m'] != _baseActivo['${stem}_$m']) {
        return true;
      }
    }
    return false;
  }

  bool get _comisionSucia {
    final v = double.tryParse(
        _comisionCtrl.text.trim().replaceAll(',', '.'));
    return v == null || !v.isFinite || v != _baseComision;
  }

  /// 1.30 D5 (UI130-17): guardado POR GRUPO de un producto.
  /// La semántica es EXACTAMENTE la del guardado único
  /// anterior, acotada a las claves del grupo: diff contra lo
  /// vigente resuelto, la misma validación (dosis > 0; el
  /// agua admite 0) y la clave legacy que sigue al efectivo.
  Future<void> _guardarGrupoPrecios(String stem) async {
    // Ronda 3-9 #10: la pantalla ya bloquea a no-dueños en build;
    // esto frena un cambio de sesión a mitad.
    if (!AuthService().isOwner) return;
    final ajustes = await LocalDb.instance.getAjustes();
    final cambios = <String, num>{};
    final tipo = _tipoDeStem(stem);
    for (final m in const ['efectivo', 'transferencia']) {
      // Autoauditoría 1.22 #2 (clase N-2): lo no finito cae al
      // -1 «inválido» de siempre (NaN no era <= 0 y se guardaba
      // como precio de dosis en los ajustes).
      final valorCrudo = double.tryParse(
          _precioCtrl['${stem}_$m']!.text.trim().replaceAll(',', '.'));
      final valor =
          (valorCrudo != null && valorCrudo.isFinite) ? valorCrudo : -1;
      // Las dosis deben costar más de 0; el agua admite 0 (sin
      // fijar) y la comisión también.
      if (stem == 'agua' ? valor < 0 : valor <= 0) {
        _aviso('Revisa los valores: las dosis deben costar más de 0',
            error: true);
        return;
      }
      if (valor != precioServicioMetodo(ajustes, tipo, m)) {
        cambios['servicio_precio_${stem}_$m'] = valor;
      }
      final activo = _activoMet['${stem}_$m']! ? 1 : 0;
      if (activo != (metodoServicioActivo(ajustes, tipo, m) ? 1 : 0)) {
        cambios['servicio_activo_${stem}_$m'] = activo;
      }
    }
    // Compatibilidad: el precio único legacy del producto sigue
    // al de EFECTIVO, para las versiones viejas aún instaladas.
    const legacyDe = {
      'racion': 'servicio_precio_sin_agua',
      'combo': 'servicio_precio_con_agua',
      'agua': 'servicio_precio_agua',
    };
    final ef = cambios['servicio_precio_${stem}_efectivo'];
    if (ef != null &&
        ef.toDouble() != (ajustes[legacyDe[stem]] as num?)?.toDouble()) {
      cambios[legacyDe[stem]!] = ef;
    }
    if (cambios.isEmpty) {
      _aviso('Sin cambios');
      return;
    }
    await _aplicarCambiosAjustes(cambios);
    if (!mounted) return;
    setState(() => _guardadoEn[stem] = _horaHabana());
    _aviso('Precios guardados (se sincronizarán)');
    await _cargar();
  }

  /// 1.30 D5 (UI130-17): la comisión es su propio grupo, con
  /// su guardado — misma validación y misma clave de siempre.
  Future<void> _guardarComision() async {
    // Ronda 3-9 #10: solo el dueño (ver _guardarGrupoPrecios).
    if (!AuthService().isOwner) return;
    final comisionCruda = double.tryParse(
        _comisionCtrl.text.trim().replaceAll(',', '.'));
    final comision =
        (comisionCruda != null && comisionCruda.isFinite) ? comisionCruda : -1;
    if (comision < 0) {
      _aviso('Revisa la comisión', error: true);
      return;
    }
    final cambios = <String, num>{};
    final pr = _precios;
    if (pr != null && comision != pr.comision) {
      cambios['servicio_comision_dosis'] = comision;
    }
    if (cambios.isEmpty) {
      _aviso('Sin cambios');
      return;
    }
    await _aplicarCambiosAjustes(cambios);
    if (!mounted) return;
    setState(() => _guardadoEn['comision'] = _horaHabana());
    _aviso('Precios guardados (se sincronizarán)');
    await _cargar();
  }

  /// El final común de todo guardado de ajustes de esta
  /// pantalla (era el final del guardado único): una op
  /// 'ajuste' por clave, la actualización optimista del
  /// espejo local (claves sueltas Y la estructura resuelta
  /// que leen los formularios) y el push.
  Future<void> _aplicarCambiosAjustes(Map<String, num> cambios) async {
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
      );
    }
    // Actualización optimista del espejo local de ajustes (patrón
    // de AdminScreen): claves sueltas Y la estructura resuelta que
    // leen los formularios, para que el cambio se vea sin esperar
    // al próximo pull.
    final aj = await LocalDb.instance.getAjustes();
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
    }
    final pub = aj['servicio_precios_metodo'];
    if (pub is Map) {
      for (final e in cambios.entries) {
        final partes = e.key.split('_');
        if (partes.length == 4 && partes[0] == 'servicio') {
          final prod = pub[partes[2]];
          if (prod is Map) {
            prod[partes[1] == 'precio'
                ? partes[3]
                : 'activo_${partes[3]}'] = e.value;
          }
        }
      }
    }
    await LocalDb.instance.setAjustes(aj);
    SyncEngine.instance.push();
  }

  /// El estado de un grupo de precios: «Cambios sin guardar»
  /// en alerta mientras difiere de su foto base, o la hora de
  /// su último guardado en esta visita a la pantalla.
  Widget _estadoGrupo(String clave, bool sucio) {
    if (sucio) {
      return Text('Cambios sin guardar',
          style: AppTexto.metadato.copyWith(
              color: AppColores.alerta, fontWeight: FontWeight.w600));
    }
    final hora = _guardadoEn[clave];
    if (hora == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_rounded, size: 14, color: AppColores.exito),
        const SizedBox(width: 4),
        Text('Guardado · $hora',
            style: AppTexto.metadato
                .copyWith(color: AppColores.textoSecundario(context))),
      ],
    );
  }

  Widget _tarjetaGrupoPrecio(String titulo, String stem) {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo, style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          // Ítem 7: precio por (producto, método), con los
          // campos de moneda del kit (D3).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CampoMoneda(
                  etiqueta: 'Efectivo',
                  controller: _precioCtrl['${stem}_efectivo']!,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: CampoMoneda(
                  etiqueta: 'Transferencia',
                  controller: _precioCtrl['${stem}_transferencia']!,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          // 1.30 D5 (UI130-17): los interruptores van a lo
          // ancho, uno por línea (antes dos apretados en una
          // fila, con la etiqueta cortada). Cada uno lleva su
          // Material transparente: dentro de una Tarjeta sin
          // onTap (que no crea Material), la tinta del
          // ListTile caería en un ancestro lejano y Flutter
          // avisa de que el fondo/la tinta serían invisibles.
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cobrar en efectivo'),
              value: _activoMet['${stem}_efectivo']!,
              onChanged: (v) =>
                  setState(() => _activoMet['${stem}_efectivo'] = v),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cobrar por transferencia'),
              value: _activoMet['${stem}_transferencia']!,
              onChanged: (v) => setState(
                  () => _activoMet['${stem}_transferencia'] = v),
            ),
          ),
          Row(
            children: [
              Expanded(child: _estadoGrupo(stem, _grupoSucio(stem))),
              FilledButton(
                onPressed: () => _guardarGrupoPrecios(stem),
                child: const Text('Guardar'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 1.30 D5 (UI130-17): la antigua megatarjeta de «Precios y
  // comisión» se reparte en una tarjeta por grupo, cada una
  // con su guardado y su estado. La carga es la misma
  // (_cargar) y el guardado conserva la semántica del único
  // (ver _guardarGrupoPrecios y _guardarComision).
  Widget _seccionPrecios() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Precios y comisión', style: AppTexto.titulo),
        const SizedBox(height: AppEspacio.sm),
        _tarjetaGrupoPrecio('Dosis', 'racion'),
        const SizedBox(height: AppEspacio.sm),
        _tarjetaGrupoPrecio('Dosis con agua', 'combo'),
        const SizedBox(height: AppEspacio.sm),
        _tarjetaGrupoPrecio('Agua', 'agua'),
        const SizedBox(height: AppEspacio.sm),
        Tarjeta(
          padding: const EdgeInsets.all(AppEspacio.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Comisión', style: AppTexto.subtitulo),
              const SizedBox(height: AppEspacio.sm),
              CampoMoneda(
                etiqueta: 'Comisión por dosis',
                controller: _comisionCtrl,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppEspacio.sm),
              Row(
                children: [
                  Expanded(
                      child: _estadoGrupo('comision', _comisionSucia)),
                  FilledButton(
                    onPressed: _guardarComision,
                    child: const Text('Guardar'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppEspacio.sm),
        Text(
          'Agua en 0 = precio sin fijar (no se puede vender suelta). '
          'Comisión en 0 = sin comisión. La comisión se paga con la '
          'nómina del mes. Apagar ambos métodos de un producto lo '
          'deja invendible (la Cuenta a la Casa no se afecta).',
          style: AppTexto.metadato.copyWith(color: Colors.grey),
        ),
      ],
    );
  }


  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Precios y comisión'),
        body: const Center(
            child: Text('Solo el dueño fija los precios.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Precios y comisión',
        acciones: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const SkeletonAjustes(grupos: 4)
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [_seccionPrecios()],
            ),
    );
  }
}
