#!/bin/sh
set -eu

REDISCLI_AUTH="$(cat /run/secrets/healthcheck_password)"
export REDISCLI_AUTH

response="$(redis-cli \
  --tls \
  --cacert /tls/ca.crt \
  -h 127.0.0.1 \
  -p 6379 \
  --user healthcheck \
  --no-auth-warning \
  ping 2>&1)" || exit 1

[ "$response" = "PONG" ]
