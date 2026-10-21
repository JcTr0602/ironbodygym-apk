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
  Novedad('1.4.3', [
    'Ficha del suplemento: ahora escribes el contenido del envase (ej. 300 g) y los servicios por envase; el cliente los ve en su catálogo',
    'Listas ordenadas por el nombre real: los clientes escritos en minúsculas (p. ej. «alberto prueba») ya no quedan al final, tras la Z',
    'Limpieza interna: se retiró el sistema viejo de subida de fotos; la cola actual es el único camino (sin cambios visibles)',
  ]),
  Novedad('1.4.2', [
    'Nómina: «Pagaron el mes» ya no cuenta a los clientes que vencen dentro del mismo mes (ese pago corresponde al mes siguiente)',
    'Panel: tocar una barra de la gráfica de 7 días ya muestra el detalle del día (antes podía cerrar la pantalla)',
    'Panel: el desglose del mes ahora incluye los suplementos y cuadra con el total',
    'Panel: «Pendiente por entrenador» muestra también lo que falta en USD',
    'Panel: nueva fila «Neto del mes» (ingresos menos gastos) y acceso directo a los que están por vencer',
    'Ayuda al día: la guía ya refleja las pantallas actuales',
  ]),
  Novedad('1.4.1', [
    'La app ahora se llama Iron Body Gestión',
    'Administración reorganizada: lo de todos los días quedó arriba',
    'Control de Acceso: opciones rápidas en cada cliente (los tres puntos de su tarjeta)',
    'Horario de turnos del dueño: la app de clientes muestra quién abre según el horario cuando no hay turno registrado',
    'Actividad: gráfico de acciones por día (30 días) y filtros que quedan guardados',
    'Adopción y Campaña WA (solo dueño): estadísticas de la app de clientes e invitaciones por tandas',
    'Foto del cliente: el recorte al ajustarla ahora sí se aplica tal cual lo dejas',
    'Eliminar la foto de un cliente funciona aunque nunca se haya descargado en este teléfono',
    'Ficha del cliente reorganizada: acciones juntas y el acceso a su app más claro',
  ]),
  Novedad('1.4.0', [
    'Control de Acceso: entrenadores y accesos de la app de clientes en un solo lugar',
    'Los clientes pueden activar su app ellos mismos con el PIN inicial',
    'Turnos manuales: marca quién abrió si el registro automático falló',
    'Estadísticas rápidas en el inicio: cuántos pagaron el mes y la base de la nómina',
    'Nómina pre-calculada (solo dueño) en Administración',
    'Mediciones del cliente simplificadas en su ficha',
    'Botón de sincronizar con estados claros: sincronizando, al día o esperando conexión',
  ]),
  Novedad('1.3.9', [
    'Permisos por usuario: cada quien ve y hace solo lo que le toca',
    'App de clientes: mediciones de progreso y planes nutricionales',
    'Al inscribir: tipos de pago personalizados en la lista (por ejemplo, las ofertas)',
  ]),
  Novedad('1.3.8', [
    'Avisos de WhatsApp mejorados',
    'Cumpleaños mejor presentados en el inicio y en los avisos',
  ]),
  Novedad('1.3.7', [
    'Suplementos: margen por producto, aviso de stock bajo y control de fiados',
    'Comprobante de venta para enviar por WhatsApp',
    'Buscar al cliente al registrar una venta',
    'Actividad y Auditoría rediseñadas; Administración reorganizada',
    '"Por vencer" ya no mezcla a los que vencen hoy (tienen su propia lista)',
  ]),
  Novedad('1.3.6', [
    'Avisos WhatsApp de hoy: cumpleaños, vencimientos y recibos en una sola bandeja',
    'Arqueo de caja (solo dueño): liquida el efectivo pendiente de cada entrenador',
    'Incidencias de sincronización visibles en Administración',
    'Botón de acciones rápidas (el rayo) en el inicio: Cobrar, Pago diario e Inscribir',
  ]),
  Novedad('1.3.5', [
    'Confirmación con resumen antes de inscribir un cliente',
    'Actividad renovada: más detalle de quién hizo qué',
    'Sincronización por alcance: baja solo lo que cambió, más ligera',
  ]),
  Novedad('1.3.4', [
    'Motor de sincronización nuevo: más rápido y más fiable',
    'Las fotos suben sin bloquear los cobros: primero los datos, después las fotos',
    'Limpieza interna de la base de datos: la app responde mejor con muchos clientes',
  ]),
  Novedad('1.3.2', [
    'Plantillas de descripción por tipo de incidencia',
    'Acciones en lote para incidencias (cambiar estado de varias a la vez)',
    '"¿Siguió viniendo?": elige la base al cobrar un pago vencido',
    'Reportes diarios por entrenador y turnos sin reporte',
    'Resumen mensual de pagos diarios por turno y entrenador',
    'Correcciones de sincronización, dinero y permisos (auditoría completa)',
  ]),
  Novedad('1.3.1', [
    'Confirmar entregas sin crashes: corrección crítica de base de datos',
    'Suplementos: precio recordado se preserva en sincronización',
    'Incidencias: no se pierden cambios locales pendientes',
    'Ventas en USD: tasa opcional, validación robusta',
    'Pago a entrenadores movido a Administración',
  ]),
  Novedad('1.3.0', [
    'Módulo de Incidencias: reporta y sigue problemas del gym',
    'Eliminar suplementos (solo dueño, con validación contable)',
    'Fotos: botón para descartar fotos atascadas en la cola',
    'Diagnóstico de sincronización mejorado',
  ]),
  Novedad('1.2.9', [
    'Fotos con subida reanudable: si se corta el internet, continúa donde quedó',
    'Sincronización blindada: lock entre procesos, sin bloqueos de base de datos',
    'Búsquedas y reportes más rápidos: filtros directos en la base de datos',
    'Fotos optimizadas: la app descarga la versión ligera (WebP), no la original',
  ]),
  Novedad('1.2.5', [
    'Cierres de turno sincronizados: el dueño ve los cierres de todos los entrenadores en Historial de caja',
    'Cierre con desglose: aviso del efectivo pendiente antes de cerrar',
    'Búsqueda rápida: índice de texto completo (nombres y teléfonos), sin trabas',
    'Sincronización más robusta: tolera cortes largos y cada tabla avanza a su ritmo',
    'PIN más seguro: el bloqueo ya no se elude adelantando el reloj del teléfono',
    'Banner de sincronización más claro y vibración en acciones importantes',
  ]),
  Novedad('1.2.4', [
    'Incidencias bidireccionales: reporta y sigue su estado con el dueño',
    'Centro de diagnóstico y bandeja de incidencias',
    'Datos bancarios en Administración',
    'Seguridad: datos sensibles fuera del repositorio público',
  ]),
  Novedad('1.2.3', [
    'Resincronizar fotos implementado de verdad',
    'Sección "Sin stock" para el dueño',
    'Control de reintentos en fotos (sin bucles infinitos)',
    'Fix USD/CUP según el modelo real del negocio',
    'Seguridad: sin atajos inseguros para detectar al dueño',
  ]),
  Novedad('1.2.2', [
    'Control de inventario: alerta de stock en 0',
    'Historial de suplementos en la ficha del cliente',
    'Tu perfil (móvil/carnet) sobrevive reinstalaciones',
    'Seguridad: el rol se lee de donde debe',
    'Fixes: USD/CUP invertido, precio de menores automático',
  ]),
  Novedad('1.2.1', [
    'Categorías de suplementos',
    '12 bugs corregidos y mejoras en Actividad',
    'Fixes de auditoría de seguridad',
  ]),
  Novedad('1.2.0', [
    'Módulo de suplementos: inventario, stock y foto',
    'Ventas de suplementos en CUP y USD con tasa configurable',
    'Inscripción + venta de suplemento en un solo flujo',
    'Promo: 1 mes gratis por compra de suplemento',
    'Pendientes CUP/USD por entrenador con desglose',
    'Historial de ventas y anulación',
    'Dashboard según rol (dueño/entrenador)',
    'Administración reorganizada (secciones A–G)',
    '"Mi día" ahora es "Día del gym"',
    'Fix: "Último acceso" muestra actividad real',
  ]),
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
