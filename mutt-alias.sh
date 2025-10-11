#!/usr/bin/env bash

# Exit on error or use of undeclared variable or pipe error.
set -o errtrace -o errexit -o nounset -o pipefail
[[ "${TRACE:-0}" == "1" ]] && set -o xtrace

# Try to inherit ERR in functions; do not abort if unsupported.
shopt -s inherit_errexit 2>/dev/null || true

IFS=$'\n\t'
PS4='+\t '

# Error trap with context preview.
error_handler() {
  local line="$1" callstack="$2" cmd="$3" status="$4"
  echo >&2 "Error: In ${BASH_SOURCE[0]}, Lines ${line} and ${callstack}, Command ${cmd} exited with Status ${status}"
  local start=$(( line - 3 ))
  if (( start < 1 )); then start=1; fi
  pr -tn "${BASH_SOURCE[0]}" | tail -n +"${start}" | head -n 7 | sed '4s/^[[:space:]]*/>>> /' >&2
  exit "$status"
}
trap 'error_handler $LINENO "$BASH_LINENO" "$BASH_COMMAND" $?' ERR

###############################################################################
# Compatibility helpers and dependency checks.
###############################################################################

# Bash version and feature detection.
BASH_MAJOR=${BASH_VERSINFO[0]:-3}
if (( BASH_MAJOR < 4 )); then
  echo "Warning: Bash >= 4 is needed for best performance (associative arrays, case mods). Falling back to slower methods." >&2
fi

# Lowercasing helper compatible with older bash.
if ((BASH_MAJOR >= 4)); then
  to_lower() { printf '%s' "${1,,}" ; }
else
  to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ; }
fi

###############################################################################
# Address parsing and sanitation utilities.
###############################################################################

# Address parsing and sanitation utilities.
# Split an RFC 5322 address list into one address-spec per line, ignoring commas
# inside double quotes, angle brackets, or comments (parentheses).
split_addrlist() {
  local s="$1"
  # Keep integer state. Use assignments with $(( ... )) so status is always 0.
  # This avoids tripping `set -e`/ERR trap on normal falsey results.
  local -i in_quote=0 in_angle=0 paren_depth=0 esc=0
  local ch acc=''

  # Read byte-wise to track state deterministically.
  while IFS= read -r -n1 ch; do
    # If last char was an escape inside quotes, take this char verbatim.
    if (( esc )); then
      acc+="$ch"; esc=0; continue
    fi
    case "$ch" in
      \\)
        if (( in_quote )); then esc=1; fi
        acc+="$ch"
        ;;
      '"')
        # Toggle quote state without using (( ... )) as a command.
        in_quote=$(( in_quote ^ 1 ))
        acc+="$ch"
        ;;
      '<')
        # Increment angle depth safely.
        in_angle=$(( in_angle + 1 ))
        acc+="$ch"
        ;;
      '>')
        # Decrement angle depth safely.
        if (( in_angle > 0 )); then in_angle=$(( in_angle - 1 )); fi
        acc+="$ch"
        ;;
      '(')
        # Increment paren depth safely.
        paren_depth=$(( paren_depth + 1 ))
        acc+="$ch"
        ;;
      ')')
        # Decrement paren depth safely.
        if (( paren_depth > 0 )); then paren_depth=$(( paren_depth - 1 )); fi
        acc+="$ch"
        ;;
      ',')
        # Only split on commas at top-level (not in quotes/angles/paren comments).
        if (( in_quote==0 && in_angle==0 && paren_depth==0 )); then
          printf '%s\n' "$acc"
          acc=''
        else
          acc+="$ch"
        fi
        ;;
      $'\r'|$'\n')
        # Ignore newlines in already-unfolded header text.
        ;;
      *)
        acc+="$ch"
        ;;
    esac
  done < <(printf '%s' "$s")

  if [[ -n "$acc" ]]; then
    printf '%s\n' "$acc"
  fi
}

# ASCII transliteration (folding) for human names.
# - Prefer iconv(1) with //TRANSLIT (widely available).
# - Fallback to Python 3 NFKD decomposition, then Perl, then lossy ASCII strip.
# - Always return a string; never propagate an error (avoid tripping -e).
ascii_fold() {
  local s="$1" out rc=0
  if command -v iconv >/dev/null 2>&1; then
    # iconv transliteration (glibc/libiconv): e.g., Ä->Ae, Ö->Oe, ß->ss.
    out="$(printf '%s' "$s" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$s" <<'PY' || rc=$?
import sys, unicodedata
s = sys.argv[1]
print(unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode('ascii'), end='')
PY
    if (( rc == 0 )); then return 0; fi
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -MUnicode::Normalize -CS -e '$_=shift; $_=NFKD($_); s/\pM+//g; print' -- "$s" && return 0 || true
  fi
  # Last-resort: drop non-ASCII.
  LC_ALL=C printf '%s' "$s" | sed 's/[^[:print:]\t ]//g'
}

###############################################################################
# RFC 2047 "encoded-words" decoder for display names.
# - Prefer Python 3 email.header (stdlib, robust).
# - Fallback to Perl Encode::MIME::Header.
# - Always succeed; never trip -e/-o pipefail.
###############################################################################
decode_mime_header() {
  local s="$1" out rc=0
  # Fast return on empty
  [[ -n "$s" ]] || { printf '%s' "$s"; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    out="$(python3 - "$s" <<'PY' || rc=$?
import sys
from email.header import decode_header, make_header
s = sys.argv[1]
try:
    print(str(make_header(decode_header(s))), end='')
except Exception:
    print(s, end='')
PY
)"
    if (( rc == 0 )); then printf '%s' "$out"; return 0; fi
  fi
  if perl -e 'use Encode::MIME::Header;' >/dev/null 2>&1; then
    perl -CS -MEncode -e 'binmode STDOUT, ":encoding(UTF-8)"; $_=shift; print decode("MIME-Header", $_)' -- "$s" 2>/dev/null || true
    return 0
  fi
  printf '%s' "$s"
}

# Trim leading/trailing whitespace and collapse internal whitespace to single spaces.
trim_collapse_ws() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

# Address parsing: extract email and display name from one address-spec.
# - Prefer angle-bracket form.
# - Otherwise, extract the first full email token anywhere without partial matches.
# - Print: email TAB display-name (name may be empty).
extract_email_and_name() {
  local spec="$1" email name rx
  email=$(sed -nE 's/.*<([^>]*)>.*/\1/p' <<< "$spec")
  if [[ -n "$email" ]]; then
    name=$(sed 's/<[^>]*>.*$//' <<< "$spec" | trim_collapse_ws)
    name="${name%\"}"; name="${name#\"}"
  else
    # Use the same email regexp as elsewhere, with a local fallback for safety.
    rx="${email_regexp:-[[:alnum:]._%+-]+@([[:alnum:]-]+\.)+[[:alpha:]]{2,}}"
    # Extract the first full email match; tolerate no-match under set -e -o pipefail.
    email=$(grep -Eo "$rx" <<< "$spec" | head -n1 || true)
    name=""
  fi
  printf '%s\t%s\n' "$email" "$name"
}

# Sanitize alias from local-part:
# Keep locale alphanumerics (incl. umlauts/accents); collapse everything else to hyphens.
sanitize_alias() {
  local lp="$1" out
  out="$(to_lower "$lp")"
  out=$(sed -E 's/[^[:alnum:]]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g' <<< "$out")
  printf '%s' "$out"
}

# Build alias from display name:
# - Collapse whitespace and lowercase.
# - Reorder "Last, First" to "First Last" for alias generation.
# - Replace spaces with hyphens.
# - Keep locale alphanumerics (incl. umlauts/accents); collapse other chars to hyphens.
# - Collapse duplicate separators and trim edges.
alias_from_display_name() {
  local name="$1" out
  # Normalize spacing first to ensure only plain spaces remain.
  out="$(printf '%s' "$name" | trim_collapse_ws)"
  # Reorder "Last, First" => "First Last" (only affects alias generation).
  if [[ "$out" =~ ^([^,]+),[[:space:]]*([^,]+)$ ]]; then
    out="${BASH_REMATCH[2]} ${BASH_REMATCH[1]}"
  fi
  # Fold to ASCII before lowercasing to match requested behavior (e.g., "Jürgen" -> "jurgen").
  out="$(ascii_fold "$out")"
  out="$(to_lower "$out")"
  # Spaces to hyphens, then collapse non-alnum (from current locale) to hyphens.
  out="${out// /-}"
  out="$(sed -E 's/[^[:alnum:]-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' <<< "$out")"
  printf '%s' "$out"
}

# Normalize display name:
# - Drop comma in "Last, First" by default (keep order), unless KEEP_COMMA=1.
# - Collapse whitespace; ensure safe for double-quote wrapping by escaping ".
normalize_display_name() {
  local name="$1" out
  out="$name"
  if [[ "${KEEP_COMMA:-0}" != "1" ]]; then
    out=$(sed -E 's/^([^,]+),[[:space:]]*([^,]+)$/\1 \2/' <<< "$out")
  fi
  out=$(printf '%s' "$out" | trim_collapse_ws)
  out="${out//\"/\\\"}"
  printf '%s' "$out"
}

# Define usage.
usage() {
  cat <<EOF
Usage: $0 [-a alias file] [-d days] [-p] [-f] [-F] [-b] [-n] [-C] DIRECTORIES
Built mutt aliases from maildir emails in DIRECTORIES.
OPTIONS:
  -a          alias file (default: value of \$alias_file in ~/.muttrc)
  -d          maximal number of days since last sent mail to (default: 0 = unlimited)
  -p          purge aliases previously added by $0
  -f          filter out added email addresses that are probably impersonal
  -F          filter out all email addresses that are probably impersonal
  -b          backup the current alias file (if it exists) to *.prev
  -n          create a new alias file instead of modifying the current one
  -C          keep commas in display names (default: drop comma in "Last, First")
  -h          display this help and exit
EOF
  exit 1
}

# Parse options.
max_age=0
purge='false'
filter='false'
Filter='false'
backup='false'
new='false'
KEEP_COMMA=0

while getopts 'a:d:pfFbnhC' opt; do
  case "${opt}" in
    a) alias_file="$OPTARG" ;;
    d) max_age="$OPTARG" ;;
    p) purge='true' ;;
    f) filter='true' ;;
    F) Filter='true' ;;
    b) backup='true' ;;
    n) new='true' ;;
    C) KEEP_COMMA=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

[ $# -eq 0 ] && usage

# Resolve alias file if not provided (guard against nounset).
if [ -z "${alias_file:-}" ]; then
  if command -v mutt >/dev/null 2>&1; then
    alias_file="$(mutt -Q alias_file 2>/dev/null | sed -nE 's/^alias_file\s*=\s*//p')"
  elif command -v neomutt >/dev/null 2>&1; then
    alias_file="$(neomutt -Q alias_file 2>/dev/null | sed -nE 's/^alias_file\s*=\s*//p')"
  elif [ -f "$HOME/.muttrc" ]; then
    alias_file="$(sed -nE 's/^\s*set\s+alias_file\s*=\s*//p' "$HOME/.muttrc" | head -n1)"
  else
    alias_file=""
  fi
fi
alias_file="${alias_file%\"}"
alias_file="${alias_file#\"}"
case "${alias_file:-}" in
  "~") alias_file="$HOME" ;;
  "~/"*) alias_file="$HOME/${alias_file#~/}" ;;
esac

# Allow creation when -n is set; otherwise require existing file.
if ! [ -f "${alias_file:-}" ]; then
  if [ "$new" = 'true' ] && [ -n "${alias_file:-}" ]; then
    mkdir -p -- "$(dirname -- "$alias_file")"
    : > "$alias_file"
  else
    echo "No alias file found. Exiting!"
    exit 1
  fi
fi

# Make backup and/or clear previous database.
alias_file_prev="${alias_file}.prev"
if [ -f "${alias_file}" ]; then
  if [ "$backup" = 'true' ] && [ "$new" = 'true' ]; then
    mv "${alias_file}" "${alias_file_prev}"
  elif [ "$backup" = 'true' ] && [ "$new" = 'false' ]; then
    cp "${alias_file}" "${alias_file_prev}"
  elif [ "$backup" = 'false' ] && [ "$new" = 'true' ]; then
    rm "${alias_file}"
  fi
fi

touch "$alias_file"
echo "Using ${alias_file} to store aliases..."

# Make temporary copy of alias file.
alias_file_orig="${alias_file}"
TMPDIR=${TMPDIR:-/tmp}
tmp_dir=$(mktemp -d "$TMPDIR/mutt-alias.XXXXXXXXXX")
cleanup_tmp() { rm -rf -- "${tmp_dir}"; }
trap 'cleanup_tmp' EXIT
alias_file="${tmp_dir}/aliases"
alias_file_new="${tmp_dir}/aliases.new"
cp "${alias_file_orig}" "${alias_file}"
: > "${alias_file_new}"

email_regexp="[[:alnum:]._%+-]+\@([[:alnum:]-]+\.)+[[:alpha:]]{2,}"

if [ "$purge" = 'true' ]; then
  # Purge lines previously added by this tool, regardless of alias/local-part relation.
  tmp_purge="${tmp_dir}/aliases.purged"
  if ! grep -Eiv '^alias [^#]*# mutt-alias: e-mail sent on ' "${alias_file}" > "${tmp_purge}"; then
    : > "${tmp_purge}"
  fi
  mv "${tmp_purge}" "${alias_file}"
fi

# Preload seen email addresses from existing alias file to avoid duplicates.
if (( BASH_MAJOR >= 4 )); then
  # Associative-array path (Bash >= 4).
  declare -A SEEN_EMAILS
  while IFS= read -r _addr; do
    [[ -n "$_addr" ]] || continue
    _addr="$(to_lower "$_addr")"
    SEEN_EMAILS["$_addr"]=1
  done < <(sed -nE 's/.*<([^>]+)>.*/\1/p' "${alias_file}")
  seen_has() { local a; a="$(to_lower "$1")"; [[ -n "${SEEN_EMAILS[$a]:-}" ]]; }
  seen_add() { local a; a="$(to_lower "$1")"; SEEN_EMAILS["$a"]=1; }
else
  # File-backed path (Bash 3.x).
  seen_emails_file="${tmp_dir}/seen_emails"
  : > "$seen_emails_file"
  sed -nE 's/.*<([^>]+)>.*/\1/p' "${alias_file}" | while IFS= read -r _addr; do
    printf '%s\n' "$(to_lower "$_addr")"
  done >> "$seen_emails_file"
  seen_has() {
    local a; a="$(to_lower "$1")"
    # Return 0 if found, 1 otherwise.
    grep -Fqx -- "$a" "$seen_emails_file" >/dev/null 2>&1
  }
  seen_add() {
    local a; a="$(to_lower "$1")"
    printf '%s\n' "$a" >> "$seen_emails_file"
  }
fi

NOW=$(date +%s)
old_IFS=$IFS
for directory in "$@"; do
  # Restore IFS during loop body.
  IFS=${old_IFS}
  echo "Processing ${directory}"
  if [ "${max_age}" = "0" ]; then
    emails="$(find "${directory}" -type f -print)"
  else
    emails="$(find "${directory}" -type f -mtime "-${max_age}" -print)"
  fi

  [ -n "$emails" ] || continue
  for email in $emails; do
    # Parse "To:" (unfolded).
    in_to="$(awk 'BEGIN {found="no"}; ((found=="yes") && /^\S/) || /^$/ {exit}; (found=="yes") && /^\s/ { printf "%s", $0 }; /^To:/ {found="yes"; sub(/^To: ?/, "", $0) ; printf "%s", $0}' "$email")"

    # Parse "Date:" and convert to epoch (0 if missing or unparsable).
    in_date="$(awk 'BEGIN {found="no"}; ((found=="yes") && /^\S/) || /^$/ {exit}; (found=="yes") && /^\s/ { printf "%s", $0 }; /^Date:/ {found="yes"; sub(/^Date: ?/, "", $0) ; printf "%s", $0}' "$email")"
    out_date="$( date --date="$in_date" +%s 2>/dev/null || echo 0 )"
    [ -z "${out_date}" ] && out_date="0"

    epoch=0
    if [[ -n "$in_date" ]]; then
      epoch=$(date -ud "$in_date" +%s 2>/dev/null || echo 0)
    fi
    if [[ "$max_age" != "0" && $epoch -gt 0 ]]; then
      out_age=$(( (NOW - epoch) / 86400 ))
    fi
    if (( epoch > 0 )); then
      hr_out_date=$(date -ud "@$epoch" +%Y-%m-%d@%H:%M:%S)
    else
      hr_out_date="$in_date"
    fi

    # Robustly split To: into address-specs using a state machine.
    [ -n "$in_to" ] || continue
    while IFS= read -r each_to; do
      # Extract email and display name (raw, unescaped for alias derivation).
      IFS=$'\t' read -r out_to name_raw <<<"$(extract_email_and_name "$each_to")"

      # Skip if no valid email.
      if [[ -z "$out_to" ]]; then
        continue
      fi

      # Decode RFC 2047-encoded display names before alias generation.
      name_raw="$(decode_mime_header "$name_raw")"

      # Normalize case of email (mutt treats addresses case-insensitively).
      out_to="$(to_lower "$out_to")"

      # - If display name is present, build alias from it.
      # - Otherwise, use full local-part.
      if [[ -n "$name_raw" ]]; then
        alias_to="$(alias_from_display_name "$name_raw")"
      else
        alias_to="$(sanitize_alias "${out_to%@*}")"
      fi
      # Fallback to local-part if the result is empty after sanitization.
      if [[ -z "$alias_to" ]]; then
        alias_to="$(sanitize_alias "${out_to%@*}")"
      fi

      # Normalize decoded display name for storage (escaping, commas policy).
      name_to="$(normalize_display_name "$name_raw")"

      if [[ "$out_to" =~ ^${email_regexp}$ ]]; then
        # Default unknown age to 0 to avoid arithmetic errors under -e.
        out_age=${out_age:-0}
        # Apply age filter first, then duplicate filter.
        if [ "0" = "$max_age" ] || [ "$out_age" -lt "$max_age" ]; then
          if ! seen_has "$out_to"; then
            new_entry="alias ${alias_to} \"${name_to}\" <${out_to}> # mutt-alias: e-mail sent on ${hr_out_date}"
            echo "${new_entry}" >> "${alias_file_new}"
            seen_add "$out_to"
          fi
        fi
      fi
    done < <(split_addrlist "$in_to")
  done
done

# Restore IFS.
IFS=${old_IFS}

# ERE-compatible approximation of word-boundary for email-like tokens.
# This avoids GNU grep -P.
begin_ere='(^|[^[:alnum:]._%+-])'
end_ere='($|[^[:alnum:]._%+-])'
middle_ere='([[:alnum:]._%+-]*([0-9]{9,}|([0-9]+[a-z]+){3,}|\+|nicht-?antworten|ne-?pas-?repondre|not?[-_.]?reply|(un)?subscribe|MAILER-DAEMON)[[:alnum:]._%+-]*@([[:alnum:]-]+\.)+[[:alpha:]]{2,})'
filter_regexp="${begin_ere}${middle_ere}${end_ere}"

if [ "$filter" = 'true' ]; then
  if ! grep -Eiv -- "$filter_regexp" "${alias_file_new}" > "${alias_file_new}.filtered"; then
    : > "${alias_file_new}.filtered"
  fi
  mv "${alias_file_new}.filtered" "${alias_file_new}"
fi

# Append new entries to the alias file.
cat "${alias_file_new}" >> "${alias_file}"
rm -f "${alias_file_new}"

if [ "$Filter" = 'true' ]; then
  if ! grep -Eiv -- "$filter_regexp" "${alias_file}" > "${alias_file}.filtered"; then
    : > "${alias_file}.filtered"
  fi
  mv "${alias_file}.filtered" "${alias_file}"
fi

# Override alias file by temporary copy of alias file.
mv "${alias_file}" "${alias_file_orig}"

# Return time it took to run, removing leading zeros.
format_duration() {
  local s="$1"
  local h=$(( s / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local sec=$(( s % 60 ))
  printf '%02d:%02d:%02d' "$h" "$m" "$sec"
}
TOTALTIME=$(format_duration "$SECONDS" | sed -E 's/^0(0:(0)?)?//')
echo "Database updated in ${TOTALTIME}."
