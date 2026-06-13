# 04 — Ramas y entornos

## Estrategia de ramas

| Rama | Propósito | Despliega a | Etiqueta |
|------|-----------|-------------|----------|
| `qa` | Calidad / pruebas | entorno **qa** | `:qa` |
| `main` | Producción | entorno **production** | `:prod` |

Las ramas `develop` y `feature/*` que ya existen siguen sirviendo para el desarrollo
diario. El flujo recomendado:

```
feature/*  ──PR──►  qa  ──(prueba en QA)──►  PR  ──►  main  ──►  producción
```

- Trabajas en `feature/...`.
- Merge a `qa` → se despliega a QA automáticamente.
- Validado en QA → PR de `qa` a `main` → se despliega a producción.

> Aplica esto en **los tres repos** (backend, frontend, infra). En `infra` la rama
> `main` es la que el workflow de deploy usa como fuente del `docker-compose.deploy.yml`.

## Crear la rama `qa`

Automático con el script incluido (requiere `gh` autenticado):

```bash
./scripts/setup-github.sh GaboIV/consultora-pro-backend
./scripts/setup-github.sh GaboIV/consultora-pro-frontend
./scripts/setup-github.sh GaboIV/consultora-pro-infra
```

O a mano en cada repo:

```bash
git checkout main
git pull
git checkout -b qa
git push -u origin qa
```

## Proteger las ramas (que estén "controladas")

El objetivo: que nadie pueda hacer `push` directo a `qa` ni a `main`; todo entra por
**Pull Request** con al menos **1 aprobación**, sin force-push ni borrado.

El `scripts/setup-github.sh` ya aplica esta protección:

- ✅ Requiere Pull Request con 1 review aprobado.
- ✅ Descarta aprobaciones obsoletas si llegan commits nuevos.
- ✅ Prohíbe `force push` y borrado de la rama.
- ✅ Historial lineal (obliga a squash/rebase, evita merges sucios).

> **Importante sobre el plan:** la protección de ramas está disponible gratis en repos
> **públicos**. En repos **privados** requiere **GitHub Pro / Team / Enterprise**. Si
> tus repos son privados con cuenta Free, el script avisará y la protección no se
> aplicará; en ese caso usa una "Ruleset" si tu plan lo permite, o mantén la disciplina
> de PRs manualmente.

### A mano (UI)

Repo → **Settings → Branches → Add branch ruleset / protection rule**:
- Branch name pattern: `qa` (y otra para `main`).
- ✔ Require a pull request before merging → Require approvals: 1.
- ✔ Do not allow bypassing the above settings.
- ✔ Restrict deletions / Block force pushes.

## Environments (`qa` y `production`)

Los **Environments** de GitHub sirven para dos cosas clave:

1. **Aislar secretos**: cada entorno tiene sus propios secretos (el `SSH_HOST` de QA es
   distinto del de producción). Un job que corre en el Environment `qa` **no puede ver**
   los secretos de `production`.
2. **Puerta de aprobación**: en `production` puedes exigir **Required reviewers**, de
   modo que un humano apruebe manualmente antes de desplegar a producción.

El `setup-github.sh` crea los Environments `qa` y `production`. Para activar la
aprobación manual en producción:

Repo `infra` → **Settings → Environments → production → Required reviewers** → añádete a
ti mismo (o al equipo). A partir de ahí, cada deploy a producción esperará tu visto bueno.

> Como mínimo, crea los Environments en el repo **infra** (es quien despliega) y en los
> repos de **app** (porque sus workflows seleccionan Environment por rama). Los secretos
> de cada uno se detallan en [05](05-secretos-y-conexiones.md).

Siguiente: [Secretos y conexiones](05-secretos-y-conexiones.md).
