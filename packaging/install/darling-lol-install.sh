#!/usr/bin/env bash
# darling-lol-install.sh -- install the Darling runtime and the darling-lol launcher.
#
# PLAN §16. This file IS the release asset `darling-lol-install.sh`: it is published next to the
# packages and the tarballs, and the release's SHA256SUMS covers it, so the installer itself can be
# verified before it is run:
#
#   curl -fsSLO https://github.com/QuinsZouls/darling-lol/releases/latest/download/darling-lol-install.sh
#   curl -fsSLO https://github.com/QuinsZouls/darling-lol/releases/latest/download/SHA256SUMS
#   sha256sum -c --ignore-missing SHA256SUMS     # verifies this file, ignores what you did not fetch
#   less darling-lol-install.sh                  # read it first -- the next line runs it as root
#   sudo bash darling-lol-install.sh --version v0.1.2
#
# The script is deliberately boring. Outside coreutils and tar it needs at most one of
# curl/wget for the download and one of apt-get/dnf/pacman for the install -- everything else is
# bash builtins. It installs the same assets the packages are published as, verifies the checksums,
# installs with the family's package manager, and then asserts that what landed is actually usable
# (setuid 4755, the real mldr, the guest tree, every binfmt interpreter, `darling --help`).
#
# Non-root users are refused up front (§16.2.1): /usr/bin/darling must be setuid root, the runtime's
# prefix is compiled in, and the binfmt drop-in is only read from a system path. See
# docs/PACKAGING.md for what that means for you (nothing else in the runtime is privileged: the
# container prefix ~/.darling and the launcher's ~/.local/share/darling-lol are per-user).
set -eu

ORIG_ARGS="$*"                       # captured BEFORE parsing, so require_root can echo the sudo line

RELEASE_BASE=https://github.com/QuinsZouls/darling-lol/releases

METHOD=auto
DRY=0
DETECT_ONLY=0
ASSET_DIR=""
VERSION=""
CHANNEL=stable
NO_VERIFY=0
PREFIX=/usr
PREFIX_SET=0
RUNTIME_ASSET=
LAUNCHER_ASSET=
TARBALL=
# The tarball path's own record of what it unpacked (R2/MAJOR-1). It is NOT a package-owned path:
# the payload is the /usr tree, and no package owns anything under /var/lib/darling-lol. The
# documented removal recipe reads this file; cmake's installed-files.txt cannot be used for it
# (39 007 absolute /usr/local lines from a different tree, 165 real paths missing).
STATE_FILE=/var/lib/darling-lol/tar-installed-files.txt

# --- helpers -------------------------------------------------------------------------------------
# Only four verbs, so the script reads the same way everywhere: say/err go to the log, warn does not
# stop anything, die stops everything.
say()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "error: $*" >&2; }
warn() { printf '%s\n' "warning: $*" >&2; }
die()  { printf '%s\n' "darling-lol-install.sh: $*" >&2; exit 1; }

need() {  # need ASSET -- the file must already be in $ASSET_DIR
  [ -f "$ASSET_DIR/$1" ] || die "missing asset $ASSET_DIR/$1
       It is listed in the release's SHA256SUMS. Download it from
         $RELEASE_BASE
       or point --asset-dir at a directory that holds the release assets."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' is not installed"
}

apt_get() {
  # One wrapper, every apt-get call site: DEBIAN_FRONTEND is mandatory for a script, and the
  # recovery call in install_pkg is the one that is easy to forget it on.
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

usage() {
  cat <<'EOF'
darling-lol-install.sh -- install the Darling runtime and the darling-lol launcher (x86_64).

Usage:
  sudo bash darling-lol-install.sh [options]

Options:
  --method auto|apt|dnf|pacman|tar  how to install. auto (the default) picks the family's
                                    package manager from /etc/os-release; tar unpacks the release
                                    tarball into /usr for a distribution with no package.
  --version TAG                     the release to install, e.g. --version v0.1.2 (required on the
                                    stable channel).
  --channel stable|latest           where the assets come from (default: stable).
  --prefix DIR                      where --method tar unpacks. Only /usr is accepted: the
                                    install prefix is compiled into the runtime and cannot move.
  --asset-dir DIR                   install from assets already downloaded into DIR. Nothing is
                                    fetched; SHA256SUMS is still verified.
  --no-verify                       skip SHA256SUMS verification. NOT recommended -- say it out
                                    loud, and never in a documented example.
  --dry-run                         check the machine, print what would be done, then stop. Still
                                    needs root: a dry run that hides the root precondition would
                                    tell you something false about your machine.
  --detect-only                     print the detected family and release, then stop. Needs no
                                    root -- it only reads /etc/os-release.
  -h, --help                        this text. Needs no root.

Installing without root is not supported: see docs/PACKAGING.md.

Read it before you run it:
  curl -fsSLO https://github.com/QuinsZouls/darling-lol/releases/latest/download/darling-lol-install.sh
  less darling-lol-install.sh
  sudo bash darling-lol-install.sh --version v0.1.2

Verified installs (a supported distribution, then the tarball fallback):
  sudo bash darling-lol-install.sh --version v0.1.2
  sudo bash darling-lol-install.sh --version v0.1.2 --method tar

The install matrix, the uninstall commands and the audio/video caveat live in docs/PACKAGING.md.
EOF
}

# --- §16.2.1 the global root gate ----------------------------------------------------------------
require_root() {
  # EUID, not `id -u`: this script is bash (the shebang says so) and EUID is a bash builtin
  # variable, so it costs no fork and cannot be spoofed by a PATH trick on `id`.
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then return 0; fi

  cat >&2 <<EOF
darling-lol-install.sh: this installer needs root, and you are $(id -un) (uid ${EUID:-$(id -u)}).

Nothing has been downloaded, unpacked or modified.

Why root is required -- two concrete reasons, not habit:
  1. /usr/bin/darling is installed setuid root (mode 4755). The runtime creates a mount
     namespace and an overlayfs; that is the privilege boundary, and a package manager will
     not set a setuid bit for a non-root user.
  2. /usr/lib/binfmt.d/darling.conf is only read from a system path, so registering the
     Mach-O handler is a system-wide change.

Re-run with:
    sudo bash $0 $ORIG_ARGS

Installing without root is not supported, and there is no flag for it: the runtime needs a system
prefix (/usr, compiled in) and a setuid-root /usr/bin/darling, and neither can be provided per
user. See docs/PACKAGING.md.

Everything the runtime CREATES is already per-user and needs no root: the container prefix is
~/.darling and the launcher renders into ~/.local/share/darling-lol. Only this install step is
privileged -- you run 'darling-lol' as yourself afterwards.
EOF
  exit 1
}

# --- §16.2 step 3: architecture ------------------------------------------------------------------
detect_arch() {
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) ARCH=x86_64 ;;
    *) die "this release ships x86_64 assets only, and this machine is '$arch'.
       Build from source instead: see docs/PACKAGING.md" ;;
  esac
  say "detected: $arch -> $ARCH"
}

# --- §16.3 distro detection (real code) ----------------------------------------------------------
detect_distro() {
  # OS_RELEASE_FIXTURE is the test seam for G-INSTALL-2b: it lets the detection be exercised
  # against the seven fixtures without touching /etc/os-release. It is not documented in --help:
  # it is a gate input, not a user-facing option.
  osrel=/etc/os-release
  [ -n "${OS_RELEASE_FIXTURE:-}" ] && osrel=$OS_RELEASE_FIXTURE
  [ -r "$osrel" ] || die "cannot read $osrel; use --method tar"
  # 🚨 /etc/os-release defines VERSION (e.g. "24.04.5 LTS (Noble Numbat)") and NAME, so
  # sourcing it clobbers the CLI's --version -- the value that names the release to download.
  # Measured before this pair of lines existed (as root, in ubuntu:24.04):
  #   --version v0.1.2 --dry-run  =>  assets would come from
  #   https://github.com/QuinsZouls/darling-lol/releases/download/24.04.5 LTS (Noble Numbat)
  # and the "required on the stable channel" guard in release_url_base() never fired, because the
  # clobbered value is non-empty. --detect-only cannot see this: it exits before the URL is built.
  cli_version=$VERSION
  # shellcheck disable=SC1090,SC1091  # the file is /etc/os-release, or the gate's fixture for it
  . "$osrel"
  VERSION=$cli_version
  DISTRO_ID=${ID:-unknown}
  DISTRO_VER=${VERSION_ID:-0}
  DISTRO_LIKE=${ID_LIKE:-}

  case "$DISTRO_ID" in
    ubuntu)  FAMILY=deb;  RELEASE=$(ubuntu_codename "${DISTRO_VER}") ;;
    debian)  FAMILY=deb;  RELEASE=${VERSION_CODENAME:-bookworm} ;;
    fedora)  FAMILY=rpm;  RELEASE="fc${DISTRO_VER%%.*}" ;;
    rhel|centos|rocky|almalinux) FAMILY=rpm; RELEASE="el${DISTRO_VER%%.*}" ;;
    opensuse*|sles|sled)   FAMILY=rpm; RELEASE="openSUSE" ;;
    arch|manjaro|endeavouros|garuda) FAMILY=arch; RELEASE=rolling ;;
    *)
      # ID_LIKE fallback: steamos -> arch, linuxmint -> ubuntu, nobara -> fedora
      # 🚨 the Arch token is *arch*, NOT the distribution's own ID string: no derivative sets
      # that one (Arch itself sets no ID_LIKE at all) and the stricter pattern made the SteamOS
      # fixture die -- the plan's single most important target (EVIDENCE C24, §7.6).
      case " $DISTRO_LIKE " in
        *arch*)  FAMILY=arch; RELEASE=rolling ;;
        # A Debian derivative (linuxmint, pop, ...): the .deb's Depends list is codename-specific,
        # so use the UBUNTU_CODENAME the derivative's own os-release records (Mint 22 => noble).
        # 🚨 NOT ubuntu_codename "$DISTRO_VER": a derivative's VERSION_ID is ITS version (22), not
        # the Ubuntu one, and 22%%.* -> jammy would name the wrong Depends list (review NIT-2).
        *ubuntu*)          FAMILY=deb; RELEASE=${UBUNTU_CODENAME:-bookworm} ;;
        *debian*)          FAMILY=deb; RELEASE=bookworm ;;
        *rhel*|*fedora*)   FAMILY=rpm; RELEASE="fc41" ;;
        *) die "unsupported distribution '$DISTRO_ID' (ID_LIKE='$DISTRO_LIKE').
       Use: $0 --method tar   (portable install into --prefix, default /usr)" ;;
      esac ;;
  esac
  say "detected: $DISTRO_ID $DISTRO_VER -> family=$FAMILY release=$RELEASE"
}

ubuntu_codename() {   # VERSION_ID -> codename, because the .deb Depends list is codename-specific
  case "${1%%.*}" in
    22) echo jammy ;;  24) echo noble ;;  25) echo questing ;;  26) echo "noble" ;;
    *)  echo noble ;;  # unknown future LTS: noble is the closest supported baseline
  esac
}

# --- method, prefix, assets ----------------------------------------------------------------------
resolve_method() {
  case "$METHOD" in
    auto)
      case "$FAMILY" in
        deb)  METHOD=apt ;;
        rpm)  METHOD=dnf ;;
        arch) METHOD=pacman ;;
        *)    die "no package manager for family '$FAMILY'; use --method tar" ;;
      esac ;;
    apt|dnf|pacman)
      # A mismatch is not a preference: an .rpm cannot install on Debian, and the tool the user
      # named is not the one this family has. Say which one is right, and always offer tar.
      case "$FAMILY" in
        deb)  [ "$METHOD" = apt ]    || die "--method $METHOD on a deb-family distribution: use --method apt (or --method tar)" ;;
        rpm)  [ "$METHOD" = dnf ]    || die "--method $METHOD on an rpm-family distribution: use --method dnf (or --method tar)" ;;
        arch) [ "$METHOD" = pacman ] || die "--method $METHOD on an Arch-family distribution: use --method pacman (or --method tar)" ;;
      esac ;;
    tar) : ;;
    *) die "unknown --method '$METHOD' (auto|apt|dnf|pacman|tar)" ;;
  esac
  say "method: $METHOD"
}

resolve_prefix() {
  if [ "$METHOD" = tar ]; then return 0; fi
  # The package installs to /usr: LIBEXEC_PATH/INSTALL_PREFIX are compile-time strings, so the
  # prefix is not a choice the installer can make. Accepting --prefix here and then asserting
  # against the wrong tree is how a green "installed" turns into a broken runtime.
  if [ "$PREFIX_SET" = 1 ] && [ "$PREFIX" != /usr ]; then
    die "--prefix is only meaningful with --method tar: the packages install to /usr and the
       runtime's prefix is compiled in. See docs/PACKAGING.md"
  fi
  PREFIX=/usr
}

release_url_base() {
  case "$CHANNEL" in
    stable)
      [ -n "$VERSION" ] || die "--version is required on the stable channel (e.g. --version v0.1.2)"
      printf '%s/download/%s\n' "$RELEASE_BASE" "$VERSION" ;;
    latest)
      printf '%s/latest/download\n' "$RELEASE_BASE" ;;
    *) die "unknown --channel '$CHANNEL' (stable|latest)" ;;
  esac
}

fetch() {  # fetch NAME... -- curl or wget, one asset at a time, into $ASSET_DIR
  base=$(release_url_base)
  for name in "$@"; do
    if [ -f "$ASSET_DIR/$name" ]; then
      say "already downloaded: $name"
      continue
    fi
    say "downloading $base/$name"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 -o "$ASSET_DIR/$name" "$base/$name" \
        || die "download failed: $base/$name"
    elif command -v wget >/dev/null 2>&1; then
      wget -q --tries=3 -O "$ASSET_DIR/$name" "$base/$name" \
        || die "download failed: $base/$name"
    else
      die "need curl or wget to download the release assets (or use --asset-dir)"
    fi
  done
}

sha_names() {  # the bare asset names SHA256SUMS lists, in order
  while read -r _hash name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$name"
  done < "$ASSET_DIR/SHA256SUMS"
}

name_for() {  # name_for PATTERN -- the one SHA256SUMS entry matching PATTERN, or die
  pat=$1
  found=0
  pick=
  while IFS= read -r name; do
    # shellcheck disable=SC2053  # $pat IS a glob: that is how "the rpm for this release" is said
    if [[ "$name" == $pat ]]; then
      found=$((found + 1))
      pick=$name
    fi
  done < <(sha_names)
  case "$found" in
    0) die "SHA256SUMS lists no asset matching '$pat'" ;;
    1) printf '%s\n' "$pick" ;;
    *) die "SHA256SUMS lists $found assets matching '$pat': download a clean release directory" ;;
  esac
}

assets_for_method() {  # the names to download for the resolved method
  case "$METHOD" in
    apt)    printf '%s\n' "$(name_for 'darling-lol_*.deb')" \
                           "$(name_for 'darling-lol-launcher_*.deb')" ;;
    dnf)    printf '%s\n' "$(name_for 'darling-lol-*.x86_64.rpm')" \
                           "$(name_for 'darling-lol-launcher-*.noarch.rpm')" ;;
    pacman) printf '%s\n' "$(name_for 'darling-lol-*-x86_64.pkg.tar.zst')" \
                           "$(name_for 'darling-lol-launcher-*-any.pkg.tar.zst')" ;;
    tar)    printf '%s\n' "$(name_for 'darling-lol-*-linux-x86_64.tar.gz')" ;;
  esac
}

collect_asset() {  # collect_asset PATTERN -- ASSET_MATCHES gets the files matching it
  ASSET_MATCHES=()
  for path in "$ASSET_DIR"/$1; do
    [ -f "$path" ] || continue
    ASSET_MATCHES+=("$path")
  done
}

ambiguous_asset() {  # ambiguous_asset PATTERN -- more than one candidate is a refusal, never a toss
  # Same policy name_for() applies to SHA256SUMS. Measured with a --asset-dir holding two runtime
  # packages: the earlier "warn and use the first match" made the tar path pick whichever
  # *.tar.gz the glob listed first -- in a real release directory that can be
  # darling-lol-linux-x86_64-<ver>-runtime-artifacts.tar.gz, i.e. a tree that is not the runtime.
  die "$ASSET_DIR holds ${#ASSET_MATCHES[@]} files matching '$1':
       ${ASSET_MATCHES[*]}
       Point --asset-dir at one release's assets: its SHA256SUMS lists exactly one per format."
}

pick_asset() {  # pick_asset PATTERN -- the single file matching PATTERN; absent or ambiguous is fatal
  collect_asset "$1"
  [ "${#ASSET_MATCHES[@]}" -gt 0 ] || die "no asset matching '$1' in $ASSET_DIR
       Download it from $RELEASE_BASE (it is listed in the release's SHA256SUMS), or point
       --asset-dir at a complete download."
  [ "${#ASSET_MATCHES[@]}" -eq 1 ] || ambiguous_asset "$1"
  printf '%s\n' "${ASSET_MATCHES[0]}"
}

resolve_assets() {
  if [ -n "$ASSET_DIR" ]; then
    [ -d "$ASSET_DIR" ] || die "--asset-dir '$ASSET_DIR' is not a directory"
    say "using the assets already in $ASSET_DIR; nothing will be downloaded"
  else
    # One private scratch directory under $TMPDIR, removed on exit. This runs after require_root,
    # so a refused run creates nothing at all -- which is exactly what G-INSTALL-7 asserts.
    ASSET_DIR=$(mktemp -d "${TMPDIR:-/tmp}/darling-lol-install.XXXXXX")
    # shellcheck disable=SC2064  # expand $ASSET_DIR now: the trap must name THIS run's directory.
    trap "rm -rf '$ASSET_DIR'" EXIT INT TERM
    # SHA256SUMS first and always: it is mandatory in verify_checksums, and it is also the list we
    # download from -- the asset names carry the rpm's %dist token and the deb's revision, so
    # re-deriving them here would be a second, drifting source of truth.
    fetch SHA256SUMS
    # shellcheck disable=SC2046  # the substitution is a word list of bare asset names, by design.
    fetch $(assets_for_method)
  fi

  # Resolve the paths we install from by pattern: identical for a release download and for a
  # --asset-dir tree, and it cannot disagree with the version in the file names.
  case "$METHOD" in
    apt)    RUNTIME_ASSET=$(pick_asset 'darling-lol_*.deb')
            LAUNCHER_ASSET=$(pick_asset 'darling-lol-launcher_*.deb') ;;
    dnf)    RUNTIME_ASSET=$(pick_asset 'darling-lol-*.x86_64.rpm')
            LAUNCHER_ASSET=$(pick_asset 'darling-lol-launcher-*.noarch.rpm') ;;
    pacman) RUNTIME_ASSET=$(pick_asset 'darling-lol-*-x86_64.pkg.tar.zst')
            LAUNCHER_ASSET=$(pick_asset 'darling-lol-launcher-*-any.pkg.tar.zst') ;;
    tar)    tar_in ;;
  esac
}

tar_in() {  # set TARBALL from $ASSET_DIR: .tar.gz first, and never guess between candidates
  # .tar.gz first: GNU tar auto-detects gzip everywhere, zstd only since 1.31.
  # 🚨 the matching below runs in THIS shell on purpose: inside `$(...)` a `die` only kills the
  # subshell, and a `||` chain would then carry on to the next pattern. An ambiguous directory has
  # to stop the install, not be worked around by it.
  for pat in 'darling-lol-*-linux-x86_64.tar.gz' 'darling-lol-*-linux-x86_64.tar.zst' \
             '*.tar.gz' '*.tar.zst'; do
    collect_asset "$pat"
    [ "${#ASSET_MATCHES[@]}" -eq 0 ] && continue
    [ "${#ASSET_MATCHES[@]}" -eq 1 ] || ambiguous_asset "$pat"
    TARBALL=${ASSET_MATCHES[0]}
    # 🚨 R1: the generic `*.tar.gz`/`*.tar.zst` fallback is what would otherwise hand the installer
    # the v0.1.0-era pair -- darling-lol-linux-x86_64-<desc>-base-runtime.tar.gz and
    # -runtime-artifacts.tar.gz -- and those are /usr/local trees. Refuse them BY NAME, so the
    # outcome is a clean refusal and never a /usr/local tree extracted into a /usr install.
    case "${TARBALL##*/}" in
      darling-lol-linux-x86_64-*-base-runtime.tar.*|darling-lol-linux-x86_64-*-runtime-artifacts.tar.*)
        die "$ASSET_DIR holds the legacy /usr/local pair, not the /usr tree this installer installs
       (darling-lol-<ver>-linux-x86_64.tar.gz). Nothing was extracted." ;;
    esac
    return 0
  done
  die "no tarball in $ASSET_DIR (expected darling-lol-<ver>-linux-x86_64.tar.gz)"
}

# --- §16.4 checksum verification (mandatory) -----------------------------------------------------
verify_checksums() {
  [ "$NO_VERIFY" = 1 ] && { warn "--no-verify: skipping checksum validation"; return 0; }
  need SHA256SUMS
  need_cmd sha256sum
  # -c against the whole list; only the files we actually downloaded are checked.
  ( cd "$ASSET_DIR" && sha256sum -c --ignore-missing --quiet SHA256SUMS ) \
    || die "checksum verification FAILED. Do not install this download.
       Expected file: $ASSET_DIR/SHA256SUMS
       Re-download, or verify against the release page:
         https://github.com/QuinsZouls/darling-lol/releases/tag/$VERSION"
  say "checksums OK"
}

# --- §16.2 step 7: pre-flight --------------------------------------------------------------------
sdk_recorded_in() {  # sdk_recorded_in FILE -- the SDK path the per-user prefix records, or nothing
  sed -n 's/^[[:space:]]*SDK=//p' "$1" 2>/dev/null | head -1
}

preflight() {
  # R13: a ~/.darling created by an earlier tree records its SDK in etc/build -- the v0.1.0-era
  # tarball records /usr/local/libexec/darling, the /usr tree (packages and the current tarball)
  # records /usr/libexec/darling. When that path no longer exists the installed runtime and the
  # prefix disagree, and the failure ("the container will not start") is a confusing one two
  # hours later. Detect it, print the
  # recovery command, and touch nothing: the prefix is the user's, not the installer's.
  for home in $(state_homes); do
    build=$home/.darling/etc/build
    [ -r "$build" ] || continue
    sdk=$(sdk_recorded_in "$build")
    [ -n "$sdk" ] || continue
    [ -e "$sdk" ] && continue
    warn "the per-user container prefix $home/.darling was created with a runtime that is no longer
       installed: $build records SDK=$sdk, which does not exist.
       Nothing was deleted. After installing, recreate the prefix as your normal user:
         darling destroy            # rebuild it from the installed runtime
       or, by hand:
         rm -rf $home/.darling"
  done
}

state_homes() {
  # The state that matters belongs to the invoking user, not to root: `sudo ./install.sh` runs
  # with SUDO_USER set, and ~/.darling is that user's tree.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    case "$SUDO_USER" in
      # `~user` is expanded by bash from the password database: no fork, no getent.
      *[!A-Za-z0-9_.-]*) : ;;
      *) eval "printf '%s\n' ~$SUDO_USER" ;;
    esac
  fi
  printf '%s\n' "${HOME:-/root}"
}

# --- §16.5 install + the post-install assertion (the part that actually matters) -----------------
install_pkg() {
  case "$METHOD" in
    apt)
      need_cmd apt-get
      # apt-get install ./x.deb resolves Depends from the configured repos; a raw dpkg unpack does
      # not. EVIDENCE C14 measured the failure mode: the unpack alone leaves the package in state
      # 'iU' and names every unsatisfied dependency, and `apt-get -f install` recovers.
      apt_get install -y "$RUNTIME_ASSET" "$LAUNCHER_ASSET" \
        || { say "apt reported dependency problems; attempting 'apt-get -f install'"; \
             apt_get -f install -y || die "dependency resolution failed (see above)."; }
      ;;
    dnf)
      need_cmd dnf
      dnf install -y "$RUNTIME_ASSET" "$LAUNCHER_ASSET"
      ;;
    pacman)
      need_cmd pacman
      pacman -U --noconfirm "$RUNTIME_ASSET" "$LAUNCHER_ASSET"
      ;;
    tar)  install_tar ;;
  esac
  assert_install
}

# The package managers' own hooks already assert this (PLAN 9.4 / 10.1 / 11.3), but pacman hooks
# CANNOT fail the transaction, and a user may have installed with --no-verify or by hand. So the
# installer re-asserts, once, for every family. This is the single most valuable check in the
# script: EVIDENCE C3 shows how easily the setuid bit disappears without anyone noticing.
assert_install() {
  sdk="$PREFIX/libexec/darling"
  fail=0
  m=$(stat -c '%a' "$PREFIX/bin/darling" 2>/dev/null || echo missing)
  [ "$m" = 4755 ] || { err "$PREFIX/bin/darling is mode $m, expected 4755 (setuid root)"; fail=1; }
  own=$(stat -c '%U:%G' "$PREFIX/bin/darling" 2>/dev/null || echo missing)
  [ "$own" = root:root ] || { err "$PREFIX/bin/darling is owned by $own, expected root:root"; fail=1; }
  [ -x "$sdk/usr/libexec/darling/mldr" ] || { err "the real mldr is missing at $sdk/usr/libexec/darling/mldr"; fail=1; }
  [ -d "$sdk/System" ] || { err "the guest tree is missing ($sdk/System)"; fail=1; }
  if [ -r "$PREFIX/lib/binfmt.d/darling.conf" ]; then
    while IFS= read -r line; do
      i=$(printf '%s' "$line" | awk -F: '{print $7}'); [ -n "$i" ] || continue
      [ -x "$i" ] || { err "binfmt handler points at a missing interpreter: $i"; fail=1; }
    done < "$PREFIX/lib/binfmt.d/darling.conf"
  fi
  if command -v darling >/dev/null 2>&1; then
    darling --help >/dev/null 2>&1 || { err "'darling --help' failed"; fail=1; }
  else
    err "darling(1) is not on PATH after install"; fail=1
  fi
  [ "$fail" = 0 ] || die "post-install verification FAILED. The package installed but the runtime
       is not usable. Please open an issue with the output above and
       $(command -v dpkg >/dev/null && echo "'dpkg -L darling-lol'")
       $(command -v rpm  >/dev/null && echo "'rpm -ql darling-lol'")
       $(command -v pacman >/dev/null && echo "'pacman -Ql darling-lol'")"
  say "post-install verification OK (setuid 4755, mldr, guest tree, binfmt, darling --help)"
}

# --- §16.6 the tarball fallback ------------------------------------------------------------------
# The tar path's prefix, in ONE place. --dry-run announces the prefix of the selected method, and
# install_tar() writes into it; before T10b's mutation battery these were two independent statements
# (the global `PREFIX=/usr` default that --dry-run printed, and install_tar's own `${PREFIX:-/usr}`)
# which agreed only by accident. Mutating one of them left the gate's prefix cross-check green --
# `mx_prefix_usrlocal` in run-mutations.sh. Both callers now go through set_tar_prefix().
set_tar_prefix() {  # sets $PREFIX for --method tar: /usr, the prefix compiled in (LIBEXEC_PATH)
  PREFIX=${PREFIX:-/usr}
  [ "$PREFIX" = /usr ] || die "--prefix with --method tar must be /usr: the runtime's install
       prefix is compiled in (LIBEXEC_PATH=/usr/libexec/darling). A relocated tree extracts
       cleanly and then fails at mount(\"overlay\")."
}

install_tar() {
  # The release tarball IS the /usr tree (D1, owner ruling R1 of the T10b review, 2026-10-17):
  # packaging/common/build-tar.sh builds darling-lol-<ver>-linux-x86_64.tar.gz/.tar.zst with
  # `-C "$pkg/root" -T files.all.rel` over the SAME staged tree as the packages, so its members
  # are usr/bin/darling, usr/libexec/darling, usr/lib/darling-lol, usr/lib/binfmt.d/... -- and
  # the archive's own gate asserts usr/bin/darling as -rwsr-xr-x (build-tar.sh's check_archive).
  # PREFIX is therefore /usr, the prefix compiled in (LIBEXEC_PATH) and the prefix of the asset
  # the glob above resolves. It is NOT /usr/local: only the v0.1.0-era
  # darling-lol-linux-x86_64-<ver>-base-runtime.tar.gz pair is a /usr/local tree, and that name
  # does not match anything in tar_in(). The cross-check below makes a future divergence fail
  # BEFORE anything is extracted.
  set_tar_prefix
  need_cmd tar
  # busybox tar has no --preserve-permissions (measured: 'unrecognized option'), and without it
  # the setuid bit is silently dropped (EVIDENCE C3). Detect and refuse.
  tar --help 2>&1 | grep -q -- '--preserve-permissions' \
    || die "your tar does not support --preserve-permissions (busybox?). Install GNU tar."
  # Root was already required globally (§16.2.1 require_root, step 2). This is a belt-and-braces
  # re-assert because the tarball path is the only one that writes WITHOUT a package manager in
  # between: if require_root is ever moved after asset resolution, this is what still stops a
  # non-root `tar -xp -C /` from half-extracting until it hits a permission error.
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "the tarball install must run as root (it sets setuid root on
       $PREFIX/bin/darling). Re-run with sudo. See docs/PACKAGING.md for why there is no
       rootless mode."
  # The prefix this function demands must be the prefix of the asset it is about to unpack (info
  # INFO-4 / ruling R6). One line of membership check turns the old failure mode -- ~589 MB of
  # setuid tree extracted into /usr and THEN a failed assert_install against /usr/local -- into a
  # clean refusal. The member list is sorted, so head -1 is stable; the two known trees are
  # /usr (packages + the current tarball) and /usr/local (the v0.1.0-era pair).
  first=$(tar -tf "$TARBALL" | head -1)
  case "$first" in
    usr/local/*) archive_prefix=/usr/local ;;
    usr/*)       archive_prefix=/usr ;;
    *)           archive_prefix="/${first%%/*}" ;;
  esac
  [ "$archive_prefix" = "$PREFIX" ] || die "$TARBALL is a $archive_prefix tree and --method tar
       installs $PREFIX. The tarball this installer selects is the /usr tree
       (darling-lol-<ver>-linux-x86_64.tar.gz); the /usr/local pair is the v0.1.0-era
       -base-runtime/-runtime-artifacts asset, which this installer never picks. Nothing was
       extracted."
  # df names the tree that is actually written: the extraction is `-C /`, so what has to hold the
  # space is the filesystem that carries $PREFIX (MENOR-1 of the review).
  free_kb=$(df -Pk "$PREFIX" | awk 'NR==2{print $4}')
  case "$free_kb" in
    ''|*[!0-9]*) die "cannot determine the free space on the filesystem that holds $PREFIX (df gave '$free_kb')" ;;
  esac
  [ "$free_kb" -gt 1500000 ] || die "need ~1.5 GB free on the filesystem that holds $PREFIX, have $((free_kb/1024)) MB"

  # Refuse to mix a tarball install with a package install. Under R1's ruling this is a PATH-LEVEL
  # collision in /usr, not two disjoint trees: the tar install writes the paths the packages own.
  # The guard is one-way by construction (a package manager only sees its own database), so the
  # reverse order is detected with the same database at the file level -- `dpkg -S /usr/bin/darling`
  # (or `rpm -qf` / `pacman -Qo`) names the owner, and after a tar install it names nothing. That
  # command is printed in docs/PACKAGING.md next to the removal recipe.
  if command -v dpkg >/dev/null && dpkg -s darling-lol >/dev/null 2>&1; then
    die "the darling-lol .deb is already installed. Remove it first: sudo apt remove darling-lol"
  fi
  # The symmetric probe: an earlier tarball install is recorded in our own state file. Re-extracting
  # over it is idempotent, so this is a message, not a refusal.
  [ -e "$STATE_FILE" ] && say "a previous --method tar install is recorded in $STATE_FILE; re-extracting over it"

  say "extracting to $PREFIX (this preserves setuid; ~589 MB)"
  tar -xp --numeric-owner --no-same-owner -f "$TARBALL" -C /

  # R2/MAJOR-1: record EXACTLY the members we unpacked, so the documented removal does not have to
  # trust cmake's installed-files.txt (39 007 absolute /usr/local lines from another tree, with
  # 165 real paths missing). Absolute paths, one member per line, no prefixing on removal. Written
  # after a successful extract and only by this path: --dry-run never reaches install_tar.
  mkdir -p "${STATE_FILE%/*}"
  tar -tf "$TARBALL" | sed 's|/$||; s|^/*|/|' > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  say "recorded $(wc -l < "$STATE_FILE" | tr -d ' ') unpacked members in $STATE_FILE"
}

# --- §16.7 per-user launcher step -----------------------------------------------------------------
launcher_step() {
  if [ -x /usr/bin/darling-lol ]; then
    cat <<EOF

Next step (as your normal user, NOT root):
    darling-lol

That renders the launcher into ~/.local/share/darling-lol, creates the per-user container
prefix at ~/.darling on first run (a few minutes), then starts the Riot client. You will be
asked for your Riot region.
EOF
  else
    # The /usr tarball carries the same launcher payload as the package (usr/bin/darling-lol), so
    # this is only reached by a tree without it; name the path that tree uses (R1: /usr, not the
    # legacy /usr/local pair).
    cat <<EOF

Next step (as your normal user, NOT root):
    /usr/bin/darling-lol
EOF
  fi
}

# --- §16.2 step 11: next steps --------------------------------------------------------------------
next_steps() {
  cat <<EOF

First run: 'darling-lol' asks for your Riot region, then prepares the per-user prefix
(~/.darling, ~/.local/share/darling-lol). That takes a few minutes the first time; it is a
one-off cost per user, and it needs no root.

Before you launch: the runtime is pinned to League of Legends, so make sure the client's
region matches the account you play with.

To remove the packages again, and to remove the per-user state, see docs/PACKAGING.md. There is
no uninstall flag on purpose: the package managers do it correctly, and this script owning a
delete over /usr would be a footgun.
EOF
}

# --- §16.2 steps 1, 1b, 2, 3..11 -- the dispatch --------------------------------------------------
# ---- step 1: parse. There is no rootless branch and there must not be one: the installer is
#               system-wide by design (§16.2.1, and §23 for the discarded alternative).
while [ $# -gt 0 ]; do
  case "$1" in
    --method)      METHOD=$2;      shift 2;;
    --version)     VERSION=$2;     shift 2;;
    --channel)     CHANNEL=$2;     shift 2;;
    --prefix)      PREFIX=$2;      PREFIX_SET=1; shift 2;;
    --asset-dir)   ASSET_DIR=$2;   shift 2;;
    --dry-run)     DRY=1;          shift;;
    --no-verify)   NO_VERIFY=1;    shift;;
    --detect-only) DETECT_ONLY=1;  shift;;
    -h|--help)     usage; exit 0;;                      # step 1b: unprivileged exit #1
    *) die "unknown option '$1' (try --help)";;          # ← any unknown flag dies here
  esac
done

# ---- step 1b: read-only detection stays usable unprivileged (this is G-INSTALL-2's entry point).
if [ "$DETECT_ONLY" = 1 ]; then detect_distro; exit 0; fi   # unprivileged exit #2

# ---- step 2: the global root gate. ONE exception set (--help, --detect-only) and nothing else.
#      🚨 --dry-run does NOT bypass it (C25): a dry run that hides the script's own precondition
#      lies to the user, and it made G-INSTALL-7 vacuous because the harness passes --dry-run.
require_root

# ---- steps 3..11
detect_arch
detect_distro
resolve_method
resolve_prefix
if [ "$DRY" = 1 ]; then
  # The root precondition has been checked above, which is the point of a dry run; everything
  # below this line writes or fetches, so the dry run stops here and says what would happen.
  base=$(release_url_base)
  # 🚨 The announced prefix must be the prefix the selected method will actually write into
  # (single source: set_tar_prefix). Cheap here, and it turns a --prefix the tar path cannot honour
  # into a dry-run refusal instead of an announcement the install would contradict.
  if [ "$METHOD" = tar ]; then set_tar_prefix; fi
  say "dry run: nothing has been fetched, unpacked or modified."
  say "dry run: family=$FAMILY release=$RELEASE method=$METHOD prefix=$PREFIX"
  say "dry run: assets would come from $base"
  # --no-verify has a consumer in verify_checksums(), which the dry run never reaches: without
  # this line the flag would be silent in the one mode where the user is deciding.
  [ "$NO_VERIFY" = 1 ] && say "dry run: --no-verify is set: the checksums would NOT be verified."
  say "dry run: re-run without --dry-run to install."
  exit 0
fi
resolve_assets
verify_checksums
preflight
install_pkg
launcher_step
next_steps
