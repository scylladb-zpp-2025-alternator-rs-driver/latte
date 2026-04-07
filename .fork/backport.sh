#!/usr/bin/env bash
# backport.sh - Create or update a backport branch with develop-only commits.
#
# Usage: backport.sh [--pick <sha>] [--dry-run] [<backport-branch> [<base>]]
#   --pick <sha>       Only backport the given merge commit's branch, or a
#                      single commit. <sha> can be abbreviated.
#   --dry-run          Print the git commands instead of executing them.
#   <backport-branch>  Branch to create/update  (default: backport)
#   <base>             Base for new branch       (default: main)
#
# Workflow:
#   1. First run:   creates <backport-branch> from <base>, cherry-picks all
#                   develop-only commits (oldest first, with -x trailers),
#                   then squashes fixup!/amend! units via rebase --autosquash.
#   2. Next runs:   detects which commits are already applied (by patch-id or
#                   cherry-picked trailer), cherry-picks only the new ones,
#                   then runs rebase --autosquash again.
#   3. Squash units: commits with fixup!/amend! subjects in develop are
#                   cherry-picked as-is, then collapsed by rebase --autosquash.
#                   The final squashed commit carries a trailer:
#                     (cherry picked from commit <orig-sha>)
#   4. On conflict during cherry-pick: resolve, git cherry-pick --continue,
#                   then re-run backport.sh to apply remaining units.
#   5. On conflict during rebase --autosquash: resolve and
#                   git rebase --continue  (no need to re-run backport.sh).
#   6. To abort:    git cherry-pick --abort  (during cherry-pick phase)
#                   git rebase --abort       (during autosquash phase)
#                   Re-run backport.sh to retry from scratch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
PICK_SHA=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --pick) PICK_SHA="$2"; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done

BACKPORT_BRANCH="${args[0]:-backport}"
BASE="${args[1]:-main}"

GIT_DIR="$(git rev-parse --git-dir)"

# ── Unit helpers ──────────────────────────────────────────────────────────────

# parse_unit <line>
# Sets: UNIT_ORIG, UNIT_FIXUPS (space-sep, may be empty), UNIT_ORIG_SKIP
# A plan line prefixed with '~' means orig is already on the backport branch
# as a plain commit; only UNIT_FIXUPS need to be cherry-picked.
parse_unit() {
  local line="$1"
  local first="${line%% *}"
  if [[ "$first" == "~"* ]]; then
    UNIT_ORIG="${first:1}"
    UNIT_ORIG_SKIP=1
  else
    UNIT_ORIG="$first"
    UNIT_ORIG_SKIP=0
  fi
  local rest="${line#* }"
  if [[ "$rest" == "$first" ]]; then
    UNIT_FIXUPS=""
  else
    UNIT_FIXUPS="$rest"
  fi
}

describe_unit() {
  local orig="$1"
  local fixups="$2"
  local skip="${3:-0}"
  local oneline
  oneline=$(git log --no-walk --oneline "$orig")
  if [[ -z "$fixups" ]]; then
    echo "  $oneline"
  else
    local n first_fixup suffix
    n=$(echo "$fixups" | wc -w)
    first_fixup=$(echo "$fixups" | awk '{print $1}')
    if (( n > 1 )); then
      suffix=" (+$((n-1)) more)"
    else
      suffix=""
    fi
    if (( skip )); then
      echo "  $oneline  [already applied; squash with: $first_fixup$suffix]"
    else
      echo "  $oneline  [squash with: $first_fixup$suffix]"
    fi
  fi
}

# ── Guards (skipped in dry-run) ───────────────────────────────────────────────
if (( ! DRY_RUN )); then

  # ── Guard: any in-progress git operation ───────────────────────────────────
  if [[ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]]; then
    echo "ERROR: a cherry-pick is in progress." >&2
    echo "  Resolve conflicts, then:  git cherry-pick --continue" >&2
    echo "  To abandon:               git cherry-pick --abort" >&2
    echo "  Then re-run backport.sh." >&2
    exit 1
  fi
  if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    echo "ERROR: a merge is in progress. Finish or abort it first:" >&2
    echo "  git merge --continue  |  git merge --abort" >&2
    exit 1
  fi
  if [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]; then
    echo "ERROR: a rebase is in progress." >&2
    echo "  If started by backport.sh:  git rebase --continue  (no need to re-run backport.sh)" >&2
    echo "  To abandon:                 git rebase --abort && .fork/backport.sh $BACKPORT_BRANCH $BASE" >&2
    exit 1
  fi
  if [[ -f "$GIT_DIR/BISECT_LOG" ]]; then
    echo "ERROR: a bisect is in progress. Finish or abort it first:" >&2
    echo "  git bisect reset" >&2
    exit 1
  fi

  # ── Guard: uncommitted changes ─────────────────────────────────────────────
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: you have uncommitted changes. Stash or commit them first:" >&2
    echo "  git stash  (then later: git stash pop)" >&2
    git status --short >&2
    exit 1
  fi
fi

# ── Compute backport plan (oldest → newest units) ─────────────────────────────
echo "Computing backport plan..."
mapfile -t plan_lines < <("$SCRIPT_DIR/dev-commits.sh" --backport-plan "$BACKPORT_BRANCH" "$BASE")

# Check for leftover unsquashed fixup!/amend! commits (from an interrupted run)
has_pending_squash=0
if (( ! DRY_RUN )) && git rev-parse --verify "$BACKPORT_BRANCH" &>/dev/null; then
  git log "$BACKPORT_BRANCH" --not "$BASE" --no-merges --format="%s" \
    | grep -qP "^(fixup|amend)! " && has_pending_squash=1 || true
fi

if [[ ${#plan_lines[@]} -eq 0 && $has_pending_squash -eq 0 ]]; then
  echo "Backport branch '$BACKPORT_BRANCH' is already up to date."
  exit 0
fi

# ── Apply --pick filter if requested ─────────────────────────────────────────
if [[ -n "$PICK_SHA" ]]; then
  full_pick=$(git rev-parse "$PICK_SHA")
  parent_count=$(git log -1 --format="%P" "$full_pick" | wc -w)

  if (( parent_count > 1 )); then
    # Merge commit: select units whose orig is reachable from this merge's side branches
    parent1=$(git log -1 --format="%P" "$full_pick" | awk '{print $1}')
    declare -A pick_set=()
    while read -r sha; do pick_set[$sha]=1; done < <(
      git log "$full_pick" --not "$parent1" --no-merges --format="%H"
    )
    filtered=()
    for line in "${plan_lines[@]}"; do
      orig="${line%% *}"
      [[ -n "${pick_set[$orig]+_}" ]] && filtered+=("$line")
    done
    plan_lines=("${filtered[@]}")
    echo "(--pick: selecting commits from merge $PICK_SHA)"
  else
    # Single commit: find it in plan
    filtered=()
    for line in "${plan_lines[@]}"; do
      orig="${line%% *}"
      [[ "$orig" == "$full_pick" ]] && filtered+=("$line")
    done
    if [[ ${#filtered[@]} -eq 0 ]]; then
      echo "ERROR: $PICK_SHA is not a pending backport unit." >&2
      exit 1
    fi
    plan_lines=("${filtered[@]}")
    echo "(--pick: selecting single unit $PICK_SHA)"
  fi
fi

if [[ ${#plan_lines[@]} -eq 0 ]]; then
  echo "No commits matched --pick $PICK_SHA."
  exit 0
fi

# ── Print plan ────────────────────────────────────────────────────────────────
if [[ ${#plan_lines[@]} -gt 0 ]]; then
  echo ""
  echo "Plan: apply ${#plan_lines[@]} unit(s) onto '$BACKPORT_BRANCH'"
  echo ""
  for line in "${plan_lines[@]}"; do
    parse_unit "$line"
    describe_unit "$UNIT_ORIG" "$UNIT_FIXUPS" "$UNIT_ORIG_SKIP"
  done
  echo ""
fi

# ── Dry-run: print commands and exit ─────────────────────────────────────────
if (( DRY_RUN )); then
  echo "# Commands to apply ${#plan_lines[@]} unit(s) onto '$BACKPORT_BRANCH':"
  echo ""
  if ! git rev-parse --verify "$BACKPORT_BRANCH" &>/dev/null; then
    echo "git checkout -b $BACKPORT_BRANCH $BASE"
  else
    echo "git checkout $BACKPORT_BRANCH"
  fi
  has_squash_units=0
  for line in "${plan_lines[@]}"; do
    parse_unit "$line"
    if [[ -z "$UNIT_FIXUPS" ]]; then
      echo "git cherry-pick -x $UNIT_ORIG"
    else
      has_squash_units=1
      if (( UNIT_ORIG_SKIP )); then
        echo "# squash unit: orig=$UNIT_ORIG (already on branch) fixups=$UNIT_FIXUPS"
      else
        echo "# squash unit: orig=$UNIT_ORIG fixups=$UNIT_FIXUPS"
        echo "git cherry-pick -x $UNIT_ORIG"
      fi
      for f in $UNIT_FIXUPS; do echo "git cherry-pick -x $f"; done
    fi
  done
  if (( has_squash_units )); then
    echo ""
    echo "# Squash fixup!/amend! commits into their targets:"
    echo "GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash $BASE"
  fi
  echo ""
  echo "# On conflict during cherry-pick: resolve files, then:"
  echo "#   git cherry-pick --continue"
  echo "#   .fork/backport.sh $BACKPORT_BRANCH $BASE   # to apply remaining units"
  echo "# On conflict during rebase:"
  echo "#   git rebase --continue                      # no need to re-run backport.sh"
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
read -r -p "Proceed? [Y/n] " confirm
[[ "${confirm,,}" == "n" ]] && { echo "Aborted."; exit 0; }

# ── Create or checkout branch ─────────────────────────────────────────────────
current_branch="$(git symbolic-ref --short HEAD)"

if ! git rev-parse --verify "$BACKPORT_BRANCH" &>/dev/null; then
  echo "Creating '$BACKPORT_BRANCH' from '$BASE'..."
  git checkout -b "$BACKPORT_BRANCH" "$BASE"
else
  git checkout "$BACKPORT_BRANCH"
fi

# ── Apply units ───────────────────────────────────────────────────────────────
apply_units() {
  local lines=("$@")
  for line in "${lines[@]}"; do
    parse_unit "$line"
    local orig="$UNIT_ORIG"
    local fixups="$UNIT_FIXUPS"

    echo "Cherry-picking $(git log --no-walk --oneline "$orig") ..."
    if (( UNIT_ORIG_SKIP )); then
      echo "  (orig already applied on backport branch, cherry-picking fixups only)"
    elif ! git cherry-pick -x "$orig"; then
      echo "ERROR: conflict cherry-picking $orig" >&2
      echo "  Resolve conflicts, then:  git cherry-pick --continue" >&2
      echo "  Then re-run backport.sh to apply remaining units." >&2
      exit 1
    fi

    if [[ -n "$fixups" ]]; then
      local fixup_sha
      for fixup_sha in $fixups; do
        local fixup_subj
        fixup_subj=$(git log --no-walk --format="%s" "$fixup_sha")
        echo "  Staging fixup $(git log --no-walk --oneline "$fixup_sha") ..."
        if ! git cherry-pick -x "$fixup_sha"; then
          echo "ERROR: conflict cherry-picking fixup $fixup_sha" >&2
          echo "  Resolve conflicts, then:  git cherry-pick --continue" >&2
          echo "  Then re-run backport.sh to apply remaining units." >&2
          exit 1
        fi
        # For amend! commits, rewrite the cherry-pick trailer to reference orig
        # so that after rebase --autosquash the squashed commit has the right trailer.
        if [[ "$fixup_subj" == amend!\ * ]]; then
          local body
          body=$(git log --no-walk --format="%B" HEAD)
          body=$(printf '%s' "$body" \
            | sed "s|(cherry picked from commit [0-9a-f][0-9a-f]*)|(cherry picked from commit $orig)|g")
          git commit --amend -m "$body"
        fi
      done
    fi
  done
}

if [[ ${#plan_lines[@]} -gt 0 ]]; then
  echo ""
  echo "Applying units onto '$BACKPORT_BRANCH'..."
  echo "If a conflict occurs during cherry-pick, resolve it, then:"
  echo "  git cherry-pick --continue"
  echo "  .fork/backport.sh $BACKPORT_BRANCH $BASE   # to apply remaining units"
  echo ""
  apply_units "${plan_lines[@]}"
fi

# ── Autosquash fixup!/amend! commits ─────────────────────────────────────────
if git log "$BACKPORT_BRANCH" --not "$BASE" --no-merges --format="%s" \
   | grep -qP "^(fixup|amend)! "; then
  echo ""
  echo "Squashing fixup!/amend! commits via rebase --autosquash..."
  echo "If a conflict occurs during rebase, resolve it, then:"
  echo "  git rebase --continue  (no need to re-run backport.sh)"
  echo ""
  GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash "$BASE"
fi

echo ""
echo "Done. '$BACKPORT_BRANCH' is up to date."
echo "You were on '$current_branch'; you are now on '$BACKPORT_BRANCH'."
