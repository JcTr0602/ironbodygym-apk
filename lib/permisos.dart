import 'auth.dart';

/// Sistema de permisos por acción (v1.0.12).
///
/// Roles:
/// - Dueño: control total (Jc).
/// - Administrador: casi todo, sin gestión de usuarios ni borrado definitivo.
/// - Entrenador: operación diaria (cobrar, inscribir, listas).
class Permisos {
  final AuthService _auth = AuthService();

  bool get esDueno => _auth.isOwner;
  bool get esAdmin => _auth.isAdmin;
  bool get esEntrenador => !esAdmin;

  /// Ver finanzas: dashboard, flujo de caja, cuentas por cobrar.
  bool get verFinanzas => esAdmin;

  /// Gestionar usuarios APK.
  bool get gestionarUsuarios => esDueno;

  /// Borrado definitivo en papelera.
  bool get borradoDefinitivo => esDueno;

  /// Cambiar precios y ajustes del sistema.
  bool get cambiarPrecios => esDueno;

  /// Ver auditoría completa.
  bool get verAuditoria => esAdmin;

  /// Exportar datos a Excel.
  bool get exportarDatos => esAdmin;

  /// Ver lista de congelados.
  bool get verCongelados => esAdmin;

  /// Editar cualquier cliente (entrenador solo los que inscribió).
  bool get editarClientes => esAdmin;

  /// Cobrar mensualidades y diarios.
  bool get cobrar => true;

  /// Inscribir clientes nuevos.
  bool get inscribir => true;

  /// Ver sección Administración.
  bool get verAdministracion => esAdmin;
}
