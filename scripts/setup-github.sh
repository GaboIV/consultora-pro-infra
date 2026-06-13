#!/usr/bin/env bash
# =====================================================================
#  setup-github.sh
#  Crea la rama 'qa', protege 'qa' y 'main', y crea los Environments
#  'qa' y 'production' en un repositorio de GitHub.
#
#  Requisitos:
#    - GitHub CLI instalado y autenticado:  gh auth login
#    - Ejecutarse DENTRO del repo que quieres configurar, o pasar --repo
#
#  Uso:
#    ./scripts/setup-github.sh GaboIV/consultora-pro-backend
#    ./scripts/setup-github.sh GaboIV/consultora-pro-frontend
#    ./scripts/setup-github.sh GaboIV/consultora-pro-infra   (sin rama qa/main de codigo, ver nota)
# =====================================================================
set -euo pipefail

REPO="${1:?Uso: ./setup-github.sh <owner/repo>}"

echo ">> Configurando repo: $REPO"

# --- 1. Crear rama qa a partir de main (si no existe) ---
if gh api "repos/$REPO/branches/main" >/dev/null 2>&1; then
  if ! gh api "repos/$REPO/branches/qa" >/dev/null 2>&1; then
    echo ">> Creando rama 'qa' desde 'main'..."
    MAIN_SHA=$(gh api "repos/$REPO/git/refs/heads/main" --jq '.object.sha')
    gh api "repos/$REPO/git/refs" -f ref="refs/heads/qa" -f sha="$MAIN_SHA" >/dev/null
    echo "   rama 'qa' creada."
  else
    echo ">> rama 'qa' ya existe, ok."
  fi
else
  echo "!! Aviso: no existe rama 'main' en $REPO. Crea/pushea main primero."
fi

# --- 2. Proteger ramas main y qa ---
# Requiere Pull Request con 1 aprobacion y que pase el workflow.
protect_branch () {
  local BRANCH="$1"
  echo ">> Protegiendo rama '$BRANCH'..."
  gh api -X PUT "repos/$REPO/branches/$BRANCH/protection" \
    -H "Accept: application/vnd.github+json" \
    --input - <<'JSON' >/dev/null
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
  echo "   rama '$BRANCH' protegida."
}

protect_branch main || echo "   (no se pudo proteger main; revisa permisos/plan)"
protect_branch qa   || echo "   (no se pudo proteger qa; revisa permisos/plan)"

# --- 3. Crear Environments qa y production ---
create_env () {
  local ENV_NAME="$1"
  echo ">> Creando Environment '$ENV_NAME'..."
  gh api -X PUT "repos/$REPO/environments/$ENV_NAME" >/dev/null
  echo "   Environment '$ENV_NAME' listo."
}

create_env qa
create_env production

echo ""
echo ">> Listo. Recuerda:"
echo "   - Cargar los SECRETOS en cada Environment (ver docs/05-secretos-y-conexiones.md)"
echo "   - En 'production' puedes activar 'Required reviewers' para aprobacion manual."
echo "   - La proteccion de ramas requiere repo en plan que la soporte"
echo "     (repos publicos o GitHub Pro/Team/Enterprise para privados)."
