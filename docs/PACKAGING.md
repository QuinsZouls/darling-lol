# Packaging — installing darling-lol from a release

This document covers the four install formats, the one release asset that installs them
(`darling-lol-install.sh`), what the runtime needs from the host, and how to remove everything again.

One line each, because the rest of the document is the detail:

* **Debian/Ubuntu/Fedora/Arch** — `sudo bash darling-lol-install.sh --version v0.1.2` picks the
  family's package manager.
* **Anything else** — `sudo bash darling-lol-install.sh --version v0.1.2 --method tar` unpacks the
  release tarball under `/usr/local`.
* **Root is required, and there is no flag for it** — see [Installing without root is not
  supported](#installing-without-root-is-not-supported).

## What a release carries

| asset | what it is |
|---|---|
| `darling-lol_<ver>+lol-1_amd64.deb` | the runtime: `darling`, `darlingserver`, `/usr/libexec/darling/**`, the binfmt drop-in. ~589 MB installed |
| `darling-lol-launcher_<ver>+lol-1_all.deb` | `/usr/bin/darling-lol` plus the per-user templates and the Riot tools. Under 1 MB |
| `darling-lol-<ver>-1.lol.fc41.x86_64.rpm`, `darling-lol-launcher-<ver>-1.lol.fc41.noarch.rpm` | the same two packages for Fedora |
| `darling-lol-<ver>-1-x86_64.pkg.tar.zst`, `darling-lol-launcher-<ver>-1-any.pkg.tar.zst` | the same two packages for Arch |
| `darling-lol-<ver>-linux-x86_64.tar.zst`, `...tar.gz` | the runtime as one tree, for a distribution with no package |
| `darling-lol-install.sh` | the installer described here |
| `SHA256SUMS` | one checksum line per asset above |
| `BUILD-INFO-packages.txt` | provenance: the commit, the tag, the cmake line, the payload counts |
| `install.log`, `installed-files.txt`, `BUILD-INFO.txt` | the install manifest and log of the tree |

The two packages are always installed together: the launcher hardcodes `--sdk /usr/libexec/darling`
and `Depends` on the runtime. Nothing on the host should link against Darling's guest libraries, so the
packages deliberately do not declare `Provides`.

## Install matrix

Family and release are detected from `/etc/os-release`, including its `ID_LIKE` field, so
derivatives (SteamOS and EndeavourOS → Arch, Linux Mint and Pop!_OS → Debian, Nobara → Fedora) work
without a per-distribution table.

| family | releases | command | the equivalent, by hand |
|---|---|---|---|
| Debian / Ubuntu | Ubuntu 24.04+ (noble), Debian 12 (bookworm), Debian 13+ | `sudo bash darling-lol-install.sh --version v0.1.2` | `sudo apt-get install ./darling-lol_<ver>+lol-1_amd64.deb ./darling-lol-launcher_<ver>+lol-1_all.deb` |
| Fedora / RHEL family | Fedora 41, RHEL 9 derivatives | same | `sudo dnf install ./darling-lol-<ver>-1.lol.fc41.x86_64.rpm ./darling-lol-launcher-<ver>-1.lol.fc41.noarch.rpm` |
| Arch family | rolling | same | `sudo pacman -U --noconfirm ./darling-lol-<ver>-1-x86_64.pkg.tar.zst ./darling-lol-launcher-<ver>-1-any.pkg.tar.zst` |
| anything else | — | `sudo bash darling-lol-install.sh --version v0.1.2 --method tar` | `sudo tar -xp --numeric-owner --no-same-owner -f darling-lol-<ver>-linux-x86_64.tar.gz -C /` |

`--method auto` (the default) is the first row's command: it detects the family and picks `apt-get`,
`dnf` or `pacman`. Use `--method tar` when the detected distribution has no package, and
`--detect-only` (no root needed) to see what was detected before you commit to an install.

The installer is not the only way in — the packages are ordinary files, and the manual column above is
the same thing with the checksum step and the post-install assertions left to you. What the installer
adds is the part that is easy to get wrong:

1. it verifies `SHA256SUMS` (`sha256sum -c --ignore-missing`) **before** anything is installed;
2. it installs with `apt-get install ./x.deb` rather than a raw unpack, so `Depends` resolve from the
   configured repositories, and it runs `apt-get -f install` as the recovery step;
3. after installing it asserts that what landed is usable: `/usr/bin/darling` is mode `4755` and owned
   by `root:root`, the real `mldr` is present, the guest tree is present, every interpreter named by
   `/usr/lib/binfmt.d/darling.conf` exists, and `darling --help` runs. A package manager's hook can
   fail the transaction; pacman's hooks cannot, which is why this check exists.

`--version` pins the release tag. On the `latest` channel it is optional, and the asset names are read
from the release's own `SHA256SUMS` rather than re-derived, so the installer cannot disagree with the
build about the rpm's `%dist` token or the deb revision.

## Installing without root is not supported

An unprivileged install cannot satisfy the runtime: the prefix is compiled into
`LIBEXEC_PATH`/`INSTALL_PREFIX` (there is no run-time override), so the runtime needs a system tree
(`/usr` for the packages, `/usr/local` for the tarball), and `/usr/bin/darling` must be setuid root
(mode `4755`) because it is the privilege boundary for the mount namespace and the overlayfs; on top of
that, `/usr/lib/binfmt.d/darling.conf` is only read from a system path, so registering the Mach-O
handler is a system-wide change.

Installing without root is not supported, and there is no flag for it. Root is needed for this one
step and nothing else: the container prefix `~/.darling` and the launcher's
`~/.local/share/darling-lol` are created per user by the runtime itself, and `darling-lol` is run as
your normal user afterwards. The decision is recorded in full, with the alternatives that were
measured and the reason they were rejected (cost/benefit, owner ruling 2026-10-16), in appendix §23 of
the packaging plan — read that before proposing a user-mode install.

## Read it before you run it

The installer runs as root and the release is a public URL, so read the script first. The release's
`SHA256SUMS` covers `darling-lol-install.sh` itself:

```sh
VER=v0.1.2
curl -fsSLO "https://github.com/QuinsZouls/darling-lol/releases/download/$VER/darling-lol-install.sh"
curl -fsSLO "https://github.com/QuinsZouls/darling-lol/releases/download/$VER/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS    # verifies the installer; ignores assets you did not fetch
less darling-lol-install.sh                 # the read-it-first step is not a formality
sudo bash darling-lol-install.sh --version "$VER"
```

The one-liner form exists, and it takes the same read-it-first step — the shell it feeds is root's:

```sh
curl -fsSL "https://github.com/QuinsZouls/darling-lol/releases/download/v0.1.2/darling-lol-install.sh" \
  | sudo bash -s -- --version v0.1.2
```

Prefer the download form: `sha256sum -c` can only check a file you actually kept.

## Audio and video (AV wrappers)

The guest's audio/video decode wrappers load `libavcodec.so.60`, i.e. ffmpeg 6.x, through `dlopen`.

* **Ubuntu 24.04 and newer, Debian 13 and newer: fully supported.** They ship the ffmpeg 6.x sonames
  the wrappers load, so video playback works out of the box.
* **Fedora 41 and Debian 12: the packages install and the runtime starts, but the AV wrappers may be
  unavailable.** Fedora 41 ships ffmpeg 7.x (a different soname) and Debian 12's packaging differs in
  the same direction, so the guest wrappers that need ffmpeg 6.x will report a missing library. If the
  client says an AV wrapper is missing, install ffmpeg 6.x compat libraries from a source you trust,
  or run the tarball on an Ubuntu 24.04 host. The runtime does not declare a hard `Requires` on
  ffmpeg: a satisfied dependency that still fails at run time is worse than an honest weak one.

## `Conflicts: darling`

Upstream Darling ships twenty-one packages (`darling`, `darling-core`, `darling-system`, `darling-cli`,
…), and every one of them owns `/usr/bin/darling`, `/usr/bin/darlingserver` and
`/usr/libexec/darling/**` — exactly the paths this runtime owns. Two Darling runtimes cannot coexist on
one host: the conflict is path-level, not stylistic. The packages therefore declare all twenty-one
names in `Conflicts:` (rpm adds `Obsoletes: darling < 999`; Arch uses `conflict=` lines in
`.PKGINFO`), and on the Debian family also `Breaks:`/`Replaces:`, which is what lets `apt` *upgrade* a
machine that already has upstream's Darling instead of stopping with an unresolvable conflict for the
user to untangle. If you have upstream's Darling installed, remove it first — the packages will not
share those paths with it, and they will not silently overwrite them either.

Two packages for one runtime is deliberate: the launcher is `noarch`/`all` and carries the
League-side churn, so it can be updated without re-publishing 90 MB of runtime.

## User state survives removal

`~/.darling` (the container prefix, created on first run, a few minutes' work once) and
`~/.local/share/darling-lol` (the launcher's rendered templates) are **per-user state**. No package
script, and no branch of the installer, reads or deletes them: removing, reinstalling or upgrading the
packages leaves them alone, so a reinstall does not cost you another first run.

To delete that state by hand — only if you want the runtime rebuilt from scratch — it is one line:

```sh
rm -rf ~/.darling ~/.local/share/darling-lol
```

If you have installed the packages *and* an older `/usr/local` tree before, the runtime's own prefix
records which SDK it was created with (`~/.darling/etc/build`). The installer checks that file, reports
a prefix whose SDK no longer exists, and prints the two commands that fix it (`darling destroy`, or the
`rm -rf` above). It never deletes the prefix itself.

## Uninstall

Four commands, one per format. There is no uninstall flag in the installer on purpose: the package
managers already remove exactly the files they own, and a script that deletes trees under `/usr` is a
footgun.

```sh
# Debian / Ubuntu
sudo apt remove darling-lol-launcher darling-lol

# Fedora / RHEL family
sudo dnf remove darling-lol-launcher darling-lol

# Arch family
sudo pacman -R darling-lol-launcher darling-lol

# --method tar (a distribution with no package): the payload is one tree, and the release publishes
# its manifest as installed-files.txt, generated from the same list the build stages. Read the list
# first -- it is what will be deleted:
curl -fsSLO https://github.com/QuinsZouls/darling-lol/releases/download/v0.1.2/installed-files.txt
less installed-files.txt
sudo sh -c 'while IFS= read -r p; do rm -f -- "/usr/local/$p"; done < installed-files.txt'
sudo find /usr/local -mindepth 1 -depth -type d -empty -delete
```

Removing the `.deb` also unregisters the Mach-O binfmt handlers it installed, so a removed package does
not leave the kernel routing Mach-O `execve` calls to a now-deleted `mldr`. Purge (`apt purge`) removes
the generated configuration as well; the user state above is still untouched by both.

## Re-dispatching a tag: assets rebuilt, `.tar.gz` checksum changed

Packages were added to a release that already existed, so the same tag (`v0.1.2`) was dispatched again.
A re-dispatch **rebuilds the tarballs**, so the published `.tar.gz` digest changes even though the
extracted tree is identical: the new archive no longer carries the duplicate directory members and
self-referential hard links of the first one (1 239 and 40 of them, measured), which is a defect worth
fixing. `SHA256SUMS` is republished with the new digests and covers every asset, including this
installer.

**Assets rebuilt, `.tar.gz` checksum changed:** if you pinned the old `.tar.gz` SHA256 by hand you will
see a mismatch, and `SHA256SUMS` — not a memorised hash — is the authority. The `.tar.zst` is new
(built with `zstd -19`, 92.5 MB against the gzip's 145 MB), and the `.deb`, `.rpm`, `.pkg.tar.zst` and
`darling-lol-install.sh` are new with this release.

## Verifying an install

The installer prints these checks when it is done; by hand they are a short list, and worth keeping in a
bug report:

```sh
stat -c '%a %U:%G' /usr/bin/darling          # 4755 root:root -- the setuid bit is load-bearing
ls -l /usr/libexec/darling/usr/libexec/darling/mldr   # the real mldr the binfmt drop-in names
darling --help                                # the CLI runs
dpkg -L darling-lol | head                    # (or: rpm -ql darling-lol, pacman -Ql darling-lol)
darling-lol                                   # as your normal user: renders, then starts the client
```

If a launch fails with a permission error, check the first line before anything else: a lost setuid bit
(mode not `4755`) is the most common cause, and it is exactly what the installer refuses to leave
behind. The first `darling-lol` run asks for your Riot region and builds the per-user prefix — that
takes a few minutes and happens once per user, not once per upgrade. See `docs/TROUBLESHOOTING.md` for
the runtime-side problems, and `docs/SETUP.md` for building from source.
