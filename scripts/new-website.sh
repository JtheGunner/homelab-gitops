#!/usr/bin/env bash
# Onboard a new website. Generates
#   <repo>/apps/base/webhosting/websites/<name>/{image,imagepolicy,release,kustomization}.yaml
# from templates/website/ and appends <name> to the websites kustomization.
#
#   scripts/new-website.sh <name> <repo-url> <host> <port> [owner]
#
# Target repo: $KCONFIG_ROOT (default: this repo, for the staging mirror).
# owner: 5th argument or $GHCR_OWNER.
set -euo pipefail

NAME="${1:?name missing}"
REPO_URL="${2:?repo-url missing}"
HOST="${3:?host missing}"
PORT="${4:?port missing}"
OWNER="${5:-${GHCR_OWNER:-}}"

TOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${KCONFIG_ROOT:-$TOOL_ROOT}"
TEMPLATE="$TOOL_ROOT/templates/website"
WEBSITES="$ROOT/apps/base/webhosting/websites"
DEST="$WEBSITES/$NAME"
KUST="$WEBSITES/kustomization.yaml"

case "$NAME" in *[!a-z0-9-]*) echo "ERROR: name may only contain [a-z0-9-]." >&2; exit 1 ;; esac
[ -n "$OWNER" ] || { echo "ERROR: owner missing (5th arg or \$GHCR_OWNER)." >&2; exit 1; }
# OCI image names must be lowercase.
OWNER="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
[ -d "$DEST" ] && { echo "ERROR: $DEST already exists." >&2; exit 1; }
[ -f "$KUST" ] || { echo "ERROR: $KUST not found (create the structure first)." >&2; exit 1; }

mkdir -p "$DEST"
for f in kustomization.yaml image.yaml imagepolicy.yaml release.yaml; do
  sed -e "s|__NAME__|$NAME|g" \
      -e "s|__OWNER__|$OWNER|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__REPO_URL__|$REPO_URL|g" \
      "$TEMPLATE/$f" > "$DEST/$f"
done

# Insert <name> into the websites kustomization (before the marker) unless already present.
if ! grep -qE "^[[:space:]]*-[[:space:]]+$NAME[[:space:]]*$" "$KUST"; then
  tmp="$(mktemp)"
  awk -v n="  - $NAME" '
    /# further websites/ && !done { print n; done=1 }
    { print }
  ' "$KUST" > "$tmp" && mv "$tmp" "$KUST"
fi

echo "✅ Website '$NAME' -> apps/base/webhosting/websites/$NAME  (ns: webhosting)"
echo "   Repo: $REPO_URL   Host: https://$HOST   Port: $PORT"
echo
echo "Next steps: review, commit, push -> kpack builds, Flux deploys."
