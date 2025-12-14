#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run-local.sh <path-to-zip> <github-token> [owner] [repository] [retries] [backoff]
PACKAGE_ZIP=${1:-dist/*.zip}
GITHUB_TOKEN=${2:-}
REPO_OWNER=${3:-}
REPO=${4:-}
RETRIES=${5:-3}
BACKOFF=${6:-5}

if [ -z "$GITHUB_TOKEN" ]; then
  echo "Usage: $0 <path-to-zip> <github-token> [owner] [repository] [retries] [backoff]"
  exit 1
fi

export GITHUB_TOKEN="$GITHUB_TOKEN"

bash ./.github/actions/github-packages-publish/publish.sh "$PACKAGE_ZIP" "$GITHUB_TOKEN" "$RETRIES" "$BACKOFF" "$REPO_OWNER" "$REPO"

