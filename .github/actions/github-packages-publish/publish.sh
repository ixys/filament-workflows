#!/usr/bin/env bash
set -euo pipefail

PACKAGE_GLOB=${1:-}
GITHUB_TOKEN_INPUT=${2:-}
RETRIES_INPUT=${3:-3}
BACKOFF_INPUT=${4:-5}
REPO_OWNER_INPUT=${5:-}
REPO_INPUT=${6:-}

# Resolve token (prefer input, fallback to env GITHUB_TOKEN)
if [ -n "$GITHUB_TOKEN_INPUT" ]; then
  GITHUB_TOKEN="$GITHUB_TOKEN_INPUT"
else
  GITHUB_TOKEN="${GITHUB_TOKEN:-}"
fi

if [ -z "$GITHUB_TOKEN" ]; then
  echo "ERROR: No GitHub token provided (use github_token input or ensure GITHUB_TOKEN is available)." >&2
  exit 1
fi

# Find the zip file (support glob)
ZIP_FILE=""
for f in $PACKAGE_GLOB; do
  if [ -f "$f" ]; then
    ZIP_FILE="$f"
    break
  fi
done
if [ -z "$ZIP_FILE" ]; then
  echo "ERROR: No artifact matching '$PACKAGE_GLOB' found." >&2
  exit 1
fi

echo "Found archive to publish: $ZIP_FILE"

# Read composer.json to determine package name & version
if [ ! -f composer.json ]; then
  echo "ERROR: composer.json not found in repository root." >&2
  exit 1
fi
PACKAGE_NAME=$(jq -r .name composer.json)
PACKAGE_VERSION=$(jq -r .version composer.json)
PACKAGE_DESC=$(jq -r '.description // ""' composer.json)

if [ -z "$PACKAGE_NAME" ] || [ "$PACKAGE_NAME" = "null" ]; then
  echo "ERROR: package name not found in composer.json" >&2
  exit 1
fi
if [ -z "$PACKAGE_VERSION" ] || [ "$PACKAGE_VERSION" = "null" ]; then
  echo "ERROR: package version not found in composer.json" >&2
  exit 1
fi

echo "Package: $PACKAGE_NAME@$PACKAGE_VERSION"

# Determine owner/repository
REPOSITORY_OWNER="${REPO_OWNER_INPUT:-${GITHUB_REPOSITORY_OWNER:-}}"
REPOSITORY_FULL="${REPO_INPUT:-${GITHUB_REPOSITORY:-}}"
if [ -z "$REPOSITORY_OWNER" ]; then
  # fallback: parse owner from GITHUB_REPOSITORY if available
  if [ -n "$REPOSITORY_FULL" ]; then
    REPOSITORY_OWNER=${REPOSITORY_FULL%%/*}
  fi
fi

if [ -z "$REPOSITORY_OWNER" ]; then
  echo "ERROR: cannot determine repository owner (set repository_owner input or ensure GITHUB_REPOSITORY_OWNER env)." >&2
  exit 1
fi

# Prepare metadata JSON
cat > /tmp/metadata.json <<EOF
{
  "name": "$PACKAGE_NAME",
  "package_type": "composer",
  "version": "$PACKAGE_VERSION",
  "description": "$PACKAGE_DESC"
}
EOF

# URL-encode package name for path
ENCODED_NAME=$(php -r 'echo rawurlencode(trim(stream_get_contents(STDIN)));' <<< "$PACKAGE_NAME")

# Detect owner type with retries and error handling (protect jq from empty response)
OWNER_INFO_FILE=/tmp/owner_info.json
OWNER_DETECT_ATTEMPT=1
OWNER_DETECT_MAX=3
OWNER_DETECT_BACKOFF=2
OWNER_HTTP_STATUS=0

while [ $OWNER_DETECT_ATTEMPT -le $OWNER_DETECT_MAX ]; do
  echo "Fetching owner info (attempt $OWNER_DETECT_ATTEMPT/$OWNER_DETECT_MAX)..."
  # Save body to file and capture http status
  OWNER_HTTP_STATUS=$(curl -sS -o "$OWNER_INFO_FILE" -w "%{http_code}" -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/users/$REPOSITORY_OWNER" || echo "000")

  if [ "$OWNER_HTTP_STATUS" -lt 400 ] && [ -s "$OWNER_INFO_FILE" ]; then
    OWNER_INFO=$(cat "$OWNER_INFO_FILE")
    break
  fi

  echo "Warning: failed to fetch owner info (status: $OWNER_HTTP_STATUS)"
  if [ $OWNER_DETECT_ATTEMPT -lt $OWNER_DETECT_MAX ]; then
    SLEEP_SECONDS=$(( OWNER_DETECT_BACKOFF * (2 ** (OWNER_DETECT_ATTEMPT - 1)) ))
    echo "Retrying after ${SLEEP_SECONDS}s..."
    sleep $SLEEP_SECONDS
  fi
  OWNER_DETECT_ATTEMPT=$((OWNER_DETECT_ATTEMPT + 1))
done

if [ -n "${OWNER_INFO:-}" ]; then
  # Protect jq: if parsing fails, fallback to 'User'
  OWNER_TYPE=$(echo "$OWNER_INFO" | jq -r '.type // "User"' 2>/dev/null || echo "User")
else
  echo "Warning: could not determine owner info after ${OWNER_DETECT_MAX} attempts (HTTP status: $OWNER_HTTP_STATUS). Defaulting owner type to 'User'."
  OWNER_TYPE="User"
fi

echo "Repository owner: $REPOSITORY_OWNER (type: $OWNER_TYPE)"

if [ "$OWNER_TYPE" = "Organization" ]; then
  API_URL="https://api.github.com/orgs/$REPOSITORY_OWNER/packages/composer/$ENCODED_NAME/versions"
else
  API_URL="https://api.github.com/user/packages/composer/$ENCODED_NAME/versions"
fi

echo "GitHub Packages API URL: $API_URL"

# Retry loop
ATTEMPT=1
MAX_RETRIES=${RETRIES_INPUT:-3}
BACKOFF=${BACKOFF_INPUT:-5}

while true; do
  echo "Attempt #$ATTEMPT to upload package"
  HTTP_STATUS=$(curl -s -o /tmp/ghpkg_resp.txt -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -F "metadata=@/tmp/metadata.json;type=application/json" \
    -F "package=@$ZIP_FILE;type=application/zip" \
    "$API_URL")

  echo "GitHub Packages response (status $HTTP_STATUS):"
  cat /tmp/ghpkg_resp.txt || true

  if [ "$HTTP_STATUS" -lt 400 ]; then
    echo "Published $PACKAGE_NAME@$PACKAGE_VERSION to GitHub Packages successfully."
    break
  fi

  if { [ "$HTTP_STATUS" -eq 429 ] || [ "$HTTP_STATUS" -ge 500 ]; } && [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
    SLEEP_SECONDS=$(( BACKOFF * (2 ** (ATTEMPT - 1)) ))
    echo "Transient error (status $HTTP_STATUS). Retrying after ${SLEEP_SECONDS}s..."
    sleep $SLEEP_SECONDS
    ATTEMPT=$((ATTEMPT + 1))
    continue
  fi

  echo "Publish to GitHub Packages failed with HTTP status $HTTP_STATUS" >&2
  exit 1
done

