# 08 — Módulo Kanban (Tableros estilo Trello por proyecto)

> Plan de implementación detallado para añadir un Kanban potente a ConsultoraPro.
> Jerarquía: **Proyecto → Tablero(s) → Columnas → Tarjetas**. Cada tarjeta recibe un
> **código legible e inmutable** del tipo `REP-TAR-001`.

---

## 1. Objetivo y alcance

Agregar un sistema de gestión de trabajo tipo Trello, **anidado dentro de cada proyecto**:

- Un proyecto puede tener **varios tableros** (p. ej. "Tareas", "Bugs", "Roadmap").
- Cada tablero tiene **columnas** ordenables (p. ej. "Por hacer", "En progreso", "Hecho").
- Cada columna contiene **tarjetas** ordenables que se arrastran entre columnas.
- Cada tarjeta tiene **responsables** (uno o varios miembros del proyecto), etiquetas,
  fecha límite, descripción, checklist, comentarios y adjuntos.
- Cada tablero tiene **responsables** (owners del tablero).
- **Cada tarjeta genera un código** legible único: `{CLAVE_PROYECTO}-{CLAVE_TABLERO}-{NNN}`.
  - Proyecto `Repsol` (clave `REP`) + tablero `Tareas` (clave `TAR`) → `REP-TAR-001`, `REP-TAR-002`, …
- Drag & drop fluido (columnas y tarjetas), filtros, búsqueda y permisos por rol.

### Fuera de alcance (fase posterior)

- Automatizaciones tipo "Butler" de Trello.
- Vistas alternativas (timeline/Gantt, calendario) — se deja preparado el modelo pero no la UI.
- Tiempo real con WebSockets/SignalR (ver [§13](#13-consideraciones-de-tiempo-real-opcional)).

---

## 2. Decisiones de diseño clave

Estas decisiones rigen el resto del documento. Si alguna se cambia, hay que revisar el plan.

| # | Decisión | Resolución propuesta |
|---|----------|----------------------|
| D1 | **¿Dónde vive la clave del proyecto?** | Nuevo campo `Clave` en `Proyecto` (3–8 letras, único). Default: derivado del nombre (primeras letras alfanuméricas en mayúscula). Editable. |
| D2 | **¿Dónde vive la clave del tablero?** | Campo `Clave` en `Tablero` (2–6 letras, único **dentro del proyecto**). Default derivado del nombre. |
| D3 | **¿Cómo se numera la tarjeta?** | Contador `SecuenciaActual` en el `Tablero`. Se incrementa de forma atómica al crear la tarjeta. El número se guarda en `Tarjeta.Numero`. |
| D4 | **¿El código cambia si la tarjeta se mueve?** | **No.** El código es inmutable y queda ligado al tablero donde **nació**. Si se mueve a otro tablero (fase 2), conserva su código original. |
| D5 | **Padding del número** | 3 dígitos (`001`). Si supera `999`, crece naturalmente (`1000`). El formato no se rompe. |
| D6 | **Posicionamiento (orden) de columnas y tarjetas** | Campo `Orden` tipo `double`/`decimal` con técnica de "rango fraccional" (LexoRank simplificado): al insertar entre A y B, `orden = (A+B)/2`. Reduce reescrituras masivas en drag & drop. |
| D7 | **Borrado** | Soft delete (`Activo = false`) en tablero, columna y tarjeta, coherente con el resto del backend (clientes, ambientes, etc.). |
| D8 | **Responsables del tablero vs de la tarjeta** | Dos relaciones distintas: `TableroMiembro` (owners/colaboradores del tablero) y `TarjetaResponsable` (asignados a una tarjeta). Ambos referencian `ApplicationUser`. |
| D9 | **¿Quién puede asignarse?** | Cualquier `ApplicationUser` activo. (Opcional: restringir a miembros del proyecto vía `ProyectoMiembro` — ver [§12](#12-preguntas-abiertas)). |

---

## 3. Modelo de dominio (backend `ConsultoraPro.Domain`)

Nuevas entidades en `src/ConsultoraPro.Domain/Models/`. Siguen el estilo existente
(`Guid Id`, navegaciones `= null!`, colecciones inicializadas, `Activo`, timestamps UTC).

### 3.1 Diagrama de relaciones

```
Proyecto (1) ──< (N) Tablero
                      │
                      ├──< (N) TableroMiembro >── (1) ApplicationUser
                      ├──< (N) ColumnaKanban
                      │            └──< (N) Tarjeta
                      │                       ├──< (N) TarjetaResponsable >── ApplicationUser
                      │                       ├──< (N) TarjetaEtiqueta >── EtiquetaKanban
                      │                       ├──< (N) ChecklistItem
                      │                       ├──< (N) ComentarioTarjeta >── ApplicationUser
                      │                       ├──< (N) AdjuntoTarjeta
                      │                       └──< (N) ActividadTarjeta (log)
                      └──< (N) EtiquetaKanban  (catálogo de etiquetas del tablero)
```

### 3.2 Entidades

**`Tablero`** (`Models/Tablero.cs`)
```csharp
public class Tablero
{
    public Guid Id { get; set; }
    public Guid ProyectoId { get; set; }
    public Proyecto Proyecto { get; set; } = null!;
    public string Nombre { get; set; } = string.Empty;     // "Tareas"
    public string Clave { get; set; } = string.Empty;      // "TAR" (único dentro del proyecto)
    public string? Descripcion { get; set; }
    public string ColorClass { get; set; } = "blue";
    public int Orden { get; set; }                          // orden del tablero dentro del proyecto
    public int SecuenciaActual { get; set; }                // contador para el código de tarjeta (D3)
    public bool Activo { get; set; } = true;
    public DateTime FechaCreacion { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public ICollection<ColumnaKanban> Columnas { get; set; } = new List<ColumnaKanban>();
    public ICollection<TableroMiembro> Miembros { get; set; } = new List<TableroMiembro>();
    public ICollection<EtiquetaKanban> Etiquetas { get; set; } = new List<EtiquetaKanban>();
}
```

**`TableroMiembro`** (`Models/TableroMiembro.cs`) — responsables del tablero
```csharp
public class TableroMiembro
{
    public Guid Id { get; set; }
    public Guid TableroId { get; set; }
    public Tablero Tablero { get; set; } = null!;
    public Guid UsuarioId { get; set; }
    public ApplicationUser Usuario { get; set; } = null!;
    public RolTablero Rol { get; set; } = RolTablero.Colaborador;  // Owner | Colaborador
    public DateTime FechaAsignacion { get; set; } = DateTime.UtcNow;
}
```

**`ColumnaKanban`** (`Models/ColumnaKanban.cs`)
```csharp
public class ColumnaKanban
{
    public Guid Id { get; set; }
    public Guid TableroId { get; set; }
    public Tablero Tablero { get; set; } = null!;
    public string Nombre { get; set; } = string.Empty;     // "Por hacer"
    public double Orden { get; set; }                       // rango fraccional (D6)
    public int? LimiteWip { get; set; }                     // WIP limit opcional
    public bool Activo { get; set; } = true;
    public DateTime FechaCreacion { get; set; } = DateTime.UtcNow;

    public ICollection<Tarjeta> Tarjetas { get; set; } = new List<Tarjeta>();
}
```

**`Tarjeta`** (`Models/Tarjeta.cs`)
```csharp
public class Tarjeta
{
    public Guid Id { get; set; }
    public Guid ColumnaId { get; set; }
    public ColumnaKanban Columna { get; set; } = null!;
    public Guid TableroId { get; set; }                     // desnormalizado: tablero "dueño" del código
    public Tablero Tablero { get; set; } = null!;
    public int Numero { get; set; }                         // 1, 2, 3...  (D3)
    public string Codigo { get; set; } = string.Empty;      // "REP-TAR-001" (inmutable, único global)
    public string Titulo { get; set; } = string.Empty;
    public string? Descripcion { get; set; }                // markdown
    public double Orden { get; set; }                       // rango fraccional dentro de la columna (D6)
    public PrioridadTarjeta Prioridad { get; set; } = PrioridadTarjeta.Media;
    public DateTime? FechaLimite { get; set; }
    public DateTime? FechaInicio { get; set; }
    public bool Completada { get; set; }
    public Guid? CreadaPorId { get; set; }
    public ApplicationUser? CreadaPor { get; set; }
    public bool Activo { get; set; } = true;
    public DateTime FechaCreacion { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public ICollection<TarjetaResponsable> Responsables { get; set; } = new List<TarjetaResponsable>();
    public ICollection<TarjetaEtiqueta> Etiquetas { get; set; } = new List<TarjetaEtiqueta>();
    public ICollection<ChecklistItem> Checklist { get; set; } = new List<ChecklistItem>();
    public ICollection<ComentarioTarjeta> Comentarios { get; set; } = new List<ComentarioTarjeta>();
    public ICollection<AdjuntoTarjeta> Adjuntos { get; set; } = new List<AdjuntoTarjeta>();
    public ICollection<ActividadTarjeta> Actividades { get; set; } = new List<ActividadTarjeta>();
}
```

**`TarjetaResponsable`** (`Models/TarjetaResponsable.cs`)
```csharp
public class TarjetaResponsable
{
    public Guid Id { get; set; }
    public Guid TarjetaId { get; set; }
    public Tarjeta Tarjeta { get; set; } = null!;
    public Guid UsuarioId { get; set; }
    public ApplicationUser Usuario { get; set; } = null!;
    public DateTime FechaAsignacion { get; set; } = DateTime.UtcNow;
}
```

**`EtiquetaKanban`** (`Models/EtiquetaKanban.cs`) — catálogo de etiquetas por tablero
```csharp
public class EtiquetaKanban
{
    public Guid Id { get; set; }
    public Guid TableroId { get; set; }
    public Tablero Tablero { get; set; } = null!;
    public string Nombre { get; set; } = string.Empty;     // "Backend", "Urgente"
    public string ColorClass { get; set; } = "blue";
    public bool Activo { get; set; } = true;
}
```

**`TarjetaEtiqueta`** (`Models/TarjetaEtiqueta.cs`) — relación N:N
```csharp
public class TarjetaEtiqueta
{
    public Guid TarjetaId { get; set; }
    public Tarjeta Tarjeta { get; set; } = null!;
    public Guid EtiquetaId { get; set; }
    public EtiquetaKanban Etiqueta { get; set; } = null!;
}
```

**`ChecklistItem`** (`Models/ChecklistItem.cs`)
```csharp
public class ChecklistItem
{
    public Guid Id { get; set; }
    public Guid TarjetaId { get; set; }
    public Tarjeta Tarjeta { get; set; } = null!;
    public string Texto { get; set; } = string.Empty;
    public bool Completado { get; set; }
    public double Orden { get; set; }
}
```

**`ComentarioTarjeta`** (`Models/ComentarioTarjeta.cs`)
```csharp
public class ComentarioTarjeta
{
    public Guid Id { get; set; }
    public Guid TarjetaId { get; set; }
    public Tarjeta Tarjeta { get; set; } = null!;
    public Guid AutorId { get; set; }
    public ApplicationUser Autor { get; set; } = null!;
    public string Texto { get; set; } = string.Empty;
    public DateTime FechaCreacion { get; set; } = DateTime.UtcNow;
    public DateTime? EditadoEn { get; set; }
}
```

**`AdjuntoTarjeta`** (`Models/AdjuntoTarjeta.cs`) — reutiliza el `IFileStorage`/`uploads` ya existente (ver `Infrastructure/Storage` y el patrón de `Screenshot`)
```csharp
public class AdjuntoTarjeta
{
    public Guid Id { get; set; }
    public Guid TarjetaId { get; set; }
    public Tarjeta Tarjeta { get; set; } = null!;
    public string Nombre { get; set; } = string.Empty;
    public string Url { get; set; } = string.Empty;
    public string? ContentType { get; set; }
    public long TamanoBytes { get; set; }
    public Guid? SubidoPorId { get; set; }
    public ApplicationUser? SubidoPor { get; set; }
    public DateTime FechaSubida { get; set; } = DateTime.UtcNow;
}
```

**`ActividadTarjeta`** (`Models/ActividadTarjeta.cs`) — log de auditoría/actividad (estilo `AuditoriaCredencial`)
```csharp
public class ActividadTarjeta
{
    public Guid Id { get; set; }
    public Guid TarjetaId { get; set; }
    public Tarjeta Tarjeta { get; set; } = null!;
    public Guid? UsuarioId { get; set; }
    public ApplicationUser? Usuario { get; set; }
    public TipoActividadTarjeta Tipo { get; set; }          // Creada, Movida, Asignada, Comentada...
    public string? Detalle { get; set; }                    // texto legible o JSON
    public DateTime Fecha { get; set; } = DateTime.UtcNow;
}
```

### 3.3 Enums (`src/ConsultoraPro.Domain/Enums/`)

```csharp
// RolTablero.cs
public enum RolTablero { Owner, Colaborador }

// PrioridadTarjeta.cs
public enum PrioridadTarjeta { Baja, Media, Alta, Critica }

// TipoActividadTarjeta.cs
public enum TipoActividadTarjeta
{
    Creada, Editada, Movida, Asignada, Desasignada,
    Comentada, EtiquetaAgregada, EtiquetaQuitada,
    Completada, Reabierta, Archivada, Restaurada
}
```

### 3.4 Cambio en entidad existente `Proyecto`

Añadir el campo `Clave` (D1) y la colección de tableros:

```csharp
// Proyecto.cs  (añadir)
public string Clave { get; set; } = string.Empty;          // "REP"
public ICollection<Tablero> Tableros { get; set; } = new List<Tablero>();
```

### 3.5 Interfaces de repositorio (`Domain/Interfaces/`)

- `ITableroRepository`
- `IColumnaKanbanRepository`
- `ITarjetaRepository`
- (Etiquetas, comentarios, checklist y adjuntos se manejan vía el repositorio de tarjeta o repos pequeños dedicados, a criterio; recomendado: `ITableroRepository` para tablero+columnas+etiquetas y `ITarjetaRepository` para tarjeta y sus hijos).

---

## 4. Generación del código de tarjeta (núcleo del requisito)

### 4.1 Algoritmo

Al crear una tarjeta:

1. Cargar el `Tablero` (con su `Clave` y `SecuenciaActual`) y el `Proyecto` (con su `Clave`).
2. `nuevoNumero = SecuenciaActual + 1`.
3. `codigo = $"{proyecto.Clave}-{tablero.Clave}-{nuevoNumero:D3}"`.
4. Persistir `Tarjeta { Numero = nuevoNumero, Codigo = codigo }` y `tablero.SecuenciaActual = nuevoNumero`
   **en la misma transacción**.

### 4.2 Concurrencia (importante)

Dos usuarios creando tarjetas en el mismo tablero a la vez no deben recibir el mismo número.
Opciones, de simple a robusta:

- **Recomendada:** envolver en transacción + `SELECT ... FOR UPDATE` sobre la fila del tablero
  (en EF Core con Pomelo/MySQL: `context.Database.BeginTransactionAsync()` +
  `FromSqlRaw("SELECT * FROM Tableros WHERE Id = {0} FOR UPDATE", id)`), incrementar, guardar, commit.
- **Alternativa:** token de concurrencia (`[Timestamp]`/`RowVersion`) en `Tablero` + reintento (`DbUpdateConcurrencyException`).
- Añadir **índice único** sobre `(TableroId, Numero)` y sobre `Tarjeta.Codigo` como red de seguridad.

### 4.3 Generación de claves por defecto

Helper en `Application` (p. ej. `KanbanCodeHelper`):

```
DeriveKey(nombre, longitud) =>
   tomar letras/dígitos de 'nombre', quitar tildes/espacios, MAYÚSCULAS,
   recortar a 'longitud' (proyecto 3, tablero 3). Si colisiona, sufijo numérico.
```

- "Repsol" → `REP`; "Tareas" → `TAR`; "QA / Bugs" → `QAB`.
- La clave es **editable** por el usuario en el formulario (con validación de unicidad).

---

## 5. Capa de aplicación (`ConsultoraPro.Application`)

### 5.1 DTOs (`DTOs/Kanban/`)

- `TableroDto`, `TableroDetalleDto` (incluye columnas + tarjetas + etiquetas + miembros),
  `CreateTableroDto`, `UpdateTableroDto`.
- `ColumnaDto`, `CreateColumnaDto`, `UpdateColumnaDto`, `ReordenarColumnaDto`.
- `TarjetaDto` (resumen para el board), `TarjetaDetalleDto` (modal completo),
  `CreateTarjetaDto`, `UpdateTarjetaDto`, `MoverTarjetaDto`.
- `TarjetaResponsableDto`, `EtiquetaDto`, `ChecklistItemDto`, `ComentarioDto`, `AdjuntoDto`, `ActividadDto`.
- `MoverTarjetaDto`:
  ```csharp
  public record MoverTarjetaDto(Guid ColumnaDestinoId, Guid? AntesDeTarjetaId, Guid? DespuesDeTarjetaId);
  ```
  El servicio calcula el nuevo `Orden` fraccional con los vecinos.

### 5.2 Servicios e interfaces (`Interfaces/` + `Services/`)

- `ITableroService` / `TableroService`
- `IColumnaService` / `ColumnaService`
- `ITarjetaService` / `TarjetaService` (incluye mover, asignar, etiquetas, checklist, comentarios, adjuntos)

Responsabilidades clave de `TarjetaService`:
- `CreateAsync`: genera código (§4), registra `ActividadTarjeta.Creada`.
- `MoverAsync`: valida tablero/columna, recalcula `Orden`, opcionalmente `Completada` si la columna destino es "terminal", registra `Movida`.
- `AsignarResponsableAsync` / `QuitarResponsableAsync`: valida usuario activo, registra actividad.
- Validaciones de pertenencia: la columna debe pertenecer al tablero; el tablero al proyecto.

### 5.3 Validadores (FluentValidation, `Validators/Kanban/`)

- `CreateTableroValidator`: `Nombre` requerido (≤200), `Clave` 2–6 alfanumérico mayúsculas, `ProyectoId` existe.
- `CreateColumnaValidator`, `CreateTarjetaValidator` (`Titulo` requerido ≤200), `MoverTarjetaValidator`, etc.

### 5.4 AutoMapper (`Profiles/AutoMapperProfile.cs`)

Añadir mapeos `Tablero↔Dto`, `ColumnaKanban↔Dto`, `Tarjeta↔Dto` (incluyendo proyección de
responsables → lista de `{ usuarioId, nombre, iniciales }`, etiquetas, conteo de checklist
`completados/total`, conteo de comentarios y adjuntos para los badges del board).

### 5.5 Registro DI

Añadir los servicios en `Application/DependencyInjection.cs` y los repositorios en
`Infrastructure/DependencyInjection.cs` (mismo patrón que `IAmbienteService`, etc.).

---

## 6. Persistencia (`ConsultoraPro.Infrastructure`)

### 6.1 `AppDbContext`

Añadir los `DbSet<>`:

```csharp
public DbSet<Tablero> Tableros => Set<Tablero>();
public DbSet<TableroMiembro> TableroMiembros => Set<TableroMiembro>();
public DbSet<ColumnaKanban> ColumnasKanban => Set<ColumnaKanban>();
public DbSet<Tarjeta> Tarjetas => Set<Tarjeta>();
public DbSet<TarjetaResponsable> TarjetaResponsables => Set<TarjetaResponsable>();
public DbSet<EtiquetaKanban> EtiquetasKanban => Set<EtiquetaKanban>();
public DbSet<TarjetaEtiqueta> TarjetaEtiquetas => Set<TarjetaEtiqueta>();
public DbSet<ChecklistItem> ChecklistItems => Set<ChecklistItem>();
public DbSet<ComentarioTarjeta> ComentariosTarjeta => Set<ComentarioTarjeta>();
public DbSet<AdjuntoTarjeta> AdjuntosTarjeta => Set<AdjuntoTarjeta>();
public DbSet<ActividadTarjeta> ActividadesTarjeta => Set<ActividadTarjeta>();
```

Configuración en `OnModelCreating` (mismo estilo que las entidades actuales):

- **Tablero**: `Nombre` req. ≤200; `Clave` req. ≤8; índice **único** `(ProyectoId, Clave)`;
  enum vía string si aplica; FK a `Proyecto` `OnDelete(Restrict)`; default `CURRENT_TIMESTAMP(6)`.
- **TableroMiembro**: índice único `(TableroId, UsuarioId)`; `Rol` `HasConversion<string>()`;
  FKs `Cascade` (tablero) y `Restrict` (usuario).
- **ColumnaKanban**: `Nombre` req. ≤120; índice `(TableroId, Activo)`; FK a tablero `Cascade`.
- **Tarjeta**: `Titulo` req. ≤200; `Codigo` req. ≤40 con índice **único**; índice único
  `(TableroId, Numero)`; índice `(ColumnaId, Activo)`; `Prioridad` `HasConversion<string>()`;
  FK a columna `Restrict` (la tarjeta no se borra al borrar columna; se reubica), FK a tablero `Restrict`,
  FK `CreadaPor` `Restrict`.
- **TarjetaResponsable**: índice único `(TarjetaId, UsuarioId)`; FK tarjeta `Cascade`, usuario `Restrict`.
- **EtiquetaKanban**: `Nombre` ≤80; FK tablero `Cascade`.
- **TarjetaEtiqueta**: clave compuesta `(TarjetaId, EtiquetaId)`; FKs `Cascade`.
- **ChecklistItem / ComentarioTarjeta / AdjuntoTarjeta / ActividadTarjeta**: FK a tarjeta `Cascade`;
  autores/usuarios `Restrict`; defaults de fecha `CURRENT_TIMESTAMP(6)`.

> Añadir el manejo de `UpdatedAt` para `Tablero` y `Tarjeta` en `ApplyAutomaticTimestamps()`
> (igual que `Proyecto`/`Credencial`).

### 6.2 Migración

```bash
dotnet ef migrations add AddKanban \
  --project src/ConsultoraPro.Infrastructure \
  --startup-project src/ConsultoraPro.API
```

Migración adicional (o incluida) para **poblar `Proyecto.Clave`** en proyectos existentes:
derivar de `Nombre` y garantizar unicidad (sufijo numérico si colisiona). Se aplica
automáticamente al arranque (`InitializeDatabaseAsync` ya ejecuta migraciones).

### 6.3 Repositorios

`TableroRepository`, `ColumnaKanbanRepository`, `TarjetaRepository` con los `Include`
necesarios (p. ej. `GetTableroDetalle` trae columnas→tarjetas→responsables→etiquetas).
**Ojo con rendimiento**: usar `AsSplitQuery()` para el detalle del tablero (varias colecciones).

### 6.4 Seed (`Data/Seed/DataSeeder.cs`)

Para los proyectos de ejemplo, sembrar:
- `Clave` del proyecto (REP, TEL, BBVA…).
- Un tablero `Tareas` (clave `TAR`) con 3 columnas: `Por hacer`, `En progreso`, `Hecho`.
- 3–4 tarjetas demo con código `REP-TAR-001…` y algún responsable, para ver el board funcionando.

---

## 7. API REST (`ConsultoraPro.API/Controllers`)

Convención existente: `[ApiController]`, `[Route("api/[controller]")]`, `ApiResponse<T>`,
`[Authorize(Policy = "...")]`.

### 7.1 `TablerosController`

| Método | Ruta | Permiso | Descripción |
|---|---|---|---|
| GET | `/tableros/proyecto/{proyectoId}` | `kanban.ver` | Lista tableros del proyecto (resumen). |
| GET | `/tableros/{id}` | `kanban.ver` | Detalle del tablero con columnas, tarjetas, etiquetas y miembros. |
| POST | `/tableros` | `kanban.crear` | Crea tablero (genera/valida `Clave`; crea columnas por defecto opcionalmente). |
| PUT | `/tableros/{id}` | `kanban.editar` | Edita nombre, descripción, color, clave. |
| DELETE | `/tableros/{id}` | `kanban.eliminar` | Soft delete del tablero. |
| PUT | `/tableros/{id}/miembros` | `kanban.gestionar` | Actualiza owners/colaboradores del tablero. |
| GET/POST/PUT/DELETE | `/tableros/{id}/etiquetas...` | `kanban.editar` | CRUD de catálogo de etiquetas del tablero. |

### 7.2 `ColumnasController`

| Método | Ruta | Permiso | Descripción |
|---|---|---|---|
| POST | `/columnas` | `kanban.editar` | Crea columna en un tablero. |
| PUT | `/columnas/{id}` | `kanban.editar` | Renombra / cambia WIP. |
| PUT | `/columnas/{id}/reordenar` | `kanban.editar` | Reordena columna (orden fraccional). |
| DELETE | `/columnas/{id}` | `kanban.editar` | Soft delete (requiere columna vacía o reubicar tarjetas). |

### 7.3 `TarjetasController`

| Método | Ruta | Permiso | Descripción |
|---|---|---|---|
| GET | `/tarjetas/{id}` | `kanban.ver` | Detalle completo de la tarjeta (modal). |
| POST | `/tarjetas` | `kanban.crear` | Crea tarjeta → **genera código** (§4). |
| PUT | `/tarjetas/{id}` | `kanban.editar` | Edita título, descripción, prioridad, fechas. |
| PUT | `/tarjetas/{id}/mover` | `kanban.editar` | Mueve entre columnas / reordena. |
| PUT | `/tarjetas/{id}/responsables` | `kanban.editar` | Asigna/quita responsables. |
| PUT | `/tarjetas/{id}/etiquetas` | `kanban.editar` | Asigna/quita etiquetas. |
| POST/PUT/DELETE | `/tarjetas/{id}/checklist...` | `kanban.editar` | CRUD de checklist. |
| POST/DELETE | `/tarjetas/{id}/comentarios...` | `kanban.comentar` | Comentarios. |
| POST/DELETE | `/tarjetas/{id}/adjuntos...` | `kanban.editar` | Adjuntos (multipart, reusa storage). |
| GET | `/tarjetas/{id}/actividad` | `kanban.ver` | Historial de actividad. |
| DELETE | `/tarjetas/{id}` | `kanban.eliminar` | Soft delete / archivar. |

---

## 8. Permisos (`Domain/Security/PermissionCatalog.cs`)

Añadir un módulo **Kanban** al catálogo (IDs 28+, continuando la numeración):

```csharp
new(28, "kanban.ver",       "Ver kanban",          "Kanban", "Permite consultar tableros y tarjetas."),
new(29, "kanban.crear",     "Crear en kanban",     "Kanban", "Permite crear tableros y tarjetas."),
new(30, "kanban.editar",    "Editar kanban",       "Kanban", "Permite editar columnas, tarjetas, mover y asignar."),
new(31, "kanban.comentar",  "Comentar tarjetas",   "Kanban", "Permite comentar en tarjetas."),
new(32, "kanban.eliminar",  "Eliminar en kanban",  "Kanban", "Permite eliminar/archivar tableros y tarjetas."),
new(33, "kanban.gestionar", "Gestionar tableros",  "Kanban", "Permite administrar miembros y configuración del tablero."),
```

Cada clave se registra automáticamente como policy en `Program.cs` (mismo bucle que el resto).

### 8.1 Matriz de roles propuesta (`RolePermissions`)

| Permiso | Gerencia | Arquitecto | LT | Dev |
|---|:---:|:---:|:---:|:---:|
| `kanban.ver` | ✅ | ✅ | ✅ | ✅ |
| `kanban.crear` | — | ✅ | ✅ | ✅ |
| `kanban.editar` | — | ✅ | ✅ | ✅ |
| `kanban.comentar` | ✅ | ✅ | ✅ | ✅ |
| `kanban.eliminar` | — | ✅ | ✅ | — |
| `kanban.gestionar` | — | ✅ | ✅ | — |

> `Arquitecto` ya recibe todos los permisos automáticamente (`All.Select(...)`).
> Solo hay que añadir las claves a `Gerencia`, `LT` y `Dev` en el diccionario.

---

## 9. Frontend (Angular standalone)

### 9.1 Modelos (`core/models/kanban.models.ts`)

Interfaces `Tablero`, `TableroDetalle`, `Columna`, `Tarjeta`, `TarjetaDetalle`,
`Responsable`, `Etiqueta`, `ChecklistItem`, `Comentario`, `Adjunto`, `Actividad`,
y los request types (`CreateTablero`, `CreateTarjeta`, `MoverTarjeta`, …) espejando los DTOs.

### 9.2 Servicios (`core/services/`)

- `tableros.service.ts`, `tarjetas.service.ts` (patrón idéntico a `despliegues.service.ts`:
  `inject(HttpClient)`, `environment.apiBaseUrl`, helper `extractData<T>()`, `ApiResponse<T>`).

### 9.3 Rutas (`app.routes.ts`)

Anidadas bajo el proyecto y/o una sección propia:

```ts
// Tablero individual dentro del proyecto
{
  path: 'proyectos/:proyectoId/tableros/:tableroId',
  canActivate: [AuthGuard, PermissionGuard],
  data: { permiso: 'kanban.ver' },
  loadComponent: () => import('./features/kanban/board.page').then(m => m.BoardPage),
  title: 'Tablero | ConsultoraPro'
}
```

Además, dentro de `project-detail.page` (ya existe) añadir una **pestaña "Tableros"** que
liste los tableros del proyecto y permita crear uno nuevo, navegando al `BoardPage`.

### 9.4 Componentes (`features/kanban/`)

- `board.page.ts/html/scss` — vista del tablero: cabecera (nombre, clave, miembros, filtros),
  columnas en horizontal con scroll, botón "añadir columna".
- `column.component.ts` — columna con su lista de tarjetas y "añadir tarjeta".
- `card.component.ts` — tarjeta compacta: muestra **código** (`REP-TAR-001`), título, etiquetas,
  avatares de responsables, badges (checklist `2/5`, nº comentarios, fecha límite, prioridad).
- `card-detail.modal.ts` — modal/panel lateral: descripción (markdown), responsables, etiquetas,
  checklist, comentarios, adjuntos, actividad.
- `board-form.modal.ts`, `tablero-list.component.ts` (para la pestaña del proyecto).

### 9.5 Drag & drop

Usar **Angular CDK `DragDropModule`** (`cdkDropList` + `cdkDrag`, `cdkDropListGroup` para mover
entre columnas). En `drop()`:
1. Reordenar localmente (optimista) con `moveItemInArray` / `transferArrayItem`.
2. Calcular vecinos (tarjeta anterior/siguiente en la columna destino) y llamar
   `PUT /tarjetas/{id}/mover` con `MoverTarjetaDto`.
3. Si la API falla, revertir y mostrar toast.

> Confirmar si el proyecto ya usa `@angular/cdk`. Si no, `npm i @angular/cdk` (alineado con la
> versión de Angular del `package.json`). **Recordatorio de estilos:** cualquier `@import` de CSS
> de `@angular/cdk` debe ir al **inicio** de `styles.scss`, antes de reglas propias (ver memoria
> del proyecto sobre orden de imports que dejó modals en blanco).

### 9.6 Menú / navegación

Añadir entrada de menú "Kanban" o exponerlo solo desde el detalle del proyecto (decisión de UX,
ver [§12](#12-preguntas-abiertas)). El shell/layout ya filtra ítems por permiso (`kanban.ver`).

---

## 10. Plan de trabajo por fases

| Fase | Entregable | Incluye |
|---|---|---|
| **F1 — Backend base** | Tableros + columnas + tarjetas + **código** | Entidades, enums, `Proyecto.Clave`, migración, repos, servicios, controllers, permisos, generación de código con concurrencia, seed demo. |
| **F2 — Frontend board** | Tablero usable con drag & drop | Modelos, servicios, rutas, `BoardPage`, columnas, tarjetas, crear/editar/mover, pestaña en project-detail. |
| **F3 — Tarjeta rica** | Modal de detalle | Responsables, etiquetas, prioridad/fechas, checklist, comentarios. |
| **F4 — Extras** | Adjuntos + actividad + filtros | Adjuntos (storage existente), log de actividad, filtros por responsable/etiqueta/prioridad, búsqueda. |
| **F5 — Pulido (opcional)** | Tiempo real / mover entre tableros / WIP | SignalR, mover tarjetas entre tableros, límites WIP visuales. |

Recomendación: **F1 y F2 entregan valor de inmediato** (board funcional con códigos). El resto es incremental.

---

## 11. Pruebas

- **Unitarias (`backend/tests`)**: generación de código (formato `REP-TAR-001`, padding,
  incremento), unicidad, concurrencia (dos creaciones simultáneas → números distintos),
  cálculo de orden fraccional al mover, validación de pertenencia columna↔tablero↔proyecto.
- **Integración API**: flujos crear tablero → crear columna → crear tarjeta → mover → asignar.
- **Frontend**: pruebas de `card.component` (render del código y badges) y lógica de `drop()`.

---

## 12. Preguntas abiertas

1. **¿Clave del proyecto editable o automática?** Propuesta: autogenerada y editable con validación
   de unicidad. (Afecta D1.)
2. **¿Responsables limitados a miembros del proyecto** (`ProyectoMiembro`) **o cualquier usuario activo?**
   Propuesta: cualquier usuario activo en F1; restringir a miembros del proyecto es trivial de añadir.
3. **¿El Kanban se accede solo desde el detalle del proyecto** o también desde un ítem de menú global
   "Mis tarjetas"? Propuesta: pestaña en project-detail (F2) + vista "Asignadas a mí" en F4.
4. **¿Mover tarjetas entre tableros?** Propuesta: no en F1–F4 (el código quedaría ligado al tablero
   original, D4); evaluarlo en F5.
5. **¿Tiempo real?** Ver §13.

---

## 13. Consideraciones de tiempo real (opcional)

Para colaboración en vivo (tarjetas que se mueven solas cuando otro usuario edita), añadir
**SignalR** con un hub por tablero (`/hubs/kanban`) que emita eventos `TarjetaMovida`,
`TarjetaCreada`, etc. No es necesario para la primera versión: el board funciona con
refetch al entrar y actualización optimista local. Se deja anotado para F5.

---

## 14. Checklist de implementación (resumen accionable)

**Backend**
- [ ] Enums `RolTablero`, `PrioridadTarjeta`, `TipoActividadTarjeta`.
- [ ] Entidades del §3 + `Proyecto.Clave`.
- [ ] Interfaces de repositorio.
- [ ] Configuración EF + índices únicos (`Codigo`, `(TableroId,Numero)`, `(ProyectoId,Clave)`).
- [ ] `ApplyAutomaticTimestamps` para `Tablero`/`Tarjeta`.
- [ ] Migración `AddKanban` + backfill de `Proyecto.Clave`.
- [ ] DTOs, validadores, AutoMapper, servicios, repos, DI.
- [ ] Generación de código con transacción/lock (§4.2).
- [ ] Permisos (§8) + matriz de roles.
- [ ] Controllers `Tableros`, `Columnas`, `Tarjetas`.
- [ ] Seed demo.
- [ ] Pruebas (§11).

**Frontend**
- [ ] `@angular/cdk` (si falta) — import de estilos al inicio de `styles.scss`.
- [ ] Modelos + servicios `tableros`/`tarjetas`.
- [ ] Rutas + pestaña en `project-detail`.
- [ ] `BoardPage`, `column`, `card`, `card-detail.modal`, formularios.
- [ ] Drag & drop con actualización optimista.
- [ ] Filtros/búsqueda (F4).

**Documentación**
- [ ] Actualizar `backend/SISTEMA_BACKEND.md` y `frontend/SISTEMA_FRONTEND.md` con el módulo Kanban.
- [ ] Añadir este doc al índice de `docs/README.md`.
</content>
</invoke>
