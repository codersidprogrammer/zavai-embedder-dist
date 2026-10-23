#!/usr/bin/env bash
# zavai-embedder installer for Debian 12+ (amd64).
#
# Installs the packaged build, writes /etc/zavai-embedder/embedder.env, checks
# the PostgreSQL host (16 + pgvector) and applies the embedder's migrations.
# It never provisions PostgreSQL: point it at an existing server.
#
#   sudo ./install.sh --deb ./zavai-embedder_0.1.0~dev..._amd64.deb \
#        --models-deb ./zavai-embedder-models_0.1.0~dev..._all.deb
#
#   sudo zavai-embedder-install --reconfigure
#   sudo zavai-embedder-install --uninstall
#
# Secrets are read from flags, the process environment, or interactive prompts;
# they are never echoed and never passed on a command line by this script.
set -euo pipefail

PROGRAM="zavai-embedder-install"
# Artifacts are published to a public repository that holds no source. The
# build repository stays private; override with --repo for a private mirror.
DIST_REPO="${ZAVAI_DIST_REPO:-codersidprogrammer/zavai-embedder-dist}"
REPO="${ZAVAI_GITHUB_REPO:-$DIST_REPO}"
PREFIX=/opt/zavai-embedder
SHARE=/usr/lib/zavai-embedder
ETC=/etc/zavai-embedder
ENV_FILE="$ETC/embedder.env"
STATE=/var/lib/zavai-embedder
PY="$PREFIX/python/bin/python3"
LAUNCHER=/usr/bin/zavai-embedder

MODE=install
DEB="" MODELS_DEB="" TARBALL="" RELEASE_TAG="" TOKEN="${GITHUB_TOKEN:-}"
NON_INTERACTIVE=0 DRY_RUN=0 SKIP_MIGRATE=0 WITH_CUDA=0 ENABLE_TIMER=0
FORCE=0 ASSUME_YES=0
ENV_MODE="" SKIP_MODELS=0

# Values start from the process environment so `sudo DATABASE_URL=... ./install.sh`
# works without putting a secret on the command line. Flags override them.
DB_URL="${DATABASE_URL:-}"
LLM_BASE="${LLM_BASE_URL:-}"
LLM_KEY="${LLM_API_KEY:-}"
LLM_MODEL="${LLM_EMBED_MODEL:-}"
LLM_DIM="${LLM_EMBED_DIM:-}"
COLLECTION="${VECTOR_COLLECTION:-}"
SP_TENANT="${SHAREPOINT_TENANT_ID:-}"
SP_CLIENT="${SHAREPOINT_CLIENT_ID:-}"
SP_SECRET="${SHAREPOINT_CLIENT_SECRET:-}"
SP_DOMAIN="${SHAREPOINT_DOMAIN:-}"
SP_SITE="${SHAREPOINT_SITE:-}"
SP_DRIVES="${SHAREPOINT_DRIVES:-}"
ENV_MODE="${ZAVAI_ENV:-}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-}"

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   warning: %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
zavai-embedder installer for Debian 12+ (amd64).

Installs the packaged build, writes /etc/zavai-embedder/embedder.env, checks the
PostgreSQL host (16 + pgvector) and applies the embedder's migrations. It never
provisions PostgreSQL: point it at an existing server.

  sudo ./install.sh --deb ./zavai-embedder_<version>_amd64.deb \
       --models-deb ./zavai-embedder-models_<version>_all.deb

  sudo zavai-embedder-install --reconfigure
  sudo zavai-embedder-install --uninstall

Options:
  --deb PATH                 runtime .deb to install
  --models-deb PATH          offline Docling weights .deb (recommended)
  --tarball PATH             portable tree instead of .deb (non-dpkg hosts)
  --release TAG              download a published release (default: newest dev build)
  --token TOKEN              GitHub token (only for a private mirror)
  --repo OWNER/REPO          override the distribution repository
                             (default: codersidprogrammer/zavai-embedder-dist)
  --reconfigure              rewrite configuration and migrate; install nothing
  --uninstall                remove the packages, keep corpus data and config

  --database-url URL         DATABASE_URL (postgresql+psycopg://...)
  --llm-base-url URL         LLM_BASE_URL (OpenAI-compatible base, no /v1)
  --llm-api-key KEY          LLM_API_KEY
  --llm-embed-model NAME     LLM_EMBED_MODEL (default text-embedding-3-large)
  --llm-embed-dim N          LLM_EMBED_DIM (default 2000, must match the runner)
  --vector-collection NAME   VECTOR_COLLECTION (default main)
  --sharepoint-tenant-id ID  SHAREPOINT_TENANT_ID
  --sharepoint-client-id ID  SHAREPOINT_CLIENT_ID
  --sharepoint-client-secret SECRET
  --sharepoint-domain HOST   SHAREPOINT_DOMAIN
  --sharepoint-site PATH     SHAREPOINT_SITE   (e.g. /sites/Procedures)
  --sharepoint-drives CSV    SHAREPOINT_DRIVES (exact drive names)
  --env-mode MODE            production (default) or development
  --artifact-root PATH       stage artifacts (default /var/lib/zavai-embedder/artifacts)

  --with-cuda                replace CPU PyTorch with a CUDA build for OCR
  --enable-timer             install and start the daily sync timer
  --non-interactive          never prompt; fail on missing values
  --skip-migrate             do not run `zavai-embedder migrate`
  --skip-models              do not install the models package
  --force                    overwrite an existing configuration file
  --yes                      accept confirmations
  --dry-run                  print the plan; change nothing
  -h, --help                 this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --deb) DEB="${2:?}"; shift 2 ;;
        --models-deb) MODELS_DEB="${2:?}"; shift 2 ;;
        --tarball) TARBALL="${2:?}"; shift 2 ;;
        --release) RELEASE_TAG="${2:?}"; shift 2 ;;
        --token) TOKEN="${2:?}"; shift 2 ;;
        --repo) REPO="${2:?}"; shift 2 ;;
        --reconfigure) MODE=reconfigure; shift ;;
        --uninstall) MODE=uninstall; shift ;;
        --database-url) DB_URL="${2:?}"; shift 2 ;;
        --llm-base-url) LLM_BASE="${2:?}"; shift 2 ;;
        --llm-api-key) LLM_KEY="${2:?}"; shift 2 ;;
        --llm-embed-model) LLM_MODEL="${2:?}"; shift 2 ;;
        --llm-embed-dim) LLM_DIM="${2:?}"; shift 2 ;;
        --vector-collection) COLLECTION="${2:?}"; shift 2 ;;
        --sharepoint-tenant-id) SP_TENANT="${2:?}"; shift 2 ;;
        --sharepoint-client-id) SP_CLIENT="${2:?}"; shift 2 ;;
        --sharepoint-client-secret) SP_SECRET="${2:?}"; shift 2 ;;
        --sharepoint-domain) SP_DOMAIN="${2:?}"; shift 2 ;;
        --sharepoint-site) SP_SITE="${2:?}"; shift 2 ;;
        --sharepoint-drives) SP_DRIVES="${2:?}"; shift 2 ;;
        --env-mode) ENV_MODE="${2:?}"; shift 2 ;;
        --artifact-root) ARTIFACT_ROOT="${2:?}"; shift 2 ;;
        --with-cuda) WITH_CUDA=1; shift ;;
        --enable-timer) ENABLE_TIMER=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --skip-migrate) SKIP_MIGRATE=1; shift ;;
        --skip-models) SKIP_MODELS=1; shift ;;
        --force) FORCE=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    [ "$NON_INTERACTIVE" = "1" ] && return 1
    local answer
    read -r -p "   $1 [y/N] " answer || true
    case "${answer:-n}" in [yY]*) return 0 ;; *) return 1 ;; esac
}

ask() {
    # ask <variable> <prompt> <default> [secret]
    # In interactive mode the current value (flag or environment) is the
    # default, so Enter keeps it; secrets are never echoed.
    local __var="$1" __prompt="$2" __default="$3" __secret="${4:-}"
    local __current="${!__var}"
    if [ -n "$__current" ]; then
        __default="$__current"
    fi

    if [ "$NON_INTERACTIVE" = "1" ]; then
        [ -n "$__default" ] || die "$__prompt is required with --non-interactive"
        printf -v "$__var" '%s' "$__default"
        return 0
    fi

    local __input=""
    if [ "$__secret" = "secret" ]; then
        if [ -n "$__default" ]; then
            read -r -s -p "   $__prompt [keep current]: " __input || true
        else
            read -r -s -p "   $__prompt: " __input || true
        fi
        printf '\n'
    elif [ -n "$__default" ]; then
        read -r -p "   $__prompt [$__default]: " __input || true
    else
        read -r -p "   $__prompt: " __input || true
    fi
    if [ -z "$__input" ]; then
        __input="$__default"
    fi
    [ -n "$__input" ] || die "$__prompt is required"
    printf -v "$__var" '%s' "$__input"
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" = "0" ] || die "run as root (sudo $PROGRAM ...)"
}

check_platform() {
    [ "$(uname -s)" = "Linux" ] || die "this installer targets Debian Linux"
    [ "$(uname -m)" = "x86_64" ] || die "packages are built for x86_64 only"
    if [ -r /etc/debian_version ]; then
        local major
        major="$(cut -d. -f1 /etc/debian_version 2>/dev/null || echo 0)"
        case "$major" in ''|*[!0-9]*) major=0 ;; esac
        if [ "$major" -lt 12 ]; then
            warn "Debian $major detected; packages are built for Debian 12+ (glibc 2.36)"
        fi
    else
        warn "not a Debian host; continuing, but only Debian 12+ is supported"
    fi
}

check_disk() {
    local needed_mb=3500
    [ "$SKIP_MODELS" = "1" ] && needed_mb=2500
    [ "$WITH_CUDA" = "1" ] && needed_mb=$((needed_mb + 3500))
    local avail
    avail="$(df -Pm /opt 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "${avail:-}" ] && [ "$avail" -lt "$needed_mb" ]; then
        warn "only ${avail} MiB free on /opt; about ${needed_mb} MiB is needed"
    fi
}

# ---------------------------------------------------------------------------
# Release download
# ---------------------------------------------------------------------------
curl_release() {
    # curl_release <output> <url>; adds the token only for a private repository.
    local out="$1" url="$2"
    if [ -n "$TOKEN" ]; then
        curl -fsSL --retry 3 -H "Authorization: Bearer ${TOKEN}" -o "$out" "$url"
    else
        curl -fsSL --retry 3 -o "$out" "$url"
    fi
}

asset_id() {
    # asset_id <release-json> <asset-name>; prints the numeric asset id.
    # The API asset URL is the only download that works for a private repo:
    # GitHub answers 404 on the browser download URL even with a token.
    awk -v want="$2" '
        /"url": *".*\/releases\/assets\/[0-9]+"/ {
            line = $0
            sub(/.*\/releases\/assets\//, "", line)
            sub(/".*/, "", line)
            id = line
        }
        index($0, "\"name\": \"" want "\"") { if (id != "") { print id; exit } }
    ' "$1"
}

fetch_asset() {
    # fetch_asset <asset-id> <output>; follows the redirect to storage.
    local id="$1" out="$2"
    if [ -n "$TOKEN" ]; then
        curl -fsSL --retry 3 -H "Authorization: Bearer ${TOKEN}" \
            -H "Accept: application/octet-stream" -o "$out" \
            "https://api.github.com/repos/${REPO}/releases/assets/${id}"
    else
        curl -fsSL --retry 3 -H "Accept: application/octet-stream" -o "$out" \
            "https://api.github.com/repos/${REPO}/releases/assets/${id}"
    fi
}

fetch_public_asset() {
    # fetch_public_asset <tag> <name> <output>: browser URL, no token needed.
    # Only public repositories serve it anonymously; private ones answer 404.
    curl -fsSL --retry 3 -o "$3" \
        "https://github.com/${REPO}/releases/download/${1}/$(printf '%s' "$2" | sed 's/ /%20/g')"
}

download_release() {
    local tag="$RELEASE_TAG" json version asset_version dir asset id
    json="/tmp/.zavai-release.json"
    if [ -z "$tag" ]; then
        # /releases/latest excludes prereleases, so list instead and take one.
        curl_release "$json" \
            "https://api.github.com/repos/${REPO}/releases?per_page=1" \
            || die "cannot list releases for ${REPO}"
        tag="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$json" | head -n1)"
        [ -n "$tag" ] || die "no releases found in ${REPO}"
    else
        curl_release "$json" \
            "https://api.github.com/repos/${REPO}/releases/tags/${tag}" \
            || die "cannot read release ${tag} from ${REPO}"
    fi
    dir="/tmp/zavai-release-${tag}"
    rm -rf "$dir"
    mkdir -p "$dir"
    say "Downloading ${REPO} ${tag}"

    # The manifest names the exact asset files, so the tag scheme never leaks
    # into the Debian version.
    id="$(asset_id "$json" release-manifest.json)"
    [ -n "$id" ] || die "release ${tag} has no release-manifest.json"
    if ! fetch_asset "$id" "$dir/release-manifest.json"; then
        fetch_public_asset "$tag" release-manifest.json "$dir/release-manifest.json" \
            || die "release ${tag} has no release-manifest.json"
    fi
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$dir/release-manifest.json" | head -n1)"
    [ -n "$version" ] || die "release manifest is malformed"
    # GitHub rewrites "~" in release asset names; the manifest records the
    # safe form used for the files (older builds only had "version").
    asset_version="$(sed -n 's/.*"asset_version": *"\([^"]*\)".*/\1/p' "$dir/release-manifest.json" | head -n1)"
    [ -n "$asset_version" ] || asset_version="$version"

    for asset in \
        "zavai-embedder_${asset_version}_amd64.deb" \
        "zavai-embedder-models_${asset_version}_all.deb" \
        "SHA256SUMS"; do
        if [ "$SKIP_MODELS" = "1" ] && [ "${asset#zavai-embedder-models}" != "$asset" ]; then
            continue
        fi
        id="$(asset_id "$json" "$asset")"
        if [ -z "$id" ]; then
            case "$asset" in
                *-models_*) warn "this release has no models package" ;;
                SHA256SUMS) warn "no checksums published" ;;
                *) die "release ${tag} has no ${asset}" ;;
            esac
            continue
        fi
        if ! fetch_asset "$id" "$dir/$asset"; then
            # The API can be rate-limited on a shared address; a public
            # repository also serves the asset over the browser URL.
            fetch_public_asset "$tag" "$asset" "$dir/$asset" \
                || die "download failed: ${asset}"
        fi
    done

    DEB="$dir/zavai-embedder_${asset_version}_amd64.deb"
    if [ -f "$dir/zavai-embedder-models_${asset_version}_all.deb" ]; then
        MODELS_DEB="$dir/zavai-embedder-models_${asset_version}_all.deb"
    fi
    [ -f "$DEB" ] || die "download failed: ${DEB} is missing"
    if [ -f "$dir/SHA256SUMS" ]; then
        # The sums also cover the tarball and install.sh, which this path does
        # not fetch; verify only what is present.
        (cd "$dir" && sha256sum -c --ignore-missing SHA256SUMS) \
            || die "checksum verification failed"
    fi
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
install_deb() {
    local deb="$1"
    [ -f "$deb" ] || die "package not found: $deb"
    say "Installing $(basename "$deb")"
    if [ "$DRY_RUN" = "1" ]; then
        run dpkg -i "$deb"
        return 0
    fi
    if ! dpkg -i "$deb" >/dev/null; then
        note "resolving dependencies with apt-get"
        apt-get update -qq || true
        apt-get -f install -y >/dev/null
        dpkg -i "$deb" >/dev/null || die "dpkg failed for $deb"
    fi
}

install_tarball() {
    local tar="$1"
    [ -f "$tar" ] || die "archive not found: $tar"
    say "Extracting $(basename "$tar") into /"
    # Keep an existing /etc/zavai-embedder/embedder.env: the template must not
    # overwrite a configured host on an upgrade.
    run tar -xzf "$tar" -C / --exclude='./etc/*'
    run install -d -o root -g zavai -m 0750 "$ETC"
    if [ ! -f "$ENV_FILE" ]; then
        run tar -xzf "$tar" -C / './etc'
    fi
    # The tarball has no maintainer scripts; create what postinst would.
    if ! getent group zavai >/dev/null 2>&1; then
        run addgroup --system zavai
    fi
    if ! getent passwd zavai >/dev/null 2>&1; then
        run adduser --system --ingroup zavai --home "$STATE" --no-create-home \
            --shell /usr/sbin/nologin zavai
    fi
    run install -d -o zavai -g zavai -m 0750 "$STATE" "$STATE/artifacts" "$STATE/logs"
    run install -d -o root -g zavai -m 0750 "$ETC"
}

install_cuda() {
    say "Installing the CUDA PyTorch build (OCR acceleration only)"
    [ "$DRY_RUN" = "1" ] && return 0
    local torch_version torchvision_version
    torch_version="$("$PY" -c 'import torch; print(torch.__version__.split("+")[0])')"
    torchvision_version="$("$PY" -c 'import torchvision; print(torchvision.__version__.split("+")[0])')"
    note "matching torch ${torch_version}, torchvision ${torchvision_version}"
    if ! "$PY" -m pip install --no-cache-dir --force-reinstall \
        --index-url https://download.pytorch.org/whl/cu126 \
        --extra-index-url https://pypi.org/simple \
        "torch==${torch_version}" "torchvision==${torchvision_version}"; then
        warn "CUDA wheels are unavailable for this torch version; keeping the CPU build"
        return 1
    fi
    if "$PY" -c 'import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)'; then
        note "CUDA is available: Docling OCR will use the GPU"
    else
        warn "torch.cuda.is_available() is false; check the driver (nvidia-smi)"
    fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
read_existing() {
    [ -f "$ENV_FILE" ] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in ''|\#*) continue ;; esac
        value="${value%\'}"; value="${value#\'}"
        value="${value%\"}"; value="${value#\"}"
        case "$key" in
            DATABASE_URL) DB_URL="${DB_URL:-$value}" ;;
            LLM_BASE_URL) LLM_BASE="${LLM_BASE:-$value}" ;;
            LLM_API_KEY) LLM_KEY="${LLM_KEY:-$value}" ;;
            LLM_EMBED_MODEL) LLM_MODEL="${LLM_MODEL:-$value}" ;;
            LLM_EMBED_DIM) LLM_DIM="${LLM_DIM:-$value}" ;;
            VECTOR_COLLECTION) COLLECTION="${COLLECTION:-$value}" ;;
            ZAVAI_ENV) ENV_MODE="${ENV_MODE:-$value}" ;;
            SHAREPOINT_TENANT_ID) SP_TENANT="${SP_TENANT:-$value}" ;;
            SHAREPOINT_CLIENT_ID) SP_CLIENT="${SP_CLIENT:-$value}" ;;
            SHAREPOINT_CLIENT_SECRET) SP_SECRET="${SP_SECRET:-$value}" ;;
            SHAREPOINT_DOMAIN) SP_DOMAIN="${SP_DOMAIN:-$value}" ;;
            SHAREPOINT_SITE) SP_SITE="${SP_SITE:-$value}" ;;
            SHAREPOINT_DRIVES) SP_DRIVES="${SP_DRIVES:-$value}" ;;
            ARTIFACT_ROOT) ARTIFACT_ROOT="${ARTIFACT_ROOT:-$value}" ;;
        esac
    done <"$ENV_FILE"
}

normalize_database_url() {
    case "$DB_URL" in
        postgresql+psycopg://*) ;;
        postgresql://*) DB_URL="postgresql+psycopg://${DB_URL#postgresql://}" ;;
        postgres://*) DB_URL="postgresql+psycopg://${DB_URL#postgres://}" ;;
        *) die "DATABASE_URL must start with postgresql+psycopg://" ;;
    esac
}

collect_config() {
    read_existing
    if [ "$DRY_RUN" = "1" ] && [ "$NON_INTERACTIVE" != "1" ]; then
        note "[dry-run] would prompt for the database, provider and SharePoint values"
        return 0
    fi
    ENV_MODE="${ENV_MODE:-production}"
    LLM_MODEL="${LLM_MODEL:-text-embedding-3-large}"
    LLM_DIM="${LLM_DIM:-2000}"
    COLLECTION="${COLLECTION:-main}"
    ARTIFACT_ROOT="${ARTIFACT_ROOT:-$STATE/artifacts}"

    say "Configuration"
    if [ "$NON_INTERACTIVE" = "0" ]; then
        note "Enter the existing PostgreSQL credentials (nothing is provisioned)."
    fi
    ask DB_URL "PostgreSQL URL (postgresql+psycopg://user:pass@host:5432/db)" "$DB_URL" secret
    [ -n "$DB_URL" ] || die "a PostgreSQL URL is required"
    normalize_database_url

    ask LLM_BASE "Embedding endpoint base URL" "${LLM_BASE:-http://localhost:11434}"
    ask LLM_KEY "Embedding API key" "${LLM_KEY:-}" secret
    ask LLM_MODEL "Embedding model" "$LLM_MODEL"
    ask LLM_DIM "Embedding dimensions (must match the runner)" "$LLM_DIM"
    ask COLLECTION "Vector collection" "$COLLECTION"

    ask SP_TENANT "SharePoint tenant id" "${SP_TENANT:-}" 
    ask SP_CLIENT "SharePoint app (client) id" "${SP_CLIENT:-}"
    ask SP_SECRET "SharePoint client secret" "${SP_SECRET:-}" secret
    ask SP_DOMAIN "SharePoint domain" "${SP_DOMAIN:-tenant.sharepoint.com}"
    ask SP_SITE "SharePoint site path" "${SP_SITE:-/sites/Procedures}"
    ask SP_DRIVES "SharePoint drive names (comma separated)" "${SP_DRIVES:-}"

    ENV_MODE="$(printf '%s' "$ENV_MODE" | tr '[:upper:]' '[:lower:]')"
    case "$ENV_MODE" in
        production|development) ;;
        *) die "--env-mode must be production or development" ;;
    esac
    if [ "$LLM_DIM" != "2000" ]; then
        warn "LLM_EMBED_DIM=$LLM_DIM differs from the runner default 2000;"
        warn "the runner must be configured to the same dimension or retrieval breaks"
    fi
}

write_config() {
    say "Writing ${ENV_FILE}"
    local tmp
    tmp="$(mktemp)"
    chmod 0600 "$tmp"
    {
        cat <<EOF
# zavai-embedder configuration. Generated by ${PROGRAM} on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Never world-readable: it carries the database password and app secrets.
ZAVAI_ENV=$(shell_quote "$ENV_MODE")
DATABASE_URL=$(shell_quote "$DB_URL")
VECTOR_COLLECTION=$(shell_quote "$COLLECTION")
LLM_BASE_URL=$(shell_quote "$LLM_BASE")
LLM_API_KEY=$(shell_quote "$LLM_KEY")
LLM_EMBED_MODEL=$(shell_quote "$LLM_MODEL")
LLM_EMBED_DIM=$(shell_quote "$LLM_DIM")
SHAREPOINT_TENANT_ID=$(shell_quote "$SP_TENANT")
SHAREPOINT_CLIENT_ID=$(shell_quote "$SP_CLIENT")
SHAREPOINT_CLIENT_SECRET=$(shell_quote "$SP_SECRET")
SHAREPOINT_DOMAIN=$(shell_quote "$SP_DOMAIN")
SHAREPOINT_SITE=$(shell_quote "$SP_SITE")
SHAREPOINT_DRIVES=$(shell_quote "$SP_DRIVES")
SHAREPOINT_INCLUDE='*.pdf'
SHAREPOINT_EXCLUDE_GLOBS='**/~\$*,**/Archive/**'
INGEST_MAX_PDF_MB=150
INGEST_MAX_PAGES=1500
ARTIFACT_ROOT=$(shell_quote "$ARTIFACT_ROOT")
AUTO_ACTIVATE=true
OUTLINE_CAP=100
ALLOW_INCOMPLETE_OUTLINE=false
CHUNK_TARGET_TOKENS=400
CHUNK_SOFT_MAX_TOKENS=700
CHUNK_HARD_MAX_TOKENS=1000
CHUNK_OVERLAP_SENTENCES=0
QUARANTINE_MIN_TOKENS=20
QUARANTINE_MANGLED_RATIO=0.05
DUPLICATE_SIMILARITY=0.95
MAX_UNREADABLE_PAGE_FRACTION=0.25
EMBED_BATCH_SIZE=96
EMBED_CONCURRENCY=3
EMBED_TIMEOUT_SECONDS=60
EMBED_MAX_RETRIES=5
CONVERT_OCR_ENABLED=true
OCR_MIN_CONFIDENCE=0.5
LOG_LEVEL=INFO
RETENTION_RETIRED_DAYS=180
RETENTION_FAILED_DAYS=30
RETENTION_SOURCE_DAYS=30
RETENTION_RUNS_DAYS=365
EOF
    } >"$tmp"
    if [ "$DRY_RUN" = "1" ]; then
        rm -f "$tmp"
        note "[dry-run] would install ${ENV_FILE} (mode 0640 root:zavai)"
        return 0
    fi
    install -d -o root -g zavai -m 0750 "$ETC"
    install -o root -g zavai -m 0640 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
    install -d -o zavai -g zavai -m 0750 "$STATE" "$STATE/logs"
    install -d -o zavai -g zavai -m 0750 "$ARTIFACT_ROOT" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Database verification (uses the bundled interpreter and psycopg)
# ---------------------------------------------------------------------------
check_database() {
    say "Checking the PostgreSQL host"
    if [ "$DRY_RUN" = "1" ]; then
        note "[dry-run] would verify server version, pgvector and write access"
        return 0
    fi
    [ -x "$PY" ] || die "bundled interpreter missing at $PY"
    "$PY" - "$DB_URL" <<'PY'
import sys

from sqlalchemy import create_engine, text

url = sys.argv[1]
engine = create_engine(url, connect_args={"connect_timeout": 10})
try:
    with engine.connect() as conn:
        version_num = int(conn.execute(text("SHOW server_version_num")).scalar() or 0)
        if version_num < 160000:
            print(f"   error: PostgreSQL {version_num} found; version 16 or newer is required.")
            sys.exit(11)
        vector = conn.execute(
            text("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
        ).scalar()
        available = conn.execute(
            text("SELECT default_version FROM pg_available_extensions WHERE name = 'vector'")
        ).scalar()
        if vector is not None:
            print(f"   postgres {version_num // 10000}, pgvector {vector}")
        elif available is not None:
            # Migration 0003 runs CREATE EXTENSION; the server only has to
            # publish the extension package.
            print(f"   postgres {version_num // 10000}, pgvector {available} available "
                  "(migrations install it)")
        else:
            print("   error: pgvector is not available on this PostgreSQL server.")
            print("   install it first, then rerun:")
            print("       apt-get install postgresql-16-pgvector")
            print("   or point DATABASE_URL at a pgvector-enabled instance.")
            sys.exit(12)
except SystemExit:
    raise
except Exception as exc:  # never render the URL or the password
    print(f"   error: cannot connect ({exc.__class__.__name__})")
    print("   check host, port, role, password, pg_hba.conf and the database name")
    sys.exit(10)
PY
}

run_migrations() {
    [ "$SKIP_MIGRATE" = "1" ] && return 0
    say "Applying migrations (ledger: embed_schema_migrations)"
    if [ "$DRY_RUN" = "1" ]; then
        note "[dry-run] would run zavai-embedder migrate as the zavai user"
        return 0
    fi
    chown -R zavai:zavai "$STATE" 2>/dev/null || true
    if command -v runuser >/dev/null 2>&1; then
        runuser -u zavai -- env HOME="$STATE" "$LAUNCHER" migrate
    else
        su -s /bin/sh -c "HOME=$STATE $LAUNCHER migrate" zavai
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u zavai -- env HOME="$STATE" "$LAUNCHER" doctor || true
    else
        su -s /bin/sh -c "HOME=$STATE $LAUNCHER doctor" zavai || true
    fi
}

enable_timer() {
    [ "$ENABLE_TIMER" = "1" ] || return 0
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        warn "systemd is not running; the sync timer was not enabled"
        return 0
    fi
    say "Enabling the daily sync timer"
    run systemctl daemon-reload
    run systemctl enable --now zavai-embedder-sync.timer
    note "logs: journalctl -u zavai-embedder-sync.service"
}

print_summary() {
    cat <<EOF

== Next steps

    zavai-embedder version
    zavai-embedder doctor          # configuration, database, provider, collection
    zavai-embedder discover --full # inventory only, writes no revisions
    zavai-embedder sync            # discover, ingest and activate changed documents
    zavai-embedder                 # admin TUI (a TTY is required)

    Configuration : $ENV_FILE (0640 root:zavai)
    Interpreter   : $PY
    Artifacts     : $ARTIFACT_ROOT
    Runs as       : user 'zavai', home $STATE

  Production mode is read-only in the TUI; pass --allow-mutations to write.
  The bundled CPU PyTorch is enough for OCR. --with-cuda swaps in a GPU build
  for Docling OCR only; embeddings always go to your OpenAI-compatible endpoint.
EOF
}

do_uninstall() {
    require_root
    say "Removing zavai-embedder"
    if command -v systemctl >/dev/null 2>&1; then
        run systemctl disable --now zavai-embedder-sync.timer 2>/dev/null || true
    fi
    if dpkg -s zavai-embedder >/dev/null 2>&1; then
        if dpkg -s zavai-embedder-models >/dev/null 2>&1; then
            run dpkg -r zavai-embedder-models
        fi
        run dpkg -r zavai-embedder
    else
        warn "package not installed; removing the tree only"
        run rm -rf "$PREFIX" "$SHARE" "$LAUNCHER" /usr/sbin/zavai-embedder-install
    fi
    note "kept: $ETC (configuration), $STATE (artifacts), user 'zavai'"
    exit 0
}

do_reconfigure() {
    require_root
    [ -x "$LAUNCHER" ] || die "zavai-embedder is not installed; run without --reconfigure"
    collect_config
    write_config
    check_database
    run_migrations
    enable_timer
    print_summary
    exit 0
}

# ---------------------------------------------------------------------------
config_is_complete() {
    [ -f "$ENV_FILE" ] || return 1
    grep -Eq "^DATABASE_URL='[^']+'" "$ENV_FILE"
}

main() {
    [ "$MODE" = "uninstall" ] && do_uninstall
    [ "$MODE" = "reconfigure" ] && do_reconfigure

    check_platform
    require_root

    if [ -z "$DEB" ] && [ -z "$TARBALL" ] && [ -z "$RELEASE_TAG" ]; then
        if [ -f "$LAUNCHER" ] && config_is_complete; then
            die "already installed; use --reconfigure (or --deb to upgrade)"
        fi
        die "nothing to install: pass --deb, --tarball or --release"
    fi

    local keep_config=0
    if config_is_complete && [ "$FORCE" != "1" ]; then
        warn "$ENV_FILE already holds a configured environment"
        if ! confirm "reconfigure it now?"; then
            keep_config=1
        fi
    fi

    check_disk

    if [ -n "$RELEASE_TAG" ] || { [ -z "$DEB" ] && [ -z "$TARBALL" ]; }; then
        download_release
    fi

    if [ -n "$TARBALL" ]; then
        install_tarball "$TARBALL"
    else
        install_deb "$DEB"
    fi
    if [ -n "$MODELS_DEB" ] && [ "$SKIP_MODELS" != "1" ]; then
        install_deb "$MODELS_DEB"
    elif [ "$SKIP_MODELS" != "1" ]; then
        warn "no models package given; Docling will download weights on first use"
    fi

    if [ "$keep_config" = "1" ]; then
        say "Keeping the existing configuration"
        read_existing
        normalize_database_url
    else
        collect_config
        write_config
    fi

    check_database
    run_migrations

    if [ "$WITH_CUDA" = "1" ]; then
        install_cuda || true
    fi
    enable_timer
    print_summary
}

main "$@"
