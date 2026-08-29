#!/usr/bin/env bash
#
# rebase-upstream.sh - Synchronize private mirror with upstream Chaptarr and rebase homelab patches.
#
# Usage:
#   scripts/rebase-upstream.sh [--check | --dry-run | --apply | --push]
#
# Flags:
#   --check           Report upstream divergence and patch rebase status without modifying local branches.
#   --dry-run         Simulate fetch, develop fast-forward, and patch branch rebase on temporary branches.
#   --apply           Fetch upstream, fast-forward develop to upstream/develop, and rebase homelab/patches.
#   --push            Perform --apply and push updated develop and homelab/patches to origin (with lease).
#   --upstream-url    Override upstream git URL (default: https://github.com/Chaptarr/chaptarr.git).
#   --upstream-branch Upstream target branch (default: develop).
#   --homelab-branch  Local homelab patch branch (default: homelab/patches).
#   --help, -h        Show this help message.

set -euo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
MODE="check"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/Chaptarr/chaptarr.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-develop}"
HOMELAB_BRANCH="${HOMELAB_BRANCH:-homelab/patches}"
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --push)
      MODE="push"
      shift
      ;;
    --upstream-url)
      UPSTREAM_URL="$2"
      shift 2
      ;;
    --upstream-branch)
      UPSTREAM_BRANCH="$2"
      shift 2
      ;;
    --homelab-branch)
      HOMELAB_BRANCH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      ;;
  esac
done

# Ensure we are in a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log_error "Must be executed inside a git repository."
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

# Ensure upstream remote is configured
if ! git remote get-url "${UPSTREAM_REMOTE}" >/dev/null 2>&1; then
  log_info "Adding upstream remote '${UPSTREAM_REMOTE}' -> ${UPSTREAM_URL}"
  git remote add "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
fi

# Fetch remotes
log_info "Fetching latest refs from '${UPSTREAM_REMOTE}' and '${ORIGIN_REMOTE}'..."
git fetch "${UPSTREAM_REMOTE}" "${UPSTREAM_BRANCH}" --tags --quiet
if git remote get-url "${ORIGIN_REMOTE}" >/dev/null 2>&1; then
  git fetch "${ORIGIN_REMOTE}" --quiet || log_warn "Could not fetch from '${ORIGIN_REMOTE}'; continuing with local refs."
fi

UPSTREAM_REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
UPSTREAM_SHA="$(git rev-parse "${UPSTREAM_REF}")"

log_info "Latest upstream '${UPSTREAM_BRANCH}' SHA: ${UPSTREAM_SHA}"

# Check develop status
DEVELOP_SHA=""
if git rev-parse --verify "develop" >/dev/null 2>&1; then
  DEVELOP_SHA="$(git rev-parse "develop")"
  log_info "Local 'develop' SHA: ${DEVELOP_SHA}"
else
  log_warn "Local 'develop' branch does not exist yet."
fi

# Check homelab branch status
HOMELAB_SHA=""
if git rev-parse --verify "${HOMELAB_BRANCH}" >/dev/null 2>&1; then
  HOMELAB_SHA="$(git rev-parse "${HOMELAB_BRANCH}")"
  log_info "Local '${HOMELAB_BRANCH}' SHA: ${HOMELAB_SHA}"
elif git rev-parse --verify "${ORIGIN_REMOTE}/${HOMELAB_BRANCH}" >/dev/null 2>&1; then
  HOMELAB_SHA="$(git rev-parse "${ORIGIN_REMOTE}/${HOMELAB_BRANCH}")"
  log_info "Remote '${ORIGIN_REMOTE}/${HOMELAB_BRANCH}' SHA: ${HOMELAB_SHA}"
else
  log_warn "Branch '${HOMELAB_BRANCH}' not found locally or on '${ORIGIN_REMOTE}'."
fi

# Mode: CHECK
if [[ "${MODE}" == "check" ]]; then
  echo ""
  echo "================================================================="
  echo "                     SYNC & REBASE STATUS                        "
  echo "================================================================="
  if [[ "${DEVELOP_SHA}" == "${UPSTREAM_SHA}" ]]; then
    log_success "'develop' is exactly aligned with '${UPSTREAM_REF}' (${UPSTREAM_SHA:0:7})."
  else
    SHORT_DEV="none"
    if [[ -n "${DEVELOP_SHA}" ]]; then
      SHORT_DEV="${DEVELOP_SHA:0:7}"
    fi
    log_warn "'develop' (${SHORT_DEV}) differs from '${UPSTREAM_REF}' (${UPSTREAM_SHA:0:7})."
    if [[ -n "${DEVELOP_SHA}" ]]; then
      BEHIND_COUNT="$(git rev-list --count "develop..${UPSTREAM_REF}" 2>/dev/null || echo "0")"
      AHEAD_COUNT="$(git rev-list --count "${UPSTREAM_REF}..develop" 2>/dev/null || echo "0")"
      echo "  - Behind upstream by ${BEHIND_COUNT} commit(s)"
      echo "  - Ahead of upstream by ${AHEAD_COUNT} commit(s)"
    fi
  fi

  if [[ -n "${HOMELAB_SHA}" ]]; then
    PATCH_COUNT="$(git rev-list --count "${UPSTREAM_REF}..${HOMELAB_SHA}" 2>/dev/null || echo "0")"
    echo "  - '${HOMELAB_BRANCH}' carries ${PATCH_COUNT} homelab patch commit(s) relative to upstream."
  fi
  echo "================================================================="
  echo "Run with '--dry-run' to test rebase or '--apply' to execute."
  exit 0
fi

# For mutating modes, verify working directory is clean
if [[ -n "$(git status --porcelain)" ]]; then
  log_error "Working directory is not clean. Commit or stash existing changes before running in '${MODE}' mode."
  git status --short
  exit 1
fi

# Mode: DRY-RUN or APPLY
INITIAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
TEMP_DEVELOP="temp-sync-develop-$$"
TEMP_HOMELAB="temp-sync-homelab-$$"

cleanup() {
  local exit_code=$?
  # Ensure we return to original branch if still on temp
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "${current_branch}" == "${TEMP_DEVELOP}" || "${current_branch}" == "${TEMP_HOMELAB}" ]]; then
    git checkout "${INITIAL_BRANCH}" --quiet 2>/dev/null || true
  fi
  # Remove temp branches
  git branch -D "${TEMP_DEVELOP}" 2>/dev/null || true
  git branch -D "${TEMP_HOMELAB}" 2>/dev/null || true
  if [[ ${exit_code} -ne 0 ]]; then
    log_error "Operation failed or interrupted. Restored initial state."
  fi
}
trap cleanup EXIT

if [[ "${MODE}" == "dry-run" ]]; then
  log_info "Starting dry-run simulation on temporary branches..."

  # Create temp develop from upstream
  git checkout -b "${TEMP_DEVELOP}" "${UPSTREAM_REF}" --quiet
  log_success "Temporary develop created from ${UPSTREAM_REF} (${UPSTREAM_SHA:0:7})"

  # If homelab branch exists, test rebase
  if [[ -n "${HOMELAB_SHA}" ]]; then
    git checkout -b "${TEMP_HOMELAB}" "${HOMELAB_SHA}" --quiet
    log_info "Simulating rebase of homelab patches onto '${UPSTREAM_REF}'..."
    if git rebase "${TEMP_DEVELOP}"; then
      log_success "Dry-run rebase completed successfully with zero conflicts!"
      git log --oneline -n 5
    else
      log_error "Dry-run rebase encountered conflicts. Run manual rebase to resolve."
      git rebase --abort 2>/dev/null || true
      exit 1
    fi
  fi

  log_success "Dry-run simulation completed cleanly. No branches were modified."
  exit 0
fi

# Mode: APPLY or PUSH
log_info "Applying upstream sync and rebasing homelab patches..."

# 1. Update develop branch to exactly match upstream/develop
if git rev-parse --verify "develop" >/dev/null 2>&1; then
  git checkout develop --quiet
  git reset --hard "${UPSTREAM_REF}" --quiet
else
  git checkout -b develop "${UPSTREAM_REF}" --quiet
fi
log_success "'develop' updated to match '${UPSTREAM_REF}' (${UPSTREAM_SHA:0:7})"

# 2. Rebase or create homelab branch
if git rev-parse --verify "${HOMELAB_BRANCH}" >/dev/null 2>&1; then
  git checkout "${HOMELAB_BRANCH}" --quiet
  log_info "Rebasing '${HOMELAB_BRANCH}' onto 'develop'..."
  if ! git rebase develop; then
    log_error "Rebase conflict encountered on '${HOMELAB_BRANCH}'."
    log_error "Resolve conflicts manually with 'git status', edit conflicting files, 'git add <files>', and 'git rebase --continue'."
    exit 1
  fi
  log_success "'${HOMELAB_BRANCH}' successfully rebased onto 'develop'."
elif git rev-parse --verify "${ORIGIN_REMOTE}/${HOMELAB_BRANCH}" >/dev/null 2>&1; then
  git checkout -b "${HOMELAB_BRANCH}" "${ORIGIN_REMOTE}/${HOMELAB_BRANCH}" --quiet
  log_info "Rebasing '${HOMELAB_BRANCH}' onto 'develop'..."
  if ! git rebase develop; then
    log_error "Rebase conflict encountered on '${HOMELAB_BRANCH}'."
    exit 1
  fi
  log_success "'${HOMELAB_BRANCH}' successfully rebased onto 'develop'."
fi

# Show final log
echo ""
log_info "Recent commits on '${HOMELAB_BRANCH}':"
git log --oneline -n 8

# Mode: PUSH
if [[ "${MODE}" == "push" ]]; then
  log_info "Pushing updated branches to '${ORIGIN_REMOTE}'..."
  git push "${ORIGIN_REMOTE}" develop --force-with-lease
  git push "${ORIGIN_REMOTE}" "${HOMELAB_BRANCH}" --force-with-lease
  log_success "Branches 'develop' and '${HOMELAB_BRANCH}' successfully pushed to '${ORIGIN_REMOTE}'!"
fi

log_success "Rebase procedure complete!"
