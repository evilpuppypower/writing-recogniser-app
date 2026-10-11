#!/usr/bin/env bash
# Security check for the CI workflows (this repo is public, and CI holds the
# signing key). Fails if a workflow:
#  - uses an action by tag or branch instead of a full commit SHA;
#  - runs on events outsiders can cause that get secrets
#    (pull_request_target, workflow_run, issue_comment, issues, discussion,
#    discussion_comment, fork, watch), in any trigger syntax;
#  - has no top-level permissions: block;
#  - uses github.event or github.head_ref in ${{ }} anywhere except as an
#    UPPER_CASE value inside an env: block (script injection, including through action
#    inputs like script:);
#  - grants write permissions other than checks: write.
# Run locally or in CI: tool/security_check.sh
set -u
status=0
fail() { echo "SECURITY: $1"; status=1; }

shopt -s nullglob globstar
for f in .github/workflows/*.yml .github/workflows/*.yaml .github/actions/**/action.yml .github/actions/**/action.yaml; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    n=${line%%:*}; text=${line#*:}
    ref=$(printf '%s' "$text" | sed -E 's/.*uses:[[:space:]]*["'"'"']?([^[:space:]#"'"'"']+).*/\1/')
    case "$ref" in ./*|docker://*) continue ;; esac
    printf '%s' "$ref" | grep -Eq '@[0-9a-f]{40}$' \
      || fail "$f line $n: action not pinned to a commit SHA ($ref)"
  done < <(grep -n -E '^[[:space:]-]*uses:' "$f")
  # Comments removed, so a mention in a comment doesn't count.
  body=$(sed -E 's/(^|[[:space:]])#.*$//' "$f")
  # Triggers outsiders can cause that run with this repo's secrets.
  while IFS= read -r n; do
    [ -n "$n" ] && fail "$f line $n: trigger not allowed (pull_request_target, workflow_run, issue_comment, issues, discussion, discussion_comment, fork, watch)"
  done < <(printf '%s\n' "$body" \
    | awk '/^["'"'"']?on["'"'"']?:/ { on = 1 } on && /^[A-Za-z]/ && !/^["'"'"']?on["'"'"']?:/ { on = 0 } { print (on ? $0 : "") }' \
    | grep -n -E '\b(pull_request_target|workflow_run|issue_comment|issues|discussion|discussion_comment|fork|watch)\b' | cut -d: -f1)
  # Write permissions, in any YAML style, except checks: write.
  while IFS= read -r n; do
    [ -n "$n" ] && fail "$f line $n: write permission other than checks: write"
  done < <(printf '%s\n' "$body" | sed -E 's/checks:[[:space:]]*["'"'"']?write["'"'"']?//g' \
    | grep -n -E 'write-all|[a-z-]+:[[:space:]]*["'"'"']?write\b' | cut -d: -f1)
  # Workflows must say what the token may do (least privilege).
  case "$f" in
    .github/workflows/*) grep -q -E '^permissions:' "$f" || fail "$f: no top-level permissions: block" ;;
  esac
  # Event text (titles, branch names, comments...) only as an UPPER_CASE
  # value inside an env: block; anywhere else it can inject commands.
  awk -v f="$f" '
    function col(s) { match(s, /[^ ]/); return RSTART }
    { line = $0; sub(/(^|[ \t])#.*$/, "", line) }
    line ~ /^[ \t]*$/ { next }
    inenv && col(line) <= envcol { inenv = 0 }
    line ~ /^[ \t-]*env:[ \t]*$/ { inenv = 1; envcol = index(line, "env:"); next }
    line ~ /\$\{\{[^}]*github\.(event|head_ref)([^A-Za-z0-9_]|$)/ {
      if (!(inenv && line ~ /^[ \t]+[A-Z_][A-Z0-9_]*:[ \t]*\$\{\{/)) {
        printf "SECURITY: %s line %d: github.event/head_ref text outside an UPPER_CASE env: value\n", f, NR; bad = 1
      }
    }
    END { exit bad }' "$f" || status=1
done
[ $status -eq 0 ] && echo "security check: clean" || echo "security check: FAILED (see lines above)" >&2
exit $status
