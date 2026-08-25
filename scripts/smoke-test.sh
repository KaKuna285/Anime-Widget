#!/bin/bash
# Smoke test for anime-downloaded.sh's data-file handling.
#
# The pure "cat"-based read commands (list, history, pending, etc.)
# never parse JSON, so they can't crash on corrupted content -- the
# real risk lives in commands that json.load() a file before writing
# to it. This test targets those specifically: the default
# new-episode case, undo, skip-grade, and dismiss-batch-warning,
# since between them they touch every data file via a real parse.
#
# Runs entirely inside a throwaway sandbox HOME -- never touches
# your real ~/.local/share or ~/.config data. Dev tool only; not
# deployed by install.sh.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/anime-downloaded.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

DATA_DIR="$SANDBOX/.local/share"

PASS_COUNT=0
FAIL_COUNT=0

run() {
    env HOME="$SANDBOX" "$TARGET_SCRIPT" "$@"
}

expect_success() {
    local label="$1"
    shift

    local output
    output="$(run "$@" 2>&1)"
    local exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "PASS: $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: $label (expected success, got exit $exit_code)"
        echo "  Output: $output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Runs a command against corrupted data and checks it fails loudly
# (nonzero exit + non-empty message) rather than succeeding silently
# or crashing with no explanation.
expect_loud_failure() {
    local label="$1"
    shift

    local output
    output="$(run "$@" 2>&1)"
    local exit_code=$?

    if [ "$exit_code" -ne 0 ] && [ -n "$output" ]; then
        echo "PASS: $label (failed loudly as expected)"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$exit_code" -eq 0 ]; then
        echo "FAIL: $label (succeeded silently on corrupted data -- should have failed)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "FAIL: $label (failed with no output -- silent failure, not loud)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

reset_data_dir() {
    rm -rf "$DATA_DIR"
}

echo "=== Phase 1: mutating commands against a fresh environment ==="
reset_data_dir

expect_success "default new-episode case on fresh environment" \
    "[Group] Test Show - 01 (1080p) [ABCD1234].mkv" /some/path "$SANDBOX/some-dir/Test Show" ""

expect_loud_failure "undo on fresh environment (correctly reports nothing to undo)" \
    "undo"

expect_loud_failure "skip-grade on fresh environment (correctly reports no pending grade)" \
    "skip-grade" "Some Series"

expect_success "dismiss-batch-warning on fresh environment" \
    "dismiss-batch-warning" "some-key"

echo ""
echo "=== Phase 2: mutating commands against corrupted data files ==="

# default new-episode case touches TODO, SERIES_MAP, and PENDING
for file_name in anime-todo.json anime-series-map.json anime-pending-matches.json; do
    reset_data_dir
    run list >/dev/null 2>&1  # bootstrap all files to valid empty state first
    echo "not valid json" > "$DATA_DIR/$file_name"

    expect_loud_failure "default new-episode case with corrupted $file_name" \
        "[Group] Test Show - 01 (1080p) [ABCD1234].mkv" /some/path "$SANDBOX/some-dir/Test Show" ""
done

# undo touches HISTORY and LAST_REMOVED
for file_name in anime-history.json anime-last-removed.json; do
    reset_data_dir
    run list >/dev/null 2>&1
    echo "not valid json" > "$DATA_DIR/$file_name"

    expect_loud_failure "undo with corrupted $file_name" "undo"
done

# skip-grade touches PENDING_GRADES
reset_data_dir
run list >/dev/null 2>&1
echo "not valid json" > "$DATA_DIR/anime-pending-grades.json"

expect_loud_failure "skip-grade with corrupted anime-pending-grades.json" \
    "skip-grade" "Some Series"

# dismiss-batch-warning touches BATCH_WARNINGS
reset_data_dir
run list >/dev/null 2>&1
echo "not valid json" > "$DATA_DIR/anime-batch-warnings.json"

# dismiss-batch-warning deliberately treats a corrupted/missing
# warnings file as empty (graceful degradation, not a crash) --
# this is intentional.
expect_success "dismiss-batch-warning with corrupted anime-batch-warnings.json (gracefully treated as empty)" \
    "dismiss-batch-warning" "some-key"

echo ""
echo "=== Sanity check: everything still works after restoration ==="
reset_data_dir
expect_success "list after fresh reset" "list"

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
