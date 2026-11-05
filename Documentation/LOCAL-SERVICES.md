# Local sync service recovery

Shelf can use remote services or an existing local Docker stack. For the local
Colima deployment, preserve the `kosync` and `crosspoint-sync` containers and their
volumes; both should use Docker's `unless-stopped` restart policy.

Install the login/recovery job from Terminal:

```sh
python3 Scripts/install-sync-recovery.py
```

It checks the two local HTTP health endpoints every two minutes. Healthy checks
run no Docker commands and produce no log output. If Docker is offline and the
active context is Colima, the job starts Colima. It starts stopped containers,
and restarts a running but unresponsive container only after consecutive failed
checks. Failed recovery backs off to at most one attempt per 15 minutes. It never
recreates containers or deletes volumes. Another Docker runtime must be started
through that runtime's own login settings.

Avoid a duplicate `colima start -f` login service when Colima was already started
outside that foreground process: some versions exit with “already running” and
are relaunched repeatedly by launchd. The Shelf recovery job is sufficient for
this deployment. Remove obsolete login jobs pointing to an uninstalled Docker.app.

Status is stored under the configured state directory in `sync-runtime-health.json`;
recovery actions are in `sync-runtime.log`. This provides recovery while the Mac
is awake and logged in; a sleeping or powered-off Mac cannot serve readers.

Shelf saves its own reader's positions before network publication and retries
pending positions while the app is running. A newer remote timestamp takes
precedence over an older queued local position. The bridge reconciles successful
server updates into Calibre; opening a book alone does not fabricate progress.
