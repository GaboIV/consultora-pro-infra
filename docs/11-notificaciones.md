# 11 · Sistema de notificaciones (campana + correo)

Implementado el 2026-07-02. Notificaciones en la app (campana del header) y por correo,
con preferencias por usuario, agrupación anti-spam y proveedor de correo intercambiable.

## Arquitectura

```
Evento de negocio (crear usuario, asignar tarjeta, mover tarjeta, ...)
        │
        ▼
INotificacionService.PublicarAsync (Application)   ← punto ÚNICO de emisión
        │  resuelve preferencias por destinatario y excluye al actor
        ├──► tabla Notificaciones          → campana (polling de /api/notificaciones/resumen)
        └──► tabla CorreosPendientes (outbox)
                    │
                    ▼
        CorreoPendienteProcessor (BackgroundService, cada 30 s)
                    │  agrupa por usuario lo vencido; 1 fila → correo individual,
                    │  varias → correo "resumen de actividad"
                    ▼
        IEmailSender: Console | Smtp (Gmail) | Brevo | Resend
```

Piezas principales:

| Pieza | Ubicación |
|---|---|
| Catálogo de tipos (defaults, agrupables, seguridad) | `Domain/Notificaciones/NotificacionCatalog.cs` |
| Entidades `Notificacion`, `PreferenciaNotificacion`, `CorreoPendiente` | `Domain/Models` |
| Emisión + preferencias | `Application/Services/NotificacionService.cs` |
| Plantilla HTML de correos (tema oscuro de la app) | `Application/Notificaciones/EmailTemplateBuilder.cs` |
| Outbox processor | `Infrastructure/Notificaciones/CorreoPendienteProcessor.cs` |
| Proveedores de correo | `Infrastructure/Email/*` |
| API | `API/Controllers/NotificacionesController.cs` |
| Frontend: campana | `layout/shell/notificaciones-dropdown` |
| Frontend: preferencias | `features/notification-settings` (ruta `/configuracion/notificaciones`) |

## Eventos notificados

| Evento | Tipo | Destinatarios | Correo |
|---|---|---|---|
| Cuenta creada | `UsuarioBienvenida` | el nuevo usuario | obligatorio |
| Admin restablece tu contraseña | `PasswordCambiadaPorAdmin` | el usuario | obligatorio |
| Cambias tu contraseña | `PasswordCambiada` | el usuario | obligatorio |
| Te cambian el rol | `RolCambiado` | el usuario | default sí |
| Te asignan/retiran proyectos | `ProyectoAsignado` / `ProyectoDesasignado` | el usuario (1 aviso por lote) | sí / no |
| Te agregan a un tablero | `TableroCompartido` | miembros nuevos | sí |
| Te asignan/quitan de una tarjeta | `TarjetaAsignada` / `TarjetaDesasignada` | responsables nuevos/quitados | sí / no |
| Mueven una tarjeta tuya | `TarjetaMovida` | responsables + creador | **agrupado** |
| Completan/reabren una tarjeta tuya | `TarjetaCompletada` | responsables + creador | **agrupado** |
| Comentan una tarjeta tuya | `TarjetaComentario` | responsables + creador (menos el autor) | **agrupado** |
| Solicitud de revelación de credencial | `CredencialSolicitud` | usuarios con `credenciales.solicitud.aprobar` | sí |
| Resuelven tu solicitud | `CredencialSolicitudResuelta` | el solicitante | sí |

## Anti-spam

- **Actor excluido**: nadie recibe avisos de sus propias acciones (salvo los de seguridad
  sobre su propia cuenta, con `IncluirActor = true`).
- **Ventana de agrupación** (`Notificaciones:VentanaAgrupacionMinutos`, default 10): los tipos
  agrupables no envían el correo al instante; el processor espera la ventana y, si hay varios
  pendientes del mismo usuario, manda un solo correo resumen.
- **Deduplicación** (`DedupKey`): mover la misma tarjeta 5 veces dentro de la ventana produce
  UNA fila en el outbox (se actualiza el contenido con el último estado; la fecha programada
  no se extiende, así el resumen sale como máximo 10 min después del primer evento).
- **Lotes**: asignar 8 proyectos a un usuario genera un solo aviso con la lista.
- **Preferencias por usuario**: cada tipo se puede apagar por canal (app/correo) en
  `/configuracion/notificaciones`, excepto el correo de los avisos de seguridad.
- La campana solo hace polling del contador (`GET /notificaciones/resumen`, cada 60 s);
  la lista se carga al abrirla.

## Configuración de correo

Sección `Email` de `appsettings.json` (todo sobreescribible por env vars `Email__*`):

```jsonc
"Email": {
  "Provider": "Console",            // Console | Smtp | Brevo | Resend
  "From": "no-reply@tudominio.com",
  "FromName": "ConsultoraPro",
  "FrontendBaseUrl": "http://localhost:4200",  // base de los links de los correos
  "Smtp":   { "Host": "smtp.gmail.com", "Port": 587, "User": "", "Password": "", "EnableSsl": true },
  "Brevo":  { "ApiKey": "" },
  "Resend": { "ApiKey": "" }
}
```

### Desarrollo local

`Provider: Console` (default): los correos se imprimen en el log del backend, no se envía nada.

### Pruebas locales con Gmail

1. Cuenta Google → Seguridad → verificación en 2 pasos activada.
2. Crear una **contraseña de aplicación**: <https://myaccount.google.com/apppasswords>
   (16 caracteres, sin espacios).
3. En `appsettings.Development.json` (o user-secrets, mejor):

```json
"Email": {
  "Provider": "Smtp",
  "From": "tucuenta@gmail.com",
  "FromName": "ConsultoraPro (dev)",
  "Smtp": { "User": "tucuenta@gmail.com", "Password": "xxxxxxxxxxxxxxxx" }
}
```

> Gmail exige que `From` sea la misma cuenta autenticada. Límite ~500 correos/día — solo dev.

### Producción con dominio propio (Brevo o Resend)

Ambos requieren **verificar el dominio** (registros SPF/DKIM/DMARC en el DNS) para que el
`From` sea `no-reply@tudominio.com` y no caiga en spam:

- **Brevo**: panel → Senders & Domains → autenticar dominio → generar API key (SMTP & API).
  Plan gratis: 300 correos/día.
- **Resend**: panel → Domains → add domain → copiar registros DNS → API key.
  Plan gratis: 3 000 correos/mes.

En el servidor, variables del `.env` que consume `docker-compose.deploy.yml`:

```bash
EMAIL_PROVIDER=Brevo            # o Resend
EMAIL_FROM=no-reply@tudominio.com
EMAIL_FROM_NAME=ConsultoraPro
BREVO_API_KEY=xkeysib-...       # o RESEND_API_KEY=re_...
# FRONTEND_BASE_URL ya existe (links de los correos)
```

## Operación

- Migración: `AddNotificaciones` (tablas `Notificaciones`, `PreferenciasNotificacion`,
  `CorreosPendientes`); se aplica sola al arrancar (`MigrateAsync`).
- Reintentos: backoff exponencial (2, 4, 8, 16 min); tras `MaxIntentos` (5) la fila queda
  en `Estado = Error` con `UltimoError` para diagnóstico. Correos a usuarios inactivos o
  sin email quedan `Cancelado`.
- Los fallos al notificar **nunca** rompen la operación de negocio (try/catch + log en
  `PublicarAsync`).
- Para depurar el outbox: `SELECT * FROM CorreosPendientes ORDER BY FechaCreacion DESC;`

## Extender

Para notificar algo nuevo: agregar el valor a `TipoNotificacion` + su definición en
`NotificacionCatalog` (grupo, defaults, agrupable, seguridad) y llamar a
`INotificacionService.PublicarAsync` desde el punto de negocio. No se necesita tocar el
procesador, la API ni la pantalla de preferencias (se alimentan del catálogo).
