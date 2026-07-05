// SPDX-License-Identifier: GPL-2.0-only
// Collect report metadata (protocol.md section 1).
'use strict';

import { readfile, popen } from 'fs';
import { unpack } from 'struct';

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

// Extract the GNU build-id from an ELF note blob such as
// /sys/kernel/notes. Note format: namesz/descsz/type (3x u32 native
// endian), name (padded to 4), desc (padded to 4). Pure function for
// unit testing; returns lowercase hex or null.
export function parse_kernel_notes(data) {
	if (!data)
		return null;

	let len = length(data);
	let off = 0;

	while (off + 12 <= len) {
		let hdr = unpack('3I', substr(data, off, 12));
		let namesz = hdr[0], descsz = hdr[1], type = hdr[2];

		if (namesz > 256 || descsz > 4096)
			return null;

		let name = rtrim(substr(data, off + 12, namesz), '\0');
		let desc_off = off + 12 + ((namesz + 3) & ~3);

		if (desc_off + descsz > len)
			return null;

		// NT_GNU_BUILD_ID == 3
		if (name == 'GNU' && type == 3)
			return hexenc(substr(data, desc_off, descsz));

		off = desc_off + ((descsz + 3) & ~3);
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
	let buildid = parse_kernel_notes(readfile('/sys/kernel/notes'));

	let meta = {
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

	// lets the server verify fetched debug symbols match this kernel
	if (buildid)
		meta.kernel_buildid = buildid;

	return meta;
};
