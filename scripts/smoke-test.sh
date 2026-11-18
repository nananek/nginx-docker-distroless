#!/usr/bin/env bash
# Smoke test for nginx-docker-distroless. Usage: smoke-test.sh <image>
set -euo pipefail

image=${1:?usage: smoke-test.sh <image>}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
suffix=$$
container="nginx-smoke-${suffix}"
upstream="nginx-upstream-${suffix}"
dns_proxy="nginx-dns-${suffix}"
network="nginx-smoke-${suffix}"

cleanup() {
  docker rm -f "$container" "$upstream" "$dns_proxy" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# 1. nginx -t with a production-like config (user nginx; pid /run/nginx.pid).
docker run --rm \
  -v "${root}/tests/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${root}/tests/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$image" -t

# 2. Serve HTTP, and check the master/worker uid split.
docker run -d --name "$container" -p 127.0.0.1:18080:80 \
  -v "${root}/tests/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${root}/tests/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18080/ >"$work/body"; then break; fi
  sleep 1
done
grep -qx 'ok' "$work/body"

master_pid=$(docker inspect -f '{{.State.Pid}}' "$container")
worker_pid=$(pgrep -P "$master_pid" | head -n1)
test -n "$worker_pid"
test "$(stat -c %u "/proc/${master_pid}")" = "0"
test "$(stat -c %u "/proc/${worker_pid}")" = "101"

# 3. Docker embedded DNS (127.0.0.11) resolved from the nginx worker.
docker network create "$network" >/dev/null
docker run -d --name "$upstream" --network "$network" "$image" >/dev/null
docker run -d --name "$dns_proxy" --network "$network" -p 127.0.0.1:18081:80 \
  -v "${root}/tests/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${root}/tests/dns-default.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18081/ >"$work/dns-body"; then break; fi
  sleep 1
done
grep -q 'Welcome to nginx' "$work/dns-body"

# 4. The image must not contain a shell or package manager.
absent() {
  local path=$1
  shift
  if docker run --rm --entrypoint "$path" "$image" "$@" >/dev/null 2>&1; then
    echo "unexpected executable in image: $path" >&2
    exit 1
  fi
}
absent /bin/sh -c true
absent /bin/bash -c true
absent /usr/bin/apt-get --version
absent /sbin/apk --version

# 5. Record image size (target: 30-50 MiB).
bytes=$(docker image inspect -f '{{.Size}}' "$image")
awk -v b="$bytes" 'BEGIN { printf "image size: %.1f MiB\n", b / 1048576 }'
