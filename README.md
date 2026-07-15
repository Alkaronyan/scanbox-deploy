# scanbox-deploy

Public deploy entry point for the **private** [`Alkaronyan/scanbox`](https://github.com/Alkaronyan/scanbox)
subsystem. This repo holds a single file — `bootstrap.sh` — that anyone with the
deploy passphrase can run to provision a device.

## Deploy

```bash
curl -fsSL https://raw.githubusercontent.com/Alkaronyan/scanbox-deploy/main/bootstrap.sh | bash
```

It installs the minimal tools (`git`, `age`), shows a passphrase hint, asks for
the passphrase, decrypts a **read-only, single-repo** clone token in memory,
clones the private repo, and hands off to its `deploy.sh`.

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

## Rotating the token

Regenerate the encrypted blob + hint with `secrets/encrypt_repo_token.sh` in the
private repo, paste both into `bootstrap.sh`, and push the update here.
