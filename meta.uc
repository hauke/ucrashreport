// SPDX-License-Identifier: GPL-2.0-only
// Collect report metadata (protocol.md section 1).
'use strict';

import { readfile, popen } from 'fs';

// Parse /etc/os-release style KEY="value" content. Pure function for
// unit testing.
export function parse_os_release(content) {
	let res = {};

	for (let line in split(content ?? '', '\n')) {
		let m = match(line, /^([A-Z0-9_]+)="?([^"]*)"?$/);
		if (m)
			res[m[1]] = m[2];
	}

	return res;
};

// Parse `apk list --installed kernel` output. Returns the full version
// string including the ~buildhash, e.g. "6.12.94~0c91ecae4d...-r1".
// Pure function for unit testing.
export function parse_apk_kernel(content) {
	for (let line in split(content ?? '', '\n')) {
		let m = match(line, /^kernel-([^ ]+) /);
		if (m)
			return m[1];
	}

	return null;
};

function kernel_version() {
	let p = popen('apk list --installed kernel 2>/dev/null');
	let ver;

	if (p) {
		ver = parse_apk_kernel(p.read('all'));
		p.close();
	}

	if (ver)
		return ver;

	// Fallback for self-built images without package metadata. The
	// server detects the missing ~buildhash and skips the symbol
	// cross-check.
	p = popen('uname -r');
	if (p) {
		ver = trim(p.read('all'));
		p.close();
	}

	return ver;
}

// Build the static part of the report metadata. payload_* fields are
// added by the spool when the payload is written.
export function collect(kind, uuid) {
	let osr = parse_os_release(readfile('/etc/os-release'));

	return {
		format: 1,
		kind: kind,
		uuid: uuid,
		captured_at: time(),
		openwrt: {
			version: osr.VERSION ?? 'unknown',
			revision: osr.BUILD_ID ?? 'unknown',
			target: osr.OPENWRT_BOARD ?? 'unknown',
			arch: osr.OPENWRT_ARCH ?? 'unknown',
		},
		board: trim(readfile('/tmp/sysinfo/board_name') ?? 'unknown'),
		kernel: kernel_version() ?? 'unknown',
	};
};
