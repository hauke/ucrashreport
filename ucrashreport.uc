#!/usr/bin/ucode
// SPDX-License-Identifier: GPL-2.0-only
// ucrashreport CLI — thin wrapper around the ucrashreportd ubus API.
'use strict';

import * as libubus from 'ubus';

const USAGE = `Usage: ucrashreport <command> [args]

Commands:
  status                show daemon status
  list                  list spooled/uploaded reports
  show <uuid>           show one report's metadata
  approve <uuid>        queue a pending-review report for upload
  discard <uuid>        drop a report
  upload-now            trigger an immediate upload attempt
  login-url             print the URL to view this device's reports
  rotate-key            generate a new device key
`;

const COMMANDS = {
	'status':     { method: 'status' },
	'list':       { method: 'list' },
	'show':       { method: 'show', uuid: true },
	'approve':    { method: 'approve', uuid: true },
	'discard':    { method: 'discard', uuid: true },
	'upload-now': { method: 'upload_now' },
	'login-url':  { method: 'login_url' },
	'rotate-key': { method: 'rotate_key' },
};

let cmd = COMMANDS[ARGV[0]];

if (!cmd) {
	warn(USAGE);
	exit(1);
}

let args = {};

if (cmd.uuid) {
	if (!ARGV[1]) {
		warn(USAGE);
		exit(1);
	}
	args.uuid = ARGV[1];
}

let conn = libubus.connect();
let res = conn.call('ucrashreport', cmd.method, args);

if (res == null && conn.error()) {
	warn(`ucrashreport: ${conn.error()} (is the service enabled and running?)\n`);
	exit(1);
}

if (type(res) == 'object')
	print(sprintf('%.J\n', res));
else
	print('ok\n');
