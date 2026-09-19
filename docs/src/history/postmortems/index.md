# Postmortems

Written when something broke badly enough that the fix is not obvious from the
diff, and kept afterwards because the reasoning is the part that does not
survive in git.

The house style: a timeline with real timestamps, impact **measured** rather
than estimated, and a "what went badly" section that is allowed to be
unflattering. A postmortem that only lists what went well is a press release.

| Date       | Title                                                                                             | One-line cause                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| 2026-09-16 | [A dependency window that took the box down for six minutes](2026-09-16-flake-update-rollback.md) | a three-second transient in one non-critical container made deploy-rs abort, and the abort stopped every container |

The structural lesson from that one is in
[Failure modes](../../operations/recovery.md#the-abort-that-was-worse-than-the-failure):
a failed activation leaves the box on the previous generation's
_configuration_, not its previous _running state_.
