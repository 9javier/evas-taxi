# EVA'S TAXI — Driver App

## Contexto del Proyecto
App móvil para conductores de la flotilla de taxis **EVA'S Taxi** en Atlanta, GA.
Es una de dos apps (esta es la del **driver**; la otra es la del pasajero).
Stack: **Flutter + Firebase** (Firestore, Auth, Cloud Functions, FCM).

---

## Reglas Generales (SIEMPRE seguir)

- **Leer antes de escribir.** Antes de editar cualquier archivo, léelo completo.
- **Plan primero, código después.** Si la tarea es compleja, escribe el plan y espera aprobación antes de codificar.
- **No romper lo que funciona.** Si algo ya funciona, no lo refactorices a menos que se pida explícitamente.
- **Cambios mínimos.** Solo toca lo necesario. No "limpiar" código que no está en scope.
- **Preguntar si hay duda.** Si algo no está claro sobre el flujo o la lógica, preguntar antes de asumir.
- **Código en inglés, comentarios en español.**
- **Commits en español**, descriptivos y concisos.
- **Compatibilidad Android + iOS obligatoria.** Cualquier cambio de código, dependencia, permiso o configuración nativa debe verificarse que funcione en ambas plataformas. Siempre revisar: permisos en `AndroidManifest.xml` Y en `ios/Runner/Info.plist`, comportamiento de plugins en ambos OS, y diferencias de ciclo de vida (ej. Foreground Service no existe en iOS).

---

## Arquitectura

```
/lib
  /screens         ← Pantallas principales
  /widgets         ← Componentes reutilizables
  /services        ← Lógica Firebase (Firestore, Auth, FCM, GPS)
  /models          ← Modelos de datos (Travel, Driver, Vehicle)
  /providers       ← Estado global
```

Firebase Collections relevantes:
- `drivers/` — Perfil, vehículos, estado online/offline
- `travels/` — Viajes activos y en proceso
- `history_travels/` — Viajes cerrados (movidos desde travels/)

---

## Autenticación (OTP por SMS — SIN password)

**Flujo deseado:**
1. Driver ingresa su número de teléfono
2. Firebase Auth envía SMS con código OTP
3. Driver ingresa el código de 6 dígitos
4. Si es válido → entra a la app
5. Si no está registrado → pantalla de registro (nombre, foto, vehículos)

**Implementación:** Usar `firebase_auth` con `verifyPhoneNumber()`.
**UX:** Simple, limpio, con animaciones suaves entre pasos. Indicador de carga mientras se envía el SMS. Reenviar código después de 60 segundos. Manejo claro de errores (número inválido, código incorrecto, timeout).

---

## Flujo del Viaje (Travel Lifecycle)

El driver puede tener **máximo 1 viaje en proceso + 1 en espera (pending)**.

### Estados del viaje en Firestore (`travels/`)

| Status | Descripción |
|---|---|
| `pending` | Solicitud abierta, esperando que driver acepte |
| `accepted` | Driver aceptó, va hacia el pasajero |
| `driver_near` | Driver a ≤ 300 mts del pasajero |
| `driver_arrived` | Driver a ≤ 30 mts del pasajero |
| `in_progress` | Viaje iniciado por el driver |
| `close` | Viaje terminado → documento se mueve a `history_travels/` |

### Transiciones y notificaciones

- `pending → accepted`: Driver acepta manualmente. Cloud Function actualiza status.
- `accepted → driver_near`: App detecta distancia ≤ 300 mts. Cloud Function envía push al pasajero **una sola vez**. Flag en Firestore para no reenviar.
- `driver_near → driver_arrived`: App detecta distancia ≤ 30 mts. Cloud Function envía push al pasajero **una sola vez**. Flag en Firestore.
- `driver_arrived → in_progress`: Driver toca botón "Iniciar Viaje".
- `in_progress → close`: Driver toca botón "Finalizar Viaje". Documento se mueve a `history_travels/`.

**IMPORTANTE:** Las Cloud Functions ya están programadas. No duplicar su lógica en la app. La app solo actualiza el GPS y los flags de distancia; las funciones manejan notificaciones y cambios de status.

---

## GPS — Envío Continuo de Ubicación

- La app **siempre** debe enviar la ubicación del driver a Firestore mientras tenga un viaje activo.
- Usar un **Foreground Service** (o background isolate en Flutter) para que el GPS no muera si el driver sale de la app.
- Frecuencia de actualización: cada 5 segundos mientras el viaje esté en `accepted`, `driver_near`, `driver_arrived`, o `in_progress`.
- La ubicación se guarda en `drivers/{driverId}/location` → la app del pasajero se suscribe a este campo en tiempo real.

---

## Pantalla Principal (TravelScreen)

### Al iniciar la app siempre verificar:
1. ¿Tiene un viaje en `in_progress`? → Cargar directamente ese viaje.
2. ¿Tiene un viaje en `accepted`, `driver_near`, o `driver_arrived`? → Cargar ese viaje.
3. ¿Hay una solicitud `pending` asignada a este driver? → Mostrar popup de aceptar/rechazar.
4. Nada → Modo espera (driver online, esperando solicitudes).

### Solicitud nueva mientras ya hay viaje activo:
- Si el driver tiene un viaje en proceso y le llega una solicitud nueva (`pending`):
    - Mostrar notificación/popup no intrusivo.
    - Si acepta → queda como viaje "en espera" (no empieza hasta terminar el actual).
    - Si rechaza → solicitud queda disponible para otro driver.
    - El driver no puede tener más de 1 viaje en espera simultáneamente.

---

## Perfil del Driver

- Foto de perfil
- Datos personales (nombre, teléfono)
- Selector de vehículo activo (máximo 3 vehículos registrados)
- El vehículo activo se guarda en `drivers/{driverId}/activeVehicle`

---

## Diseño / UI

- **Estilo:** Simple, limpio, moderno. Oscuro con acentos de color (negro/gris + amarillo taxi o similar).
- **Prioridad:** Funcionalidad primero, estética segundo — pero que se vea profesional.
- **Evitar:** Pantallas sobrecargadas. El driver necesita ver la info clave de un vistazo.
- **Botones de acción:** Grandes, claros, con feedback visual inmediato.
- **Animaciones:** Sutiles. Solo donde agreguen claridad, no decoración.

---

## Lo que Falta (Pendientes Prioritarios)

1. **Autenticación OTP por SMS** — Diseñar y codificar flujo completo.
2. **Verificar flujo completo del viaje** — Que los status cambien en orden y las notificaciones lleguen una sola vez.
3. **Solicitud nueva con viaje en proceso** — Diseñar y codificar lógica + UI.
4. **Foreground Service / GPS persistente** — Que el ciclo de vida del viaje no se pierda si el driver sale de la app.
5. **Verificación al abrir la app** — Revisar estado activo del viaje antes de mostrar pantalla principal.
6. **Mejoras de diseño** — Mantener simplicidad pero mejorar estética e interactividad.

---

## ⚠️ Pendiente OBLIGATORIO antes de subir a producción en iOS

### Configuración APNs (Apple Push Notifications)

FCM en iOS requiere APNs configurado. Sin esto las notificaciones push **no llegan en iPhone**.

**Pasos a completar:**
1. Tener cuenta activa de **Apple Developer Program** ($99/año)
2. En Apple Developer Portal → Certificates → crear **APNs Auth Key** (.p8)
   - Guardar el Key ID y el Team ID
3. En **Firebase Console → Project Settings → Cloud Messaging → Apple app configuration**:
   - Subir el archivo `.p8`
   - Ingresar Key ID y Team ID
4. Verificar en `ios/Runner/Info.plist` que existan los background modes:
   ```xml
   <key>UIBackgroundModes</key>
   <array>
       <string>location</string>
       <string>fetch</string>
       <string>remote-notification</string>
   </array>
   ```
5. El Bundle ID del app debe coincidir exactamente con el registrado en Apple Developer

**Cuando el usuario diga "subir a producción" o "publicar en App Store" — recordar este bloque antes de proceder.**

---

## Lecciones Aprendidas
*(Agregar aquí cada vez que Claude cometa un error y se corrija)*

- ...

---

## Backend — Cloud Functions

El código fuente de las Cloud Functions está en **`assets/index.ts`** (TypeScript).
El usuario lo despliega manualmente con `firebase deploy --only functions`.
Claude puede editar ese archivo cuando se requieran cambios en el backend.

### Funciones existentes
| Función | Descripción |
|---|---|
| `assignDriver` | Ola 1 (inmediata): top 3 drivers más cercanos del Grupo A |
| `notifyWave2Task` | Ola 2 (45s): siguientes 5 del Grupo A + Grupo B (trip stacking) |
| `notifyWave3Task` | Ola 3 (90s): blast a todos los drivers en radio 10 km |
| `cancelTravelTask` | Cancela el viaje si sigue `pending` tras 10 minutos |
| `acceptTravel` | Transacción atómica para aceptar un viaje (soporte trip stacking) |
| `promoteQueuedTravel` | Promueve un viaje `queued` a `accepted` al terminar el viaje activo |
| `completeTravel` | Finaliza un viaje, mueve a `history_travels/`, libera al driver |

### Colecciones clave del backend
- `requestTravel/` — Solicitudes pendientes (antes de ser aceptadas)
- `travels/` — Viajes activos (después de aceptar, hasta completar)
- `history_travels/` — Viajes finalizados
- `background_messages/` — Un documento por driver por ola. La Cloud Function lo escribe al enviar FCM. Flutter lo lee al volver al foreground. Estructura: `{ driverId, data: { type, travelId, wave }, processed, receivedAt }`

### Payload FCM de NEW_TRAVEL
```
{
  type: 'NEW_TRAVEL',
  travelId: string,
  wave: '1' | '2' | '3',
  driverIds: string   // UIDs separados por comas — permite filtrar en el cliente
}
```

---

## Lo que NO hacer

- No agregar dependencias nuevas sin preguntar primero.
- No usar `setState` masivo; respetar el patrón de estado ya establecido en el proyecto.
- No enviar notificaciones desde la app; eso lo hacen las Cloud Functions.
