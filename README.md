# FreeOS

A minimal Android TV system based on AOSP (Android 14, tag `android-14.0.0_r75`).

| Path | What it is |
|---|---|
| `manifests/freeos.xml` | FreeOS changes to the AOSP manifest (add/remove projects) |
| `ci/aosp/build.sh` | Syncs AOSP and builds `sdk_atv_x86` (Android TV emulator image) |
| `ci/gcp/setup.sh` | One-time GCP setup: build VM, start/stop service account, GitHub auth |
| `ci/gcp/vm-startup.sh` | Boot script of the build VM (deps, runner, idle auto-poweroff) |
| `.github/workflows/build.yml` | CI: start VM → build → upload image → stop VM |

## CI build (GitHub Actions + GCP)

AOSP is too big for GitHub's hosted runners (~300 GB disk, 64 GB RAM), so the
build runs on a self-hosted runner on a GCP VM that CI starts and stops.
The source, `out/` and ccache stay on a persistent disk, so only the first build
is slow (32 vCPU: roughly 2–3 h; later builds usually under 1 h).

**Cost (approx.):** spot `n2-standard-32` ≈ $0.30–0.45/h while building,
400 GB pd-balanced disk ≈ $40/month whether running or not.

### One-time setup

1. **Runner token:** GitHub → this repo → *Settings → Actions → Runners →
   New self-hosted runner*, copy the token from the `config.sh --token …` line
   (valid for 1 hour).
2. **GCP:** open [Cloud Shell](https://shell.cloud.google.com), select your
   project, then:
   ```bash
   git clone https://github.com/Rolbubx/Free-os && cd Free-os
   RUNNER_TOKEN=<token> bash ci/gcp/setup.sh
   ```
   Optional overrides: `ZONE`, `MACHINE`, `DATA_DISK_GB`, `SPOT=false`.
3. **GitHub variables:** add the five `GCP_*` values the script prints under
   *Settings → Secrets and variables → Actions → Variables*.
4. *Settings → Actions → General → Fork pull request workflows*: require
   approval for all outside collaborators (the runner must never run fork code).
5. Run **Actions → Build FreeOS (AOSP Android TV) → Run workflow**.

Notes:
- GCP free-trial accounts are capped at 8 vCPUs: run setup with
  `MACHINE=n2-highmem-8` there (slower: roughly 6–10 h for the first build).
- Spot VMs can be preempted. If a build dies with "runner lost communication",
  just re-run it; it continues from where it stopped.
- The VM powers itself off after 30 idle minutes. Touch `/aosp/.keep-awake` on
  the VM to prevent that while working over SSH.

## Running the image on Windows

Download the `freeos-<n>` artifact from the workflow run. It contains
`sdk-repo-linux-system-images-*.zip`; extract it into
`%LOCALAPPDATA%\Android\Sdk\system-images\android-34\freeos\` (so the folder
contains `x86\`), then create an AVD with a TV device profile in Android
Studio's Device Manager, or with `avdmanager`, and start it.
