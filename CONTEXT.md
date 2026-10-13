# Status Watchr personal monitoring

Status Watchr lets its owner follow coding work from a phone while that work runs on their work computer.

## Language

**Conversation**:
A continuing exchange with a coding agent that can contain multiple runs. It is the unit for choosing whether completion and attention notifications are enabled.
_Avoid_: Agent, when referring to the notification preference's scope.

**Conversation title**:
The existing name of a Codex conversation, used by the owner to recognize it in the private phone dashboard. It is distinct from the conversation's message contents.
_Avoid_: Prompt summary, when referring to the displayed title.

**Subtask conversation**:
A conversation spawned within another conversation. The dashboard groups it under its highest retained parent and includes its activity in that parent's log. Its completion does not determine the parent's status.
_Avoid_: Duplicate task, when identities differ but names share a parent title.

**Run**:
One period of agent work responding to a request within a conversation. A finished run does not establish that the entire assignment has been successfully completed.
_Avoid_: Completed assignment, when only the run has finished.

**Watched conversation**:
A conversation whose owner has enabled completion and attention notifications. It remains watched across subsequent runs until the owner mutes it.
_Avoid_: One-shot watch.

**Completion notification**:
An optional alert for a watched conversation when a run finishes and remains its latest finished run after a five-second confirmation window. A queued follow-up that resumes work suppresses the earlier completion alert. Each eligible finished run produces at most one completion notification.
_Avoid_: Assignment-success notification.

**Attention request**:
A distinct question or approval request that asks for the owner's input. A question can remain outstanding while the conversation continues working. An outstanding request remains the same request when observed again. The local question-alert trial is disabled by default; see [its behavior and verification boundary](docs/question-alert-trial.md).
_Avoid_: Completion, when work is waiting for input.

**Attention notification**:
An alert that a watched conversation needs the owner's input. Each distinct attention request produces one notification, with no repeated alerts for that same outstanding request.
_Avoid_: Repeated reminder.
