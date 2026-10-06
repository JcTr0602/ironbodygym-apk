# Iron Body Gym — APK (Flutter, offline-first)

App Android para los entrenadores (Duany, Gabriel). Funciona sin
conexión en el gimnasio y sincroniza con el servidor al tener internet.

## Arquitectura

```
APK (SQLite local + cola de ops)
   ↕  Supabase (sync_ops, espejos, Storage)
Puente (cron cada 1 min, en el servidor)
   ↕  gym.db  ←→  bot de Telegram
```

- **Subida**: la app encola operaciones con `op_uuid` (idempotente) en
  `sync_ops`. El puente las aplica a `gym.db`.
- **Bajada**: la app descarga espejos (`sync_clientes`, `sync_pagos`,
  `sync_pagos_diarios`) y borrados por `sync_seq` incremental.
- **Fotos**: se suben a Storage (`fotos-clientes`) cuando la inscripción
  ya fue aplicada; el puente las guarda en `gym.db`.
- **Login**: solo nombre de usuario + contraseña (`Gabriel` →
  `gabriel@ironbody.gym` vía `usernameToEmail`, igual que en el servidor).

## Compilar

```bash
export ANDROID_HOME=~/android-sdk
export PATH=$PATH:~/flutter-sdk/flutter/bin
cd ~/workspace/ironbody-apk
flutter pub get
flutter build apk --release
# APK en: build/app/outputs/flutter-apk/app-release.apk
```

## Estructura

- `lib/main.dart` — entrada, sesión, timer de sincronización (60 s).
- `lib/config.dart` — URL Supabase, anon key, datos de transferencia.
- `lib/auth.dart` — login por nombre de usuario.
- `lib/localdb.dart` — SQLite local (espejos, cola, fotos, watermark).
- `lib/sync.dart` — motor de sincronización.
- `lib/negocio.dart` — búsqueda, vencen hoy, atrasados (espejo del bot).
- `lib/ui/` — pantallas.

## Versionado

`pubspec.yaml`: `version: 1.0.0+1` (incrementar `+N` en cada build).
