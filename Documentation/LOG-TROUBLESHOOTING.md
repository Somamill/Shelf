# Repairing local automation failures

Shelf's log copy includes historical output. A file updated today can contain
errors from months ago. Keep the logs as evidence and check for a later successful
run of the same job before changing the system. Diagnostic exports include up to
50 distinct recent issues, with repeated messages grouped.

## iCloud access and interrupted file operations

`Operation not permitted` is a macOS privacy/access failure. Reselect the import
folder in Shelf Setup, confirm the folder is downloaded locally in Finder, and
check System Settings → Privacy & Security for access denied to Shelf or the
specific app running the automation. A folder grant to Shelf does not grant
access to a separate launch agent or legacy importer app. Use a local inbox when
background iCloud access remains unavailable. Keep the active Calibre library
local. Do not change file permissions recursively or disable macOS protections.

For interrupted iCloud scans or staging failures, retain the originals, ensure
files are downloaded, and retry the affected job. The legacy importer, malware
guard, duplicate guard, backup, and power-policy scripts under a user's Books
folder are not shipped in this repository; their fixes require inspecting those
scripts and their launch-agent configuration on that Mac.

## Calibre authentication, contention, and timeouts

Shelf's health probe negotiates the server's authentication scheme, including
Digest. A 401 challenge followed by 200 is normal Digest negotiation; repeated
final 401 responses require checking the configured username and saved password.
Do not turn off server authentication. Broken pipes can follow a client timeout;
investigate sustained failures rather than treating every disconnected client as
database damage.

If another Calibre writer is already running, inspect the configured launch agent
and running Calibre processes and keep one server responsible for writes. Do not
delete lock files or terminate unknown processes. Remove obsolete server options
such as `--enable-zeroconf` from the affected local launch configuration after
checking the installed server's `--help`.

The bundled progress bridge gives calibredb 120 seconds and its subprocess 150
seconds. Timed-out writes have an unknown outcome: the next pass reads the current
values before writing again. A completed `BRIDGE END` confirms that pass finished;
unmatched device records still need review and must not be force-matched.

An Xcode-license error from an old agent using Apple's developer Python requires
the Mac owner to review and accept the license, or configure that agent to use an
installed supported Python. Shelf releases include their own Python runtime.

## Antivirus and book validation

Keep import blocked when ClamAV is unavailable. For malformed databases, signature
errors, or `NULL X509 store`, check the installed ClamAV version, trusted CA setup,
and official updater diagnostics. Restore a verified database and run a scan before
retrying import. A successful database update alone does not verify scanning.
Never disable signature checks or the malware gate to make imports succeed.

EPUBCheck errors concern individual book files. Retain originals and validate a
repaired copy before importing it. Conversion success alone does not establish a
valid EPUB. Routine power-policy entries, device scans, and successful backups
are informational and need no repair.
