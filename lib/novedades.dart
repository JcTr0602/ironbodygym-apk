/// "Lo Nuevo": cambios por versión, para la sección de Ayuda.
///
/// Se muestra automáticamente una vez tras actualizar la app (punto 46).
library;

import 'package:flutter/material.dart';

import 'config.dart';
import 'perfil.dart';

class Novedad {
  final String version;
  final List<String> cambios;
  const Novedad(this.version, this.cambios);
}

const novedades = [
  Novedad('1.1.1', [
    'Inicio: contador de clientes que pagaron este mes (tocable) y de clientes al día',
    'Datos de transferencia: enviar por SMS o WhatsApp al móvil del cliente',
    'Mi Turno: cierre de turno real, sin necesidad de pagos diarios',
    'Tarjeta "Lo Nuevo" con nuevo diseño',
    'Errores de red en lenguaje simple',
  ]),
  Novedad('1.1.0', [
    'Rediseño visual completo: colores carbón y naranja, tarjetas, iconos Material en vez de emojis',
    'Login, Home, listas, ficha e inscripción rediseñados',
    'Cobrar, Mi Turno/Mis cobros y diálogo de pago renovados',
    'Sincronización y Administración con nuevo diseño',
    'Actividad: más detalles y tocar un registro abre la ficha del cliente',
    'Papelera con foto de cliente',
    'Pagos realizados accesible desde el inicio',
  ]),
  Novedad('1.0.16', [
    'Tipos de pago dinámicos: agrégalos, edítalos o desactívalos en Administración → Tipos de pago',
    'Precio de menores configurable (ya no fijo en el código)',
    'Pendiente por entrenador tocable: ves qué compone cada monto',
    'Historial por entrenador mejorado: tendencia, comparativas y filtros',
    'Mi Turno mejorado: cierre de turno, qué entregar, vencimientos, tendencia, historial semanal',
    'Para el dueño: "Mi turno" ahora es "Mis cobros" (sin pendiente/entregas)',
    'Icono nuevo, SyncBanner rediseñado, Sincronización como tarjeta propia',
  ]),
  Novedad('1.0.15', [
    'Dashboard mejorado: comparativa del mes, desgloses, proyección, ranking de entrenadores, alerta por vencer, gráfico 30 días',
    'Buscar diferenciado: búsqueda en notas, rango de edad, filtro sin foto',
    'Caja rápida en Agregar pago',
    'Reporte de pagos diarios por fecha y turno',
    'Eliminar foto de cliente desde la ficha',
    'Actividad con badge, pendiente a recoger',
  ]),
  Novedad('1.0.14', [
    'Menores de 18 pagan 1500 CUP/mes automáticamente',
    'Usuarios APK: rol, dispositivo, historial de accesos, foto, compartir credenciales por WhatsApp',
    'Cierre de turno sin pagos diarios',
    'Aviso visual de días vigentes al pagar por adelantado (fix del preview)',
    'Distingue "sin internet" de "servidor inaccesible" (fix del falso "sin conexión")',
    'Fix: la huella ahora sí se verifica al abrir',
    'Pantalla de sincronización con 3 estados y mejor UX',
  ]),
  Novedad('1.0.13', [
    'Pagos realizados tocable: lista de clientes que pagaron',
    '️ Miniaturas de fotos en Mi día',
    'Ayuda rediseñada por temas, más fácil de leer',
    'Pago diario: botón rápido, nota, total del día, deshacer y corregir',
    '️ Eliminar cliente definitivamente desde la papelera (arreglado)',
  ]),
  Novedad('1.0.12', [
    'Gestión de usuarios APK: lista con estado y último acceso',
    'Bloquear/desbloquear/cambiar contraseña sin escribir nombres',
    'Cerrar sesión a distancia desde la lista de usuarios',
    'Seguridad en perfil: vincular dispositivo, huella digital, PIN rápido',
    'Detalle por entrenador al tocar (hoy, últimos 7 días, mes)',
    'Auditoría mejorada: cliente, qué cambió y foto',
    '️ Editar pago completo: monto, fecha y método',
    '️ Fixes de seguridad: sync real, precios siempre actualizados',
  ]),
  Novedad('1.0.11', [
    'Quitado botón flotante de sincronizar (tapaba Ayuda)',
    'Editar vencimiento de mensualidad desde la ficha',
    'Detalle de cada operación sincronizada',
    'Foto en grande al tocarla en la ficha',
    'Elegir teléfono desde los contactos del móvil',
    'Dashboard interactivo (toca las tarjetas)',
    'Dueño ya no se debe a sí mismo en Pendiente a entregar',
    'Miniatura de foto en Cuentas por cobrar',
    'Rol en home: Dueño / Entrenador',
  ]),
  Novedad('1.0.10', [
    'Fecha del pago elegible al renovar (ayer, hoy, etc.)',
    '️ Botón "Verificar con servidor" en la ficha del cliente',
    '️ Lista de congelados en Administración (descongelar)',
    'Pantalla de sincronización rediseñada',
    'Avisado ahora es toggle (se puede deshacer)',
    '"Inscrito por" muestra "Migración del sistema anterior"',
    '️ Miniaturas de fotos en lista corregidas',
    'Caché de fotos se invalida al cambiar la foto',
  ]),
  Novedad('1.0.9', [
    'Historial por entrenador: cobrado, pagos, inscripciones y pendiente',
    '️ Congelar membresía: pausa el vencimiento (no aparece en vencidos)',
    'Exportar Excel: clientes y pagos del mes en CSV',
  ]),
  Novedad('1.0.8', [
    'Dashboard: ingresos hoy/7 días/mes, activos vs vencidos',
    'Mi día: cobros del turno, por cobrar hoy, cerrar turno',
    'Cuentas por cobrar: dinero dormido en vencidos',
    'Marcar avisado en vencidos',
    'Mis avisos: configura notificaciones',
    'Gráfico de ingresos últimos 7 días',
  ]),
  Novedad('1.0.7', [
    'Resumen post-sync: popup con lo subido/bajado',
    'Cumpleaños del mes mejorado',
    'Panel salud del sistema',
    'Editor de foto: zoom y mover para centrar',
    'Sync silenciosa al abrir la app',
    '️ Papelera con selección múltiple',
    '️ Eliminar definitivo (solo dueño)',
    'Cobro en 2 toques',
    '️ Clientes en riesgo',
    'Ficha 360 con totales',
  ]),
  Novedad('1.0.6', [
    'Rechazadas: ahora puedes ver el motivo y reenviar la operación',
    'Confirmación de cobro a pantalla completa (check grande, monto, vencimiento)',
    'Auditoría: quién hizo qué y cuándo (solo dueño)',
    'Pago rápido desde vencidos (ya existía, mejorado)',
  ]),
  Novedad('1.0.5', [
    'La APK ahora verifica si el servidor rechazó una operación (no más falso "aplicada")',
    'Fix: clientes nuevos desde la APK ahora aparecen correctamente',
    'Diálogo "Novedades" al actualizar',
  ]),
  Novedad('1.0.4', [
    'Fix crítico: el botón de sincronizar ahora sí funciona (bug _running)',
    'Al archivar, el cliente desaparece al momento (actualización optimista)',
    'La descarga se repite hasta estar al día (no más falso "sincronizado")',
    'Fix error 400 en gastos que bloqueaba la descarga',
    'Detalle tocable de operaciones con errores en lenguaje claro',
    'Iniciales en vez de silueta para clientes sin foto',
    'Colores: rojo vencido, amarillo por vencer, verde al día',
    '️ Pull-to-refresh en la lista de clientes',
    'Login con animación, recuerda usuario y muestra versión',
  ]),
  Novedad('1.0.3', [
    '️ Sección Administración (solo Jc): estadísticas, precios, usuarios APK, pendiente a entregar, gastos, cierre de caja y exportar',
    'Pendiente a entregar ahora cuenta también lo que aún no se sincroniza',
    'Mi Turno con historial diario, desglose por método y última entrega confirmada',
    'Botón Actualizar en Buscar y miniaturas que se descargan solas',
    'El botón Atrasados ahora abre los atrasados de menos de 30 días',
    'Nueva tarjeta "Pagos realizados" en el inicio',
    '️ Corregir pagos (monto/fecha o anular) desde la ficha, solo admin',
    'Alerta de duplicados por carnet al inscribir',
    'Gastos del gym y cierre de caja diario',
    'La sesión ahora refresca el token antes de pedirte entrar de nuevo',
    'Si una operación es rechazada por el servidor, ya no bloquea a las demás',
  ]),
  Novedad('1.0.2', [
    'Cumpleaños de la semana (la fecha sale del carnet)',
    '️ Nueva sección de Ajustes: foto de perfil, móvil, carnet, tema',
    'Cambia tu contraseña dentro de la app',
    'Las fotos se suben por partes: si se corta la conexión, continúan donde quedaron',
    'La sincronización muestra el progreso de lo pendiente por subir y bajar',
    '⏰ Aviso si llevas más de 8 horas sin subir cambios',
    'Renovación rápida con un toque (también desde la papelera)',
    'Cambia la foto de un cliente: cámara o galería',
    'Ordena las listas por nombre, vencimiento o días restantes',
    '️ Solo Jc puede eliminar definitivamente desde la papelera',
  ]),
  Novedad('1.0.1', [
    'Buscar muestra todos los clientes, con estado y días restantes',
    '️ Períodos de pago: semana, quincena y días personalizados',
    '️ Papelera recuperable',
    'Foto del cliente en ficha y listas',
    'Pago rápido desde las listas',
    'Pendiente a entregar con desglose',
    'Sincronización detallada con hora de última vez',
  ]),
];

/// Compara versiones semánticas (1.0.10 > 1.0.9).
/// La comparación de strings falla: "1.0.10" < "1.0.9" letra por letra.
int compararVersiones(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Muestra "Lo Nuevo" una sola vez tras actualizar. Devuelve true si la mostró.
Future<bool> mostrarNovedadesSiHay(BuildContext context) async {
  final perfil = PerfilService.instance;
  final vista = await perfil.getUltimaVersionVista();
  if (vista == AppConfig.appVersion) return false;
  await perfil.setUltimaVersionVista(AppConfig.appVersion);
  final nuevas = novedades
      .where((n) =>
          vista == null || compararVersiones(n.version, vista) > 0)
      .toList();
  if (nuevas.isEmpty || !context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Lo nuevo en esta versión'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final n in nuevas) ...[
              Text('Versión ${n.version}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              for (final c in n.cambios)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: 4),
                  child: Text('• $c',
                      style: const TextStyle(fontSize: 13)),
                ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido')),
      ],
    ),
  );
  return true;
}
