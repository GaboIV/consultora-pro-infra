# Buscador global — especificación completa

> Aplica a: `consultora-pro-frontend` (Angular 17+) y `consultora-pro-api` (.NET 8)
> Componente: `GlobalSearchComponent` + `SearchService` + endpoint `/api/search`

---

## Visión general

El buscador global es el único punto de entrada para encontrar cualquier entidad del sistema sin necesidad de navegar módulo por módulo. Debe sentirse instantáneo, inteligente y consciente del contexto del usuario (rol y permisos).

**Principio de diseño:** el usuario nunca debería tener que recordar en qué módulo está algo. Si busca "repsol" debe ver sus proyectos, ambientes, credenciales y usuarios asociados — todo en una sola consulta.

---

## Comportamiento por estado

### Estado 1 — Inactivo (sin foco)
- El input muestra el placeholder: `Buscar proyectos, clientes, ambientes…`
- A la derecha del input se muestra el atajo de teclado `⌘K` (Mac) / `Ctrl+K` (Windows/Linux)
- No se muestra ningún dropdown

### Estado 2 — Con foco, sin texto
- El borde del input cambia a color accent (`#4f8ef7`)
- Se despliega el dropdown con dos secciones:
  1. **Recientes** — últimas 5 búsquedas o resultados visitados (guardados en `localStorage`)
  2. **Filtros rápidos** — chips que el usuario puede clickear para prefijar la búsqueda

### Estado 3 — Escribiendo (debounce activo)
- Se muestra un spinner de carga dentro del dropdown
- Debounce de **200ms** antes de ejecutar la búsqueda
- El botón `×` de limpieza aparece a la derecha del input
- La tecla `Escape` limpia el campo y cierra el dropdown

### Estado 4 — Resultados disponibles
- Dropdown con resultados agrupados por tipo de entidad
- Cada ítem muestra: ícono del tipo, nombre (con término resaltado), subtítulo contextual, badge de estado
- Navegación con `↑` `↓` resalta el ítem seleccionado
- `Enter` navega al resultado resaltado
- Click en un ítem navega y cierra el dropdown
- Footer del dropdown muestra: atajos de teclado + conteo de resultados

### Estado 5 — Sin resultados
- Ícono + mensaje "Sin resultados para `{término}`"
- Sugerencia de usar filtros de tipo (`p:`, `c:`, etc.)
- NO mostrar búsquedas relacionadas inventadas

### Estado 6 — Error de red
- Mensaje "Error al buscar. Verifica tu conexión."
- Botón "Reintentar"
- No lanzar errores no controlados al usuario

---

## Filtros de tipo por prefijo (sintaxis rápida)

El usuario puede prefijar la búsqueda para limitar los resultados a un solo tipo de entidad:

| Prefijo | Tipo filtrado | Ejemplo |
|---------|--------------|---------|
| `p:` | Proyectos | `p: repsol` |
| `c:` | Clientes | `c: tel` |
| `u:` | Usuarios | `u: gabriel` |
| `k:` | Credenciales | `k: ssh` |
| `a:` | Ambientes | `a: produccion` |
| `r:` | Repositorios | `r: erp` |
| `d:` | Despliegues | `d: v2.4` |

Reglas:
- El prefijo es case-insensitive (`P:` = `p:`)
- Si el prefijo existe pero no hay término (`p:` con espacio vacío), listar todos los items de ese tipo (máximo 10)
- Si el prefijo no es reconocido, buscar en todos los tipos como texto normal

---

## Entidades buscables y campos indexados

### Proyectos
Campos buscados: `nombre`, `clienteNombre`, `techLead`, `etapa`, `estado`, `repositorios[]`
Subtítulo mostrado: `{clienteNombre} · {etapa} · {progreso}%`
Badge: estado del proyecto con color correspondiente
Ícono: `folder-kanban`
Restricción: solo proyectos a los que el usuario tiene acceso según su rol

### Clientes
Campos buscados: `nombre`, `industria`
Subtítulo mostrado: `{totalProyectos} proyectos · {industria}`
Badge: Activo / Inactivo
Ícono: `building-skyscraper`
Restricción: requiere permiso `clientes.ver`

### Usuarios
Campos buscados: `nombres`, `apellidos`, `correo`, `puesto`, `iniciales`
Subtítulo mostrado: `{correo} · {puesto}`
Badge: rol del usuario
Ícono: `user`
Restricción: requiere permiso `roles.ver`; usuarios sin ese permiso NO ven esta sección

### Credenciales
Campos buscados: `nombre`, `tipo`, `servidor`, `ambiente`
Subtítulo mostrado: `{proyectoNombre} · {tipo} · Vence en {días}d`
Badge: estado de vencimiento (OK / Por vencer / Urgente / Vencida)
Ícono: `lock`
Restricción: requiere permiso `credenciales.ver`
IMPORTANTE: el valor cifrado NUNCA se incluye en resultados de búsqueda

### Ambientes
Campos buscados: `nombre`, `tipo`, `url`, `tecnologia`, `proyectoNombre`
Subtítulo mostrado: `{proyectoNombre} · {tecnologia} · {estado}`
Badge: estado del ambiente (Online / Alerta / Offline)
Ícono: `server`
Restricción: requiere permiso `ambientes.ver`

### Repositorios
Campos buscados: `nombre`, `proveedor`, `ramaPrincipal`, `proyectoNombre`
Subtítulo mostrado: `{proyectoNombre} · {proveedor} · {ramaPrincipal}`
Badge: estado del pipeline (Passing / Failed)
Ícono: `git-branch`
Restricción: requiere permiso `proyectos.ver`

### Despliegues
Campos buscados: `version`, `proyectoNombre`, `ambienteNombre`, `ejecutadoPor`
Subtítulo mostrado: `{proyectoNombre} → {ambienteNombre} · {fechaHora}`
Badge: estado (Exitoso / Fallido / En curso)
Ícono: `rocket`
Restricción: requiere permiso `despliegues.ver`

---

## Orden de resultados en el dropdown

1. Coincidencia exacta en nombre primero
2. Coincidencia de inicio de palabra (ej: "rep" encuentra "Repsol" antes que "Comprep")
3. Coincidencia parcial en cualquier posición
4. Dentro del mismo score, ordenar por fecha de actualización (más reciente primero)

Máximo de resultados por tipo: **3 ítems** (para no saturar el dropdown)
Máximo total de resultados: **12 ítems**

---

## Resaltado del término buscado

El término encontrado debe resaltarse visualmente dentro del nombre del resultado:
- Color del resaltado: `#4f8ef7` (accent azul), font-weight: 500
- Solo resaltar en el campo `nombre` (no en el subtítulo)
- No resaltar si el match viene de un campo de tags interno no visible

```typescript
function highlight(text: string, query: string): string {
  if (!query.trim()) return text;
  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`(${escaped})`, 'gi');
  return text.replace(regex, '<mark>$1</mark>');
}
```

El `<mark>` debe tener estilos: `background: transparent; color: #4f8ef7; font-weight: 500`

---

## Atajo de teclado global `⌘K` / `Ctrl+K`

Implementar con `@HostListener('document:keydown')` en el componente raíz o en un servicio global:

```typescript
@HostListener('document:keydown', ['$event'])
handleShortcut(e: KeyboardEvent) {
  const isMac = navigator.platform.toUpperCase().includes('MAC');
  const trigger = isMac ? e.metaKey : e.ctrlKey;
  if (trigger && e.key === 'k') {
    e.preventDefault();
    this.searchService.open();
  }
}
```

El servicio `SearchService` expone un `BehaviorSubject<boolean>` para que el `GlobalSearchComponent` sepa cuándo enfocar el input.

---

## Historial de búsquedas recientes

Guardar en `localStorage` con clave `cp_search_history`:

```typescript
interface SearchHistory {
  term: string;
  resultType: string;
  resultId: string;
  resultName: string;
  visitedAt: string; // ISO
}
```

Reglas:
- Máximo 5 entradas
- Al visitar un resultado, guardarlo (FIFO — eliminar el más antiguo si hay 5)
- No guardar términos sin resultados
- No guardar búsquedas de credenciales en el historial (seguridad)
- Al hacer logout, limpiar el historial (`localStorage.removeItem('cp_search_history')`)

---

## Endpoint del backend `/api/search`

### Request
```
GET /api/search?q={término}&types={tipos}&limit={max}
```

Parámetros:
- `q` — término de búsqueda (requerido, mín 2 caracteres)
- `types` — lista separada por coma de tipos a incluir: `proyecto,cliente,usuario,credencial,ambiente,repositorio,despliegue` (opcional, default: todos los permitidos según permisos del JWT)
- `limit` — máximo de resultados totales (default: 12, max: 30)

### Lógica en el backend

```csharp
public async Task<SearchResultDto> SearchAsync(
    string query, string[] types, int limit, ClaimsPrincipal user)
{
    var permisos = user.GetPermisos(); // extensión que lee el claim "permisos"
    var results = new List<SearchItemDto>();

    var tasks = new List<Task>();

    if (types.Contains("proyecto") || types.Length == 0)
        tasks.Add(SearchProyectosAsync(query, permisos, results));

    if (types.Contains("cliente") && permisos.Contains("clientes.ver"))
        tasks.Add(SearchClientesAsync(query, results));

    if (types.Contains("usuario") && permisos.Contains("roles.ver"))
        tasks.Add(SearchUsuariosAsync(query, results));

    if (types.Contains("credencial") && permisos.Contains("credenciales.ver"))
        tasks.Add(SearchCredencialesAsync(query, results)); // NUNCA incluir valor

    if (types.Contains("ambiente") && permisos.Contains("ambientes.ver"))
        tasks.Add(SearchAmbientesAsync(query, results));

    await Task.WhenAll(tasks); // ejecutar en paralelo para rapidez

    return new SearchResultDto
    {
        Items = results
            .OrderByDescending(r => r.Score)
            .ThenByDescending(r => r.UpdatedAt)
            .Take(limit)
            .ToList(),
        Total = results.Count
    };
}
```

Usar `Task.WhenAll` para ejecutar todas las búsquedas en paralelo. El tiempo de respuesta objetivo es < 150ms.

### Respuesta

```json
{
  "success": true,
  "data": {
    "items": [
      {
        "id": "uuid",
        "type": "proyecto",
        "name": "ERP Upstream",
        "subtitle": "Repsol · Desarrollo · 62%",
        "badge": "En curso",
        "badgeVariant": "amber",
        "icon": "folder-kanban",
        "score": 0.95,
        "updatedAt": "2026-05-12T10:30:00Z",
        "navigateTo": "/proyectos/uuid"
      }
    ],
    "total": 4,
    "query": "repsol"
  }
}
```

El campo `navigateTo` es la ruta Angular a la que navegar al seleccionar el resultado.

### Algoritmo de scoring en el backend

```csharp
double CalculateScore(string field, string query)
{
    var f = field.ToLowerInvariant();
    var q = query.ToLowerInvariant();

    if (f == q)                   return 1.0;   // coincidencia exacta
    if (f.StartsWith(q))          return 0.9;   // inicio de campo
    if (f.Contains($" {q}"))      return 0.8;   // inicio de palabra interna
    if (f.Contains(q))            return 0.6;   // coincidencia parcial
    return 0.0;
}
```

Combinar scores de múltiples campos: `Math.Max(scoreNombre, scoreSub * 0.7)`

---

## Búsqueda en frontend (fallback sin red)

Si el backend tarda más de 500ms o hay error de red, el frontend puede hacer una búsqueda local sobre el snapshot cacheado en memoria (`SnapshotService`):

```typescript
searchLocal(query: string): SearchItem[] {
  const snapshot = this.snapshotService.getSnapshot();
  const q = query.toLowerCase();
  return [
    ...snapshot.proyectos
      .filter(p => p.nombre.toLowerCase().includes(q) || p.clienteNombre.toLowerCase().includes(q))
      .map(p => this.toSearchItem('proyecto', p)),
    ...snapshot.clientes
      .filter(c => c.nombre.toLowerCase().includes(q))
      .map(c => this.toSearchItem('cliente', c)),
  ].slice(0, 8);
}
```

Mostrar un indicador "Resultados locales (sin conexión)" si se usa este modo.

---

## Condiciones de filtrado por permiso (resumen)

| Tipo de resultado | Permiso requerido | Visible para |
|---|---|---|
| Proyectos | `proyectos.ver` | Todos los roles |
| Clientes | `clientes.ver` | Gerencia, Arquitecto, LT, Dev |
| Usuarios | `roles.ver` | Gerencia, Arquitecto |
| Credenciales | `credenciales.ver` | Arquitecto, LT |
| Ambientes | `ambientes.ver` | Todos los roles |
| Repositorios | `proyectos.ver` | Todos los roles |
| Despliegues | `despliegues.ver` | Todos los roles |

Si el usuario no tiene un permiso, esa sección no aparece ni en el frontend ni en la respuesta del backend. No se muestra "no tienes acceso" — simplemente no existe para ese usuario.

Adicionalmente para proyectos: un usuario con rol `Dev` o `LT` solo ve los proyectos en los que es miembro. Un `Arquitecto` o `Gerencia` ve todos.

---

## Accesibilidad

- El input tiene `aria-label="Búsqueda global"` y `aria-expanded="{true/false}"`
- El dropdown tiene `role="listbox"` y `aria-label="Resultados de búsqueda"`
- Cada ítem tiene `role="option"` y `aria-selected="{true/false}"`
- El resaltado de término usa `<mark>` semántico, no solo `<span>`
- El spinner tiene `aria-live="polite"` con texto "Buscando…"
- El resultado de "sin resultados" tiene `aria-live="assertive"`
- Navegación completa por teclado: Tab para foco, ↑↓ para navegar, Enter para seleccionar, Esc para cerrar

---

## Implementación Angular — estructura de archivos

```
src/app/shared/components/global-search/
├── global-search.component.ts       ← componente principal
├── global-search.component.html     ← template con dropdown
├── global-search.component.scss     ← estilos del dropdown
├── search-result-item.component.ts  ← ítem individual reutilizable
└── global-search.service.ts         ← lógica, debounce, historial, shortcut

src/app/core/services/
└── search-api.service.ts            ← llamadas HTTP al /api/search
```

### `global-search.service.ts` — estructura clave

```typescript
@Injectable({ providedIn: 'root' })
export class GlobalSearchService {
  private isOpen$ = new BehaviorSubject<boolean>(false);
  private query$ = new Subject<string>();

  results$: Observable<SearchResultDto> = this.query$.pipe(
    debounceTime(200),
    filter(q => q.trim().length >= 2 || q.includes(':')),
    distinctUntilChanged(),
    switchMap(q => this.api.search(q).pipe(
      catchError(() => this.searchLocal(q))
    ))
  );

  open() { this.isOpen$.next(true); }
  close() { this.isOpen$.next(false); }
  search(q: string) { this.query$.next(q); }
  saveToHistory(item: SearchItem) { /* localStorage */ }
  getHistory(): SearchHistoryItem[] { /* localStorage */ }
  clearHistory() { localStorage.removeItem('cp_search_history'); }
}
```

Usar `switchMap` (no `mergeMap`) para cancelar peticiones anteriores automáticamente cuando el usuario sigue escribiendo.

---

## Performance — objetivos medibles

| Métrica | Objetivo |
|---|---|
| Tiempo hasta primer resultado visible | < 300ms desde que el usuario deja de escribir |
| Tiempo de respuesta del backend | < 150ms p95 |
| Debounce | 200ms |
| Máximo resultados totales | 12 (3 por tipo) |
| Tamaño máximo de payload de respuesta | < 10KB |
| Re-render al navegar con ↑↓ | < 16ms (60fps) |

---

## Casos de uso y comportamiento esperado

### Caso 1 — Búsqueda de término corto ambiguo
Input: `"db"`
Esperado: muestra credenciales de base de datos (`db-prod-repsol`, `db-dev-bbva`) + ambientes con "db" en el nombre
NO mostrar: usuarios, clientes (no hay match relevante)

### Caso 2 — Búsqueda de cliente con proyectos
Input: `"repsol"`
Esperado:
- Clientes: Repsol (1 resultado)
- Proyectos: ERP Upstream, CRM Corporativo (proyectos de Repsol)
- Credenciales: db-prod-repsol, ssh-staging-repsol
- Ambientes: Producción ERP Upstream

### Caso 3 — Usuario sin permiso de credenciales busca "ssh"
Esperado: No aparece ninguna sección de Credenciales en resultados. El backend filtra por permisos, el frontend no hace petición de credenciales.

### Caso 4 — Búsqueda con filtro de tipo
Input: `"k: ssh"`
Esperado: Solo resultados de tipo Credencial que contengan "ssh". Todas las otras secciones están ocultas aunque haya matches.

### Caso 5 — Búsqueda vacía con foco
Input: vacío, solo foco
Esperado: Dropdown con historial de los últimos 5 resultados visitados + chips de filtros rápidos. No se hace ninguna petición al backend.

### Caso 6 — Búsqueda de una versión de despliegue
Input: `"v2.4"`
Esperado: Despliegues con versión "v2.4.1", "v2.4.0", etc. El badge muestra el estado (Exitoso/Fallido) y el subtítulo el proyecto y ambiente.

### Caso 7 — Búsqueda de usuario por iniciales
Input: `"gc"`
Esperado: Gabriel Caraballo aparece (sus iniciales son "GC", que están en el índice de búsqueda)

### Caso 8 — Credencial con vencimiento urgente en resultados
Cualquier credencial que venza en menos de 7 días debe mostrar su badge en rojo con el texto "Vence en Xd" aunque el usuario no esté en el módulo de Credenciales.

---

## Lo que NO debe hacer el buscador

- ❌ Mostrar valores de credenciales ni siquiera parcialmente
- ❌ Mostrar resultados de entidades a las que el usuario no tiene permiso
- ❌ Guardar búsquedas de credenciales en el historial local
- ❌ Hacer peticiones con términos de menos de 2 caracteres (excepción: prefijos como `p:`)
- ❌ Navegar automáticamente si hay más de 1 resultado al presionar Enter (solo el resaltado)
- ❌ Mostrar más de 3 resultados por tipo sin que el usuario lo solicite explícitamente
- ❌ Dejar el dropdown abierto si el usuario clickea fuera de él
- ❌ Hacer una petición por cada tecla (siempre debounce de 200ms)
- ❌ Mantener el historial después de logout
