# Documentación de Despliegue — ConsultoraPro

Manual completo para construir, versionar y desplegar ConsultoraPro
(backend .NET + frontend Angular + MySQL) usando **Docker** y
**GitHub Actions**, con dos entornos: **QA** (rama `qa`) y
**Producción** (rama `main`).

## Índice

| # | Documento | Qué cubre |
|---|-----------|-----------|
| 01 | [Arquitectura](01-arquitectura.md) | Visión general, repos, flujo de despliegue, diagrama |
| 02 | [Docker](02-docker.md) | Imágenes, Dockerfiles, compose, comandos, desarrollo local |
| 03 | [GitHub Actions](03-github-actions.md) | Workflows, GHCR, cómo se dispara cada deploy |
| 04 | [Ramas y entornos](04-ramas-y-entornos.md) | `qa` / `main`, protección de ramas, Environments |
| 05 | [Secretos y conexiones](05-secretos-y-conexiones.md) | SSH, secretos, GHCR, manera segura de gestionarlos |
| 06 | [Preparación del servidor](06-preparacion-servidor.md) | Provisionar el server, usuario, primer despliegue |
| 07 | [Nginx proxy inverso](07-nginx-proxy-inverso.md) | Nginx del host delante de los contenedores, dominios, HTTPS |
| 08 | [Módulo Kanban](08-modulo-kanban.md) | Plan del Kanban por proyecto: tableros, columnas, tarjetas con código `REP-TAR-001`, permisos, frontend |
| 09 | [Almacenamiento de archivos](09-almacenamiento-archivos.md) | Paso a paso: crear Azure Blob, configurar el `.env`, desplegar y verificar uploads/descargas con SAS |

## Resumen en 30 segundos

```
git push a qa    ─┐
                  ├─► Actions compila imagen ─► GHCR (:qa / :prod) ─► avisa al repo infra
git push a main  ─┘                                                          │
                                                                             ▼
                                          repo infra ─SSH─► servidor: docker compose pull && up -d
```

- **3 repositorios**: `consultora-pro-backend`, `consultora-pro-frontend`, `consultora-pro-infra`.
- Cada repo de app **compila y publica** su imagen en GHCR y avisa al repo `infra`.
- El repo `infra` **orquesta el despliegue** por SSH (es el único que tiene las llaves del servidor).
- Secretos de la app (DB, JWT) viven **en el servidor** (`.env`), nunca en GitHub.

## Qué tienes que hacer tú (una sola vez)

Resumido aquí; el detalle está en cada documento.

1. Crear el repo `consultora-pro-infra` en GitHub y subir esta carpeta + los compose. → [01](01-arquitectura.md)
2. Crear las ramas `qa` y protegerlas en los 3 repos. → [04](04-ramas-y-entornos.md) / `scripts/setup-github.sh`
3. Provisionar el servidor (Docker, usuario `deploy`, `.env`). → [06](06-preparacion-servidor.md) / `scripts/server-bootstrap.sh`
4. Cargar los secretos (SSH, GHCR) en los Environments. → [05](05-secretos-y-conexiones.md)
