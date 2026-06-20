# 05 — Secretos y conexiones (seguridad)

Este es el documento que te interesa para "agregar el usuario, la SSH key del servidor
y mantener las conexiones y secretos de forma sencilla y segura".

## Principio de diseño

```
┌────────────────────────────────────────────────────────────────────┐
│ Secretos del SERVIDOR (SSH, GHCR)  →  SOLO en el repo infra          │
│ Secretos de la APP (DB, JWT)       →  SOLO en el servidor (.env)     │
│ Token para disparar deploy         →  en los repos de app            │
└────────────────────────────────────────────────────────────────────┘
```

- Las **llaves del servidor** viven en **un único repo** (infra). Si mañana
  comprometen el repo de frontend, el atacante **no** obtiene acceso SSH al servidor.
- Los **secretos de la aplicación** (password de MySQL, clave JWT) **nunca tocan
  GitHub**: viven en el `.env` del servidor. GitHub no los necesita para desplegar.
- Todo secreto se guarda en **Environments** (no en "Repository secrets" globales), para
  que QA y Producción estén aislados y producción pueda exigir aprobación.

## Resumen de qué secreto va dónde

### Repo `consultora-pro-infra` → Environment `qa` y `production`

| Secreto | Qué es | Ejemplo |
|---------|--------|---------|
| `SSH_HOST` | IP o dominio del servidor | `203.0.113.10` |
| `SSH_USER` | usuario de despliegue | `deploy` |
| `SSH_PRIVATE_KEY` | clave **privada** SSH (contenido completo) | `-----BEGIN OPENSSH...` |
| `SSH_PORT` | puerto SSH (opcional, default 22) | `22` |
| `DEPLOY_PATH` | carpeta del compose en el server | `/opt/consultorapro` |
| `GHCR_USER` | tu usuario de GitHub | `GaboIV` |
| `GHCR_PAT` | token para que el server baje imágenes (read:packages) | `ghp_...` |

> En `production` los mismos nombres pero apuntando al servidor/carpeta de producción.
> Así el **mismo workflow** sirve para ambos entornos sin cambiar código.

### Repos `consultora-pro-backend` y `consultora-pro-frontend`

| Secreto | Qué es |
|---------|--------|
| `INFRA_DISPATCH_TOKEN` | PAT *fine-grained* con permiso **Contents: write** SOLO sobre el repo `consultora-pro-infra`. Sirve para que el push de imagen dispare el deploy. |

> El push a GHCR usa el `GITHUB_TOKEN` automático: **no** hay que crear un secreto para eso.

## Paso a paso: el usuario y la SSH key del servidor

### 1. Crear el usuario `deploy` en el servidor

Lo hace `scripts/server-bootstrap.sh` automáticamente. A mano sería:

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy          # para usar docker sin sudo
sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
```

> Usamos un usuario **dedicado** sin password (solo entra por llave). No usamos `root`.

### 2. Generar el par de llaves SSH (en TU máquina, no en el servidor)

```bash
ssh-keygen -t ed25519 -C "deploy-consultorapro" -f ./deploy_key
# Genera dos archivos:
#   deploy_key       -> clave PRIVADA  (va a GitHub como SSH_PRIVATE_KEY)
#   deploy_key.pub   -> clave PUBLICA  (va al servidor)
```

> Crea **una llave por entorno** si QA y Producción son servidores distintos
> (`deploy_key_qa`, `deploy_key_prod`). Así puedes rotar una sin afectar a la otra.

### 3. Instalar la clave PÚBLICA en el servidor

```bash
# Copia el contenido de deploy_key.pub al authorized_keys del usuario deploy:
cat deploy_key.pub | ssh root@TU_SERVIDOR "cat >> /home/deploy/.ssh/authorized_keys"
# o pega el contenido manualmente en /home/deploy/.ssh/authorized_keys
```

Permisos correctos (importante o SSH lo rechaza):
```bash
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

### 4. Cargar la clave PRIVADA en GitHub

Repo `infra` → **Settings → Environments → qa → Add secret**:
- `SSH_PRIVATE_KEY` = **todo** el contenido de `deploy_key` (incluidas las líneas
  `BEGIN`/`END`).

Con `gh` CLI:
```bash
gh secret set SSH_PRIVATE_KEY --env qa  -R GaboIV/consultora-pro-infra < deploy_key
gh secret set SSH_HOST        --env qa  -R GaboIV/consultora-pro-infra --body "203.0.113.10"
gh secret set SSH_USER        --env qa  -R GaboIV/consultora-pro-infra --body "deploy"
gh secret set DEPLOY_PATH     --env qa  -R GaboIV/consultora-pro-infra --body "/opt/consultorapro"
# ...repite con --env production y los valores de producción
```

### 5. Borra las llaves de tu disco

```bash
shred -u deploy_key            # Linux/Mac
# (en Windows borra el archivo de forma segura)
```
La privada ya está en GitHub y la pública en el servidor. No necesitas conservarlas.

## El token de GHCR (`GHCR_PAT`) para que el servidor baje imágenes

Las imágenes son privadas, así que el servidor necesita autenticarse para `docker pull`.

1. GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)**.
2. Crea un token con **solo** el scope `read:packages`.
3. Guárdalo como secreto `GHCR_PAT` y tu usuario como `GHCR_USER` en los Environments
   `qa` y `production` del repo `infra`.

```bash
gh secret set GHCR_PAT  --env qa -R GaboIV/consultora-pro-infra --body "ghp_xxx"
gh secret set GHCR_USER --env qa -R GaboIV/consultora-pro-infra --body "GaboIV"
```

> Alternativa más simple: hacer los paquetes **públicos** (GitHub → tu perfil → Packages →
> cada paquete → Package settings → Change visibility → Public). Entonces el servidor no
> necesita `GHCR_PAT` para `pull`. Menos secretos, a cambio de que las imágenes sean
> visibles. Tú eliges.

## El token de dispatch (`INFRA_DISPATCH_TOKEN`)

Permite que backend/frontend disparen el deploy en infra.

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens**.
2. **Resource owner**: tu cuenta. **Repository access**: solo `consultora-pro-infra`.
3. **Permissions** → Repository → **Contents: Read and write** (necesario para `repository_dispatch`).
4. Guárdalo como secreto en **ambos** repos de app:

```bash
gh secret set INFRA_DISPATCH_TOKEN -R GaboIV/consultora-pro-backend  --body "github_pat_xxx"
gh secret set INFRA_DISPATCH_TOKEN -R GaboIV/consultora-pro-frontend --body "github_pat_xxx"
```

## Los secretos de la aplicación (DB, JWT) — en el servidor

Estos **no van a GitHub**. Van en `/opt/consultorapro/.env` en el servidor:

```bash
cd /opt/consultorapro
cp .env.example .env     # si copiaste la plantilla; si no, créalo
nano .env                # rellena MYSQL_*, JWT_KEY, IMAGE_TAG=qa|prod, puertos
chmod 600 .env           # solo el usuario deploy lo lee
```

> El `.env` real está en `.gitignore`: nunca se sube. Si rotas la clave JWT o el password
> de MySQL, lo editas en el servidor y reinicias (`docker compose ... up -d`).

## Almacenamiento de archivos (Azure Blob en QA/Prod)

Los archivos subidos (screenshots, adjuntos e imágenes de tarjetas) se guardan según el entorno:

```
┌────────────────────────────────────────────────────────────────────┐
│ Local (dev)   →  filesystem en disco (Storage:Local:RootPath)       │
│ QA / Prod     →  Azure Blob Storage, contenedor PRIVADO + SAS        │
└────────────────────────────────────────────────────────────────────┘
```

- El **proveedor** lo decide `Storage__Provider` (`Local` | `AzureBlob`).
- Las descargas en Azure usan **URLs SAS firmadas** de corta expiración
  (`Storage:SignedUrlExpiryMinutes`, 15 min por defecto): el contenedor nunca es público.
- La **connection string** de la Storage Account incluye la *account key* (necesaria para
  firmar SAS). Es un **secreto de la aplicación**: va en el `.env` del servidor, nunca a Git.

### Variables (en el `.env` del servidor)

| Variable | Qué es | Ejemplo |
|----------|--------|---------|
| `STORAGE_CONNECTION_STRING` | Connection string de la Storage Account (con AccountKey) | `DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net` |
| `STORAGE_CONTAINER` | Contenedor privado por entorno | `consultorapro-qa` / `consultorapro-prod` |

### Provisionar (una vez por entorno)

```bash
# Crear Storage Account y contenedor PRIVADO (sin acceso anónimo):
az storage account create -n consultorapro<qa|prod> -g <grupo> -l <region> --sku Standard_LRS
az storage container create --account-name consultorapro<qa|prod> -n consultorapro-<qa|prod> --public-access off
# Obtener la connection string (cópiala al .env como STORAGE_CONNECTION_STRING):
az storage account show-connection-string -n consultorapro<qa|prod> -g <grupo> -o tsv
```

> Usa **cuentas/contenedores separados** para QA y Prod. Rota la account key periódicamente
> (Azure permite dos llaves para rotación sin downtime). Nunca commitees la connection string.

## Buenas prácticas de seguridad (resumen)

- 🔑 **Una llave SSH por entorno**, usuario dedicado `deploy`, nunca `root`.
- 🔒 En el servidor: deshabilita login por password y root (ver [06](06-preparacion-servidor.md)).
- 🧱 **Environments** en vez de secretos globales → QA y Prod aislados.
- ✅ **Required reviewers** en el Environment `production` → aprobación manual antes de prod.
- 🎯 Tokens con el **mínimo scope** (`read:packages`, fine-grained al repo justo).
- ♻️ **Rota** llaves y tokens periódicamente; revoca los que ya no uses.
- 🚫 Nunca commitees `.env`, `*.pem`, ni claves privadas (ya están en `.gitignore`).

Siguiente: [Preparación del servidor](06-preparacion-servidor.md).
