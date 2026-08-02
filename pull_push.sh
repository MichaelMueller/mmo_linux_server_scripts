#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Development helper: create a checkpoint commit and sync with the remote.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]]; then
  echo "No changes - nothing to commit."
else
  git add -A
  git commit -m "Checkpoint commit as of $(date +'%Y-%m-%d-%H-%M-%S')."
fi

git pull --rebase
git push
