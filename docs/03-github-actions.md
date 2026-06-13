# 03 — GitHub Actions

## Los tres workflows

| Repo | Archivo | Disparador | Qué hace |
|------|---------|-----------|----------|
| backend | `.github/workflows/deploy.yml` | push a `qa`/`main` | compila imagen, push a GHCR, avisa a infra |
| frontend | `.github/workflows/deploy.yml` | push a `qa`/`main` | compila imagen, push a GHCR, avisa a infra |
| infra | `.github/workflows/deploy.yml` | `repository_dispatch` o manual | SSH al servidor: pull + up |

## GHCR (GitHub Container Registry)

Las imágenes se publican en `ghcr.io/gaboiv/...` (el owner va en **minúsculas**).
El push usa el `GITHUB_TOKEN` automático del workflow (no configuras nada para esto).

```
ghcr.io/gaboiv/consultora-pro-backend:qa     ← último build de rama qa
ghcr.io/gaboiv/consultora-pro-backend:prod   ← último build de rama main
ghcr.io/gaboiv/consultora-pro-backend:<sha>  ← cada commit (trazabilidad)
```

> Las imágenes nacen **privadas**. Por eso el servidor necesita un token para bajarlas
> (`GHCR_PAT`). Ver [05](05-secretos-y-conexiones.md). Si prefieres, puedes hacer los
> paquetes públicos desde GitHub → Packages → Package settings, y entonces el servidor
> no necesitaría token para `pull` (pero sí seguiría siendo recomendable).

## Workflow de los repos de app (backend / frontend)

Resumen de los pasos:

1. **Checkout** del código.
2. **Calcular variables**: nombre de imagen (owner en minúsculas) y etiqueta según la rama
   (`qa` → `qa`, `main` → `prod`).
3. **Login en GHCR** con `GITHUB_TOKEN`.
4. **Build & Push** con `docker/build-push-action` (con caché de capas vía `type=gha`,
   así los builds siguientes son rápidos).
5. **Disparar deploy**: envía un `repository_dispatch` (evento `deploy`) al repo
   `consultora-pro-infra` con el entorno en el payload. Usa el secreto
   `INFRA_DISPATCH_TOKEN`.

El job corre dentro del **Environment** `qa` o `production` según la rama, de modo que
toma los secretos correctos y respeta las reglas de aprobación.

## Workflow del repo infra (orquestación)

Se dispara de dos formas:

- **Automática**: cuando backend o frontend terminan su push de imagen y envían el
  `repository_dispatch` tipo `deploy`.
- **Manual**: pestaña **Actions → Deploy → Run workflow**, eligiendo `qa` o `production`.
  Útil para redeploys sin tocar el código.

Pasos:

1. **Checkout** (para tener `docker-compose.deploy.yml`).
2. **scp** del compose al servidor (`appleboy/scp-action`).
3. **ssh** al servidor (`appleboy/ssh-action`):
   - `docker login ghcr.io` con `GHCR_PAT`,
   - verifica que exista `.env`,
   - `docker compose pull` + `up -d --remove-orphans`,
   - `docker image prune -f`.

El `concurrency` impide dos despliegues simultáneos del mismo entorno.

## ¿Cómo sé qué etiqueta despliega cada entorno?

El workflow de infra **no** elige la etiqueta: lo hace el `.env` del servidor
(`IMAGE_TAG=qa` o `IMAGE_TAG=prod`). Así, el servidor de QA siempre toma `:qa` y el de
producción siempre `:prod`, sin importar quién dispare el deploy.

## Probar manualmente

```bash
# Disparar el deploy de infra a mano con gh CLI (equivale al botón Run workflow):
gh workflow run deploy.yml -R GaboIV/consultora-pro-infra -f environment=qa

# Ver ejecuciones
gh run list -R GaboIV/consultora-pro-infra
gh run watch -R GaboIV/consultora-pro-infra
```

## Acciones de terceros usadas (y por qué)

| Acción | Uso |
|--------|-----|
| `actions/checkout@v4` | traer el código |
| `docker/login-action@v3` | login GHCR |
| `docker/setup-buildx-action@v3` | builder con caché |
| `docker/build-push-action@v6` | compilar y publicar imagen |
| `peter-evans/repository-dispatch@v3` | avisar al repo infra |
| `appleboy/scp-action` / `appleboy/ssh-action` | copiar compose y ejecutar deploy por SSH |

> Buena práctica de seguridad: más adelante puedes **fijar las acciones por SHA** en
> lugar de por tag (`@v4`) para evitar que un tag mutable cambie bajo tus pies.

Siguiente: [Ramas y entornos](04-ramas-y-entornos.md).
