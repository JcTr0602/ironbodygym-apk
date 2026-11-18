/// v1.13.0 (Bloque 4, D4): sección «Medidas» de la ficha del cliente.
///
/// Filas INMUTABLES (nunca se editan: una corrección es una fila
/// nueva). El registro viaja por la op `registrar_medicion_cliente`
/// (CHECK 80, otra vía) y baja por el espejo `cliente_mediciones`.
/// La lectura combina espejo + ops pendientes del propio teléfono.
/// Gate: permiso `can_record_measurements` (el dueño siempre puede).
/// Si el permiso se revoca con la op en cola, el servidor la rechaza
/// de forma NO bloqueante (nunca atasca la cola).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../mediciones_cliente.dart';
import '../negocio.dart' show fmtFecha;
import '../permisos_entrenador.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'grafico_metrica.dart';

/// Nombre legible de cada métrica para chips y gráficos.
const Map<String, String> kNombreMetrica = {
  'peso_kg': 'Peso',
  'cintura_cm': 'Cintura',
  'brazo_cm': 'Brazo',
  'pecho_cm': 'Pecho',
  'muslo_cm': 'Muslo',
  'cadera_cm': 'Cadera',
  'grasa_pct': 'Grasa corporal',
};

String nombreMetrica(String clave) =>
    kNombreMetrica[clave] ?? clave.replaceAll('_', ' ');

/// Valor con un decimal y coma, como pinta la ficha.
String _fmtMedida(double v) =>
    v.toStringAsFixed(1).replaceAll('.', ',');

class TarjetaMedidas extends StatefulWidget {
  final int clienteId;

  /// 1.28 (M4-B3): mediciones ya leídas por la ficha (su
  /// _cargar las necesita para el resumen). Si vienen, la
  /// tarjeta NO reescanea el espejo al abrir: dos escaneos
  /// completos por apertura era el coste de R3M4-H6.
  final List<Map<String, dynamic>>? medidasIniciales;

  const TarjetaMedidas(
      {super.key, required this.clienteId, this.medidasIniciales});

  @override
  State<TarjetaMedidas> createState() => _TarjetaMedidasState();
}

class _TarjetaMedidasState extends State<TarjetaMedidas> {
  List<Map<String, dynamic>> _medidas = [];
  bool _cargando = true;
  // 1.36 H-B2 (136-554): fallo de carga visible con reintento
  // (antes un error de lectura dejaba la tarjeta en «sin
  // medidas» o cargando para siempre).
  bool _errorCarga = false;
  // 1.28 (M4-A12): registro en curso — dos toques abrían
  // dos diálogos y registraban la fila dos veces.
  bool _registrando = false;
  // 1.28 (M4-B3): la tarjeta enseña la evolución (última
  // medición + gráfico); el historial entero solo con
  // «Ver todo».
  bool _verTodo = false;
  // 1.36 FICHA (136-210): «Ver todo» pinta el historial
  // por tramos de 40 (antes, todas las mediciones en un
  // solo Column de golpe) y la serie/los deltas se
  // memoizan por identidad de la lista de medidas.
  int _topeVerTodo = 40;
  List<Map<String, dynamic>>? _medidasMemoSerie;
  String? _metricaMemoSerie;
  List<({DateTime fecha, double valor})>? _serieMemo;
  List<Map<String, dynamic>>? _medidasMemoDeltas;
  Map<String, double?>? _deltasMemo;

  List<({DateTime fecha, double valor})> _serieVigente() {
    if (identical(_medidas, _medidasMemoSerie) &&
        _metricaVigente == _metricaMemoSerie &&
        _serieMemo != null) {
      return _serieMemo!;
    }
    final s = serieMedicion(_medidas, _metricaVigente);
    _medidasMemoSerie = _medidas;
    _metricaMemoSerie = _metricaVigente;
    _serieMemo = s;
    return s;
  }

  Map<String, double?> _deltasVigentes() {
    if (identical(_medidas, _medidasMemoDeltas) &&
        _deltasMemo != null) {
      return _deltasMemo!;
    }
    final d = deltasUltimaMedicion(_medidas);
    _medidasMemoDeltas = _medidas;
    _deltasMemo = d;
    return d;
  }
  String? _metricaGrafico;

  @override
  void initState() {
    super.initState();
    final iniciales = widget.medidasIniciales;
    if (iniciales != null) {
      _medidas = iniciales;
      _cargando = false;
    } else {
      _cargar();
    }
  }

  @override
  void didUpdateWidget(TarjetaMedidas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // La ficha recargó y trae una foto IGUAL O MÁS NUEVA
    // (nunca más corta: una foto vieja no pisa el registro
    // local recién hecho que esta tarjeta ya recargó).
    final nuevas = widget.medidasIniciales;
    if (nuevas != null &&
        !identical(nuevas, oldWidget.medidasIniciales)) {
      // 1.36 H-C1 (136-553): una lista MÁS CORTA se acepta
      // cuando no es una foto vieja: si conserva la
      // medición local más reciente (mismo id y mismo
      // instante), lo que falta son filas BORRADAS y la
      // foto es la vigente. La foto vieja —anterior al
      // registro local recién hecho— no trae esa fila y
      // se sigue descartando.
      var aceptar = nuevas.length >= _medidas.length;
      if (!aceptar && _medidas.isNotEmpty) {
        final ultimaLocal = _medidas.first;
        aceptar = nuevas.any((n) =>
            '${n['medicion_id'] ?? ''}' ==
                '${ultimaLocal['medicion_id'] ?? ''}' &&
            '${n['creado_en'] ?? ''}' ==
                '${ultimaLocal['creado_en'] ?? ''}');
      }
      if (aceptar) {
        setState(() {
          _medidas = nuevas;
          _cargando = false;
        });
      }
    }
  }

  Future<void> _cargar() async {
    // 1.36 H-B2 (136-554): try/catch con EstadoError+reintento.
    try {
      final m = await medicionesClienteLocal(widget.clienteId);
      if (mounted) {
        setState(() {
          _medidas = m;
          _cargando = false;
          _errorCarga = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = true;
        });
      }
    }
  }

  bool get _puedeRegistrar =>
      AuthService().isOwner ||
      PermisosEntrenador().canRecordMeasurements;

  Future<void> _registrar() async {
    if (_registrando) return;
    _registrando = true;
    try {
      await _registrarFlujo();
    } finally {
      _registrando = false;
    }
  }

  Future<void> _registrarFlujo() async {
    // 1.29 (D-B1-08, defecto destapado por su propio test):
    // el diálogo es un StatefulWidget DUEÑO de los
    // controladores (regla de la casa). Antes se creaban
    // aquí y se disponían en cuanto showDialog resolvía —
    // pero la ruta aún se estaba desmontando y sus campos
    // se reconstruían una última vez contra controladores
    // ya dispuestos («used after being disposed») y con un
    // alto absurdo. Ahora el diálogo los dispone en su
    // propio dispose, cuando ya no queda ningún campo.
    final res = await showDialog<_ResultadoMedidaDialogo>(
      context: context,
      builder: (ctx) => const _DialogoRegistrarMedida(),
    );
    if (res == null || !mounted) return;
    final medidas = res.medidas;
    final descartadas = res.descartadas;
    if (medidas.isEmpty && descartadas.isNotEmpty) {
      // Nada parseó: la verdad es que nada se guardó, y el
      // aviso nombra los campos (no el genérico «escribe al
      // menos una medida» de cuando todo venía vacío).
      if (mounted) {
        mostrarSnack(context,
            descartadas.length == 1
                ? '${descartadas.first} no se guardó: revisa el valor.'
                : 'Nada se guardó: revisa ${descartadas.join(', ')}.',
            significado: SignificadoChip.alerta);
      }
      return;
    }
    try {
      await registrarMedicionCliente(
          clienteId: widget.clienteId, medidas: medidas);
      await _cargar();
      if (mounted) {
        if (descartadas.isEmpty) {
          mostrarSnack(context, 'Medida registrada.', significado: SignificadoChip.exito);
        } else {
          mostrarSnack(context,
              descartadas.length == 1
                  ? 'Medida registrada. Ojo: ${descartadas.first} no se guardó: revisa el valor.'
                  : 'Medida registrada. Ojo: no se guardaron ${descartadas.join(', ')}: revisa los valores.',
              significado: SignificadoChip.alerta);
        }
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, e.toString().replaceFirst('Exception: ', ''), significado: SignificadoChip.error);
      }
    }
  }

  /// Métricas con al menos un punto, en el orden canónico
  /// de la lista cerrada (las que la tarjeta puede graficar).
  List<String> get _metricasConDatos {
    final presentes = <String>{};
    for (final m in _medidas) {
      final medidas = m['medidas'];
      if (medidas is Map) {
        for (final k in medidas.keys) {
          presentes.add('$k');
        }
      }
    }
    return [
      for (final k in kMetricasMedicion.keys)
        if (presentes.contains(k)) k,
    ];
  }

  String get _metricaVigente {
    final conDatos = _metricasConDatos;
    final elegida = _metricaGrafico;
    if (elegida != null && conDatos.contains(elegida)) return elegida;
    if (conDatos.contains('peso_kg')) return 'peso_kg';
    return conDatos.isEmpty ? 'peso_kg' : conDatos.first;
  }

  Widget _filaHistorial(Map<String, dynamic> m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(fmtFecha(m['fecha_medicion'] as String?),
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w600)),
            ),
            if (m['espejado'] != true)
              const Text('por sincronizar',
                  style: AppTexto.secundario),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          (m['medidas'] as Map<String, dynamic>).entries.map((e) {
            final spec = kMetricasMedicion[e.key];
            final unidad = spec?.unidad ?? '';
            final v = (e.value as num?)?.toDouble();
            return '${nombreMetrica(e.key)}: '
                '${v == null ? '${e.value}' : _fmtMedida(v)} $unidad';
          }).join(' · '),
          style: AppTexto.cuerpo,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Medidas', style: AppTexto.titulo),
              ),
              if (_puedeRegistrar)
                TextButton.icon(
                  onPressed: _registrar,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Registrar medida'),
                ),
            ],
          ),
          if (_cargando)
            // 1.36 H-B2 (136-558): la carga se anuncia a
            // accesibilidad con su nombre.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
              child: Semantics(
                label: 'Cargando medidas',
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_errorCarga && _medidas.isEmpty)
            EstadoError(
              titulo: 'No se pudieron cargar las medidas',
              onReintentar: () {
                setState(() => _cargando = true);
                _cargar();
              },
            )
          else if (_medidas.isEmpty)
            // Alcance FIJADO en B7 (bloque4_b7_estados):
            // esta tarjeta es una SECCIÓN de la ficha, no
            // una pantalla — su vacío queda como texto de
            // sección, sin migrar a EstadoVacio. (M4-C4 lo
            // respeta; ver el informe de la oleada.)
            const Text('Sin medidas registradas todavía.',
                style: AppTexto.secundario)
          else ...[
            // 1.28 (M4-B3): última medición DESTACADA, con
            // la variación de cada métrica contra la
            // anterior que la trae.
            const SizedBox(height: AppEspacio.sm),
            _ultimaDestacada(),
            // Mini-gráfico de la métrica elegida.
            if (_metricasConDatos.isNotEmpty) ...[
              const SizedBox(height: AppEspacio.md),
              Wrap(
                spacing: AppEspacio.sm,
                runSpacing: AppEspacio.xs,
                children: [
                  for (final k in _metricasConDatos)
                    ChoiceChip(
                      label: Text(nombreMetrica(k)),
                      selected: _metricaVigente == k,
                      onSelected: (_) =>
                          setState(() => _metricaGrafico = k),
                    ),
                ],
              ),
              // 1.36 H-B2 (136-557): el cambio de métrica
              // cruza con fundido en vez de sustituir en seco.
              AnimatedSwitcher(
                duration:
                    AppMovimiento.resuelta(context, AppMovimiento.corta),
                child: GraficoMetricaGestion(
                  key: ValueKey(_metricaVigente),
                  titulo:
                      'Evolución de ${nombreMetrica(_metricaVigente).toLowerCase()}',
                  unidad: kMetricasMedicion[_metricaVigente]?.unidad ??
                      '',
                  puntos: [
                    for (final p in _serieVigente())
                      PuntoSerie(p.fecha, p.valor),
                  ],
                ),
              ),
            ],
            // Historial completo, solo a petición.
            // 136-210: por tramos de 40, no de golpe.
            // 1.36 H-B2 (136-557): el despliegue se anima en
            // altura (AnimatedSize) en vez de aparecer de golpe.
            AnimatedSize(
              duration:
                  AppMovimiento.resuelta(context, AppMovimiento.corta),
              alignment: Alignment.topCenter,
              child: _verTodo
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final m in _medidas.take(_topeVerTodo))
                          _filaHistorial(m),
                        if (_medidas.length > _topeVerTodo)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () =>
                                  setState(() => _topeVerTodo += 40),
                              child: Text(
                                  'Ver más mediciones (${_medidas.length - _topeVerTodo} restantes)'),
                            ),
                          ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _verTodo = !_verTodo),
                icon: Icon(
                    _verTodo
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18),
                label: Text(_verTodo
                    ? 'Ver menos'
                    : 'Ver todo (${_medidas.length} mediciones)'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// La medición más reciente en grande: fecha y cada
  /// métrica con su variación desde la anterior comparable
  /// (▲/▼ y la cifra; sin juicio: subir o bajar no es
  /// bueno ni malo por sí solo).
  Widget _ultimaDestacada() {
    final ultima = _medidas.first;
    final medidas = ultima['medidas'];
    final deltas = _deltasVigentes();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: AppColores.naranja.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadio.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    'Última medición · '
                    '${fmtFecha(ultima['fecha_medicion'] as String?)}',
                    style: AppTexto.subtitulo),
              ),
              if (ultima['espejado'] != true)
                const Text('por sincronizar',
                    style: AppTexto.secundario),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          if (medidas is Map)
            Wrap(
              spacing: AppEspacio.md,
              runSpacing: AppEspacio.xs,
              children: [
                for (final e in medidas.entries)
                  if ((e.value as num?) != null)
                    _chipMedida('${e.key}', (e.value as num).toDouble(),
                        deltas['${e.key}']),
              ],
            ),
        ],
      ),
    );
  }

  Widget _chipMedida(String clave, double valor, double? delta) {
    final unidad = kMetricasMedicion[clave]?.unidad ?? '';
    final textoDelta = delta == null || delta == 0
        ? null
        : '${delta > 0 ? '▲' : '▼'} ${_fmtMedida(delta.abs())}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${nombreMetrica(clave)} ${_fmtMedida(valor)} $unidad',
          style:
              AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w700),
        ),
        if (textoDelta != null) ...[
          const SizedBox(width: 4),
          Text(textoDelta, style: AppTexto.secundario),
        ],
      ],
    );
  }
}

/// Resultado del diálogo de registro de medida: las medidas
/// que parsearon y los NOMBRES de los campos que no (1.29,
/// D-B1-08: el aviso los nombra, no los descarta en silencio).
class _ResultadoMedidaDialogo {
  final Map<String, double> medidas;
  final List<String> descartadas;
  const _ResultadoMedidaDialogo(this.medidas, this.descartadas);
}

/// 1.29 (D-B1-08): el diálogo de «Registrar medida» como
/// StatefulWidget DUEÑO de sus controladores (regla de la
/// casa para diálogos con TextEditingController). Los
/// dispone en su propio dispose — cuando la ruta ya se
/// desmontó entera — en vez de al resolver showDialog,
/// que dejaba los campos reconstruyéndose contra
/// controladores muertos durante la animación de salida.
class _DialogoRegistrarMedida extends StatefulWidget {
  const _DialogoRegistrarMedida();

  @override
  State<_DialogoRegistrarMedida> createState() =>
      _DialogoRegistrarMedidaState();
}

class _DialogoRegistrarMedidaState
    extends State<_DialogoRegistrarMedida> {
  final _ctrls = <String, TextEditingController>{
    for (final k in kMetricasMedicion.keys) k: TextEditingController(),
  };
  // Yunque R4-M6-3: error de rango DENTRO del diálogo (ver
  // _registrar).
  String? _errorRango;
  // 1.36 H-B2 (136-556): error en línea cuando no hay ninguna
  // medida válida: el diálogo NO se cierra.
  String? _errorVacio;

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _registrar() {
    final medidas = <String, double>{};
    // Los campos con texto que NO parsea se NOMBRAN en el
    // resultado (D-B1-08): un «8O» con O de letra en el peso
    // no desaparece sin dejar rastro.
    final descartadas = <String>[];
    for (final e in _ctrls.entries) {
      final txt = e.value.text.trim().replaceAll(',', '.');
      if (txt.isEmpty) continue;
      final v = double.tryParse(txt);
      if (v != null) {
        medidas[e.key] = v;
      } else {
        descartadas.add(nombreMetrica(e.key));
      }
    }
    // 1.36 H-B2 (136-556): sin ninguna medida válida el
    // diálogo se queda abierto con el error en línea (antes
    // se cerraba y el aviso llegaba tarde, fuera de contexto).
    if (medidas.isEmpty) {
      setState(() => _errorVacio = descartadas.isEmpty
          ? 'Escribe al menos una medida.'
          : 'Revisa ${descartadas.join(', ')}: el valor no es un número.');
      return;
    }
    // Yunque R4-M6-3: el rango se valida AQUÍ, con el
    // diálogo abierto y lo tecleado intacto. Antes el
    // diálogo se cerraba primero y validarMedicion
    // rechazaba DESPUÉS: un peso de 500 kg perdía las 7
    // medidas escritas. Los rangos salen de la misma
    // lista cerrada que valida el registro.
    for (final e in medidas.entries) {
      final spec = kMetricasMedicion[e.key];
      if (spec != null &&
          (e.value < spec.min || e.value > spec.max)) {
        setState(() => _errorRango =
            '${nombreMetrica(e.key)} está fuera de rango '
            '(${spec.min}–${spec.max} ${spec.unidad}). '
            'Corrige el valor; lo demás queda como está.');
        return;
      }
    }
    Navigator.pop(
        context, _ResultadoMedidaDialogo(medidas, descartadas));
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Registrar medida',
      iconoTitulo: Icons.straighten_rounded,
      // 1.36 H-B2 (136-555): contenido desplazable (con el
      // teclado abierto las 7 métricas no caben) y etiquetas
      // por nombreMetrica, como los chips de la tarjeta.
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Escribe al menos una medida. Las filas no se editan: '
              'si te equivocas, registra otra fila corregida.',
              style: AppTexto.secundario,
            ),
            const SizedBox(height: 8),
            for (final e in kMetricasMedicion.entries)
              TextField(
                controller: _ctrls[e.key],
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                onChanged: (_) {
                  if (_errorRango != null || _errorVacio != null) {
                    setState(() {
                      _errorRango = null;
                      _errorVacio = null;
                    });
                  }
                },
                decoration: InputDecoration(
                    labelText:
                        '${nombreMetrica(e.key)} (${e.value.unidad})'),
              ),
            if (_errorRango != null || _errorVacio != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorRango ?? _errorVacio!,
                style: AppTexto.metadato.copyWith(
                    color: AppColores.errorTexto(context)),
              ),
            ],
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _registrar,
          child: const Text('Registrar'),
        ),
      ],
    );
  }
}
