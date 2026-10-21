#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
migration_target="${1:-native}"
migration_container="$(docker run --rm -d \
  -e POSTGRES_PASSWORD=migrator \
  -p 127.0.0.1::5432 postgres:16-alpine)"

cleanup() {
  docker stop "$migration_container" >/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

migration_attempt=0
until docker exec "$migration_container" pg_isready -U postgres >/dev/null 2>&1; do
  migration_attempt=$((migration_attempt + 1))
  if [ "$migration_attempt" -ge 30 ]; then
    docker logs "$migration_container"
    exit 1
  fi
  sleep 1
done

migration_address="$(docker port "$migration_container" 5432/tcp)"
MIGRATOR_POSTGRES_TEST_PORT="${migration_address##*:}" moon test --target "$migration_target"
