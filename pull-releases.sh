#!/usr/bin/env bash
#
# pull-releases.sh — fetch the latest release artifacts for all capp projects.
#
# For each project this resolves the latest GitHub release tag, then pulls
# and saves its Docker image(s), Helm chart(s), release notes, and source code
# tarball. It also pulls the cappctl image and downloads the cappctl CLI
# binaries (both published as part of the capp-backend release). Finally, the
# whole output directory is packed into a single zip file next to it
# (<output-dir>.zip).
#
# Usage:
#   ./pull-releases.sh [-o|--output-dir DIR]
#
# Requires: curl, docker, helm, jq, zip
#
# Uses the unauthenticated GitHub REST API (60 req/hr limit). Set GITHUB_TOKEN
# to raise that limit if needed.

set -euo pipefail

OUTPUT_DIR="./capp-releases"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-o|--output-dir DIR]

Pulls the latest Docker images, Helm charts, release notes, source code
tarballs, and cappctl CLI binaries for all capp projects (capp-backend,
capp-mcp, cappctl, capp-frontend, container-app-operator, capp-monitoring),
then packs everything into a single zip file (<output-dir>.zip).

Options:
  -o, --output-dir DIR   Directory to save artifacts into (default: ./capp-releases)
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

for cmd in curl docker helm jq zip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

GHCR_REGISTRY="ghcr.io/dana-team"
HELM_REGISTRY="oci://ghcr.io/dana-team/helm-charts"
GITHUB_ORG="dana-team"

IMAGES_DIR="$OUTPUT_DIR/images"
HELM_DIR="$OUTPUT_DIR/helm"
CAPPCTL_DIR="$OUTPUT_DIR/cappctl"
NOTES_DIR="$OUTPUT_DIR/release-notes"
SOURCE_DIR="$OUTPUT_DIR/source"
VERSIONS_FILE="$OUTPUT_DIR/versions.txt"

mkdir -p "$IMAGES_DIR" "$HELM_DIR" "$CAPPCTL_DIR" "$NOTES_DIR" "$SOURCE_DIR"
: > "$VERSIONS_FILE"

log() {
  echo ">> $*"
}

# github_api <path> — GET https://api.github.com/<path>, using GITHUB_TOKEN if set
github_api() {
  local path="$1"
  local auth_header=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL "${auth_header[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/${path}"
}

# latest_tag <repo> — prints the latest release tag_name for dana-team/<repo>
latest_tag() {
  local repo="$1"
  local tag
  tag=$(github_api "repos/${GITHUB_ORG}/${repo}/releases/latest" | jq -r '.tag_name // empty')
  if [[ -z "$tag" ]]; then
    echo "Error: could not resolve latest release tag for ${GITHUB_ORG}/${repo}" >&2
    exit 1
  fi
  echo "$tag"
}

# pull_image <image_ref> <name> <tag> — docker pull + save to a tar
pull_image() {
  local image_ref="$1" name="$2" tag="$3"
  log "Pulling image ${image_ref}"
  docker pull "$image_ref"
  local out="${IMAGES_DIR}/${name}-${tag}.tar"
  log "Saving image to ${out}"
  docker save "$image_ref" -o "$out"
}

# pull_chart <chart_name> <tag> — helm pull an OCI chart into HELM_DIR
pull_chart() {
  local chart_name="$1" tag="$2"
  log "Pulling helm chart ${chart_name} (${tag})"
  helm pull "${HELM_REGISTRY}/${chart_name}" --version "$tag" -d "$HELM_DIR"
}

# pull_release_notes <repo> <tag> — save the release notes of dana-team/<repo>@<tag> as markdown
pull_release_notes() {
  local repo="$1" tag="$2"
  local out="${NOTES_DIR}/${repo}-${tag}.md"
  log "Saving ${repo} ${tag} release notes to ${out}"
  github_api "repos/${GITHUB_ORG}/${repo}/releases/tags/${tag}" | jq -r '
    "# \(.name // .tag_name)\n\n" +
    "- Tag: \(.tag_name)\n" +
    "- Published: \(.published_at)\n" +
    "- URL: \(.html_url)\n\n" +
    (if (.body // "") == "" then "_No release notes provided._" else .body end)
  ' > "$out"
}

# pull_source <repo> <tag> — download the source tarball of dana-team/<repo>@<tag>
pull_source() {
  local repo="$1" tag="$2"
  local out="${SOURCE_DIR}/${repo}-${tag}.tar.gz"
  log "Saving ${repo} ${tag} source code to ${out}"
  curl -fsSL -o "$out" "https://github.com/${GITHUB_ORG}/${repo}/archive/refs/tags/${tag}.tar.gz"
}

record_version() {
  echo "$1: $2" >> "$VERSIONS_FILE"
}

# ── capp-backend + capp-mcp + cappctl ────────────────────────────────────────
log "Resolving capp-backend latest release..."
BACKEND_TAG=$(latest_tag "capp-backend")
record_version "capp-backend" "$BACKEND_TAG"
log "Latest capp-backend release: ${BACKEND_TAG}"
pull_release_notes "capp-backend" "$BACKEND_TAG"
pull_source "capp-backend" "$BACKEND_TAG"

pull_image "${GHCR_REGISTRY}/capp-backend:${BACKEND_TAG}" "capp-backend" "$BACKEND_TAG"
pull_chart "capp-backend" "$BACKEND_TAG"

pull_image "${GHCR_REGISTRY}/capp-mcp:${BACKEND_TAG}" "capp-mcp" "$BACKEND_TAG"
pull_chart "capp-mcp" "$BACKEND_TAG"

pull_image "${GHCR_REGISTRY}/cappctl:${BACKEND_TAG}" "cappctl" "$BACKEND_TAG"

log "Downloading cappctl CLI binaries (${BACKEND_TAG})..."
CAPPCTL_BASE_URL="https://github.com/${GITHUB_ORG}/capp-backend/releases/download/${BACKEND_TAG}"
curl -fsSL -o "${CAPPCTL_DIR}/cappctl-linux-amd64" "${CAPPCTL_BASE_URL}/cappctl-linux-amd64"
chmod +x "${CAPPCTL_DIR}/cappctl-linux-amd64"
curl -fsSL -o "${CAPPCTL_DIR}/cappctl-windows-amd64.exe" "${CAPPCTL_BASE_URL}/cappctl-windows-amd64.exe"

# ── capp-frontend ─────────────────────────────────────────────────────────────
log "Resolving capp-frontend latest release..."
FRONTEND_TAG=$(latest_tag "capp-frontend")
record_version "capp-frontend" "$FRONTEND_TAG"
log "Latest capp-frontend release: ${FRONTEND_TAG}"
pull_release_notes "capp-frontend" "$FRONTEND_TAG"
pull_source "capp-frontend" "$FRONTEND_TAG"

pull_image "${GHCR_REGISTRY}/capp-frontend:${FRONTEND_TAG}" "capp-frontend" "$FRONTEND_TAG"
pull_chart "capp-frontend" "$FRONTEND_TAG"

# ── container-app-operator ───────────────────────────────────────────────────
log "Resolving container-app-operator latest release..."
OPERATOR_TAG=$(latest_tag "container-app-operator")
record_version "container-app-operator" "$OPERATOR_TAG"
log "Latest container-app-operator release: ${OPERATOR_TAG}"
pull_release_notes "container-app-operator" "$OPERATOR_TAG"
pull_source "container-app-operator" "$OPERATOR_TAG"

pull_image "${GHCR_REGISTRY}/container-app-operator:${OPERATOR_TAG}" "container-app-operator" "$OPERATOR_TAG"
pull_chart "container-app-operator" "$OPERATOR_TAG"

# ── capp-monitoring ───────────────────────────────────────────────────────────
log "Resolving capp-monitoring latest release..."
MONITORING_TAG=$(latest_tag "capp-monitoring")
record_version "capp-monitoring" "$MONITORING_TAG"
log "Latest capp-monitoring release: ${MONITORING_TAG}"
pull_release_notes "capp-monitoring" "$MONITORING_TAG"
pull_source "capp-monitoring" "$MONITORING_TAG"

pull_image "${GHCR_REGISTRY}/capp-benchmark-runner:${MONITORING_TAG}" "capp-benchmark-runner" "$MONITORING_TAG"
pull_chart "capp-monitoring" "$MONITORING_TAG"

# ── zip the whole release ────────────────────────────────────────────────────
# Strip trailing slashes so "dir/" zips as "dir.zip" rather than "dir/.zip".
RELEASE_DIR="${OUTPUT_DIR%/}"
RELEASE_PARENT="$(cd "$(dirname "$RELEASE_DIR")" && pwd)"
RELEASE_NAME="$(basename "$RELEASE_DIR")"
ZIP_FILE="${RELEASE_PARENT}/${RELEASE_NAME}.zip"

log "Zipping ${RELEASE_DIR} into ${ZIP_FILE}"
# Remove any previous zip so stale files from an older run don't linger in it.
rm -f "$ZIP_FILE"
# Zip from the parent dir so the archive has a single top-level folder.
(cd "$RELEASE_PARENT" && zip -r -q "$ZIP_FILE" "$RELEASE_NAME")

log "Done. Artifacts saved under ${OUTPUT_DIR}"
log "Release archive: ${ZIP_FILE}"
log "Resolved versions:"
cat "$VERSIONS_FILE"
