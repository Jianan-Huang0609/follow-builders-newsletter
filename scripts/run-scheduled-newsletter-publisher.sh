#!/usr/bin/env bash

set -euo pipefail

export TZ="${TZ:-Asia/Shanghai}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PUBLISH_SCRIPT="${REPO_ROOT}/scripts/publish-daily-newsletter.sh"
LOCK_DIR="${TMPDIR:-/tmp}/follow-builders-newsletter.lock"
LOOKBACK_DAYS="${PUBLISH_LOOKBACK_DAYS:-2}"
RETRY_ATTEMPTS="${PUBLISH_RETRY_ATTEMPTS:-2}"
RETRY_SLEEP_SECONDS="${PUBLISH_RETRY_SLEEP_SECONDS:-90}"
OPENCLAW_TIMEOUT_SECONDS="${OPENCLAW_TIMEOUT_SECONDS:-1800}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"
}

date_days_ago() {
  local offset="$1"
  if [[ "${offset}" == "0" ]]; then
    date +%Y-%m-%d
    return
  fi
  if date -v-"${offset}"d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"${offset}"d +%Y-%m-%d
    return
  fi
  date -d "${offset} days ago" +%Y-%m-%d
}

issue_json_path() {
  local publish_date="$1"
  printf '%s/data/issues/ai-builders-digest-%s.json' "${REPO_ROOT}" "${publish_date}"
}

issue_html_path() {
  local publish_date="$1"
  printf '%s/issues/ai-builders-digest-%s-rerun.html' "${REPO_ROOT}" "${publish_date}"
}

issue_exists() {
  local publish_date="$1"
  [[ -f "$(issue_json_path "${publish_date}")" && -f "$(issue_html_path "${publish_date}")" ]]
}

emit_candidate_dates() {
  local raw_dates="${NEWSLETTER_DATES:-}"
  if [[ -n "${raw_dates}" ]]; then
    printf '%s\n' "${raw_dates}" | tr ', ' '\n\n' | awk 'NF { print $0 }'
    return
  fi
  local offset
  for ((offset=LOOKBACK_DAYS; offset>=0; offset--)); do
    date_days_ago "${offset}"
  done
}

publish_date() {
  local publish_date="$1"
  local attempt=1

  if issue_exists "${publish_date}"; then
    log "Issue ${publish_date} already exists; skipping."
    return 0
  fi

  while (( attempt <= RETRY_ATTEMPTS )); do
    log "Publishing ${publish_date} (attempt ${attempt}/${RETRY_ATTEMPTS})..."

    if NEWSLETTER_DATE="${publish_date}" \
      OPENCLAW_TIMEOUT_SECONDS="${OPENCLAW_TIMEOUT_SECONDS}" \
      SKIP_GIT=1 \
      /bin/bash "${PUBLISH_SCRIPT}"; then
      if issue_exists "${publish_date}"; then
        log "Published ${publish_date} successfully."
        return 0
      fi
      log "Publish flow finished without both JSON and HTML for ${publish_date}."
    else
      local exit_code=$?
      log "Publish flow for ${publish_date} failed with exit code ${exit_code}."
    fi

    if (( attempt < RETRY_ATTEMPTS )); then
      log "Sleeping ${RETRY_SLEEP_SECONDS}s before retrying ${publish_date}."
      sleep "${RETRY_SLEEP_SECONDS}"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

main() {
  local failed=0

  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    log "Another scheduled publisher run is already active; skipping."
    exit 0
  fi
  trap 'rmdir "${LOCK_DIR}" >/dev/null 2>&1 || true' EXIT

  while IFS= read -r publish_date; do
    [[ -n "${publish_date}" ]] || continue
    if ! publish_date "${publish_date}"; then
      failed=1
    fi
  done < <(emit_candidate_dates)

  # Push generated issues to GitHub Pages
  log "Pushing to GitHub Pages..."
  cd "${REPO_ROOT}"
  if git add data/issues/ issues/ index.html 2>/dev/null; then
    if ! git diff --cached --quiet; then
      TODAY=$(date +%Y-%m-%d)
      git commit -m "publish: daily digest ${TODAY} [skip ci]" 2>/dev/null || true
      if git push origin main 2>/dev/null; then
        log "GitHub Pages updated: https://jianan-huang0609.github.io/follow-builders-newsletter/"
      else
        log "WARNING: git push failed (will retry next run)"
      fi
    else
      log "No new changes to push"
    fi
  fi

  if (( failed )); then
    log "Scheduled publisher finished with at least one failed date."
    exit 1
  fi
  log "Scheduled publisher finished successfully."
}

main "$@"
