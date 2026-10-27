/// Cliente protegido (2026-10-26, diseño Argón AMARILLO→VERDE).
///
/// Regla: el entrenador ve SOLO foto y nombre de un cliente protegido.
/// Ni teléfono, ni edad, ni fechas, ni botones de acción. El dueño
/// (Jctr0602) ve y modifica todo igual que antes.
///
/// La marca viaja en el espejo local como `protegido` (1/0): la pone
/// el servidor (op `set_cliente_protegido`, solo dueño) y el pull la
/// publica en la fila de `sync_clientes`; la app NO la inventa.
///
/// La guarda REAL vive en el servidor (`sync.py`, rechazo
/// CLIENTE_PROTEGIDO). Esto de aquí es solo presentación: que la UI
/// no ofrezca lo que el servidor va a rechazar.
library;

import 'auth.dart';

/// ¿El cliente está marcado como protegido? Tolerante con el tipo
/// que traiga el espejo (int de SQLite, String del JSON, bool).
bool clienteEstaProtegido(Map<String, dynamic> c) {
  final v = c['protegido'];
  if (v is int) return v == 1;
  if (v is String) return v == '1' || v.toLowerCase() == 'true';
  if (v is bool) return v;
  return false;
}

/// ¿La vista debe mostrarse bloqueada? Protegido Y quien mira NO es
/// el dueño. [esDueno] existe para tests (sin sesión activa); la UI
/// lo omite y se resuelve desde [AuthService].
///
/// 2026-10-26 (Protegido 2): si AuthService no puede resolverse
/// (p. ej. Supabase sin inicializar en tests), se falla CERRADO:
/// se trata como no-dueño y la vista se bloquea, en vez de reventar.
bool esVistaProtegida(Map<String, dynamic> c, {bool? esDueno}) {
  bool dueno;
  if (esDueno != null) {
    dueno = esDueno;
  } else {
    try {
      dueno = AuthService().isOwner;
    } catch (_) {
      dueno = false;
    }
  }
  return clienteEstaProtegido(c) && !dueno;
}

/// Texto que ve el entrenador al intentar modificar un protegido.
const String mensajeClienteProtegido =
    'Cliente protegido: solo el dueño puede modificarlo';

/// Banner de la ficha bloqueada (palabras de Jc).
const String bannerClienteProtegido =
    'Cliente Protegido — solo Jctr0602 puede modificar';
