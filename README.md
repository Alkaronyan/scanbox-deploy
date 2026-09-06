<!-- GENERATED from scanbox:scripts/deploy/README_DEPLOY.md — do not edit here; publish with scripts/deploy/publish_bootstrap.sh -->
# scanbox-deploy

Public deploy entry point for the **private** [`Alkaronyan/scanbox`](https://github.com/Alkaronyan/scanbox)
subsystem. This repo holds the two halves of provisioning — `bootstrap.sh`,
which runs **on the device**, and `flash.ps1`, which runs **on a Windows PC** and
produces a device that runs `bootstrap.sh` by itself — plus this README, the
operator's guide.

Both carry the same encrypted, read-only clone token. Anyone with the deploy
passphrase can provision a device; nobody without it can do anything with either
file.

## Provision or update a device (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/Alkaronyan/scanbox-deploy/main/bootstrap.sh | bash
```

Run it on the device (Raspberry Pi OS Lite 64-bit, network up). The same
command is also the update path — re-running it updates the device in place;
there is no separate upgrade procedure.

What happens, in order: it installs the minimal tools (`git`, `age`), shows a
passphrase hint and asks for the passphrase — **the only prompt there will ever
be, and only on the very first provision**; later runs unlock a token sealed to
the device itself and ask nothing. Then it decrypts the clone token, clones the
private repo, and hands off to its `deploy.sh`, which installs Docker,
provisions the host (kernel headers, USB-gadget services, the patched
`usb_f_uvc` kernel module), builds and launches the container stack, and writes
`VERSION`.

The embedded clone token is `age`-encrypted and **read-only, scoped to one
repo** — the passphrase is the only secret you carry.

## First provision: one reboot, handled for you

A fresh Pi must be switched into USB device mode, which only takes effect on
boot. The deploy does this itself: when every step has succeeded it prints
`REBOOT REQUIRED` and **reboots after a 10-second countdown** (Ctrl-C aborts;
`SCANBOX_NO_REBOOT=1` skips the reboot and tells you to do it yourself). If any
step had failed, it stops instead — a broken device is never rebooted out from
under you.

The gadget assembles and binds itself on the way back up. **Nothing needs to be
re-run.**

## A bare board, from nothing: `flash.ps1`

Everything above assumes a device that already boots and is on the network.
`flash.ps1` is for the case before that — a Compute Module with a blank eMMC.
Run it on a Windows PC with the module attached over USB:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File flash.ps1
```

It presents a numbered menu; option 1 is the whole path. It writes the pinned
Raspberry Pi OS image, then writes a cloud-init seed that gives the board its
name, clock, account, keys and passwordless sudo, and finally has the board
fetch and run the `bootstrap.sh` above on its own.

**You are asked for one thing and asked to do two:**

| | |
|---|---|
| type | the deploy passphrase, once |
| do | fit the nRPIBOOT jumper before, remove it after |

Nothing else. The account password and your SSH keys are reused from Raspberry
Pi Imager's own stored settings, so they are not asked for either — and the
password is only ever handled as a hash, never as a plaintext, on the PC or on
the card.

The passphrase reaches the card as one file and the board **destroys it in the
first seconds of first boot**, before the network is even up. If you would
rather it never touched the card, `-NoPassphrase` leaves it out: the board still
comes up provisioned and reachable, and prints the one command to finish it over
SSH.

Requirements on the PC: Windows PowerShell 5.1, Git for Windows (for `openssl`),
Raspberry Pi Imager, and `age`. `flash.ps1 -Action probe` reports which of those
are present without changing anything, and `-Action cleanup` removes only what
the script itself installed — recorded when it installs, never guessed at
afterwards.

Its own log for a run is on the device at `/var/log/scanbox-provision.log`, and
the deploy's log follows at `~/scanbox/deploy.log`.

## Verify it worked

After the reboot the device shows up as a USB webcam on the PC it is plugged
into (any camera app, no driver needed). On the Pi itself:

```bash
~/scanbox/host/boot_selftest.sh
```

A read-only boot-to-webcam self-check — 4/4 PASS means gadget bound, stack up,
video device fed, stream alive.

## If something goes wrong

Every run is written in full to **`~/scanbox/deploy.log`** — screen output
scrolls thousands of lines during a first provision, so the log, not the
terminal, is the record. Each run is appended under a dated header. If the
clone itself never happened (no network, wrong passphrase), the log lands at
`~/scanbox-deploy-failed.log` instead.

## Overrides

| Env var | Default | Purpose |
|---|---|---|
| `SCANBOX_REPO_BRANCH` | `uvc-webcam-beta` | branch to deploy; falls back to the remote default (with a warning) if it is gone |
| `SCANBOX_DEPLOY_DIR` | `$HOME/scanbox` | where to clone |
| `SCANBOX_NO_REBOOT` | — | if set, never reboot automatically; print the instruction instead |
| `SCANBOX_PASSPHRASE_HINT` | *(baked in)* | override the printed hint |

> Env vars go on the `bash` side of the pipe, not before `curl`. In
> `VAR=x curl … | bash`, `VAR` is set for `curl` and never reaches the script.
> Put them after the `|`, on `bash`.

## Updating this repo

All three files here are **published copies** — the sources live in the private
repo (`scripts/deploy/bootstrap.sh`, `scripts/deploy/flash.ps1` and
`scripts/deploy/README_DEPLOY.md`), and `scripts/deploy/publish_bootstrap.sh`
there is the only sanctioned way to publish them (token rotation included).

`bootstrap.sh` and `flash.ps1` are published **together, in one commit**,
because they carry one token between them: the publisher patches both blobs in a
single rotation and refuses to push if they disagree. Never hand-edit the copies
here — a drift test in the private repo diffs served against source, and also
checks that the two served files still carry the same token and print the same
hint.
