# Plan de Diseño: Permisos y Roles Configurable (Antigravity)

Este documento propone un diseño robusto, escalable y totalmente configurable para el control de acceso en **ConsultoraPro**. La arquitectura abarca la definición de permisos atómicos, la asignación de roles globales y específicos de proyecto, el control de acceso por recurso para mitigar vulnerabilidades críticas de seguridad, y la lógica de integración en backend (.NET) y frontend (Angular).

---

## Índice

1. [Conceptos Clave y Modelo Mental](#1-conceptos-clave-y-modelo-mental)
2. [Modelo de Base de Datos Configurable](#2-modelo-de-base-de-datos-configurable)
3. [Catálogo de Permisos y Reglas de Implicación](#3-catálogo-de-permisos-y-reglas-de-implicación)
4. [Ámbito de Control: Global vs. Asignados](#4-ámbito-de-control-global-vs-asignados)
5. [Credenciales: Niveles y Flujo de Aprobación Temporal](#5-credenciales-niveles-y-flujo-de-aprobación-temporal)
6. [Seguridad Avanzada y Mitigación de Brechas](#6-seguridad-avanzada-y-mitigación-de-brechas)
7. [Arquitectura y Enforcement en Backend (.NET)](#7-arquitectura-y-enforcement-en-backend-net)
8. [Arquitectura y Directivas en Frontend (Angular)](#8-arquitectura-y-directivas-en-frontend-angular)
9. [Plan de Migración e Implementación Incremental](#9-plan-de-migración-e-implementación-incremental)

---

## 1. Conceptos Clave y Modelo Mental

Para lograr un sistema **100% configurable** que se adapte tanto a usuarios globales como a usuarios restringidos por proyecto, definimos los siguientes pilares conceptuales:

```
┌───────────┐         concede         ┌───────────┐         asociado a         ┌──────────────┐
│  Permiso  │ ◄────────────────────── │    Rol    │ ◄────────────────────────  Usuario      │
└─────┬─────┘                         └───────────┘                            └──────┬───────┘
      │                                                                               │
      ▼                                                                               ▼
┌───────────┐                                                                  ┌──────────────┐
│  Ámbito   │ (Global / Por Proyecto)                                          │   Proyecto   │
└───────────┘                                                                  └──────────────┘
```

*   **Permiso (Atomic Permission):** Representa una acción específica sobre un recurso (ej: `clientes.crear`, `credenciales.nivel.basico`).
*   **Rol (Role):** Un contenedor de permisos. El sistema tendrá roles sembrados (del sistema, como `SuperAdmin`, `Developer`) y soportará roles creados dinámicamente por los administradores.
*   **Ámbito (Scope):** Define el alcance de los permisos. Puede ser **Global** (el usuario puede ejecutar la acción en todo el sistema) o **Por Proyecto** (la acción solo es válida dentro de los proyectos a los que el usuario ha sido asignado explícitamente).
*   **Implicación (Permission Implication):** Reglas lógicas donde la concesión de un permiso de mayor nivel otorga automáticamente permisos secundarios. Por ejemplo, `proyectos.ver.todos` implica `proyectos.ver.asignados`.
*   **Asignación Contextual:** Un usuario no solo tiene roles globales. Puede tener un rol determinado para la plataforma entera (ej: `Dev` global) y otro rol particular para un proyecto específico (ej: `LT` para el Proyecto A).

---

## 2. Modelo de Base de Datos Configurable

Para dar flexibilidad total sin necesidad de recompilar el backend, el modelo de datos separa la definición de permisos (semilla) de las asignaciones de roles y ámbitos.

### 2.1 Tabla de Entidades de Seguridad

```sql
-- ============================================================
-- 1. CATÁLOGO DE PERMISOS (Semilla estática del sistema)
-- ============================================================
CREATE TABLE Permisos (
    Id           INT PRIMARY KEY IDENTITY(1,1),
    Clave        NVARCHAR(100) NOT NULL UNIQUE, -- Ej: 'proyectos.detalle.tableros.editar'
    Nombre       NVARCHAR(150) NOT NULL,
    Modulo       NVARCHAR(50)  NOT NULL,        -- Ej: 'Proyectos', 'Credenciales'
    Descripcion  NVARCHAR(500) NULL,
    EsSistema    BIT NOT NULL DEFAULT 0          -- Protege permisos semilla contra borrado
);

-- ============================================================
-- 2. ROLES (Dinámicos y de Sistema)
-- ============================================================
-- Nota: Extiende el AspNetRoles de Identity.
CREATE TABLE AspNetRoles (
    Id                   UNIQUEIDENTIFIER PRIMARY KEY,
    Name                 NVARCHAR(256) NOT NULL UNIQUE,
    NormalizedName       NVARCHAR(256) NOT NULL UNIQUE,
    ConcurrencyStamp     NVARCHAR(MAX) NULL,
    Descripcion          NVARCHAR(500) NOT NULL DEFAULT '',
    EsActivo             BIT NOT NULL DEFAULT 1,
    EsSistema            BIT NOT NULL DEFAULT 0, -- Bloquea edición de roles base (Gerencia, Dev, etc.)
    VersionPermisos      INT NOT NULL DEFAULT 0  -- Incremental para invalidar JWTs cuando cambia el rol
);

-- ============================================================
-- 3. ASIGNACIÓN ROL ↔ PERMISO (La matriz configurable)
-- ============================================================
CREATE TABLE RolPermisos (
    RolId      UNIQUEIDENTIFIER NOT NULL,
    PermisoId  INT NOT NULL,
    Concedido  BIT NOT NULL DEFAULT 1,
    CONSTRAINT PK_RolPermisos PRIMARY KEY (RolId, PermisoId),
    CONSTRAINT FK_RolPermisos_Roles FOREIGN KEY (RolId) REFERENCES AspNetRoles(Id) ON DELETE CASCADE,
    CONSTRAINT FK_RolPermisos_Permisos FOREIGN KEY (PermisoId) REFERENCES Permisos(Id) ON DELETE CASCADE
);

-- ============================================================
-- 4. VINCULACIÓN USUARIO - PROYECTO - ROL (El núcleo del ámbito)
-- ============================================================
-- Permite que un usuario tenga un rol específico dentro de un proyecto o globalmente (ProyectoId = NULL)
CREATE TABLE UsuarioProyectoRoles (
    Id           UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    UsuarioId    UNIQUEIDENTIFIER NOT NULL,
    RolId        UNIQUEIDENTIFIER NOT NULL,
    ProyectoId   UNIQUEIDENTIFIER NULL, -- NULL significa que el rol tiene alcance GLOBAL
    AsignadoPor  UNIQUEIDENTIFIER NOT NULL,
    FechaAlta    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_UPR_Usuarios FOREIGN KEY (UsuarioId) REFERENCES AspNetUsers(Id) ON DELETE CASCADE,
    CONSTRAINT FK_UPR_Roles FOREIGN KEY (RolId) REFERENCES AspNetRoles(Id) ON DELETE CASCADE,
    CONSTRAINT FK_UPR_Proyectos FOREIGN KEY (ProyectoId) REFERENCES Proyectos(Id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IX_UPR_Usuario_Rol_Proyecto ON UsuarioProyectoRoles(UsuarioId, RolId, ProyectoId) WHERE ProyectoId IS NOT NULL;
CREATE UNIQUE INDEX IX_UPR_Usuario_Rol_Global ON UsuarioProyectoRoles(UsuarioId, RolId) WHERE ProyectoId IS NULL;

-- ============================================================
-- 5. OVERRIDES DIRECTOS DE USUARIO (Flexibilidad extrema)
-- ============================================================
-- Permite conceder o denegar de forma explícita un permiso a un usuario sin crear un rol nuevo
CREATE TABLE UsuarioPermisosDirectos (
    Id           UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    UsuarioId    UNIQUEIDENTIFIER NOT NULL,
    PermisoId    INT NOT NULL,
    ProyectoId   UNIQUEIDENTIFIER NULL, -- NULL = global, Guid = proyecto específico
    Concedido    BIT NOT NULL,          -- 1 = Permitido, 0 = Denegado explícitamente
    AsignadoPor  UNIQUEIDENTIFIER NOT NULL,
    FechaAlta    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_UPD_Usuarios FOREIGN KEY (UsuarioId) REFERENCES AspNetUsers(Id) ON DELETE CASCADE,
    CONSTRAINT FK_UPD_Permisos FOREIGN KEY (PermisoId) REFERENCES Permisos(Id) ON DELETE CASCADE,
    CONSTRAINT FK_UPD_Proyectos FOREIGN KEY (ProyectoId) REFERENCES Proyectos(Id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IX_UPD_Usuario_Permiso_Proyecto ON UsuarioPermisosDirectos(UsuarioId, PermisoId, ProyectoId) WHERE ProyectoId IS NOT NULL;
```

---

## 3. Catálogo de Permisos y Reglas de Implicación

Para reflejar el mapeo de accesos solicitado, redefinimos el catálogo de permisos estructurando las claves de forma uniforme (`modulo.accion[.detalle]`).

### 3.1 Catálogo de Permisos Semilla

| Módulo | Clave de Permiso | Nombre del Permiso | Ámbito Predeterminado | Observaciones |
| :--- | :--- | :--- | :--- | :--- |
| **Dashboard** | `dashboard.ver` | Ver Dashboard | Global | Siempre activo por defecto. |
| **Clientes** | `clientes.ver.todos` | Ver todos los clientes | Global | Acceso a todo el catálogo. |
| | `clientes.ver.asignados` | Ver clientes asignados | Global / Proyecto | Implícito si tiene `clientes.ver.todos`. |
| | `clientes.editar` | Crear/Editar clientes | Global | Permiso administrativo de Clientes. |
| **Proyectos** | `proyectos.ver.todos` | Ver todos los proyectos | Global | Acceso global sin restricción. |
| | `proyectos.ver.asignados` | Ver proyectos asignados | Proyecto | Restringido a membresías. |
| | `proyectos.editar` | Crear/Editar proyectos | Global / Proyecto | Permite crear o modificar proyectos. |
| **Detalle Proyectos** | `proyectos.detalle.tableros.ver` | Ver tableros en detalle | Proyecto | Acceso de lectura a kanban de proyecto. |
| | `proyectos.detalle.tableros.comentar`| Comentar tableros en detalle| Proyecto | |
| | `proyectos.detalle.tableros.editar` | Editar tableros en detalle | Proyecto | Acceso completo (Crear/Editar/Eliminar tarjetas).|
| | `proyectos.detalle.screenshots.ver` | Ver Screenshots | Proyecto | |
| | `proyectos.detalle.screenshots.editar`| Crear/Eliminar Screenshots | Proyecto | |
| **Mis Tableros** | `mistableros.ver` | Acceso a Mis Tableros | Global | Siempre activo para el usuario actual. |
| **Ambientes** | `ambientes.ver.todos` | Ver todos los ambientes | Global | |
| | `ambientes.ver.asignados` | Ver ambientes asignados | Proyecto | Usado en Pestaña del Proyecto y Módulo Global. |
| | `ambientes.editar` | Crear/Editar ambientes | Global / Proyecto | |
| **Repositorios**| `repositorios.ver.todos` | Ver todos los repositorios | Global | |
| | `repositorios.ver.asignados`| Ver repositorios asignados| Proyecto | |
| | `repositorios.editar` | Crear/Editar repositorios | Global / Proyecto | |
| **Credenciales**| `credenciales.ver.todos` | Ver credenciales globales | Global | |
| | `credenciales.ver.asignados`| Ver credenciales de asignados| Proyecto | |
| | `credenciales.nivel.full` | Credenciales - Full Acceso | Global / Proyecto | Ver, editar, crear y revelar contraseñas. |
| | `credenciales.nivel.vertodo` | Credenciales - Ver todo | Global / Proyecto | Lectura total (incluye contraseña). No edita/crea. |
| | `credenciales.nivel.basico` | Credenciales - Ver básico | Global / Proyecto | Sin contraseña visible (requiere solicitud). |
| | `credenciales.solicitud.aprobar`| Aprobar revelación | Proyecto | Permite autorizar solicitudes de revelación. |
| **Usuarios** | `usuarios.ver.todos` | Ver todos los usuarios | Global | |
| | `usuarios.editar` | Editar datos de usuarios | Global | Modificar nombres, email, etc. |
| | `usuarios.cambiar-password` | Cambiar contraseñas | Global | Seguridad crítica. |
| | `usuarios.eliminar` | Eliminar/Desactivar usuarios | Global | |
| **Roles** | `roles.ver.todos` | Ver todos los roles | Global | |
| | `roles.editar` | Crear/Editar roles | Global | Modificación de matriz de permisos. |
| | `roles.eliminar` | Eliminar roles | Global | |

### 3.2 Reglas de Implicación (Herencia Lógica)

El sistema de resolución expandirá automáticamente los permisos usando un árbol de implicación definido en el backend. Esto evita configurar múltiples checkboxes redundantes en la UI.

```csharp
public static class PermissionImplications
{
    public static readonly IReadOnlyDictionary<string, string[]> Mapping = 
        new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            ["clientes.ver.todos"] = new[] { "clientes.ver.asignados" },
            ["proyectos.ver.todos"] = new[] { "proyectos.ver.asignados" },
            ["ambientes.ver.todos"] = new[] { "ambientes.ver.asignados" },
            ["repositorios.ver.todos"] = new[] { "repositorios.ver.asignados" },
            ["credenciales.ver.todos"] = new[] { "credenciales.ver.asignados" },
            
            // Jerarquía de Niveles de Credenciales
            ["credenciales.nivel.full"] = new[] { 
                "credenciales.nivel.vertodo", 
                "credenciales.nivel.basico", 
                "credenciales.solicitud.aprobar" 
            },
            ["credenciales.nivel.vertodo"] = new[] { 
                "credenciales.nivel.basico" 
            }
        };
}
```

---

## 4. Ámbito de Control: Global vs. Asignados

La gran mayoría de accesos dependerá de a qué proyectos esté asignado un usuario. El ámbito se calcula dinámicamente evaluando dos condiciones:

### 4.1 Modos de Resolución de Ámbitos

1.  **Ámbito Global (`ver.todos`):**
    Si el rol del usuario asignado (ya sea global o sobre el proyecto) otorga la clave `.ver.todos`, el usuario tiene acceso a **todas** las entidades de ese módulo.
2.  **Ámbito Acotado (`ver.asignados`):**
    Si el usuario carece de la clave `.ver.todos` pero posee `.ver.asignados`, el sistema intersecta la consulta con la tabla `ProyectoMiembros`. El usuario solo ve los elementos vinculados a los proyectos donde su `UsuarioId` está registrado.

### 4.2 Lógica de Herencia en el Detalle del Proyecto

El Detalle de Proyecto no tiene un catálogo de permisos independientes por cada pestaña (a excepción de Tableros y Screenshots). Hereda el comportamiento del módulo principal acotado a ese proyecto concreto:

*   **Pestaña Información / Equipo:** Visible por defecto si el usuario tiene acceso al proyecto en general.
*   **Pestaña Ambientes:** Muestra los ambientes de este proyecto si el usuario tiene `ambientes.ver.asignados` o `ambientes.ver.todos`.
*   **Pestaña Repositorios:** Muestra los repositorios de este proyecto si tiene `repositorios.ver.asignados` o `repositorios.ver.todos`.
*   **Pestaña Credenciales:** Muestra las credenciales de este proyecto respetando el nivel efectivo del usuario (`full`, `vertodo` o `basico`) sobre este proyecto en particular.

---

## 5. Credenciales: Niveles y Flujo de Aprobación Temporal

El módulo de credenciales requiere una gestión diferenciada para evitar la exposición innecesaria de secretos industriales (claves de producción, APIs, bases de datos).

### 5.1 Matriz de Niveles

*   **Full Acceso:** Puede realizar cualquier operación. Ve las contraseñas, las modifica y las crea.
*   **Ver Todo:** Puede leer todo (incluyendo contraseñas) para tareas operativas de soporte, pero no puede crear ni editar la configuración de la credencial.
*   **Ver Datos Básicos:** Solo ve el nombre, usuario, servidor y descripción. La contraseña aparece oculta con un botón de **"Solicitar Acceso"**.

### 5.2 Flujo de Revelación Temporal (Request-Approval Flow)

Cuando un usuario con nivel **Básico** necesita ver un secreto, el sistema inicia el siguiente flujo transaccional con una validez temporal (TTL):

```
Usuario (Básico)               API (Servidor)                Usuario (Aprobador Full)
       │                              │                                 │
       │ 1. Solicita revelar secreto  │                                 │
       ├─────────────────────────────►│                                 │
       │                              │ 2. Crea solicitud pendiente     │
       │                              │ 3. Genera alerta en sistema     │
       │                              ├────────────────────────────────►│
       │                              │                                 │
       │                              │ 4. Aprueba solicitud (e.g. 15m) │
       │                              │◄────────────────────────────────┤
       │                              │                                 │
       │ 5. Petición GET con Token/Id │                                 │
       ├─────────────────────────────►│                                 │
       │                              │ 6. Valida TTL                   │
       │                              │ 7. Registra auditoría           │
       │ 8. Retorna secreto en claro  │                                 │
       │◄─────────────────────────────┤                                 │
```

#### Tabla de Control de Solicitudes
```sql
CREATE TABLE SolicitudesRevelacion (
    Id              UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    CredencialId    UNIQUEIDENTIFIER NOT NULL,
    SolicitanteId   UNIQUEIDENTIFIER NOT NULL,
    ProyectoId      UNIQUEIDENTIFIER NOT NULL,
    Estado          NVARCHAR(20) NOT NULL, -- 'Pendiente', 'Aprobada', 'Rechazada', 'Expirada'
    FechaSolicitud  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    FechaResolucion DATETIME2 NULL,
    AprobadoPor     UNIQUEIDENTIFIER NULL,
    ExpiracionUtc   DATETIME2 NULL,        -- TTL: Fecha hasta la cual puede revelarse
    Motivo          NVARCHAR(500) NOT NULL,
    CONSTRAINT FK_SR_Credencial FOREIGN KEY (CredencialId) REFERENCES Credenciales(Id) ON DELETE CASCADE,
    CONSTRAINT FK_SR_Solicitante FOREIGN KEY (SolicitanteId) REFERENCES AspNetUsers(Id),
    CONSTRAINT FK_SR_AprobadoPor FOREIGN KEY (AprobadoPor) REFERENCES AspNetUsers(Id)
);
```

---

## 6. Seguridad Avanzada y Mitigación de Brechas

Un sistema de permisos dinámico introduce vectores de ataque si no se diseña con defensas en profundidad. A continuación se detallan las mitigaciones para cada brecha de seguridad:

### 6.1 IDOR / BOLA (Insecure Direct Object Reference)
*   **Brecha:** Un usuario tiene `ambientes.ver.asignados` pero adivina o inyecta el ID (GUID) de un ambiente de un proyecto ajeno en `/api/ambientes/{id}`.
*   **Mitigación:** Todas las entidades asociadas a proyectos deben implementar la interfaz `IProyectoScoped`. El manejador de autorización interceptará cada petición por ID y validará si el proyecto del recurso coincide con los proyectos permitidos del usuario.

### 6.2 Escalada de Privilegios por Gestión de Roles
*   **Brecha:** Un usuario con permiso `roles.editar` modifica un rol del sistema o añade permisos críticos a su propio rol secundario.
*   **Mitigación:**
    1.  Los roles del sistema (`EsSistema = 1`) no pueden ser modificados. Sus permisos son de solo lectura.
    2.  Al guardar asignaciones de permisos a un rol, el backend valida que el administrador actual **tenga** al menos el mismo conjunto de permisos que intenta otorgar o modificar (no puede otorgar permisos que él mismo no posee).
    3.  Un usuario no puede auto-asignarse roles ni modificar las asignaciones de su propio usuario (`UsuarioProyectoRoles` / `UsuarioPermisosDirectos`).

### 6.3 Exposición en Tránsito de Secretos de Credenciales
*   **Brecha:** La API de listado `/api/credenciales` retorna toda la lista incluyendo el campo `Password` enmascarado en el JSON pero expuesto en texto plano en la red.
*   **Mitigación:**
    1.  El endpoint de listado **nunca** incluye el campo `Password` ni secretos sensibles en el DTO de respuesta.
    2.  El secreto solo se expone en un endpoint específico `/api/credenciales/{id}/revelar` el cual valida en tiempo real si el usuario tiene nivel `full`, `vertodo` o una solicitud de revelación temporal vigente y aprobada en `SolicitudesRevelacion`.
    3.  El servicio en backend descifra el valor de la base de datos usando un algoritmo criptográfico seguro (AES-256) en el último momento.

### 6.4 Sesión / JWT Desactualizado
*   **Brecha:** Un administrador revoca el rol de un usuario despedido o lo cambia de proyecto, pero su token JWT sigue siendo válido por 8 horas, permitiéndole seguir operando.
*   **Mitigación:**
    *   Se añade la columna `VersionPermisos` a la tabla `AspNetUsers` y `AspNetRoles`.
    *   Cada cambio en roles, permisos o membresías incrementa la versión.
    *   El middleware de autorización compara la versión del token JWT del usuario contra la base de datos (con un caché en memoria con TTL de 2 minutos). Si difiere, invalida el token de inmediato retornando `401 Unauthorized (TokenStale)` y obligando al frontend a refrescar la sesión.

---

## 7. Arquitectura y Enforcement en Backend (.NET)

La lógica de control de acceso se implementa de manera declarativa y en capas dentro del backend en .NET para asegurar que ninguna petición salte los controles de seguridad.

### 7.1 Interface de Entidades Protegidas

```csharp
public interface IProyectoScoped
{
    Guid ProyectoId { get; }
}
```

### 7.2 Atributo y Requerimiento de Autorización

```csharp
[AttributeUsage(AttributeTargets.Method | AttributeTargets.Class, AllowMultiple = true)]
public class HasPermissionAttribute : AuthorizeAttribute
{
    public string Permiso { get; }

    public HasPermissionAttribute(string permiso) : base(permiso)
    {
        Permiso = permiso;
    }
}
```

### 7.3 Manejador de Autorización basado en Recursos (Anti-IDOR)

Este manejador unifica el control de acceso en consultas detalladas:

```csharp
public class ResourceAuthorizationHandler : AuthorizationHandler<OperationRequirement, IProyectoScoped>
{
    private readonly ICurrentUserService _currentUserService;
    private readonly ISecurityRepository _securityRepository;

    public ResourceAuthorizationHandler(ICurrentUserService currentUserService, ISecurityRepository securityRepository)
    {
        _currentUserService = currentUserService;
        _securityRepository = securityRepository;
    }

    protected override async Task HandleRequirementAsync(
        AuthorizationHandlerContext context,
        OperationRequirement requirement,
        IProyectoScoped resource)
    {
        var userId = _currentUserService.UserId;
        
        // 1. Obtener todos los permisos del usuario para este proyecto específico
        var permisosEfectivos = await _securityRepository.ObtenerPermisosEfectivosAsync(userId, resource.ProyectoId);

        // 2. Comprobar si el permiso requerido está concedido
        if (permisosEfectivos.Contains(requirement.PermisoClave))
        {
            context.Succeed(requirement);
        }
    }
}
```

### 7.4 Servicio de Resolución de Permisos Efectivos

El algoritmo en el backend ejecuta la resolución combinando roles globales, específicos de proyecto, implicaciones y overrides directos:

```csharp
public async Task<HashSet<string>> ObtenerPermisosEfectivosAsync(Guid usuarioId, Guid? proyectoId = null)
{
    var permisosFinales = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    // 1. Cargar roles globales y del proyecto
    var roles = await _context.UsuarioProyectoRoles
        .Where(upr => upr.UsuarioId == usuarioId && (upr.ProyectoId == null || upr.ProyectoId == proyectoId))
        .Select(upr => upr.RolId)
        .ToListAsync();

    // 2. Obtener permisos de los roles cargados
    var permisosRoles = await _context.RolPermisos
        .Where(rp => roles.Contains(rp.RolId) && rp.Concedido)
        .Select(rp => rp.Permiso.Clave)
        .ToListAsync();

    foreach (var permiso in permisosRoles)
    {
        permisosFinales.Add(permiso);
        // Expandir herencias lógicas
        if (PermissionImplications.Mapping.TryGetValue(permiso, out var implicados))
        {
            foreach (var imp in implicados) permisosFinales.Add(imp);
        }
    }

    // 3. Aplicar Overrides Directos (Gana sobre roles)
    var overrides = await _context.UsuarioPermisosDirectos
        .Where(upd => upd.UsuarioId == usuarioId && (upd.ProyectoId == null || upd.ProyectoId == proyectoId))
        .Select(upd => new { upd.Permiso.Clave, upd.Concedido })
        .ToListAsync();

    foreach (var ov in overrides)
    {
        if (ov.Concedido)
        {
            permisosFinales.Add(ov.Clave);
            if (PermissionImplications.Mapping.TryGetValue(ov.Clave, out var implicados))
            {
                foreach (var imp in implicados) permisosFinales.Add(imp);
            }
        }
        else
        {
            permisosFinales.Remove(ov.Clave);
        }
    }

    return permisosFinales;
}
```

---

## 8. Arquitectura y Directivas en Frontend (Angular)

El frontend utiliza directivas estructurales y guards para ajustar dinámicamente la UI basándose en el estado del usuario, brindando una navegación fluida y coherente.

### 8.1 Servicio de Autorización Angular (`PermissionService`)

```typescript
import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { BehaviorSubject, Observable, of } from 'rxjs';
import { map, tap } from 'rxjs/operators';

@Injectable({
  providedIn: 'root'
})
export class PermissionService {
  private permisos$ = new BehaviorSubject<string[]>([]);
  private proyectoActualId: string | null = null;

  constructor(private http: HttpClient) {}

  // Carga los permisos efectivos según el contexto de proyecto
  cargarPermisosContexto(proyectoId?: string): Observable<string[]> {
    this.proyectoActualId = proyectoId || null;
    const url = proyectoId 
      ? `/api/usuarios/me/permisos?proyectoId=${proyectoId}` 
      : '/api/usuarios/me/permisos';

    return this.http.get<string[]>(url).pipe(
      tap(permisos => this.permisos$.next(permisos))
    );
  }

  // Verifica si el usuario tiene el permiso
  hasPermission(permiso: string): boolean {
    const listado = this.permisos$.value;
    return listado.includes(permiso);
  }

  // Comprueba niveles de credencial (XOR / Precedencia)
  obtenerNivelCredencial(): 'full' | 'vertodo' | 'basico' {
    if (this.hasPermission('credenciales.nivel.full')) return 'full';
    if (this.hasPermission('credenciales.nivel.vertodo')) return 'vertodo';
    return 'basico';
  }
}
```

### 8.2 Directiva Estructural `*hasPermission`

Permite ocultar/mostrar elementos de la UI de forma declarativa:

```typescript
import { Directive, Input, TemplateRef, ViewContainerRef, OnInit, OnDestroy } from '@angular/core';
import { PermissionService } from './permission.service';
import { Subscription } from 'rxjs';

@Directive({
  selector: '[hasPermission]'
})
export class HasPermissionDirective implements OnInit, OnDestroy {
  private permissionRequired!: string;
  private hasView = false;
  private sub!: Subscription;

  constructor(
    private templateRef: TemplateRef<any>,
    private viewContainer: ViewContainerRef,
    private permissionService: PermissionService
  ) {}

  @Input() set hasPermission(val: string) {
    this.permissionRequired = val;
    this.updateView();
  }

  ngOnInit() {
    this.sub = this.permissionService.cargarPermisosContexto().subscribe(() => {
      this.updateView();
    });
  }

  private updateView() {
    const canAccess = this.permissionService.hasPermission(this.permissionRequired);
    if (canAccess && !this.hasView) {
      this.viewContainer.createEmbeddedView(this.templateRef);
      this.hasView = true;
    } else if (!canAccess && this.hasView) {
      this.viewContainer.clear();
      this.hasView = false;
    }
  }

  ngOnDestroy() {
    if (this.sub) this.sub.unsubscribe();
  }
}
```

### 8.3 Uso en Vistas Angular

```html
<!-- Gestión de Clientes -->
<button *hasPermission="'clientes.editar'" (click)="abrirModalCrear()">
  Nuevo Cliente
</button>

<!-- Pestaña de Ambientes en Proyecto -->
<div *hasPermission="'ambientes.ver.asignados'">
  <app-proyecto-ambientes [proyectoId]="proyectoId"></app-proyecto-ambientes>
</div>

<!-- Visualización de Credenciales según Nivel -->
<ng-container [ngSwitch]="nivelCredencial">
  <!-- Nivel Full o Ver Todo -->
  <div *ngSwitchCase="'full' || 'vertodo'">
    <label>Contraseña:</label>
    <input type="text" [value]="credencial.password" />
  </div>

  <!-- Nivel Básico (Con Solicitud) -->
  <div *ngSwitchCase="'basico'">
    <label>Contraseña: **********</label>
    <button (click)="solicitarRevelar(credencial.id)">Solicitar Revelación</button>
  </div>
</ng-container>
```

---

## 9. Plan de Migración e Implementación Incremental

Para no interrumpir la operación del sistema actual mientras se implanta este nuevo modelo, proponemos un plan dividido en **4 fases lógicas**:

### Fase 1: Base de Datos y Semillado (Duración: 1 semana)
1.  Crear y aplicar la migración de Entity Framework para añadir las tablas `UsuarioProyectoRoles`, `UsuarioPermisosDirectos` y `SolicitudesRevelacion`.
2.  Introducir el catálogo de `Permisos` inicial mediante un script de semillado automático idempotente (que haga inserción si no existe la Clave).
3.  Migrar las relaciones de roles actuales en la tabla intermedia a la nueva estructura global (ProyectoId = NULL).

### Fase 2: Lógica de Resolución Backend y Middleware (Duración: 1.5 semanas)
1.  Implementar `ResourceAuthorizationHandler` y el servicio `ObtenerPermisosEfectivosAsync`.
2.  Proteger endpoints heredados utilizando el atributo `[HasPermission]`.
3.  Desarrollar la interfaz `IProyectoScoped` y aplicarla en los modelos de base de datos (`Ambiente`, `Repositorio`, `Credencial`, `Screenshot`).
4.  Crear las pruebas unitarias automáticas en xUnit para verificar la resolución de implicaciones y ámbitos por proyecto.

### Fase 3: Integración del Frontend y Directivas Angular (Duración: 1.5 semanas)
1.  Desplegar el `PermissionService` de Angular y sincronizar la lista de permisos mediante llamadas HTTP al cambiar de pantalla o proyecto.
2.  Implementar la directiva `*hasPermission` e incorporarla progresivamente en las vistas principales.
3.  Adaptar las rutas del sistema para que utilicen un `PermissionGuard` genérico.

### Fase 4: Flujo de Aprobación de Credenciales y UI de Roles (Duración: 2 semanas)
1.  Desarrollar los endpoints para crear, listar y aprobar solicitudes de revelación de secretos (`SolicitudesRevelacion`).
2.  Diseñar la pantalla de administración de roles en Angular, permitiendo editar la matriz de permisos para cada rol mediante un árbol jerárquico modular.
3.  Habilitar el panel de asignación de roles a usuarios, con selectores de proyectos específicos.
