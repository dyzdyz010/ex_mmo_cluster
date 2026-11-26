#!/bin/sh
# Switch the running server to another image version with a restorable backup.
# Usage (in the deploy dir): ./upgrade.sh <new_version>
#   1. stop the app (World checkpoints on shutdown are not required: the overlay log is durable per transaction)
#   2. pg_dump the database and archive the player-published prefabs (the only world files not derivable);
#      Hindsight（NPC 记忆）用官方 hindsight-admin backup 在运行中的容器里导出（单事务 REPEATABLE READ 快照），拷到 backups/
#   3. set VOXIM_VERSION in .env, start the app, wait until the QUIC listener is up
# Rollback: restore the dump printed below (pg_restore --clean), put the old VOXIM_VERSION back, docker compose up -d app.
# Hindsight 的恢复步骤见 README“Hindsight”的备份与恢复（restore 会先清空库，再 repair-bank）。
set -eu
new=${1:?usage: ./upgrade.sh <new_version>}
cd "$(dirname "$0")"
set -a; . ./.env; set +a
old=$VOXIM_VERSION
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p backups

docker image inspect "voxim-server:$new" >/dev/null
# Hindsight 备份放在停 app 之后（NPC 不再写，两边备份同一时刻）；先确认它在跑，不在跑就在游戏停之前退出。
docker compose exec -T hindsight true
docker compose stop app
docker compose exec -T db pg_dump -U "$MMO_DB_USER" -Fc "$MMO_DB_NAME" > "backups/$stamp-$old.dump"
tar -czf "backups/$stamp-$old-prefabs.tgz" -C "$VOXIM_DATA_DIR" $(cd "$VOXIM_DATA_DIR" && ls -d world/*/prefabs 2>/dev/null) || true
docker compose exec -T hindsight hindsight-admin backup /tmp/hindsight-backup.zip
docker compose cp hindsight:/tmp/hindsight-backup.zip "backups/$stamp-hindsight.zip"
docker compose exec -T hindsight rm /tmp/hindsight-backup.zip
echo "backup: backups/$stamp-$old.dump backups/$stamp-$old-prefabs.tgz backups/$stamp-hindsight.zip"

sed -i "s/^VOXIM_VERSION=.*/VOXIM_VERSION=$new/" .env
docker compose up -d app
for _ in $(seq 1 900); do
  if docker compose logs app 2>&1 | grep -q "voxim_quic_listener port="; then
    echo "voxim-server:$new ready (was $old)"
    exit 0
  fi
  sleep 1
done
echo "voxim-server:$new did not report the QUIC listener within 15 min; see docker compose logs app" >&2
exit 1
