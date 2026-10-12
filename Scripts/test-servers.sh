#!/bin/zsh
# Starts the test servers (docker-compose.yml) that `swift test` connects to, after making the SSH bastion's
# test key in .testing/ssh (gitignored, so every checkout makes its own).
#
#   Scripts/test-servers.sh          start and wait until healthy
#   Scripts/test-servers.sh down     stop (add -v to delete their data)
#
# forwardsThroughThisMac also needs this Mac's Remote Login and the key in ~/.ssh/authorized_keys; the test
# prints the line to add.
set -euo pipefail
cd "${0:A:h}/.."

if [[ ${1:-up} == down ]]; then
  shift; docker compose down "$@"; exit
fi
if [[ ! -f .testing/ssh/id_ed25519 ]]; then
  mkdir -p .testing/ssh
  ssh-keygen -q -t ed25519 -N '' -C 'DatabasePro tests' -f .testing/ssh/id_ed25519
  echo "==> Made the test key .testing/ssh/id_ed25519"
fi
docker compose up -d --wait
