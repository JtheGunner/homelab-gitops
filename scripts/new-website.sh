#!/usr/bin/env bash
# Onboard a new website. Generates
#   <repo>/apps/base/webhosting/websites/<name>/{image,imagepolicy,release,kustomization}.yaml
# from templates/website/ and appends <name> to the websites kustomization.
#
#   scripts/new-website.sh <name> <repo-url> <host> <port> [owner] [db]
#
# Target repo: $KCONFIG_ROOT (default: this repo, for the staging mirror).
# owner: 5th argument or $GHCR_OWNER.
# db:    6th argument. Empty = no DB. "mariadb" (or "mysql") = bundle a MariaDB
#        StatefulSet + PVC + service into the website's HelmRelease.
set -euo pipefail

NAME="${1:?name missing}"
REPO_URL="${2:?repo-url missing}"
HOST="${3:?host missing}"
PORT="${4:?port missing}"
OWNER="${5:-${GHCR_OWNER:-}}"
DB="${6:-}"

TOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${KCONFIG_ROOT:-$TOOL_ROOT}"
TEMPLATE="$TOOL_ROOT/templates/website"
WEBSITES="$ROOT/apps/base/webhosting/websites"
DEST="$WEBSITES/$NAME"
KUST="$WEBSITES/kustomization.yaml"

case "$NAME" in *[!a-z0-9-]*) echo "ERROR: name may only contain [a-z0-9-]." >&2; exit 1 ;; esac
[ -n "$OWNER" ] || { echo "ERROR: owner missing (5th arg or \$GHCR_OWNER)." >&2; exit 1; }

# Optional bundled database. Only MariaDB is supported for now; "mysql" is an
# accepted alias (the mariadb image speaks the MySQL wire protocol).
WITH_DB=0
case "$(printf '%s' "$DB" | tr '[:upper:]' '[:lower:]')" in
  "")                WITH_DB=0 ;;
  mariadb|mysql|maria) WITH_DB=1 ;;
  *) echo "ERROR: unknown db '$DB' (use 'mariadb' or leave empty)." >&2; exit 1 ;;
esac
# OCI image names must be lowercase.
OWNER="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
[ -d "$DEST" ] && { echo "ERROR: $DEST already exists." >&2; exit 1; }
[ -f "$KUST" ] || { echo "ERROR: $KUST not found (create the structure first)." >&2; exit 1; }

# Files to render. With a DB we add the secret + patch and swap in the
# DB-aware kustomization (rendered below from kustomization-db.yaml).
FILES="image.yaml imagepolicy.yaml release.yaml"
DB_PASSWORD=""; DB_ROOT_PASSWORD=""
if [ "$WITH_DB" -eq 1 ]; then
  FILES="$FILES db-secret.yaml db-patch.yaml"
  gen_pw() { openssl rand -hex 24 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 48; }
  DB_PASSWORD="$(gen_pw)"
  DB_ROOT_PASSWORD="$(gen_pw)"
fi

render() {  # render <template-file> <dest-file>
  sed -e "s|__NAME__|$NAME|g" \
      -e "s|__OWNER__|$OWNER|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__REPO_URL__|$REPO_URL|g" \
      -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" \
      -e "s|__DB_ROOT_PASSWORD__|$DB_ROOT_PASSWORD|g" \
      "$TEMPLATE/$1" > "$DEST/$2"
}

mkdir -p "$DEST"
for f in $FILES; do render "$f" "$f"; done
# kustomization: DB variant lists the extra resource + patch; plain otherwise.
if [ "$WITH_DB" -eq 1 ]; then render kustomization-db.yaml kustomization.yaml
else render kustomization.yaml kustomization.yaml; fi

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
if [ "$WITH_DB" -eq 1 ]; then
  echo "   DB:   MariaDB bundled (service '$NAME-db:3306', PVC 5Gi, db/user '$NAME')"
  echo
  echo "⚠️  $DEST/db-secret.yaml holds PLAINTEXT passwords. Encrypt before committing:"
  echo "      sops --encrypt --in-place $DEST/db-secret.yaml"
fi
echo
echo "Next steps: review, commit, push -> kpack builds, Flux deploys."
