// SPDX-License-Identifier: GPL-2.0-only
// Device identity: an ed25519 keypair managed with usign. The public key
// is the device's pseudonymous identity (protocol.md section 2).
'use strict';

import { readfile, writefile, mkdir, unlink, access, mkstemp } from 'fs';

const KEY_DIR = '/etc/ucrashreport';
const SEC_KEY = KEY_DIR + '/key.sec';
const PUB_KEY = KEY_DIR + '/key.pub';

// Extract the base64 blob (second line) from a usign key/sig file.
function blob(content) {
	let lines = split(content ?? '', '\n');

	return length(lines) >= 2 ? trim(lines[1]) : null;
}

export function ensure() {
	if (access(SEC_KEY, 'r'))
		return true;

	mkdir(KEY_DIR, 0o700);

	return system([ 'usign', '-G',
		'-s', SEC_KEY, '-p', PUB_KEY,
		'-c', 'ucrashreport device key' ]) == 0;
};

export function rotate() {
	unlink(SEC_KEY);
	unlink(PUB_KEY);

	return ensure();
};

// base64 public key blob for the X-UCR-Pubkey header
export function pubkey() {
	return blob(readfile(PUB_KEY));
};

// Detached signature over the file at `path`; returns the base64
// signature blob for the X-UCR-Signature header.
export function sign_file(path) {
	let sig_path = `${path}.sig`;

	if (system([ 'usign', '-S', '-m', path,
	             '-s', SEC_KEY, '-x', sig_path ]) != 0)
		return null;

	let sig = blob(readfile(sig_path));

	unlink(sig_path);

	return sig;
};

// Sign a short message (e.g. a login nonce) passed as a string.
export function sign_msg(msg) {
	let tmp = mkstemp('/tmp/ucrashreport-msg-XXXXXX');

	if (!tmp)
		return null;

	tmp.write(msg);
	tmp.flush();

	// mkstemp files are unlinked but still readable via /proc
	let sig = sign_file(`/proc/self/fd/${tmp.fileno()}`);

	tmp.close();

	return sig;
};
