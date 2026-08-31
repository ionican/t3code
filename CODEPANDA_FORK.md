# T3 Code Auto

This branch is a local, co-installable T3 Code fork for two-account Claude
quota failover. It stays close to `upstream/main` and carries two changes:

1. `thread.turn.start` accepts `onlyIfSettled`. The server evaluates the guard
   against its authoritative projection before it emits a message or starts a
   turn, so an automated retry cannot replace newer user work.
2. The desktop app has its own identity and storage:
   - application: `T3 Code Auto`
   - bundle ID: `com.codepanda.t3code-auto`
   - URL schemes: `t3code-auto` and `t3code-auto-dev`
   - backend state: `~/.t3-auto`
   - Electron user data: `~/Library/Application Support/t3code-auto`
   - background service: `com.codepanda.t3code-auto.service`

Automatic updates are disabled by default. Local builds use a `-pr.` version,
which also prevents electron-builder from embedding an update feed. The
official T3 Code app and `~/.t3` are not modified.

## Updating from upstream

Run `scripts/codepanda-update-fork.sh` from a terminal after quitting T3 Code
Auto. It fetches `upstream/main`, merges into a temporary candidate worktree,
runs the focused tests and package typechecks, builds an unsigned Apple Silicon
DMG, verifies the bundle/storage/update invariants, backs up the installed fork
and its state, then promotes the candidate and installs it. Any conflict,
failed check or identity mismatch stops before the installed app is changed.

The update is intentionally manual: an upstream database migration can make a
downgrade unsafe, so the command refuses to run while T3 Code Auto is open and
takes a consistent state backup before installation.
