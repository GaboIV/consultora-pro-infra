# Permisos y Roles — Diseño Totalmente Configurable (Opus)

> Propuesta de arquitectura para hacer **configurable al 100 %** el acceso a cada módulo y a cada
> elemento de detalle dentro de los módulos de ConsultoraPro, partiendo de lo que **ya existe** en el
> código y cerrando las brechas de seguridad detectadas.
>
> Documento hermano: [`10-permissions-roles-bigpickle.md`](10-permissions-roles-bigpickle.md). Este
> documento ("opus") prioriza el anclaje al código actual, la **autorización por recurso** (anti-IDOR)
> y un plan de migración incremental sin romper lo existente.

## Índice

- [0. TL;DR](#0-tldr)
- [1. Estado actual (AS-IS)](#1-estado-actual-as-is)
- [2. Principios de diseño](#2-principios-de-diseño)
- [3. Modelo conceptual: acción × ámbito × nivel](#3-modelo-conceptual-acción--ámbito--nivel)
- [4. Catálogo de permisos propuesto](#4-catálogo-de-permisos-propuesto)
- [5. Mapeo por módulo (lo que mapeaste, reconciliado)](#5-mapeo-por-módulo-lo-que-mapeaste-reconciliado)
- [6. Detalle de Proyecto y herencia de permisos](#6-detalle-de-proyecto-y-herencia-de-permisos)
- [7. Credenciales: niveles y flujo de solicitud](#7-credenciales-niveles-y-flujo-de-solicitud)
- [8. Modelo de datos](#8-modelo-de-datos)
- [9. Enforcement en backend](#9-enforcement-en-backend)
- [10. Enforcement en frontend](#10-enforcement-en-frontend)
- [11. Brechas de seguridad y mitigaciones](#11-brechas-de-seguridad-y-mitigaciones)
- [12. Auditoría y observabilidad](#12-auditoría-y-observabilidad)
- [13. Semillas y migraciones](#13-semillas-y-migraciones)
- [14. Plan de implementación por fases](#14-plan-de-implementación-por-fases)
- [15. Matriz de pruebas](#15-matriz-de-pruebas)
- [Anexo A — Catálogo completo de claves](#anexo-a--catálogo-completo-de-claves)

---

## Estado de implementación

> Actualizado el 2026-06-21. Backend compila, **45/45 tests** verdes; frontend `ng build` correcto.

**Implementado (Fase 1 + Fase 3 + Fase 4 + Fase 6 + backbone de expansión):**

- ✅ Catálogo extendido ([`PermissionCatalog.cs`](../backend/src/ConsultoraPro.Domain/Security/PermissionCatalog.cs)):
  claves de ámbito `<modulo>.ver.todos`, niveles de credenciales (`credenciales.nivel.{full,ver-todo,basico}` +
  `credenciales.solicitud.aprobar`), `screenshots.{ver,editar}`, módulo **Usuarios** (`usuarios.{ver,editar,cambiar-password,eliminar,asignar-proyectos}`),
  mapa `Implies` y `ScopedModules`.
- ✅ [`PermissionExpander`](../backend/src/ConsultoraPro.Domain/Security/PermissionExpander.cs): cierre transitivo
  de implicaciones, usado por el JWT y por `CurrentUserService` (una sola fuente de verdad).
- ✅ JWT emite el **conjunto expandido** ([`AuthService.cs`](../backend/src/ConsultoraPro.API/Services/AuthService.cs)):
  cliente y servidor evalúan lo mismo; el frontend sigue funcionando sin tocar sus checks existentes.
- ✅ Ámbito **por módulo**: `ICurrentUserService.HasFullProjectAccessFor(modulo)` (flag global del rol **o**
  `<modulo>.ver.todos`), cableado en los 7 servicios con scope de proyecto y en `ScreenshotsController`.
- ✅ Screenshots ahora exige `screenshots.ver`/`screenshots.editar` (antes sin permiso propio).
- ✅ Usuarios separado de Roles: `UsuariosController` migrado a `usuarios.*` (incl. `cambiar-password`).
- ✅ Migración de datos idempotente ([`SecuritySeeder.MigrateLegacyGrantsAsync`](../backend/src/ConsultoraPro.Infrastructure/Data/Seed/SecuritySeeder.cs))
  que traduce concesiones legacy → claves nuevas preservando el comportamiento (solo agrega, nunca revoca).
- ✅ Frontend alineado: rutas/menú/búsqueda/pestañas de Usuarios y Screenshots, fetch condicional de screenshots.
- ✅ Tests de expansión ([`PermissionExpanderTests.cs`](../backend/tests/ConsultoraPro.Tests/PermissionExpanderTests.cs)).

**Implementado (Fase 3 — Credenciales por niveles + flujo de solicitud):**

- ✅ Entidad [`SolicitudRevelacionCredencial`](../backend/src/ConsultoraPro.Domain/Models/SolicitudRevelacionCredencial.cs)
  + enum `EstadoSolicitudRevelacion` + migración EF `AddSolicitudRevelacionCredencial`.
- ✅ Repositorio [`SolicitudRevelacionRepository`](../backend/src/ConsultoraPro.Infrastructure/Repositories/SolicitudRevelacionRepository.cs)
  (pendiente / vigente / bandeja / por solicitante).
- ✅ Revelación **re-validada en servidor** ([`CredencialService.RevealAsync`](../backend/src/ConsultoraPro.Application/Services/CredencialService.cs)):
  nivel ver-todo/full revela directo; nivel básico exige una **aprobación vigente (TTL 15 min)** o lanza
  `RevelacionRequiereSolicitudException`. El claim del JWT nunca basta por sí solo.
- ✅ Endpoints: `POST {id}/solicitudes`, `GET mis-solicitudes`, `GET solicitudes` (bandeja del aprobador),
  `POST solicitudes/{id}/aprobar|rechazar`. La policy de `revelar` se relajó a `credenciales.ver` y la
  decisión real se toma en el servicio; el "necesita solicitud" devuelve **HTTP 409** (no 403, para evitar
  el redirect global del frontend) con código `REVELACION_REQUIERE_SOLICITUD`.
- ✅ Notificaciones vía el feed de Alertas ([`AlertaService`](../backend/src/ConsultoraPro.Application/Services/AlertaService.cs)):
  pendientes para el aprobador; aprobación vigente / rechazo reciente para el solicitante.
- ✅ Auditoría: cada revelación (directa o por solicitud) se registra en `AuditoriaCredencial` con el detalle
  de la solicitud que la autorizó.
- ✅ Frontend: botón Revelar visible para `credenciales.ver`; ante 409 ofrece crear la solicitud; panel de
  bandeja del aprobador ([`SolicitudesRevelacionPanelComponent`](../frontend/src/app/features/credenciales/solicitudes-revelacion-panel.component.ts))
  con aprobar/rechazar, embebido en la página de Credenciales y protegido por `credenciales.solicitud.aprobar`.
- ✅ Tests del gate de revelación ([`CredencialRevealFlowTests.cs`](../backend/tests/ConsultoraPro.Tests/CredencialRevealFlowTests.cs)).

**Implementado (Fase 6 — UI de administración de roles):**

- ✅ Editor de permisos rediseñado ([`rol-permisos.component.ts`](../frontend/src/app/features/equipo/roles/rol-permisos.component.ts)),
  data-driven a partir del catálogo:
  - **Credenciales** se configura con un único radio de nivel (Sin acceso / Datos básicos / Ver todo /
    Acceso total); se ocultan las claves implícitas/legacy (`credenciales.ver/revelar/crear/editar/solicitud.aprobar`)
    y al guardar solo se persiste la clave del nivel elegido (el resto se deriva por implicación en el JWT).
  - **Módulos con ámbito** (clientes, proyectos, ambientes, repositorios) muestran un selector
    "Ver: Sin acceso / Asignados / Todos" (mapea `<modulo>.ver` y `<modulo>.ver.todos`) más checkboxes para
    el resto de acciones; se ocultan las claves `.ver`/`.ver.todos` sueltas.
  - El resto de módulos siguen como checkboxes simples.
  - Datos legacy se mapean al control equivalente al abrir el editor (p. ej. `credenciales.revelar` → "Ver todo").
- ✅ Asignación de proyectos por usuario ya existía (`UsuariosController` + diálogo en la lista de usuarios),
  ahora bajo el permiso `usuarios.asignar-proyectos`.

**Pendiente (próximos incrementos, descritos abajo):**

- ⏳ Fase 2 explícita: `AuthorizationHandler` por recurso + `IProjectScope` central (hoy el scope se aplica
  con el patrón per-servicio ya existente, que cubre listas y by-id, pero conviene centralizarlo).
  Nota: las **credenciales** aún no se filtran por proyecto asignado (su servicio nunca lo hizo); conviene
  abordarlo aquí.
- ⏳ Fase 5: `permVersion` + revocación de sesiones + refresh token corto (migración de esquema).
- ⏳ Fase 8: tabla `AuditoriaSeguridad` + métricas de `Forbid`.

> **Nota de migración:** tras desplegar, los usuarios con sesión activa deben re-loguearse para que su
> token incluya las claves nuevas (`usuarios.ver`, etc.). El reseed de arranque concede esas claves a los
> roles antes del próximo login, por lo que el efecto es transitorio y se autocorrige.

---

## 0. TL;DR

1. **Conservar** el modelo actual `Permiso` / `RolPermiso` / claim `permisos` y la autorización por
   _policy_ (`[Authorize(Policy = "clave")]`). Funciona y es la base.
2. **Añadir tres dimensiones ortogonales** a cada permiso: **acción** (ver/crear/editar/…),
   **ámbito** (`todos` vs `asignados`) y, donde aplica, **nivel** (Credenciales: full / ver-todo / básico).
3. **Mover el ámbito de proyecto desde el rol al permiso**: hoy `AccesoTotalProyectos` es un único flag
   de rol; debe poder configurarse _por módulo_ (p. ej. ver todos los clientes pero solo proyectos asignados).
4. **Introducir autorización por recurso** (`AuthorizationHandler<Requirement, TRecurso>`) para cerrar el
   hueco de IDOR/BOLA: hoy el _scope_ se filtra a mano en cada servicio y es fácil olvidarlo.
5. **Tratar el JWT como caché de UX, nunca como fuente de verdad de autorización** para operaciones
   sensibles. Añadir versión de permisos (`permVersion`) y revocación de sesiones.
6. **Cerrar gaps concretos**: Screenshots no tiene permiso en el catálogo; el nivel "básico sin password
   + solicitud" de Credenciales no existe; el usuario tiene un solo rol (`FirstOrDefault`).

---

## 1. Estado actual (AS-IS)

Lo que ya está implementado (no reinventar):

| Pieza | Archivo | Qué hace |
|---|---|---|
| Catálogo de permisos | [`PermissionCatalog.cs`](../backend/src/ConsultoraPro.Domain/Security/PermissionCatalog.cs) | 36 claves `modulo.accion`, roles de sistema y su matriz por defecto |
| Entidad permiso | [`Permiso.cs`](../backend/src/ConsultoraPro.Domain/Models/Permiso.cs) | `Id, Clave, Nombre, Modulo, Descripcion` |
| Concesión rol↔permiso | [`RolPermiso.cs`](../backend/src/ConsultoraPro.Domain/Models/RolPermiso.cs) | `RolId, PermisoId, Concedido` |
| Rol | [`ApplicationRole.cs`](../backend/src/ConsultoraPro.Domain/Models/ApplicationRole.cs) | `Descripcion, EsActivo, AccesoTotalProyectos, EsSistema` |
| Membresía a proyecto | [`ProyectoMiembro.cs`](../backend/src/ConsultoraPro.Domain/Models/ProyectoMiembro.cs) | `UsuarioId, ProyectoId, Rol (RolDesarrollador)` |
| Emisión de claims | [`AuthService.cs`](../backend/src/ConsultoraPro.API/Services/AuthService.cs) | JWT 8 h con `role`, `accesoTotalProyectos`, `permisos[]` |
| Policy handler | [`PermissionAuthorizationHandler.cs`](../backend/src/ConsultoraPro.API/Authorization/PermissionAuthorizationHandler.cs) | Comprueba que el claim `permisos` contenga la clave |
| Contexto de usuario | [`CurrentUserService.cs`](../backend/src/ConsultoraPro.API/Services/CurrentUserService.cs) | `UserId, Role, HasFullProjectAccess, HasPermission()` |
| Guard de ruta | [`permission.guard.ts`](../frontend/src/app/core/guards/permission.guard.ts) | Lee `route.data.permiso` y llama `auth.hasPermission()` |
| Modelos UI | [`security.models.ts`](../frontend/src/app/core/models/security.models.ts) | `Permiso, PermisoModulo, RolDetalle, UsuarioProyectosAcceso` |

**Limitaciones a resolver:**

- **L1 — Ámbito a nivel de rol, no de módulo.** `AccesoTotalProyectos` es un booleano único del rol. No se
  puede expresar "ve todos los clientes pero solo los proyectos asignados".
- **L2 — Sin ámbito por recurso al consultar por id.** El filtrado por proyecto asignado se hace a mano
  (`ProyectoService.GetAll` filtra; pero `GetById` de otros módulos podría no hacerlo). Riesgo de IDOR.
- **L3 — Un solo rol por usuario.** `GetRolesAsync(...).FirstOrDefault()` ignora roles adicionales.
- **L4 — Credenciales sin niveles graduados** ni flujo "solicitar revelación".
- **L5 — Screenshots sin permiso** en el catálogo (no hay `screenshots.*`).
- **L6 — JWT estático de 8 h**: cambiar un rol no surte efecto hasta el siguiente login; tampoco hay
  revocación de sesión.
- **L7 — Nomenclatura `equipo.*` vs `usuarios`/`roles`** mezclada; conviene separar Usuarios de Roles.

---

## 2. Principios de diseño

1. **El servidor es la única fuente de verdad.** El claim `permisos` del JWT es una _conveniencia de UX_.
   Toda decisión de autorización sensible se vuelve a comprobar contra la BD o contra el principal validado.
2. **Negar por defecto (deny-by-default).** Sin permiso explícito ⇒ sin acceso. El único permiso "siempre
   activo" es `dashboard.ver` y se concede a todo usuario autenticado, no por configuración.
3. **Ortogonalidad.** Acción, ámbito y nivel son dimensiones independientes y combinables, no permisos
   sueltos que se solapan.
4. **Configurable sin desplegar.** Crear un rol, marcar/desmarcar permisos y ajustar ámbitos se hace desde
   la UI de administración; no requiere recompilar. El catálogo de _claves_ sí es código (semilla), porque
   define superficies que deben existir en backend.
5. **El proyecto es el eje del ámbito.** Como indicaste, casi todos los permisos se ven influidos por los
   proyectos asignados. El ámbito `asignados` se evalúa siempre contra `ProyectoMiembro`.
6. **Implicación, no duplicación.** `ver.todos` implica `ver.asignados`; `nivel.full` implica `ver-todo`,
   etc. La implicación se define en el catálogo, no se almacena repetida.

---

## 3. Modelo conceptual: acción × ámbito × nivel

Cada permiso efectivo se compone de hasta tres dimensiones:

```
                ┌─────────────┐
   ACCIÓN  ───► │ ver / crear │   ¿qué operación?
                │ editar /…   │
                └─────────────┘
                       ×
                ┌─────────────┐
   ÁMBITO  ───► │ todos /     │   ¿sobre cuántos recursos? (todos | solo asignados)
                │ asignados   │
                └─────────────┘
                       ×
                ┌─────────────┐
   NIVEL   ───► │ full /      │   ¿con qué profundidad? (solo Credenciales hoy)
                │ ver-todo /  │
                │ básico      │
                └─────────────┘
```

### 3.1 Representación de claves

Mantenemos el separador actual `.` y extendemos la gramática:

```
<modulo>.<accion>[.<calificador>]
```

- Acción simple:        `clientes.crear`
- Acción con ámbito:     `clientes.ver.todos`, `clientes.ver.asignados`
- Acción con nivel:      `credenciales.nivel.full`, `credenciales.nivel.ver-todo`, `credenciales.nivel.basico`

> **Por qué claves explícitas y no una columna `Ambito`:** modelar `ver.todos`/`ver.asignados` como dos
> claves del catálogo permite reutilizar **sin cambios** la infraestructura existente (claim `permisos[]`,
> _policies_ por clave, `RolPermiso.Concedido`, la UI de checkboxes por módulo). El "costo" es definir
> un par de claves por módulo y una **regla de implicación** central.

### 3.2 Reglas de implicación (definidas en código)

```csharp
// PermissionCatalog: implicaciones expandidas al construir el claim y al evaluar en servidor.
public static readonly IReadOnlyDictionary<string, string[]> Implies =
    new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
    {
        ["clientes.ver.todos"]       = ["clientes.ver.asignados"],
        ["proyectos.ver.todos"]      = ["proyectos.ver.asignados"],
        ["ambientes.ver.todos"]      = ["ambientes.ver.asignados"],
        ["repositorios.ver.todos"]   = ["repositorios.ver.asignados"],
        ["credenciales.nivel.full"]  = ["credenciales.nivel.ver-todo", "credenciales.nivel.basico",
                                        "credenciales.crear", "credenciales.editar", "credenciales.revelar"],
        ["credenciales.nivel.ver-todo"] = ["credenciales.nivel.basico", "credenciales.revelar"],
    };
```

La expansión se aplica en **un solo lugar** (`PermissionExpander`) y se usa tanto al emitir el JWT como en
las comprobaciones de servidor, de modo que cliente y servidor nunca discrepan.

---

## 4. Catálogo de permisos propuesto

Reorganización del catálogo actual para soportar las tres dimensiones. Cambios respecto del AS-IS marcados
con 🆕 (nuevo) y 🔁 (renombrado/desglosado). El catálogo completo está en el [Anexo A](#anexo-a--catálogo-completo-de-claves).

Resumen de cambios estructurales:

- 🔁 `clientes.ver` → `clientes.ver.todos` + `clientes.ver.asignados`.
- 🔁 `proyectos.ver` → `proyectos.ver.todos` + `proyectos.ver.asignados`.
- 🔁 `ambientes.ver` → `ambientes.ver.todos` + `ambientes.ver.asignados`.
- 🔁 `repositorios.ver` → `repositorios.ver.todos` + `repositorios.ver.asignados`.
- 🔁 `credenciales.ver`/`revelar` → niveles `credenciales.nivel.{full,ver-todo,basico}` + acciones `crear`/`editar`.
- 🆕 `screenshots.ver` + `screenshots.editar` (no existían).
- 🆕 `credenciales.solicitud.aprobar` (resolver solicitudes de revelación).
- 🔁 `equipo.*` → módulo **Usuarios** (`usuarios.ver`, `usuarios.editar`, `usuarios.cambiar-password`,
   `usuarios.eliminar`, `usuarios.asignar-proyectos`) separado de **Roles** (`roles.*`).
- `dashboard.ver`: permiso lógico **implícito** para todo autenticado (no se almacena como concesión editable).

> **Compatibilidad:** durante la transición se mantienen alias. La migración (sección 13) copia cada
> concesión vieja a su(s) clave(s) nueva(s) para no romper roles existentes.

---

## 5. Mapeo por módulo (lo que mapeaste, reconciliado)

Tabla 1:1 con tu mapeo. "Por defecto siempre activo" ⇒ no es un permiso configurable, es un mínimo
garantizado a todo autenticado o a todo miembro del recurso.

| # | Módulo | Permiso configurable | Clave propuesta | Notas |
|---|---|---|---|---|
| 1 | **Dashboard** | Ver | _(implícito)_ | Siempre activo para autenticados. No editable. |
| 2 | **Clientes** | Ver todos | `clientes.ver.todos` | Implica `ver.asignados`. |
| | | Ver asignados | `clientes.ver.asignados` | Activo por defecto si tiene `ver.todos`. |
| | | Editar (Crear) | `clientes.crear`, `clientes.editar` | Desglosado crear vs editar. |
| 3 | **Proyectos** | Ver todos | `proyectos.ver.todos` | |
| | | Ver asignados | `proyectos.ver.asignados` | Eje del ámbito; se evalúa contra `ProyectoMiembro`. |
| | | Editar (Crear) | `proyectos.crear`, `proyectos.editar` | |
| 4 | **Mis Tableros** | Full acceso | _(implícito por membresía)_ | Acceso completo a los tableros donde es miembro (`TableroMiembro`). |
| 5 | **Credenciales** | Nivel de acceso | `credenciales.nivel.{full,ver-todo,basico}` | Niveles **exclusivos y rankeados**. Ver sección 7. |
| 6 | **Ambientes** | Ver todos / asignados / Editar | `ambientes.ver.todos`, `ambientes.ver.asignados`, `ambientes.crear`, `ambientes.editar` | |
| 7 | **Repositorios** | Ver todos / asignados / Editar | `repositorios.ver.todos`, `repositorios.ver.asignados`, `repositorios.editar` | |
| 8 | **Usuarios** | Ver todos | `usuarios.ver` | |
| | | Editar usuarios | `usuarios.editar` | |
| | | Cambiar contraseña | `usuarios.cambiar-password` | Sub-nivel separado (privilegio sensible). |
| | | Eliminar | `usuarios.eliminar` | |
| | | (Asignar proyectos) | `usuarios.asignar-proyectos` | Define el ámbito `asignados` de otros. **Crítico** (sec. 11). |
| 9 | **Roles** | Ver / Editar / Eliminar | `roles.ver`, `roles.crear`, `roles.editar`, `roles.eliminar`, `roles.asignar` | `roles.editar` es escalada de privilegios potencial (sec. 11). |

---

## 6. Detalle de Proyecto y herencia de permisos

El detalle de proyecto es el caso más rico: cada pestaña **hereda** el permiso de su módulo, evaluado
**en el ámbito de ese proyecto concreto**. No se crean permisos nuevos por pestaña (salvo Screenshots).

| Pestaña | Permiso que controla visibilidad/edición | Regla |
|---|---|---|
| **Información** | _(implícito)_ | Visible para quien pueda ver el proyecto (`proyectos.ver.*` + acceso al proyecto). |
| **Ambientes** | `ambientes.ver.*` / `ambientes.editar` | Heredado del módulo Ambientes, acotado al proyecto. |
| **Repositorios** | `repositorios.ver.*` / `repositorios.editar` | Heredado del módulo Repositorios. |
| **Credenciales** | `credenciales.nivel.*` | Heredado; el **nivel** decide si ve contraseñas (sec. 7). |
| **Tableros** | `kanban.ver` / `kanban.comentar` / `kanban.editar` (+`crear`,`eliminar`,`gestionar`) | "Full acceso" = todas las acciones kanban. |
| **Equipo** | _(implícito)_ | Visible para quien accede al proyecto. Editarlo requiere `proyectos.editar` o `usuarios.asignar-proyectos`. |
| **Screenshots** | 🆕 `screenshots.ver` / `screenshots.editar` | Ver y editar (agregar/eliminar). |

**Regla de herencia (formal):**

> Un usuario ve la pestaña X del proyecto P **si y solo si**
> `tienePermiso(X.ver)` **Y** `tieneAccesoAlProyecto(P)`,
> donde `tieneAccesoAlProyecto(P)` = `permiso(modulo.ver.todos)` **o** `esMiembroDe(P)`.

Esto se implementa una sola vez con autorización por recurso (sección 9.3), de modo que cada pestaña no
tenga su propia lógica copiada.

---

## 7. Credenciales: niveles y flujo de solicitud

Los tres niveles que mapeaste son **excluyentes y ordenados** (no checkboxes aditivos). Se modelan como
tres claves con precedencia; la UI los presenta como _radio buttons_.

| Nivel | Clave | Puede listar | Ve datos no sensibles | Ve/revela secretos | Crea/Edita |
|---|---|---|---|---|---|
| **Full acceso** | `credenciales.nivel.full` | ✅ | ✅ | ✅ | ✅ |
| **Ver todo** | `credenciales.nivel.ver-todo` | ✅ | ✅ | ✅ | ❌ |
| **Ver datos básicos** | `credenciales.nivel.basico` | ✅ | ✅ | ❌ (debe **solicitar**) | ❌ |

Precedencia: `full ⊃ ver-todo ⊃ basico`. Un rol declara **un** nivel; la implicación (sec. 3.2) expande
los inferiores para que las _policies_ existentes sigan funcionando.

### 7.1 Flujo "solicitar revelación" (nivel básico)

```
Usuario (básico)            Sistema                 Aprobador (full)
     │  POST /credenciales/{id}/solicitudes           │
     │ ─────────────────────────────►│                │
     │                               │  crea SolicitudRevelacion (Pendiente)
     │                               │  notifica (Alerta)  ──────────►│
     │                               │                │  GET /credenciales/solicitudes?estado=pendiente
     │                               │◄───────────────┤  POST .../{sol}/aprobar (o /rechazar)
     │                               │  registra AuditoriaCredencial   │
     │  GET /credenciales/{id}/revelar (ventana TTL) │                │
     │ ◄─────────────────────────────│                │
```

- La aprobación concede una **revelación temporal** (TTL configurable, p. ej. 15 min) registrada por
  credencial+usuario, **no** un permiso permanente.
- El aprobador debe tener `credenciales.solicitud.aprobar` (implicado por `nivel.full`).
- Toda revelación (directa o aprobada) se registra en [`AuditoriaCredencial`](../backend/src/ConsultoraPro.Domain/Models/AuditoriaCredencial.cs).
- El _endpoint_ de revelación valida **en servidor**: nivel ≥ ver-todo **o** existe revelación temporal
  vigente; el claim del JWT nunca basta por sí solo.

---

## 8. Modelo de datos

### 8.1 Cambios mínimos sobre lo existente

```
Permiso (existente)                RolPermiso (existente)
 ├─ Id                              ├─ RolId
 ├─ Clave        ── + Ambito?       ├─ PermisoId
 ├─ Nombre       ── + EsImplicito   ├─ Concedido
 ├─ Modulo                          └─ + Ambito (enum: Heredado|Todos|Asignados)   🆕 opción B
 └─ Descripcion
```

Hay **dos opciones** para el ámbito; recomendamos la A por simplicidad y compatibilidad:

- **Opción A (recomendada) — ámbito como claves separadas.** `ver.todos` y `ver.asignados` son filas
  distintas en `Permiso`. `RolPermiso` no cambia. Cero columnas nuevas; toda la infra actual se reutiliza.
- **Opción B — columna `Ambito` en `RolPermiso`.** Una clave `ver` con un enum de ámbito por concesión.
  Más "elegante" pero obliga a cambiar el claim, las _policies_ y la UI. Mayor coste, mismo resultado.

### 8.2 Tablas nuevas

```sql
-- Revelaciones temporales aprobadas (nivel básico → ver secreto por una ventana de tiempo)
CREATE TABLE SolicitudesRevelacionCredencial (
    Id              uniqueidentifier PRIMARY KEY,
    CredencialId    uniqueidentifier NOT NULL REFERENCES Credenciales(Id),
    SolicitanteId   uniqueidentifier NOT NULL REFERENCES AspNetUsers(Id),
    AprobadorId     uniqueidentifier NULL     REFERENCES AspNetUsers(Id),
    Estado          int NOT NULL,             -- Pendiente|Aprobada|Rechazada|Expirada
    Motivo          nvarchar(500) NULL,
    FechaSolicitud  datetime2 NOT NULL,
    FechaResolucion datetime2 NULL,
    VigenteHasta    datetime2 NULL            -- TTL de la revelación aprobada
);

-- Versionado de permisos para invalidar JWTs tras cambios de rol (ver sec. 11.2)
ALTER TABLE AspNetUsers     ADD PermVersion int NOT NULL DEFAULT 0;
ALTER TABLE AspNetRoles     ADD PermVersion int NOT NULL DEFAULT 0;
```

> `ProyectoMiembro` ya existe y es la base del ámbito `asignados`. No requiere cambios para la Opción A.

### 8.3 ¿Multi-rol por usuario?

Identity ya soporta N roles por usuario; el límite está en `AuthService.GetRoleAndPermissionsAsync`
(`FirstOrDefault`). Propuesta: **unir** los permisos de todos los roles del usuario (unión de conjuntos)
y, para el ámbito, tomar el **más permisivo** (`todos` gana a `asignados`). Esto se decide en producto;
es opcional para la primera fase pero conviene dejar el código preparado (cambiar `FirstOrDefault` por la
unión). Documentado como **decisión abierta**.

---

## 9. Enforcement en backend

Tres capas, de la más barata a la más fuerte. **Una operación sensible pasa por las tres.**

### 9.1 Capa 1 — Policy por permiso (ya existe, se extiende)

```csharp
[Authorize(Policy = "credenciales.nivel.basico")]   // mínimo para listar
public Task<IActionResult> Get() ...
```

Se registran las policies nuevas en `Program.cs` igual que las actuales, generadas desde
`PermissionCatalog.All` para no olvidarse ninguna:

```csharp
foreach (var p in PermissionCatalog.All)
    options.AddPolicy(p.Clave, policy => policy.Requirements.Add(new PermissionRequirement(p.Clave)));
```

El `PermissionAuthorizationHandler` actual ya resuelve esto; solo hay que pasarlo por el `PermissionExpander`
para que `nivel.full` satisfaga la policy `nivel.basico`.

### 9.2 Capa 2 — Filtro de ámbito en consultas de lista

Centralizar el filtro "todos vs asignados" en un helper reutilizable, en vez de repetirlo por servicio
(hoy en [`ProyectoService.cs:78`](../backend/src/ConsultoraPro.Application/Services/ProyectoService.cs#L78)):

```csharp
public interface IProjectScope
{
    bool VeTodos(string modulo);                       // tiene <modulo>.ver.todos
    IQueryable<T> FiltrarPorAcceso<T>(IQueryable<T> q, // aplica WHERE ProyectoId IN (asignados)
        Expression<Func<T, Guid>> proyectoIdSelector, string modulo);
    Task<IReadOnlySet<Guid>> ProyectosAsignadosAsync();
}
```

Cada servicio de lista (Ambientes, Repositorios, Credenciales, Screenshots, Kanban…) usa
`FiltrarPorAcceso` en vez de su propio `Where`. Así no se puede "olvidar" el filtro en un módulo nuevo.

### 9.3 Capa 3 — Autorización por recurso (anti-IDOR) ⭐ la pieza que falta

Para los _endpoints_ "por id" (`GET/PUT/DELETE /ambientes/{id}`), comprobar que el recurso pertenece a un
proyecto al que el usuario tiene acceso. ASP.NET soporta esto nativamente:

```csharp
public sealed class ProjectResourceHandler
    : AuthorizationHandler<ModuloOperationRequirement, IProyectoScoped>
{
    protected override Task HandleRequirementAsync(
        AuthorizationHandlerContext ctx, ModuloOperationRequirement req, IProyectoScoped recurso)
    {
        var permisos = Expand(ctx.User);                    // claims expandidos
        var veTodos  = permisos.Contains($"{req.Modulo}.ver.todos");
        var esMiembro = _scope.EsMiembro(recurso.ProyectoId); // contra ProyectoMiembro (BD)
        if (permisos.Contains(req.Clave) && (veTodos || esMiembro))
            ctx.Succeed(req);
        return Task.CompletedTask;
    }
}
```

```csharp
// En el controller / handler de aplicación:
var auth = await _authorization.AuthorizeAsync(User, ambiente, new ModuloOperationRequirement("ambientes", "ambientes.editar"));
if (!auth.Succeeded) return Forbid();
```

Donde `IProyectoScoped` es una interfaz mínima (`Guid ProyectoId { get; }`) que implementan `Ambiente`,
`Repositorio`, `Credencial`, `Screenshot`, `Tablero`, etc. Esto convierte la "herencia" de la sección 6 en
una sola línea por _endpoint_ y elimina el riesgo de que un módulo nuevo exponga datos de proyectos ajenos.

> **Regla de oro:** ningún _endpoint_ que reciba un `{id}` de un recurso ligado a proyecto puede confiar en
> que la Capa 1 (policy global) basta. La Capa 3 es obligatoria para esos casos.

### 9.4 Niveles de credenciales en servidor

```csharp
// Revelar un secreto: re-evaluar SIEMPRE en servidor, nunca confiar solo en el claim.
if (nivel < Nivel.VerTodo &&
    !await _revelaciones.TieneVigenteAsync(credencialId, userId))
        return Forbid();   // nivel básico sin aprobación vigente
```

---

## 10. Enforcement en frontend

El frontend **oculta** lo que el usuario no puede usar (UX), pero nunca es la barrera de seguridad.

### 10.1 Guard de ruta (existe, se mantiene)

`PermissionGuard` ya lee `route.data.permiso`. Se extiende para aceptar **cualquiera de** un conjunto
(p. ej. `ver.todos` o `ver.asignados`) y para expandir implicaciones con la misma tabla que el backend
(generada y exportada como JSON para no duplicar reglas).

### 10.2 Directiva estructural `*hasPermission`

```html
<button *hasPermission="'clientes.crear'">Nuevo cliente</button>
<section *hasPermission="['credenciales.nivel.ver-todo']">…contraseña…</section>
```

Reemplaza los `*ngIf` ad-hoc por una directiva que consulta `AuthService` y aplica la misma expansión.

### 10.3 Menú y pestañas guiados por permisos

El menú lateral y las pestañas del detalle de proyecto se construyen desde un mapa
`permiso → ítem`, de modo que añadir un módulo nuevo no requiere tocar el HTML del menú.

### 10.4 Pestañas del detalle de proyecto

Cada pestaña de [`project-detail`](../frontend/src/app/features/project-detail/) declara su permiso; el
componente filtra la lista de pestañas visibles con la regla de herencia (sec. 6). El servidor vuelve a
validar en cada llamada de datos.

---

## 11. Brechas de seguridad y mitigaciones

| # | Riesgo | Descripción | Mitigación |
|---|---|---|---|
| **G1** | **IDOR / BOLA** | `GET /ambientes/{id}` de un proyecto ajeno sin filtrar por membresía. | Capa 3 (sec. 9.3): autorización por recurso obligatoria en todo _endpoint_ con `{id}` ligado a proyecto. Test automático que falle si un recurso no implementa `IProyectoScoped`. |
| **G2** | **JWT obsoleto** | Permisos viven 8 h en el token; revocar un rol no surte efecto. | `permVersion` en usuario/rol; el middleware compara el claim con la BD y fuerza re-login si difiere. Reducir TTL del access token + refresh token. Endpoint admin "revocar sesiones". |
| **G3** | **Escalada vía `roles.editar`** | Quien edita roles puede concederse a sí mismo cualquier permiso. | Separar `roles.editar` de `roles.asignar`; prohibir editar el propio rol; los flags estructurales de roles de sistema siguen bloqueados (`EsSistema`); auditar todo cambio de permiso; opcional "doble aprobación" para roles con permisos sensibles. |
| **G4** | **Escalada vía asignación de proyectos** | `usuarios.asignar-proyectos` permite ampliar el ámbito `asignados` de cualquiera (incl. uno mismo). | Permiso separado y auditado; no permitir auto-asignación sin `roles.editar`; registrar quién asignó qué. |
| **G5** | **Fuga de secretos (Credenciales)** | Nivel básico podría ver contraseñas vía API directa. | Revelación re-validada en servidor (sec. 9.4); secretos **nunca** en respuestas de listado; cifrado en reposo ([`EncryptionService.cs`](../backend/src/ConsultoraPro.Infrastructure/Security/EncryptionService.cs)); auditar cada revelación; TTL en revelaciones temporales. |
| **G6** | **Confiar en el cliente** | El front oculta botones pero la API responde igual. | El servidor autoriza siempre; el guard/directiva son solo UX. Tests de API sin token o con token de menor privilegio. |
| **G7** | **Mass assignment / over-posting** | DTO de actualización trae `RolId` o `Activo` y un usuario común se auto-promueve. | DTOs de entrada sin campos de privilegio; cambios de rol solo por `roles.asignar`; validar en servidor que el actor puede establecer ese rol. |
| **G8** | **Usuario aprovisionado por Google sin rol** | `ProvisionGoogleUserAsync` crea usuario **sin rol** (correcto), pero hay que garantizar deny-by-default. | Confirmar que sin rol ⇒ sin permisos ⇒ solo Dashboard. Pantalla "pendiente de aprobación". |
| **G9** | **Implicaciones inconsistentes** front/back | Si front y back expanden distinto, hay bypass o falsos negativos. | Una sola tabla de implicación, exportada del back al front (build-time). Test que compara ambos catálogos. |
| **G10** | **Roles huérfanos / permisos colgados** | Borrar un permiso del catálogo deja `RolPermiso` apuntando a nada. | Catálogo versionado; migración idempotente que reconcilia; FK con `ON DELETE` controlado; el catálogo es semilla, no se borra en caliente. |
| **G11** | **Endpoints sin `[Authorize]`** | Un controller nuevo olvida la policy. | Fallback global: `RequireAuthenticatedUser` por defecto; test que enumera acciones de controller sin atributo de autorización explícito. |
| **G12** | **Enumeración por respuestas distintas** | 403 vs 404 revela existencia de recursos ajenos. | Devolver 404 (no 403) cuando el recurso existe pero está fuera de ámbito, para no filtrar su existencia. |

### 11.1 Defensa en profundidad (resumen)

```
Petición ─► [JWT válido + no expirado]
         ─► [permVersion coincide con BD]        (G2)
         ─► [Policy: tiene la clave]             (Capa 1)
         ─► [Ámbito: todos | miembro del proyecto] (Capa 2/3, G1)
         ─► [Nivel: credenciales]                (G5)
         ─► [Validación de DTO sin sobre-posteo] (G7)
         ─► Auditoría                            (sec. 12)
```

### 11.2 `permVersion` (detalle)

Al cambiar permisos de un rol o roles de un usuario, se incrementa `PermVersion`. El JWT incluye
`permVersion`. Un middleware ligero compara claim vs BD (cacheable) y, si difiere, responde 401 con código
`token-stale` para que el front renueve. Coste: una lectura cacheada por petición; beneficio: revocación
casi inmediata sin sesiones de 8 h colgando.

---

## 12. Auditoría y observabilidad

- **Auditar** (quién, cuándo, qué, sobre quién): cambios de permisos de rol, asignación de roles a usuarios,
  asignación de proyectos, revelación de credenciales (ya hay [`AuditoriaCredencial`](../backend/src/ConsultoraPro.Domain/Models/AuditoriaCredencial.cs)),
  aprobación/rechazo de solicitudes, y todo `403/Forbid` en operaciones sensibles.
- **Tabla `AuditoriaSeguridad`** genérica: `Actor, Accion, Entidad, EntidadId, Antes, Despues, Ip, Fecha`.
- **Alertas**: reutilizar el módulo de Alertas para notificar solicitudes de revelación pendientes y
  cambios de permisos sobre la propia cuenta.
- **Métricas**: nº de `Forbid` por endpoint (detecta configuración incorrecta o sondeo), nº de revelaciones.

---

## 13. Semillas y migraciones

1. **Extender `PermissionCatalog.All`** con las claves nuevas (Anexo A) manteniendo Ids estables; las
   nuevas usan Ids siguientes (37+). **Nunca reasignar Ids existentes.**
2. **Migración de datos idempotente** (seeder en [`Infrastructure/Data/Seed`](../backend/src/ConsultoraPro.Infrastructure/Data/Seed/)):
   - Inserta permisos nuevos que falten (`upsert` por `Clave`).
   - Para cada `RolPermiso` con clave vieja, crea la concesión equivalente nueva:
     `clientes.ver` ⇒ `clientes.ver.todos` (los roles de sistema con acceso total) o `…asignados` (resto),
     decidido según `AccesoTotalProyectos` del rol para preservar el comportamiento actual.
   - `credenciales.ver`+`revelar` ⇒ `credenciales.nivel.ver-todo`; solo `credenciales.ver` ⇒ `nivel.basico`;
     Arquitecto ⇒ `nivel.full`.
   - Añade `screenshots.ver`/`editar` a los roles que ya editaban proyectos.
3. **Mantener alias temporales**: el `PermissionExpander` mapea claves viejas→nuevas durante una versión,
   para que JWTs ya emitidos sigan funcionando hasta expirar.
4. **Migración EF** para `SolicitudesRevelacionCredencial`, `PermVersion`, `AuditoriaSeguridad`.
5. **Reseed de la matriz por defecto** (`PermissionCatalog.RolePermissions`) sin pisar personalizaciones:
   solo añade lo que falte; no revoca lo que un admin haya tocado a mano (marcar `EsPersonalizado`).

> Recordatorio de proyecto: las inserciones de hijos con clave preasignada deben hacerse por el patrón
> documentado en [[project_ef_navadd_preset_key_update_bug]] (no por colección de navegación + `UpdateAsync`).

---

## 14. Plan de implementación por fases

| Fase | Alcance | Entregable | Riesgo |
|---|---|---|---|
| **0. Anclaje** | Documentar AS-IS, tests de caracterización de permisos actuales | Suite verde sobre comportamiento actual | Bajo |
| **1. Ámbito por módulo** | Desglosar `ver` → `ver.todos`/`ver.asignados`; `PermissionExpander`; migración + alias | Roles existentes intactos, ámbito configurable por módulo | Medio (migración) |
| **2. Autorización por recurso** | `IProyectoScoped` + `ProjectResourceHandler` + `IProjectScope`; aplicar a todos los `{id}` | Cierre de IDOR (G1) | Medio-alto |
| **3. Credenciales por niveles** | Niveles + flujo de solicitud + revelación temporal + auditoría | Niveles full/ver-todo/básico operativos | Alto (seguridad) |
| **4. Screenshots + Usuarios/Roles** | `screenshots.*`; separar `usuarios.*` de `roles.*` con sub-niveles | Mapeo completo de tu tabla | Bajo |
| **5. Frescura de token** | `permVersion`, revocación de sesiones, refresh token corto | Revocación casi inmediata (G2) | Medio |
| **6. UI de administración** | Editor de roles con ámbito por módulo, niveles y asignación de proyectos | Configuración 100 % sin desplegar | Medio |
| **7. Frontend fino** | Directiva `*hasPermission`, menú y pestañas por permiso | UX coherente con el back | Bajo |
| **8. Auditoría y alertas** | `AuditoriaSeguridad`, métricas de `Forbid`, alertas de cambios | Observabilidad | Bajo |

Las fases 1 y 2 son la columna vertebral; 3 es la de mayor sensibilidad. Cada fase es desplegable de forma
independiente gracias a los alias de compatibilidad.

---

## 15. Matriz de pruebas

Casos mínimos que deben existir (xUnit en [`tests/ConsultoraPro.Tests`](../backend/tests/ConsultoraPro.Tests/) + e2e front):

1. **Deny-by-default**: usuario sin rol ⇒ solo Dashboard; todo lo demás 403/404.
2. **Ámbito**: usuario con `proyectos.ver.asignados` no ve proyectos donde no es miembro (lista y por id).
3. **IDOR**: `GET /ambientes/{idAjeno}` ⇒ 404 (no 403, no 200) para usuario fuera de ámbito (G1, G12).
4. **Implicación**: `clientes.ver.todos` satisface la policy `clientes.ver.asignados`.
5. **Credenciales nivel básico**: listar sí, revelar no; tras aprobación, revelar sí dentro del TTL; tras
   expirar, no.
6. **Escalada**: usuario con `roles.editar` no puede editar su propio rol ni concederse permisos de sistema (G3).
7. **Token obsoleto**: cambiar el rol incrementa `permVersion` ⇒ siguiente petición con token viejo ⇒ 401 `token-stale` (G2).
8. **Over-posting**: `PUT /usuarios/{id}` con `rolId` por un usuario sin `roles.asignar` ⇒ rol sin cambios (G7).
9. **Cobertura de policies**: test que recorre `PermissionCatalog.All` y verifica que existe policy registrada.
10. **Cobertura de `[Authorize]`**: test que enumera acciones de controller sin atributo de autorización (G11).
11. **Paridad front/back**: el JSON de implicaciones del front coincide con `PermissionCatalog.Implies` (G9).
12. **Catálogo escaneable por recurso**: cada entidad ligada a proyecto implementa `IProyectoScoped` (G1).

---

## Anexo A — Catálogo completo de claves

> Ids 1–36 = existentes (no reasignar). Desgloses de `ver` reutilizan el Id base para `.todos` y añaden uno
> nuevo para `.asignados`. Las claves 🆕 toman Ids ≥ 37.

| Módulo | Clave | Tipo | Implica |
|---|---|---|---|
| Dashboard | `dashboard.ver` | implícito | — |
| Clientes | `clientes.ver.todos` | ámbito | `clientes.ver.asignados` |
| Clientes | `clientes.ver.asignados` | ámbito | — |
| Clientes | `clientes.crear` | acción | — |
| Clientes | `clientes.editar` | acción | — |
| Clientes | `clientes.eliminar` | acción | — |
| Proyectos | `proyectos.ver.todos` | ámbito | `proyectos.ver.asignados` |
| Proyectos | `proyectos.ver.asignados` | ámbito | — |
| Proyectos | `proyectos.crear` | acción | — |
| Proyectos | `proyectos.editar` | acción | — |
| Proyectos | `proyectos.eliminar` | acción | — |
| Ambientes | `ambientes.ver.todos` | ámbito | `ambientes.ver.asignados` |
| Ambientes | `ambientes.ver.asignados` | ámbito | — |
| Ambientes | `ambientes.crear` | acción | — |
| Ambientes | `ambientes.editar` | acción | — |
| Repositorios | `repositorios.ver.todos` | ámbito | `repositorios.ver.asignados` |
| Repositorios | `repositorios.ver.asignados` | ámbito | — |
| Repositorios | `repositorios.editar` | acción | — |
| Credenciales | `credenciales.nivel.full` | nivel | `ver-todo, basico, crear, editar, revelar, solicitud.aprobar` |
| Credenciales | `credenciales.nivel.ver-todo` | nivel | `basico, revelar` |
| Credenciales | `credenciales.nivel.basico` | nivel | — |
| Credenciales | `credenciales.crear` | acción | — |
| Credenciales | `credenciales.editar` | acción | — |
| Credenciales | `credenciales.solicitud.aprobar` | acción 🆕 | — |
| Despliegues | `despliegues.ver` | acción | — |
| Despliegues | `despliegues.ejecutar` | acción | — |
| Despliegues | `despliegues.historial` | acción | — |
| Kanban | `kanban.ver` | acción | — |
| Kanban | `kanban.crear` | acción | — |
| Kanban | `kanban.editar` | acción | — |
| Kanban | `kanban.comentar` | acción | — |
| Kanban | `kanban.eliminar` | acción | — |
| Kanban | `kanban.gestionar` | acción | — |
| Screenshots | `screenshots.ver` | acción 🆕 | — |
| Screenshots | `screenshots.editar` | acción 🆕 | — |
| Usuarios | `usuarios.ver` | acción 🔁 | — |
| Usuarios | `usuarios.editar` | acción 🔁 | — |
| Usuarios | `usuarios.cambiar-password` | acción 🆕 | — |
| Usuarios | `usuarios.eliminar` | acción 🔁 | — |
| Usuarios | `usuarios.asignar-proyectos` | acción 🔁 | — |
| Roles | `roles.ver` | acción | — |
| Roles | `roles.crear` | acción | — |
| Roles | `roles.editar` | acción | — |
| Roles | `roles.eliminar` | acción | — |
| Roles | `roles.asignar` | acción | — |

---

### Decisiones abiertas (requieren tu confirmación)

1. **Multi-rol por usuario**: ¿un usuario puede tener varios roles (unión de permisos) o seguimos con uno?
2. **Ámbito Opción A vs B** (sec. 8.1): recomiendo A (claves separadas) por compatibilidad.
3. **TTL de revelación temporal** de credenciales (sugerido 15 min) y **TTL del access token** (sugerido
   reducir de 8 h con refresh token).
4. **Doble aprobación** para conceder permisos sensibles (Credenciales full, Roles): ¿lo queremos en v1?
