#!/bin/sh
# Switch the running server to another image version with a restorable backup.
# Usage (in the deploy dir): ./upgrade.sh <new_version>
#   1. stop the app (World checkpoints on shutdown are not required: the overlay log is durable per transaction)
#   2. pg_dump the database and archive the player-published prefabs (the only world files not derivable)
#   3. set VOXIM_VERSION in .env, start the app, wait until the QUIC listener is up
# Rollback: restore the dump printed below (pg_restore --clean), put the old VOXIM_VERSION back, docker compose up -d app.
set -eu
new=${1:?usage: ./upgrade.sh <new_version>}
cd "$(dirname "$0")"
set -a; . ./.env; set +a
old=$VOXIM_VERSION
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p backups

docker image inspect "voxim-server:$new" >/dev/null
docker compose stop app
docker compose exec -T db pg_dump -U "$MMO_DB_USER" -Fc "$MMO_DB_NAME" > "backups/$stamp-$old.dump"
tar -czf "backups/$stamp-$old-prefabs.tgz" -C "$VOXIM_DATA_DIR" $(cd "$VOXIM_DATA_DIR" && ls -d world/*/prefabs 2>/dev/null) || true
echo "backup: backups/$stamp-$old.dump backups/$stamp-$old-prefabs.tgz"

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
