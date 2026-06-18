#!/usr/bin/env bash
# fan-out investigation orchestrator for `sift auto`. spawns one fresh
# headless pi session per phase and per lead — the new process per lead is
# the context manager (no compaction, no deadline, no sidecar). all state is
# plain files in the run dir:
#   leads.txt      the worklist (agents append to it via `sift queue`)
#   segments/*.md  one write-up per lead (agents fill via `sift note`)
#   report.md      the deliverable
# re-running resumes: planning is skipped once leads.txt exists, and any lead
# whose segment already exists is skipped.
#
# env supplied by `sift auto`: PI_BIN, SIFT_SKILL, SIFT_SYSTEM_PROMPT, and the
# ALEPH_* creds/paths the `sift` tools read. args: <run-dir> <brief-file>.
set -euo pipefail

RUN_DIR="$1"; BRIEF="$2"
SEG="$RUN_DIR/segments"; LEADS="$RUN_DIR/leads.txt"; REPORT="$RUN_DIR/report.md"
mkdir -p "$SEG"

run_pi() { "$PI_BIN" --skill "$SIFT_SKILL" --system-prompt "$SIFT_SYSTEM_PROMPT" \
    --no-session -p --mode text "$1"; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//;s/-$//' | cut -c1-40; }
segfile() { printf '%s/%s-%s.md' "$SEG" "$(slug "$1")" "$(printf '%s' "$1" | shasum | cut -c1-6)"; }

# phase 0 — plan. one session turns the brief into a queued worklist.
if [[ ! -f "$LEADS" ]]; then
    : > "$LEADS"
    echo "[auto] planning from $(basename "$BRIEF")"
    SIFT_TOPIC_LIST="$LEADS" run_pi "You are planning an investigation. Read the brief below and build a worklist of concrete leads to investigate. Work one angle at a time: run 'sift search \"<angle>\"' to confirm the collection holds something, then immediately queue that lead with 'sift queue \"<lead>\"' before moving on. Drop angles that return nothing. Keep it to roughly a dozen leads, split large subjects apart, and do not investigate deeply or write anything up — this is only reconnaissance. Stop once the worthwhile leads are queued.

BRIEF:
$(cat "$BRIEF")"
fi

# phase 1 — sweep. one fresh session per pending lead; re-scan each pass so
# leads queued mid-sweep get picked up. a lead is done once its segment exists.
i=0
while :; do
    lead=""; seg=""
    while IFS= read -r line; do
        case "$line" in ''|'#'*|'✓'*) continue ;; esac
        s="$(segfile "$line")"
        [[ -s "$s" ]] && continue
        lead="$line"; seg="$s"; break
    done < "$LEADS"
    [[ -z "$lead" ]] && break
    i=$((i + 1))
    echo "[auto] lead $i: $lead"
    SIFT_SEGMENT="$seg" SIFT_TOPIC_LIST="$LEADS" run_pi "Investigate this single lead against the collection and write up what you find. Search, read what matters, and pivot with similar / expand / hubs to follow the trail. The moment a document establishes something — a party, an account, an asset, a payment, an ownership or control link — record it with 'sift note \"<finding>\"' in neutral, wire-service prose, citing the source alias (r4) inline so every claim is traceable. Open with 'sift note \"## <lead>\"'. If the trail forks or runs deeper than one sitting, append the follow-up with 'sift queue \"<lead>\"' and stop — a fresh session will take it. Stop when this lead is exhausted.

LEAD: $lead" || echo "[auto] pi exited nonzero on this lead — continuing"
    # never retry a lead that produced nothing: leave an honest marker so the
    # scan above treats it as done.
    [[ -s "$seg" ]] || printf '## %s\n\n(no findings recorded.)\n' "$lead" > "$seg"
done
# guard on segments, not work-done-this-run, so a fully-resumed sweep still
# reaches the report instead of erroring.
shopt -s nullglob; segs=("$SEG"/*.md); shopt -u nullglob
[[ ${#segs[@]} -gt 0 ]] || { echo "[auto] no leads to sweep — delete $LEADS to re-plan"; exit 1; }

# phase 2 — reduce. one session stitches the segments into the report.
echo "[auto] writing report.md"
run_pi "The sweep is complete. Read every file under $SEG (each is one lead's write-up) and stitch them into a single coherent investigation at $REPORT. Merge what overlaps, fold duplicated parties into one account, flag where two segments contradict each other, and order the material so it reads as one report rather than a pile of leads. Write in neutral, wire-service prose: state what the documents show, don't editorialise, no 'major' / 'explosive' / 'breakthrough', no exclamation marks. Carry through the source alias (r4) each load-bearing claim cites, and use markdown tables for structured data. End with a Sources table — every alias cited, one row each with a short note of what it is ('sift read <alias>' prints its Aleph url for an [open](<url>) link) — then the open questions and next steps a reporter would need. Write $REPORT and stop." || true

if [[ -s "$REPORT" ]]; then echo "[auto] done — report.md in $RUN_DIR"
else echo "[auto] done — no report.md written; segments are in $SEG"; fi
