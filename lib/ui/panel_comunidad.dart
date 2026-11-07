import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import '../comunidad_panel.dart';
import 'app_bar.dart';

/// 1.27 (Comunidad MVP, Pieza G): «Comunidad» del
/// Panel — los perfiles que los clientes han hecho
/// visibles y el botón de ocultarlos.
///
/// El cliente manda sobre sus datos: esta pantalla NO
/// puede encender la vitrina de nadie ni ver lo que el
/// cliente apagó (eso ni siquiera sale del servidor);
/// solo puede OCULTAR un perfil del directorio (p. ej.
/// un nombre inadecuado) y deshacer esa ocultación.
/// La RPC admin_comunidad_ocultar valida es_admin en
/// el servidor (la tarjeta solo vive en el Panel del
/// dueño, como la de Premios, cuya compuerta visual
/// está en el hub). Cargadores inyectables para los
/// tests.
class ComunidadPanelScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? cargarPerfiles;
  final Future<Map<String, dynamic>> Function(
      int clienteId, bool ocultar)? ocultarPerfil;

  const ComunidadPanelScreen(
      {super.key, this.cargarPerfiles, this.ocultarPerfil});

  @override
  State<ComunidadPanelScreen> createState() =>
      _ComunidadPanelScreenState();
}

class _ComunidadPanelScreenState extends State<ComunidadPanelScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  bool _resolviendo = false;
  List<PerfilComunidadAdmin> _perfiles = const [];

  // 1.28 (M5-B4): el buscador de la lista (con dispose,
  // regla de la casa para controladores en diálogos y
  // pantallas).
  final _busquedaCtrl = TextEditingController();
  String _consulta = '';

  @override
  void initState() {
    super.initState();
    // Sin sesión de dueño ni siquiera se dispara la
    // RPC de administración (ver la guarda en build).
    if (AuthService().isOwner) _cargar();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _cargarReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_comunidad_perfiles')
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    // 1.28 (M5-A2 ★): una respuesta que no es un mapa es
    // un FALLO, no «todavía nadie tiene vitrina» (antes
    // devolvía {} y el parse degradaba a lista vacía con
    // _falloCarga en false: lo cargado mentía).
    throw StateError(
        'admin_comunidad_perfiles: respuesta no es un mapa');
  }

  Future<Map<String, dynamic>> _ocultarReal(
      int clienteId, bool ocultar) async {
    final res = await Supabase.instance.client.rpc(
      'admin_comunidad_ocultar',
      params: {'p_cliente_id': clienteId, 'p_ocultar': ocultar},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final json = await (widget.cargarPerfiles ?? _cargarReal)();
      if (!mounted) return;
      setState(() {
        _perfiles = parsePerfilesComunidad(json);
        _cargando = false;
        // 1.28 (M5-A2 ★): un {ok:false} (o una respuesta
        // sin ok) ES un fallo de carga aunque el mapa
        // venga vacío — antes el isNotEmpty lo disfrazaba
        // de directorio vacío legítimo.
        _falloCarga = json['ok'] != true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  Future<void> _alternarOculto(PerfilComunidadAdmin p) async {
    final nuevo = !p.ocultoAdmin;
    setState(() => _resolviendo = true);
    try {
      final res = await (widget.ocultarPerfil ?? _ocultarReal)(
          p.clienteId, nuevo);
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _perfiles = [
            for (final x in _perfiles)
              if (x.clienteId == p.clienteId) x.conOculto(nuevo) else x,
          ];
          _resolviendo = false;
        });
      } else {
        setState(() => _resolviendo = false);
        _avisar('El servidor no aplicó el cambio. '
            'Inténtalo de nuevo.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _resolviendo = false);
        _avisar('Sin conexión no se pudo cambiar. '
            'Inténtalo de nuevo.');
      }
    }
  }

  void _avisar(String texto) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  @override
  Widget build(BuildContext context) {
    // Delta Argón 1.27 (#5): guarda defensiva de
    // dueño, el mismo patrón de PremiosHubScreen. La
    // tarjeta solo vive en el Panel del dueño y la
    // RPC valida es_admin en el servidor (el cinturón
    // final), pero la pantalla tampoco se pinta para
    // un entrenador que llegara a abrirla.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Comunidad'),
        body: const Center(
            child: Text('Solo el dueño administra la comunidad.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Comunidad'),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _falloCarga
              ? _mensaje(
                  'No se pudieron cargar los perfiles. '
                  'Revisa la conexión e inténtalo de nuevo.',
                  reintento: true)
              : _perfiles.isEmpty
                  ? _mensaje('Ningún cliente ha creado su '
                      'vitrina todavía. Cuando alguien la '
                      'encienda en su app, aparecerá aquí.')
                  : _listaConBuscador(),
    );
  }

  /// 1.28 (M5-B4): cabecera con los CONTEOS de la
  /// comunidad y el buscador por nombre; debajo, la
  /// lista filtrada. Los conteos son de la lista
  /// COMPLETA (no del filtro): dicen cómo está el
  /// directorio, no la búsqueda.
  Widget _listaConBuscador() {
    final conteos = conteosComunidad(_perfiles);
    final visibles =
        filtrarPerfilesComunidad(_perfiles, _consulta);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'El cliente manda sobre sus datos: '
                'desde aquí solo puedes ocultar un '
                'perfil del directorio (y deshacerlo). '
                'Lo que cada cliente apagó no se ve '
                'ni aquí.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 10),
              Text(
                '${conteos.conVitrina} con vitrina · '
                '${conteos.visibles} visibles en el directorio · '
                '${conteos.ocultosPorTi} ocultos por ti',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _busquedaCtrl,
                decoration: InputDecoration(
                  hintText: 'Buscar por nombre…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _consulta.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _busquedaCtrl.clear();
                            setState(() => _consulta = '');
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _consulta = v),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
        Expanded(
          child: visibles.isEmpty
              ? _mensaje('Ningún perfil coincide con '
                  '«$_consulta».')
              : ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: visibles.length,
                  itemBuilder: (context, i) =>
                      _tarjeta(visibles[i]),
                ),
        ),
      ],
    );
  }

  Widget _mensaje(String texto, {bool reintento = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(texto,
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4)),
            if (reintento) ...[
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: _cargar, child: const Text('Reintentar')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tarjeta(PerfilComunidadAdmin p) {
    final estado = p.ocultoAdmin
        ? 'Oculto por administración'
        : p.visible
            ? 'Visible en el directorio'
            : 'Vitrina apagada (no aparece)';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(p.nombre,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '$estado'
          '${p.bloquesActivos.isEmpty ? '' : '\nComparte: ${p.bloquesActivos.join(', ')}'}',
        ),
        trailing: TextButton(
          onPressed:
              _resolviendo ? null : () => _alternarOculto(p),
          child: Text(p.ocultoAdmin ? 'Mostrar' : 'Ocultar'),
        ),
      ),
    );
  }
}
