#!/usr/bin/env bash
#
# bootstrap.sh — SCANBOX public deploy entry point.
# =============================================================================
# Host this file publicly (a public gist or a small public repo). The private
# code repo stays private; this file carries only an *encrypted* read-only
# clone token, so it is safe in the open.
#
#   curl -fsSL <public-url>/bootstrap.sh | bash
#
# Flow: install the minimal tools to decrypt+clone (git, age) -> ask for the
# passphrase -> decrypt the read-only token in memory -> clone the private
# repo -> hand off to the repo's own deploy.sh (which does the real host/stack
# provisioning). The passphrase is the ONLY secret you provide; the token at
# rest is age-encrypted.
#
# The token blob below is produced by scripts/deploy/encrypt_repo_token.sh — run that,
# then paste its output between the AGE markers. Nothing else needs editing.
# =============================================================================
set -euo pipefail

REPO="${SCANBOX_REPO:-Alkaronyan/scanbox}"
# During beta, deploy the beta branch; if it no longer exists (e.g. after it is
# merged into main and deleted) the clone falls back to the remote's default
# branch with a warning. Flip this to "main" once beta is promoted.
BRANCH="${SCANBOX_REPO_BRANCH:-uvc-webcam-beta}"
DEPLOY_DIR="${SCANBOX_DEPLOY_DIR:-${HOME}/scanbox}"

# ---- encrypted read-only repo token (age -p, armored) -----------------------
# Replace the placeholder with the output of scripts/deploy/encrypt_repo_token.sh.
REPO_TOKEN_AGE=$(cat <<'AGE'
-----BEGIN AGE ENCRYPTED FILE-----
YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNjcnlwdCBtMTJaYXVZWlA5OUl1VThI
NXBTelpRIDE4CmljWnRGcCtLNEdXTUF0cGpoOXNUVDlxdlZFY0RHQjdobnRQRVg3
bmN3M00KLS0tIEltRDZUNTlmZFFrTFJQY25WdXRmVkR4TzF1KzVlVk1LNEpqYWFp
Vzduek0KH5zNpNgupXp6Xo5Z/irlOtMweYD90uNl4ybx0pic+CrlsTJIf6sinDD0
5NEmNFl7wZZ2HXtqW+TTl+jHdpntTvyUjsxFIfRQ/Zh3uXb1TztEfIisY5gshuKk
ZALKf9ulzYiDHeHKUqJ6H2+lzPvoZKNcbOR/ViJu0AK+lkA=
-----END AGE ENCRYPTED FILE-----
AGE
)

# ---- passphrase reminder (safe to be public — a memory jog, NEVER the passphrase)
# Printed right before the prompt so you know which passphrase to type. Replace
# it with your own reminder (a password-manager entry name, "the bench secret",
# …) — meaningful to you but useless to a stranger. Overridable via
# SCANBOX_PASSPHRASE_HINT.
PASSPHRASE_HINT="${SCANBOX_PASSPHRASE_HINT:-La de PaKithor}"

log() { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[bootstrap] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- deploy log (prelude) ----------------------------------------------------
# Tee everything from here on: the screen is not a record — a first provision
# scrolls thousands of lines. The checkout that holds the real log does not
# exist yet (we are about to create it), so write to a temp file and pass the
# path on; deploy.sh inherits this stdout through the exec handoff, so this one
# file ends up holding the whole story, and deploy.sh folds it into
# <checkout>/deploy.log at the end. The passphrase is unaffected: age reads and
# echoes it on /dev/tty, never through this pipe.
SCANBOX_LOG_TMP="$(mktemp /tmp/scanbox-deploy.XXXXXX.log)"
exec > >(tee -a "${SCANBOX_LOG_TMP}") 2>&1
export SCANBOX_LOG_TMP

case "${REPO_TOKEN_AGE}" in
  *PASTE*) die "bootstrap.sh still has the placeholder token — run scripts/deploy/encrypt_repo_token.sh and paste its output between the AGE markers." ;;
esac

# ---- 1. minimal deps to decrypt + clone (deploy.sh installs the rest) --------
missing=""
command -v git >/dev/null 2>&1 || missing="git"
command -v age >/dev/null 2>&1 || missing="${missing} age"
if [ -n "${missing}" ]; then
  log "installing:${missing} (needs sudo)…"
  sudo apt-get update -qq
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq ${missing}
fi

# ---- 2. obtain the clone token ----------------------------------------------
# Already-provisioned devices hold their own age identity with the token sealed
# inside (J5): read it and skip the passphrase entirely — this is what makes
# unattended/cron updates possible. Only a first provision (or a device whose
# identity is gone) falls back to the embedded blob + the operator passphrase.
DEVICE_KEY="/etc/scanbox/device-key.txt"
DEVICE_ENV="${DEPLOY_DIR}/.env.age"
TOKEN=""
if sudo test -r "${DEVICE_KEY}" 2>/dev/null && [ -f "${DEVICE_ENV}" ]; then
  log "device identity found — reading the sealed token (no passphrase needed)."
  TOKEN="$(sudo age -d -i "${DEVICE_KEY}" "${DEVICE_ENV}" 2>/dev/null \
           | sed -n 's/^SCANBOX_REPO_TOKEN=//p' | head -1)" || true
  [ -n "${TOKEN}" ] || log "no sealed token in this device's secrets — falling back to the passphrase."
fi
if [ -z "${TOKEN}" ]; then
  log "decrypting the deploy token."
  printf '\033[36m[bootstrap]\033[0m \033[33mpassphrase hint:\033[0m %s\n' "${PASSPHRASE_HINT}"
  log "enter the passphrase when prompted:"
  TOKEN="$(printf '%s' "${REPO_TOKEN_AGE}" | age -d)" || die "decryption failed (wrong passphrase?)."
  [ -n "${TOKEN}" ] || die "empty token after decryption."
fi

# ---- 3. clone/update the private repo WITHOUT the token touching ps/URL ------
# The token goes into a private tmpfs file; a GIT_ASKPASS shim feeds it to git,
# so it never appears in a command line, the remote URL, or the environment.
TOKEN_FILE="$(mktemp /dev/shm/sbxtok.XXXXXX)"; chmod 600 "${TOKEN_FILE}"
printf '%s' "${TOKEN}" > "${TOKEN_FILE}"; unset TOKEN
ASKPASS="$(mktemp /dev/shm/sbxask.XXXXXX)"; chmod 700 "${ASKPASS}"
cat > "${ASKPASS}" <<ASK
#!/bin/sh
case "\$1" in
  *[Uu]sername*) printf 'x-access-token' ;;
  *)             cat "${TOKEN_FILE}" ;;
esac
ASK

cleanup() { rm -f "${TOKEN_FILE}" "${ASKPASS}" 2>/dev/null || true; }
trap cleanup EXIT

export GIT_ASKPASS="${ASKPASS}" GIT_TERMINAL_PROMPT=0
URL="https://github.com/${REPO}.git"

# Resolve the branch: prefer the configured one; if it is gone, fall back to the
# remote's default branch (loudly, never silently) so a merged-away beta branch
# keeps working without editing this file.
if git ls-remote --exit-code --heads "${URL}" "${BRANCH}" >/dev/null 2>&1; then
  CLONE_BRANCH="${BRANCH}"
else
  CLONE_BRANCH="$(git ls-remote --symref "${URL}" HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}')"
  [ -n "${CLONE_BRANCH}" ] || CLONE_BRANCH="main"
  log "WARNING: branch '${BRANCH}' not found on the remote — falling back to the default branch '${CLONE_BRANCH}'."
fi

if [ -d "${DEPLOY_DIR}/.git" ]; then
  # Safety: never reset --hard over a checkout with uncommitted work — that would
  # silently discard local changes (e.g. a dev tree). Abort unless forced.
  if [ -z "${SCANBOX_BOOTSTRAP_FORCE:-}" ] && \
     [ -n "$(git -C "${DEPLOY_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    die "existing checkout at ${DEPLOY_DIR} has uncommitted changes — refusing to reset --hard over it. Commit/stash them, pick another SCANBOX_DEPLOY_DIR, or set SCANBOX_BOOTSTRAP_FORCE=1 to discard."
  fi
  log "updating existing checkout at ${DEPLOY_DIR} (${CLONE_BRANCH})…"
  git -C "${DEPLOY_DIR}" fetch --quiet origin "${CLONE_BRANCH}"
  git -C "${DEPLOY_DIR}" checkout --quiet "${CLONE_BRANCH}"
  git -C "${DEPLOY_DIR}" reset --quiet --hard "origin/${CLONE_BRANCH}"
else
  log "cloning ${REPO} (${CLONE_BRANCH}) into ${DEPLOY_DIR}…"
  git clone --quiet --branch "${CLONE_BRANCH}" "${URL}" "${DEPLOY_DIR}"
fi
unset GIT_ASKPASS
# Keep the token file alive across the handoff ONLY so deploy.sh can seal it
# into this device's .env.age (first provision) — after that the device reads
# it from its own identity and no passphrase is ever needed again. Same
# hygiene as the askpass shim: the *path* travels in the environment, the
# secret stays in a 0600 tmpfs file, and deploy.sh's own trap wipes it.
rm -f "${ASKPASS}" 2>/dev/null || true
trap - EXIT
export SCANBOX_TOKEN_FILE="${TOKEN_FILE}"

# ---- 4. hand off to the real deploy -----------------------------------------
if [ -n "${SCANBOX_BOOTSTRAP_CLONE_ONLY:-}" ]; then
  log "clone-only mode (SCANBOX_BOOTSTRAP_CLONE_ONLY set) — stopping before deploy.sh."
  log "decrypt + clone verified. Repo at ${DEPLOY_DIR}."
  exit 0
fi
log "clone OK — handing off to deploy.sh"
[ -f "${DEPLOY_DIR}/scripts/deploy/deploy.sh" ] || die "no deploy.sh in the repo at ${DEPLOY_DIR}."
# Pass the resolved branch through so deploy.sh operates on the same branch we
# just cloned (its own default is main).
export SCANBOX_REPO_BRANCH="${CLONE_BRANCH}"
# Tell deploy.sh the checkout is already current: this script just cloned or
# fetch+reset it with the (ephemeral) token credential, which is destroyed
# before the handoff by design. deploy.sh must NOT fetch again — it has no
# credential for the private repo and would die on "could not read Username".
export SCANBOX_REPO_READY=1
exec bash "${DEPLOY_DIR}/scripts/deploy/deploy.sh" "$@"
