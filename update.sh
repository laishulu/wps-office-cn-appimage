#!/usr/bin/env bash
set -euo pipefail

# 1. Map required commands to their corresponding Nix package names
declare -A BIN_PKG_MAP=(
  [curl]="curl"
  [jq]="jq"
  [python3]="python3"
  [nix-hash]="nix"
)

REQUIRED_BINS=("${!BIN_PKG_MAP[@]}")
MISSING_PKGS=()

for bin in "${REQUIRED_BINS[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    pkg="${BIN_PKG_MAP[$bin]}"
    # Avoid adding duplicate packages
    if [[ ! " ${MISSING_PKGS[*]:-} " =~ [[:space:]]${pkg}[[:space:]] ]]; then
      MISSING_PKGS+=("$pkg")
    fi
  fi
done

# 2. Re-enter via nix-shell if dependencies are missing (guarded against recursive loops)
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  if [ "${IN_NIX_SHELL_UPDATER:-}" = "1" ]; then
    echo "Error: Still missing dependencies inside nix-shell: ${MISSING_PKGS[*]}" >&2
    exit 1
  fi

  echo "==> Missing dependencies: ${MISSING_PKGS[*]}"
  echo "==> Entering temporary nix-shell environment..."
  exec env IN_NIX_SHELL_UPDATER=1 nix-shell -p "${MISSING_PKGS[@]}" --run "$(printf '%q ' "$0" "$@")"
fi

NIX_FILE="${1:-flake.nix}"
VERSION_FILE="version.txt"

if [ ! -f "$NIX_FILE" ]; then
  echo "Error: Nix file not found: $NIX_FILE" >&2
  exit 1
fi

echo "==> 1. Fetching AUR PKGBUILD for wps-office-cn..."
AUR_DIR=$(mktemp -d)
trap 'rm -rf "$AUR_DIR"' EXIT

curl -sSL "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=wps-office-cn" -o "$AUR_DIR/PKGBUILD"

echo "==> 2. Parsing PKGBUILD variables..."
# Safely source variables in an isolated subshell
PARSED_VARS=$(bash -c '
  set -a
  source "'"$AUR_DIR/PKGBUILD"'" 2>/dev/null || true

  deb_url=""
  for item in "${source_x86_64[@]:-}" "${source[@]:-}"; do
    candidate="${item#*::}"
    if [[ "$candidate" =~ ^https?:// ]] && [[ "$candidate" == *.deb* || "$candidate" == *wps* ]]; then
      deb_url="$candidate"
      break
    fi
  done

  # Strip query parameters if present in the raw source URL
  deb_url="${deb_url%%\?*}"

  sha512="${sha512sums_x86_64[0]:-${sha512sums[0]:-}}"
  sha256="${sha256sums_x86_64[0]:-${sha256sums[0]:-}}"

  echo "PKGVER=${pkgver:-}"
  echo "DEB_URL=${deb_url:-}"
  echo "SHA512=${sha512:-}"
  echo "SHA256=${sha256:-}"
')

eval "$PARSED_VARS"

if [ -z "$DEB_URL" ] || [ -z "$PKGVER" ]; then
  echo "Error: Failed to parse package version or deb URL from AUR PKGBUILD." >&2
  exit 1
fi

echo "Version : $PKGVER"
echo "Base URL: $DEB_URL"

echo "==> 3. Updating version.txt..."
echo "$PKGVER" > "$VERSION_FILE"

echo "==> 4. Verifying CDN URL and calculating SRI hash..."
sign_wps_url() {
  local raw_url="$1"
  if [[ "$raw_url" =~ ^https://wps-linux-personal.wpscdn.cn ]]; then
    local security_key="7f8faaaa468174dc1c9cd62e5f218a5b"
    local uri="${raw_url#https://wps-linux-personal.wpscdn.cn}"
    local timestamp
    timestamp=$(date '+%s')
    local md5
    md5=$(printf '%s' "$security_key$uri$timestamp" | md5sum | cut -d' ' -f1)
    echo "${raw_url}?t=${timestamp}&k=${md5}"
  else
    echo "$raw_url"
  fi
}

SIGNED_URL=$(sign_wps_url "$DEB_URL")

# Validate that the link is accessible (HTTP 200/302)
HTTP_STATUS=$(curl -sSL -o /dev/null -w "%{http_code}" "$SIGNED_URL" || true)
if [ "$HTTP_STATUS" != "200" ] && [ "$HTTP_STATUS" != "302" ]; then
  echo "Error: Signed CDN URL returned HTTP status $HTTP_STATUS ($SIGNED_URL)" >&2
  exit 1
fi

# Convert hex checksum from PKGBUILD to Nix SRI, or prefetch if absent
if [[ "${SHA512:-}" =~ ^[a-fA-F0-9]{128}$ ]]; then
  DEB_HASH=$(nix-hash --type sha512 --to-sri "$SHA512")
elif [[ "${SHA256:-}" =~ ^[a-fA-F0-9]{64}$ ]]; then
  DEB_HASH=$(nix-hash --type sha256 --to-sri "$SHA256")
else
  echo "Checksum not found in PKGBUILD, prefetching..."
  RAW_SHA256=$(nix-prefetch-url --type sha256 "$SIGNED_URL")
  DEB_HASH=$(nix-hash --type sha256 --to-sri "$RAW_SHA256")
fi

echo "SRI Hash: $DEB_HASH"

echo "==> 5. Updating $NIX_FILE..."
python3 -c "
import re

with open('$NIX_FILE', 'r') as f:
    content = f.read()

content = re.sub(
    r'(wpsConfig\s*=\s*\{[\s\S]*?version\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$PKGVER\2',
    content
)

content = re.sub(
    r'(wpsConfig\s*=\s*\{[\s\S]*?url\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$DEB_URL\2',
    content
)

content = re.sub(
    r'(wpsConfig\s*=\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$DEB_HASH\2',
    content
)

with open('$NIX_FILE', 'w') as f:
    f.write(content)
"

echo "==> 6. Updating latest.txt..."
date -u -Iseconds > latest.txt

echo "==> Successfully updated $NIX_FILE!"
