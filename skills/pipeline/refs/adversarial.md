# Adversarial review (`roles.adversarial = true`, default off)

Read when `talos.sh env` prints `ref=adversarial` or `next` answers `dispatch stage=adversarial`.

An optional second opinion, usually on another backend (`agents.roles.adversarial.runner: custom` with `runner_cmd`). Off: no dispatches, and `adversarial:approved` is never required by Step 4.

**Phase 3, after security** (in the draft order it joins the reviewer + security batch): `bash scripts/talos.sh prompt adversarial --issue <N> --pr <PR_NUMBER> --prior-file F`, spawned per the Spawning paragraph. A role named by the re-stamp check gets its re-stamp variant. Then `done adversarial ... --verdict CLEAR|FINDINGS`; `next=fix-round stage=adversarial` is handled exactly like reviewer's and security's (Step 3e: the fix-round gate).
