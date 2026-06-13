#!/usr/bin/env bash
# =====================================================================
#  server-bootstrap.sh
#  Prepara un servidor Ubuntu/Debian limpio para alojar ConsultoraPro:
#    - Instala Docker Engine + plugin compose
#    - Crea el usuario de despliegue 'deploy'
#    - Crea la carpeta de despliegue y deja todo listo para el .env
#
#  Ejecutar EN EL SERVIDOR como root (o con sudo):
#    sudo bash server-bootstrap.sh
#
#  Despues de esto, sigue docs/06-preparacion-servidor.md para:
#    - colocar la clave SSH publica del usuario 'deploy'
#    - crear el archivo .env
# =====================================================================
set -euo pipefail

DEPLOY_USER="deploy"
DEPLOY_DIR="/opt/consultorapro"

echo ">> Actualizando paquetes..."
apt-get update -y

echo ">> Instalando Docker Engine..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
else
  echo "   docker ya instalado."
fi

echo ">> Verificando docker compose plugin..."
docker compose version >/dev/null 2>&1 || {
  apt-get install -y docker-compose-plugin
}

echo ">> Creando usuario '$DEPLOY_USER'..."
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
# Permitir que 'deploy' use docker sin sudo
usermod -aG docker "$DEPLOY_USER"

echo ">> Preparando carpeta de despliegue $DEPLOY_DIR..."
mkdir -p "$DEPLOY_DIR"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_DIR"

echo ">> Preparando ~/.ssh del usuario deploy..."
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown "$DEPLOY_USER":"$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"

echo ""
echo ">> LISTO. Pasos manuales restantes:"
echo "   1) Pega la CLAVE PUBLICA de despliegue en:"
echo "        /home/$DEPLOY_USER/.ssh/authorized_keys"
echo "   2) Crea el archivo de entorno:"
echo "        $DEPLOY_DIR/.env   (usa .env.example como plantilla)"
echo "   3) (Opcional pero recomendado) endurece SSH:"
echo "        - PasswordAuthentication no"
echo "        - PermitRootLogin no"
echo "   Detalle completo en docs/06-preparacion-servidor.md"
