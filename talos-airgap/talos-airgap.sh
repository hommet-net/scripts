#!/usr/bin/env bash
# talos-airgap.sh — prepare a Talos bundle online (fetch) and load it in an airgap registry (push).
# Rootless: only needs bash, curl, tar, sha256sum. talosctl and crane are downloaded into the bundle.
# See SPEC.md for the design.
set -euo pipefail

FACTORY="https://factory.talos.dev"
CRANE_VERSION="v0.21.6"

# ---------- helpers ----------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# HTTPS only, modern TLS, retry transient errors.
dl() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$@"; }

# One temp root created in the main shell, removed on any exit (mktmp runs in $(...) subshells,
# so it must not track state itself).
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mktmp() { mktemp -d "$TMPROOT/XXXXXX"; }

# match <value> <regex> <message>: validate an input at the boundary.
match() { [[ $1 =~ $2 ]] || die "$3: '$1'"; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

host_os()   { uname -s | tr '[:upper:]' '[:lower:]'; }
host_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) die "unsupported host arch $(uname -m)" ;; esac; }

# Ask a question with a default; fails when stdin is not a terminal.
ask() { # ask <prompt> <default> <choices...>
  local prompt=$1 def=$2 ans; shift 2
  [[ -t 0 ]] || die "$prompt: no value given and not running interactively"
  read -r -p "$prompt [$*] (default: $def): " ans
  ans=${ans:-$def}
  [[ " $* " == *" $ans "* ]] || die "invalid choice: $ans"
  echo "$ans"
}

usage() {
  cat <<'EOF'
Usage:
  talos-airgap.sh fetch [options]   internet side, builds the bundle
  talos-airgap.sh push  [options]   airgap side, loads the bundle into a registry

fetch options:
  --talos-version vX.Y.Z      Talos version (interactive choice if missing)
  --k8s-version vX.Y.Z        Kubernetes version (default: Talos default)
  --target metal|vm           vm = Proxmox/QEMU (nocloud + qemu-guest-agent)
  --cpu intel|amd             microcode, metal only
  --gpu none|nvidia|amd       default none
  --nvidia-driver open|proprietary   default open (proprietary for pre-Turing GPUs)
  --nvidia-branch production|lts     default production
  --extensions a,b            extra official extensions (e.g. iscsi-tools,util-linux-tools)
  --kernel-args "..."         default "net.ifnames=0"
  --extra-images FILE         extra image refs, one per line (Cilium, device plugins...)
  --extra-files F1,F2         files copied into bundle/files (rendered manifests...)
  --mode cache|registry|both  what to carry, default both
  --arch amd64|arm64          default amd64
  --proxy URL                 HTTP(S) proxy for every download
  --out DIR                   default ./bundle

push options:
  --registry HOST[:PORT]      destination registry (required)
  --registry-prefix PATH      e.g. "mirror" -> HOST/mirror/ghcr.io/...
  --registry-ca FILE          CA certificate of the registry
  --insecure                  registry over plain HTTP (http:// mirrors)
  --tls-skip-verify           registry over HTTPS, certificate not verified (self-signed, no CA at hand)
  --registry-user USER        password read from $REGISTRY_PASSWORD
  --bundle DIR                default: the script directory if it is a bundle, else ./bundle
EOF
  exit "${1:-0}"
}

# ---------- fetch ----------
set_proxy() {
  [[ -n $PROXY ]] || return 0
  export HTTP_PROXY=$PROXY HTTPS_PROXY=$PROXY http_proxy=$PROXY https_proxy=$PROXY
}

pick_version() {
  [[ -n $TALOS_VERSION ]] && return 0
  local versions
  versions=$(dl "$FACTORY/versions" | tr -d '[]"' | tr ',' '\n' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^v1\.([0-9]|1[01])\.' | tail -n 8)
  [[ -n $versions ]] || die "cannot list Talos versions from $FACTORY"
  # shellcheck disable=SC2086
  TALOS_VERSION=$(ask "Talos version" "$(tail -n1 <<<"$versions")" $versions)
}

# Talos >= 1.12: talosctl "image k8s-bundle" and the RegistryMirrorConfig documents both start there.
check_version() {
  match "$TALOS_VERSION" '^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$' "invalid Talos version"
  local major minor
  IFS=. read -r major minor _ <<<"${TALOS_VERSION#v}"
  (( major > 1 || minor >= 12 )) || die "Talos $TALOS_VERSION not supported, 1.12 or newer required"
}

pick_profile() {
  [[ -n $TARGET ]] || TARGET=$(ask "Target" metal metal vm)
  [[ $TARGET == metal || $TARGET == vm ]] || die "--target must be metal or vm"
  if [[ $TARGET == metal ]]; then
    [[ -n $CPU ]] || CPU=$(ask "CPU vendor" amd intel amd)
    [[ $CPU == intel || $CPU == amd ]] || die "--cpu must be intel or amd"
  fi
  [[ $GPU =~ ^(none|nvidia|amd)$ ]] || die "--gpu must be none, nvidia or amd"
  [[ $NVIDIA_DRIVER =~ ^(open|proprietary)$ ]] || die "--nvidia-driver must be open or proprietary"
  [[ $NVIDIA_BRANCH =~ ^(production|lts)$ ]] || die "--nvidia-branch must be production or lts"
  [[ $MODE =~ ^(cache|registry|both)$ ]] || die "--mode must be cache, registry or both"
  match "$ARCH" '^(amd64|arm64)$' "--arch must be amd64 or arm64"
  [[ -z $K8S_VERSION ]] || match "$K8S_VERSION" '^v[0-9]+\.[0-9]+\.[0-9]+$' "invalid --k8s-version"
  [[ -z $EXTENSIONS ]] || match "$EXTENSIONS" '^[a-z0-9-]+(,[a-z0-9-]+)*$' "invalid --extensions"
  # kernel args end up in YAML: refuse quotes, backslashes and YAML-special leading chars
  read -ra KARGS <<<"$KERNEL_ARGS"
  local a; for a in ${KARGS[@]+"${KARGS[@]}"}; do match "$a" '^[A-Za-z0-9_.,=:/+-]+$' "invalid kernel arg"; done
  PLATFORM=$([[ $TARGET == vm ]] && echo nocloud || echo metal)
}

# Official extension names (without the siderolabs/ prefix) for the profile.
profile_extensions() {
  [[ $TARGET == vm ]] && echo qemu-guest-agent
  [[ $TARGET == metal ]] && echo "$CPU-ucode"
  case $GPU in
    amd) echo amdgpu ;;
    nvidia)
      if [[ $NVIDIA_DRIVER == open ]]; then echo "nvidia-open-gpu-kernel-modules-$NVIDIA_BRANCH"
      else echo "nonfree-kmod-nvidia-$NVIDIA_BRANCH"; fi
      echo "nvidia-container-toolkit-$NVIDIA_BRANCH" ;;
  esac
  [[ -z $EXTENSIONS ]] || tr ',' '\n' <<<"$EXTENSIONS"
}

download_tools() {
  local os arch bin=$OUT/bin
  os=$(host_os); arch=$(host_arch)
  mkdir -p "$bin"
  if [[ ! -x $bin/talosctl ]]; then
    log "Downloading talosctl $TALOS_VERSION"
    local base="https://github.com/siderolabs/talos/releases/download/$TALOS_VERSION"
    dl -o "$bin/talosctl" "$base/talosctl-$os-$arch"
    verify_sum "$bin/talosctl" "$(dl "$base/sha256sum.txt" | awk -v f="talosctl-$os-$arch" '$2==f{print $1}')"
    chmod +x "$bin/talosctl"
  fi
  if [[ ! -x $bin/crane ]]; then
    log "Downloading crane $CRANE_VERSION"
    local base="https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION"
    local file tmp
    file="go-containerregistry_$(uname -s)_$(uname -m | sed 's/aarch64/arm64/').tar.gz"
    tmp=$(mktmp)
    dl -o "$tmp/$file" "$base/$file"
    verify_sum "$tmp/$file" "$(dl "$base/checksums.txt" | awk -v f="$file" '$2==f{print $1}')"
    tar -xzf "$tmp/$file" -C "$bin" crane
  fi
  TALOSCTL=$bin/talosctl CRANE=$bin/crane
}

verify_sum() { # verify_sum <file> <expected>
  [[ -n $2 ]] || die "no published checksum for $1"
  [[ $(sha256 "$1" | awk '{print $1}') == "$2" ]] || { rm -f "$1"; die "checksum mismatch for $1"; }
}

create_schematic() {
  local exts
  exts=$(profile_extensions | sed 's|^|      - siderolabs/|')
  {
    echo "customization:"
    echo "  extraKernelArgs:"
    local a; for a in ${KARGS[@]+"${KARGS[@]}"}; do echo "    - \"$a\""; done
    echo "  systemExtensions:"
    echo "    officialExtensions:"
    echo "$exts"
  } >"$OUT/schematic.yaml"
  SCHEMATIC_ID=$(dl -X POST --data-binary @"$OUT/schematic.yaml" "$FACTORY/schematics" \
    | sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p')
  [[ -n $SCHEMATIC_ID ]] || die "Image Factory did not return a schematic ID"
  log "Schematic $SCHEMATIC_ID"
}

build_image_list() {
  local k8s_args=()
  [[ -z $K8S_VERSION ]] || k8s_args=(--k8s-version "$K8S_VERSION")
  {
    "$TALOSCTL" image k8s-bundle ${k8s_args[@]+"${k8s_args[@]}"}
    echo "factory.talos.dev/$PLATFORM-installer/$SCHEMATIC_ID:$TALOS_VERSION"
    [[ -z $EXTRA_IMAGES ]] || grep -vE '^\s*(#|$)' "$EXTRA_IMAGES"
  } | sed 's/[[:space:]]//g' | sort -u >"$OUT/images.list"
  log "$(wc -l <"$OUT/images.list" | tr -d ' ') images to fetch"
}

# One OCI layout dir per image; images.txt maps ref -> dir. Existing dirs are reused.
# OCI layout, not crane's legacy tarball: the tarball writer hangs on some images (e.g. flannel).
pull_images() {
  mkdir -p "$OUT/images"
  touch "$OUT/images.txt"
  local ref tar
  while read -r ref; do
    tar="images/$(printf '%s' "$ref" | sha256 | cut -c1-16)"
    if [[ ! -s $OUT/$tar/index.json ]]; then
      log "Pulling $ref"
      rm -rf "${OUT:?}/$tar"
      "$CRANE" pull --format oci --platform "linux/$ARCH" "$ref" "$OUT/$tar"
    fi
    grep -qF "$ref"$'\t' "$OUT/images.txt" || printf '%s\t%s\n' "$ref" "$tar" >>"$OUT/images.txt"
  done <"$OUT/images.list"
}

create_cache() {
  log "Creating image cache"
  "$TALOSCTL" image cache-create --force --platform "linux/$ARCH" \
    --image-cache-path "$OUT/image-cache.oci" --images=- <"$OUT/images.list"
}

# Extension image refs (with digest) for this Talos version, matched against the schematic.
extension_refs() {
  local catalog name ref
  catalog=$(dl "$FACTORY/version/$TALOS_VERSION/extensions/official" | tr '{' '\n')
  while read -r name; do
    ref=$(grep -F "\"name\":\"siderolabs/$name\"" <<<"$catalog" \
      | sed -n 's/.*"ref":"\([^"]*\)","digest":"\([^"]*\)".*/\1@\2/p')
    [[ -n $ref ]] || die "extension siderolabs/$name not found for $TALOS_VERSION"
    echo "$ref"
  done < <(profile_extensions)
}

build_iso() {
  local iso="$OUT/talos-$TALOS_VERSION-$PLATFORM-$ARCH-$SCHEMATIC_ID.iso"
  if [[ -s $iso ]]; then log "ISO already present"; return; fi
  if [[ $MODE != registry ]] && command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    build_iso_with_cache "$iso"
  else
    [[ $MODE != cache ]] || die "--mode cache needs docker to bake the image cache into the ISO"
    log "Downloading Factory ISO (no image cache inside)"
    dl -o "$iso" "$FACTORY/image/$SCHEMATIC_ID/$TALOS_VERSION/$PLATFORM-$ARCH.iso"
  fi
}

build_iso_with_cache() {
  local iso=$1 imager="ghcr.io/siderolabs/imager:$TALOS_VERSION" tmp args=()
  log "Loading $imager through crane (docker daemon proxy not needed)"
  tmp=$(mktmp)
  "$CRANE" pull --platform "linux/$(host_arch)" "$imager" "$tmp/imager.tar"
  docker load -i "$tmp/imager.tar" >/dev/null
  local a r
  for a in ${KARGS[@]+"${KARGS[@]}"}; do args+=(--extra-kernel-arg "$a"); done
  while read -r r; do args+=(--system-extension-image "$r"); done < <(extension_refs)
  mkdir -p "$OUT/.imager"
  log "Building ISO with image cache"
  docker run --rm -t \
    -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY \
    -v "$OUT/image-cache.oci:/image-cache.oci:ro" -v "$OUT/.imager:/out" \
    "$imager" iso --arch "$ARCH" --platform "$PLATFORM" --image-cache /image-cache.oci ${args[@]+"${args[@]}"}
  mv "$OUT/.imager/$PLATFORM-$ARCH.iso" "$iso"
  rm -rf "$OUT/.imager"
}

finish_bundle() {
  if [[ -n $EXTRA_FILES ]]; then
    mkdir -p "$OUT/files"
    local f; IFS=, read -ra f <<<"$EXTRA_FILES"
    cp -- "${f[@]}" "$OUT/files/"
  fi
  cat >"$OUT/profile.env" <<EOF
TALOS_VERSION=$TALOS_VERSION
K8S_VERSION=${K8S_VERSION:-default}
TARGET=$TARGET
CPU=${CPU:-}
GPU=$GPU
NVIDIA_DRIVER=$NVIDIA_DRIVER
NVIDIA_BRANCH=$NVIDIA_BRANCH
ARCH=$ARCH
MODE=$MODE
SCHEMATIC_ID=$SCHEMATIC_ID
TALOSCTL_VERSION=$TALOS_VERSION
CRANE_VERSION=$CRANE_VERSION
IMAGER=ghcr.io/siderolabs/imager:$TALOS_VERSION
EOF
  cp "$0" "$OUT/talos-airgap.sh"
  (cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | while read -r f; do sha256 "$f"; done >SHA256SUMS)
  log "Bundle ready: $OUT ($(du -sh "$OUT" | cut -f1))"
  log "SHA256SUMS fingerprint (note it, compare on the airgap side): $(sha256 "$OUT/SHA256SUMS" | cut -d' ' -f1)"
}

cmd_fetch() {
  need curl; need tar
  set_proxy
  pick_version
  check_version
  pick_profile
  [[ -z $EXTRA_IMAGES || -r $EXTRA_IMAGES ]] || die "cannot read $EXTRA_IMAGES"
  mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
  download_tools
  create_schematic
  build_image_list
  [[ $MODE == cache ]] || pull_images
  [[ $MODE == registry ]] || create_cache
  build_iso
  finish_bundle
}

# ---------- push ----------
# docker.io/library normalisation: "nginx" -> docker.io/library/nginx
upstream_of() {
  local ref=${1%@*} first=${1%%/*}
  if [[ $ref != */* ]]; then echo "docker.io/library/$ref"
  elif [[ $first == *.* || $first == *:* || $first == localhost ]]; then echo "$ref"
  else echo "docker.io/$ref"; fi
}

# Destination ref: registry[/prefix]/<upstream registry>/<repo>:<tag>; digest-only refs keep their digest.
dest_of() {
  local up base=$REGISTRY${REGISTRY_PREFIX:+/$REGISTRY_PREFIX}
  up=$(upstream_of "$1")
  if [[ ${up##*/} != *:* && $1 == *@* ]]; then echo "$base/$up@${1#*@}"; else echo "$base/$up"; fi
}

write_patch() {
  local scheme=https
  [[ -z $INSECURE ]] || scheme=http
  local upstreams
  upstreams=$(cut -f1 "$BUNDLE/images.txt" | while read -r r; do upstream_of "$r" | cut -d/ -f1; done | sort -u)
  local prefix=${REGISTRY_PREFIX:+$REGISTRY_PREFIX/}
  {
    local u; for u in $upstreams; do
      printf -- '---\napiVersion: v1alpha1\nkind: RegistryMirrorConfig\nname: %s\nendpoints:\n  - url: %s://%s/v2/%s%s\n    overridePath: true\n' \
        "$u" "$scheme" "$REGISTRY" "$prefix" "$u"
    done
    if [[ -n $REGISTRY_CA || -n $SKIP_VERIFY ]]; then
      printf -- '---\napiVersion: v1alpha1\nkind: RegistryTLSConfig\nname: %s\n' "$REGISTRY"
      [[ -z $SKIP_VERIFY ]] || echo "insecureSkipVerify: true"
      [[ -z $REGISTRY_CA ]] || { echo "ca: |-"; sed 's/^/  /' "$REGISTRY_CA"; }
    fi
  } >"$BUNDLE/machine-patch.yaml"
  log "Talos patch written: $BUNDLE/machine-patch.yaml (registry auth, if any, must be added by hand)"
}

cmd_push() {
  [[ -n $REGISTRY ]] || die "--registry is required"
  [[ -f $BUNDLE/SHA256SUMS ]] || die "no bundle in $BUNDLE"
  BUNDLE=$(cd "$BUNDLE" && pwd)
  match "$REGISTRY" '^[A-Za-z0-9.-]+(:[0-9]+)?$' "--registry must be HOST[:PORT]"
  [[ -z $REGISTRY_PREFIX ]] || match "$REGISTRY_PREFIX" '^[a-z0-9._/-]+$' "invalid --registry-prefix"
  log "Verifying checksums (fingerprint $(sha256 "$BUNDLE/SHA256SUMS" | cut -d' ' -f1))"
  (cd "$BUNDLE" && sha256 -c --quiet SHA256SUMS) || die "bundle is corrupted"
  # read values, never execute profile.env
  TALOS_VERSION=$(sed -n 's/^TALOS_VERSION=//p' "$BUNDLE/profile.env"); check_version
  [[ -s $BUNDLE/images.txt ]] || die "bundle built with --mode cache: no images to push (boot the ISO, no registry needed)"
  [[ -z $INSECURE || -z $SKIP_VERIFY ]] || die "--insecure (HTTP) and --tls-skip-verify (HTTPS) are exclusive"
  [[ -z $INSECURE || -z $REGISTRY_CA ]] || die "--registry-ca makes no sense with --insecure (HTTP)"
  local crane=$BUNDLE/bin/crane flags=()
  # crane has a single --insecure switch: it allows HTTP and skips TLS verification
  [[ -z $INSECURE && -z $SKIP_VERIFY ]] || flags+=(--insecure)
  if [[ -n $REGISTRY_CA ]]; then [[ -r $REGISTRY_CA ]] || die "cannot read $REGISTRY_CA"; export SSL_CERT_FILE=$REGISTRY_CA; fi
  if [[ -n $REGISTRY_USER ]]; then
    [[ -n ${REGISTRY_PASSWORD:-} ]] || die "set REGISTRY_PASSWORD for --registry-user"
    # throw-away docker config: the password is not left in ~/.docker/config.json
    DOCKER_CONFIG=$(mktmp); export DOCKER_CONFIG
    printf '%s' "$REGISTRY_PASSWORD" | "$crane" auth login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin
  fi
  local ref tar dest
  while IFS=$'\t' read -r ref tar; do
    dest=$(dest_of "$ref")
    log "Pushing $dest"
    "$crane" push ${flags[@]+"${flags[@]}"} "$BUNDLE/$tar" "$dest"
  done <"$BUNDLE/images.txt"
  write_patch
}

# ---------- main ----------
CMD=${1:-}; [[ $# -gt 0 ]] && shift
case $CMD in fetch|push|help|-h|--help) ;; "") usage 1 ;; *) die "first argument must be 'fetch' or 'push', got '$CMD' (see --help)" ;; esac
TALOS_VERSION="" K8S_VERSION="" TARGET="" CPU="" GPU=none NVIDIA_DRIVER=open NVIDIA_BRANCH=production
EXTENSIONS="" KERNEL_ARGS="net.ifnames=0" EXTRA_IMAGES="" EXTRA_FILES="" MODE=both ARCH=amd64 PROXY="" OUT=./bundle
KARGS=() REGISTRY="" REGISTRY_PREFIX="" REGISTRY_CA="" INSECURE="" SKIP_VERIFY="" REGISTRY_USER="" BUNDLE=./bundle
# push run from inside a transferred bundle: default to the script's own directory
[[ -f "$(dirname "$0")/SHA256SUMS" ]] && BUNDLE=$(dirname "$0")

while [[ $# -gt 0 ]]; do
  case $1 in
    --insecure) INSECURE=1; shift; continue ;;
    --tls-skip-verify) SKIP_VERIFY=1; shift; continue ;;
    -h|--help) usage ;;
  esac
  [[ $# -ge 2 ]] || die "$1 needs a value"
  case $1 in
    --talos-version) TALOS_VERSION=v${2#v} ;;
    --k8s-version) K8S_VERSION=v${2#v} ;;
    --target) TARGET=$2 ;;
    --cpu) CPU=$2 ;;
    --gpu) GPU=$2 ;;
    --nvidia-driver) NVIDIA_DRIVER=$2 ;;
    --nvidia-branch) NVIDIA_BRANCH=$2 ;;
    --extensions) EXTENSIONS=$2 ;;
    --kernel-args) KERNEL_ARGS=$2 ;;
    --extra-images) EXTRA_IMAGES=$2 ;;
    --extra-files) EXTRA_FILES=$2 ;;
    --mode) MODE=$2 ;;
    --arch) ARCH=$2 ;;
    --proxy) PROXY=$2 ;;
    --out) OUT=$2 ;;
    --registry) REGISTRY=$2 ;;
    --registry-prefix) REGISTRY_PREFIX=${2%/} ;;
    --registry-ca) REGISTRY_CA=$2 ;;
    --registry-user) REGISTRY_USER=$2 ;;
    --bundle) BUNDLE=$2 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift 2
done

case $CMD in
  fetch) cmd_fetch ;;
  push) cmd_push ;;
  -h|--help|help) usage ;;
  *) usage 1 ;;
esac
