#!/bin/sh
# Installs the `fsp` binary (the fespalier code generator) without needing Rust.
#
#   curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
#
# Environment:
#   FSP_VERSION      release tag to install, e.g. v0.3.0 (default: latest release)
#   FSP_INSTALL_DIR  where to put `fsp` (default: $HOME/.local/bin)
#   FSP_BASE_URL     where releases are downloaded from
#                    (default: https://github.com/fespalier/fespalier/releases/download)
set -eu

REPO="fespalier/fespalier"
RELEASES_URL="https://github.com/${REPO}/releases"
BASE_URL="${FSP_BASE_URL:-${RELEASES_URL}/download}"
INSTALL_DIR="${FSP_INSTALL_DIR:-${HOME:-}/.local/bin}"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "${FSP_INSTALL_DIR:-}" ] && [ -z "${HOME:-}" ]; then
  err "HOME is not set; set FSP_INSTALL_DIR to say where to install fsp"
fi

# download <url> <output-file>
download() {
  if have curl; then
    curl -fsSL "$1" -o "$2"
  elif have wget; then
    wget -q -O "$2" "$1"
  else
    err "need curl or wget to download files"
  fi
}

# --- platform -> target triple ---------------------------------------------
os=$(uname -s)
arch=$(uname -m)

case "$os" in
  Linux) os_part="unknown-linux-gnu" ;;
  Darwin) os_part="apple-darwin" ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    err "Windows is not supported by this script. In PowerShell run: irm https://raw.githubusercontent.com/fespalier/fespalier/main/install.ps1 | iex (or download fsp-x86_64-pc-windows-msvc.zip from ${RELEASES_URL} and put fsp.exe on your PATH)."
    ;;
  *) err "unsupported operating system: ${os} (supported: Linux, macOS). Prebuilt binaries are listed at ${RELEASES_URL}; otherwise build from source with cargo." ;;
esac

case "$arch" in
  x86_64 | amd64) arch_part="x86_64" ;;
  arm64 | aarch64) arch_part="aarch64" ;;
  *) err "unsupported architecture: ${arch} (supported: x86_64, arm64/aarch64)" ;;
esac

target="${arch_part}-${os_part}"

# Only these targets are published.
case "$target" in
  x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu | x86_64-apple-darwin | aarch64-apple-darwin) ;;
  *) err "no prebuilt binary for ${target}; see ${RELEASES_URL}" ;;
esac

# --- version ----------------------------------------------------------------
version="${FSP_VERSION:-}"
if [ -z "$version" ]; then
  # /releases/latest redirects to /releases/tag/<tag>
  if have curl; then
    latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${RELEASES_URL}/latest") \
      || err "could not look up the latest release; set FSP_VERSION (e.g. v0.3.0)"
  elif have wget; then
    latest_url=$(wget -q -S --spider "${RELEASES_URL}/latest" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1 | tr -d '\r') \
      || true
  else
    err "need curl or wget to download files"
  fi
  version="${latest_url##*/}"
  case "$version" in
    v[0-9]*) ;;
    *) err "could not determine the latest release (got '${version}'); set FSP_VERSION (e.g. v0.3.0)" ;;
  esac
fi
case "$version" in
  v*) ;;
  *) version="v${version}" ;;
esac

# --- download and verify ----------------------------------------------------
archive="fsp-${target}.tar.gz"
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t fsp-install)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Installing fsp ${version} (${target})"
download "${BASE_URL}/${version}/${archive}" "${tmp}/${archive}" \
  || err "could not download ${BASE_URL}/${version}/${archive} (does release ${version} exist?)"
download "${BASE_URL}/${version}/${archive}.sha256" "${tmp}/${archive}.sha256" \
  || err "could not download ${BASE_URL}/${version}/${archive}.sha256"

expected=$(awk '{print $1; exit}' "${tmp}/${archive}.sha256")
[ -n "$expected" ] || err "checksum file for ${archive} is empty"

if have sha256sum; then
  actual=$(sha256sum "${tmp}/${archive}" | awk '{print $1}')
elif have shasum; then
  actual=$(shasum -a 256 "${tmp}/${archive}" | awk '{print $1}')
else
  err "need sha256sum or shasum to verify the download"
fi

if [ "$expected" != "$actual" ]; then
  err "checksum mismatch for ${archive}: expected ${expected}, got ${actual}"
fi

# --- install ----------------------------------------------------------------
tar -xzf "${tmp}/${archive}" -C "$tmp" fsp || err "could not extract fsp from ${archive}"
mkdir -p "$INSTALL_DIR" || err "could not create ${INSTALL_DIR}"
if have install; then
  install -m 755 "${tmp}/fsp" "${INSTALL_DIR}/fsp"
else
  cp "${tmp}/fsp" "${INSTALL_DIR}/fsp"
  chmod 755 "${INSTALL_DIR}/fsp"
fi

say "Installed ${INSTALL_DIR}/fsp"

case ":${PATH:-}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    say ""
    say "${INSTALL_DIR} is not on your PATH. Add it, e.g.:"
    say "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    ;;
esac
