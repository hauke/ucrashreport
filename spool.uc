// SPDX-License-Identifier: GPL-2.0-only
// Report spool with state machine:
//   captured -> pending-review -> queued -> uploading -> uploaded
//                                        \-> failed
// Entries live in /tmp: they do not survive a reboot, which is fine —
// crashes that take the system down are recovered via pstore.
'use strict';

import { readfile, writefile, popen, mkdir, lsdir, stat, unlink, rmdir } from 'fs';
import * as meta from 'ucrashreport.meta';

const BASE_DIR = '/tmp/ucrashreport';
const SPOOL_DIR = BASE_DIR + '/spool';
const SEEN_FILE = BASE_DIR + '/seen';
const QUOTA_FILE = BASE_DIR + '/quota';

// history of successfully uploaded reports; persistent (and kept
// across sysupgrade) because the spool in /tmp dies with the reboot
// that a crash typically causes
const HISTORY_FILE = '/etc/ucrashreport/uploads.log';

const MAX_ENTRIES = 16;
const MAX_SEEN = 50;
const MAX_HISTORY = 50;

let config = {};

export const STATES = [
	'captured', 'pending-review', 'queued',
	'uploading', 'uploaded', 'failed'
];

export function init(cfg) {
	config = cfg;
	mkdir(BASE_DIR, 0o700);
	mkdir(SPOOL_DIR, 0o700);
};

function gen_uuid() {
	return trim(readfile('/proc/sys/kernel/random/uuid'));
}

function sha256_file(path) {
	let p = popen(`sha256sum ${path}`);
	if (!p)
		return null;

	let out = p.read('all');
	p.close();

	return match(out, /^([0-9a-f]{64})/)?.[1];
}

// Dedup: remember hashes of recently reported payloads so a repeating
// oops or re-read pstore records (keep_files=1) are reported only once.
function seen(hash) {
	let list = split(readfile(SEEN_FILE) ?? '', '\n');

	if (hash in list)
		return true;

	push(list, hash);
	while (length(list) > MAX_SEEN)
		shift(list);

	writefile(SEEN_FILE, join('\n', list));

	return false;
}

function quota_exceeded() {
	let today = sprintf('%d', time() / 86400);
	let cur = split(readfile(QUOTA_FILE) ?? '', ' ');
	let count = (cur[0] == today) ? int(cur[1]) : 0;

	if (count >= int(config.max_reports_per_day ?? 5))
		return true;

	writefile(QUOTA_FILE, `${today} ${count + 1}`);

	return false;
}

export function get_state(uuid) {
	return trim(readfile(`${SPOOL_DIR}/${uuid}/state`) ?? '');
};

export function set_state(uuid, state) {
	assert(state in STATES, `invalid state ${state}`);
	writefile(`${SPOOL_DIR}/${uuid}/state`, state);
};

export function get_meta(uuid) {
	return json(readfile(`${SPOOL_DIR}/${uuid}/meta.json`) ?? 'null');
};

export function payload_path(uuid) {
	return `${SPOOL_DIR}/${uuid}/payload.bin`;
};

export function list() {
	let res = [];

	for (let uuid in (lsdir(SPOOL_DIR) ?? [])) {
		let m = get_meta(uuid);
		if (!m)
			continue;
		push(res, {
			uuid: uuid,
			kind: m.kind,
			captured_at: m.captured_at,
			state: get_state(uuid),
			result: json(readfile(`${SPOOL_DIR}/${uuid}/result.json`) ?? 'null'),
		});
	}

	return sort(res, (a, b) => a.captured_at - b.captured_at);
};

export function remove(uuid) {
	let dir = `${SPOOL_DIR}/${uuid}`;

	for (let f in (lsdir(dir) ?? []))
		unlink(`${dir}/${f}`);
	rmdir(dir);
};

function prune() {
	let entries = list();
	let removable = filter(entries, e => e.state in ['uploaded', 'failed']);

	// oldest first, done entries before anything else
	for (let e in [...removable, ...entries]) {
		if (length(list()) < MAX_ENTRIES)
			break;
		if (!config.keep_files)
			remove(e.uuid);
	}
}

// Create a new spool entry from a raw payload string.
// encoding: 'none' (we gzip it here) or a pre-encoded format such as
// 'zlib' for compressed pstore records stored verbatim.
export function create(kind, payload, encoding) {
	// dedup on the raw payload
	let tmp = `${BASE_DIR}/dedup.tmp`;
	writefile(tmp, payload);
	let hash = sha256_file(tmp);
	unlink(tmp);

	if (!hash || seen(hash))
		return null;

	if (quota_exceeded())
		return null;

	prune();

	let uuid = gen_uuid();
	let dir = `${SPOOL_DIR}/${uuid}`;
	let m = meta.collect(kind, uuid);

	mkdir(dir, 0o700);

	if (encoding == null || encoding == 'none') {
		let gz = popen(`gzip -c > ${dir}/payload.bin`, 'w');
		gz.write(payload);
		gz.close();
		m.payload_encoding = 'gzip';
	} else {
		writefile(`${dir}/payload.bin`, payload);
		m.payload_encoding = encoding;
	}

	m.payload_sha256 = sha256_file(`${dir}/payload.bin`);

	writefile(`${dir}/meta.json`, sprintf('%J', m));
	set_state(uuid, 'captured');
	set_state(uuid, config.review ? 'pending-review' : 'queued');

	return uuid;
};

export function approve(uuid) {
	if (get_state(uuid) != 'pending-review')
		return false;
	set_state(uuid, 'queued');
	return true;
};

export function discard(uuid) {
	if (config.keep_files)
		set_state(uuid, 'failed');
	else
		remove(uuid);
	return true;
};

export function set_result(uuid, result) {
	writefile(`${SPOOL_DIR}/${uuid}/result.json`, sprintf('%J', result));
};

// One JSON object per line, newest last, capped at MAX_HISTORY.
export function history_add(entry) {
	mkdir('/etc/ucrashreport', 0o700);

	let lines = filter(split(readfile(HISTORY_FILE) ?? '', '\n'),
	                   l => length(l));

	push(lines, sprintf('%J', entry));
	while (length(lines) > MAX_HISTORY)
		shift(lines);

	writefile(HISTORY_FILE, join('\n', lines) + '\n');
};

export function history() {
	let res = [];

	for (let line in split(readfile(HISTORY_FILE) ?? '', '\n')) {
		if (!length(line))
			continue;
		try {
			push(res, json(line));
		} catch (e) {
			// skip corrupt lines
		}
	}

	return res;
};
