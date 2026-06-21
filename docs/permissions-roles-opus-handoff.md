# Handoff — Permisos y Roles (lo que falta) · para otro agente de IA

> Continuación de [`permissions-roles-opus.md`](permissions-roles-opus.md). Lee primero la sección
> **[Estado de implementación](permissions-roles-opus.md#estado-de-implementación)** de ese documento:
> ahí está marcado lo ya hecho (Fases 1, 3, 4, 6 + backbone de expansión) y lo pendiente.
>
> Estado verificado al cierre: **backend 45/45 tests verdes**, `dotnet build` y `ng build` correctos.
> Quedan **3 fases**: **2** (authz por recurso), **5** (frescura de token), **8** (auditoría). Orden
> recomendado: **2 → 5 → 8** (la 2 es la más crítica de seguridad).

---

## Contexto imprescindible (aprendido durante la implementación)

Antes de tocar nada, interioriza estos 5 hechos o romperás algo:

1. **El JWT lleva el conjunto de permisos YA EXPANDIDO.** La expansión transitiva vive en un solo lugar:
   [`PermissionExpander`](../backend/src/ConsultoraPro.Domain/Security/PermissionExpander.cs) +
   `PermissionCatalog.Implies` ([`PermissionCatalog.cs`](../backend/src/ConsultoraPro.Domain/Security/PermissionCatalog.cs)).
   `AuthService.GetRoleAndPermissionsAsync` emite el set expandido. Si añades claves/implicaciones, NO
   dupliques lógica de expansión: amplía `Implies` y todo lo demás se propaga. Ref: doc §3.2.
2. **Ámbito por módulo:** `<modulo>.ver` = "ver asignados" (acceso base); `<modulo>.ver.todos` amplía a
   todos. La decisión se evalúa con `ICurrentUserService.HasFullProjectAccessFor("modulo")`
   ([`CurrentUserService.cs`](../backend/src/ConsultoraPro.API/Services/CurrentUserService.cs)), que es
   `flag global del rol` **OR** `tiene <modulo>.ver.todos`. Ref: doc §3, §5.
3. **El frontend redirige TODOS los 403 a `/sin-acceso`**
   ([`error` handler en interceptors](../frontend/src/app/core/interceptors)). Por eso el caso
   "necesita solicitud" de credenciales devuelve **409** (no 403) con código `REVELACION_REQUIERE_SOLICITUD`.
   Si en Fase 5 devuelves un 401 "token-stale", trátalo aparte en el interceptor (no como logout ciego).
4. **EF usa migraciones reales** (`Database.MigrateAsync()` en
   [`DependencyInjection.InitializeDatabaseAsync`](../backend/src/ConsultoraPro.Infrastructure/DependencyInjection.cs)).
   Tablas/columnas nuevas requieren `dotnet ef migrations add`. **Gotcha:** si el API está corriendo,
   bloquea los DLL y `ef`/`build` fallan con MSB3027 (file lock) — y `--no-build` genera migraciones
   VACÍAS usando ensamblados viejos. Compila SIEMPRE antes de generar, y para el API si está corriendo.
   Los permisos del catálogo se siembran como **datos** (no migración) vía
   [`SecuritySeeder`](../backend/src/ConsultoraPro.Infrastructure/Data/Seed/SecuritySeeder.cs).
5. **`ICurrentUserService` se puede inyectar en la capa Application** (interfaz en Application, impl en API).
   Ya se usa en `AlertaService`. Úsalo para leer el usuario/permisos en servicios.

---

## FASE 2 — Autorización por recurso (anti-IDOR) · PRIORIDAD MÁXIMA

**Referencia en el plan:** §9.2 (IProjectScope), §9.3 (AuthorizationHandler por recurso, ⭐),
§6 (herencia de pestañas), §11 G1/G12 (riesgos), §14 fila "2", §15 casos 1-3, 12.

**Qué existe hoy:** el scope por proyecto se aplica **a mano** en cada servicio con el patrón
`if (!HasFullProjectAccessFor("modulo")) { ...ProyectoMiembros.Any(... UserId) }`. Cubre listas y by-id en:
`ProyectoService`, `ClienteService`, `AmbienteService`, `AmbienteTestUserService`, `TableroService`,
`TarjetaService`, `ManagementService` y `ScreenshotsController`. Funciona, pero es fácil olvidarlo en un
módulo nuevo y **hay un hueco real: las credenciales NO se filtran por proyecto asignado** (su servicio
nunca lo hizo — ver `CredencialService.GetAllAsync` / `GetByIdAsync` / `RevealAsync`).

**Tareas:**
1. Crear `IProyectoScoped { Guid ProyectoId { get; } }` (Domain) e implementarlo en `Ambiente`,
   `Repositorio`, `Credencial`, `Screenshot`, `Tablero`, etc. (todos ya tienen `ProyectoId`).
2. Crear un helper central `IProjectScope` (doc §9.2): `VeTodos(modulo)`, `ProyectosAsignadosAsync()`,
   `FiltrarPorAcceso<T>(IQueryable<T>, selector, modulo)`. Reemplazar los `Where` ad-hoc por este helper.
3. **Cerrar el hueco de credenciales:** filtrar `CredencialService` por proyectos asignados igual que el
   resto (usar `HasFullProjectAccessFor("credenciales")` o `"proyectos"` — decidir y documentar; recomiendo
   `"proyectos"` porque el acceso a credenciales sigue la membresía del proyecto). Aplica a list, by-id,
   reveal, y a `CrearSolicitudAsync` (no debería poder solicitar sobre un proyecto ajeno).
4. (Opcional, más robusto) `AuthorizationHandler<ModuloOperationRequirement, IProyectoScoped>` (doc §9.3)
   para los endpoints `{id}`.
5. **Devolver 404 (no 403)** cuando el recurso existe pero está fuera de ámbito (doc §11 G12), para no
   filtrar su existencia.

**Criterios de aceptación (doc §15):** tests 2 (lista respeta asignados), 3 (IDOR by-id → 404), 12 (toda
entidad ligada a proyecto implementa `IProyectoScoped`). Añadir un test que falle si un módulo nuevo no usa
el filtro central.

**Gotcha:** `credenciales.ver.todos` NO existe como clave (Credenciales usa niveles, no ámbito). Para el
scope de credenciales reutiliza el ámbito de `proyectos` (`HasFullProjectAccessFor("proyectos")`).

---

## FASE 5 — Frescura de token (revocación) · PRIORIDAD MEDIA

**Referencia en el plan:** §8.2 (columna `PermVersion`), §11 G2, §11.1, §11.2 (detalle), §14 fila "5",
§15 caso 7.

**Problema:** el JWT vive 8 h ([`AuthService.GenerateTokenAsync`](../backend/src/ConsultoraPro.API/Services/AuthService.cs)).
Cambiar permisos de un rol o el rol de un usuario NO surte efecto hasta el próximo login. Sin revocación.

**Tareas:**
1. Migración EF: `ALTER TABLE AspNetUsers ADD PermVersion int NOT NULL DEFAULT 0` y lo mismo en
   `AspNetRoles` (añadir `int PermVersion` a [`ApplicationUser`](../backend/src/ConsultoraPro.Domain/Models/ApplicationUser.cs)
   y [`ApplicationRole`](../backend/src/ConsultoraPro.Domain/Models/ApplicationRole.cs)).
2. Emitir un claim `permVersion` en el JWT (combinar user+rol, p. ej. `user.PermVersion ^ role.PermVersion`
   o concatenado).
3. Incrementar `PermVersion`:
   - del **rol** en `RolesController.UpdatePermisos` / `Update` (cambios de permisos/flags).
   - del **usuario** en `UsuariosController.Update` (cambio de rol) y en cualquier asignación sensible.
4. Middleware ligero (registrar en [`Program.cs`](../backend/src/ConsultoraPro.API/Program.cs) tras
   `UseAuthentication`) que compara el claim `permVersion` con la BD (cacheable con `IMemoryCache`, ya
   registrado). Si difiere → 401 con código `token-stale`.
5. **Frontend:** en el interceptor, tratar 401 `token-stale` llamando a `refreshCurrentUser()` /
   re-login suave en vez del logout genérico. Hoy 401 → logout (revisar
   [`auth.interceptor.ts`](../frontend/src/app/core/interceptors/auth.interceptor.ts)).
6. (Opcional) refresh token corto + endpoint de "revocar sesiones" (doc §11.2). Mínimo viable: pasos 1-5.

**Criterio de aceptación (doc §15 caso 7):** cambiar el rol/permiso incrementa `PermVersion` ⇒ la siguiente
petición con el token viejo responde 401 `token-stale`.

**Gotcha:** no rompas el flujo Google OAuth ni el break-glass; el claim se añade en el mismo sitio que
`role`/`accesoTotalProyectos`/`permisos`.

---

## FASE 8 — Auditoría de seguridad y métricas · PRIORIDAD BAJA

**Referencia en el plan:** §12 (auditoría y observabilidad), §11 (qué auditar por riesgo), §14 fila "8".

**Tareas:**
1. Tabla/entidad `AuditoriaSeguridad { Actor, Accion, Entidad, EntidadId, Antes, Despues, Ip, Fecha }`
   (+ migración EF). Reutiliza el patrón de [`AuditoriaCredencial`](../backend/src/ConsultoraPro.Domain/Models/AuditoriaCredencial.cs)
   (que ya audita revelaciones — NO dupliques eso).
2. Registrar: cambios de permisos de rol, asignación de rol a usuario, asignación de proyectos,
   aprobación/rechazo de solicitudes de revelación, y los `403/Forbid` en operaciones sensibles.
3. Métrica: contador de `Forbid` por endpoint (detecta config incorrecta o sondeo). Un middleware o un
   `IAuthorizationMiddlewareResultHandler` sirve.
4. (Opcional) superficie de lectura en UI para Gerencia/Arquitecto.

---

## Riesgos del plan aún NO mitigados en código (revisar al implementar)

De §11, ya cubiertos: G1 (parcial, falta centralizar + credenciales), G5 (niveles+solicitud),
G6 (servidor autoriza), G8 (Google sin rol = solo dashboard). **Pendientes de endurecer:**

- **G2** (token obsoleto) → Fase 5.
- **G3 / G4** (escalada vía `roles.editar` / `usuarios.asignar-proyectos`): hoy NO se impide que un usuario
  con `roles.editar` se edite su propio rol o se conceda permisos. Añadir guardas en `RolesController` /
  `UsuariosController` (prohibir auto-edición de rol/permisos; los roles de sistema ya están protegidos por
  `EsSistema`). Auditar (Fase 8).
- **G7** (over-posting): revisar que los DTO de `UsuariosController.Update` no permitan auto-promoción
  (el cambio de rol debería exigir un permiso distinto de la edición de datos).
- **G11** (endpoints sin `[Authorize]`): añadir un test que enumere acciones de controller sin atributo de
  autorización explícito (doc §15 caso 10). El `DefaultPolicy` global ya exige autenticación, pero conviene
  el test.

---

## Decisiones abiertas (confirmar con el usuario antes de implementar)

Listadas al final de [`permissions-roles-opus.md`](permissions-roles-opus.md#decisiones-abiertas):
1. **Multi-rol por usuario** (hoy `FirstOrDefault` → un solo rol). Si se quiere, unir permisos de todos los
   roles y tomar el ámbito más permisivo. Toca `AuthService.GetRoleAndPermissionsAsync` y
   `UsuariosController`.
2. **TTL del access token** (hoy 8 h) y TTL de revelación temporal (hoy 15 min, constante en
   `CredencialService.RevelacionTemporalTtl`).
3. **Doble aprobación** para conceder permisos sensibles (Credenciales full / Roles) — no implementado.

---

## Cómo verificar (comandos)

```bash
# backend (desde backend/). Si el API está corriendo, páralo primero o el build falla por file-lock.
dotnet build ConsultoraPro.slnx
dotnet test tests/ConsultoraPro.Tests/ConsultoraPro.Tests.csproj      # 45 tests hoy
dotnet ef migrations add <Nombre> -p src/ConsultoraPro.Infrastructure -s src/ConsultoraPro.API   # SIN --no-build

# frontend (desde frontend/)
npx ng build --configuration development
```

No hay specs de frontend configuradas (`ng test` existe pero sin specs); la verificación de UI es por
compilación o levantando la app. La migración se aplica sola al arrancar el API (`MigrateAsync`).
