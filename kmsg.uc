// SPDX-License-Identifier: GPL-2.0-only
// Watch /dev/kmsg for kernel oopses/warnings and capture the full splat
// including some preceding context lines.
//
// /dev/kmsg semantics: each read(2) returns exactly one record of the form
//   "<prio>,<seq>,<usec>,<flags>;message"
// with optional continuation lines prefixed by a space.
'use strict';

import { open } from 'fs';
import * as uloop from 'uloop';

const CONTEXT_LINES = 20;
const MAX_LINES = 500;
const QUIET_MS = 2000;

// Patterns that start a capture. WARNINGs only if enabled in config.
const TRIGGER = [
	'Oops',
	'kernel BUG at',
	'Internal error:',
	'Unable to handle kernel',
	'Unhandled fault',
	'BUG:',
];
const TRIGGER_WARN = [ 'WARNING:' ];

// Pattern that ends a capture.
const END_MARKER = '---[ end trace';

let state = {
	file: null,
	handle: null,
	ring: [],		// recent lines for context
	capture: null,		// lines of the capture in progress
	timer: null,		// quiet-period timeout
	triggers: null,
	on_report: null,	// callback(text)
};

function is_match(line, patterns) {
	for (let p in patterns)
		if (index(line, p) >= 0)
			return true;

	return false;
}

function finish() {
	if (!state.capture)
		return;

	let text = join('\n', state.capture) + '\n';

	state.capture = null;
	state.timer?.cancel();
	state.timer = null;

	state.on_report(text);
}

function handle_line(line) {
	if (state.capture) {
		push(state.capture, line);

		if (index(line, END_MARKER) >= 0 ||
		    length(state.capture) >= MAX_LINES) {
			finish();
			return;
		}

		// restart the quiet-period timeout
		state.timer?.set(QUIET_MS);
		return;
	}

	push(state.ring, line);
	while (length(state.ring) > CONTEXT_LINES)
		shift(state.ring);

	if (is_match(line, state.triggers)) {
		// start a capture, seeded with the context ring
		state.capture = [ ...state.ring ];
		state.timer = uloop.timer(QUIET_MS, finish);
	}
}

function handle_record(rec) {
	// strip the "prio,seq,usec,flags;" prefix, keep the message;
	// keep continuation lines (leading space) as-is
	let m = match(rec, /^[0-9]+,[0-9]+,[0-9]+,[^;]*;(.*)$/);

	handle_line(m ? m[1] : rtrim(rec));
}

export function start(cfg, on_report) {
	state.on_report = on_report;
	state.triggers = [ ...TRIGGER ];
	if (cfg.warnings)
		push(state.triggers, ...TRIGGER_WARN);

	state.file = open('/dev/kmsg', 'r');
	if (!state.file)
		return false;

	// only report crashes that happen from now on
	state.file.seek(0, 2);

	// NOTE: relies on uloop dispatching per readable record and on
	// line-buffered reads returning one kmsg record per read(2).
	// Must be validated on target (stdio buffering!); if it does not
	// hold, this needs an unbuffered read path in ucode fs or a tiny
	// C helper.
	state.handle = uloop.handle(state.file, () => {
		let rec = state.file.read('line');
		if (rec != null && rec != '')
			handle_record(rec);
	}, uloop.ULOOP_READ);

	return true;
};

export function stop() {
	state.handle?.delete();
	state.file?.close();
	state.timer?.cancel();
	state = { ring: [], capture: null };
};
