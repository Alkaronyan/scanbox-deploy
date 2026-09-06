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
# During beta, deploy the beta branch. If it no longer exists (e.g. after it is
# merged away and deleted), the resolver below follows the code to the branch it
# now LIVES in — the nearest branch containing this node's commit — never to the
# remote's default branch, which is the fallback that stranded both benches on
# 2026-08-07 (J16). See the reasoning at the resolver itself.
# J7's promotion owns flipping this default to "main".
BRANCH="${SCANBOX_REPO_BRANCH:-uvc-webcam-beta}"
DEPLOY_DIR="${SCANBOX_DEPLOY_DIR:-${HOME}/scanbox}"

# ---- encrypted read-only repo token (age -p, armored) -----------------------
# Replace the placeholder with the output of scripts/deploy/encrypt_repo_token.sh.
REPO_TOKEN_AGE=$(cat <<'AGE'
-----BEGIN AGE ENCRYPTED FILE-----
YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNjcnlwdCBnL1pJZTdXYWNIME5Wczdy
VWFsN1VBIDE4ClhFN0Z2VGxpb0ZTdDdsODFGZkhST284Y3k3U2NQTTNlQUY4aFlP
N2lObjAKLS0tIExCTHMvZ3JlcU9HNVpQMWt5enk1Tk1nUmRHQlc0ZnZNVnlVTWsr
SDA3SDQK2GDp8VkgEBjU0m+aRnlp8qb+eHHUWXAoFamUan8UWsUSIx1GhgF420hF
NTYmtqzR/reSh12zCpJ084m9zE2HwCZ4dRupjQZRj+kaYIu3VLOGHiti3jfQNXuO
tz62m582dOc5FiQ4214GFwmV3nb10N41zd39nVYG6AVpTPQ=
-----END AGE ENCRYPTED FILE-----
AGE
)

# ---- passphrase reminder (safe to be public — a memory jog, NEVER the passphrase)
# Printed right before the prompt so you know which passphrase to type. Replace
# it with your own reminder (a password-manager entry name, "the bench secret",
# …) — meaningful to you but useless to a stranger. Overridable via
# SCANBOX_PASSPHRASE_HINT.
PASSPHRASE_HINT="${SCANBOX_PASSPHRASE_HINT:-Old naming}"

# ---- one elapsed clock for the WHOLE cold deploy ----------------------------
# deploy.sh stamps its lines; this script did not, and the untimed span is the
# expensive one: on a bare node the bootstrap installs git, age and the whole of
# Docker, and clones the repo, all before deploy.sh exists. "Where did the time
# go" was unanswerable for precisely the part that takes longest.
#
# The zero is EXPORTED, not kept, so deploy.sh continues this count instead of
# restarting at 0 across the exec handoff. It is an epoch rather than bash's
# SECONDS because SECONDS is per-process and cannot survive that handoff. Both
# scripts then report elapsed time for the RUN - the thing being measured -
# and neither reports it for itself.
SCANBOX_DEPLOY_T0_EPOCH="${SCANBOX_DEPLOY_T0_EPOCH:-$(date +%s)}"
export SCANBOX_DEPLOY_T0_EPOCH
# ---- one stamp on EVERY line, applied where all output already passes -------
# Stamping each script's own log() reached only the lines those scripts print
# themselves - the [1/7]..[7/7] progress. Everything that actually takes the
# time is printed by somebody else: setup_host.sh's own echoes, apt, and the
# docker builds. Watching a real cold deploy, section 5 scrolls for minutes
# without a single stamp, which is exactly the stretch you want to measure.
#
# So the stamp goes on the OUTERMOST pipeline instead, where every line from
# every child already flows. One place, whole run, nothing to remember when a
# new script is added. The per-script log()s keep their [bootstrap]/[deploy]
# identity and deliberately carry no time of their own - two stamps on one line
# is worse than none.
#
# printf's %(...)T and EPOCHSECONDS are bash builtins: a `date` fork per line
# would cost thousands of forks on a Pi and time the stamper instead of the
# deploy. TZ is set inside the subshell so the clock is UTC without touching
# the caller's environment.
_sb_stamp() {
    (
      export TZ=UTC
      local t0="${SCANBOX_DEPLOY_T0_EPOCH:-${EPOCHSECONDS:-0}}" line
      while IFS= read -r line || [ -n "${line}" ]; do
          printf '[%(%H:%M:%S)T +%4ds] %s\n' -1 "$(( ${EPOCHSECONDS:-0} - t0 ))" "${line}"
      done
    )
}

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
exec > >(_sb_stamp | tee -a "${SCANBOX_LOG_TMP}") 2>&1
# Tell deploy.sh the stream it inherits is already stamped, so it does not stamp
# it a second time - and, more importantly, so it DOES stamp when an older
# published copy of this file handed it an unstamped one.
SCANBOX_LOG_STAMPED=1
export SCANBOX_LOG_STAMPED
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
# A token HANDED OVER for this run, ahead of the passphrase and behind the
# device's own identity.
#
# It exists for one caller: scripts/deploy/flash.ps1, which has already opened
# the blob on the PC because the operator typed the passphrase there. Without
# this branch the only way to get a first provision unattended is to put the
# MASTER PASSPHRASE on the card - and the embedded blob is public, so a card
# carrying the passphrase carries every token that blob will ever hold, for
# every node, unrevocably. A card carrying this token carries one read-only,
# single-repo, revocable credential instead.
#
# It is NOT the same mechanism as the device-identity branch above and does not
# pretend to be: that one is a secret BOUND to a machine, sitting root-only on
# its disk, which has never travelled. This one travels. What changes is what
# is lost when it is lost, not whether anything is.
#
# The token arrives in a FILE and not in the environment or an argument: /proc
# publishes both to every user on the box, and this file is the caller's to
# create with the permissions it wants and to destroy when we are done. We read
# it, we shred it, and we say which of the two happened - never leaving the
# caller to assume the destruction from our silence.
#
# Backwards compatible by construction: with SCANBOX_REPO_TOKEN_FILE unset,
# every path below is exactly what it was.
if [ -z "${TOKEN}" ] && [ -n "${SCANBOX_REPO_TOKEN_FILE:-}" ]; then
  if [ -r "${SCANBOX_REPO_TOKEN_FILE}" ]; then
    TOKEN="$(head -n 1 "${SCANBOX_REPO_TOKEN_FILE}" | tr -d '\r\n')"
    shred -u -z "${SCANBOX_REPO_TOKEN_FILE}" 2>/dev/null || rm -f "${SCANBOX_REPO_TOKEN_FILE}"
    if [ -e "${SCANBOX_REPO_TOKEN_FILE}" ]; then
      log "WARNING: ${SCANBOX_REPO_TOKEN_FILE} still exists after shred - REMOVE IT BY HAND."
    fi
    if [ -n "${TOKEN}" ]; then
      log "clone token handed over by the caller (no passphrase needed); the file is gone."
    else
      log "the handed-over token file was EMPTY - falling back to the passphrase."
    fi
  else
    # Named but unreadable is not the same as not named, and the difference
    # decides whether a prompt on a headless node is a bug or the design.
    log "SCANBOX_REPO_TOKEN_FILE is set to ${SCANBOX_REPO_TOKEN_FILE} but it cannot be read - falling back to the passphrase."
  fi
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
elif [ -d "${DEPLOY_DIR}/.git" ]; then
  # The branch is gone from the remote, which means it was merged away. Go to
  # the branch its code now LIVES in — the one containing this node's last
  # commit — not to the remote's default branch.
  #
  # That fallback used to be `main`, and it is the same defect that stranded
  # both benches on 2026-08-07 (J16): a node quietly moved onto a lineage
  # nobody deploys, taking .gitignore with it. It was survivable while this
  # script always prompted for a passphrase, because a human was watching. A
  # node with a valid sealed token is no longer asked — proven on glnode0,
  # 2026-08-07 — so the fallback could move a node's branch unattended.
  #
  # Nearest wins: the branch fewest commits ahead of ours, so a long-lived
  # integration branch beats `main` when both contain us.
  git -C "${DEPLOY_DIR}" fetch --quiet --prune origin 2>/dev/null || true
  _here="$(git -C "${DEPLOY_DIR}" rev-parse --verify --quiet HEAD || true)"
  CLONE_BRANCH="$(git -C "${DEPLOY_DIR}" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/*' 2>/dev/null       | grep -v '^origin/HEAD$'       | while read -r r; do
            if git -C "${DEPLOY_DIR}" merge-base --is-ancestor "${_here}" "${r}" 2>/dev/null; then
                echo "$(git -C "${DEPLOY_DIR}" rev-list --count "${_here}..${r}") ${r#origin/}"
            fi
        done | sort -n | head -1 | awk '{print $2}')"
  [ -n "${CLONE_BRANCH}" ]     || die "branch '${BRANCH}' is gone from the remote and no other branch contains this node's commit. Say which one with SCANBOX_REPO_BRANCH=<name>."
  log "branch '${BRANCH}' is gone from the remote; its code now lives in '${CLONE_BRANCH}' — following it."
else
  # A first provision has nothing to trace from: no checkout, no commit. There
  # is no honest way to infer where the code went, so ask rather than guess.
  die "branch '${BRANCH}' is not on the remote and this machine has no checkout to infer a successor from. Set SCANBOX_REPO_BRANCH=<name>, or update this script's BRANCH."
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
