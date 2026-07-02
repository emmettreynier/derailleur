#!/usr/bin/env bash
# Create the orchestrator label set in a repo.
# Usage: ./setup-labels.sh owner/repo
# Idempotent: --force updates color/description if the label already exists.
set -euo pipefail
REPO="${1:?usage: setup-labels.sh owner/repo}"

create() { gh label create "$1" -R "$REPO" --color "$2" --description "$3" --force; }

# Loop-driving labels the digest script keys on (see design.md).
create needs-input      "d93f0b" "Worker/checker escalated a question — your court (answer)"
create resume           "0e8a16" "Worker's court: your answer is in, or checker found worker-fixable changes to address"
create needs-definition "fbca04" "Orchestrator verdict: under-specified — your court (author criteria)"
create checked-pass     "0e8a16" "Checker passed it (criteria met; any findings are yours to weigh) — your court (review & merge)"
create hold             "6a737b" "Your pre-emptive 'not ready' — orchestrator skips entirely"
create blocked          "b60205" "Waiting on something external"

echo "Orchestrator labels created in $REPO"
