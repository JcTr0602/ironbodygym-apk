/// Listas del Panel (Bloque 2 NÚCLEO, 1.10.0).
///
/// - B5: cuentas a la Casa.
/// - E5: productos sin foto o sin precio, señalados.
/// - D3: vencimientos próximos (7 días) + ya vencidos, con acción
///   (tocar abre la ficha, desde donde se cobra).
/// - B2: permisos explicados en sencillo (diálogo de referencia con
///   las 14 claves y qué permite cada una, en palabras claras).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../congelaciones_gestion.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'suplementos.dart';
import '../app_log.dart';

/// B2: las 14 claves de permiso, explicadas en sencillo.
const kPermisosExplicados = {
  'can_generate_pin':
      'Generar PIN: puede crear el PIN de acceso a la app para un cliente.',
  'can_edit_nutrition':
      'Editar nutrición: puede crear y cambiar planes nutricionales.',
  'can_record_measurements':
      'Registrar medidas: puede anotar peso y medidas de clientes.',
  'can_view_progress':
      'Ver progreso: puede ver el progreso y las medidas de clientes.',
  'can_view_payroll':
      'Ver nómina: puede ver su resumen de nómina y adelantos.',
  'can_cobrar_pagos': 'Cobrar pagos: puede cobrar mensualidades y diarios.',
  'can_inscribir_clientes':
      'Inscribir clientes: puede dar de alta clientes nuevos.',
  'can_editar_fichas':
      'Editar fichas: puede cambiar datos básicos (nombre, teléfono). '
      'Nunca datos sensibles: esos son solo del dueño.',
  'can_vender_suplementos':
      'Vender suplementos: puede vender del catálogo y registrar ventas.',
  'can_registrar_gastos': 'Registrar gastos: puede anotar gastos del día.',
  'can_gestionar_turnos':
      'Gestionar turnos: puede abrir y cerrar turnos del gym.',
  'can_ver_todos_pagos':
      'Ver todos los pagos: puede ver los pagos del mes de todos.',
  'can_ver_cifras': 'Ver cifras: puede ver montos y resúmenes de caja.',
  'can_ver_ranking_servicios':
      'Ver ranking de servicios: puede ver quién vende más dosis.',
};

Future<void> mostrarPermisosExplicados(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => DialogoApp(
      titulo: 'Permisos, en sencillo',
      iconoTitulo: Icons.security_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in kPermisosExplicados.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppEspacio.sm),
                child: Text('• ${e.value}', style: AppTexto.cuerpo),
              ),
            const Text(
              // 1.29 (Oleada 6, D-B3-07): el texto decía que
              // sin permiso la acción «no se ve», pero la
              // regla vigente desde la 1.24 es la contraria:
              // el botón se VE siempre; lo que falta sin
              // permiso es que ocurra algo al tocarlo.
              'El dueño siempre tiene todo. Un entrenador sin un '
              'permiso ve el botón igual que todos: al tocarlo, '
              'la app le avisa de que no tiene permiso y la '
              'acción no ocurre.',
              style: AppTexto.secundario,
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar')),
      ],
    ),
  );
}

/// B5: cuentas a la Casa (lista desde el espejo local).
class CuentasCasaScreen extends StatefulWidget {
  const CuentasCasaScreen({super.key});
  @override
  State<CuentasCasaScreen> createState() => _CuentasCasaScreenState();
}

class _CuentasCasaScreenState extends State<CuentasCasaScreen> {
  var _cargando = true;
  // (136-802) triestado de carga.
  String? _errorCarga;
  var _sinAcceso = false;
  List<Map<String, dynamic>> _casas = [];

  @override
  void initState() {
    super.initState();
    _cargar();
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
      if (mounted) setState(() => _errorCarga = '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    // 1.23 AT-02 (auditoría total de Argón): la Casa la otorga
    // y la quita SOLO el dueño, pero esta lista no tenía
    // guarda: un entrenador que alcanzara la ruta veía la
    // lista completa de cuentas a la Casa. Guarda en la carga
    // + pantalla de bloqueo + filtro de protegidos (la lista
    // tampoco debe mostrar clientes protegidos a un no-dueño
    // si algún día la guarda cambia).
    if (!AuthService().isOwner) {
      if (!mounted) return;
      setState(() {
        _sinAcceso = true;
        _cargando = false;
      });
      return;
    }
    final todos = await LocalDb.instance.allMirror('clientes');
    final casas = todos
        .where((c) => c['cuenta_casa'] == 1 || c['cuenta_casa'] == true)
        .where((c) => !esVistaProtegida(c))
        .toList();
    if (!mounted) return;
    setState(() {
      _casas = casas;
      _errorCarga = null;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_sinAcceso) {
      return Scaffold(
        appBar: appBarIron(context, 'Cuentas a la Casa'),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppEspacio.xl),
            child: Text(
              'Solo el dueño puede ver las cuentas a la Casa.',
              style: AppTexto.secundario,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Cuentas a la Casa'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando…')
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudo cargar',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
          : _casas.isEmpty
              ? const Center(
                  child: Text('Ninguna cuenta a la Casa.',
                      style: AppTexto.secundario))
              : ListView(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    const Text(
                      'Precio 0, nunca vencen, fuera de ingresos, caja '
                      'y nómina. Solo el dueño otorga o quita la Casa '
                      'desde la ficha.',
                      style: AppTexto.secundario,
                    ),
                    const SizedBox(height: 12),
                    for (final c in _casas)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.home_rounded,
                              color: AppColores.casaIcono),
                          title: Text('${c['nombre'] ?? ''}'),
                          subtitle: Text('${c['telefono'] ?? ''}'),
                          onTap: () => Navigator.push(
                              context,
                              RutaIron(
                                  builder: (_) => FichaScreen(
                                      clienteId:
                                          (c['id'] as num).toInt()))),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// E5: productos sin foto o sin precio, señalados.
class SinFotoPrecioScreen extends StatefulWidget {
  const SinFotoPrecioScreen({super.key});
  @override
  State<SinFotoPrecioScreen> createState() => _SinFotoPrecioScreenState();
}

class _SinFotoPrecioScreenState extends State<SinFotoPrecioScreen> {
  var _cargando = true;
  // (136-802) triestado de carga.
  String? _errorCarga;
  List<Map<String, dynamic>> _mal = [];

  @override
  void initState() {
    super.initState();
    _cargar();
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
      if (mounted) setState(() => _errorCarga = '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final todos = await LocalDb.instance.allMirror('suplementos');
    final mal = todos.where((s) {
      // P2#7: fuera eliminados e inactivos (activo != 1).
      final eliminado = s['eliminado'];
      if (eliminado == 1 || eliminado == true) return false;
      final act = s['activo'];
      if (act == 0 || act == false) return false;
      // P2#7: las claves vivas son foto_storage/foto_local y
      // precio_oficial (foto_url/precio son claves viejas).
      final fotoLocal = '${s['foto_local'] ?? ''}';
      final fotoStorage = '${s['foto_storage'] ?? ''}';
      final precio = (s['precio_oficial'] as num?)?.toDouble();
      return (fotoLocal.isEmpty && fotoStorage.isEmpty) ||
          precio == null ||
          precio <= 0;
    }).toList();
    if (!mounted) return;
    setState(() {
      _mal = mal;
      _errorCarga = null;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Productos sin foto o sin precio'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando…')
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudo cargar',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
          : _mal.isEmpty
              ? const Center(
                  child: Text(
                      'Todos los productos tienen foto y precio.',
                      style: AppTexto.secundario))
              : ListView(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    for (final s in _mal)
                      Card(
                        child: ListTile(
                          // 1.23 (Delta Argón 6ª): naranja de la
                          // casa en vez de Colors.orange.
                          leading: const Icon(Icons.warning_amber_rounded,
                              color: AppColores.naranja),
                          title: Text('${s['nombre'] ?? 'Producto'}'),
                          subtitle: Text(_motivo(s)),
                          // P2#7: tocar abre la edición del producto.
                          onTap: () => Navigator.push(
                              context,
                              RutaIron(
                                  builder: (_) =>
                                      EditarSuplementoScreen(
                                          suplemento: s))).then(
                              (_) => _cargar()),
                        ),
                      ),
                  ],
                ),
    );
  }

  String _motivo(Map<String, dynamic> s) {
    final fotoLocal = '${s['foto_local'] ?? ''}';
    final fotoStorage = '${s['foto_storage'] ?? ''}';
    final foto =
        fotoLocal.isNotEmpty ? fotoLocal : fotoStorage;
    final precio = (s['precio_oficial'] as num?)?.toDouble();
    final motivos = <String>[];
    if (foto.isEmpty) motivos.add('sin foto');
    if (precio == null || precio <= 0) motivos.add('sin precio');
    return motivos.join(' · ');
  }
}

/// D3: vencimientos próximos (7 días) + ya vencidos, con acción.
/// Tocar abre la ficha (desde donde se cobra con preview).
class VencimientosProximosScreen extends StatefulWidget {
  const VencimientosProximosScreen({super.key});
  @override
  State<VencimientosProximosScreen> createState() =>
      _VencimientosProximosScreenState();
}

class _VencimientosProximosScreenState
    extends State<VencimientosProximosScreen> {
  var _cargando = true;
  String? _errorCarga;
  List<Map<String, dynamic>> _vencidos = [];
  List<Map<String, dynamic>> _proximos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
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
      if (mounted) setState(() => _errorCarga = '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final hoy = hoyHabanaIso();
    // 1.24 B2: límite por aritmética de fecha pura (sumarDiasIso).
    final limite = sumarDiasIso(hoy, 7);
    final todos = await LocalDb.instance.allMirror('clientes');
    // Congelación 0.5 (M2): con la pausa aprobada EN CURSO el
    // cliente no está vencido ni por vencer: su fecha se
    // mueve al terminar. Solo excluye en el teléfono del
    // dueño (su espejo trae las filas; el del entrenador no).
    final congelados = await CongelacionesService.instance
        .idsCongeladosEnCurso(ahoraHabana());
    final vencidos = <Map<String, dynamic>>[];
    final proximos = <Map<String, dynamic>>[];
    for (final c in todos) {
      if (c['cuenta_casa'] == 1 || c['cuenta_casa'] == true) continue;
      if (congelados.contains((c['id'] as num?)?.toInt() ?? 0)) {
        continue;
      }
      // P2#5: solo activos (esto ya excluye congelado, inactivo y
      // la cáscara 'eliminado'), y nunca protegidos para no-dueño.
      if ((c['estado'] as String?) != 'activo') continue;
      if (esVistaProtegida(c)) continue;
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.length < 10) continue;
      final f = ph.substring(0, 10);
      if (f.compareTo(hoy) < 0) {
        vencidos.add(c);
      } else if (f.compareTo(limite) <= 0) {
        proximos.add(c);
      }
    }
    vencidos.sort((a, b) =>
        '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
    proximos.sort((a, b) =>
        '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
    if (!mounted) return;
    setState(() {
      _vencidos = vencidos;
      _proximos = proximos;
      _errorCarga = null;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Vencimientos próximos'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando…')
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudo cargar',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // 1.25 T121 (F5-27): antes se pintaban AMBOS
                // encabezados aunque una lista estuviera vacía
                // («Ya vencidos / Nadie vencido.» ocupando
                // media pantalla). Ahora: resumen con conteos
                // arriba y cada sección solo si tiene filas;
                // si no hay nadie en ninguna, un solo vacío.
                Text(
                  '${_vencidos.length} vencido(s) · '
                  '${_proximos.length} por vencer en 7 días',
                  style: AppTexto.secundario,
                ),
                if (_vencidos.isEmpty && _proximos.isEmpty) ...[
                  const SizedBox(height: 24),
                  const EstadoVacio(
                    icono: Icons.check_circle_rounded,
                    titulo: 'Nadie vencido ni por vencer',
                    subtitulo: 'Ningún cliente está vencido ni vence '
                        'en los próximos 7 días.',
                  ),
                ],
                if (_vencidos.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Ya vencidos (${_vencidos.length})',
                      style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  for (final c in _vencidos) _filaCliente(c, true),
                ],
                if (_proximos.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Próximos 7 días (${_proximos.length})',
                      style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  for (final c in _proximos) _filaCliente(c, false),
                ],
              ],
            ),
    );
  }

  Widget _filaCliente(Map<String, dynamic> c, bool vencido) => Card(
        child: ListTile(
          leading: Icon(
              vencido ? Icons.warning_amber_rounded : Icons.event_rounded,
              color: vencido ? Colors.red : AppColores.naranja),
          title: Text('${c['nombre'] ?? ''}'),
          subtitle: Text(
              'Vence: ${fmtFecha('${c['pagado_hasta']}'.substring(0, 10))}'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.push(
              context,
              RutaIron(
                  builder: (_) =>
                      FichaScreen(clienteId: (c['id'] as num).toInt()))),
        ),
      );
}
