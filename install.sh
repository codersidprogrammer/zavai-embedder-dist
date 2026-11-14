#!/usr/bin/env bash
# zavai-embedder installer for Debian 12+ (amd64).
#
# Installs the packaged build, writes /etc/zavai-embedder/embedder.env, checks
# the PostgreSQL host (16 + pgvector) and applies the embedder's migrations.
# It never provisions PostgreSQL: point it at an existing server.
#
#   sudo ./install.sh --deb ./zavai-embedder_1.2.0~dev..._amd64.deb \
#        --models-deb ./zavai-embedder-models_1.2.0~dev..._all.deb
#
#   sudo zavai-embedder-install --reconfigure
#   sudo zavai-embedder-install --upgrade [--deb PATH | --release [TAG]]
#   sudo zavai-embedder-install --rollback
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
# Pins the converter stack across the CUDA swap; shipped beside the migrations.
CONSTRAINTS="$SHARE/constraints.txt"
# Offline Docling weights and the digest the installed runtime expects of them.
MODELS_DIR="$SHARE/models"
WEIGHTS_MANIFEST="$SHARE/weights-manifest.json"

MODE=install
DEB="" MODELS_DEB="" TARBALL="" RELEASE_TAG="" TOKEN="${GITHUB_TOKEN:-}"
RELEASE_REQUESTED=0
NON_INTERACTIVE=0 DRY_RUN=0 SKIP_MIGRATE=0 WITH_CUDA=0 ENABLE_TIMER=0
FORCE=0 ASSUME_YES=0
ENV_MODE="" SKIP_MODELS=0
# Upgrade/rollback state: the retained package of the version we replaced, so a
# rollback never downloads anything and never touches the corpus (US5/T064/T065).
UPGRADE_STATE="$STATE/upgrade.state"
PACKAGE_CACHE="$STATE/packages"

# Values start from the process environment so `sudo DATABASE_URL=... ./install.sh`
# works without putting a secret on the command line. Flags override them.
DB_URL="${DATABASE_URL:-}"
LLM_BASE="${LLM_BASE_URL:-}"
LLM_KEY="${LLM_API_KEY:-}"
LLM_MODEL="${LLM_EMBED_MODEL:-}"
LLM_DIM="${LLM_EMBED_DIM:-}"
LLM_VISION_MODEL="${LLM_VISION_MODEL:-}"
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

opt_value() {
    # opt_value <option> <value>: a missing value or one that is really the
    # next flag is a usage error, never a silent reinterpretation.
    local option="$1" value="${2:-}"
    if [ -z "$value" ] || [ "${value#-}" != "$value" ]; then
        printf 'error: %s requires a value\n' "$option" >&2
        exit 2
    fi
    printf '%s' "$value"
}

absolutize() {
    # Resolve a caller-relative path before main() changes directory.
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
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
  sudo zavai-embedder-install --upgrade [--deb PATH | --release [TAG]]
  sudo zavai-embedder-install --rollback
  sudo zavai-embedder-install --uninstall

Options:
  --deb PATH                 runtime .deb to install
  --models-deb PATH          offline Docling weights .deb (recommended)
  --tarball PATH             portable tree instead of .deb (non-dpkg hosts)
  --release [TAG]            download a published release (default: newest dev build)
  --token TOKEN              GitHub token (only for a private mirror)
  --repo OWNER/REPO          override the distribution repository
                             (default: codersidprogrammer/zavai-embedder-dist)
  --reconfigure              rewrite configuration and migrate; install nothing
  --upgrade                  replace the installed runtime in place, keeping
                             configuration, corpus, artifacts and matching weights
  --rollback                 restore the runtime replaced by the last --upgrade
  --uninstall                remove the packages, keep corpus data and config

  --database-url URL         DATABASE_URL (postgresql+psycopg://...)
  --llm-base-url URL         LLM_BASE_URL (OpenAI-compatible base, no /v1)
  --llm-api-key KEY          LLM_API_KEY
  --llm-embed-model NAME     LLM_EMBED_MODEL (default text-embedding-3-large)
  --llm-embed-dim N          LLM_EMBED_DIM (default 2000, must match the runner)
  --llm-vision-model NAME    LLM_VISION_MODEL (optional; enables figure descriptions)
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
                             (a failed request exits non-zero; any later
                             package upgrade restores the CPU build)
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
        --deb) DEB="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --models-deb) MODELS_DEB="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --tarball) TARBALL="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --release)
            # The value is optional: no value means the newest release. A
            # following flag is never consumed as a tag.
            RELEASE_REQUESTED=1
            case "${2:-}" in
                ''|-*) shift ;;
                *) RELEASE_TAG="$(opt_value "$1" "$2")"; shift 2 ;;
            esac
            ;;
        --token) TOKEN="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --repo) REPO="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --reconfigure) MODE=reconfigure; shift ;;
        --upgrade) MODE=upgrade; shift ;;
        --rollback) MODE=rollback; shift ;;
        --uninstall) MODE=uninstall; shift ;;
        --database-url) DB_URL="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --llm-base-url) LLM_BASE="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --llm-api-key) LLM_KEY="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --llm-embed-model) LLM_MODEL="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --llm-embed-dim) LLM_DIM="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --llm-vision-model) LLM_VISION_MODEL="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --vector-collection) COLLECTION="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --sharepoint-tenant-id) SP_TENANT="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --sharepoint-client-id) SP_CLIENT="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --sharepoint-client-secret) SP_SECRET="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --sharepoint-domain) SP_DOMAIN="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --sharepoint-site) SP_SITE="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --sharepoint-drives) SP_DRIVES="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --env-mode) ENV_MODE="$(opt_value "$1" "${2:-}")"; shift 2 ;;
        --artifact-root) ARTIFACT_ROOT="$(opt_value "$1" "${2:-}")"; shift 2 ;;
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

# Resolve paths while the caller's working directory is still current, then
# leave it: a production run refuses to start where a `.env` exists, and the
# Debian maintainer-script convention is to run from /.
for _path_var in DEB MODELS_DEB TARBALL; do
    eval "_value=\${$_path_var}"
    if [ -n "$_value" ]; then
        eval "$_path_var=\"\$(absolutize \"\$_value\")\""
    fi
done
unset _path_var _value
cd /

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

pick_release_tag() {
    # pick_release_tag <output-json>: resolve a tag when --release was omitted.
    # A supported release wins: /releases/latest excludes prereleases, so an
    # unqualified install gets the stable version instead of the tip of
    # `development`. The project shipped dev builds only for a while, so fall
    # back to the newest release of any kind when no supported one exists yet.
    # Pass a tag explicitly (`--release <tag>`) to install a development build.
    local json="$1" tag
    if curl_release "$json" \
        "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null; then
        tag="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$json" | head -n1)"
        if [ -n "$tag" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi
    if curl_release "$json" \
        "https://api.github.com/repos/${REPO}/releases?per_page=1" 2>/dev/null; then
        tag="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$json" | head -n1)"
        if [ -n "$tag" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi
    # The REST API is rate limited per address (60/h unauthenticated) and an
    # unusable token 401s; neither means the release is missing. The atom feed
    # is served by github.com, lists releases newest first, and includes
    # prereleases -- so this last resort cannot prefer the supported release.
    curl -fsSL "https://github.com/${REPO}/releases.atom" -o "$json.atom" \
        2>/dev/null || return 1
    tag="$(sed -n 's|.*releases/tag/\([^"]*\)".*|\1|p' "$json.atom" | head -n1)"
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}
download_release() {
    local tag="$RELEASE_TAG" json version asset_version dir asset id
    json="/tmp/.zavai-release.json"
    if [ -z "$tag" ]; then
        tag="$(pick_release_tag "$json")" \
            || die "cannot list releases for ${REPO}"
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
        # The sums also cover the tarball and the weights manifest, which this
        # path does not fetch; verify only what is present.
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
    # Retain every installed runtime package so `--rollback` has a local copy
    # and never needs to download the version being replaced (US5/T065).
    if [ "$(deb_field "$deb" Package)" = "zavai-embedder" ]; then
        retain_package "$deb" || warn "cannot retain this runtime package for rollback"
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

install_cpu_torch() {
    # install_cpu_torch <torch> <torchvision>: restore the artifact default.
    local torch_version="$1" torchvision_version="$2"
    "$PY" -m pip install --no-cache-dir --constraint "$CONSTRAINTS" \
        --index-url https://download.pytorch.org/whl/cpu \
        --extra-index-url https://pypi.org/simple \
        "torch==${torch_version}" "torchvision==${torchvision_version}"
}

install_cuda() {
    say "Installing the CUDA PyTorch build (OCR acceleration only)"
    if [ "$DRY_RUN" = "1" ]; then
        note "[dry-run] would replace torch/torchvision with cu126 wheels"
        note "[dry-run] constraints: $CONSTRAINTS"
        return 0
    fi
    [ -f "$CONSTRAINTS" ] || die "missing constraints file: $CONSTRAINTS"
    local torch_version torchvision_version
    torch_version="$("$PY" -c 'import torch; print(torch.__version__.split("+")[0])')"
    torchvision_version="$("$PY" -c 'import torchvision; print(torchvision.__version__.split("+")[0])')"
    note "matching torch ${torch_version}, torchvision ${torchvision_version}"
    # Uninstall first. `--force-reinstall` re-resolves torchvision's whole
    # dependency set (it moved pillow 12.3.0 -> 13.0.0 on a real host); a
    # constrained fresh install keeps the OCR stack the artifact ships.
    "$PY" -m pip uninstall -y torch torchvision >/dev/null 2>&1 || true
    if ! "$PY" -m pip install --no-cache-dir --constraint "$CONSTRAINTS" \
        --index-url https://download.pytorch.org/whl/cu126 \
        --extra-index-url https://pypi.org/simple \
        "torch==${torch_version}" "torchvision==${torchvision_version}"; then
        warn "CUDA wheels are unavailable for this torch version; reinstalling the CPU build"
        install_cpu_torch "$torch_version" "$torchvision_version" \
            || warn "the CPU build could not be restored; rerun --reconfigure --with-cuda"
        return 1
    fi
    if "$PY" -c 'import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)'; then
        note "CUDA is available: Docling OCR will use the GPU"
    else
        warn "torch.cuda.is_available() is false; the cu126 wheels are installed but the"
        warn "driver is not usable (check nvidia-smi). OCR still runs on the CPU."
        return 1
    fi
    return 0
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
            LLM_VISION_MODEL) LLM_VISION_MODEL="${LLM_VISION_MODEL:-$value}" ;;
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
    # Vision is optional: a model enables figure descriptions, blank disables
    # them. `ask` rejects an empty value, so this uses a dedicated prompt that
    # keeps whatever the flag or environment already provided when the operator
    # just presses Enter.
    if [ "$NON_INTERACTIVE" = "0" ]; then
        read -r -p "   Vision model (blank disables figure descriptions) [${LLM_VISION_MODEL}]: " __vision || true
        [ -n "$__vision" ] && LLM_VISION_MODEL="$__vision"
    fi
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
LLM_VISION_MODEL=$(shell_quote "$LLM_VISION_MODEL")
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
# After a native crash, retry once on this RapidOCR backend (empty disables).
CONVERT_OCR_FALLBACK_BACKEND=onnxruntime
OCR_MIN_CONFIDENCE=0.5
# --- Extraction backend (optional; defaults to ppstructure) ---
# ppstructure: internal PP-StructureV3 service (fetch by document number).
# docling: bundled local extractor (fully offline).
# EXTRACT_BACKEND=ppstructure
# PPSTRUCTURE_BASE_URL=http://172.16.170.15:8080
# PPSTRUCTURE_TIMEOUT_SECONDS=900
# PPSTRUCTURE_PROFILE=accuracy
# PPSTRUCTURE_LANG=id
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
    check_platform
    check_disk
    if [ "$WITH_CUDA" = "1" ]; then
        install_cuda || die "CUDA was requested but is not active; see the warning above"
    fi
    collect_config
    write_config
    check_database
    run_migrations
    enable_timer
    print_summary
    exit 0
}

# ---------------------------------------------------------------------------
# Upgrade and rollback (US5/T064/T065; contracts/package-upgrade.md)
#
# The upgrade keeps the configuration conffile, the corpus, the artifacts, the
# logs and the sync timer, and reinstalls the weights only when their content
# digest differs from what the new runtime expects. The package being replaced
# is retained under $PACKAGE_CACHE so `--rollback` never downloads anything.
# ---------------------------------------------------------------------------
PREVIOUS_VERSION="" PREVIOUS_PACKAGE="" PREVIOUS_WEIGHTS_DIGEST=""
UPGRADED_VERSION="" REMOTE_MANIFEST=""

installed_version() {
    dpkg-query -W -f='${Version}' zavai-embedder 2>/dev/null || return 1
}

version_lt() { dpkg --compare-versions "$1" lt "$2"; }
version_eq() { dpkg --compare-versions "$1" eq "$2"; }

deb_field() {
    # deb_field <deb> <field>; empty when the package cannot be read.
    dpkg-deb -f "$1" "$2" 2>/dev/null || true
}

verify_deb_checksum() {
    # A sibling SHA256SUMS is authoritative when present; dpkg verifies the
    # archive itself on install. A mismatch never touches the installed tree.
    local deb="$1" dir base expected actual
    dir="$(dirname "$deb")"
    base="$(basename "$deb")"
    if [ ! -f "$dir/SHA256SUMS" ]; then
        note "no SHA256SUMS beside ${base}; relying on dpkg integrity checks"
        return 0
    fi
    expected="$(awk -v want="$base" '$2 == want || $2 == "*" want {print $1}' \
        "$dir/SHA256SUMS" | head -n1)"
    if [ -z "$expected" ]; then
        warn "${base} is not listed in ${dir}/SHA256SUMS"
        return 1
    fi
    actual="$(sha256sum "$deb" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        warn "checksum mismatch for ${base}"
        note "expected: ${expected}"
        note "actual:   ${actual}"
        return 1
    fi
    note "sha256 verified for ${base}"
}

dir_digest() {
    # dir_digest <root>; byte-identical to packaging/release_manifest.py's
    # content_digest: sorted "<sha256> <relative-path>\n" lines, hashed once.
    [ -d "$1" ] || return 1
    "$PY" - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
lines = []
for path in sorted(root.rglob("*")):
    if path.is_file():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest} {path.relative_to(root).as_posix()}\n")
if not lines:
    sys.exit(1)
print(hashlib.sha256("".join(lines).encode("utf-8")).hexdigest())
PY
}

_manifest_digest() {
    # The 64-hex content_digest of a weights manifest, empty when absent.
    [ -f "$1" ] || return 0
    sed -n 's/.*"content_digest": *"\([0-9a-f]\{64\}\)".*/\1/p' "$1" | head -n1
}

expected_weights_digest() {
    _manifest_digest "$WEIGHTS_MANIFEST"
}

expected_digest_from_deb() {
    # The weights digest a runtime .deb declares, read without installing it.
    local deb="$1"
    dpkg-deb --fsys-tarfile "$deb" 2>/dev/null \
        | tar -xO ./usr/lib/zavai-embedder/weights-manifest.json 2>/dev/null \
        | sed -n 's/.*"content_digest": *"\([0-9a-f]\{64\}\)".*/\1/p' | head -n1 || true
}

digest_from_models_deb() {
    # The content digest of the weights tree inside a models .deb.
    local deb="$1" tmp digest
    tmp="$(mktemp -d)"
    if ! dpkg-deb -x "$deb" "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    digest="$(dir_digest "$tmp$MODELS_DIR" || true)"
    rm -rf "$tmp"
    [ -n "$digest" ] || return 1
    printf '%s\n' "$digest"
}

verify_weights_digest() {
    # Compare the installed weights tree with what the runtime expects.
    local expected actual
    expected="$(expected_weights_digest)"
    if [ -z "$expected" ]; then
        warn "the runtime package carries no weights manifest; cannot verify weights"
        return 0
    fi
    if [ ! -d "$MODELS_DIR" ]; then
        warn "no weights are installed at ${MODELS_DIR}"
        return 1
    fi
    actual="$(dir_digest "$MODELS_DIR" || true)"
    if [ "$actual" != "$expected" ]; then
        warn "installed weights digest does not match the runtime's expectation"
        note "expected:  ${expected}"
        note "installed: ${actual:-<unreadable>}"
        note "remedy: install the matching zavai-embedder-models package"
        return 1
    fi
    note "weights digest verified"
    return 0
}

retain_package() {
    # Keep a runtime .deb by its Debian version for a later --rollback.
    local deb="$1" version target
    version="$(deb_field "$deb" Version)"
    [ -n "$version" ] || return 1
    target="$PACKAGE_CACHE/zavai-embedder_${version}_amd64.deb"
    if [ "$DRY_RUN" = "1" ]; then
        note "[dry-run] would retain ${deb} for rollback"
        return 0
    fi
    # A fresh install already retained this package, so an upgrade hands the
    # retained copy straight back here. `install` refuses to copy a file onto
    # itself ("are the same file"), which failed the upgrade with "cannot retain
    # the installed <version> package; refusing to upgrade without a rollback
    # path" even though the rollback copy was sitting right there.
    if [ "$deb" -ef "$target" ]; then
        return 0
    fi
    install -d -o root -g root -m 0750 "$PACKAGE_CACHE"
    install -m 0640 "$deb" "$target"
}

ensure_previous_package() {
    # Sets PREVIOUS_PACKAGE to a cached .deb for VERSION; 1 when unavailable.
    local version="$1" candidate tmp
    candidate="$PACKAGE_CACHE/zavai-embedder_${version}_amd64.deb"
    if [ ! -f "$candidate" ]; then
        candidate="/var/cache/apt/archives/zavai-embedder_${version}_amd64.deb"
    fi
    if [ ! -f "$candidate" ] && command -v dpkg-repack >/dev/null 2>&1; then
        tmp="$(mktemp -d)"
        if (cd "$tmp" && dpkg-repack zavai-embedder >/dev/null 2>&1); then
            candidate="$(find "$tmp" -maxdepth 1 -name 'zavai-embedder_*.deb' -print -quit)"
            if [ -n "$candidate" ] && [ "$(deb_field "$candidate" Version)" != "$version" ]; then
                candidate=""
            fi
        else
            candidate=""
        fi
    fi
    if [ -z "$candidate" ] || [ ! -f "$candidate" ]; then
        warn "no package retained for ${version}"
        note "install dpkg-repack (apt-get install dpkg-repack), or place"
        note "zavai-embedder_${version}_amd64.deb in ${PACKAGE_CACHE}"
        return 1
    fi
    retain_package "$candidate" || return 1
    PREVIOUS_PACKAGE="$PACKAGE_CACHE/zavai-embedder_${version}_amd64.deb"
    return 0
}

read_upgrade_state() {
    [ -f "$UPGRADE_STATE" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            previous_version) PREVIOUS_VERSION="$value" ;;
            previous_package) PREVIOUS_PACKAGE="$value" ;;
            previous_weights_digest) PREVIOUS_WEIGHTS_DIGEST="$value" ;;
            runtime_version) UPGRADED_VERSION="$value" ;;
        esac
    done <"$UPGRADE_STATE"
    [ -n "$PREVIOUS_VERSION" ]
}

write_upgrade_state() {
    # write_upgrade_state <previous-version> <previous-package>
    #                     <previous-weights-digest> <runtime-version> <runtime-package>
    local tmp
    tmp="$(mktemp)"
    {
        printf 'previous_version=%s\n' "$1"
        printf 'previous_package=%s\n' "$2"
        printf 'previous_weights_digest=%s\n' "${3:-}"
        printf 'runtime_version=%s\n' "$4"
        printf 'runtime_package=%s\n' "${5:-}"
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$tmp"
    if [ "$DRY_RUN" = "1" ]; then
        rm -f "$tmp"
        note "[dry-run] would record the upgrade state at ${UPGRADE_STATE}"
        return 0
    fi
    install -d -o root -g root -m 0750 "$STATE"
    install -o root -g root -m 0640 "$tmp" "$UPGRADE_STATE"
    rm -f "$tmp"
}

ledger_head() {
    # The embedder's own migration head; empty when the database is unknown.
    local url
    read_existing
    url="${DB_URL:-}"
    [ -n "$url" ] || return 1
    "$PY" - "$url" <<'PY' || return 1
import sys

from sqlalchemy import create_engine, text

try:
    engine = create_engine(sys.argv[1], connect_args={"connect_timeout": 10})
    with engine.connect() as conn:
        row = conn.execute(
            text(
                "SELECT version_num FROM embed_schema_migrations "
                "ORDER BY version_num DESC LIMIT 1"
            )
        ).scalar()
    print(row or "")
except Exception:
    sys.exit(1)
PY
}

check_rollback_compatible() {
    # The database must not be at a migration the previous runtime lacks.
    local deb="$1" tmp known current
    tmp="$(mktemp -d)"
    if ! dpkg-deb -x "$deb" "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        warn "cannot unpack ${deb} to inspect its migration set"
        return 1
    fi
    known="$(find "$tmp$SHARE/migrations/versions" -maxdepth 1 -name '*.py' \
        2>/dev/null | sed 's#.*/##; s/\.py$//' | sort)"
    rm -rf "$tmp"
    current="$(ledger_head || true)"
    [ -n "$current" ] || return 0
    if printf '%s\n' "$known" | grep -qx "$current"; then
        return 0
    fi
    warn "the database is at migration '${current}', which the previous runtime does not ship"
    warn "migrations known to the previous package: $(printf '%s ' $known)"
    return 1
}

timer_enabled() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    systemctl is-enabled --quiet zavai-embedder-sync.timer 2>/dev/null
}

installed_models_pins_runtime() {
    # A pre-decoupling weights package declares `zavai-embedder (= <version>)`,
    # which dpkg refuses to leave installed beside a new runtime.
    dpkg-query -W -f='${Depends}' zavai-embedder-models 2>/dev/null \
        | grep -q 'zavai-embedder (= '
}

restart_timer_if_enabled() {
    [ "$1" = "1" ] || return 0
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        return 0
    fi
    run systemctl daemon-reload
    run systemctl enable --now zavai-embedder-sync.timer
}

require_doctor() {
    [ "$DRY_RUN" = "1" ] && { note "[dry-run] would run zavai-embedder doctor"; return 0; }
    say "Running zavai-embedder doctor"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u zavai -- env HOME="$STATE" "$LAUNCHER" doctor
    else
        su -s /bin/sh -c "HOME=$STATE $LAUNCHER doctor" zavai
    fi
}

probe_release_manifest() {
    # Fetch only release-manifest.json so the weights digest is known before
    # any package is downloaded. Sets RELEASE_TAG and REMOTE_MANIFEST.
    local tag="$RELEASE_TAG" json id
    json="$(mktemp)"
    if [ -z "$tag" ]; then
        tag="$(pick_release_tag "$json")" || { rm -f "$json"; return 1; }
    else
        if ! curl_release "$json" \
            "https://api.github.com/repos/${REPO}/releases/tags/${tag}"; then
            rm -f "$json"
            return 1
        fi
    fi
    if [ -z "$tag" ]; then
        rm -f "$json"
        return 1
    fi
    RELEASE_TAG="$tag"
    id="$(asset_id "$json" release-manifest.json)"
    if [ -z "$id" ]; then
        rm -f "$json"
        return 1
    fi
    REMOTE_MANIFEST="$(mktemp)"
    if ! fetch_asset "$id" "$REMOTE_MANIFEST"; then
        if ! fetch_public_asset "$tag" release-manifest.json "$REMOTE_MANIFEST"; then
            rm -f "$json" "$REMOTE_MANIFEST"
            REMOTE_MANIFEST=""
            return 1
        fi
    fi
    rm -f "$json"
    return 0
}

do_upgrade() {
    require_root
    check_platform
    check_disk
    [ -x "$LAUNCHER" ] || die "zavai-embedder is not installed; run without --upgrade"
    [ -f "$ENV_FILE" ] || die "configuration missing at ${ENV_FILE}; run --reconfigure first"

    local current new_version expected_digest installed_digest models_digest
    local timer_was_enabled=0 weights_needed=0
    current="$(installed_version)" || die "cannot read the installed version"
    say "Installed version: ${current}"

    if [ "$RELEASE_REQUESTED" = "1" ]; then
        [ -n "$DEB" ] && die "--release cannot be combined with --deb"
        probe_release_manifest || die "cannot read the release manifest for ${REPO}"
        expected_digest="$(_manifest_digest "$REMOTE_MANIFEST")"
        installed_digest="$(dir_digest "$MODELS_DIR" 2>/dev/null || true)"
        if [ "$SKIP_MODELS" != "1" ] && [ -n "$expected_digest" ] \
            && [ "$expected_digest" = "$installed_digest" ] \
            && ! installed_models_pins_runtime; then
            # The weights content is unchanged: do not download them at all.
            SKIP_MODELS=1
            note "release weights match the installed content; they will not be downloaded"
        fi
        download_release
        rm -f "$REMOTE_MANIFEST"
        REMOTE_MANIFEST=""
    else
        [ -n "$DEB" ] || die "--upgrade needs --deb PATH or --release"
        verify_deb_checksum "$DEB" || die "refusing to install a package that failed verification"
    fi
    [ -f "$DEB" ] || die "package not found: ${DEB}"
    new_version="$(deb_field "$DEB" Version)"
    [ -n "$new_version" ] || die "cannot read the version of ${DEB}"

    if version_eq "$new_version" "$current"; then
        say "Already current: ${current}"
        exit 0
    fi
    if version_lt "$new_version" "$current" && [ "$FORCE" != "1" ]; then
        die "refusing to downgrade ${current} -> ${new_version} (use --force, or --rollback)"
    fi

    # Guarantee 1: the package being replaced is retained *before* anything is
    # replaced. If it cannot be retained, rollback would be a lie, so stop.
    ensure_previous_package "$current" \
        || die "cannot retain the installed ${current} package; refusing to upgrade without a rollback path"

    # The new runtime's expected weights digest decides whether the models
    # package is touched at all (guarantee 4).
    if [ "$RELEASE_REQUESTED" != "1" ]; then
        expected_digest="$(expected_digest_from_deb "$DEB" || true)"
        installed_digest="$(dir_digest "$MODELS_DIR" 2>/dev/null || true)"
    fi
    if [ -z "${expected_digest:-}" ]; then
        warn "the new runtime carries no weights manifest; weights will be verified after install"
    elif [ "$expected_digest" = "$installed_digest" ]; then
        if installed_models_pins_runtime; then
            # Metadata, not content: the old weights package pins the old
            # runtime exactly. dpkg needs the new weights package in the same
            # transaction, even though its files are byte-identical.
            if [ -z "$MODELS_DEB" ]; then
                die "the installed weights package pins the previous runtime exactly; pass --models-deb PATH (the weights content did not change)"
            fi
            weights_needed=1
            note "the installed weights package pins the old runtime; replacing it with the identical content"
        else
            note "installed weights already match the new runtime; not reinstalling them"
            MODELS_DEB=""
        fi
    else
        weights_needed=1
        if [ -z "$MODELS_DEB" ]; then
            die "the new runtime expects different model weights; pass --models-deb PATH (or use --release)"
        fi
        models_digest="$(digest_from_models_deb "$MODELS_DEB" || true)"
        if [ -n "$models_digest" ] && [ "$models_digest" != "$expected_digest" ]; then
            die "weights package digest does not match the runtime (expected ${expected_digest}, got ${models_digest})"
        fi
        note "weights package matches the new runtime and will be replaced"
    fi

    timer_enabled && timer_was_enabled=1

    # Guarantee 2/3: checksum-verified package, replaced in place. dpkg keeps
    # the conffile because embedder.env is registered as one.
    install_deb "$DEB"

    if [ "$weights_needed" = "1" ] && [ -n "$MODELS_DEB" ]; then
        install_deb "$MODELS_DEB"
    fi

    if [ "$WITH_CUDA" = "1" ]; then
        install_cuda || die "CUDA was requested but is not active; see the warning above"
    fi

    verify_weights_digest || die "installed weights do not match the new runtime; see the remedy above"

    # Guarantee 5: configuration, corpus, artifacts and logs were never touched.
    write_upgrade_state "$current" "$PREVIOUS_PACKAGE" \
        "${installed_digest:-}" "$new_version" "$DEB"

    # Guarantee 7: a failed doctor leaves the previous package retained.
    if ! require_doctor; then
        warn "doctor failed after the upgrade; the previous runtime is retained"
        note "roll back with: sudo ${PROGRAM} --rollback"
        exit 1
    fi

    restart_timer_if_enabled "$timer_was_enabled"

    say "Upgrade complete: ${current} -> ${new_version}"
    note "configuration, corpus, artifacts and logs were preserved"
    note "rollback with: sudo ${PROGRAM} --rollback"
    exit 0
}

do_rollback() {
    require_root
    check_platform
    [ -x "$LAUNCHER" ] || die "zavai-embedder is not installed"
    read_upgrade_state \
        || die "no upgrade state at ${UPGRADE_STATE}; nothing to roll back"

    local current
    current="$(installed_version)" || die "cannot read the installed version"
    if [ ! -f "$PREVIOUS_PACKAGE" ]; then
        ensure_previous_package "$PREVIOUS_VERSION" \
            || die "the retained package for ${PREVIOUS_VERSION} is missing"
    fi
    verify_deb_checksum "$PREVIOUS_PACKAGE" \
        || die "refusing to install a package that failed verification"

    # Never half-restore: refuse before replacing anything when the schema has
    # moved past what the previous runtime can read.
    if ! check_rollback_compatible "$PREVIOUS_PACKAGE"; then
        die "cannot roll back to ${PREVIOUS_VERSION}: the database schema is newer than that runtime"
    fi

    say "Rolling back ${current} -> ${PREVIOUS_VERSION}"
    if [ -n "$UPGRADED_VERSION" ]; then
        note "undoing the upgrade to ${UPGRADED_VERSION}"
    fi
    # Guarantee 2: configuration, corpus, artifacts and weights stay untouched.
    install_deb "$PREVIOUS_PACKAGE"

    if ! require_doctor; then
        die "the previous runtime does not pass doctor against the current database"
    fi

    say "Rollback complete: ${PREVIOUS_VERSION}"
    if [ -n "$PREVIOUS_WEIGHTS_DIGEST" ]; then
        note "model weights were left in place (digest ${PREVIOUS_WEIGHTS_DIGEST})"
    fi
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
    [ "$MODE" = "upgrade" ] && do_upgrade
    [ "$MODE" = "rollback" ] && do_rollback

    check_platform
    require_root

    if [ -n "$DEB" ] && [ -n "$TARBALL" ]; then
        die "use either --deb or --tarball, not both"
    fi
    if [ "$RELEASE_REQUESTED" = "1" ] && { [ -n "$DEB" ] || [ -n "$TARBALL" ]; }; then
        die "--release cannot be combined with --deb or --tarball"
    fi
    if [ -z "$DEB" ] && [ -z "$TARBALL" ] && [ "$RELEASE_REQUESTED" != "1" ]; then
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

    if [ "$RELEASE_REQUESTED" = "1" ]; then
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

    # GPU wheels are a post-install mutation of the package tree: apply them
    # before configuration and migrations, and fail loudly when the request
    # cannot be honoured. `dpkg -i` on any later upgrade restores the CPU build.
    if [ "$WITH_CUDA" = "1" ]; then
        install_cuda || die "CUDA was requested but is not active; see the warning above"
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
    enable_timer
    print_summary
}

main "$@"
