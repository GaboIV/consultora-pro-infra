# 06 — Preparación del servidor

Pasos para dejar un servidor (Ubuntu/Debian) listo para alojar ConsultoraPro.

## Requisitos del servidor

- Ubuntu 22.04+ / Debian 12+ (cualquier VPS sirve).
- Acceso `root` o un usuario con `sudo` para la preparación inicial.
- Puertos abiertos: `22` (SSH), `8080` (frontend), `5000` (backend API). Ajusta según tu `.env`.

## Opción A — automática (script incluido)

Copia `scripts/server-bootstrap.sh` al servidor y ejecútalo:

```bash
scp scripts/server-bootstrap.sh root@TU_SERVIDOR:/root/
ssh root@TU_SERVIDOR
sudo bash /root/server-bootstrap.sh
```

Esto instala Docker, crea el usuario `deploy`, lo añade al grupo `docker`, crea
`/opt/consultorapro` y prepara `~/.ssh/authorized_keys`. Luego saltas al paso "Colocar
la llave pública" y "Crear el .env" más abajo.

## Opción B — manual

### 1. Instalar Docker

```bash
curl -fsSL https://get.docker.com | sh
docker compose version    # verifica que el plugin compose esté
```

### 2. Crear el usuario de despliegue

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
sudo touch /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### 3. Carpeta de despliegue

```bash
sudo mkdir -p /opt/consultorapro
sudo chown -R deploy:deploy /opt/consultorapro
```

## Colocar la llave pública

Pega el contenido de tu `deploy_key.pub` (ver [05](05-secretos-y-conexiones.md), paso 2)
en `/home/deploy/.ssh/authorized_keys`. Verifica desde tu máquina:

```bash
ssh -i deploy_key deploy@TU_SERVIDOR "echo OK && docker ps"
```

Si responde `OK` y lista contenedores, el acceso por llave funciona.

## Crear el `.env` del servidor

Este archivo define la versión a desplegar, los puertos y los secretos de la app.

```bash
ssh deploy@TU_SERVIDOR
cd /opt/consultorapro
# Trae la plantilla (cópiala desde el repo infra o pégala a mano):
nano .env
```

Contenido para **QA** (ejemplo):

```env
COMPOSE_PROJECT_NAME=consultorapro_qa
BACKEND_IMAGE=ghcr.io/gaboiv/consultora-pro-backend
FRONTEND_IMAGE=ghcr.io/gaboiv/consultora-pro-frontend
IMAGE_TAG=qa
FRONTEND_PORT=8080
BACKEND_PORT=5000
MYSQL_ROOT_PASSWORD=<password-root-seguro>
MYSQL_DATABASE=consultorapro
MYSQL_USER=consultorapro
MYSQL_PASSWORD=<password-user-seguro>
ASPNETCORE_ENVIRONMENT=Production
JWT_KEY=<clave-jwt-min-32-caracteres>
JWT_ISSUER=ConsultoraPro
JWT_AUDIENCE=ConsultoraProApp
```

Para **Producción** usa `COMPOSE_PROJECT_NAME=consultorapro_prod` y `IMAGE_TAG=prod`
(y, si es el mismo servidor que QA, **otra carpeta** y **otros puertos** para no chocar).

```bash
chmod 600 .env     # protege el archivo
```

## QA y Producción en el mismo servidor (opcional)

Si usas un solo servidor para ambos, crea dos carpetas con su propio `.env` y puertos
distintos, y apunta `DEPLOY_PATH` de cada Environment a la carpeta correcta:

```
/opt/consultorapro-qa     IMAGE_TAG=qa    FRONTEND_PORT=8080  BACKEND_PORT=5000
/opt/consultorapro-prod   IMAGE_TAG=prod  FRONTEND_PORT=80    BACKEND_PORT=5001
```

## Primer despliegue manual (prueba antes de automatizar)

```bash
ssh deploy@TU_SERVIDOR
cd /opt/consultorapro
echo "<GHCR_PAT>" | docker login ghcr.io -u GaboIV --password-stdin
# Copia docker-compose.deploy.yml aquí (scp o pégalo), luego:
docker compose -f docker-compose.deploy.yml --env-file .env pull
docker compose -f docker-compose.deploy.yml --env-file .env up -d
docker compose -f docker-compose.deploy.yml --env-file .env ps
```

Si esto funciona a mano, el workflow de Actions hará exactamente lo mismo.

## Endurecer SSH (recomendado)

Edita `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

```bash
sudo systemctl restart ssh
```

> Asegúrate de que tu llave funciona **antes** de deshabilitar el password, o te quedas
> fuera.

## Firewall (opcional pero recomendado)

```bash
sudo ufw allow 22/tcp
sudo ufw allow 8080/tcp
sudo ufw allow 5000/tcp
sudo ufw enable
```

## Backup de la base de datos

```bash
# Volcado manual
docker exec consultorapro_qa_db \
  sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" consultorapro' > backup_$(date +%F).sql
```

Programa un cron con esto para backups periódicos. El volumen `mysql_data` persiste
entre despliegues; un `docker compose down` **no** borra los datos (solo `down -v` lo haría).

## Checklist final

- [ ] Docker + compose instalados.
- [ ] Usuario `deploy` creado, en grupo `docker`.
- [ ] Llave pública en `authorized_keys`, probada con `ssh -i`.
- [ ] `/opt/consultorapro/.env` creado y con `chmod 600`.
- [ ] `docker login ghcr.io` exitoso desde el servidor.
- [ ] Primer `pull && up -d` manual funcionando.
- [ ] Secretos cargados en los Environments de GitHub ([05](05-secretos-y-conexiones.md)).
- [ ] SSH endurecido y firewall activo.
