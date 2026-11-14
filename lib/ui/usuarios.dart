import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../config.dart' show AppConfig;
import '../tiempo.dart' show ahoraHabana, aHabana;
import 'app_bar.dart';
import 'diseno.dart';
import 'componentes.dart';
import 'foto_elegir.dart';

/// Gestión de usuarios APK (v1.0.12, mejoras v1.0.14).
/// Lista desde sync_estado (publicada por el puente), acciones directas
/// sin escribir nombres a mano.
class UsuariosScreen extends StatefulWidget {
  const UsuariosScreen({super.key});

  @override
  State<UsuariosScreen> createState() => _UsuariosScreenState();
}

/// Validación para crear un usuario APK (1.14, M6.9): el nombre
/// se recorta (un nombre de solo espacios no vale) y la
/// contraseña exige mínimo 6 caracteres. La función valida la
/// cadena que recibe tal cual: el llamador debe pasarla ya
/// normalizada (ver normalizarPasswordNuevoUsuario y P6 1.15).
/// Devuelve el mensaje de error o null si vale. La pantalla
/// encola 'admin_usuario' solo si vale.
String? validarNuevoUsuarioApk(String nombre, String password) {
  if (nombre.trim().isEmpty || password.length < 6) {
    return 'Nombre vacío o contraseña muy corta (mín. 6)';
  }
  return null;
}

/// 1.15 P6: la contraseña de un usuario nuevo se normaliza con
/// trim ANTES de validar, encolar y compartir: una clave de 6
/// caracteres que tras trim queda en menos debe rechazarse, y la
/// encolada/compartida debe ser exactamente la validada (antes
/// se validaba sin recortar pero se encolaba el texto crudo).
String normalizarPasswordNuevoUsuario(String crudo) => crudo.trim();

/// 1.15 P2: guard de acciones de administración de usuarios.
/// Solo el dueño ejecuta crear/administrar/foto (patrón
/// PanelPermisos: AuthService().isOwner). BLOQUEA la acción,
/// no solo oculta el botón: cada método de acción lo comprueba
/// antes de cualquier diálogo o escritura.
bool puedeEjecutarAccionesUsuarios(bool esDueno) => esDueno;

/// 1.15 P2: payload de la op `admin_usuario` para cambiar la foto
/// de un usuario. CONTRATO con el servidor: accion='cambiar_foto',
/// payload {username, foto_base64} con el base64 de los bytes
/// elegidos (comprimidos por el picker). La app NUNCA sube la
/// foto directa a Storage: la encola y el servidor la sube
/// tras validar que quien la pide es el dueño.
Map<String, dynamic> payloadCambiarFotoUsuario(
        {required String username, required List<int> bytes}) =>
    {
      'accion': 'cambiar_foto',
      'username': username,
      'foto_base64': base64Encode(bytes),
    };

class _UsuariosScreenState extends State<UsuariosScreen> {
  List<Map<String, dynamic>> _usuarios = [];
  bool _cargando = true;
  // 1.25 T119 (F3-22): buscador (como el de Invitados) y marca
  // de frescura cuando el pull falla y la lista sale de la
  // caché: antes un fallo de red dejaba la lista vieja en
  // pantalla sin ningún aviso.
  final _busquedaCtrl = TextEditingController();
  String _filtro = '';
  bool _pullFallo = false;
  DateTime? _ultimoPull;

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    // Yunque de App 1.31 (C4-1 + C2-2): PINTAR LO LOCAL
    // PRIMERO. Antes el pull corría antes de pintar la meta
    // local y la pantalla esperaba la bajada entera (con una
    // fila sucia del espejo además moría en spinner: las
    // lecturas locales iban sin red — C2-2). Ahora: la lista
    // guardada se pinta al momento y el pull refresca tras
    // ella, conservando la marca de frescura F3-22.
    var pullFallo = false;
    try {
      await _leerLocal();
    } catch (e) {
      AppLog.error('usuarios', 'lectura_local_fallo', d: '$e');
      _pintar(const [], pullFallo: _pullFallo || pullFallo);
      return;
    }
    try {
      await SyncEngine.instance.pull();
    } catch (_) {
      pullFallo = true;
    }
    try {
      await _leerLocal(pullFallo: pullFallo);
    } catch (e) {
      // El pull puede haber actualizado la meta; si releer
      // falla, se CONSERVA lo ya pintado y queda bitácora.
      AppLog.error('usuarios', 'relectura_fallo', d: '$e');
      _pintar(_usuarios, pullFallo: pullFallo);
    }
  }

  /// Lee la lista guardada en la meta y la pinta (con la
  /// marca de frescura del pull que corresponda).
  Future<void> _leerLocal({bool? pullFallo}) async {
    final tsPull = await LocalDb.instance.getMeta('ultimo_pull_ts');
    final ultimoPull = tsPull == null ? null : DateTime.tryParse(tsPull);
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    final lista = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final u in jsonDecode(raw) as List) {
          lista.add(Map<String, dynamic>.from(u as Map));
        }
      } catch (_) {}
    }
    lista.sort((a, b) => '${a['username']}'.compareTo('${b['username']}'));
    _pintar(lista, pullFallo: pullFallo ?? _pullFallo, ultimoPull: ultimoPull);
  }

  void _pintar(List<Map<String, dynamic>> lista,
      {required bool pullFallo, DateTime? ultimoPull}) {
    if (!mounted) return;
    setState(() {
      _usuarios = lista;
      _cargando = false;
      _pullFallo = pullFallo;
      if (ultimoPull != null) _ultimoPull = ultimoPull;
    });
  }

  /// F3-22: la lista que se pinta, tras el filtro del buscador.
  List<Map<String, dynamic>> get _visibles {
    final f = _filtro.trim().toLowerCase();
    if (f.isEmpty) return _usuarios;
    return _usuarios
        .where((u) =>
            '${u['username'] ?? ''}'.toLowerCase().contains(f) ||
            '${u['nombre'] ?? ''}'.toLowerCase().contains(f))
        .toList();
  }

  /// F3-22: texto de frescura cuando la lista sale de la caché
  /// tras un pull fallido (mismo formato que Mi Día).
  String _textoFrescuraCache() {
    final ts = _ultimoPull;
    if (ts == null) return '📴 Sin conexión · datos guardados';
    final diff = ahoraHabana().difference(aHabana(ts));
    if (diff.inMinutes < 1) return '📴 Sin conexión · datos de ahora mismo';
    if (diff.inMinutes < 60) {
      return '📴 Sin conexión · datos de hace ${diff.inMinutes} min';
    }
    if (diff.inHours < 24) {
      return '📴 Sin conexión · datos de hace ${diff.inHours} h';
    }
    return '📴 Sin conexión · datos de hace ${diff.inDays} días';
  }

  Future<void> _accion(
      String username, String accion, String titulo,
      {String? rol}) async {
    // 1.15 P2: guard de acción (no solo de botón): sin dueño,
    // nada se encola ni se dialoga.
    if (!puedeEjecutarAccionesUsuarios(AuthService().isOwner)) {
      if (!mounted) return;
      mostrarSnack(context, 'Solo el dueño puede gestionar usuarios.', significado: SignificadoChip.alerta);
      return;
    }
    if (accion == 'eliminar') {
      final ok = await DialogoApp.confirmar(
        context,
        titulo: 'Eliminar usuario',
        mensaje:
            '¿Eliminar a "$username"? Perderá acceso inmediatamente.',
        aceptar: 'Eliminar',
        peligro: true,
        icono: Icons.delete_outline_rounded,
      );
      if (ok != true || !mounted) return;
    }
    String? password;
    if (accion == 'reset_pass') {
      final texto = await showDialog<String>(
        context: context,
        builder: (ctx) =>
            _DialogoNuevaContrasena(username: username),
      );
      if (texto == null || !mounted) return;
      password = texto.trim();
      if (password.length < 6) {
        mostrarSnack(context, 'Contraseña muy corta (mín. 6 caracteres)', significado: SignificadoChip.alerta);
        return;
      }
    }
    final payload = <String, dynamic>{
      'accion': accion,
      'username': username,
    };
    if (password != null) payload['password'] = password;
    if (rol != null) payload['rol'] = rol;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: payload,
    );
    if (!mounted) return;
    mostrarSnack(context, '"$titulo" encolado para $username', significado: SignificadoChip.exito);
    // v1.0.14: ofrecer compartir credenciales tras crear/resetear
    if ((accion == 'crear' || accion == 'reset_pass') &&
        password != null) {
      _compartirCredenciales(username, password);
    }
    SyncEngine.instance.push();
  }

  /// v1.0.14: texto listo para compartir credenciales por WhatsApp.
  void _compartirCredenciales(String username, String password) {
    final texto = textoCredencialesStaff(username, password);
    showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Compartir credenciales',
        iconoTitulo: Icons.share_rounded,
        contenido: SingleChildScrollView(child: Text(texto)),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copiar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadio.md),
              ),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: texto));
              Navigator.pop(ctx);
              mostrarSnack(context, 'Copiado, pégalo en WhatsApp');
            },
          ),
        ],
      ),
    );
  }

  /// v1.0.14: historial de accesos del usuario.
  void _verHistorial(Map<String, dynamic> u) {
    final username = '${u['username'] ?? '?'}';
    final accesos = (u['accesos'] as List?)?.cast<String>() ?? [];
    showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Accesos de $username',
        iconoTitulo: Icons.history_rounded,
        contenido: SizedBox(
          width: double.maxFinite,
          child: accesos.isEmpty
              ? const Text('Sin accesos registrados.''\n'
                  'El historial se genera con el uso de la APK.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: accesos.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1),
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.login_rounded, size: 18),
                    title: Text(tiempoRelativo(accesos[i]),
                        style: AppTexto.cuerpo),
                    subtitle: Text(fmtFecha(accesos[i]),
                        style: AppTexto.metadato),
                  ),
                ),
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

  /// v1.0.14: avatar con foto del usuario si existe.
  /// 1.34 Campo 2 (P-4): la resolución vive en el State de
  /// _AvatarUsuario, no en un futuro creado en el build.
  Widget _avatar(String username, bool bloqueado, bool esAdmin) =>
      _AvatarUsuario(
          username: username, bloqueado: bloqueado, esAdmin: esAdmin);

  /// v1.0.14: foto del entrenador (1.15 P2: ya NO sube directa
  /// a Storage). Se encola la op `admin_usuario` con
  /// accion='cambiar_foto' y el base64 de la imagen elegida; el
  /// servidor valida al dueño y sube la foto. Una foto encolada
  /// sin conexión NO aparenta estar subida: el aviso dice
  /// «encolada», no «actualizada», y no se invalida la caché
  /// ni se repinta el avatar hasta que el pull la confirme.
  Future<void> _cambiarFoto(String username) async {
    // 1.15 P2: guard de acción.
    if (!puedeEjecutarAccionesUsuarios(AuthService().isOwner)) {
      if (!mounted) return;
      mostrarSnack(context, 'Solo el dueño puede gestionar usuarios.', significado: SignificadoChip.alerta);
      return;
    }
    // Cierre §17 (×10): por la vía segura de la casa
    // (foto_elegir.dart) — try/catch con aviso, recuperación
    // con retrieveLostData y guarda anti-doble-toque. El
    // pickImage vivía fuera del try que cubre el resto.
    final img = await elegirFotoSegura(
      context,
      origen: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 75, // Gemini: compresión obligatoria para Cuba
    );
    if (img == null || !mounted) return;
    try {
      final bytes = await File(img.path).readAsBytes();
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'admin_usuario',
        payload: payloadCambiarFotoUsuario(
            username: username, bytes: bytes),
      );
      if (!mounted) return;
      mostrarSnack(context, 'Foto encolada (se sincronizará)', significado: SignificadoChip.exito);
      SyncEngine.instance.push();
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo encolar la foto: $e', significado: SignificadoChip.error);
    }
  }

  /// v1.0.14: cambiar rol desde la lista.
  Future<void> _cambiarRol(
      String username, String rolActual) async {
    // 1.15 P2: guard de acción.
    if (!puedeEjecutarAccionesUsuarios(AuthService().isOwner)) {
      if (!mounted) return;
      mostrarSnack(context, 'Solo el dueño puede gestionar usuarios.', significado: SignificadoChip.alerta);
      return;
    }
    final nuevoRol =
        rolActual == 'admin' ? 'entrenador' : 'admin';
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cambiar rol',
      mensaje: '"$username" pasará de "$rolActual" a "$nuevoRol".\n\n'
          '${nuevoRol == 'admin' ? 'Tendrá acceso a Administración, finanzas y auditoría.' : 'Solo verá las funciones de entrenador.'}',
      aceptar: 'Cambiar a $nuevoRol',
      icono: Icons.manage_accounts_rounded,
    );
    if (ok == true && mounted) {
      await _accion(username, 'cambiar_rol', 'Cambiar rol', rol: nuevoRol);
      _cargar();
    }
  }

  Future<void> _crear() async {
    // 1.15 P2: guard de acción.
    if (!puedeEjecutarAccionesUsuarios(AuthService().isOwner)) {
      if (!mounted) return;
      mostrarSnack(context, 'Solo el dueño puede gestionar usuarios.', significado: SignificadoChip.alerta);
      return;
    }
    final datos =
        await showDialog<({String nombre, String pass})>(
      context: context,
      builder: (ctx) => const _DialogoCrearUsuario(),
    );
    if (datos == null || !mounted) return;
    final nombre = datos.nombre.trim();
    // 1.15 P6: la contraseña se recorta ANTES de validar, encolar
    // y compartir: la validada, la encolada y la compartida son
    // la MISMA cadena normalizada.
    final pass = normalizarPasswordNuevoUsuario(datos.pass);
    // 1.14 (M6.9): la regla vive en validarNuevoUsuarioApk.
    final error = validarNuevoUsuarioApk(nombre, pass);
    if (error != null) {
      mostrarSnack(context, error, significado: SignificadoChip.error);
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: {'accion': 'crear', 'username': nombre, 'password': pass},
    );
    if (!mounted) return;
    mostrarSnack(context, 'Usuario encolado (se sincronizará)', significado: SignificadoChip.exito);
    SyncEngine.instance.push();
    _compartirCredenciales(nombre, pass);
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    // 1.25 T29: guarda de VISTA, no solo de acciones (patrón
    // de la pantalla hermana PanelPermisos): un entrenador
    // podía abrir Usuarios y ver cuentas, dispositivos,
    // versiones y últimos accesos de todo el staff. La lista
    // ni se pinta sin ser dueño; las acciones ya tenían su
    // propio guard (puedeEjecutarAccionesUsuarios).
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Usuarios APK'),
        body: const Center(
            child: Text('Solo el dueño puede ver los usuarios.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Usuarios APK',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _crear,
        icon: const Icon(Icons.person_add_rounded),
        label: const Text('Crear'),
      ),
      // 1.23 T7: cruce por tipo de estado (el vacío ya era el
      // compartido EstadoVacio).
      // 1.25 T119 (F3-22): sobre el cruce van el buscador y,
      // si el pull falló, la marca de frescura de la caché.
      body: Column(
        children: [
          if (!_cargando && _usuarios.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.md, AppEspacio.lg, AppEspacio.xs),
              child: TextField(
                controller: _busquedaCtrl,
                decoration: InputDecoration(
                  hintText: 'Buscar usuario…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Quitar búsqueda',
                          onPressed: () {
                            _busquedaCtrl.clear();
                            setState(() => _filtro = '');
                          },
                        ),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
            if (_pullFallo)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                    AppEspacio.xs, AppEspacio.lg, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_textoFrescuraCache(),
                      style: AppTexto.metadato),
                ),
              ),
          ],
          Expanded(
            child: CruceEstados(
        estado: _cargando
            ? 'cargando'
            : (_usuarios.isEmpty || _visibles.isEmpty)
                ? 'vacio'
                : 'contenido',
        child: _cargando
            ? const EstadoCargando(texto: 'Cargando usuarios…')
            : _usuarios.isEmpty
                ? EstadoVacio(
                  icono: Icons.people_outline_rounded,
                  titulo: 'Sin datos',
                  subtitulo: 'Sincroniza para ver la lista.',
                  textoAccion: 'Actualizar',
                  onAccion: _cargar,
                )
                : _visibles.isEmpty
                    ? EstadoVacio(
                        icono: Icons.search_off_rounded,
                        titulo: 'Nadie coincide',
                        subtitulo:
                            'Ningún usuario coincide con «$_filtro».',
                        textoAccion: 'Quitar búsqueda',
                        onAccion: () {
                          _busquedaCtrl.clear();
                          setState(() => _filtro = '');
                        },
                      )
              : RefrescoIron(
                  onRefresh: _cargar,
                  child: ListView.separated(
                    itemCount: _visibles.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final u = _visibles[i];
                      final username = '${u['username'] ?? '?'}';
                      final bloqueado = u['bloqueado'] == true;
                      // v1.0.14: tiempo relativo legible
                      final ultimoRel =
                          tiempoRelativo('${u['ultimo_acceso'] ?? ''}');
                      final dispositivo =
                          '${u['dispositivo'] ?? ''}';
                      // v1.3.3: versión de la app instalada por el usuario.
                      final appVersion = '${u['app_version'] ?? ''}';
                      final rol = '${u['rol'] ?? 'entrenador'}';
                      final esAdmin = rol == 'admin';
                      // F3-22: el dueño se detecta por IDENTIDAD
                      // (el uid de la fila contra el uid de la
                      // sesión, vía AuthService), no por un
                      // username escrito a mano en la UI. Sin uid
                      // en la fila (cachés viejas), respaldo por
                      // la lista de dueños de la configuración.
                      final uidFila = '${u['id'] ?? ''}';
                      final miUid = AuthService().userId ?? '';
                      final esDueno = uidFila.isNotEmpty
                          ? uidFila == miUid
                          : AppConfig.ownerUsernames
                              .contains(username.toLowerCase());
                      return ListTile(
                        leading: _avatar(username, bloqueado, esAdmin),
                        title: Row(
                          children: [
                            Expanded(
                                child: Text(username,
                                    overflow:
                                        TextOverflow.ellipsis)),
                            if (esDueno)
                              const Chip(
                                label: Text('Dueño',
                                    style: AppTexto.minuscula),
                                visualDensity: VisualDensity.compact,
                              )
                            else if (esAdmin)
                              const Chip(
                                label: Text('Admin',
                                    style: AppTexto.minuscula),
                                visualDensity: VisualDensity.compact,
                              ),
                            // F3-22: el chip se pinta también en
                            // la fila del dueño — antes se
                            // ocultaba justo ahí, y un bloqueo
                            // del dueño en el servidor no se veía.
                            if (bloqueado)
                              const Chip(
                                label: Text('Bloqueado',
                                    style: AppTexto.minuscula),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Último acceso: $ultimoRel',
                              style: AppTexto.metadato,
                            ),
                            if (dispositivo.isNotEmpty)
                              Text(
                                dispositivo,
                                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                        context)),
                              ),
                            // v1.3.3: versión de la app del usuario.
                            if (appVersion.isNotEmpty)
                              Text(
                                'App: v$appVersion',
                                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                        context)),
                              ),
                          ],
                        ),
                        onTap: () => _verHistorial(u),
                        trailing: esDueno
                            ? null
                            : PopupMenuButton<String>(
                                popUpAnimationStyle: estiloAparicionMenu,
                                onSelected: (v) {
                                  if (v == 'cambiar_rol') {
                                    _cambiarRol(username, rol);
                                    return;
                                  }
                                  if (v == 'foto') {
                                    _cambiarFoto(username);
                                    return;
                                  }
                                  if (v == 'historial') {
                                    _verHistorial(u);
                                    return;
                                  }
                                  final titulos = {
                                    'bloquear': 'Bloquear',
                                    'desbloquear': 'Desbloquear',
                                    'forzar_cierre':
                                        'Cerrar sesión a distancia',
                                    'reset_pass': 'Cambiar contraseña',
                                    'eliminar': 'Eliminar',
                                  };
                                  _accion(username, v, titulos[v] ?? v);
                                },
                                itemBuilder: (ctx) => [
                                  const PopupMenuItem(
                                    value: 'cambiar_rol',
                                    child: Text(
                                        'Cambiar rol (entrenador ↔ admin)'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'foto',
                                    child: Text('Cambiar foto'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'historial',
                                    child: Text('Ver historial de accesos'),
                                  ),
                                  if (!bloqueado)
                                    const PopupMenuItem(
                                      value: 'bloquear',
                                      child: Text('Bloquear'),
                                    ),
                                  if (bloqueado)
                                    const PopupMenuItem(
                                      value: 'desbloquear',
                                      child: Text('Desbloquear'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'forzar_cierre',
                                    child:
                                        Text('Cerrar sesión a distancia'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'reset_pass',
                                    child: Text('Cambiar contraseña'),
                                  ),
                                  PopupMenuItem(
                                    value: 'eliminar',
                                    child: Text('Eliminar',
                                        style: TextStyle(
                                            color: AppColores.error)),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Nueva contraseña» como
/// StatefulWidget propio: posee y dispone su controlador
/// (antes se creaba en el llamador y nunca se liberaba).
/// Devuelve el texto escrito o null si se cancela.
class _DialogoNuevaContrasena extends StatefulWidget {
  final String username;
  const _DialogoNuevaContrasena({required this.username});

  @override
  State<_DialogoNuevaContrasena> createState() =>
      _DialogoNuevaContrasenaState();
}

class _DialogoNuevaContrasenaState
    extends State<_DialogoNuevaContrasena> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Nueva contraseña para ${widget.username}',
      iconoTitulo: Icons.key_rounded,
      contenido: CampoTexto(
        controller: _ctrl,
        etiqueta: 'Contraseña (mín. 6)',
        obscure: true,
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
              ),
            ),
            child: const Text('Cambiar')),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Crear usuario APK»
/// como StatefulWidget propio: posee y dispone sus
/// controladores (antes se creaban en el llamador y nunca
/// se liberaban). Devuelve nombre y contraseña escritos o
/// null si se cancela.
class _DialogoCrearUsuario extends StatefulWidget {
  const _DialogoCrearUsuario();

  @override
  State<_DialogoCrearUsuario> createState() =>
      _DialogoCrearUsuarioState();
}

class _DialogoCrearUsuarioState extends State<_DialogoCrearUsuario> {
  final _nombreCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Crear usuario APK',
      iconoTitulo: Icons.person_add_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CampoTexto(
              controller: _nombreCtrl,
              etiqueta: 'Nombre de usuario'),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _passCtrl,
              etiqueta: 'Contraseña (mín. 6)',
              obscure: true),
        ],
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
            onPressed: () => Navigator.pop(context,
                (nombre: _nombreCtrl.text, pass: _passCtrl.text)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColores.naranja,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(AppRadio.md),
              ),
            ),
            child: const Text('Crear')),
      ],
    );
  }
}

/// v1.0.14: texto de credenciales del staff listo para
/// compartir. Yunque 2.34 (G-2): cierra con la línea de
/// mensaje automático de la regla de Jc (2026-11-01), como
/// ya hacía el mensaje del PIN (C6-4) — este era el único
/// mensaje compuesto por la app que no la llevaba. PURO.
String textoCredencialesStaff(String username, String password) =>
    '''🏋️ *Iron Body Gym*

Hola $username, estas son tus credenciales para la app del gym:

👤 *Usuario:* $username
🔑 *Contraseña:* $password

📲 Descarga la APK e inicia sesión con estos datos.
⚠️ No compartas tu contraseña con nadie.$lineaMensajeAutomatico''';

/// 1.34 Campo 2 (P-4): avatar de la lista de usuarios con
/// su foto si existe. El futuro de caché se crea en el
/// State (una vez por username), no dentro del build de
/// la fila; la decodificación va acotada (P-1).
class _AvatarUsuario extends StatefulWidget {
  final String username;
  final bool bloqueado;
  final bool esAdmin;
  const _AvatarUsuario(
      {required this.username,
      required this.bloqueado,
      required this.esAdmin});

  @override
  State<_AvatarUsuario> createState() => _AvatarUsuarioState();
}

class _AvatarUsuarioState extends State<_AvatarUsuario> {
  late Future<File?> _futura;

  Future<File?> _resolver() => FotoCache.instance
      .enCache('usuarios/${widget.username.toLowerCase()}.jpg');

  @override
  void initState() {
    super.initState();
    _futura = _resolver();
  }

  @override
  void didUpdateWidget(_AvatarUsuario old) {
    super.didUpdateWidget(old);
    if (old.username != widget.username) _futura = _resolver();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        final file = snap.data;
        if (file != null) {
          return CircleAvatar(
            backgroundImage: providerFotoAcotada(FileImage(file),
                ancho:
                    (80 * MediaQuery.devicePixelRatioOf(ctx)).round()),
            backgroundColor: AppColores.borde(ctx),
          );
        }
        final username = widget.username;
        return CircleAvatar(
          backgroundColor: widget.bloqueado
              ? AppColores.error.withValues(alpha: 0.15)
              : widget.esAdmin
                  ? AppColores.info.withValues(alpha: 0.15)
                  : AppColores.exito.withValues(alpha: 0.15),
          child: Text(
            username.isNotEmpty ? username[0].toUpperCase() : '?',
            style: TextStyle(
              color: widget.bloqueado
                  ? AppColores.error
                  : widget.esAdmin
                      ? AppColores.info
                      : AppColores.exito,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    );
  }
}
