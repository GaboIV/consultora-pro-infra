# 10 — Permisos y Roles: Diseño Configurable (BigPickle)

## Índice

- [1. Conceptos fundamentales](#1-conceptos-fundamentales)
- [2. Modelo de datos](#2-modelo-de-datos)
- [3. Catálogo completo de permisos](#3-catálogo-completo-de-permisos)
- [4. Heredabilidad y dependencias](#4-heredabilidad-y-dependencias)
- [5. Estrategia de asignación](#5-estrategia-de-asignación)
- [6. Ámbito: Global vs Por-Proyecto](#6-ámbito-global-vs-por-proyecto)
- [7. Brechas de seguridad y mitigaciones](#7-brechas-de-seguridad-y-mitigaciones)
- [8. Implementación backend ( .NET )](#8-implementación-backend--net-)
- [9. Implementación frontend ( Angular )](#9-implementación-frontend--angular-)
- [10. UI de administración](#10-ui-de-administración)
- [11. Semillas y migraciones](#11-semillas-y-migraciones)
- [12. Plan de implementación por fases](#12-plan-de-implementación-por-fases)

---

## 1. Conceptos fundamentales

### 1.1 Permiso

Unidad atómica que representa una acción sobre un recurso.
Siempre tiene la forma `módulo:acción[:detalle]`.

Ejemplos:
- `dashboard:ver`
- `clientes:ver:todos`
- `proyectos:editar`
- `credentiales:nivel:full_acceso`

### 1.2 Rol

Conjunto de permisos con nombre. Un usuario tiene uno o varios roles.

### 1.3 Ámbito (Scope)

Un permiso puede tener ámbito **Global** (aplica a todo el sistema) o **Por-Proyecto** (aplica solo a proyectos específicos).

### 1.4 Usuario-Rol-Proyecto (URP)

Unión que define qué rol(es) tiene un usuario sobre qué proyecto(s).
Si el rol es global, la URP se registra con `proyecto_id = NULL`.

### 1.5 Herencia

Un permiso puede heredarse automáticamente al conceder otro. Ejemplo: `clientes:ver:todos` implica `clientes:ver:asignados`. Esto se define en el catálogo, no en la asignación.

---

## 2. Modelo de datos

### 2.1 Tablas

```sql
-- ============================================================
-- Catálogo de permisos (semilla estática del sistema)
-- ============================================================
CREATE TABLE permisos (
    id           INT PRIMARY KEY AUTO_INCREMENT,
    codigo       VARCHAR(80)  NOT NULL UNIQUE,   -- ej: "proyectos.detalle.tableros.editar"
    nombre       VARCHAR(120) NOT NULL,           -- ej: "Editar tableros"
    descripcion  VARCHAR(300),                     -- ej: "Permite agregar, editar y eliminar tarjetas"
    modulo       VARCHAR(40)  NOT NULL,            -- ej: "proyectos"
    padre_id     INT NULL REFERENCES permisos(id), -- para jerarquía
    herencia     VARCHAR(20) NOT NULL DEFAULT 'none', -- none | padre_concede_hijo | hijo_concede_padre
    global_scope BOOLEAN NOT NULL DEFAULT TRUE,    -- TRUE: se asigna globalmente; FALSE: requiere proyecto
    orden        INT NOT NULL DEFAULT 0
);

-- ============================================================
-- Roles
-- ============================================================
CREATE TABLE roles (
    id           INT PRIMARY KEY AUTO_INCREMENT,
    nombre       VARCHAR(60) NOT NULL UNIQUE,
    descripcion  VARCHAR(300),
    es_sistema   BOOLEAN NOT NULL DEFAULT FALSE, -- TRUE si es rol semilla (no se puede eliminar)
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- ============================================================
-- Asignación permiso → rol
-- ============================================================
CREATE TABLE roles_permisos (
    id           INT PRIMARY KEY AUTO_INCREMENT,
    rol_id       INT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permiso_id   INT NOT NULL REFERENCES permisos(id) ON DELETE CASCADE,
    UNIQUE (rol_id, permiso_id)
);

-- ============================================================
-- Asignación usuario → rol (y opcionalmente a un proyecto)
-- ============================================================
CREATE TABLE usuarios_roles (
    id           INT PRIMARY KEY AUTO_INCREMENT,
    usuario_id   INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    rol_id       INT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    proyecto_id  INT NULL REFERENCES proyectos(id) ON DELETE CASCADE,
    asignado_por INT NOT NULL REFERENCES usuarios(id),
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (usuario_id, rol_id, proyecto_id)  -- NULL project = global
);

-- ============================================================
-- (Opcional) Permisos directos sin rol — override fino
-- ============================================================
CREATE TABLE usuarios_permisos_directos (
    id           INT PRIMARY KEY AUTO_INCREMENT,
    usuario_id   INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    permiso_id   INT NOT NULL REFERENCES permisos(id) ON DELETE CASCADE,
    proyecto_id  INT NULL REFERENCES proyectos(id) ON DELETE CASCADE,
    concedido    BOOLEAN NOT NULL DEFAULT TRUE,  -- TRUE = concede, FALSE = deniega
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (usuario_id, permiso_id, proyecto_id)
);
```

### 2.2 Diagrama de relaciones

```
usuarios ──< usuarios_roles >── roles ──< roles_permisos >── permisos
             └─ proyecto_id (NULL = global)
```

---

## 3. Catálogo completo de permisos

A continuación el listado exhaustivo. La columna **Código** es la clave única.

| # | Código | Nombre | Hereda de | Ámbito | Observaciones |
|---|--------|--------|-----------|--------|---------------|
| **1. Dashboard** |||||
| 1.1 | `dashboard:ver` | Ver dashboard | — | Global | Siempre activo por defecto, pero se puede revocar si se desea |
| **2. Clientes** |||||
| 2.1 | `clientes:ver:todos` | Ver todos los clientes | — | Global ||
| 2.2 | `clientes:ver:asignados` | Ver clientes asignados | `clientes:ver:todos` lo concede automáticamente | Global / Proyecto | Si el usuario tiene `ver:todos`, este permiso está implícito |
| 2.3 | `clientes:editar` | Crear / editar clientes | — | Global ||
| **3. Proyectos** |||||
| 3.1 | `proyectos:ver:todos` | Ver todos los proyectos | — | Global ||
| 3.2 | `proyectos:ver:asignados` | Ver proyectos asignados | `proyectos:ver:todos` lo concede | Global / Proyecto ||
| 3.3 | `proyectos:editar` | Crear / editar proyectos | — | Global ||
| **3.4 Detalle de Proyecto** |||||
| 3.4.1 | `proyectos.detalle:informacion` | Ver información del proyecto | — | Proyecto | Siempre activo si el usuario puede ver el proyecto |
| 3.4.2 | `proyectos.detalle:ambientes` | Ver ambientes del proyecto | Hereda permisos del módulo Ambientes (5.x) | Proyecto ||
| 3.4.3 | `proyectos.detalle:repositorios` | Ver repositorios del proyecto | Hereda permisos del módulo Repositorios (7.x) | Proyecto ||
| 3.4.4 | `proyectos.detalle:credenciales` | Ver credenciales del proyecto | Hereda permisos del módulo Credenciales (6.x) | Proyecto ||
| 3.4.5 | `proyectos.detalle:tableros:ver` | Ver tableros del proyecto | — | Proyecto ||
| 3.4.6 | `proyectos.detalle:tableros:comentar` | Comentar en tableros | — | Proyecto ||
| 3.4.7 | `proyectos.detalle:tableros:editar` | Editar tableros (crear/editar/eliminar tarjetas) | — | Proyecto ||
| 3.4.8 | `proyectos.detalle:equipo` | Ver equipo del proyecto | — | Proyecto | Siempre activo si el usuario puede ver el proyecto |
| 3.4.9 | `proyectos.detalle:screenshots:ver` | Ver screenshots | — | Proyecto ||
| 3.4.10 | `proyectos.detalle:screenshots:editar` | Subir / eliminar screenshots | — | Proyecto ||
| **4. Mis Tableros** |||||
| 4.1 | `mis-tableros:full_acceso` | Acceso completo a Mis Tableros | — | Global | Siempre activo por defecto |
| **5. Ambientes** |||||
| 5.1 | `ambientes:ver:todos` | Ver todos los ambientes | — | Global ||
| 5.2 | `ambientes:ver:asignados` | Ver ambientes asignados | `ambientes:ver:todos` lo concede | Global / Proyecto ||
| 5.3 | `ambientes:editar` | Crear / editar ambientes | — | Global ||
| **6. Credenciales** |||||
| 6.1 | `credenciales:ver:todos` | Ver credenciales de todos los proyectos | — | Global ||
| 6.2 | `credenciales:ver:asignados` | Ver credenciales de proyectos asignados | `credenciales:ver:todos` lo concede | Global / Proyecto ||
| 6.3 | `credenciales:nivel:full_acceso` | Full acceso: ver todo + editar + crear | — | Global / Proyecto | Puede ver contraseñas, editar y crear credenciales |
| 6.4 | `credenciales:nivel:ver_todo` | Ver todo: ver datos completos incluyendo contraseñas | — | Global / Proyecto | Solo lectura, no puede crear/editar |
| 6.5 | `credenciales:nivel:ver_basico` | Ver datos básicos (oculta contraseñas) | — | Global / Proyecto | Puede solicitar ver password a un full_acceso |
| 6.6 | `credenciales:editar` | Crear / editar credenciales | — | Global / Proyecto | Sin `full_acceso` no puede ver passwords existentes |
| **7. Repositorios** |||||
| 7.1 | `repositorios:ver:todos` | Ver todos los repositorios | — | Global ||
| 7.2 | `repositorios:ver:asignados` | Ver repositorios asignados | `repositorios:ver:todos` lo concede | Global / Proyecto ||
| 7.3 | `repositorios:editar` | Crear / editar repositorios | — | Global ||
| **8. Usuarios** |||||
| 8.1 | `usuarios:ver:todos` | Ver todos los usuarios | — | Global ||
| 8.2 | `usuarios:editar:datos` | Editar datos de usuarios (nombre, email, etc.) | — | Global ||
| 8.3 | `usuarios:editar:password` | Cambiar contraseña de cualquier usuario | — | Global ||
| 8.4 | `usuarios:eliminar` | Eliminar usuarios | — | Global ||
| **9. Roles** |||||
| 9.1 | `roles:ver:todos` | Ver todos los roles | — | Global ||
| 9.2 | `roles:editar` | Crear / editar roles y asignar permisos | — | Global ||
| 9.3 | `roles:eliminar` | Eliminar roles | — | Global ||
| **10. Administración general** |||||
| 10.1 | `admin:configuracion` | Acceder a configuración global del sistema | — | Global | |

### 3.1 Convención de códigos

```
<módulo>:<submódulo?>:<acción>[:<nivel?>]
```

Los módulos con detalle anidado usan punto: `proyectos.detalle:tableros:editar`.

### 3.2 Relación de herencia "padre concede hijo"

| Permiso padre | Permiso hijo concedido automáticamente |
|--------------|----------------------------------------|
| `clientes:ver:todos` | `clientes:ver:asignados` |
| `proyectos:ver:todos` | `proyectos:ver:asignados` |
| `ambientes:ver:todos` | `ambientes:ver:asignados` |
| `credenciales:ver:todos` | `credenciales:ver:asignados` |
| `repositorios:ver:todos` | `repositorios:ver:asignados` |

### 3.3 Relación de exclusión mutua (XOR)

| Grupo | Permisos | Regla |
|-------|----------|-------|
| Nivel de credenciales | `full_acceso`, `ver_todo`, `ver_basico` | Un usuario tiene **exactamente uno** de estos tres sobre un proyecto dado |

---

## 4. Heredabilidad y dependencias

### 4.1 Permisos que se heredan de otros módulos

Cuando un usuario entra al **Detalle de Proyecto**, las pestañas muestran contenido según permisos **heredados** del módulo correspondiente:

| Pestaña en detalle | Permiso en detalle | Permiso del módulo origen |
|-------------------|-------------------|--------------------------|
| Ambientes | `proyectos.detalle:ambientes` | Se resuelve contra `ambientes:ver:*` |
| Repositorios | `proyectos.detalle:repositorios` | Se resuelve contra `repositorios:ver:*` |
| Credenciales | `proyectos.detalle:credenciales` | Se resuelve contra `credenciales:*` |

**Regla**: El permiso `proyectos.detalle:ambientes` solo controla si la **pestaña** se muestra. El contenido respeta los permisos del módulo Ambientes. Un usuario puede ver la pestaña pero no ver credenciales si su nivel es `ver_basico` y no `ver_todo`.

### 4.2 Siempre activos

Los siguientes permisos se conceden automáticamente a cualquier usuario autenticado, pero **deben existir en la tabla `roles_permisos`** para que el motor de permisos sea uniforme:

| Permiso | Motivo |
|---------|--------|
| `dashboard:ver` | Dashboard es la pantalla de inicio |
| `proyectos.detalle:informacion` | Información básica del proyecto |
| `proyectos.detalle:equipo` | Ver quién trabaja en el proyecto |
| `mis-tableros:full_acceso` | Tablero personal |

---

## 5. Estrategia de asignación

### 5.1 Roles semilla del sistema

Estos roles se crean en la primera migración y no se pueden eliminar (`es_sistema = TRUE`).

| Rol | Permisos incluidos | Uso |
|-----|-------------------|-----|
| `SuperAdmin` | **Todos los permisos** del catálogo | Dueño del sistema, puede hacer cualquier cosa |
| `Admin` | Todos excepto `usuarios:eliminar` y `roles:eliminar` | Administrador del día a día |
| `ProjectManager` | `clientes:ver:todos`, `clientes:editar`, `proyectos:ver:todos`, `proyectos:editar`, `proyectos.detalle:*`, `ambientes:ver:todos`, `ambientes:editar`, `repositorios:ver:todos`, `repositorios:editar`, `credenciales:nivel:ver_todo`, `usuarios:ver:todos` | Gestiona proyectos y equipos |
| `Developer` | `proyectos:ver:asignados`, `proyectos.detalle:*` (excepto credenciales), `ambientes:ver:asignados`, `repositorios:ver:asignados`, `credenciales:nivel:ver_basico`, `mis-tableros:full_acceso` | Miembro técnico de proyectos |
| `Viewer` | `dashboard:ver`, `proyectos:ver:asignados`, `proyectos.detalle:informacion`, `proyectos.detalle:equipo`, `mis-tableros:full_acceso` | Solo lectura, solo proyectos donde está asignado |
| `Client` | Solo los proyectos donde esté asignado, con `proyectos.detalle:tableros:ver` y `proyectos.detalle:tableros:comentar` | Cliente externo que da seguimiento |

### 5.2 Matriz permisos × roles semilla

| Permiso | SuperAdmin | Admin | PM | Dev | Viewer | Client |
|---------|:----------:|:-----:|:--:|:---:|:------:|:------:|
| `dashboard:ver` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `clientes:ver:todos` | ✓ | ✓ | ✓ | — | — | — |
| `clientes:ver:asignados` | ✓ | ✓ | ✓ | — | — | — |
| `clientes:editar` | ✓ | ✓ | ✓ | — | — | — |
| `proyectos:ver:todos` | ✓ | ✓ | ✓ | — | — | — |
| `proyectos:ver:asignados` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `proyectos:editar` | ✓ | ✓ | ✓ | — | — | — |
| `proyectos.detalle:informacion` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `proyectos.detalle:ambientes` | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `proyectos.detalle:repositorios` | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `proyectos.detalle:credenciales` | ✓ | ✓ | ✓ | con nivel | — | — |
| `proyectos.detalle:tableros:ver` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `proyectos.detalle:tableros:comentar` | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| `proyectos.detalle:tableros:editar` | ✓ | ✓ | ✓ | ✓ | — | — |
| `proyectos.detalle:equipo` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `proyectos.detalle:screenshots:ver` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `proyectos.detalle:screenshots:editar` | ✓ | ✓ | ✓ | ✓ | — | — |
| `mis-tableros:full_acceso` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ambientes:ver:todos` | ✓ | ✓ | ✓ | — | — | — |
| `ambientes:ver:asignados` | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `ambientes:editar` | ✓ | ✓ | ✓ | — | — | — |
| `credenciales:ver:todos` | ✓ | ✓ | ✓ | — | — | — |
| `credenciales:ver:asignados` | ✓ | ✓ | ✓ | ✓ | — | — |
| `credenciales:nivel:full_acceso` | ✓ | ✓ | — | — | — | — |
| `credenciales:nivel:ver_todo` | ✓ | ✓ | ✓ | — | — | — |
| `credenciales:nivel:ver_basico` | ✓ | ✓ | ✓ | ✓ | — | — |
| `credenciales:editar` | ✓ | ✓ | — | — | — | — |
| `repositorios:ver:todos` | ✓ | ✓ | ✓ | — | — | — |
| `repositorios:ver:asignados` | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `repositorios:editar` | ✓ | ✓ | ✓ | — | — | — |
| `usuarios:ver:todos` | ✓ | ✓ | ✓ | — | — | — |
| `usuarios:editar:datos` | ✓ | ✓ | — | — | — | — |
| `usuarios:editar:password` | ✓ | ✓ | — | — | — | — |
| `usuarios:eliminar` | ✓ | — | — | — | — | — |
| `roles:ver:todos` | ✓ | ✓ | — | — | — | — |
| `roles:editar` | ✓ | ✓ | — | — | — | — |
| `roles:eliminar` | ✓ | — | — | — | — | — |
| `admin:configuracion` | ✓ | ✓ | — | — | — | — |

### 5.3 Permisos directos (overrides)

`usuarios_permisos_directos` permite conceder o denegar un permiso específico a un usuario sin crear un rol completo. Esto es útil para excepciones:

- **Caso 1**: Un Developer necesita acceso temporal de `credenciales:nivel:ver_todo` para un proyecto concreto. En lugar de crear un rol temporal, se le asigna el permiso directo sobre ese proyecto.
- **Caso 2**: Un PM que no debería eliminar clientes, se le asigna `clientes:eliminar = false` como denegación directa.

**Orden de resolución** (de mayor a menor prioridad):
1. Permiso directo denegado (`concedido = false`)
2. Permiso directo concedido (`concedido = true`)
3. Permiso concedido por rol
4. Permiso no disponible (denegado)

Esto permite que un permiso directo denegado **anule** cualquier rol.

---

## 6. Ámbito: Global vs Por-Proyecto

### 6.1 Cómo funciona

La columna `proyecto_id` en `usuarios_roles` determina el ámbito:

```
proyecto_id = NULL  → el rol aplica en TODOS los proyectos (ámbito global)
proyecto_id = X     → el rol aplica SOLO en el proyecto X
```

### 6.2 Ejemplos prácticos

| Usuario | Rol | proyecto_id | Efecto |
|---------|-----|-------------|--------|
| Ana | SuperAdmin | NULL | Ve y hace todo en todos los proyectos |
| Carlos | Developer | NULL | Ve **todos** los proyectos con permisos de Developer |
| Carlos | Developer | 7 | Ve **solo** el proyecto 7 con permisos de Developer |
| Maria | Viewer | 5 | Solo ve proyecto 5 en modo lectura |
| Maria | PM | NULL | También es PM global (ve todos los proyectos con permisos PM) |

### 6.3 Reglas de resolución

1. Se recolectan **todos** los registros de `usuarios_roles` para el usuario.
2. Se agrupan permisos de roles globales (proyecto_id IS NULL) y roles del proyecto actual.
3. Se aplican overrides directos (concedido/denegado).
4. Se aplican herencias (padre concede hijo).
5. Se validan exclusiones mutuas (XOR).

### 6.4 Ejemplo de consulta SQL

```sql
-- Obtener permisos efectivos de un usuario sobre un proyecto
WITH permisos_roles AS (
    SELECT DISTINCT rp.permiso_id
    FROM usuarios_roles ur
    JOIN roles_permisos rp ON rp.rol_id = ur.rol_id
    WHERE ur.usuario_id = @UsuarioId
      AND (ur.proyecto_id IS NULL OR ur.proyecto_id = @ProyectoId)
),
permisos_directos AS (
    SELECT permiso_id, concedido
    FROM usuarios_permisos_directos
    WHERE usuario_id = @UsuarioId
      AND (proyecto_id IS NULL OR proyecto_id = @ProyectoId)
)
SELECT p.codigo,
       CASE
           WHEN pd.concedido = 0 THEN FALSE   -- denegación directa gana
           WHEN pd.concedido = 1 THEN TRUE    -- concesión directa gana
           WHEN pr.permiso_id IS NOT NULL THEN TRUE
           ELSE FALSE
       END AS concedido
FROM permisos p
LEFT JOIN permisos_roles pr ON pr.permiso_id = p.id
LEFT JOIN permisos_directos pd ON pd.permiso_id = p.id
```

---

## 7. Brechas de seguridad y mitigaciones

### 7.1 Brecha: Usuario con dos roles sobre el mismo proyecto

**Problema**: Un usuario tiene rol Viewer (solo lectura) y Developer sobre el mismo proyecto. El sistema debe unir permisos, no reemplazar.

**Mitigación**: El motor de permisos resuelve como **unión** de todos los roles. Si un rol da `editar` y otro no, el usuario tiene `editar`. Si se quiere denegar explícitamente, se usa permiso directo denegado.

### 7.2 Brecha: Permiso de credenciales mal limitado

**Problema**: Un Developer con `credenciales:nivel:ver_basico` puede ver la pestaña de credenciales en el detalle del proyecto (porque `proyectos.detalle:credenciales` está activo) y hacer force-brute a IDs de credenciales para obtener datos que no debería.

**Mitigación**:
- El backend **nunca** devuelve passwords en endpoints si el permiso efectivo no es `full_acceso` o `ver_todo`.
- El endpoint GET `/api/credentiales/{id}` valida el nivel contra el proyecto.
- El endpoint `POST /api/credentiales/{id}/solicitar-password` requiere `ver_basico` y que exista un `full_acceso` en el proyecto.
- Se audita cada solicitud de password.

### 7.3 Brecha: Usuario eliminado pero con registro en usuarios_roles

**Problema**: Si se elimina un usuario sin CASCADE, roles huérfanos pueden causar errores o fugas.

**Mitigación**: La FK hacia `usuarios(id)` tiene `ON DELETE CASCADE`. El sistema nunca elimina físicamente usuarios (soft-delete: `usuarios.activo = FALSE`), y la resolución de permisos filtra `WHERE u.activo = TRUE`.

### 7.4 Brecha: Proyecto eliminado pero usuarios_roles con proyecto_id huérfano

**Problema**: Ídem anterior: FK con `ON DELETE CASCADE` en `proyecto_id`.

### 7.5 Brecha: Elevación de privilegios por modificación de rol

**Problema**: Un usuario con `roles:editar` podría asignarse permisos que no debería tener.

**Mitigación**:
- `roles:editar` es un permiso de alto privilegio (solo SuperAdmin y Admin lo tienen por defecto).
- Se audita cada cambio en `roles_permisos` con `created_at` y `usuario_id` del modificador.
- Un usuario no puede modificarse su propio rol (validación en backend).

### 7.6 Brecha: Acceso directo a API sin pasar por UI

**Problema**: El frontend oculta botones, pero el usuario llama la API directamente con Postman/curl.

**Mitigación**:
- **Toda la autorización se valida en el backend**, nunca solo en frontend.
- Cada endpoint tiene un `[AuthorizePermission("codigo:permiso")]` o similar.
- El frontend solo es una capa de UX; la seguridad real está en los controllers.

### 7.7 Brecha: IDs secuenciales en proyectos/credenciales

**Problema**: Un usuario con permiso limitado podría probar IDs numéricos.

**Mitigación**:
- Usar GUIDs (UUID v7) como claves públicas en lugar de IDs autoincrementales.
- Validar siempre que el usuario tiene acceso al proyecto en cuestión antes de devolver cualquier dato.

### 7.8 Brecha: Cache de permisos obsoleta

**Problema**: Se cambia un rol y el usuario sigue teniendo el permiso antiguo porque su sesión/token no se actualiza.

**Mitigación**:
- Almacenar permisos en un cache en memoria (Redis o MemoryCache) con TTL corto (5 min).
- Al modificar roles_permisos o usuarios_roles, invalidar la caché del usuario afectado.
- En cada request, verificar si la caché debe invalidarse (por `updated_at` del usuario).
- Opcional: usar JWT de corta duración (15 min) y refresh token.

### 7.9 Brecha: Un admin crea un rol con permisos contradictorios

**Problema**: Un rol personalizado podría combinar `clientes:eliminar` y `clientes:editar` sin `clientes:ver:todos`, lo que no tiene sentido.

**Mitigación**:
- Validar consistencia al guardar un rol: si incluye `X:editar`, debe incluir `X:ver:*` correspondiente.
- Mostrar advertencias en UI al crear roles.

### 7.10 Brecha: Usuario con rol global y rol de proyecto específico

**Problema**: Un usuario tiene `Developer` global (ve todos los proyectos) pero `Viewer` en el proyecto 5 (se le asigna explícitamente). Con la unión de roles, Developer le da más permisos que Viewer, anulando la intención de restringirlo.

**Mitigación**: Los permisos directos denegados son la herramienta correcta para este caso:
- Asignar al usuario `Developer` global.
- Asignar permiso directo denegado sobre `proyectos:ver:asignados` con `proyecto_id = 5`.
- Así no puede ver el proyecto 5 porque el permiso directo denegado tiene prioridad.

O bien, si en lugar de restringir se quiere cambiar el nivel: asignar `Developer` global + permiso directo para `credenciales:nivel:ver_todo` sobre proyecto 5.

---

## 8. Implementación backend (.NET)

### 8.1 Atributo personalizado

```csharp
[AttributeUsage(AttributeTargets.Method | AttributeTargets.Class, AllowMultiple = true)]
public class RequirePermissionAttribute : AuthorizeAttribute
{
    public string PermissionCode { get; }

    public RequirePermissionAttribute(string permissionCode)
    {
        PermissionCode = permissionCode;
    }
}
```

### 8.2 PermissionService

```csharp
public interface IPermissionService
{
    Task<bool> UserHasPermissionAsync(int userId, string permissionCode, int? projectId = null);
    Task<Dictionary<string, bool>> GetEffectivePermissionsAsync(int userId, int? projectId = null);
}

public class PermissionService : IPermissionService
{
    public async Task<bool> UserHasPermissionAsync(int userId, string permissionCode, int? projectId = null)
    {
        // 1. Verificar si usuario está activo
        // 2. Obtener todos los roles del usuario (globales + del proyecto)
        // 3. Obtener permisos de esos roles (incluyendo herencias)
        // 4. Aplicar overrides directos
        // 5. Validar XOR
        // 6. Retornar bool
    }
}
```

### 8.3 PermissionMiddleware / Policy

```csharp
// En Program.cs
builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("Permission", policy =>
        policy.Requirements.Add(new PermissionRequirement()));
});

// PermissionHandler
public class PermissionHandler : AuthorizationHandler<PermissionRequirement>
{
    protected override async Task HandleRequirementAsync(
        AuthorizationHandlerContext context,
        PermissionRequirement requirement)
    {
        // Leer el atributo RequirePermission del endpoint
        // Validar con IPermissionService
    }
}
```

### 8.4 Endpoints protectores

```csharp
[HttpGet("{id}")]
[RequirePermission("credenciales:nivel:ver_todo")]
public async Task<IActionResult> GetCredencial(int id, [FromQuery] int proyectoId)
{
    // Validar que el usuario tiene acceso al proyecto
    // Devolver datos según el nivel de permiso
}
```

---

## 9. Implementación frontend (Angular)

### 9.1 Servicio de permisos

```typescript
@Injectable({ providedIn: 'root' })
export class PermissionService {
  private permissionsCache = new Map<string, boolean>();

  hasPermission(code: string, projectId?: number): boolean {
    // Buscar en caché o llamar API
    return this.permissionsCache.get(this.cacheKey(code, projectId)) ?? false;
  }

  // Para mostrar/ocultar elementos en templates
  can(code: string, projectId?: number): Observable<boolean> {
    return of(this.hasPermission(code, projectId));
  }
}
```

### 9.2 Directiva estructural

```typescript
@Directive({ selector: '[appHasPermission]' })
export class HasPermissionDirective {
  @Input('appHasPermission') permissionCode!: string;
  @Input('appHasPermissionProject') projectId?: number;

  constructor(
    private templateRef: TemplateRef<any>,
    private viewContainer: ViewContainerRef,
    private permissionService: PermissionService
  ) {}

  ngOnInit() {
    if (this.permissionService.hasPermission(this.permissionCode, this.projectId)) {
      this.viewContainer.createEmbeddedView(this.templateRef);
    } else {
      this.viewContainer.clear();
    }
  }
}
```

### 9.3 Uso en templates

```html
<button *appHasPermission="'credenciales:editar'">Nueva Credencial</button>

<div *appHasPermission="'credenciales:nivel:ver_todo'; projectId: proyecto.id">
  <label>Contraseña</label>
  <input type="text" [value]="credencial.password" readonly />
</div>
```

### 9.4 Route guards

```typescript
const routes: Routes = [
  {
    path: 'admin/usuarios',
    component: UsuariosComponent,
    canActivate: [PermissionGuard],
    data: { permission: 'usuarios:ver:todos' }
  },
  {
    path: 'proyectos/:id/credenciales',
    component: CredencialesComponent,
    canActivate: [ProjectPermissionGuard],
    data: { permission: 'proyectos.detalle:credenciales' }
  }
];
```

---

## 10. UI de administración

### 10.1 Gestión de roles

```
/admin/roles
├── Lista de roles (tabla con nombre, descripción, #usuarios, acciones)
├── Crear rol (modal/página con nombre, descripción)
├── Editar rol
│   ├── Nombre, descripción
│   ├── Selector de permisos → árbol categorizado por módulo
│   │   ├── Dashboard
│   │   ├── Clientes
│   │   │   ├── ☐ Ver todos
│   │   │   ├── ☐ Ver asignados (se marca automático si se marca Ver todos)
│   │   │   └── ☐ Editar
│   │   ├── Proyectos
│   │   │   ├── ☐ Ver todos
│   │   │   ├── ☐ Ver asignados
│   │   │   ├── ☐ Editar
│   │   │   └── Detalle
│   │   │       ├── ☐ Información (siempre activo)
│   │   │       ├── ☐ Ambientes
│   │   │       ├── ☐ Repositorios
│   │   │       ├── ☐ Credenciales
│   │   │       ├── Tableros
│   │   │       │   ├── ☐ Ver
│   │   │       │   ├── ☐ Comentar
│   │   │       │   └── ☐ Editar
│   │   │       ├── ☐ Equipo (siempre activo)
│   │   │       └── Screenshots
│   │   │           ├── ☐ Ver
│   │   │           └── ☐ Editar
│   │   ├── Mis Tableros
│   │   ├── Ambientes
│   │   ├── Credenciales
│   │   │   ├── ☐ Ver todos
│   │   │   ├── ☐ Ver asignados
│   │   │   ├── Nivel
│   │   │   │   └── ☐ Full acceso | ☐ Ver todo | ☐ Ver básico (radio, XOR)
│   │   │   └── ☐ Editar
│   │   ├── Repositorios
│   │   ├── Usuarios
│   │   └── Roles
│   └── Guardar
└── Eliminar rol (confirmación, no si es_sistema)
```

### 10.2 Asignación de roles a usuarios

```
/admin/usuarios/{id}/roles
├── Selector de rol (dropdown)
├── Ámbito: Global ☐  |  Proyecto específico: [selector de proyecto]
├── Botón: Asignar
├── Tabla de asignaciones actuales
│   ├── Rol | Ámbito | Proyecto | Fecha asignación | Acción (quitar)
└── Sección de overrides (permisos directos)
    ├── Selector de permiso
    ├── Proyecto (opcional, si el permiso lo requiere)
    ├── Conceder ☐ / Denegar ☐
    └── Botón: Agregar override
```

---

## 11. Semillas y migraciones

### 11.1 Primera migración: permisos

```sql
INSERT INTO permisos (codigo, nombre, modulo, padre_id, herencia, global_scope, orden) VALUES
('dashboard:ver',                      'Ver Dashboard',                      'dashboard',   NULL, 'none', TRUE,  1),
('clientes:ver:todos',                 'Ver todos los clientes',            'clientes',    NULL, 'padre_concede_hijo', TRUE,  2),
('clientes:ver:asignados',             'Ver clientes asignados',            'clientes',    NULL, 'none', TRUE,  3),
('clientes:editar',                    'Editar clientes',                   'clientes',    NULL, 'none', TRUE,  4),
-- ... resto del catálogo
```

### 11.2 Segunda migración: roles semilla

```sql
-- SuperAdmin: se le asigna un permiso especial "superadmin" que concede todo automáticamente
INSERT INTO roles (nombre, descripcion, es_sistema) VALUES
('SuperAdmin',       'Acceso total al sistema',                         TRUE),
('Admin',            'Administración sin eliminar usuarios ni roles',   TRUE),
('ProjectManager',   'Gestión completa de proyectos y equipos',         TRUE),
('Developer',        'Miembro técnico de proyectos',                    TRUE),
('Viewer',           'Solo lectura en proyectos asignados',             TRUE),
('Client',           'Cliente externo con acceso a tableros',          TRUE);
```

### 11.3 Tercera migración: permisos → roles semilla

```sql
INSERT INTO roles_permisos (rol_id, permiso_id)
SELECT r.id, p.id FROM roles r, permisos p
WHERE r.nombre = 'SuperAdmin';
-- SuperAdmin obtiene todos los permisos del catálogo

INSERT INTO roles_permisos (rol_id, permiso_id)
SELECT r.id, p.id FROM roles r, permisos p
WHERE r.nombre = 'Admin'
  AND p.codigo NOT IN ('usuarios:eliminar', 'roles:eliminar');
-- Admin obtiene todos excepto eliminar usuarios y roles
-- ... etc
```

### 11.4 Consideraciones sobre migraciones futuras

- Si se agrega un nuevo permiso al catálogo, se debe decidir qué roles lo obtienen por defecto y crear una migración para `roles_permisos`.
- Los roles personalizados (es_sistema = FALSE) **no** reciben el nuevo permiso automáticamente; el administrador debe asignarlo manualmente.

---

## 12. Plan de implementación por fases

### Fase 1: Fundación (1-2 semanas)

1. Crear tablas de base de datos (`permisos`, `roles`, `roles_permisos`, `usuarios_roles`, `usuarios_permisos_directos`).
2. Crear migraciones con semillas (catálogo de permisos, roles semilla, asignaciones básicas).
3. Crear `PermissionService` en backend con resolución básica (roles + herencia + overrides).
4. Agregar middleware/attribute `[RequirePermission]`.
5. Crear endpoint `GET /api/usuarios/me/permisos?proyectoId=X`.

### Fase 2: Protección de endpoints (1 semana)

6. Agregar `[RequirePermission]` a todos los endpoints existentes (al menos un permiso por cada endpoint).
7. Agregar validación de permiso en cada consulta de listado (filtrar por proyecto si aplica).
8. Escribir tests unitarios e integración del `PermissionService`.

### Fase 3: Frontend (2 semanas)

9. Crear `PermissionService` en Angular con caché.
10. Crear directiva `*appHasPermission`.
11. Crear `PermissionGuard` para rutas.
12. Refactorizar templates para ocultar/mostrar elementos según permisos.
13. Agregar indicador visual cuando un permiso está limitado (ej: candado en credenciales).

### Fase 4: UI de administración (2-3 semanas)

14. CRUD de roles: listar, crear, editar (con árbol de permisos), eliminar.
15. CRUD de asignaciones: asignar rol a usuario, definir ámbito global o por proyecto.
16. Overrides directos desde perfil de usuario.
17. Historial de auditoría: quién asignó qué rol/cuándo.

### Fase 5: Avanzado (1-2 semanas)

18. Sistema de solicitud de password para `ver_basico`: notificación al `full_acceso` del proyecto.
19. Cache distribuido (Redis) con invalidación automática.
20. Auditoría completa de cambios en permisos (tabla `auditoria_permisos`).
21. Dashboard de reportes: "¿quién tiene acceso a qué?".

---

## Anexo A: Ejemplo de resolución de permisos

**Caso**: María tiene los siguientes roles:

1. `Developer` **global** (proyecto_id = NULL)
2. `Viewer` **proyecto 5**

**Consulta**: ¿María puede ver tableros en el proyecto 5?

| Rol | Permisos relevantes |
|-----|---------------------|
| Developer (global) | `proyectos.detalle:tableros:ver` → TRUE |
| Viewer (proyecto 5) | `proyectos.detalle:tableros:ver` → TRUE |
| **Resultado** | **TRUE** (unión de roles) |

**Consulta**: ¿María puede editar tableros en el proyecto 5?

| Rol | Permisos relevantes |
|-----|---------------------|
| Developer (global) | `proyectos.detalle:tableros:editar` → TRUE |
| Viewer (proyecto 5) | — |
| **Resultado** | **TRUE** (Developer global se lo concede) |

**Consulta**: ¿María puede ver credenciales con password en el proyecto 5?

| Rol | Permisos relevantes |
|-----|---------------------|
| Developer (global) | `credenciales:nivel:ver_basico` → TRUE |
| **Resultado** | **TRUE para ver_basico** (sin password). **FALSE para ver_todo** (no tiene ese nivel). |

Si se quiere bloquear a María del proyecto 5 por completo: agregar permiso directo denegado `proyectos:ver:asignados` con proyecto_id = 5.

---

## Anexo B: Tabla de auditoría

```sql
CREATE TABLE auditoria_permisos (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,
    usuario_id      INT NOT NULL REFERENCES usuarios(id),
    accion          VARCHAR(40) NOT NULL, -- 'rol_asignado', 'rol_removido', 'permiso_concedido', 'permiso_denegado', 'rol_creado', 'rol_modificado'
    detalle_json    JSON NOT NULL,        -- { "rol_id": 5, "proyecto_id": null, "concedido": true }
    realizado_por   INT NOT NULL REFERENCES usuarios(id),
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_usuario (usuario_id),
    INDEX idx_fecha (created_at)
);
```

Esta tabla permite responder preguntas como:
- ¿Quién le dio permiso X a Y?
- ¿Qué cambió en el rol Z y quién lo hizo?
- ¿Cuándo fue la última modificación de permisos del usuario A?

---

## Anexo C: Glosario

| Término | Definición |
|---------|-----------|
| Ámbito (Scope) | Alcance de un permiso: **Global** (aplica en todo el sistema) o **Por-Proyecto** (aplica solo sobre proyectos específicos) |
| Herencia | Mecanismo por el cual un permiso concede automáticamente otro permiso. Ej: "Ver todos" concede "Ver asignados" |
| Override | Permiso directo asignado a un usuario por fuera de un rol, con prioridad sobre roles |
| Rol | Conjunto de permisos agrupados bajo un nombre. Puede ser de sistema (inmutable) o personalizado |
| Rol semilla | Rol incluido en la migración inicial que no puede eliminarse |
| URP | Usuario-Rol-Proyecto: la tripleta que define qué rol tiene un usuario sobre qué proyecto |
| XOR (exclusión mutua) | Grupo de permisos donde solo uno puede estar activo a la vez (ej: niveles de credenciales) |
