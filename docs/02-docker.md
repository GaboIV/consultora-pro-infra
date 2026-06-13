# 02 — Docker

## Estado actual

El proyecto **ya estaba dockerizado**. Esto es lo que había y lo que se añadió:

| Archivo | Estado | Para qué |
|---------|--------|----------|
| `backend/Dockerfile` | ya existía | Imagen .NET multi-stage (SDK → runtime) |
| `frontend/Dockerfile` | ya existía | Imagen Angular → Nginx multi-stage |
| `frontend/nginx.conf` | ya existía | Config Nginx para SPA (fallback a `index.html`) |
| `docker-compose.yml` | **refactorizado** | Desarrollo local (compila el código), sin secretos hardcodeados |
| `docker-compose.deploy.yml` | **nuevo** | Despliegue en servidor (baja imágenes de GHCR) |
| `.env.example` | **nuevo** | Plantilla de variables de entorno |
| `backend/.dockerignore` | **nuevo** | Excluye `bin/`, `obj/`, secretos del contexto de build |
| `frontend/.dockerignore` | **nuevo** | Excluye `node_modules/`, `dist/`, etc. |

## Las dos imágenes

### Backend (`backend/Dockerfile`)

Multi-stage: compila con el SDK de .NET 8 y copia solo el resultado a una imagen
runtime ligera. Expone el **8080**. Recibe su configuración por variables de entorno
(`ConnectionStrings__DefaultConnection`, `Jwt__Key`, etc.).

### Frontend (`frontend/Dockerfile`)

Multi-stage: compila Angular con Node 20 (`npm ci` + `npm run build --configuration=production`)
y sirve el resultado (`dist/consultora-pro/browser`) con Nginx en el puerto **80**.

## Los dos archivos compose

Hay **dos** porque hacen cosas distintas:

### `docker-compose.yml` — desarrollo local

- Usa `build:` → **compila** el código de `./backend` y `./frontend`.
- Pensado para levantar todo en tu máquina.
- Lee valores de un `.env` local (con valores por defecto seguros para dev).

```bash
# En la raíz del proyecto (donde están backend/ y frontend/)
cp .env.example .env        # ajusta para local si quieres
docker compose up -d --build
docker compose logs -f
docker compose down
```

Accesos por defecto:
- Frontend: http://localhost:15001
- Backend (API): http://localhost:15000
- MySQL: localhost:3306

### `docker-compose.deploy.yml` — servidor (QA/Prod)

- Usa `image:` → **descarga** imágenes ya construidas desde GHCR.
- No necesita el código fuente en el servidor, solo Docker.
- Todas las variables salen del `.env` del servidor.
- Incluye `healthcheck` de MySQL y red interna `internal`.

```bash
# En el servidor (lo hace GitHub Actions por ti, pero a mano sería):
docker login ghcr.io -u <usuario> -p <token>
docker compose -f docker-compose.deploy.yml --env-file .env pull
docker compose -f docker-compose.deploy.yml --env-file .env up -d
```

## Variables de entorno

Todas están documentadas en `.env.example`. Las más importantes:

| Variable | Ejemplo | Notas |
|----------|---------|-------|
| `IMAGE_TAG` | `qa` / `prod` | Qué versión desplegar |
| `BIND_HOST` | `127.0.0.1` | Interfaz de publicación (localhost tras proxy inverso) |
| `FRONTEND_PORT` | `15001` | Puerto del frontend (único expuesto) |
| `BACKEND_PORT` | `15000` | Solo en **dev local**; en despliegue el backend no publica puerto |
| `MYSQL_ROOT_PASSWORD` | *(secreto)* | Password root de MySQL |
| `MYSQL_PASSWORD` | *(secreto)* | Password del usuario de app |
| `JWT_KEY` | *(secreto, ≥32 chars)* | Clave de firma de JWT |

> En producción, los valores secretos **no se escriben en GitHub**: viven en el `.env`
> del servidor. Ver [05](05-secretos-y-conexiones.md).

## Comandos útiles en el servidor

```bash
# Ver estado
docker compose -f docker-compose.deploy.yml --env-file .env ps

# Logs de un servicio
docker compose -f docker-compose.deploy.yml --env-file .env logs -f backend

# Reiniciar un servicio
docker compose -f docker-compose.deploy.yml --env-file .env restart backend

# Bajar y volver a subir
docker compose -f docker-compose.deploy.yml --env-file .env down
docker compose -f docker-compose.deploy.yml --env-file .env up -d

# Liberar espacio (imágenes viejas)
docker image prune -f
```

## Persistencia de datos

El volumen `mysql_data` guarda la base de datos. **No se borra** con `down`; para
borrarlo (¡cuidado!) usarías `docker compose ... down -v`. Para backups, ver el apartado
de backup en [06](06-preparacion-servidor.md).

## Nota sobre comunicación frontend ↔ backend

Solo se expone el **frontend** (`127.0.0.1:15001`, detrás del Nginx del host). El
**backend no publica puerto**: vive en la red interna de Docker y el Nginx del propio
contenedor frontend hace proxy de `/api/` → `backend:8080`. Así el Angular llama a la API
con rutas relativas (`apiBaseUrl: '/api'`, mismo origen) y el backend queda oculto.

El backend ya enruta todo bajo `/api/...`. Todo el detalle (config del Nginx del host,
del contenedor, dominios, certbot, Forwarded Headers del .NET) está en
[07 — Nginx proxy inverso](07-nginx-proxy-inverso.md).
