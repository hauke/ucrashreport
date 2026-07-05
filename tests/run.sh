#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Run host-side unit tests. Needs a host ucode interpreter; override with
# UCODE=/path/to/ucode. Extra module search paths (e.g. an out-of-tree
# fs.so) can be passed via UCODE_FLAGS='-L /path/*.so'.
set -e

UCODE="${UCODE:-ucode}"
TESTDIR="$(dirname "$0")"
REPODIR="$(dirname "$TESTDIR")"

# make modules importable as 'ucrashreport.<name>'
LINKDIR="$(mktemp -d)"
trap 'rm -rf "$LINKDIR"' EXIT
ln -s "$(cd "$REPODIR" && pwd)" "$LINKDIR/ucrashreport"

rc=0
for t in "$TESTDIR"/test_*.uc; do
	# subshell with globbing off: -L arguments are path templates and
	# must reach ucode unexpanded (UCODE_FLAGS is intentionally split)
	# shellcheck disable=SC2086
	if (set -f; exec "$UCODE" $UCODE_FLAGS -L "$LINKDIR/*.uc" "$t"); then
		echo "PASS: $t"
	else
		echo "FAIL: $t"
		rc=1
	fi
done
exit $rc
