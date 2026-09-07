#!/usr/bin/env bash
#
# bootstrap_node.sh — SCANBOX public deploy entry point.
# =============================================================================
# Host this file publicly (a public gist or a small public repo). The private
# code repo stays private; this file carries NO credential at all. The encrypted
# read-only clone token is published beside it as token.age, so this file and
# that one are both safe in the open.
#
#   curl -fsSL <public-url>/bootstrap_node.sh | bash
#
# Flow: install the minimal tools to decrypt+clone (git, age) -> obtain the clone
# token -> clone the private repo -> hand off to the repo's own deploy.sh (which
# does the real host/stack provisioning).
#
# The token is obtained by the first of three routes that can supply one:
#   1. this device's own age identity, if it has been provisioned before;
#   2. a token handed over for this run in SCANBOX_REPO_TOKEN_FILE;
#   3. the published blob plus the operator's passphrase.
# Only the third is interactive, and only on a first provision.
#
# Rotating a token changes token.age and nothing in this file. That is the point:
# the blob used to be pasted into this script AND into bootstrap_win.ps1, and two
# copies of one artefact kept in step by a guard is a drift waiting for the day
# somebody forgets to extend the guard.
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

# ---- where the shared artefacts live ---------------------------------------
# The encrypted token is NOT embedded here any more, and neither is the hint.
#
# They used to be pasted into this file AND into bootstrap_win.ps1, because bash and
# PowerShell share no code. Two copies of one secret artefact, kept in step by a
# publisher that patched both by regular expression and then compared them. That
# guard worked - and it only ever covered what somebody remembered to add to it:
# the default branch is duplicated between the two halves in exactly the same
# way and nothing checks it at all.
#
# So there is one copy now, served next to this script, and both halves fetch
# it. Rotation replaces one file instead of patching two, and the drift cannot
# happen rather than being detected.
#
# The base is derived from an overridable variable rather than hard-coded per
# artefact, so a fork or a mirror stays consistent with itself: whoever serves
# this script serves its token.
DEPLOY_BASE_URL="${SCANBOX_DEPLOY_BASE_URL:-https://raw.githubusercontent.com/Alkaronyan/scanbox-deploy/main}"
TOKEN_AGE_URL="${DEPLOY_BASE_URL}/token.age"
HINT_URL="${DEPLOY_BASE_URL}/token.age.hint"


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
# identity is gone) falls back to the published blob + the operator passphrase.
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
# It exists for one caller: scripts/deploy/bootstrap_win.ps1, which has already opened
# the blob on the PC because the operator typed the passphrase there. Without
# this branch the only way to get a first provision unattended is to put the
# MASTER PASSPHRASE on the card - and the published blob is public, so a card
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
  # Two fetches now instead of none, and each one is named when it fails. A
  # single "could not get the token" would leave the operator unable to tell a
  # network that is down from a repository that no longer serves the artefact.
  BLOB="$(curl -fsSL "${TOKEN_AGE_URL}")" \
    || die "could not fetch the encrypted token from ${TOKEN_AGE_URL} (network, or it is not published there)."
  case "${BLOB}" in
    *"BEGIN AGE ENCRYPTED FILE"*) : ;;
    *) die "${TOKEN_AGE_URL} did not return an age file. Refusing to hand it to age." ;;
  esac
  # The hint is a convenience: a node that cannot fetch it can still be
  # provisioned, so its absence is reported and not fatal.
  HINT="$(curl -fsSL "${HINT_URL}" 2>/dev/null | head -n 1)" || HINT=""
  [ -n "${HINT}" ] || HINT="(hint unavailable - ${HINT_URL} could not be read)"

  log "decrypting the deploy token."
  printf '\033[36m[bootstrap]\033[0m \033[33mpassphrase hint:\033[0m %s\n' "${SCANBOX_PASSPHRASE_HINT:-${HINT}}"
  log "enter the passphrase when prompted:"
  TOKEN="$(printf '%s' "${BLOB}" | age -d)" || die "decryption failed (wrong passphrase?)."
  [ -n "${TOKEN}" ] || die "empty token after decryption."
fi

# ---- 3. clone/update the private repo WITHOUT the token touching ps/URL ------
# The token goes into a private tmpfs file; a GIT_ASKPASS shim feeds it to git,
# so it never appears in a command line, the remote URL, or the environment.
# NOT /dev/shm, and the reason is measured rather than argued. systemd-logind
# ships RemoveIPC=yes, and it deletes every file in /dev/shm owned by a user the
# moment that user's LAST login session ends. The deploy user holds no session
# at all under cloud-init, so one ssh login by somebody watching the
# provisioning - opened and closed - takes this file with it. Measured on
# glnode7 2026-09-07: a pi-owned file in /dev/shm was gone 49 s after that
# logout while the root-owned file beside it survived. That is what emptied the
# real provisioning run of 17:00:54 UTC before deploy.sh reached step 4 at
# 17:02:45, which then sealed .env.example as the device's identity - no hwctl,
# no fleet key, and a passphrase prompt on every later run of that node.
#
# /run is a tmpfs too - RAM, cleared at boot, never on the card - and logind
# does not scan it. The askpass shim below STAYS in /dev/shm because /run is
# mounted noexec (measured on the same node) and git must execute the shim; it
# carries no secret, only the path of one, and if it dies the clone fails loudly.
#
# Its own directory, NOT /run/scanbox: that one is root-owned 0755, holds the
# gadget stamp and uvc-ready.json, and is bind-mounted into vid_mux. Taking it
# over as a private 0700 dir for this user would break every reader of those
# two files - which is what the first version of this fix did, on the bench,
# before anything was committed. `/run/scanbox-usb` and `/run/scanbox-weston`
# are the existing precedent for a purpose-made sibling.
HANDOFF_DIR=/dev/shm
if sudo -n install -d -m 0700 -o "$(id -u)" -g "$(id -g)" /run/scanbox-handoff 2>/dev/null; then
  HANDOFF_DIR=/run/scanbox-handoff
else
  log "WARNING: no promptless sudo, so the clone token stays in /dev/shm - a login"
  log "         session ending during this run deletes it (systemd RemoveIPC)."
fi
TOKEN_FILE="$(mktemp "${HANDOFF_DIR}/sbxtok.XXXXXX")"; chmod 600 "${TOKEN_FILE}"
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
