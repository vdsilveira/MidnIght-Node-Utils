#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# setup-midnight-node.sh
#   Instala/configura Cardano Node + db-sync + Midnight Node
#   em Docker, Ubuntu 24.04, rede preprod.
#
# Uso:
#   sudo ./setup-midnight-node.sh              # instala tudo do zero
#   sudo ./setup-midnight-node.sh --restore     # + restaura snapshot db-sync
#   sudo ./setup-midnight-node.sh --help        # ajuda
# ============================================================

# ---------- cores ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERRO]${NC}  $*"; }

# ---------- defaults ----------
NETWORK="${NETWORK:-preprod}"
CARDANO_IMAGE="${CARDANO_IMAGE:-ghcr.io/intersectmbo/cardano-node:11.0.1}"
DB_SYNC_IMAGE="${DB_SYNC_IMAGE:-ghcr.io/intersectmbo/cardano-db-sync:13.7.2.1}"
MIDNIGHT_IMAGE="${MIDNIGHT_IMAGE:-midnightntwrk/midnight-node:0.22.3}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-sua_senha_aqui}"
POSTGRES_DB="${POSTGRES_DB:-cexplorer}"

BASE_DIR="${BASE_DIR:-/opt/midnight}"
CARDANO_DIR="${BASE_DIR}/cardano"
DB_SYNC_DIR="${BASE_DIR}/db-sync"
MIDNIGHT_DIR="${BASE_DIR}/midnight"
COMPOSE_DIR="${BASE_DIR}/compose"

RESTORE_SNAPSHOT=false
[[ "${1:-}" == "--restore" ]] && RESTORE_SNAPSHOT=true
[[ "${1:-}" == "--help" ]] && {
  sed -n '/^# Uso:/,/^# =======/p' "$0" | sed 's/^# //'
  exit 0
}

# ============================================================
# 1. DEPENDÊNCIAS
# ============================================================
install_deps() {
  info "Verificando dependências..."

  # Docker
  if ! command -v docker &>/dev/null; then
    warn "Docker não encontrado. Instalando..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
    ok "Docker instalado"
  else
    ok "Docker encontrado ($(docker --version))"
  fi

  # gh CLI
  if ! command -v gh &>/dev/null; then
    warn "gh CLI não encontrado. Instalando..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
      dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
      tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    apt-get update && apt-get install -y gh
    ok "gh CLI instalado"
  else
    ok "gh CLI encontrado ($(gh --version 2>&1 | head -1))"
  fi

  # mitril (Mithril client) para baixar snapshot do Cardano
  if ! command -v mitril &>/dev/null; then
    warn "mitril (Mithril) não encontrado. Instalando..."
    MITHRIL_VERSION="0.10.0"
    wget -q "https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_VERSION}/mithril-client-${MITHRIL_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
      -O /tmp/mithril-client.tar.gz
    tar -xzf /tmp/mithril-client.tar.gz -C /usr/local/bin/ mithril-client
    mv /usr/local/bin/mithril-client /usr/local/bin/mitril
    chmod +x /usr/local/bin/mitril
    rm -f /tmp/mithril-client.tar.gz
    ok "mitril instalado"
  else
    ok "mitril encontrado"
  fi

  # jq + zstd + curl
  for pkg in jq zstd curl wget; do
    if ! command -v "$pkg" &>/dev/null; then
      apt-get install -y "$pkg"
      ok "$pkg instalado"
    fi
  done

  apt-get install -y ca-certificates gnupg lsb-release 2>/dev/null || true
  ok "Todas as dependências OK"
}

# ============================================================
# 2. DIRETÓRIOS
# ============================================================
create_dirs() {
  info "Criando diretórios..."
  mkdir -p "${CARDANO_DIR}/data" "${DB_SYNC_DIR}" "${MIDNIGHT_DIR}/data" "${COMPOSE_DIR}"
  ok "Diretórios criados em ${BASE_DIR}"
}

# ============================================================
# 3. CARDANO NODE (Docker)
# ============================================================
setup_cardano_node() {
  info "Configurando Cardano Node..."

  # Baixar configs da rede via mitril (mais rápido que sync do zero)
  if [ ! -f "${CARDANO_DIR}/db/ledger" ]; then
    info "Baixando snapshot do Cardano via Mithril (pode levar alguns minutos)..."
    mkdir -p "${CARDANO_DIR}/db"
    mitril cardano-db download \
      --genesis-verification-key https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/pre-release-preview/genesis.vkey \
      --download-dir "${CARDANO_DIR}/db" \
      --network preprod || warn "Falha ao baixar snapshot Mithril — o node fará sync completo (mais lento)"
  else
    ok "Banco do Cardano já existe, pulando download"
  fi

  # Parar container existente se houver
  docker rm -f cardano-node 2>/dev/null || true

  docker run -d --name cardano-node \
    --restart unless-stopped \
    --network host \
    -e NETWORK="${NETWORK}" \
    -v cardano-node-ipc:/ipc \
    -v "${CARDANO_DIR}/data:/data" \
    "${CARDANO_IMAGE}"

  ok "Cardano Node rodando (docker logs -f cardano-node)"
}

# ============================================================
# 4. POSTGRESQL + DB-SYNC
# ============================================================
setup_db_sync() {
  info "Configurando PostgreSQL + db-sync..."

  # PostgreSQL
  docker rm -f midnight-postgres 2>/dev/null || true
  docker run -d --name midnight-postgres \
    --restart unless-stopped \
    --network host \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -v midnight-postgres-data:/var/lib/postgresql/data \
    "postgres:${POSTGRES_VERSION}"

  ok "PostgreSQL rodando (porta 5432)"

  # Aguardar PostgreSQL ficar pronto
  info "Aguardando PostgreSQL ficar pronto..."
  for i in $(seq 1 30); do
    if docker exec midnight-postgres pg_isready -U "${POSTGRES_USER}" &>/dev/null; then
      ok "PostgreSQL pronto"
      break
    fi
    sleep 2
  done

  # Restaurar snapshot se --restore
  if [ "$RESTORE_SNAPSHOT" = true ]; then
    info "Modo --restore ativado. Baixando snapshot do db-sync do GitHub..."
    local SNAPSHOT_DIR="/tmp/cexplorer-snapshot-restore"
    mkdir -p "${SNAPSHOT_DIR}"
    gh release download v1.0 \
      --repo vdsilveira/MidnIght-Node-Utils \
      --dir "${SNAPSHOT_DIR}"
    info "Restaurando snapshot no PostgreSQL (pode levar vários minutos)..."
    cat "${SNAPSHOT_DIR}/cexplorer-snapshot-"*.part_* | zstd -d | \
      docker exec -i midnight-postgres pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner 2>/dev/null || true
    rm -rf "${SNAPSHOT_DIR}"
    ok "Snapshot restaurado"
  fi

  # db-sync
  docker rm -f cardano-db-sync 2>/dev/null || true
  docker run -d --name cardano-db-sync \
    --restart unless-stopped \
    --network host \
    -e NETWORK="${NETWORK}" \
    -e POSTGRES_HOST=127.0.0.1 \
    -e POSTGRES_PORT=5432 \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -v cardano-node-ipc:/node-ipc \
    "${DB_SYNC_IMAGE}"

  ok "cardano-db-sync rodando (docker logs -f cardano-db-sync)"
}

# ============================================================
# 5. MIDNIGHT NODE
# ============================================================
setup_midnight_node() {
  info "Configurando Midnight Node..."

  # Clonar repo oficial (útil pra debug, chain specs, etc.)
  if [ ! -d "${MIDNIGHT_DIR}/repo" ]; then
    info "Clonando repositório oficial do midnight-node..."
    git clone --depth 1 \
      https://github.com/midnightntwrk/midnight-node.git \
      "${MIDNIGHT_DIR}/repo"
    ok "Repo clonado em ${MIDNIGHT_DIR}/repo"
  else
    ok "Repo já clonado"
  fi

  # Parar container existente se houver
  docker rm -f midnight-node 2>/dev/null || true

  docker run -d --name midnight-node \
    --restart unless-stopped \
    --network host \
    -e CFG_PRESET="${NETWORK}" \
    -e DB_SYNC_POSTGRES_CONNECTION_STRING="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}" \
    -e CARDANO_SECURITY_PARAMETER=2160 \
    -e PGSSLMODE=disable \
    -e BASE_PATH=/data \
    -v "${MIDNIGHT_DIR}/data:/data" \
    "${MIDNIGHT_IMAGE}" \
    --sync warp \
    --rpc-external \
    --rpc-port 19944 \
    --port 30333

  ok "Midnight Node rodando (docker logs -f midnight-node)"
}

# ============================================================
# 6. AGUARDAR + VALIDAR
# ============================================================
wait_and_verify() {
  info "Aguardando Midnight Node responder na RPC..."
  for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:19944/ 2>/dev/null; then
      ok "RPC respondendo em http://127.0.0.1:19944"
      break
    fi
    sleep 5
  done

  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}  INFRAESTRUTURA PRONTA!${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo ""
  echo "  Containers rodando:"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  echo ""
  echo "  Midnight Node sync:"
  echo "    curl -s http://127.0.0.1:19944/ 2>/dev/null | jq ."
  echo ""
  echo "  Logs:"
  echo "    docker logs -f midnight-node"
  echo "    docker logs -f cardano-db-sync"
  echo "    docker logs -f cardano-node"
  echo ""
  echo "  SSH Tunnel (para acessar RPC localmente):"
  echo "    ssh -L 19944:127.0.0.1:19944 root@<IP-DA-VM>"
  echo ""
  echo "  Snapshot do Midnight Node (após sync completo):"
  echo "    sudo tar -I 'zstd -3' -cf /tmp/midnight-snapshot-\\$(date +%Y%m%d).tar.zst -C ${MIDNIGHT_DIR} data"
  echo ""
  echo "  Snapshot do db-sync:"
  echo "    sudo ./restore-db-sync-snapshot.sh"
  echo ""
}

# ============================================================
# MAIN
# ============================================================
main() {
  echo ""
  echo -e "${CYAN}============================================${NC}"
  echo -e "${CYAN}  Midnight Node Utils — Setup Completo${NC}"
  echo -e "${CYAN}  Rede: ${NETWORK}${NC}"
  echo -e "${CYAN}============================================${NC}"
  echo ""

  if [ "$(id -u)" -ne 0 ]; then
    err "Execute como root (sudo ./setup-midnight-node.sh)"
    exit 1
  fi

  install_deps
  create_dirs
  setup_cardano_node
  setup_db_sync
  setup_midnight_node
  wait_and_verify
}

main
