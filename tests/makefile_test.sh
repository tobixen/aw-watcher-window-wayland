#!/usr/bin/env bash
# Tests for the Makefile's build, install and service targets.
#
# The Makefile and unit file are copied into a scratch directory, and cargo
# and systemctl are replaced by stubs that log their arguments, so nothing
# here builds, installs into the real system or talks to a systemd manager.
#
# Covered:
# - a bare `make` builds instead of printing the help text;
# - the installed unit's ExecStart is the absolute path the binary was
#   installed to: systemd resolves a bare name only in its fixed search path
#   (/usr/local/bin:/usr/bin), so the default ~/.local install was never found;
# - `sudo make install` neither runs cargo as root nor pokes the system manager
#   about what is a user unit;
# - `sudo make enable-service` refuses instead of running `systemctl --user`
#   as root.

set -u
cd "$(dirname "$0")/.."
. tests/unit_lib.sh

command -v make >/dev/null || { echo "SKIP: make not installed"; exit 77; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

src=$tmpdir/src
log=$tmpdir/calls.log
bin=aw-watcher-window-wayland

mkdir -p "$src" "$tmpdir/stubs"
cp Makefile "$unit" "$src/"
for cmd in cargo systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$cmd" "$log" > "$tmpdir/stubs/$cmd"
    chmod +x "$tmpdir/stubs/$cmd"
done
export PATH="$tmpdir/stubs:$PATH"

fake_build() { mkdir -p "$src/target/release"; printf '#!/bin/sh\n' > "$src/target/release/$bin"; }
# run_make ENV... -- MAKE-ARGS...: run make in the sandbox with a fresh log and
# no inherited SUDO_USER/DESTDIR/PREFIX, so the developer's shell can't leak in.
run_make() {
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    : > "$log"
    env -u SUDO_USER -u DESTDIR -u PREFIX -u RELEASE HOME="$tmpdir/home" "${envs[@]}" \
        make --no-print-directory -C "$src" "$@" > "$tmpdir/out" 2>&1
}
exec_start() { sed -n 's/^ExecStart=//p' "$1"; }

# --- the shipped unit ------------------------------------------------------
case "$(exec_start "$unit")" in
    /*) ok "shipped unit has an absolute ExecStart" ;;
    *) fail "ExecStart in $unit is not an absolute path: $(exec_start "$unit")" ;;
esac

# --- default goal ----------------------------------------------------------
run_make -- -n || fail "bare make -n failed: $(cat "$tmpdir/out")"
grep -q '^cargo build' "$tmpdir/out" || fail "bare make does not build; it ran: $(head -3 "$tmpdir/out")"
ok "bare make builds"

# --- user install ----------------------------------------------------------
fake_build
run_make -- install || fail "make install failed: $(cat "$tmpdir/out")"
grep -q '^cargo build' "$log" || fail "make install did not build first"
installed=$tmpdir/home/.config/systemd/user/$unit
[ -f "$installed" ] || fail "make install did not install $installed"
want=$tmpdir/home/.local/bin/$bin
[ -x "$want" ] || fail "make install did not install $want"
[ "$(exec_start "$installed")" = "$want" ] || fail "installed ExecStart is '$(exec_start "$installed")', want '$want'"
ok "user install points ExecStart at ~/.local/bin"

run_make -- install PREFIX="$tmpdir/opt" || fail "make install PREFIX=... failed: $(cat "$tmpdir/out")"
[ "$(exec_start "$installed")" = "$tmpdir/opt/bin/$bin" ] || fail "with PREFIX set, installed ExecStart is '$(exec_start "$installed")'"
ok "ExecStart follows PREFIX"

# --- sudo install ----------------------------------------------------------
dest=$tmpdir/dest
run_make SUDO_USER=nobody -- install DESTDIR="$dest" || fail "sudo make install failed: $(cat "$tmpdir/out")"
grep -q '^cargo' "$log" && fail "sudo make install ran cargo as root: $(grep '^cargo' "$log")"
ok "sudo make install does not build"
grep -q '^systemctl' "$log" && fail "sudo make install called systemctl: $(grep '^systemctl' "$log")"
ok "sudo make install leaves systemd managers alone"
installed=$dest/usr/local/lib/systemd/user/$unit
[ -f "$installed" ] || fail "sudo make install did not install $installed"
[ -x "$dest/usr/local/bin/$bin" ] || fail "sudo make install did not install the binary under DESTDIR"
[ "$(exec_start "$installed")" = "/usr/local/bin/$bin" ] || fail "sudo-installed ExecStart is '$(exec_start "$installed")', want /usr/local/bin/$bin (no DESTDIR)"
ok "sudo install points ExecStart at /usr/local/bin, without DESTDIR"

rm -rf "$src/target" "$dest"
run_make SUDO_USER=nobody -- install DESTDIR="$dest" && fail "sudo make install succeeded with nothing built"
grep -q '^cargo' "$log" && fail "sudo make install ran cargo as root when nothing was built"
grep -qi 'make install' "$tmpdir/out" || fail "sudo make install without a build gives no hint: $(cat "$tmpdir/out")"
ok "sudo make install without a build fails with a hint"

# --- enable-service under sudo ---------------------------------------------
run_make SUDO_USER=nobody -- enable-service && fail "sudo make enable-service succeeded"
grep -q '^systemctl' "$log" && fail "sudo make enable-service called systemctl as root: $(grep '^systemctl' "$log")"
ok "sudo make enable-service refuses"

echo "PASS"
