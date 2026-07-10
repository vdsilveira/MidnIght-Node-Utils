# Midnight Node Utils

Utilitários para deploy e gerenciamento de infraestrutura Midnight Network.

## Conteúdo

- `db-sync-snapshot-*` — Snapshots do cardano-db-sync (banco `cexplorer`) para evitar resync do zero
- Scripts e configs auxiliares para midnight-node

## Como usar o Snapshot

### Download
```bash
gh release download db-sync-snapshot-2026-07-10 \
  -R vdsilveira/MidnIght-Node-Utils
```

### Restore no PostgreSQL
```bash
# Com container PostgreSQL rodando com db cexplorer vazio
docker exec -i midnight-postgres \
  pg_restore -U midnight -d cexplorer -F c \
  < cexplorer-snapshot-20260710.dump
```

> O cardano-db-sync ao iniciar detecta que o banco já está populado e não faz resync.

### Criar um novo snapshot
```bash
docker exec midnight-postgres \
  pg_dump -U midnight -d cexplorer -F c -Z 9 \
  -f /tmp/cexplorer-snapshot-$(date +%Y%m%d).dump

gh release create db-sync-snapshot-$(date +%Y-%m-%d) \
  /tmp/cexplorer-snapshot-*.dump \
  -R vdsilveira/MidnIght-Node-Utils
```

## Requisitos

- Docker & Docker Compose
- PostgreSQL 16
- gh CLI autenticado
