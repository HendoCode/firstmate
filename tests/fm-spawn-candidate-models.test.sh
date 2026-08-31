#!/usr/bin/env bash
# tests/fm-spawn-candidate-models.test.sh - --candidate-models is recorded in
# task meta and preserved across relaunch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-candidate-models)

test_candidate_models_recorded_on_fresh_spawn() {
  local dir home proj wt fakebin id
  dir="$TMP_ROOT/fresh"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  id=cand-fresh

  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fakebin=$(fm_test_make_spawn_fakebin "$dir")

  if ! FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off \
      --harness claude --model claude-sonnet \
      --candidate-models "claude-sonnet,claude-opus" >/dev/null 2>&1; then
    fail "spawn with --candidate-models failed"
  fi
  assert_grep "model_candidates=claude-sonnet,claude-opus" "$home/state/$id.meta" "candidate list not recorded in meta"
  pass "fresh spawn records --candidate-models in task meta"
}

test_candidate_models_preserved_through_relaunch() {
  local dir home proj wt fakebin id meta
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  id=cand-relaunch
  meta="$home/state/$id.meta"

  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fakebin=$(fm_test_make_spawn_fakebin "$dir")

  # Initial spawn.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off \
      --harness claude --model claude-sonnet \
      --candidate-models "claude-sonnet,claude-opus" >/dev/null 2>&1
  expect_code 0 "$?" "initial spawn should succeed"

  # Pretend the agent has exited so relaunch is allowed.
  printf 'backend=tmux\nwindow=tmux:fm-%s\n' "$id" >> "$meta"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch --model claude-opus >/dev/null 2>&1 || true

  assert_grep "model_candidates=claude-sonnet,claude-opus" "$meta" "candidate list lost across relaunch"
  pass "relaunch preserves recorded candidate list"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  "$t"
done
printf 'ok - all candidate-models tests passed\n'
