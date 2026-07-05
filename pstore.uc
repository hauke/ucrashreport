// SPDX-License-Identifier: GPL-2.0-only
// Collect crash records left in pstore (ramoops/efi-pstore) by a previous
// kernel panic. Runs once at daemon start.
//
// Record naming: dmesg-<backend>-<id>[.enc.z], where multi-part crashes
// use several ids. Compressed records (.enc.z, zlib deflate) are uploaded
// verbatim with payload_encoding=zlib and decompressed on the server.
'use strict';

import { lsdir, readfile, unlink } from 'fs';

const PSTORE_DIR = '/sys/fs/pstore';

export function collect(cfg, submit) {
	let files = lsdir(PSTORE_DIR);

	if (!length(files)) {
		// pstore might simply not be mounted yet
		system(`mount -t pstore pstore ${PSTORE_DIR} 2>/dev/null`);
		files = lsdir(PSTORE_DIR);
	}

	if (!length(files))
		return 0;

	let reports = 0;

	// Plain-text dmesg records of one crash are concatenated into a
	// single report, newest part last (higher id = earlier output).
	// TODO: verify part ordering against a real multi-part ramoops
	// record; backends differ.
	let plain = sort(filter(files, f => match(f, /^dmesg-.*[0-9]+$/)));
	let compressed = filter(files, f => match(f, /^dmesg-.*\.enc\.z$/));

	if (length(plain)) {
		let text = '';

		for (let f in reverse(plain))
			text += readfile(`${PSTORE_DIR}/${f}`) ?? '';

		if (submit('pstore', text, 'none'))
			reports++;
	}

	// Compressed records: one report per record, decompressed
	// server-side.
	for (let f in compressed) {
		let data = readfile(`${PSTORE_DIR}/${f}`);

		if (data && submit('pstore', data, 'zlib'))
			reports++;
	}

	// Free the pstore slots so the next crash can be recorded —
	// unless we are debugging (spool dedup prevents re-reporting).
	if (!cfg.keep_files)
		for (let f in [ ...plain, ...compressed ])
			unlink(`${PSTORE_DIR}/${f}`);

	return reports;
};
