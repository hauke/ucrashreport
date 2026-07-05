#!/usr/bin/ucode
// SPDX-License-Identifier: GPL-2.0-only
// ucrashreportd — capture kernel crash traces and upload them to a
// ucrashreport-server instance. Strictly opt-in (ucrashreport.settings).
'use strict';

import * as uloop from 'uloop';
import * as libubus from 'ubus';
import { cursor } from 'uci';

import * as spool from 'ucrashreport.spool';
import * as meta from 'ucrashreport.meta';
import * as kmsg from 'ucrashreport.kmsg';
import * as pstore from 'ucrashreport.pstore';
import * as keys from 'ucrashreport.keys';
import * as upload from 'ucrashreport.upload';

const RETRY_MIN_MS = 60 * 1000;
const RETRY_MAX_MS = 6 * 60 * 60 * 1000;

function load_config() {
	let raw = cursor().get_all('ucrashreport', 'settings') ?? {};

	return {
		enabled: int(raw.enabled ?? 0),
		server: rtrim(raw.server ?? '', '/'),
		oops: int(raw.oops ?? 1),
		pstore: int(raw.pstore ?? 1),
		warnings: int(raw.warnings ?? 0),
		review: int(raw.review ?? 0),
		anonymous: int(raw.anonymous ?? 0),
		max_reports_per_day: int(raw.max_reports_per_day ?? 5),
		keep_files: int(raw.keep_files ?? 0),
	};
}

let cfg = load_config();
let retry_ms = RETRY_MIN_MS;
let retry_timer;

if (!cfg.enabled || !cfg.server)
	exit(0);

function kick_uploader() {
	retry_ms = RETRY_MIN_MS;
	retry_timer.set(1);
}

function upload_tick() {
	// exceptions must never escape into the event loop — they would
	// kill the daemon
	try {
		if (upload.run_queue(cfg) > 0) {
			// entries left — retry with backoff
			retry_ms = min(retry_ms * 2, RETRY_MAX_MS);
			retry_timer.set(retry_ms);
		} else {
			retry_ms = RETRY_MIN_MS;
		}
	} catch (e) {
		warn(`ucrashreportd: upload failed: ${e}\n`);
		retry_ms = min(retry_ms * 2, RETRY_MAX_MS);
		retry_timer.set(retry_ms);
	}
}

function submit(kind, payload, encoding) {
	let uuid = spool.create(kind, payload, encoding);

	if (uuid)
		kick_uploader();

	return uuid;
}

uloop.init();

spool.init(cfg);

if (!cfg.anonymous)
	keys.ensure();

retry_timer = uloop.timer(1, upload_tick);
retry_timer.cancel();

if (cfg.pstore)
	pstore.collect(cfg, submit);

if (cfg.oops)
	kmsg.start(cfg, (text) => submit('kernel_oops', text, 'none'));

let ubus = libubus.connect();

ubus.publish('ucrashreport', {
	status: {
		args: {},
		call: function() {
			return {
				enabled: !!cfg.enabled,
				server: cfg.server,
				anonymous: !!cfg.anonymous,
				review: !!cfg.review,
				spool: length(spool.list()),
				uploaded: length(spool.history()),
			};
		},
	},
	list: {
		args: {},
		call: function() {
			return {
				reports: spool.list(),
				uploaded: spool.history(),
			};
		},
	},
	show: {
		args: { uuid: '' },
		call: function(req) {
			let uuid = req.args?.uuid;
			let m = uuid ? spool.get_meta(uuid) : null;

			if (!m)
				return libubus.STATUS_NOT_FOUND;

			return { meta: m, state: spool.get_state(uuid) };
		},
	},
	approve: {
		args: { uuid: '' },
		call: function(req) {
			if (!spool.approve(req.args?.uuid))
				return libubus.STATUS_NOT_FOUND;

			kick_uploader();
			return 0;
		},
	},
	discard: {
		args: { uuid: '' },
		call: function(req) {
			return spool.discard(req.args?.uuid) ?
				0 : libubus.STATUS_NOT_FOUND;
		},
	},
	upload_now: {
		args: {},
		call: function() {
			kick_uploader();
			return 0;
		},
	},
	login_url: {
		args: {},
		call: function() {
			let url = upload.login_url(cfg);

			return url ? { url } : libubus.STATUS_UNKNOWN_ERROR;
		},
	},
	rotate_key: {
		args: {},
		call: function() {
			return keys.rotate() ? 0 : libubus.STATUS_UNKNOWN_ERROR;
		},
	},
});

// retry uploads as soon as a network interface comes up
ubus.listener('network.interface', (type, msg) => {
	if (msg?.action == 'ifup')
		kick_uploader();
});

// anything already queued (pstore) — try right away
kick_uploader();

warn(`ucrashreportd: started, server ${cfg.server}, ` +
     `${length(spool.list())} report(s) spooled\n`);

uloop.run();
