#!/usr/bin/env bash
# =============================================================================
# Function : links
# Purpose  : Inspect hard links to a regular file or inspect and repair a
#            symbolic link.
#
# Platform : macOS (BSD utilities) and Linux (GNU utilities)
#
# Usage:
#   links [options] FILE
#
# Options:
#   -l             List hard-link paths associated with a regular file
#   -H             Hard links only
#   -S             Symbolic links only
#   -p DIR         Restrict hard-link discovery to DIR
#   --fix[=DIR]    Repair a broken symlink, searching from DIR or /
#   --fd           Use fd instead of find for a --fix search
#   -h, --help     Display help
#
# Behaviour:
#   * Regular files are inspected only for hard links.
#   * A hard-link count of one means that no additional hard links exist.
#   * Symbolic links are inspected directly; reverse symlink searches are not
#     performed for regular files.
#   * --fix searches for the basename stored in a broken symlink. A unique
#     candidate is selected automatically; ambiguous candidates are presented
#     for interactive selection.
#   * Hard-link searches do not cross filesystem boundaries.
# =============================================================================

links() {
  local OPTIND=1 OPTARG opt
  local list=0 mode="both" scope=""
  local fix=0 fix_scope="" use_fd=0
  local file resolved root os metadata inode device link_count hard_count
  local candidate candidate_metadata candidate_device candidate_inode
  local target target_trimmed search_name selected selection reply temp
  local green yellow red cyan dim reset
  local -a candidates=()

  if [[ -t 1 && ! -v NO_COLOR ]]; then
    green=$'\033[32m'
    yellow=$'\033[33m'
    red=$'\033[31m'
    cyan=$'\033[36m'
    dim=$'\033[2m'
    reset=$'\033[0m'
  else
    green="" yellow="" red=""
    cyan="" dim="" reset=""
  fi

  # Parse long options before getopts handles the remaining short options.
  local -a args=()
  while (($#)); do
    case $1 in
    --fix)
      fix=1
      ;;
    --fix=*)
      fix=1
      fix_scope=${1#*=}
      if [[ -z $fix_scope ]]; then
        printf 'links: --fix requires a non-empty directory after =\n' >&2
        return 2
      fi
      ;;
    --fd)
      use_fd=1
      ;;
    --help)
      args+=(-h)
      ;;
    --)
      shift
      args+=(-- "$@")
      break
      ;;
    --*)
      printf 'links: unknown option %s\n' "$1" >&2
      return 2
      ;;
    *)
      args+=("$1")
      ;;
    esac
    shift
  done
  set -- "${args[@]}"

  while getopts ":lHSp:h" opt; do
    case $opt in
    l)
      list=1
      ;;
    H)
      if [[ $mode == soft ]]; then
        printf 'links: -H and -S are mutually exclusive\n' >&2
        return 2
      fi
      mode="hard"
      ;;
    S)
      if [[ $mode == hard ]]; then
        printf 'links: -H and -S are mutually exclusive\n' >&2
        return 2
      fi
      mode="soft"
      ;;
    p)
      scope=$OPTARG
      ;;
    h)
      cat <<'EOF'
Usage: links [options] FILE

Inspect hard links to a regular file or inspect a symbolic link.

Options:
  -l             List hard-link paths associated with a regular file
  -H             Hard links only
  -S             Symbolic links only
  -p DIR         Restrict hard-link discovery to DIR
  --fix[=DIR]    Repair a broken symlink, searching from DIR or /
  --fd           Use fd instead of find for a --fix search
  -h, --help     Show this help

Examples:
  links file.txt
  links -l file.txt
  links -lH -p ~/Documents file.txt
  links symlink.txt
  links --fix broken_symlink.txt
  links --fd --fix=~/Documents broken_symlink.txt

Notes:
  A regular file with an st_nlink value of one has no additional hard links.
  Regular files are never searched for symbolic links pointing to them.
  An unrestricted --fix search starts at / and may take considerable time.
EOF
      return 0
      ;;
    :)
      printf 'links: option -%s requires an argument\n' "$OPTARG" >&2
      return 2
      ;;
    *)
      printf 'links: unknown option -%s\n' "$OPTARG" >&2
      return 2
      ;;
    esac
  done

  shift $((OPTIND - 1))
  if (($# != 1)); then
    printf 'Usage: links [-l] [-H | -S] [-p DIR] [--fix[=DIR]] [--fd] FILE\n' >&2
    return 2
  fi
  file=$1

  if ((use_fd && ! fix)); then
    printf 'links: --fd may only be used with --fix\n' >&2
    return 2
  fi
  if ((fix)) && [[ $mode == hard ]]; then
    printf 'links: --fix cannot be used with -H\n' >&2
    return 2
  fi
  if ((fix)) && [[ -n $scope ]]; then
    printf 'links: use --fix=DIR, not -p DIR, to scope a repair search\n' >&2
    return 2
  fi
  if [[ ! -e $file && ! -L $file ]]; then
    printf '%sERROR%s File not found: %s\n' "$red" "$reset" "$file" >&2
    return 1
  fi

  os=$(uname -s)

  _links_stat() {
    if [[ $os == Darwin ]]; then
      stat -f '%d %i %l' "$1"
    else
      stat -c '%d %i %h' -- "$1"
    fi
  }

  # A symbolic link is inspected directly. No reverse lookup is needed.
  if [[ -L $file ]]; then
    target=$(readlink -- "$file") || {
      printf 'links: unable to read symbolic link: %s\n' "$file" >&2
      return 1
    }

    if [[ $mode == hard ]]; then
      printf '%sNo hard links:%s %s is a symbolic link\n' \
        "$dim" "$reset" "$file"
      return 0
    fi

    if [[ -e $file ]]; then
      resolved=$(realpath -- "$file") || resolved=$target
      printf '%sSYMLINK (valid)%s %s -> %s\n' \
        "$green" "$reset" "$file" "$target"
      printf '%sSource:%s %s\n' "$cyan" "$reset" "$resolved"
      if ((fix)); then
        printf 'links: no repair needed\n'
      fi
      return 0
    fi

    printf '%sSYMLINK (broken)%s %s -> %s\n' \
      "$red" "$reset" "$file" "$target"
    if ((! fix)); then
      printf '%sUse --fix to search for the missing source.%s\n' \
        "$dim" "$reset"
      return 0
    fi

    if ((use_fd)) && ! command -v fd >/dev/null 2>&1; then
      printf 'links: --fd requested but fd is not installed\n' >&2
      return 1
    fi

    if [[ -n $fix_scope ]]; then
      root=$(realpath -- "$fix_scope" 2>/dev/null) || {
        printf 'links: invalid repair search directory: %s\n' \
          "$fix_scope" >&2
        return 1
      }
      if [[ ! -d $root ]]; then
        printf 'links: invalid repair search directory: %s\n' "$root" >&2
        return 1
      fi
    else
      root=/
      printf '%sWARNING:%s searching the entire filesystem may take considerable time.\n' \
        "$yellow" "$reset" >&2
    fi

    target_trimmed=${target%/}
    search_name=${target_trimmed##*/}
    if [[ -z $search_name ]]; then
      printf 'links: cannot derive a source name from target: %s\n' \
        "$target" >&2
      return 1
    fi

    printf '%sSearching for source:%s %s under %s\n' \
      "$cyan" "$reset" "$search_name" "$root"

    if ((use_fd)); then
      while IFS= read -r -d '' candidate; do
        [[ -L $candidate ]] || candidates+=("$candidate")
      done < <(
        fd -u -a -0 --exact "$search_name" "$root" 2>/dev/null
      )
    else
      while IFS= read -r -d '' candidate; do
        candidates+=("$candidate")
      done < <(
        find "$root" ! -type l -name "$search_name" -print0 2>/dev/null
      )
    fi

    if ((${#candidates[@]} == 0)); then
      printf 'links: no source candidate found for %s\n' "$target" >&2
      return 1
    fi

    if ((${#candidates[@]} == 1)); then
      selected=${candidates[0]}
    else
      printf 'Multiple source candidates found:\n'
      local i
      for ((i = 0; i < ${#candidates[@]}; i++)); do
        printf '  %d) %s\n' "$((i + 1))" "${candidates[i]}"
      done
      printf '  0) Exit without repairing\n'

      if [[ ! -t 0 ]]; then
        printf 'links: ambiguous repair requires interactive input; no change made\n' >&2
        return 1
      fi

      while :; do
        printf 'Select a source [0-%d]: ' "${#candidates[@]}"
        IFS= read -r reply || return 1
        if [[ $reply == 0 ]]; then
          printf 'links: no change made\n'
          return 0
        fi
        if [[ $reply =~ ^[0-9]+$ ]]; then
          selection=$((10#$reply))
          if ((selection >= 1 && selection <= ${#candidates[@]})); then
            selected=${candidates[selection - 1]}
            break
          fi
        fi
        printf 'links: invalid selection\n' >&2
      done
    fi

    selected=$(realpath -- "$selected") || {
      printf 'links: unable to resolve selected source: %s\n' "$selected" >&2
      return 1
    }
    temp="${file}.links.$$"
    if [[ -e $temp || -L $temp ]]; then
      printf 'links: temporary path already exists: %s\n' "$temp" >&2
      return 1
    fi
    if ! ln -s -- "$selected" "$temp"; then
      printf 'links: unable to create replacement symlink\n' >&2
      return 1
    fi
    if ! mv -f -- "$temp" "$file"; then
      rm -f -- "$temp"
      printf 'links: unable to replace broken symlink\n' >&2
      return 1
    fi

    printf '%sRepaired:%s %s -> %s\n' \
      "$green" "$reset" "$file" "$selected"
    return 0
  fi

  # A regular file is never searched for reverse symbolic links.
  if ((fix)); then
    printf 'links: --fix requires a symbolic link\n' >&2
    return 1
  fi

  resolved=$(realpath -- "$file") || {
    printf 'links: unable to resolve %s\n' "$file" >&2
    return 1
  }
  metadata=$(_links_stat "$resolved") || return 1
  read -r device inode link_count <<<"$metadata"
  hard_count=$((link_count - 1))

  printf '%sFile:%s %s\n' "$cyan" "$reset" "$resolved"
  printf 'Inode:      %s\n' "$inode"
  if ((hard_count == 0)); then
    printf 'Hard links: none\n'
    return 0
  fi
  printf 'Hard links: %d additional path(s)\n' "$hard_count"

  if [[ $mode == soft ]]; then
    printf '%sNo symbolic link:%s %s is a regular file\n' \
      "$dim" "$reset" "$file"
    return 0
  fi

  if ((! list)); then
    printf '%sUse -l to list the associated paths.%s\n' "$dim" "$reset"
    return 0
  fi

  if [[ -n $scope ]]; then
    root=$(realpath -- "$scope" 2>/dev/null) || {
      printf 'links: invalid search directory: %s\n' "$scope" >&2
      return 1
    }
  else
    root=$(df -P "$resolved" | awk 'END {print $NF}') || return 1
  fi
  if [[ ! -d $root ]]; then
    printf 'links: invalid search directory: %s\n' "$root" >&2
    return 1
  fi

  printf '\n%sSearching:%s %s\n' "$cyan" "$reset" "$root"
  printf '\n%sHard links:%s\n' "$cyan" "$reset"

  local found=0
  while IFS= read -r -d '' candidate; do
    candidate_metadata=$(_links_stat "$candidate" 2>/dev/null) || continue
    read -r candidate_device candidate_inode _ <<<"$candidate_metadata"
    [[ $candidate_device == "$device" ]] || continue
    [[ $candidate_inode == "$inode" ]] || continue
    [[ $candidate == "$resolved" ]] && continue

    ((found += 1))
    printf '  %sHARD%s %s\n' "$green" "$reset" "$candidate"
  done < <(
    find "$root" -xdev ! -type l -inum "$inode" -print0 2>/dev/null
  )

  if ((found == 0)); then
    printf '  %sNone found in search scope%s\n' "$dim" "$reset"
  fi
  printf '\nFound %d of %d additional hard-link path(s) in %s\n' \
    "$found" "$hard_count" "$root"
}
