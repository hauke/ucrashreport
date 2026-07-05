// SPDX-License-Identifier: GPL-2.0-only
// Report upload (protocol.md section 3) and device login (section 4).
//
// Uses the uclient-fetch CLI for HTTP for now.
// TODO: switch to the ucode uclient binding to get access to HTTP status
// codes; with the CLI we only see the exit code, so 4xx (drop) vs 5xx
// (retry) is approximated.
'use strict';

import { readfile, writefile, popen, unlink } from 'fs';
import * as spool from 'ucrashreport.spool';
import * as keys from 'ucrashreport.keys';

const MAX_ATTEMPTS = 8;
const CRLF = '\r\n';

function http_post(url, body_path, headers) {
	// no -q: it would suppress uclient-fetch's error messages, and
	// those are the only place the HTTP status code is visible
	let cmd = 'uclient-fetch -O - --timeout=30';

	for (let h in headers)
		cmd += ` --header '${h}'`;

	// stderr goes to the daemon's stderr, which procd forwards to the
	// syslog — silent upload failures are undebuggable in the field
	cmd += ` --post-file='${body_path}' '${url}'`;

	let p = popen(cmd);
	if (!p)
		return null;

	let body = p.read('all');
	let rc = p.close();

	// empty or non-JSON output (failed request) must not throw —
	// an exception here would take down the daemon's event loop
	let parsed = null;
	try {
		if (length(body))
			parsed = json(body);
	} catch (e) {
		warn(`ucrashreportd: unparseable server response\n`);
	}

	return { ok: rc == 0, body: parsed };
}

function build_body(uuid, boundary, path) {
	let m = readfile(`/tmp/ucrashreport/spool/${uuid}/meta.json`);
	let payload = readfile(spool.payload_path(uuid));

	if (!m || payload == null)
		return false;

	let body =
		`--${boundary}${CRLF}` +
		`Content-Disposition: form-data; name="metadata"${CRLF}` +
		`Content-Type: application/json${CRLF}${CRLF}` +
		m + CRLF +
		`--${boundary}${CRLF}` +
		`Content-Disposition: form-data; name="payload"; filename="payload.bin"${CRLF}` +
		`Content-Type: application/octet-stream${CRLF}${CRLF}` +
		payload + CRLF +
		`--${boundary}--${CRLF}`;

	return writefile(path, body) > 0;
}

function attempt(cfg, uuid) {
	let boundary = `ucrashreport-${uuid}`;
	let body_path = `/tmp/ucrashreport/spool/${uuid}/body.tmp`;

	if (!build_body(uuid, boundary, body_path))
		return false;

	let headers = [
		`Content-Type: multipart/form-data; boundary=${boundary}`,
	];

	if (!cfg.anonymous) {
		let sig = keys.sign_file(body_path);
		if (sig) {
			push(headers, `X-UCR-Pubkey: ${keys.pubkey()}`);
			push(headers, `X-UCR-Signature: ${sig}`);
		}
	}

	spool.set_state(uuid, 'uploading');

	let res = http_post(`${cfg.server}/api/v1/reports`, body_path, headers);

	unlink(body_path);

	if (res?.ok && res.body?.report_id) {
		warn(`ucrashreportd: uploaded ${uuid} as ${res.body.report_id}` +
		     `${res.body.view_url ? `, ${res.body.view_url}` : ''}\n`);
		spool.history_add({
			uploaded_at: time(),
			kind: spool.get_meta(uuid)?.kind,
			uuid: uuid,
			report_id: res.body.report_id,
			view_url: res.body.view_url,
		});

		if (cfg.keep_files) {
			spool.set_result(uuid, res.body);
			spool.set_state(uuid, 'uploaded');
		} else {
			// the persistent history is the record; drop the spool
			// entry so /tmp stays clean
			spool.remove(uuid);
		}
		return true;
	}

	warn(`ucrashreportd: upload of ${uuid} to ${cfg.server} failed` +
	     `${res ? ` (rc=${res.ok}, body=${res.body != null})` : ''}, will retry\n`);
	spool.set_state(uuid, 'queued');
	return false;
}

// Try to upload everything in state 'queued'. Returns the number of
// entries still pending (for the caller's retry timer).
export function run_queue(cfg) {
	let pending = 0;

	for (let e in spool.list()) {
		if (e.state != 'queued')
			continue;

		let dir = `/tmp/ucrashreport/spool/${e.uuid}`;
		let attempts = int(readfile(`${dir}/attempts`) ?? '0') + 1;

		if (attempts > MAX_ATTEMPTS) {
			spool.set_state(e.uuid, 'failed');
			continue;
		}

		writefile(`${dir}/attempts`, `${attempts}`);

		if (!attempt(cfg, e.uuid))
			pending++;
	}

	return pending;
};

// Device login: challenge-response, returns the browser URL or null.
export function login_url(cfg) {
	let pubkey = keys.pubkey();

	if (!pubkey)
		return null;

	let tmp = '/tmp/ucrashreport/login.tmp';
	let hdr = [ 'Content-Type: application/json' ];

	writefile(tmp, sprintf('%J', { pubkey }));
	let res = http_post(`${cfg.server}/api/v1/device/challenge`, tmp, hdr);

	if (!res?.ok || !res.body?.nonce)
		return null;

	let sig = keys.sign_msg(b64dec(res.body.nonce));
	if (!sig)
		return null;

	writefile(tmp, sprintf('%J', { pubkey, signature: sig }));
	res = http_post(`${cfg.server}/api/v1/device/login`, tmp, hdr);
	unlink(tmp);

	if (!res?.ok || !res.body?.token)
		return null;

	return `${cfg.server}/my#token=${res.body.token}`;
};
