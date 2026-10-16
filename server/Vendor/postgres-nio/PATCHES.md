# dify-sf local patches to postgres-nio 1.33.1

Upstream tag 1.33.1 (MIT-style license, see LICENSE) does not compile with the Swift 6.4.1 toolchain:
`ConnectionStateMachine.swift` calls `elementsEqual(_:by:)` on an array of tuples, which is ambiguous
there. The only change is to spell that comparison as a loop. Drop this directory and depend on the
upstream tag again once upstream builds on Swift 6.4.
