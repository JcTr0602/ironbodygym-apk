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
  Novedad('1.0.6', [
    '🔄 Rechazadas: ahora puedes ver el motivo y reenviar la operación',
    '✅ Confirmación de cobro a pantalla completa (check grande, monto, vencimiento)',
    '📋 Auditoría: quién hizo qué y cuándo (solo dueño)',
    '💰 Pago rápido desde vencidos (ya existía, mejorado)',
  ]),
  Novedad('1.0.5', [
    '🔄 La APK ahora verifica si el servidor rechazó una operación (no más falso "aplicada")',
    '🐛 Fix: clientes nuevos desde la APK ahora aparecen correctamente',
    '📋 Diálogo "Novedades" al actualizar',
  ]),
  Novedad('1.0.4', [
    '🔧 Fix crítico: el botón de sincronizar ahora sí funciona (bug _running)',
    '⚡ Al archivar, el cliente desaparece al momento (actualización optimista)',
    '🔄 La descarga se repite hasta estar al día (no más falso "sincronizado")',
    '🐛 Fix error 400 en gastos que bloqueaba la descarga',
    '👆 Detalle tocable de operaciones con errores en lenguaje claro',
    '🎨 Iniciales en vez de 👤 para clientes sin foto',
    '🌈 Colores: rojo vencido, amarillo por vencer, verde al día',
    '⬇️ Pull-to-refresh en la lista de clientes',
    '✨ Login con animación, recuerda usuario y muestra versión',
  ]),
  Novedad('1.0.3', [
    '🛡️ Sección Administración (solo Jc): estadísticas, precios, usuarios APK, pendiente a entregar, gastos, cierre de caja y exportar',
    '💰 Pendiente a entregar ahora cuenta también lo que aún no se sincroniza',
    '📊 Mi Turno con historial diario, desglose por método y última entrega confirmada',
    '📋 Botón Actualizar en Buscar y miniaturas que se descargan solas',
    '🔄 El botón Atrasados ahora abre los atrasados de menos de 30 días',
    '✅ Nueva tarjeta "Pagos realizados" en el inicio',
    '🛠️ Corregir pagos (monto/fecha o anular) desde la ficha, solo admin',
    '⛔ Alerta de duplicados por carnet al inscribir',
    '🧾 Gastos del gym y cierre de caja diario',
    '🔐 La sesión ahora refresca el token antes de pedirte entrar de nuevo',
    '📤 Si una operación es rechazada por el servidor, ya no bloquea a las demás',
  ]),
  Novedad('1.0.2', [
    '🎂 Cumpleaños de la semana (la fecha sale del carnet)',
    '⚙️ Nueva sección de Ajustes: foto de perfil, móvil, carnet, tema',
    '🔑 Cambia tu contraseña dentro de la app',
    '📷 Las fotos se suben por partes: si se corta la conexión, continúan donde quedaron',
    '📊 La sincronización muestra el progreso de lo pendiente por subir y bajar',
    '⏰ Aviso si llevas más de 8 horas sin subir cambios',
    '🔄 Renovación rápida con un toque (también desde la papelera)',
    '📷 Cambia la foto de un cliente: cámara o galería',
    '🔀 Ordena las listas por nombre, vencimiento o días restantes',
    '🗑️ Solo Jc puede eliminar definitivamente desde la papelera',
  ]),
  Novedad('1.0.1', [
    '🔍 Buscar muestra todos los clientes, con estado y días restantes',
    '🗓️ Períodos de pago: semana, quincena y días personalizados',
    '🗑️ Papelera recuperable',
    '📷 Foto del cliente en ficha y listas',
    '💰 Pago rápido desde las listas',
    '💰 Pendiente a entregar con desglose',
    '🔄 Sincronización detallada con hora de última vez',
  ]),
];

/// Muestra "Lo Nuevo" una sola vez tras actualizar. Devuelve true si la mostró.
Future<bool> mostrarNovedadesSiHay(BuildContext context) async {
  final perfil = PerfilService.instance;
  final vista = await perfil.getUltimaVersionVista();
  if (vista == AppConfig.appVersion) return false;
  await perfil.setUltimaVersionVista(AppConfig.appVersion);
  final nuevas = novedades
      .where((n) =>
          vista == null || n.version.compareTo(vista) > 0)
      .toList();
  if (nuevas.isEmpty || !context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('🎉 Lo nuevo en esta versión'),
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
