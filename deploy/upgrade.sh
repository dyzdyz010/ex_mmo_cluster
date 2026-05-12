#!/bin/sh
set -eu

# ex_mmo_cluster production upgrade helper.
# .env remains the single source of deployment configuration. The server
# release uses IMAGE_TAG; the host-side nginx client can optionally be replaced
# from WEB_CLIENT_IMAGE_TAG.

DEPLOY_DIR="${DEPLOY_DIR:-/data/ex_mmo_cluster}"
cd "$DEPLOY_DIR"

if [ ! -f .env ]; then
  echo "ERROR: $DEPLOY_DIR/.env not found" >&2
  exit 1
fi

set -a
. ./.env
set +a

: "${SCENE_SERVER_COUNT:?SCENE_SERVER_COUNT is required in .env}"
: "${IMAGE_TAG:?IMAGE_TAG is required in .env}"

if docker info >/dev/null 2>&1; then
  DOCKER_USES_SUDO=0
  docker_cmd() {
    docker "$@"
  }
else
  sudo -v
  DOCKER_USES_SUDO=1
  docker_cmd() {
    sudo docker "$@"
  }
fi

compose() {
  docker_cmd compose "$@"
}

upgrade_web_client() {
  if [ -z "${WEB_CLIENT_IMAGE_TAG:-}" ]; then
    echo "==> Skipping web client: WEB_CLIENT_IMAGE_TAG is not set"
    return 0
  fi

  WEB_CLIENT_DIST_DIR="${WEB_CLIENT_DIST_DIR:-$DEPLOY_DIR/web_client/dist}"
  stamp="$(date +%Y%m%d-%H%M%S)"
  parent_dir="$(dirname "$WEB_CLIENT_DIST_DIR")"
  tmp_dir="$parent_dir/dist.next-$stamp"
  backup_dir="$DEPLOY_DIR/backup/web_client-dist-$stamp"

  echo "==> Pulling web client image"
  docker_cmd pull "$WEB_CLIENT_IMAGE_TAG"

  echo "==> Extracting web client static files"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir" "$DEPLOY_DIR/backup"

  container_id="$(docker_cmd create "$WEB_CLIENT_IMAGE_TAG")"
  if ! docker_cmd cp "$container_id:/usr/share/nginx/html/." "$tmp_dir/"; then
    docker_cmd rm -f "$container_id" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
    echo "ERROR: failed to copy web client files from $WEB_CLIENT_IMAGE_TAG" >&2
    exit 1
  fi
  docker_cmd rm "$container_id" >/dev/null

  if [ "$DOCKER_USES_SUDO" = "1" ]; then
    sudo chown -R "$(id -u):$(id -g)" "$tmp_dir"
  fi

  test -f "$tmp_dir/index.html"
  grep -q 'src="/client/assets/' "$tmp_dir/index.html"
  chmod -R a+rX "$tmp_dir"

  echo "==> Replacing host-side web client"
  if [ -d "$WEB_CLIENT_DIST_DIR" ]; then
    mv "$WEB_CLIENT_DIST_DIR" "$backup_dir"
  fi

  if ! mv "$tmp_dir" "$WEB_CLIENT_DIST_DIR"; then
    if [ -d "$backup_dir" ] && [ ! -d "$WEB_CLIENT_DIST_DIR" ]; then
      mv "$backup_dir" "$WEB_CLIENT_DIST_DIR"
    fi
    echo "ERROR: failed to install web client; restored previous dist when possible" >&2
    exit 1
  fi

  echo "==> Web client installed at $WEB_CLIENT_DIST_DIR"
  if [ -d "$backup_dir" ]; then
    echo "==> Previous web client backup: $backup_dir"
  fi
}

echo "==> Pulling business images"
compose pull app scene

echo "==> Ensuring postgres is running without recreating it"
compose up -d --no-recreate postgres

echo "==> Running release migrations"
compose run --rm --no-deps -e RELEASE_DISTRIBUTION=none -e DISABLE_CLUSTER=true app eval 'DataService.Release.migrate()'

echo "==> Updating app and scene containers"
compose up -d --scale "scene=${SCENE_SERVER_COUNT}" app scene

upgrade_web_client

echo "==> Current compose status"
compose ps
