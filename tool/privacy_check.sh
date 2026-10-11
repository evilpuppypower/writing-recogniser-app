#!/usr/bin/env bash
# Privacy check for this public repo: fails if any file or text could
# identify the owner. Run before every commit, PR, issue or comment.
#
#   tool/privacy_check.sh                 # all tracked files
#   tool/privacy_check.sh FILE...         # only these files
#   echo "text" | tool/privacy_check.sh - # text (PR body, comment, commit message)
#
# Two kinds of checks:
#  - generic ones below (email addresses, phone numbers, time zones and
#    UTC offsets, device brands and models, certificate details, private
#    keys, Claude session links), safe to publish;
#  - the owner's own details (name, city, ...), which must never be written
#    here: one regular expression per line in the PRIVACY_PATTERNS
#    environment variable (a GitHub secret in CI) or in the file named by
#    PRIVACY_PATTERNS_FILE (kept outside the repo).
set -u

generic='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'            # email
generic+='|\+[0-9]{1,3}[ -]?\(?[0-9]{1,4}\)?[ -][0-9]{3,4}[ -]?[0-9]{3,4}' # phone
generic+='|\+[0-9]{10,14}\b'                                        # phone without spaces
generic+='|\b(Africa|America|Antarctica|Asia|Atlantic|Australia|Europe|Indian|Pacific)/[A-Z][A-Za-z_]+' # time zone
generic+='|\b(Samsung|S Pen|Galaxy|One UI|Xiaomi|Huawei|Lenovo|OnePlus|Wacom|Apple Pencil|Surface Pro|iPad|Pixel [0-9])\b' # device brands (models: owner patterns)
generic+='|\b(CN|OU|O|L|ST|C)=[^,]*, ?(CN|OU|O|L|ST|C)='                # certificate details (name, place, country)
generic+='|\b(UTC|GMT) ?[+-] ?[0-9]{1,2}\b'                           # UTC offset
generic+='|(^|[^0-9])[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)? ?[+-][0-9]{2}:?[0-9]{2}\b' # time with a UTC offset (e.g. 12:00:00+0530)
generic+='|\b[0-9]{1,2}:[0-9]{2} [+-][0-9]{4}\b'                       # (e.g. 12:00 +0530)
generic+='|\b[0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} [+-][0-9]{4}\b'          # git log dates
generic+='|BEGIN [A-Z ]*PRIVATE KEY'
generic+='|BEGIN CERTIFICATE|byte\[\] *BYTES *= *new byte'              # certificates (incl. MyScript's)
generic+='|\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}' # GitHub tokens
generic+='|\bAKIA[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{35}\b'                # AWS / Google API keys
generic+='|\bsk-[A-Za-z0-9_-]{20,}|\bxox[abpr]-[A-Za-z0-9-]{10,}'           # API keys, Slack tokens
generic+='|\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' # UUID-style keys (MyScript application key)
generic+='|(password|passwd|secret|hmac|api[_-]?key)["'"'"' ]*[:=] *["'"'"'][A-Za-z0-9+/_=-]{12,}["'"'"']' # hard-coded secret
generic+='|claude\.ai/code/session'                                   # Claude session links (owner: never publish)

# Case-sensitive checks.
generic_cs='MII[A-Za-z0-9+/]{60,}'                                      # base64 key or keystore

# Allowed: no-reply addresses used for commit credits, example domains and
# git's SSH address. Removed from each line before checking, so a real
# address on the same line is still caught.
allowed='[A-Za-z0-9._%+-]*noreply@anthropic\.com|noreply@github\.com|[A-Za-z0-9._%+-]*@users\.noreply\.github\.com|[A-Za-z0-9._%+-]*@example\.(com|org)|git@github\.com'

owner=''
if [ -n "${PRIVACY_PATTERNS:-}" ]; then owner="$PRIVACY_PATTERNS"; fi
if [ -n "${PRIVACY_PATTERNS_FILE:-}" ] && [ -f "$PRIVACY_PATTERNS_FILE" ]; then
  owner="$owner"$'\n'"$(cat "$PRIVACY_PATTERNS_FILE")"
fi
owner_re=$(printf '%s\n' "$owner" | tr -d '\r' | sed '/^[[:space:]]*$/d;/^#/d' | paste -sd'|' -)
# A broken owner pattern must fail loudly, not quietly check nothing.
if [ -n "$owner_re" ]; then
  printf 'x\n' | grep -E -i -- "$owner_re" >/dev/null 2>&1
  if [ $? -eq 2 ]; then
    echo "privacy check: an owner pattern is not a valid regular expression" >&2
    exit 2
  fi
fi

scan() { # $1 = label, reads text on stdin; -a also reads binary files
  local text hits
  text=$(tr -d '\000')
  hits=$(printf '%s\n' "$text" | sed -E "s/$allowed//g" | grep -a -n -E -i -- "$generic" || true)
  hits+=$'\n'$(printf '%s\n' "$text" | grep -a -n -E -- "$generic_cs" || true)
  if [ -n "$owner_re" ]; then
    hits+=$'\n'$(printf '%s\n' "$text" | grep -a -n -E -i -- "$owner_re" || true)
  fi
  hits=$(printf '%s\n' "$hits" | sed '/^$/d')
  if [ -n "$hits" ]; then
    # Don't echo the matched text itself into public logs: line numbers only.
    printf '%s\n' "$hits" | cut -d: -f1 | sort -un | sed "s|^|PRIVACY: $1 line |"
    return 1
  fi
}

status=0
if [ "${1:-}" = "-" ]; then
  scan "text" || status=1
else
  if [ $# -gt 0 ]; then files=("$@"); else mapfile -d '' -t files < <(git ls-files -z); fi
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # Files that must never be in the repo, whatever is inside them.
    if printf '%s\n' "$f" | grep -q -i -E -- '\.(jks|keystore|p12|pfx|pem|key|apk|aab|zip|gz|tgz|7z|rar|tar|jpe?g|heic|heif|tiff?|mp4|mov|pdf|docx?|xlsx?)$|(^|/)(key\.properties|\.env|MyCertificate\.java)$|privacy_patterns'; then
      echo "PRIVACY: $f must not be committed"; status=1; continue
    fi
    case "$f" in tool/privacy_check.sh) continue ;; esac
    # Binary files (e.g. images) are scanned too, for text inside them
    # such as metadata. Photos, videos, PDFs and office files are blocked
    # above: their metadata can hold names, places and devices.
    scan "$f" < "$f" || status=1
  done
fi
if [ -z "$owner_re" ]; then
  echo "privacy check: no owner patterns set (PRIVACY_PATTERNS); generic checks only" >&2
fi
[ $status -eq 0 ] && echo "privacy check: clean" || echo "privacy check: FAILED (see lines above)" >&2
exit $status
