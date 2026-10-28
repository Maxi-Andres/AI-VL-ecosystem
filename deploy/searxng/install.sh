#!/usr/bin/env bash
# Start the local SearXNG the vision assistant searches with (see docker-compose.yml).
# Idempotent: makes the secret once (.env, not in git), then brings the container up.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f .env ]]; then
    umask 077
    printf 'SEARXNG_SECRET=%s\n' "$(openssl rand -hex 32)" > .env
fi
docker compose up -d
for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://127.0.0.1:8095/search?q=test&format=json"; then
        echo "SearXNG answering on http://127.0.0.1:8095"
        exit 0
    fi
    sleep 1
done
echo "SearXNG did not answer in 30 s: docker logs searxng" >&2
exit 1
