/// ✅ Pagaron este mes (v1.6.0, retoque pedido por Jc).
/// El LISTADO exacto detrás de la cifra «Pagaron el mes» de Home y
/// del KPI «Pagos este mes» del panel: los clientes que forman la
/// base del mes vigente. La fuente es [NominaCalc.idsQuePagaronElMes]
/// — el MISMO conjunto (misma función) que produce la cifra, así que
/// la lista y el número nunca pueden discrepar: deduplica por
/// cliente sobre el espejo `pagos` y aplica la excepción del mes en
/// curso (quien vence dentro del propio mes no entra en su base).
/// Sin filtro por entrenador a propósito: la cifra de Home es global
/// y esta lista la refleja tal cual.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../perfil.dart';
import '../sync.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';
import '../app_log.dart';

class PagaronMesScreen extends StatefulWidget {
  const PagaronMesScreen({super.key});

  @override
  State<PagaronMesScreen> createState() => _PagaronMesScreenState();
}

class _PagaronMesScreenState extends State<PagaronMesScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _filas = [];
  // 1.25 T118 (F2-17): buscador de la lista y tarifa vigente
  // para la cabecera de base de nómina (solo dueño).
  final _qCtrl = TextEditingController();
  String _q = '';
  int? _tarifa;

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _visibles {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _filas;
    return _filas
        .where((c) => '${c['nombre']}'.toLowerCase().contains(q))
        .toList();
  }

  /// 1.23 (H-04, Argón): total canónico de la cifra de Home
  /// (ids ANTES de ocultar protegidos a un no-dueño). El título
  /// usa ESTE número — el mismo que ve en Home y en su nómina —
  /// y al pie de la lista se explica la diferencia, para que
  /// el entrenador no sospeche de su base ni deduzca cuántos
  /// protegidos hay contando filas.
  int _totalCanonico = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// El ⟳ sincroniza el alcance de pagos y luego relee la lista local.
  Future<void> _actualizar() async {
    try {
      // 1.23.1 (bug de campo 2026-11-04): se usa el resultado
      // detallado: si el ciclo NO corrió (otra sincronización en
      // curso o sin sesión) o corrió con error, no se anuncia
      // «Lista actualizada» — mismo engaño que en Buscar.
      final r = await SyncEngine.instance.sincronizarScopeDetallado('pagos');
      await _cargar();
      if (!mounted) return;
      if (!r.corrio) {
        mostrarSnack(
            context,
            r.motivo == SyncMotivoNoCorrio.sinSesion
                ? 'Sin sesión activa para sincronizar'
                : 'Ya hay una sincronización en curso',
            significado: SignificadoChip.alerta);
        return;
      }
      if (r.error) {
        mostrarSnack(context, 'Sin conexión: mostrando datos locales',
            significado: SignificadoChip.alerta);
        return;
      }
      mostrarSnack(context, 'Lista actualizada', significado: SignificadoChip.exito);
    } catch (_) {
      await _cargar();
      if (!mounted) return;
      mostrarSnack(context, 'Sin conexión: mostrando datos locales', significado: SignificadoChip.alerta);
    }
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
    // La lista sale del conjunto de NominaCalc (la cifra), no de una
    // consulta paralela: ids primero y datos del espejo después.
    final ids = await NominaCalc.idsQuePagaronElMes(
        NominaCalc.prefMesActual());
    final datos =
        await LocalDb.instance.mirrorPorIds('clientes', ids);
    final porId = <int, Map<String, dynamic>>{
      for (final c in datos) (c['id'] as num).toInt(): c,
    };
    // Cliente protegido (H3, mismo criterio que Pagos Realizados):
    // para un no-dueño la fila se omite entera — la presencia ya
    // revela que pagó este mes. Sin fila en el espejo no se puede
    // saber si es protegido y el marcador se conserva. El conteo
    // visible puede quedar por debajo de la cifra global de Home
    // en tantos protegidos como haya.
    final idsVisibles = ids.where((id) {
      final c = porId[id];
      return c == null || !esVistaProtegida(c);
    }).toList();
    final lista = <Map<String, dynamic>>[
      for (final id in idsVisibles)
        if (porId[id] != null)
          {
            'id': id,
            'nombre': '${porId[id]!['nombre'] ?? 'Cliente $id'}',
            'pagado_hasta': porId[id]!['pagado_hasta'],
            'foto_local': porId[id]!['foto_local'],
            'foto_storage': porId[id]!['foto_storage'],
            'sin_datos': false,
          }
        else
          {
            // La regla de NominaCalc CONSERVA en la base al cliente
            // sin fila en el espejo (sync incompleta): la lista lo
            // muestra como marcador para que las filas y la cifra
            // coincidan, sin navegar a una ficha vacía.
            'id': id,
            'nombre': 'Cliente $id',
            'pagado_hasta': null,
            'foto_local': null,
            'foto_storage': null,
            'sin_datos': true,
          },
    ];
    lista.sort(compararPorNombre);
    // F2-17: la tarifa para la cabecera de base (la misma
    // fuente que la foto de nómina); si no se puede leer, la
    // cabecera simplemente no se pinta.
    int? tarifa;
    if (AuthService().isOwner) {
      try {
        tarifa = await PerfilService.instance.getPagoEntrenador();
      } catch (_) {
        tarifa = null;
      }
    }
    if (mounted) {
      setState(() {
        _filas = lista;
        _totalCanonico = ids.length;
        _tarifa = tarifa;
        _cargando = false;
      });
    }
  }

  /// 1.25 T118 (F2-17): chip de vencimiento cercano de una
  /// fila («Vence hoy», «Vence en N días», «Venció hace N
  /// días»); sin chip si faltan más de 7 días o no hay fecha.
  Widget _chipVencePronto(String? pagadoHasta) {
    final d = diasRestantes(pagadoHasta);
    if (d == null || d > 7) return const SizedBox.shrink();
    final (texto, color) = d < 0
        ? ('Venció hace ${-d} día${d == -1 ? '' : 's'}', AppColores.error)
        : d == 0
            ? ('Vence hoy', AppColores.error)
            : (
                'Vence en $d día${d == 1 ? '' : 's'}',
                AppColores.alertaOscuro
              );
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.sm, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadio.sm),
        ),
        child: Text(
          texto,
          style: AppTexto.minuscula
              .copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // B1 (Jc, 2026-10-24, para la nómina de octubre): la lista ya NO
    // es solo del dueño. El entrenador la ve para verificar su base
    // (cada cliente que pagó = 150 CUP), en SOLO LECTURA: sin dueño
    // no hay chevron ni navegación a la ficha desde aquí (la ficha
    // sigue alcanzable por sus rutas habituales, sin cambio).
    // La lista en sí no tiene ninguna acción de edición.
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: appBarIron(
        context,
        _cargando ? 'Pagaron este mes' : 'Pagaron este mes ($_totalCanonico)',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar (bajar cambios)',
            onPressed: _actualizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(alcance: 'pagos'),
          // 1.25 T118 (F2-17): buscador y, para el dueño, la
          // base de nómina que esta lista forma (antes la
          // cifra vivía solo en el título y la base de
          // 150 CUP por cliente no se decía en la pantalla).
          if (!_cargando && _filas.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: TextField(
                controller: _qCtrl,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'Buscar cliente…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Limpiar búsqueda',
                          onPressed: () {
                            _qCtrl.clear();
                            setState(() => _q = '');
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (esDueno && _tarifa != null && _q.trim().isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                    AppEspacio.sm, AppEspacio.lg, 0),
                child: Text(
                  'Base de nómina por entrenador: '
                  '$_totalCanonico × ${fmtMonto(_tarifa!.toDouble())} CUP = '
                  '${fmtMonto(_totalCanonico * _tarifa!.toDouble())} CUP',
                  style: AppTexto.secundario,
                ),
              ),
          ],
          Expanded(
            child: _cargando
                ? const EstadoCargando(texto: 'Cargando pagos del mes…')
                : _filas.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.payments_rounded,
                        titulo: 'Nadie ha pagado este mes',
                        subtitulo:
                            'Los clientes que paguen aparecerán aquí')
                    : _visibles.isEmpty
                        ? EstadoVacio(
                            icono: Icons.search_off_rounded,
                            titulo: 'Sin resultados',
                            subtitulo:
                                'Nadie de la lista coincide con «${_q.trim()}»')
                        : RefrescoIron(
                        onRefresh: _actualizar,
                        child: ListView.builder(
                          // H-04: si hay protegidos ocultos, la
                          // última fila es la nota que reconcilia
                          // el título (canónico) con las filas
                          // (solo sin búsqueda activa).
                          itemCount: _visibles.length +
                              (_q.trim().isEmpty &&
                                      _totalCanonico > _filas.length
                                  ? 1
                                  : 0),
                          itemBuilder: (ctx, i) {
                            if (i == _visibles.length) {
                              return Padding(
                                padding: const EdgeInsets.all(
                                    AppEspacio.lg),
                                child: Text(
                                  '+ ${_totalCanonico - _filas.length} '
                                  'con privacidad reservada, '
                                  'incluidos en tu base de nómina.',
                                  style: AppTexto.secundario,
                                  textAlign: TextAlign.center,
                                ),
                              );
                            }
                            final c = _visibles[i];
                            final sinDatos = c['sin_datos'] == true;
                            return ListTile(
                              leading: sinDatos
                                  ? const CircleAvatar(
                                      child: Icon(Icons.person_outline_rounded),
                                    )
                                  : ClienteAvatarThumb(
                                      fotoLocal:
                                          c['foto_local'] as String?,
                                      fotoStorage:
                                          c['foto_storage'] as String?,
                                    ),
                              title: Text('${c['nombre']}'),
                              subtitle: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    sinDatos
                                        ? 'Datos aún sin descargar'
                                        : 'Pagado hasta: '
                                            '${fmtFecha(c['pagado_hasta'] as String?)}',
                                    style: AppTexto.metadato,
                                  ),
                                  // F2-17: aviso de vencimiento
                                  // cercano — la lista ya trae
                                  // pagado_hasta y no se usaba
                                  // para priorizar.
                                  if (!sinDatos)
                                    _chipVencePronto(
                                        c['pagado_hasta'] as String?),
                                ],
                              ),
                              trailing: sinDatos || !esDueno
                                  ? null
                                  : const Icon(Icons.chevron_right_rounded),
                              onTap: sinDatos || !esDueno
                                  ? null
                                  : () => Navigator.of(context)
                                      .push(RutaIron(
                                        builder: (_) => FichaScreen(
                                            clienteId: c['id'] as int),
                                      )).then((_) => _cargar()),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Avatar con miniatura de foto (15/25: mudado desde la pantalla
/// eliminada PagosRealizadosScreen, su único uso que quedaba).
/// v1.2.8 (Paso 4/E2): StatefulWidget dedicado en vez de
/// FutureBuilder directo en el itemBuilder (evita recrear futures
/// en cada scroll).
class ClienteAvatarThumb extends StatefulWidget {
  final String? fotoStorage;
  final String? fotoLocal;
  const ClienteAvatarThumb({super.key, this.fotoStorage, this.fotoLocal});

  @override
  State<ClienteAvatarThumb> createState() => _ClienteAvatarThumbState();
}

class _ClienteAvatarThumbState extends State<ClienteAvatarThumb> {
  File? _archivo;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void didUpdateWidget(ClienteAvatarThumb old) {
    super.didUpdateWidget(old);
    if (old.fotoStorage != widget.fotoStorage ||
        old.fotoLocal != widget.fotoLocal) {
      // Corrección Gemini ronda 2: resetear antes de cargar para no
      // mostrar la foto del cliente anterior durante el I/O.
      setState(() => _archivo = null);
      _cargar();
    }
  }

  Future<void> _cargar() async {
    File? f;
    if (widget.fotoLocal != null && widget.fotoLocal!.isNotEmpty) {
      final lf = File(widget.fotoLocal!);
      if (await lf.exists()) f = lf;
    }
    f ??= await FotoCache.instance.enCache(widget.fotoStorage);
    if (mounted) setState(() => _archivo = f);
  }

  @override
  Widget build(BuildContext context) {
    if (_archivo != null) {
      // 1.34 Campo 2 (P-1): avatar de 40 dp — la foto se
      // decodifica acotada (providerFotoAcotada), no entera.
      return CircleAvatar(
        backgroundImage: providerFotoAcotada(FileImage(_archivo!),
            ancho: (80 * MediaQuery.devicePixelRatioOf(context)).round()),
        backgroundColor: Colors.transparent,
      );
    }
    return const Icon(Icons.verified_rounded, color: AppColores.exito);
  }
}
