"""pipeline-secret-shapes.py -- the one list of secret-shaped values (#444).

Stdlib only. pipeline-config.sh prepends this file's text to the source of the
`python3 -I` process that loads the config (so there is no extra spawn) and
calls secret_shape() on every leaf of the project and global layers. A value
that matches names its shape and is dropped as absent; the key is named, the
value never is. The fix the message gives is the same every time: put the value
in ~/.talos/.env and reference it as env:NAME (a value starting `env:` is never
checked).

The patterns are deliberately narrow, so ordinary config (a #channel, a path,
https://hooks.example.com) never matches. The handoff validator in
pipeline-worktree.sh (_WT_HF_PY) keeps a broader list of its own; every shape
here must also be caught there, and tests/test-worktree-checkpoint.sh fails
when one is not. A new shape needs a fixture in
tests/test-config-secret-shapes.sh and a matching entry in that list.
"""

import re

SECRET_SHAPES = tuple((name, re.compile(rx)) for name, rx in (
    ("slack-token", r"xox[abposr]-[A-Za-z0-9-]{8,}"),
    ("slack-webhook", r"hooks\.slack\.com/services/[A-Za-z0-9]+/[A-Za-z0-9]+/[A-Za-z0-9]{20,}"),
    ("discord-webhook", r"discord(?:app)?\.com/api/(?:v\d+/)?webhooks/\d+/[A-Za-z0-9_-]{20,}"),
    ("teams-webhook", r"office(?:365)?\.com/webhook(?:b2)?/[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{20,}"),
    ("github-token", r"gh[pousr]_[A-Za-z0-9]{20,}"),
    ("github-pat", r"github_pat_[A-Za-z0-9_]{20,}"),
    ("gitlab-pat", r"glpat-[A-Za-z0-9_-]{20,}"),
    # Anchored so a word that merely ends in "sk" (task-, risk-) never matches.
    ("openai-key", r"(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"),
    ("aws-access-key", r"AKIA[0-9A-Z]{16}"),
    ("private-key", r"-----BEGIN [A-Z ]*PRIVATE KEY"),
    ("nostr-nsec", r"nsec1[02-9ac-hj-np-z]{16,}"),
))


def secret_shape(value):
    """The name of the first shape `value` holds, or None. Only strings are
    checked, and a value that starts `env:` is a reference, never a secret."""
    if not isinstance(value, str) or value.startswith("env:"):
        return None
    for name, rx in SECRET_SHAPES:
        if rx.search(value):
            return name
    return None
