#!/usr/bin/env bash
# Entwicklungshelfer: Checkpoint-Commit anlegen und mit dem Remote abgleichen.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]]; then
  echo "Keine Aenderungen - nichts zu committen."
else
  git add -A
  git commit -m "Checkpoint commit as of $(date +'%Y-%m-%d-%H-%M-%S')."
fi

git pull --rebase
git push
