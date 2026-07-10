# Midnight Node Utils

Utilitários para deploy e gerenciamento de infraestrutura **Midnight Network** + **Cardano** em Docker.

## O que este repositório oferece

- **`setup-midnight-node.sh`** — Script único que instala tudo do zero (Ubuntu 24.04)
- **`restore-db-sync-snapshot.sh`** — Utilitário para restaurar snapshot do db-sync
- **Snapshots (GitHub Releases)** — Banco do db-sync pré-sincronizado (~27 GB → ~4 GB comprimido)

## Quick Start

```bash
# 1. Baixar e executar o setup
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/vdsilveira/MidnIght-Node-Utils/main/setup-midnight-node.sh)"

# 2. (Opcional) Restaurar snapshot do db-sync para evitar sync do zero
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/vdsilveira/MidnIght-Node-Utils/main/setup-midnight-node.sh)" -- --restore
```

## O que será instalado

| Componente | Imagem | Função |
|---|---|---|
| Cardano Node | `ghcr.io/intersectmbo/cardano-node:11.0.1` | Node da rede Cardano (preprod) |
| PostgreSQL | `postgres:16` | Banco do db-sync |
| Cardano db-sync | `ghcr.io/intersectmbo/cardano-db-sync:13.7.2.1` | Indexador do Cardano |
| Midnight Node | `midnightntwrk/midnight-node:0.22.3` | Sidechain Midnight |

## Snapshots Disponíveis

### db-sync (cexplorer)

| Release | Data | Tamanho | Conteúdo |
|---|---|---|---|
| `v1.0` | 2026-07-10 | ~4 GB (3 partes) | db-sync preprod completo (~27 GB original) |

**Como restaurar manualmente (usar `/root/` — `/tmp` é tmpfs com tamanho limitado):**

```bash
# Download + restore em um comando
mkdir -p /root/snapshot-restore
gh release download v1.0 \
  --repo vdsilveira/MidnIght-Node-Utils \
  --dir /root/snapshot-restore

cat /root/snapshot-restore/cexplorer-snapshot-*.part_* | zstd -d | \
  docker exec -i midnight-postgres \
    pg_restore -U midnight -d cexplorer --no-owner

# Verificar
docker exec -it midnight-postgres \
  psql -U midnight -d cexplorer -c 'SELECT count(*) FROM block;'
```

**Snapshot validado:** testado com restore + conexão ao cardano-node + sync contínuo
sem erros de consenso (4.920.901 blocks, 75 tabelas, 26 GB).

### midnight-node (futuro)

Após o node sincronizar completamente, faremos snapshot do diretório `/opt/midnight/midnight/data` para releases futuras.

## Arquitetura

```
┌──────────────────────────────────────────────────┐
│                  VM / Host                       │
│                                                   │
│  ┌──────────────┐   ┌──────────────────────┐     │
│  │ cardano-node  │◄──│   cardano-db-sync    │     │
│  │  NETWORK=pre  │   │  postgres://localhost│     │
│  └──────┬───────┘   └──────────┬───────────┘     │
│         │ IPC                  │                  │
│         ▼                      ▼                  │
│  ┌──────────────────────────────────────────┐     │
│  │          midnight-node                    │     │
│  │  CFG_PRESET=preprod                       │     │
│  │  --sync warp --rpc-external              │     │
│  │  CARDANO_SECURITY_PARAMETER=2160          │     │
│  └──────────────────────────────────────────┘     │
│                                                   │
│  Portas:                                          │
│    19944 — RPC Midnight                           │
│    30333 — P2P Midnight                           │
│    3001  — P2P Cardano                            │
│    5432  — PostgreSQL                             │
└──────────────────────────────────────────────────┘
```

## Comandos Úteis

```bash
# Verificar sync do Midnight
curl -s http://127.0.0.1:19944/

# Logs
docker logs -f midnight-node
docker logs -f cardano-db-sync
docker logs -f cardano-node

# SSH Tunnel (para acessar RPC da sua máquina)
ssh -L 19944:127.0.0.1:19944 root@<IP-DA-VM>

# Verificar tamanho do banco do Midnight
du -sh /opt/midnight/midnight/data

# Criar snapshot do Midnight Node (após sync completo)
tar -I 'zstd -3' -cf /tmp/midnight-snapshot-$(date +%Y%m%d).tar.zst \
  -C /opt/midnight/midnight data
```

## Flags Importantes (aprendizados)

| Flag | Motivo |
|---|---|
| `CFG_PRESET=preprod` | Usar preset em vez de `--chain` manual |
| `--sync warp` | Evita panic no pallet `committee-selection` em blocos antigos |
| `--rpc-external --rpc-port 19944` | RPC acessível via SSH tunnel |
| `CARDANO_SECURITY_PARAMETER=2160` | Exigido pelo midnight-node em preprod |
| `PGSSLMODE=disable` | Conexão local com PostgreSQL sem SSL |
| `POSTGRES_HOST=localhost` | Usar `localhost` (não `127.0.0.1`) — db-sync 13.6.x quebra com IP |
| `POSTGRES_USER=midnight` | Usuário do PostgreSQL (configurável via env var) |

## Solução de Problemas

### Midnight Node trava ao sincronizar

Se o node panica com erro `committee-selection/pallet/lib.rs:397`, a causa é tentar
processar blocos antigos cuja inherent data não é decodificável pelo runtime v0.22.3.

**Solução:** Use `--sync warp` (já configurado no script). O warp sync baixa
o estado recente e ignora blocos antigos.

Se mesmo assim travar, limpe o banco e reinicie:

```bash
docker rm -f midnight-node
rm -rf /opt/midnight/midnight/data
docker run -d ... --sync warp ...
```

### db-sync morre com "connection to client lost"

Provavelmente falta de RAM. **Solução:** adicione swap:

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
# Opcional: /etc/fstab para persistir
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

E use pipe com zstd em vez de `-Z` interno do pg_dump (menos memória).

### db-sync: "libpq: failed (invalid integer value)"

O db-sync v13.6.0.4 não aceita `POSTGRES_HOST=127.0.0.1` — ele interpreta
o IP como parte da string de conexão de forma incorreta.

**Solução:** use `POSTGRES_HOST=localhost` (já corrigido no script).

### /tmp sem espaço (tmpfs cheio)

O `/tmp` do Ubuntu é um tmpfs (RAM), normalmente com 50% da RAM ou ~12 GB.
Para downloads grandes (snapshots de ~4 GB), use `/root/` ou `/opt/`.

**Solução:** o script já usa `/root/cexplorer-snapshot-restore` para downloads.
