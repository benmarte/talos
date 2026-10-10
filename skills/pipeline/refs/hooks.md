# Hooks

Read when `talos.sh env` prints `ref=hooks` (`hooks.pre_dispatch` is set).

**`hooks.pre_dispatch`.** Before ANY stage prompt run `bash scripts/pipeline-hooks.sh pre_dispatch <role> <N> <PR> <worktree> > "$PRE"` (`PRE` from `mktemp`) and pass `--preamble-file "$PRE"` to `talos.sh prompt`. A failure, a timeout or empty output is a silent no-op: dispatch without the preamble.

`post_stage` events are sent by `talos.sh done`; nothing to run by hand.
