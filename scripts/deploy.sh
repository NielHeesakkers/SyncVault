#!/bin/bash
# Deploy SyncVault to Docker on Mac Mini
# Usage: ./scripts/deploy.sh

set -e

echo "=== Building web UI ==="
cd "$(dirname "$0")/../web"
npm run build
rm -rf ../internal/api/rest/dist
cp -R build ../internal/api/rest/dist

echo "=== Building Go ==="
cd ..
go build ./...

echo "=== Committing ==="
git add -A
if git diff --cached --quiet; then
    echo "No changes to commit"
else
    git commit -m "${1:-Deploy update}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
fi

echo "=== Pushing ==="
git push origin main

echo "=== Waiting for CI ==="
gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')

echo "=== Deploying to server ==="
expect -c '
set timeout 90
spawn ssh -o StrictHostKeyChecking=no server@192.168.1.2
expect "assword:"
send "Niel0935\r"
expect "% "
send "/Users/server/Docker/docker-stacks/syncvault/update.sh && echo DEPLOYED\r"
expect -timeout 90 "DEPLOYED"
send "exit\r"
expect eof
'

echo ""
echo "=== Deploy complete ==="
