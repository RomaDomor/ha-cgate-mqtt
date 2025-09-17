#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="20023"
allowed_re='^(new|sync|ok)$'

output="$(
  {
    printf "net list\r\n"
    sleep 0.2
  } | nc -w 2 "$HOST" "$PORT"
)"

if ! grep -Eiq '^201[[:space:]]+Service ready:.*Clipsal C-Gate' <<<"$output"; then
  echo "Healthcheck failed: missing or invalid C-Gate banner" >&2
  exit 2
fi

net_lines="$(grep -Ei '^131[- ]?network=' <<<"$output" || true)"
if [[ -z "$net_lines" ]]; then
  echo "Healthcheck failed: no 'net list' lines found" >&2
  echo "$output" >&2
  exit 3
fi

while IFS= read -r line; do
  state="$(grep -Eo 'State=[^[:space:]]+' <<<"$line" | head -n1 | cut -d'=' -f2 || true)"
  if [[ -z "$state" ]]; then
    echo "Healthcheck failed: could not find State= in line: $line" >&2
    exit 4
  fi
  if ! [[ "$state" =~ $allowed_re ]]; then
    echo "Healthcheck failed: invalid State '$state' in line: $line" >&2
    exit 5
  fi
done <<<"$net_lines"

exit 0
