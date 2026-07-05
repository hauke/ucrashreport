// SPDX-License-Identifier: GPL-2.0-only
'use strict';

import { parse_os_release, parse_apk_kernel, parse_kernel_notes } from 'ucrashreport.meta';
import { pack } from 'struct';

let failures = 0;

function check(name, got, want) {
	if (sprintf('%J', got) != sprintf('%J', want)) {
		warn(`FAIL ${name}: got ${got}, want ${want}\n`);
		failures++;
	}
}

const OS_RELEASE = `NAME="OpenWrt"
VERSION="25.12.5"
ID=openwrt
BUILD_ID="r33051-f5dae5ece4"
OPENWRT_BOARD="mediatek/filogic"
OPENWRT_ARCH="aarch64_cortex-a53"
PRETTY_NAME="OpenWrt 25.12.5"
`;

let osr = parse_os_release(OS_RELEASE);
check('version', osr.VERSION, '25.12.5');
check('revision', osr.BUILD_ID, 'r33051-f5dae5ece4');
check('board', osr.OPENWRT_BOARD, 'mediatek/filogic');
check('arch', osr.OPENWRT_ARCH, 'aarch64_cortex-a53');
check('unquoted', osr.ID, 'openwrt');

const APK_OUT = `kernel-6.12.94~0c91ecae4d3d95c948b453b592db96fe-r1 aarch64_generic {kernel} (GPL-2.0) [installed]
`;

check('apk kernel', parse_apk_kernel(APK_OUT),
	'6.12.94~0c91ecae4d3d95c948b453b592db96fe-r1');
check('apk empty', parse_apk_kernel(''), null);
check('osr empty', parse_os_release(null), {});

// ELF notes: a Linux note first (like /sys/kernel/notes has), then the
// GNU build-id note, both with 4-byte padded names/descs
let notes =
	pack('3I', 6, 4, 1) + 'Linux\0\0\0' + '\x00\x00\x00\x00' +
	pack('3I', 4, 20, 3) + 'GNU\0' +
	'\x8d\x74\xef\x44\x13\x9b\x85\x08\xdc\xa9\x2d\x68\x8b\x15\xd2\x40\xc5\x7a\xa8\xef';

check('kernel buildid', parse_kernel_notes(notes),
	'8d74ef44139b8508dca92d688b15d240c57aa8ef');
check('notes empty', parse_kernel_notes(null), null);
check('notes garbage', parse_kernel_notes('short'), null);
check('notes no gnu', parse_kernel_notes(pack('3I', 6, 4, 1) + 'Linux\0\0\0' + 'xxxx'), null);

exit(failures ? 1 : 0);
