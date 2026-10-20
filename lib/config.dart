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
  //
  // v1.2.4 (seguridad): los números reales se eliminaron del repo público.
  // Se leen de la tabla `ajustes` de Supabase vía [datosBancarios].
  // Si no están configurados, se muestra vacío (no exponer datos bancarios).
  static const tarjetaBandec = '';
  static const tarjetaBpa = '';
  static const movilConfirmacion = '';
  static const telegramContacto = '@Jctr0602';
  static const whatsappContacto = '';

  /// Versión visible en login/Ajustes (mantener igual que pubspec).
  /// Incluye el build number para identificar claramente la versión instalada.
  static const appVersion = '1.4.1+59';

  /// Usuarios con permiso de dueño (solo Jc). Comparación en minúsculas
  /// contra la parte local del email alias (nombre@ironbody.gym).
  static const ownerUsernames = {'jc', 'jctr0602', 'julio'};

  /// v1.0.16: lee los datos bancarios de los ajustes remotos
  /// (sincronizados del servidor), con fallback a las constantes locales.
  ///
  /// Claves esperadas en ajustes: `tarjeta_bandec`, `tarjeta_bpa`,
  /// `movil_confirmacion`. Mientras no existan en el servidor, se usan
  /// los valores hardcodeados (visibles en GitHub — migrar ASAP).
  static Map<String, String> datosBancarios(
      Map<String, dynamic> ajustes) {
    String leer(String clave, String fallback) {
      final v = ajustes[clave];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      return fallback;
    }

    return {
      'bandec': leer('tarjeta_bandec', tarjetaBandec),
      'bpa': leer('tarjeta_bpa', tarjetaBpa),
      'movil': leer('movil_confirmacion', movilConfirmacion),
    };
  }
}
