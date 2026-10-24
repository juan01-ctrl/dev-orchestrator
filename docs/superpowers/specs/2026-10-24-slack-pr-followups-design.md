# Slack PR follow-ups

## Intent

Allow a user to reply to a delivered task's Slack report with text or one audio
attachment, review the understood adjustment, and explicitly approve an update to
the same open pull request. Do not create another Linear issue or start from scratch.

## Approach

Reuse versioned Slack drafts and workflow-v2 continuation checkpoints. A separate
follow-up system would duplicate transcription, confirmation, recovery and fencing;
automatic execution of every reply would remove the existing approval boundary.
The user authorized planning followed by implementation. Builder's choice: retain
explicit confirmation, since the user did not choose direct execution.

Store the report thread's organization, project, Slack workspace/channel and run
lifecycle after Slack acknowledges delivery. Subsequent reports use that root.
Only explicit mentions enter intake; no broad message history or new subscriptions.
Slack-origin tasks retain their original requester restriction. For tasks without
a Slack requester, a channel member may propose an update, as with initial intake;
only that draft's author can revise, confirm or cancel it.

Add target run/lifecycle/head fields to existing drafts. Known report threads must
never fall through to new Linear task creation. Allow a single active follow-up per
run. Each proposal freezes the reviewed head and lifecycle; stale buttons, duplicate
events, different authors and changed heads cannot enqueue another update.

Before generation and after approval, verify the existing PR is open and its current
repository, branch, base and head match the stored delivery. Recheck state and live
executor binding under a run lock before enqueueing. Provider calls stay outside
locks. Closed/merged PRs, missing context, expired checkpoints, changed configuration
or busy runs receive a clear response rather than a fresh task or branch.

Reuse the original executor, conversation, branch, baseline, frozen checks and normal
fast-forward publication. Explicit human approvals are independent of the optional
three-round CI repair budget. Increment a separate manual-follow-up counter so
reports remain distinct. Limit each approval to twenty active minutes and require a
delivery within seven days (the local retention contract). Merge remains human.

No npm release, deployment, permission changes, model changes or live provider writes
are part of implementation. Existing reports cannot be backfilled without Slack
history; only reports delivered after this migration have a durable thread mapping.

## Verification

Cover text/audio generation, report receipt persistence and thread reuse, original
author and tenant isolation, stale/duplicate approvals, closed/changed PRs, revoked
executors, new lifecycle fencing, distinct delivery reports and no Linear creation.
Use existing provider transport fixtures. Run connector and full platform suites;
record database restrictions instead of treating offline checks as SQL proof.
