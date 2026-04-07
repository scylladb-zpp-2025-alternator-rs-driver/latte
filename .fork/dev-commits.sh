#!/usr/bin/env bash
# Show commits in develop that are not in main, accounting for main→develop merges.
# Usage: dev-commits.sh [--list|--merges|--graph|--ordered|--backport-plan]
#   --list          (default) flat list of non-merge, non-fork commits
#   --merges        list of merge commits that bring in develop-only work
#   --graph         combined graph showing branch structure
#   --ordered       ordered list of SHAs oldest→newest (used by backport.sh)
#   --backport-plan ordered units oldest→newest, one unit per line:
#                     <orig-sha> [fixup-sha1] [fixup-sha2] ...
#                   Units already covered (by cherry-picked trailer or patch-id)
#                   are omitted.
#
# Fixup commits use the native git format (subject prefix):
#   fixup! <target subject>   squash into target, keep target's message
#   amend! <target subject>   squash into target, replace message with amend body
#
# Create with:  git commit --fixup <sha>
#               git commit --fixup=amend:<sha>
#
# A fixup!/amend! commit is not an independent backport unit — it is
# attached to its target commit and applied as a squash in backport.

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns 0 (true) if commit subject starts with "fixup! " or "amend! ".
_has_fixup_trailer() {
  git log --no-walk --format="%s" "$1" \
    | grep -qP "^(fixup|amend)! "
}

# Compute develop-only commits by patch-id (handles main→develop merge duplicates).
# Output: full SHAs, one per line.
# Excludes: "fork:" subject commits, and fixup!/amend! commits.
good_full() {
  local main_pids
  main_pids=$(git log -p main --no-merges | git patch-id --stable | awk '{print $1}')

  git log -p develop --not main --no-merges | git patch-id --stable \
  | awk -v mpids="$main_pids" '
      BEGIN { n=split(mpids,a,"\n"); for(i=1;i<=n;i++) ids[a[i]]=1 }
      !ids[$1] { print $2 }
    ' \
  | xargs --no-run-if-empty git log --no-walk --format="%H %s" \
  | grep -v " fork:" \
  | awk '{print $1}' \
  | while IFS= read -r sha; do
      _has_fixup_trailer "$sha" || echo "$sha"
    done
}

# Build fixup map from develop commits whose subject starts with fixup!/amend!.
# Matches fixup to target by subject (strips "fixup! "/"amend! " prefix, finds
# the develop commit with that exact subject).
# Output lines: <target-full-sha> <fixup-full-sha>  (newest-first git log order)
fixup_map() {
  # Build subject→full-sha index for all develop-only non-merge commits
  declare -A subj_to_sha=()
  while IFS=$'\t' read -r sha subj; do
    subj_to_sha[$subj]="$sha"
  done < <(git log develop --not main --no-merges --format="%H%x09%s")

  # Iterate commits whose subject starts with fixup! or amend!
  while IFS=$'\t' read -r fixup_full subj; do
    local prefix target_subj target_full
    if [[ "$subj" == fixup!\ * ]]; then
      prefix="fixup! "
    else
      prefix="amend! "
    fi
    target_subj="${subj#$prefix}"
    target_full="${subj_to_sha[$target_subj]:-}"
    if [[ -z "$target_full" ]]; then
      echo "WARNING: $prefix commit $fixup_full: no develop commit with subject '$target_subj'" >&2
      continue
    fi
    echo "$target_full $fixup_full"
  done < <(git log develop --not main --no-merges --format="%H%x09%s" \
             | grep -P "\t(fixup|amend)! " || true)
}

# Build set of develop SHAs already covered on backport/main.
# Two mechanisms:
#   1. (cherry picked from commit <sha>) trailers on backport/main commits
#   2. patch-id fallback for plain commits without that trailer
# Output: full SHAs, one per line (may have duplicates; use sort -u downstream).
covered_shas() {
  local backport_branch="${1:-backport}"
  local base="${2:-main}"

  local refs=("$base")
  git rev-parse --verify "$backport_branch" &>/dev/null && refs+=("$backport_branch")

  # Mechanism 1: (cherry picked from commit <sha>) trailers
  git log "${refs[@]}" --not develop --no-merges --format="%B" 2>/dev/null \
  | grep -oP "(?<=\(cherry picked from commit )[0-9a-f]+" \
  | while IFS= read -r sha; do
      git rev-parse --verify "${sha}^{commit}" 2>/dev/null || true
    done || true  # grep exits 1 when no matches — that is fine

  # Mechanism 2: patch-id fallback
  local ref_pids
  ref_pids=$(git log -p "${refs[@]}" --not develop --no-merges 2>/dev/null \
             | git patch-id --stable | awk '{print $1}') || true

  if [[ -n "$ref_pids" ]]; then
    git log -p develop --not main --no-merges | git patch-id --stable \
    | awk -v rpids="$ref_pids" '
        BEGIN { n=split(rpids,a,"\n"); for(i=1;i<=n;i++) ids[a[i]]=1 }
        ids[$1] { print $2 }
      '
  fi
}

# ── Ordered iterator ──────────────────────────────────────────────────────────
# Emits tagged lines oldest-first:
#   merge  <full-sha> <oneline>
#   commit <full-sha> <oneline> [FIXUPS:<sha1>,<sha2>]
#   orphan <full-sha> <oneline> [FIXUPS:<sha1>]
#
# commit/orphan lines may carry a FIXUPS: suffix (comma-separated fixup SHAs,
# oldest-first) for units that need squashing.
iter_ordered() {
  local backport_branch="${1:-backport}"
  local base="${2:-main}"

  mapfile -t good_short < <(good_full | awk '{print substr($1,1,7)}')
  declare -A good_set=()
  for sha in "${good_short[@]}"; do good_set[$sha]=1; done

  # Build fmap: target_full → comma-separated fixup SHAs (oldest-first)
  declare -A fmap_tmp=()
  while IFS=" " read -r target_full fixup_full; do
    if [[ -n "${fmap_tmp[$target_full]+_}" ]]; then
      fmap_tmp[$target_full]+=$'\n'"$fixup_full"
    else
      fmap_tmp[$target_full]="$fixup_full"
    fi
  done < <(fixup_map)

  declare -A fmap=()
  for target in "${!fmap_tmp[@]}"; do
    local reversed
    reversed=$(printf '%s\n' "${fmap_tmp[$target]}" | tac | tr '\n' ',' | sed 's/,$//')
    fmap[$target]="$reversed"
  done

  declare -A under_merge=()

  while read -r merge_sha; do
    read -ra parents <<< "$(git log -1 --format="%P" "$merge_sha")"
    local parent1="${parents[0]}"
    local merge_line
    merge_line=$(git log --no-walk --oneline "$merge_sha")
    local branch_lines=()
    while read -r bsha full; do
      if [[ -n "${good_set[$bsha]+_}" ]]; then
        local fixups_suffix=""
        [[ -n "${fmap[$full]+_}" ]] && fixups_suffix=" FIXUPS:${fmap[$full]}"
        branch_lines+=("$full$fixups_suffix")
        under_merge[$bsha]=1
      fi
    done < <(
      for parent in "${parents[@]:1}"; do
        git log "$parent" --not "$parent1" --no-merges --reverse --format="%h %H"
      done
    )
    if (( ${#branch_lines[@]} > 0 )); then
      echo "merge $merge_sha $merge_line"
      for entry in "${branch_lines[@]}"; do
        local full="${entry%% *}"
        local fixups_part=""
        [[ "$entry" == *" FIXUPS:"* ]] && fixups_part=" ${entry#* }"
        echo "commit $full $(git log --no-walk --oneline "$full")${fixups_part}"
      done
    fi
  done < <(git log develop --not main --merges --format="%H" --reverse)

  for sha in "${good_short[@]}"; do
    if [[ -z "${under_merge[$sha]+_}" ]]; then
      local full
      full=$(git log --no-walk --format="%H" "$sha")
      local fixups_suffix=""
      [[ -n "${fmap[$full]+_}" ]] && fixups_suffix=" FIXUPS:${fmap[$full]}"
      echo "orphan $full $(git log --no-walk --oneline "$full")${fixups_suffix}"
    fi
  done
}

# ── Mode dispatch ─────────────────────────────────────────────────────────────

mode="${1:---list}"

case "$mode" in
  --list)
    good_full | xargs --no-run-if-empty git log --no-walk --oneline
    ;;

  --merges)
    iter_ordered | awk '$1=="merge"{$1=$2=""; print substr($0,3)}' | grep -v " fork:"
    ;;

  --graph)
    current_merge=""
    while IFS= read -r line; do
      tag="${line%% *}"
      rest="${line#* }"
      oneline="${rest#* }"
      oneline="${oneline%% FIXUPS:*}"
      case "$tag" in
        merge)
          [[ -n "$current_merge" ]] && echo "  |"
          current_merge="$oneline"
          echo "* $oneline"
          ;;
        commit) echo "  | $oneline" ;;
        orphan)
          [[ -n "$current_merge" ]] && echo "  |" && current_merge=""
          echo "* (direct) $oneline"
          ;;
      esac
    done < <(iter_ordered | grep -v " fork:")
    [[ -n "$current_merge" ]] && echo "  |"
    ;;

  --ordered)
    iter_ordered | awk '$1=="commit"||$1=="orphan"{print $2}'
    ;;

  --backport-plan)
    backport_branch="${2:-backport}"
    base="${3:-main}"

    # Build patch-id+trailer coverage set (for plain units)
    mapfile -t _covered_arr < <(covered_shas "$backport_branch" "$base" | sort -u)
    declare -A covered=()
    for _sha in "${_covered_arr[@]}"; do
      [[ -n "$_sha" ]] && covered[$_sha]=1
    done

    # Build trailer-only coverage set (for squash units — their patch-id differs)
    _bp_refs=("$base")
    git rev-parse --verify "$backport_branch" &>/dev/null && _bp_refs+=("$backport_branch")
    declare -A trailer_covered=()
    while IFS= read -r _tsha; do
      _full=$(git rev-parse --verify "${_tsha}^{commit}" 2>/dev/null) || continue
      trailer_covered[$_full]=1
    done < <(
      git log "${_bp_refs[@]}" --not develop --no-merges --format="%B" 2>/dev/null \
      | grep -oP "(?<=\(cherry picked from commit )[0-9a-f]+" || true
    )

    while IFS= read -r line; do
      tag="${line%% *}"
      [[ "$tag" != "commit" && "$tag" != "orphan" ]] && continue

      rest="${line#* }"
      orig_sha="${rest%% *}"

      fixups_str=""
      if [[ "$line" =~ FIXUPS:([^[:space:]]+) ]]; then
        fixups_str="${BASH_REMATCH[1]//,/ }"
      fi

      if [[ -z "$fixups_str" ]]; then
        # Plain unit: patch-id or trailer coverage is sufficient
        [[ -n "${covered[$orig_sha]+_}" ]] && continue
      else
        # Squash unit.
        # Case 1: trailer present AND orig's patch not on backport → a previous squash absorbed
        #         orig+fixups into one commit → fully covered, skip.
        if [[ -n "${trailer_covered[$orig_sha]+_}" && -z "${covered[$orig_sha]+_}" ]]; then
          continue
        fi
        # Case 2: orig's patch IS on backport (as a plain commit, with or without -x trailer)
        #         → cherry-pick only the fixups that haven't been applied yet;
        #           autosquash will find the orig by subject and squash them in.
        if [[ -n "${covered[$orig_sha]+_}" ]]; then
          uncovered_fixups=""
          for _f in $fixups_str; do
            [[ -z "${covered[$_f]+_}" ]] && uncovered_fixups+=" $_f"
          done
          uncovered_fixups="${uncovered_fixups# }"
          [[ -z "$uncovered_fixups" ]] && continue
          # Prefix orig with '~': orig is known but must NOT be cherry-picked again.
          echo "~$orig_sha $uncovered_fixups"
          continue
        fi
        # Case 3: neither covered → orig not on backport yet → full unit (orig + fixups).
      fi

      echo "$orig_sha${fixups_str:+ $fixups_str}"
    done < <(iter_ordered "$backport_branch" "$base")
    ;;

  *)
    echo "Usage: $0 [--list|--merges|--graph|--ordered|--backport-plan [<backport-branch> [<base>]]]" >&2
    exit 1
    ;;
esac
