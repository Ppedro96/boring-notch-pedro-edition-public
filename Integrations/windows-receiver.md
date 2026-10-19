# Windows receiver recovery

The existing hidden, limited interactive supervisor watches only its current
native child's newly appended UDP listener failure event. Historical log entries,
inactive peers and missing traffic do not trigger a restart. A fresh byte boundary
is established for every child. Log replacement or truncation fails closed.

A fatal listener event stops that owned child and permits at most three replacement
attempts per supervisor session, with delays of one, two and four seconds. Failure
to create a child, confirm ownership, meet the fifteen-second native readiness
deadline, or confirm activation ends recovery. An in-flight bounded IPC or ownership
query can delay reporting that deadline. Unexpected process exit also ends
recovery. An explicit start is required after the budget is exhausted.

Recovery preserves the certificate and profile byte for byte. Configuration bytes
remain pinned except during an owned activation transaction or an inactive reset
before replacement. Each native activation is followed by a synchronization reply
and exact semantic validation before approving its new bytes. Native formatting,
address ordering, omission of default client ports and omission of false activation
flags are accepted; only the specifically requested peer flag may change. Peer
definitions, grants, backends, ports and all other fields must remain unchanged,
including unexpected fields. Intermediate two-peer activation states are validated
separately. The lifecycle lock excludes monitoring during the native truncate/write
interval; a failed confirmation refuses recovery instead of adopting a new hash.
Replacement resets only the validated activation flags before spawning, preventing
startup activation before native backend readiness.
Only the exact configured neighboring peers are restored, after both native
backends are ready and only while explicit activation intent remains set.

Receiver health is reported separately from the native capture and emulation
fields. Starting, recovering and failed receivers are excluded from controller
readiness. Unconfirmed activity continues to be retained by the controller.
If the operating system refuses to stop a child, its ownership evidence is retained
and the supervisor reports failure without spawning another child.

Deliberate stop clears the generation and activation intent while holding an OS
file lock, then stops the existing scheduled task and reaps matching owned children.
Spawn and activation use that same lock. A stop racing a spawn waits for the spawn
to finish, fences future launches and then reaps the child. Delayed invocations from
an older generation cannot start another child.

Local tests use temporary processes and files with simulated native IPC. They do
not exercise real input, Windows scheduling or physical network behavior. A reviewed
Windows rollout must deploy both supervisor helpers together, update the controller
readiness adapter, reuse the existing task and retain its hidden limited interactive
execution settings. Verify protected identity and the configured topology before
and after, then perform a physical input comparison. macOS and Linux native process
lifecycle behavior and the upstream native binary are unchanged.
