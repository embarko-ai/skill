# Embarko Deploy — Troubleshooting

Consult this when a deploy fails or an app doesn't come up healthy after a successful API response.
This file covers `POST /apps` specifically. For anything else — rollback, env vars, custom domains,
memory, or the platform's actual constraints (e.g. only `DATA_DIR` survives a redeploy) — see the full
platform reference at `https://embarko.ai/doc` and `https://embarko.ai/troubleshoot`.

## API error codes

Every non-2xx response from `POST /apps` includes a machine-readable `code` field alongside the human-readable `error` — branch on `code`, since `error`'s wording can change without notice. `deploy.sh` prints this automatically on failure.

| `code` | HTTP status | Meaning | Fix |
|---|---|---|---|
| `unauthorized` | 401 | `Authorization` header **present but invalid/revoked**. A **missing** header is never this — that's a valid anonymous deploy | Confirm the token is set correctly and hasn't been rotated/revoked on the dashboard — see `SKILL.md`'s "Required configuration" for both ways to get a token (dashboard or by email) |
| `invalid_app_name` | 400 | `X-App-Name` missing, or doesn't match `^[a-z0-9-]+$` | Use lowercase letters, numbers, and dashes only |
| `app_name_taken` | 409 | This exact app name already belongs to a **different** company | App names are unique platform-wide (they're also the live subdomain) — pick a different name rather than retrying the same one |
| `app_name_check_failed` | 502 | Embarko couldn't verify app-name availability (an internal service was unreachable) | Transient — retry once; if it keeps happening, this is on Embarko's side, not the app |
| `invalid_app_version` | 400 | `X-App-Version` doesn't match `^[a-zA-Z0-9._-]+$` | Use only letters, numbers, dots, dashes, underscores — see Step 2 in `SKILL.md` |
| `missing_source_file` | 400 | No `source` file in the multipart upload | Confirm the tarball is actually attached (`-F "source=@..."`) and the path exists |
| `unsupported_storage_pattern` | 422 | App calls `window.storage`, which doesn't exist outside Claude Artifacts' sandbox | See `SKILL.md`'s "Storage requirements" — switch to SQLite, writing under `DATA_DIR` |
| `deploy_failed` | 500 | The build or Nomad deploy step itself failed — this is a catch-all, not a specific validation issue | Read the response's `details` field for the actual underlying error (e.g. a build tool failure); the symptom table below covers common causes |

No project needs to exist on the dashboard beforehand — the first deploy of a new app name auto-creates it under your company. `app_name_taken` (not a generic failure) is what tells you the name itself is the problem, not your setup.

## Symptom reference

For failures during the actual build/deploy (`code: "deploy_failed"`, or infrastructure-level issues after the API accepted the request):

| Symptom | Likely cause | Fix |
|---|---|---|
| Deploy API returns an error about a missing directory or build path | The build tool was invoked with the version tag in place of the source directory | Ensure the build command's directory argument and the image/version tag are passed as separate, correctly-ordered arguments |
| App fails with an "access denied" / "not found" error when starting, even though the build succeeded | A non-unique or floating version tag (e.g. reusing the same tag across deploys) can cause the orchestrator to look for a fresh copy instead of using the one just built | Always deploy with a unique, explicit version per build |
| Build fails with a permissions error related to the build daemon | The user running the build doesn't have permission to access the build backend | Ensure the deploying user has the necessary local permissions (e.g. group membership for the container runtime) before deploying |
| Job spec fails to parse / deployment config is rejected | A configuration block was malformed (e.g. improperly nested) | Validate the generated deployment configuration before submitting it; use a dry-run/plan step if the platform supports one |
| Deployment "succeeds" per the API, but the app isn't reachable | The API only confirms the job was accepted, not that it started successfully | Always run the verification step (Step 4) — check job status and hit the returned URL directly before reporting success |
| App is reachable via direct/internal address but not via its public URL | Routing layer isn't configured for that app's port/route, or DNS hasn't propagated | Confirm the routing configuration includes the app's entrypoint; confirm DNS resolves to the expected address |
| Public URL resolves to an unexpected address | Some dynamic-DNS-style services can misparse hostnames that end in a digit adjacent to the embedded address | Ensure the app name and the address portion of the generated hostname are separated by a non-numeric label |
| Deployment stuck in a failed/retry loop | Application-level crash on startup, or leftover state from a previous failed deployment blocking a clean retry | Check application logs for the startup error; if the platform supports it, purge/reset the previous failed deployment before retrying |
| Same parse error persists after a config fix is applied | A stale duplicate process is still bound to the API's port and serving the old code — restarting/reloading a process manager entry can silently leave an old instance running under a different name/ID | List every process bound to the port directly (not just by expected name) and terminate all of them before starting a single clean instance |
| Deploy API itself becomes unreachable (connection times out, not refused) after a routing/domain change | A firewall rule for the new port wasn't added, or DNS hasn't propagated yet | Confirm DNS resolves to the expected address; confirm the port is open in the firewall; test locally on the server (bypassing DNS/firewall) before assuming the routing layer is broken |
| Deploy API returns 422 "Unsupported storage pattern detected" | App calls `window.storage`, an API specific to Claude Artifacts' sandbox that doesn't exist on Embarko | Replace `window.storage` calls with SQLite (`better-sqlite3`), writing under `DATA_DIR`, then redeploy — see `SKILL.md`'s Storage requirements section |
| App keeps restarting and eventually gets marked failed; task events show "OOM Killed" (exit code 137) | The app exceeded its memory allocation — apps using an embedded database need more memory than a plain app, and the default allocation may not account for other memory-heavy dependencies | Memory is auto-detected based on whether the app declares an embedded-database dependency (gets a higher allocation automatically). If an app is OOM-killed despite this, it likely has some other heavy dependency the auto-detection doesn't account for — check actual usage via the deployment's resource utilization stats and request a higher allocation explicitly |
| `curl` to `ship.embarko.ai` fails with a DNS/connection error (refused, timed out, "could not resolve host") — **not** an HTTP response of any status | The agent is running in a network-sandboxed environment (common for browser/cloud-based AI coding tools — e.g. Claude's cloud sandbox: Cowork, Claude Code on the web, skills with code execution) whose outbound domain allowlist doesn't include Embarko's domains by default | Self-check, don't just report failure: (1) confirm this is a connection-level failure, not a real HTTP 4xx/5xx — those are normal API errors, not a network block. (2) If it is a connection failure: check for a network/domain allowlist setting in your own environment and add `embarko.ai`, `ship.embarko.ai`, and `*.app.embarko.ai` yourself if you can. **In Claude specifically**, this is an org-admin setting at *Organization settings → Capabilities → domain allowlist* — Team/Enterprise orgs default to "package managers only", which is commonly the actual cause; changing it only applies to **new** conversations, not the current one. (3) If you can't change that setting yourself (it's usually an org-admin decision, not something an individual session can self-serve around), tell the person exactly which three domains need allowlisting and that exact settings path — don't silently give up or retry blindly. (4) Either way, mention the fallback: the same deploy command works unchanged from any environment with normal network access (the person's own machine, or a non-sandboxed agent). `scripts/deploy.sh` makes this check deterministic — it probes connectivity before packaging anything, rather than failing mid-deploy. Agents with full local/machine network access (e.g. a local terminal-based agent) don't hit this at all |
| Data an app wrote (uploads, a SQLite file, analytics/A-B-test results) is gone after a redeploy — sometimes the app also crashes with `ENOENT` on startup | Every redeploy schedules a fresh container from a fresh image — nothing outside `DATA_DIR` survives that, ever, even though nothing looks wrong at deploy time | This isn't a bug — read/write anything that must survive a redeploy under `path.join(process.env.DATA_DIR, ...)`, creating subdirectories with `{recursive: true}` on startup rather than assuming they exist. See `https://embarko.ai/troubleshoot` for the full explanation |

## Escalation

If the issue isn't covered above, gather the following before requesting support:
- The exact API response from the deploy call
- Application logs from the most recent deployment attempt
- The generated deployment configuration (if inspectable)