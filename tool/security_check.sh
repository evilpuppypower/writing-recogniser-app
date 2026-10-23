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
#  - grants write permissions other than checks: write (and contents:
#    write for the publish job of the hand-run model workflow, see below).
# Triggers are read with yq (preinstalled on GitHub's runners), so every
# way of writing them in YAML is seen.
# Run locally or in CI: tool/security_check.sh
set -u
status=0
fail() { echo "SECURITY: $1"; status=1; }

shopt -s nullglob globstar
if ! yq --version 2>/dev/null | grep -q mikefarah; then
  echo "SECURITY: needs yq (github.com/mikefarah/yq, preinstalled on GitHub's runners)"
  exit 1
fi
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
  # Triggers outsiders can cause that run with this repo's secrets: as
  # written (any line in the on: block), and as YAML reads them.
  while IFS= read -r n; do
    [ -n "$n" ] && fail "$f line $n: trigger not allowed (pull_request_target, workflow_run, issue_comment, issues, discussion, discussion_comment, fork, watch)"
  done < <(printf '%s\n' "$body" \
    | awk '/^["'"'"']?on["'"'"']?:/ { on = 1 } on && /^[A-Za-z]/ && !/^["'"'"']?on["'"'"']?:/ { on = 0 } { print (on ? $0 : "") }' \
    | grep -n -E '\b(pull_request_target|workflow_run|issue_comment|issues|discussion|discussion_comment|fork|watch)\b' | cut -d: -f1)
  triggers=''
  case "$f" in
    .github/workflows/*)
      if ! triggers=$(yq '.on | (select(tag == "!!map") | keys | .[]), (select(tag == "!!seq") | .[]), (select(tag == "!!str"))' "$f" 2>&1); then
        fail "$f: can't be read as YAML ($triggers)"
        triggers=''
      fi
      bad=$(printf '%s\n' "$triggers" | grep -x -E 'pull_request_target|workflow_run|issue_comment|issues|discussion|discussion_comment|fork|watch' | tr '\n' ' ')
      [ -n "$bad" ] && fail "$f: trigger not allowed ($bad)"
      ;;
  esac
  # The scanned-PDF model workflow publishes a release (owner, 2026-10-23):
  # its publish job may have contents: write and nothing else, and only
  # while the workflow runs by hand alone (workflow_dispatch its only
  # trigger). Its other permissions are checked as usual.
  perms="$body"
  if [ "$f" = .github/workflows/ocr-models.yml ]; then
    publish=$(yq -o=json -I=0 '.jobs.publish.permissions' "$f" 2>/dev/null)
    if [ "$triggers" = workflow_dispatch ] && [ "$publish" = '{"contents":"write"}' ]; then
      perms=$(yq 'del(.jobs.publish.permissions)' "$f" | sed -E 's/(^|[[:space:]])#.*$//')
    else
      fail "$f: must run by hand only (on: workflow_dispatch alone), with contents: write in the publish job only"
    fi
  fi
  # Write permissions, in any YAML style, except checks: write.
  while IFS= read -r n; do
    [ -n "$n" ] && fail "$f line $n: write permission other than checks: write"
  done < <(printf '%s\n' "$perms" | sed -E 's/checks:[[:space:]]*["'"'"']?write["'"'"']?//g' \
    | grep -n -E 'write-all|[a-z-]+:[[:space:]]*["'"'"']?write\b' | cut -d: -f1)
  # Workflows must say what the token may do (least privilege).
  case "$f" in
    .github/workflows/*) grep -q -E '^permissions:' "$f" || fail "$f: no top-level permissions: block" ;;
  esac
  # Event text (titles, branch names, comments...) only as an UPPER_CASE
  # value inside an env: block; anywhere else it can inject commands.
  awk -v f="$f" '
    function col(s) { match(s, /[^ ]/); return RSTART }
    # Only whole-line comments are skipped: a "#" inside a script is not
    # a comment.
    { line = $0; sub(/^[ \t]*#.*$/, "", line) }
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
