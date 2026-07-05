// SPDX-License-Identifier: GPL-2.0-only
'use strict';

import { parse_os_release, parse_apk_kernel } from 'ucrashreport.meta';

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

exit(failures ? 1 : 0);
