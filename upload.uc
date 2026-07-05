// SPDX-License-Identifier: GPL-2.0-only
// Report upload (protocol.md section 3) and device login (section 4).
//
// Uploads use the ucode uclient binding (async, uloop-driven): it
// exposes the HTTP status code, so 4xx (permanent, drop the report)
// can be told apart from 5xx/connect errors (retry with backoff).
'use strict';

import { readfile, writefile, popen, unlink } from 'fs';
import * as uclient from 'uclient';
import * as spool from 'ucrashreport.spool';
import * as keys from 'ucrashreport.keys';

const MAX_ATTEMPTS = 8;
const TIMEOUT_MS = 30 * 1000;
const CRLF = '\r\n';

function build_body(uuid, boundary) {
	let m = readfile(`/tmp/ucrashreport/spool/${uuid}/meta.json`);
	let payload = readfile(spool.payload_path(uuid));

	if (!m || payload == null)
		return null;

	return `--${boundary}${CRLF}` +
		`Content-Disposition: form-data; name="metadata"${CRLF}` +
		`Content-Type: application/json${CRLF}${CRLF}` +
		m + CRLF +
		`--${boundary}${CRLF}` +
		`Content-Disposition: form-data; name="payload"; filename="payload.bin"${CRLF}` +
		`Content-Type: application/octet-stream${CRLF}${CRLF}` +
		payload + CRLF +
		`--${boundary}--${CRLF}`;
}

function upload_done(cfg, uuid, status, body) {
	// permanent rejection: the server will never accept this report,
	// retrying would just burn the quota (protocol.md section 3)
	if (status >= 400 && status < 500) {
		warn(`ucrashreportd: server rejected ${uuid} (HTTP ${status}): ` +
		     `${body ?? ''} - dropping report\n`);
		spool.set_state(uuid, 'failed');
		return true;
	}

	let res = null;
	try {
		if (status == 200 && length(body))
			res = json(body);
	} catch (e) {
		warn(`ucrashreportd: unparseable server response for ${uuid}\n`);
	}

	if (res?.report_id) {
		warn(`ucrashreportd: uploaded ${uuid} as ${res.report_id}` +
		     `${res.view_url ? `, ${res.view_url}` : ''}\n`);
		spool.history_add({
			uploaded_at: time(),
			kind: spool.get_meta(uuid)?.kind,
			uuid: uuid,
			report_id: res.report_id,
			view_url: res.view_url,
		});

		if (cfg.keep_files) {
			spool.set_result(uuid, res);
			spool.set_state(uuid, 'uploaded');
		} else {
			// the persistent history is the record; drop the
			// spool entry so /tmp stays clean
			spool.remove(uuid);
		}
		return true;
	}

	warn(`ucrashreportd: upload of ${uuid} to ${cfg.server} failed ` +
	     `(status ${status}), will retry\n`);
	spool.set_state(uuid, 'queued');
	return false;
}

// Asynchronous upload of one report; calls done(ok) exactly once.
function attempt(cfg, uuid, done) {
	let boundary = `ucrashreport-${uuid}`;
	let body = build_body(uuid, boundary);

	warn(`ucrashreportd: uploading ${uuid} to ${cfg.server}\n`);

	if (body == null) {
		warn(`ucrashreportd: spool entry ${uuid} is unreadable, dropping\n`);
		spool.set_state(uuid, 'failed');
		return done(true);
	}

	let headers = {
		'Content-Type': `multipart/form-data; boundary=${boundary}`,
	};

	if (!cfg.anonymous) {
		// usign signs files: write the body out for signing
		let body_path = `/tmp/ucrashreport/spool/${uuid}/body.tmp`;
		writefile(body_path, body);
		let sig = keys.sign_file(body_path);
		unlink(body_path);

		if (sig) {
			headers['X-UCR-Pubkey'] = keys.pubkey();
			headers['X-UCR-Signature'] = sig;
		}
	}

	spool.set_state(uuid, 'uploading');

	let response = '';
	let finished = false;
	let uc;

	let complete = (status) => {
		if (finished)
			return;
		finished = true;

		let ok = upload_done(cfg, uuid, status, response);

		uc.free();
		done(ok);
	};

	uc = uclient.new(`${cfg.server}/api/v1/reports`, null, {
		data_read: () => {
			let data;
			while (length(data = uc.read()) > 0)
				response += data;
		},
		data_eof: () => complete(uc.status()?.status ?? 0),
		error: (cb, code) => {
			warn(`ucrashreportd: request error ${code} for ${uuid}\n`);
			complete(0);
		},
	});

	if (!uc) {
		warn(`ucrashreportd: uclient.new() failed for ${cfg.server}\n`);
		spool.set_state(uuid, 'queued');
		return done(false);
	}

	uc.set_timeout(TIMEOUT_MS);

	if (index(cfg.server, 'https://') == 0 && !uc.ssl_init({ verify: true })) {
		warn(`ucrashreportd: SSL initialization failed\n`);
		spool.set_state(uuid, 'queued');
		uc.free();
		return done(false);
	}

	if (!uc.connect() ||
	    !uc.request('POST', { headers: headers, post_data: body })) {
		warn(`ucrashreportd: cannot connect to ${cfg.server}\n`);
		spool.set_state(uuid, 'queued');
		uc.free();
		return done(false);
	}
}

// Upload all queued reports, one at a time; calls done(pending) with
// the number of reports that still need a retry.
export function run_queue(cfg, done) {
	let entries = filter(spool.list(), e => e.state == 'queued');
	let pending = 0;
	let idx = 0;

	function next() {
		if (idx >= length(entries))
			return done(pending);

		let e = entries[idx++];
		let dir = `/tmp/ucrashreport/spool/${e.uuid}`;
		let attempts = int(readfile(`${dir}/attempts`) ?? '0') + 1;

		if (attempts > MAX_ATTEMPTS) {
			warn(`ucrashreportd: giving up on ${e.uuid} after ` +
			     `${MAX_ATTEMPTS} attempts\n`);
			spool.set_state(e.uuid, 'failed');
			return next();
		}

		writefile(`${dir}/attempts`, `${attempts}`);

		attempt(cfg, e.uuid, (ok) => {
			if (!ok)
				pending++;
			next();
		});
	}

	next();
};

// Device login: challenge-response, returns the browser URL or null.
// Interactive one-shot (called via ubus from the CLI), so the simple
// blocking uclient-fetch path is fine here.
function post_json(cfg, path, obj) {
	let tmp = '/tmp/ucrashreport/login.tmp';

	writefile(tmp, sprintf('%J', obj));

	let p = popen(`uclient-fetch -O - --timeout=10 ` +
		`--header 'Content-Type: application/json' ` +
		`--post-file='${tmp}' '${cfg.server}${path}'`);
	if (!p)
		return null;

	let body = p.read('all');
	let rc = p.close();

	unlink(tmp);

	try {
		return rc == 0 && length(body) ? json(body) : null;
	} catch (e) {
		return null;
	}
}

export function login_url(cfg) {
	let pubkey = keys.pubkey();

	if (!pubkey)
		return null;

	let res = post_json(cfg, '/api/v1/device/challenge', { pubkey });
	if (!res?.nonce)
		return null;

	let sig = keys.sign_msg(b64dec(res.nonce));
	if (!sig)
		return null;

	res = post_json(cfg, '/api/v1/device/login', { pubkey, signature: sig });
	if (!res?.token)
		return null;

	return `${cfg.server}/my#token=${res.token}`;
};
