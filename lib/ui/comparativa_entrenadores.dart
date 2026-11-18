/// F7 (1.20): comparativa de entrenadores del mes, lado a
/// lado — quién cobró más, vendió más o dio más dosis.
/// Solo dueño. Los datos salen de
/// [comparativaEntrenadores] (espejos locales, sin red) y
/// tocar el nombre de un entrenador abre su detalle.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'avatar_entrenador.dart';
import 'componentes.dart';
import 'detalle_entrenador.dart';
import 'diseno.dart';
import '../app_log.dart';

class ComparativaEntrenadoresScreen extends StatefulWidget {
  const ComparativaEntrenadoresScreen({super.key});

  @override
  State<ComparativaEntrenadoresScreen> createState() =>
      _ComparativaEntrenadoresScreenState();
}

class _ComparativaEntrenadoresScreenState
    extends State<ComparativaEntrenadoresScreen> {
  static const _meses = [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
    'Diciembre',
  ];

  late DateTime _mes;
  bool _cargando = true;
  // Hy4 G#37: generación de carga — al mover el mes dos
  // veces seguidas, la carga del mes intermedio podía
  // terminar última y dejar sus filas bajo el título del
  // mes nuevo.
  int _genCarga = 0;
  List<Map<String, dynamic>> _filas = [];
  // 1.36 H-B3 (136-734): el fallo de carga se VE y se puede
  // reintentar (antes quedaban las filas del mes anterior o
  // un falso «Sin comparativa»).
  bool _errorCarga = false;
  // 1.36 H-B3 (136-738): perfiles elegidos para la tabla
  // (índices en _filas; vacío = los 3 con más actividad).
  final Set<int> _elegidos = {};

  @override
  void initState() {
    super.initState();
    final n = ahoraHabana();
    _mes = DateTime(n.year, n.month);
    _cargar();
  }

  String get _prefijo =>
      '${_mes.year.toString().padLeft(4, '0')}-'
      '${_mes.month.toString().padLeft(2, '0')}';

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
      // 1.36 H-B3 (136-734): la recarga fallida LIMPIA las
      // filas (no quedan las del período anterior bajo el
      // mes nuevo) y pinta EstadoError con reintento.
      if (mounted) {
        setState(() {
          _filas = [];
          _errorCarga = true;
        });
      }
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final gen = ++_genCarga;
    setState(() {
      _cargando = true;
      _errorCarga = false;
    });
    final filas = await comparativaEntrenadores(_prefijo);
    if (!mounted || gen != _genCarga) return;
    setState(() {
      _filas = filas;
      _elegidos.clear();
      _cargando = false;
    });
  }

  void _moverMes(int delta) {
    setState(() => _mes = DateTime(_mes.year, _mes.month + delta));
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      // FIN-07 de Argón (1.20): mismo patrón visual que
      // conciliación y diferencias para el bloqueo de rol.
      return Scaffold(
        appBar:
            appBarIron(context, 'Comparativa de entrenadores'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo: 'La comparativa es solo del dueño.',
        ),
      );
    }
    final n = ahoraHabana();
    final esMesActual = _mes.year == n.year && _mes.month == n.month;
    return Scaffold(
      appBar: appBarIron(context, 'Comparativa de entrenadores'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Mes anterior',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () => _moverMes(-1),
              ),
              Expanded(
                child: Text(
                  '${_meses[_mes.month - 1]} ${_mes.year}',
                  textAlign: TextAlign.center,
                  style: AppTexto.titulo,
                ),
              ),
              IconButton(
                tooltip: 'Mes siguiente',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: esMesActual ? null : () => _moverMes(1),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          if (_cargando)
            const EstadoCargando()
          else if (_errorCarga)
            EstadoError(
              titulo: 'No se pudo cargar la comparativa',
              detalle: 'Revisa la conexión o vuelve a intentarlo.',
              onReintentar: _cargar,
            )
          else if (_filas.length < 2)
            const EstadoVacio(
              icono: Icons.group_rounded,
              titulo: 'Sin comparativa este mes',
              subtitulo: 'Hacen falta al menos dos entrenadores '
                  'con actividad registrada en el mes.',
            )
          else
            _tabla(),
          const SizedBox(height: AppEspacio.md),
          const Text(
            'La Casa cuenta como dosis dadas, no como dinero. '
            'Las ventas anuladas no cuentan y los reversos '
            'restan.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  Widget _tabla() {
    // 1.36 H-B3 (136-738): las columnas son las ELEGIDAS
    // (hasta 3); sin elección mandan los 3 con más actividad.
    final cols = _elegidos.isEmpty
        ? _filas.take(3).toList()
        : [
            for (final i in _elegidos.toList()..sort())
              if (i >= 0 && i < _filas.length) _filas[i],
          ];
    final hayUsd =
        cols.any((f) => ((f['ventas_usd'] as num?) ?? 0) > 0);
    return Tarjeta(
      child: Column(
        children: [
          // FIN-07 de Argón (1.20): la tabla muestra hasta 3
          // columnas (ordenadas por total); si hay más perfiles
          // con actividad, se avisa en vez de ocultarlos.
          // 1.36 H-B3 (136-738): y se pueden ELEGIR con los
          // chips (antes el resto de perfiles no tenía forma
          // de verse).
          if (_filas.length > 3) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.sm),
              child: Text(
                'Elige hasta 3 perfiles de ${_filas.length} '
                'con actividad (sin elegir: los 3 con más).',
                style: AppTexto.metadato,
              ),
            ),
            Wrap(
              spacing: AppEspacio.xs,
              runSpacing: AppEspacio.xs,
              children: [
                for (var i = 0; i < _filas.length; i++)
                  FilterChip(
                    label: Text('${_filas[i]['nombre']}'),
                    selected: _elegidos.isEmpty
                        ? i < 3
                        : _elegidos.contains(i),
                    onSelected: (sel) {
                      setState(() {
                        if (_elegidos.isEmpty) {
                          _elegidos.addAll([0, 1, 2]);
                        }
                        if (sel) {
                          if (_elegidos.length >= 3) {
                            _elegidos.remove(_elegidos.first);
                          }
                          _elegidos.add(i);
                        } else {
                          _elegidos.remove(i);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
          ],
          // Cabecera: nombre de cada entrenador (tocable →
          // su detalle).
          Row(
            children: [
              const Expanded(flex: 3, child: SizedBox()),
              for (final f in cols)
                Expanded(
                  flex: 2,
                  child: InkWell(
                    // 1.36 H-B3 (136-738): la cabecera ES un
                    // botón y lo anuncia (antes nombre/avatar
                    // eran tocables sin affordance).
                    customBorder: const StadiumBorder(),
                    onTap: () => Navigator.push(
                      context,
                      RutaIron(
                        builder: (_) => DetalleEntrenadorScreen(
                            nombre: '${f['nombre']}',
                            telegramId:
                                (f['telegram_id'] as num?)
                                    ?.toInt()),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppEspacio.sm),
                      // 1.25 T83: cara antes que nombre —
                      // el avatar del entrenador abre su
                      // columna.
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.end,
                        children: [
                          AvatarEntrenador(
                              nombre: '${f['nombre']}',
                              tamano: 30),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  '${f['nombre']}',
                                  textAlign: TextAlign.right,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTexto.subtitulo.copyWith(
                                      color: AppColores
                                          .textoNaranja(context)),
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded,
                                  size: 16,
                                  color: AppColores.textoNaranja(
                                      context)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          _filaMetrica('Cobros', cols,
              (f) => '${f['cobros_n']} pagos'),
          _filaMetrica('Cobrado', cols,
              (f) => '${fmtMonto(f['cobros_monto'])} CUP',
              clave: 'cobros_monto'),
          _filaMetrica('Ventas', cols,
              (f) => '${f['ventas_n']} ventas'),
          _filaMetrica('Vendido (CUP)', cols,
              (f) => '${fmtMonto(f['ventas_cup'])} CUP',
              clave: 'ventas_cup'),
          if (hayUsd)
            _filaMetrica('Vendido (USD)', cols,
                (f) => '${fmtMonto(f['ventas_usd'])} USD',
                clave: 'ventas_usd'),
          _filaMetrica('Dosis y servicios', cols,
              (f) => '${f['dosis_n']}'),
          _filaMetrica('En dosis', cols,
              (f) => '${fmtMonto(f['dosis_monto'])} CUP',
              clave: 'dosis_monto'),
          _filaMetrica('Inscripciones', cols,
              (f) => '${f['inscripciones']}'),
          const Divider(height: 1),
          _filaMetrica('Total movido', cols,
              (f) => '${fmtMonto(f['total_cup'])} CUP',
              clave: 'total_cup', destacada: true),
        ],
      ),
    );
  }

  /// Una fila de la tabla: etiqueta a la izquierda y un
  /// valor por entrenador; el mayor de la fila (con clave
  /// numérica) va en negrita.
  Widget _filaMetrica(
    String etiqueta,
    List<Map<String, dynamic>> cols,
    String Function(Map<String, dynamic>) texto, {
    String? clave,
    bool destacada = false,
  }) {
    num? mayor;
    if (clave != null) {
      for (final f in cols) {
        final v = (f[clave] as num?) ?? 0;
        if (mayor == null || v > mayor) mayor = v;
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(etiqueta,
                style: destacada
                    ? AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.bold)
                    : AppTexto.cuerpo),
          ),
          for (final f in cols)
            Expanded(
              flex: 2,
              child: Text(
                texto(f),
                textAlign: TextAlign.right,
                // 1.36 H-B3 (136-737): valor acotado con
                // ellipsis en columnas estrechas (las cifras
                // ya van tabulares).
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTexto.cuerpo.copyWith(
                  fontWeight: (clave != null &&
                          mayor != null &&
                          mayor > 0 &&
                          ((f[clave] as num?) ?? 0) == mayor)
                      ? FontWeight.bold
                      : destacada
                          ? FontWeight.bold
                          : FontWeight.normal,
                  fontFeatures: const [
                    FontFeature.tabularFigures()
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
