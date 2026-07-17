<!-- GENERATED from scanbox:scripts/deploy/README_DEPLOY.md — do not edit here; publish with scripts/deploy/publish_bootstrap.sh -->
# scanbox-deploy

Public deploy entry point for the **private** [`Alkaronyan/scanbox`](https://github.com/Alkaronyan/scanbox)
subsystem. This repo holds `bootstrap.sh` — anyone with the deploy passphrase
can run it to provision a device — and this README, the operator's guide.

## Provision or update a device (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/Alkaronyan/scanbox-deploy/main/bootstrap.sh | bash
```

Run it on the device (Raspberry Pi OS Lite 64-bit, network up). The same
command is also the update path — re-running it updates the device in place;
there is no separate upgrade procedure.

What happens, in order: it installs the minimal tools (`git`, `age`), shows a
passphrase hint and asks for the passphrase (**the only prompt there will ever
be, and only on the very first provision** — later runs read a token sealed to
the device and ask for nothing), decrypts a **read-only, single-repo** clone
token in memory, clones the private repo, and hands off to its `deploy.sh`,
which installs Docker, provisions the host (kernel headers, USB-gadget
services, the patched `usb_f_uvc` kernel module), builds and launches the
container stack, and writes `VERSION`.

## First provision: one reboot

On a fresh Pi the deploy must enable USB device mode
(`dtoverlay=dwc2,dr_mode=peripheral`), which only takes effect after a
reboot. When you see `REBOOT REQUIRED`, just reboot — the USB webcam gadget
assembles and binds itself at boot. No re-run needed.

## Verify it worked

After the reboot the device shows up as a USB webcam on the PC it is plugged
into (any camera app, no driver needed). On the Pi itself:

```bash
~/scanbox/host/boot_selftest.sh
```

A read-only boot-to-webcam self-check — 4/4 PASS means gadget bound, stack
up, video device fed, stream alive. The web UI (an operator/debug surface
over LAN/WiFi, never over the USB link) is at `http://<pi-ip>`.

## Test it without provisioning

Decrypt + clone only (into a throwaway dir, stops before `deploy.sh`):

```bash
curl -fsSL https://raw.githubusercontent.com/Alkaronyan/scanbox-deploy/main/bootstrap.sh \
  | SCANBOX_BOOTSTRAP_CLONE_ONLY=1 SCANBOX_DEPLOY_DIR=/tmp/sbx-test bash
```

> **The env vars go on the `bash` side of the pipe, not before `curl`.** In
> `VAR=x curl … | bash`, `VAR` is set for `curl` and never reaches the script —
> so it would run with defaults (deploying into `$HOME/scanbox`). Put them after
> the `|`, on `bash`. (A safety guard also refuses to `reset --hard` a checkout
> with uncommitted changes; override with `SCANBOX_BOOTSTRAP_FORCE=1`.)

## Why the token is safe in the open

The clone token embedded in `bootstrap.sh` is **`age`-encrypted** with a
passphrase — useless without it — and is a **fine-grained, read-only token
scoped to only the `scanbox` repo**. Worst case it grants reading one repo.
The passphrase is the only secret the operator carries; it lives nowhere in
this file (there is a public *hint*, never the passphrase).

## Overrides

| Env var | Default | Purpose |
|---|---|---|
| `SCANBOX_REPO_BRANCH` | `uvc-webcam-beta` | branch to deploy; falls back to the remote default (with a warning) if it is gone |
| `SCANBOX_DEPLOY_DIR` | `$HOME/scanbox` | where to clone |
| `SCANBOX_BOOTSTRAP_CLONE_ONLY` | — | if set, stop after decrypt + clone (test mode) |
| `SCANBOX_PASSPHRASE_HINT` | *(baked in)* | override the printed hint |

## Updating this repo

Both files here are **published copies** — the sources live in the private
repo (`scripts/deploy/bootstrap.sh` and `scripts/deploy/README_DEPLOY.md`),
and `scripts/deploy/publish_bootstrap.sh` there is the only sanctioned way to
publish them (token rotation included). Never hand-edit the copies here: a
drift test in the private repo diffs served against source and will flag it.
