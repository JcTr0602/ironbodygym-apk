/// Configuración fija de la app (v1).
///
/// La URL no es secreta. La `anonKey` es la publishable key: está diseñada
/// para ir embebida en clientes (las políticas RLS limitan el acceso).
/// La `service_role` NUNCA va en la app.
class AppConfig {
  static const supabaseUrl = 'https://mjttljkfzntwnzgwjnkk.supabase.co';
  static const anonKey = 'sb_publishable_R04zp3diEAOvtgD-tjCQag_ayS5mzW_';

  static const bucketFotos = 'fotos-clientes';

  // Datos de transferencia (Transfermóvil/Enzona) — fijos del negocio.
  static const tarjetaBandec = '9224 0699 9273 2798';
  static const tarjetaBpa = '9205 1299 7518 5449';
  static const movilConfirmacion = '58191577';
  static const telegramContacto = '@Jctr0602';
  static const whatsappContacto = '58191577';

  /// Versión visible en Ayuda/Ajustes (mantener igual que pubspec).
  static const appVersion = '1.0.12';

  /// Usuarios con permiso de dueño (solo Jc). Comparación en minúsculas
  /// contra la parte local del email alias (nombre@ironbody.gym).
  static const ownerUsernames = {'jc', 'jctr0602', 'julio'};
}
