# Mac development setup

This opt-in workflow checks GitHub main every five minutes while you are logged
in. New commits are pulled with a fast-forward merge, tested, built locally, and
opened as **Shelf Dev** in `~/Applications`. It also works without a cloud-to-Mac
SSH connection. Changes must be pushed and merged into GitHub main to reach the
Mac. This is source synchronization, not two-way file synchronization: your local
edits are never uploaded automatically.

## One-time setup on the Mac

Download the setup script and run it in Terminal:

```bash
curl --fail --location https://raw.githubusercontent.com/Somamill/Shelf/main/Scripts/setup-development.sh --output /tmp/shelf-development-setup.sh
bash /tmp/shelf-development-setup.sh
```

The script clones the public repository to `~/Developer/Shelf` if it does not
exist. Existing directories are reused only if they are the expected repository
on a clean main branch. To use another existing checkout, pass its absolute path
to the setup script. Apple Command Line Tools are required; if absent, setup
opens Apple's installer and asks you to rerun after it finishes. Full Xcode is
supported, and the build script also supports Command Line Tools without full
Xcode. Development builds use the checked-in Xcode project, so XcodeGen and
Homebrew are not required. If you edit `project.yml`, regenerate the project
yourself with XcodeGen before building. The first build downloads verified Python and Sparkle
dependencies. No GitHub login, release-signing seed, or Apple signing certificate
is needed for this public repository and ad-hoc development build.

The first build runs in your Terminal. Only after it succeeds does setup register
the user LaunchAgent. Subsequent builds happen in the background and restart
Shelf Dev after successful compilation and signature verification. A failed build
is retried on the next check. The normal Shelf app is left installed and running.
Shelf Dev uses a separate bundle identifier and `shelf-dev:` URL scheme and has
release updates disabled. Both apps currently share Shelf configuration/library
data; avoid making simultaneous library changes from both applications. This
workflow is for trusted changes merged into your own main branch.

## Local development

Open `~/Developer/Shelf` in Codex for Mac or your editor. Automatic sync pauses
when there are uncommitted changes, untracked files, a feature branch, or local
commits ahead of/diverged from GitHub main. It never resets, stashes, pushes,
switches branches, or deletes local work. Finish and merge your work, then return
to a clean main branch to resume. Avoid editing while an automatic build runs;
the worker checks for changes again but cannot lock out your editor.

Build your current local changes manually at any time:

```bash
cd ~/Developer/Shelf
SHELF_DEVELOPMENT_BUILD=1 SHELF_SIGNING_IDENTITY=- SHELF_APPLICATIONS_DIR="$HOME/Applications" bash Scripts/build-and-install.sh
```

To check immediately, or inspect the actual LaunchAgent registration:

```bash
/usr/bin/python3 "$HOME/Library/Application Support/Shelf/Development/development-sync.py" sync --repo "$HOME/Developer/Shelf"
launchctl print "gui/$(id -u)/app.shelf.development-sync"
tail -n 60 "$HOME/Library/Application Support/Shelf/Development/sync.log" "$HOME/Library/Application Support/Shelf/Development/sync-error.log"
```

Stop background syncing without removing your checkout, application, or data:

```bash
/usr/bin/python3 "$HOME/Library/Application Support/Shelf/Development/development-sync.py" stop
```

The stable worker copy lives in that Development directory; rerun setup after
changes to the worker itself. Replacing the app retains one previous development
build as `~/Applications/Shelf Dev.previous.app`. Logs remain local and can be
cleared when sync is stopped. Automatic polling is not an instant update service;
network errors, a sleeping/logged-out Mac, and build failures delay updates.

## Verification boundaries

The automated tests exercise actual local Git repositories: initial build,
fast-forward, no-change checks, dirty/untracked files, unpublished commits,
feature branches, wrong origins, and retry after build failure. macOS CI builds
and verifies the development app's distinct identity and disabled release updater.
LaunchAgent installation and execution on a developer's actual Mac must still be
confirmed there; a cloud build does not establish local installation.
