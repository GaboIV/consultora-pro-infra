# 01 — Arquitectura

## Componentes del sistema

| Servicio | Tecnología | Imagen base | Puerto interno |
|----------|-----------|-------------|----------------|
| `database` | MySQL 8.0 | `mysql:8.0` | 3306 |
| `backend` | .NET 8 Web API | `mcr.microsoft.com/dotnet/aspnet:8.0` | 8080 |
| `frontend` | Angular + Nginx | `nginx:alpine` | 80 |

## Los tres repositorios

```
GaboIV/consultora-pro-backend     -> código .NET  + Dockerfile + workflow de build
GaboIV/consultora-pro-frontend    -> código Angular + Dockerfile + workflow de build
GaboIV/consultora-pro-infra       -> docker-compose.deploy.yml + docs + workflow de deploy
```

> En tu disco están como carpetas hermanas dentro de `d:\Proyectos\ConsultoraPro\`.
> El repo **infra** es la propia raíz (`d:\Proyectos\ConsultoraPro`), que **ignora**
> las carpetas `backend/` y `frontend/` porque son repos independientes.

### ¿Por qué un repo `infra` separado?

- **Una sola fuente de las llaves del servidor.** Solo el repo `infra` guarda los
  secretos SSH. Los repos de app no pueden tocar el servidor directamente: su blast
  radius se reduce. (Ver [05](05-secretos-y-conexiones.md).)
- El `docker-compose.deploy.yml` es **compartido** por backend y frontend; tiene un
  hogar natural.
- La documentación vive con la orquestación.

## Flujo de despliegue (extremo a extremo)

```
   Desarrollador
        │  git push
        ▼
 ┌──────────────────────┐        ┌──────────────────────┐
 │ consultora-pro-back  │        │ consultora-pro-front │
 │  rama qa  / main     │        │  rama qa  / main     │
 └──────────┬───────────┘        └──────────┬───────────┘
            │ Actions: build + push                    │
            ▼                                           ▼
        ┌───────────────────────────────────────────────────┐
        │   GHCR (GitHub Container Registry, privado)        │
        │   ghcr.io/gaboiv/consultora-pro-backend:qa|prod    │
        │   ghcr.io/gaboiv/consultora-pro-frontend:qa|prod   │
        └───────────────────────────────────────────────────┘
            │ repository_dispatch (event "deploy")
            ▼
 ┌──────────────────────────────────┐
 │ consultora-pro-infra             │
 │  Actions: deploy.yml             │
 │  Environment qa | production     │  ← aquí viven los secretos SSH
 └──────────────┬───────────────────┘
                │ SSH (scp compose + docker compose pull/up)
                ▼
 ┌──────────────────────────────────┐
 │ SERVIDOR (QA o Producción)       │
 │  /opt/consultorapro/.env         │  ← secretos de app (DB, JWT)
 │  docker compose: db + back + front│
 └──────────────────────────────────┘
```

### Paso a paso

1. Haces `git push` a `qa` o `main` en backend o frontend.
2. El workflow del repo de app **compila** la imagen Docker y la **publica** en GHCR:
   - rama `qa`   → etiqueta `:qa`
   - rama `main` → etiqueta `:prod`
   - (además siempre `:<sha>` para trazabilidad)
3. Ese mismo workflow envía un **`repository_dispatch`** al repo `infra` indicando el
   entorno (`qa` o `production`).
4. El workflow de `infra` se conecta por **SSH** al servidor correspondiente, copia el
   `docker-compose.deploy.yml` y ejecuta `docker compose pull && up -d`.
5. El servidor baja la nueva imagen desde GHCR y reinicia el servicio. El archivo
   `.env` del servidor decide qué etiqueta (`qa`/`prod`), puertos y secretos usar.

## Mapeo rama → entorno → etiqueta

| Rama | Entorno (GitHub Environment) | Etiqueta de imagen | Servidor |
|------|------------------------------|--------------------|----------|
| `qa` | `qa` | `:qa` | servidor/carpeta de QA |
| `main` | `production` | `:prod` | servidor/carpeta de Producción |

QA y Producción pueden ser **dos servidores distintos** o el **mismo servidor con dos
carpetas** (`/opt/consultorapro-qa` y `/opt/consultorapro-prod`, cada una con su `.env`
y sus puertos). Lo defines con los secretos `SSH_HOST` y `DEPLOY_PATH` de cada Environment.

## Siguientes pasos

- Detalle de Docker → [02](02-docker.md)
- Detalle de Actions → [03](03-github-actions.md)
