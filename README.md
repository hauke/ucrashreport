# ucrashreport

Opt-in kernel crash reporting for OpenWrt devices. Captures kernel oopses
from `/dev/kmsg` and post-panic pstore (ramoops) records, and uploads them
to a [ucrashreport-server](https://github.com/openwrt/ucrashreport-server)
instance where they are symbolized, grouped and made available to
developers.

**Status: early development, not yet working end-to-end.**

## Privacy

- Reporting is strictly **opt-in** (`ucrashreport.settings.enabled`,
  default off).
- A report contains: the crash text, OpenWrt version/revision,
  target/arch, board name and the kernel package version. No hostnames,
  no serial numbers, no IP/MAC addresses are collected on purpose.
- Reports are **private by default** on the server; the device owner can
  view their own reports (`ucrashreport login-url`) and may explicitly
  publish a report to get a shareable link, e.g. for a bug report.
- The device identifies itself with a locally generated ed25519 key
  (usign). It is pseudonymous and can be regenerated at any time
  (`ucrashreport rotate-key`). Set `anonymous '1'` to submit without any
  identity (reports cannot be viewed later).
- `review '1'` holds every report locally until approved with
  `ucrashreport approve <uuid>`.

## Components

| file | purpose |
|---|---|
| `ucrashreportd.uc` | daemon: config, ubus API, upload scheduling |
| `kmsg.uc` | /dev/kmsg watcher, oops capture state machine |
| `pstore.uc` | pstore/ramoops record collection after a crash reboot |
| `spool.uc` | report spool + state machine, dedup, rate limit |
| `meta.uc` | version/target/kernel metadata collection |
| `keys.uc` | device key handling (usign) |
| `upload.uc` | multipart upload + challenge-response login |
| `ucrashreport.uc` | CLI |

Runtime dependencies: ucode (fs, uloop, ubus, uci modules),
uclient-fetch, usign, gzip. No C code.

The wire protocol is specified in the server repository:
`docs/protocol.md`.

## Testing

Host-side unit tests (pure parsing functions): `make check`
(set `UCODE=` to a host ucode interpreter).

On-target smoke test for the oops path with CONFIG_LKDTM enabled:

    echo EXCEPTION > /sys/kernel/debug/provoke-crash/DIRECT

For the pstore path on a ramoops-enabled board: `echo c >
/proc/sysrq-trigger`, reboot, check `ucrashreport list`.
