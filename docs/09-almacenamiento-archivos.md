# 09 — Almacenamiento de archivos (Azure Blob en QA/Prod)

Manual paso a paso para poner en marcha el almacenamiento de archivos:
crear el Azure Blob Storage, configurarlo en el servidor y desplegar para que la
aplicación suba/descargue desde ese contenedor.

> **Resumen de la arquitectura** (ya implementada en el código):
> - **Local (dev):** los archivos se guardan en disco (`Storage:Local:RootPath`, p.ej. `D:\ConsultoraPro\uploads`).
> - **QA / Prod:** los archivos viven en **Azure Blob Storage**, en un **contenedor privado**.
>   Las descargas se sirven con **URLs SAS firmadas** de corta expiración (15 min por defecto).
> - En la BD se guarda solo una **key relativa** (`screenshots/{guid}.png`), nunca la URL.
> - El proveedor se elige con la variable `Storage__Provider` (`Local` | `AzureBlob`).

---

## Cómo encaja con el pipeline (lo importante)

```
push a qa/main ──> Actions (backend/frontend): build + push imagen a GHCR ──> dispara "deploy"
                                                                                   │
repo infra: Actions Deploy ──ssh──> servidor ──> docker compose --env-file .env up
                                                          │
                              Lee el .env del SERVIDOR (incluye STORAGE_*)  ──>  contenedor backend
```

**Punto clave:** GitHub Actions **no** maneja el connection string de Azure. Las imágenes se
compilan **sin** secretos de almacenamiento. Quien inyecta `STORAGE_CONNECTION_STRING` y
`STORAGE_CONTAINER` al contenedor es **`docker compose --env-file .env` en el servidor**,
leyéndolos del archivo `.env` (un *secreto de la aplicación*, que vive solo en el servidor —
ver [05](05-secretos-y-conexiones.md)). Por eso, para "activar" Azure Blob solo tienes que:

1. Crear el Storage Account + contenedor (una vez por entorno).
2. Añadir `STORAGE_*` al `.env` del servidor.
3. Redesplegar.

No hace falta tocar código ni los workflows. (Al final hay una alternativa opcional si prefieres
guardar el secreto en GitHub Environments en vez del `.env` del servidor.)

---

## Paso 1 — Crear el Azure Blob Storage

Hazlo **una vez por entorno** (cuenta/contenedor separados para QA y Prod). Usa el Portal o la CLI.

### Opción A — Azure CLI (recomendado, reproducible)

```bash
# Variables (ajusta a tus valores)
RG=rg-consultorapro
LOC=eastus
ENV=qa                          # qa | prod
ACCOUNT=consultorapro${ENV}     # nombre global y único, solo minúsculas/números, 3-24 chars
CONTAINER=consultorapro-${ENV}

# 0) (si no existe) grupo de recursos
az group create -n "$RG" -l "$LOC"

# 1) Storage Account (Standard LRS es suficiente para archivos de la app)
az storage account create \
  -n "$ACCOUNT" -g "$RG" -l "$LOC" \
  --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false      # refuerza: nada de acceso anónimo

# 2) Contenedor PRIVADO (sin acceso público)
az storage container create \
  --account-name "$ACCOUNT" -n "$CONTAINER" \
  --public-access off \
  --auth-mode login

# 3) Connection string (incluye la AccountKey, necesaria para firmar SAS)
az storage account show-connection-string -n "$ACCOUNT" -g "$RG" -o tsv
```

Copia el valor del paso 3: es lo que irá en `STORAGE_CONNECTION_STRING`. Tiene esta forma:

```
DefaultEndpointsProtocol=https;AccountName=consultoraproqa;AccountKey=xxxx...==;EndpointSuffix=core.windows.net
```

### Opción B — Portal de Azure

1. **Crear un recurso → Storage account.**
   - Resource group: el tuyo. Name: `consultorapro<qa|prod>` (único global).
   - Region: la más cercana. Performance: *Standard*. Redundancy: *LRS*.
   - En **Advanced**: deja **Allow blob public access** en *Disabled*. **Create**.
2. En la cuenta creada → **Data storage → Containers → + Container.**
   - Name: `consultorapro-<qa|prod>`. **Public access level: Private**. **Create**.
3. **Security + networking → Access keys → Show → Connection string** (key1). Cópiala.

> Repite ambos pasos creando una cuenta/contenedor para **prod** cuando lo necesites.

---

## Paso 2 — Configurar el `.env` del servidor

En **cada servidor** (QA y Prod), edita el `.env` que usa `docker-compose.deploy.yml`
(normalmente en `DEPLOY_PATH`, p.ej. `/opt/consultorapro/.env`):

```bash
ssh deploy@TU_SERVIDOR
cd /opt/consultorapro
nano .env
```

Añade estas dos líneas (usa los valores del Paso 1). **En una sola línea, sin comillas:**

```env
# --- Almacenamiento de archivos (Azure Blob) ---
STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=consultoraproqa;AccountKey=xxxx...==;EndpointSuffix=core.windows.net
STORAGE_CONTAINER=consultorapro-qa
```

```bash
chmod 600 .env        # solo el usuario deploy lo lee
```

> - **No** pongas comillas alrededor del connection string: `docker compose` toma todo lo que
>   sigue al primer `=` como valor, así que los `;` y `=` internos no son problema.
> - El `.env` real **nunca** se sube a Git (está en `.gitignore`).
> - En el servidor de **prod**, el mismo par de variables pero con la cuenta/contenedor de prod.

Estas variables ya están **mapeadas** en [`docker-compose.deploy.yml`](../docker-compose.deploy.yml):

```yaml
backend:
  environment:
    - Storage__Provider=AzureBlob
    - Storage__AzureBlob__ConnectionString=${STORAGE_CONNECTION_STRING}
    - Storage__AzureBlob__ContainerName=${STORAGE_CONTAINER}
```

`.NET` traduce `Storage__AzureBlob__ConnectionString` → `Storage:AzureBlob:ConnectionString`.

---

## Paso 3 — Desplegar la imagen

Tienes el código (rename a `StorageKey`, migración EF, proveedores) ya commiteado. Para desplegar:

### A) Despliegue normal (por push)

```bash
# QA:   push a la rama qa   -> imagen :qa   -> deploy automático al entorno qa
git push origin qa

# Prod: push a la rama main -> imagen :prod -> deploy al entorno production
git push origin main
```

Esto dispara, en orden:
1. `backend/.github/workflows/deploy.yml`: compila la imagen y la sube a GHCR.
2. El repo **infra** recibe el `repository_dispatch` y ejecuta su `Deploy`:
   SSH al servidor → `docker compose --env-file .env pull && up -d`.
3. Al levantar, el contenedor recibe `STORAGE_*` desde el `.env` → la app arranca con Azure Blob.

> La **migración EF** (`RenameFileUrlToStorageKey`) se aplica sola al iniciar el backend
> (`MigrateAsync` en el arranque). No tienes que ejecutarla a mano.

### B) Redeploy manual (sin cambiar código)

Útil cuando solo editaste el `.env` (p.ej. acabas de añadir `STORAGE_*`):

```bash
# Opción 1: re-lanzar el workflow de infra desde tu máquina
gh workflow run deploy.yml -R GaboIV/consultora-pro-infra -f environment=qa

# Opción 2: directamente en el servidor
ssh deploy@TU_SERVIDOR
cd /opt/consultorapro
docker compose -f docker-compose.deploy.yml --env-file .env up -d --remove-orphans
```

---

## Paso 4 — Verificar que funciona

```bash
# En el servidor: comprobar que el backend tomó la config de Azure
docker compose -f docker-compose.deploy.yml --env-file .env logs backend | tail -n 50
# No debe aparecer ningún error tipo:
#   "Storage:AzureBlob:ConnectionString no está configurada"
#   "Storage:AzureBlob:ContainerName no está configurado"
```

Prueba funcional desde la app (UI):
1. Sube un **adjunto** o **screenshot** en una tarjeta/proyecto.
2. En el Portal de Azure → tu Storage Account → Containers → `consultorapro-qa`:
   deberías ver el blob bajo `adjuntos/` o `screenshots/`.
3. En la app, la imagen/enlace se ve correctamente: la URL devuelta es una **SAS**
   (`https://<cuenta>.blob.core.windows.net/<contenedor>/<key>?...&sig=...&se=...`).
4. Copia esa URL SAS y ábrela en el navegador: funciona. Cuando expira (≈15 min) → **403**.
5. La URL del blob **sin** la firma SAS (quitando el `?...`) → **404/AuthenticationFailed**
   (confirma que el contenedor es privado).

> ¿Quieres cambiar la expiración de las SAS? Ajusta `Storage:SignedUrlExpiryMinutes`
> (vía `appsettings` o `Storage__SignedUrlExpiryMinutes` en el `.env`).

---

## Rotación de llaves (mantenimiento)

Azure ofrece dos llaves (`key1`/`key2`) para rotar sin downtime:

```bash
# 1) Regenera la llave que NO estás usando, p.ej. key2
az storage account keys renew -n consultoraproqa -g rg-consultorapro --key key2
# 2) Pon en el .env la connection string con key2, redeploy (Paso 3B)
# 3) Cuando todo va con key2, regenera key1
az storage account keys renew -n consultoraproqa -g rg-consultorapro --key key1
```

---

## Problemas comunes

| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| Backend no arranca, log: *ConnectionString no está configurada* | `STORAGE_CONNECTION_STRING` falta o vacío en el `.env` | Añádelo (Paso 2) y redeploy |
| Subidas fallan con *AuthorizationFailure* / *AuthenticationFailed* | AccountKey incorrecta o caducada | Copia de nuevo la connection string (Paso 1.3) |
| *Container not found* al subir | `STORAGE_CONTAINER` no coincide con el contenedor real | Verifica el nombre exacto del contenedor |
| Imagen no se ve y la URL no tiene `?sig=` | El proveedor sigue en `Local` | Confirma `Storage__Provider=AzureBlob` (lo fija el compose de deploy) |
| El connection string se "corta" | Lo pusiste entre comillas en el `.env` | Quita las comillas; una sola línea |

---

## (Opcional) Alternativa: el secreto en GitHub Environments

Por diseño, los secretos de la app viven en el `.env` del servidor (más simple y aislado).
Si **prefieres** gestionar el connection string desde GitHub (Environments `qa`/`production`
del repo **infra**), puedes inyectarlo en el deploy en lugar de tenerlo en el `.env`:

1. Guarda los secretos en el repo infra:
   ```bash
   gh secret set STORAGE_CONNECTION_STRING --env qa -R GaboIV/consultora-pro-infra --body "DefaultEndpoints...=="
   gh secret set STORAGE_CONTAINER         --env qa -R GaboIV/consultora-pro-infra --body "consultorapro-qa"
   ```
2. En `.github/workflows/deploy.yml` (repo infra), antes del `docker compose up`, **append** al
   `.env` del servidor desde los secretos (dentro del `script:` del paso SSH):
   ```bash
   # Asegura que STORAGE_* estén en el .env en cada deploy
   grep -q '^STORAGE_CONNECTION_STRING=' .env || \
     echo "STORAGE_CONNECTION_STRING=${{ secrets.STORAGE_CONNECTION_STRING }}" >> .env
   grep -q '^STORAGE_CONTAINER=' .env || \
     echo "STORAGE_CONTAINER=${{ secrets.STORAGE_CONTAINER }}" >> .env
   ```
   (O escribiéndolo siempre con `sed`/regeneración del `.env` si quieres que GitHub sea la fuente de verdad.)

> Trade-off: ganas gestión centralizada y rotación desde GitHub, a cambio de que el secreto pase
> por los logs/entorno de Actions. La opción por defecto (`.env` en el servidor) lo mantiene
> fuera de GitHub por completo.

Siguiente: vuelve al [índice de docs](README.md).
