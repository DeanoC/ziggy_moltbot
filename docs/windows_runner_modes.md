# Windows runner modes (SCM service vs user-session runner)

## End-user model

On Windows, ZiggyStarClaw installer/setup presents three **install profiles**:

1) **Pure Client**
   - Installs operator client only
   - No node runner enabled
   - No tray startup task enabled

2) **Service Node**
   - Installs/starts SCM service node runner
   - Installs tray startup task
   - Reliable, limited desktop access

3) **User Session Node**
   - Installs/starts scheduled-task session runner
   - Installs tray startup task
   - Interactive desktop access

For node profiles, node execution still uses **exactly one** of two mutually exclusive runner modes:

1) **Always-on service**
   - Runs as a Windows SCM service (Session 0)
   - **Pros:** reliable, starts without a logged-in user
   - **Cons:** limited desktop access (some interactive capabilities may not work)

2) **User session runner**
   - Runs in the currently logged-in user session
   - Installed as a Scheduled Task (On Logon) that launches a small wrapper/supervisor
   - **Pros:** interactive desktop access (camera/screen/etc)
   - **Cons:** only runs when the user is logged on

The UI and tray app must describe modes by **capabilities**, not by project history (avoid “legacy”).

## Labels (tray)

- Service mode:
  - `Mode: Always-on service (reliable, limited desktop access)`
- Session mode:
  - `Mode: User session runner (interactive desktop access)`
- Misconfiguration:
  - `Mode: ERROR (both enabled) — run: ziggystarclaw-cli node runner install --mode service|session`

## CLI commands

Recommended mode switch command:

```powershell
ziggystarclaw-cli node runner install --mode service
ziggystarclaw-cli node runner install --mode session
```

Supporting commands:

```powershell
ziggystarclaw-cli node profile apply --profile client
ziggystarclaw-cli node profile apply --profile service
ziggystarclaw-cli node profile apply --profile session

ziggystarclaw-cli node runner status
ziggystarclaw-cli node runner start
ziggystarclaw-cli node runner stop

ziggystarclaw-cli node service install|uninstall|start|stop|status
ziggystarclaw-cli node session install|uninstall|start|stop|status
ziggystarclaw-cli tray startup install|uninstall|start|stop|status
```

Client installer-handoff mode:

```powershell
ziggystarclaw-client.exe --install-profile-only
```

This opens just the install profile card in Settings; after profile apply completes, the app exits.

## Migration behavior (mutual exclusion)

The installer/CLI performs best-effort migration so the user ends up with **one active mode**.

### Selecting service mode

When installing the SCM service (via `node service install` or `node runner install --mode service`):

- Stop any user-session Scheduled Task instance (best-effort)
- Delete the Scheduled Task (idempotent)
- Install/update the SCM service

### Selecting session mode

When installing the user-session runner (`node session install` or `node runner install --mode session`):

- Stop + uninstall the SCM service first
- Then install the Scheduled Task (On Logon) wrapper

If the SCM service is installed but cannot be removed due to elevation requirements, the CLI refuses
to proceed (to avoid running two nodes) and prints the exact command to run in an elevated shell.

## Implementation notes

- The session runner Scheduled Task launches:
  - `ziggystarclaw-cli node supervise ...`
  - This wrapper ensures log files are written next to the selected config and exposes a control pipe
    used by the tray app for start/stop.

## Manual test plan (Windows)

1) **Switch to service mode**
   - Install session runner:
     - `ziggystarclaw-cli node session install`
   - Switch to service:
     - `ziggystarclaw-cli node runner install --mode service`
   - Verify:
     - Scheduled Task `ZiggyStarClaw Node` is removed
     - SCM service `ZiggyStarClaw Node` exists and can be started/stopped

2) **Switch to session mode**
   - With service installed, run:
     - `ziggystarclaw-cli node runner install --mode session`
   - Verify:
     - SCM service is uninstalled
     - Scheduled Task exists and running under user session

3) **Conflict detection**
   - Force both service + task to exist (manual) and run tray
   - Verify the tray mode line shows an ERROR and suggests the mode switch command

4) **Tray controls**
   - In service mode: Start/Stop controls SCM service
   - In session mode: Start/Stop controls session runner (pipe when available, Scheduled Task otherwise)
