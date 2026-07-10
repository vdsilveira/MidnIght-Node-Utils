#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# restore-db-sync-snapshot.sh
#   Baixa o snapshot do cardano-db-sync do GitHub e restaura
#   no PostgreSQL. Evita synar o db inteiro do zero (~27 GB).
#
# Uso:
#   sudo ./restore-db-sync-snapshot.sh
#   sudo ./restore-db-sync-snapshot.sh --release v1.0
# ============================================================

RELEASE="${1:-v1.0}"
REPO="vdsilveira/MidnIght-Node-Utils"
POSTGRES_USER="${POSTGRES_USER:-midnight}"
RESTORE_DIR="/root/cexplorer-restore-$$"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

cleanup() { rm -rf "${RESTORE_DIR}"; }
trap cleanup EXIT

main() {
  echo ""
  echo -e "${CYAN}============================================${NC}"
  echo -e "${CYAN}  Restore db-sync Snapshot${NC}"
  echo -e "${CYAN}  Release: ${RELEASE}${NC}"
  echo -e "${CYAN}============================================${NC}"
  echo ""

  # Verificar dependências
  if ! command -v gh &>/dev/null; then
    echo -e "${RED}[ERRO] gh CLI não encontrado. Instale com: sudo apt install gh${NC}"
    exit 1
  fi
  if ! command -v zstd &>/dev/null; then
    echo -e "${RED}[ERRO] zstd não encontrado. Instale com: sudo apt install zstd${NC}"
    exit 1
  fi
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}[ERRO] Docker não encontrado.${NC}"
    exit 1
  fi

  # Verificar se o container postgres existe
  if ! docker ps --format '{{.Names}}' | grep -q midnight-postgres; then
    echo -e "${RED}[ERRO] Container 'midnight-postgres' não está rodando.${NC}"
    echo "  Execute primeiro: docker run -d --name midnight-postgres ..."
    exit 1
  fi

  # Autenticar gh (se não estiver autenticado)
  gh auth status &>/dev/null || {
    info "Autenticando no GitHub..."
    gh auth login
  }

  # Baixar snapshot
  info "Baixando snapshot ${RELEASE} do repositório ${REPO}..."
  mkdir -p "${RESTORE_DIR}"
  gh release download "${RELEASE}" \
    --repo "${REPO}" \
    --dir "${RESTORE_DIR}"

  local FILES=("${RESTORE_DIR}/cexplorer-snapshot-"*.part_*)
  if [ ${#FILES[@]} -eq 0 ]; then
    echo -e "${RED}[ERRO] Nenhum arquivo de snapshot encontrado na release ${RELEASE}${NC}"
    echo "  Arquivos encontrados em ${RESTORE_DIR}:"
    ls -la "${RESTORE_DIR}"
    exit 1
  fi

  # Restaurar
  local TOTAL_SIZE
  TOTAL_SIZE=$(du -ch "${FILES[@]}" | tail -1 | cut -f1)
  info "Restaurando ${TOTAL_SIZE} de snapshots no PostgreSQL..."
  info "Isso pode levar vários minutos. Não interrompa."

  cat "${FILES[@]}" | zstd -d | \
    docker exec -i midnight-postgres \
      pg_restore -U "${POSTGRES_USER}" -d cexplorer --no-owner 2>/dev/null || true

  ok "Restore concluído!"
  echo ""
  echo "  Para verificar:"
  echo "    docker exec -it midnight-postgres psql -U ${POSTGRES_USER} -d cexplorer -c 'SELECT count(*) FROM block;'"
  echo ""
  echo "  Agora inicie o cardano-db-sync:"
  echo "    docker run -d --name cardano-db-sync ..."
  echo "    (ou rode setup-midnight-node.sh --restore)"
  echo ""
}

main
