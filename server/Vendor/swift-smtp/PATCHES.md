# dify-sf local patches to swift-smtp 2.19.0

Upstream tag 2.19.0 (sersoft-gmbh/swift-smtp, Apache License 2.0, see LICENSE) is a maintained Swift 6 SMTP client on
swift-nio. Its manifest also declares Vapor 4 (for its optional `SwiftSMTPVapor` target) and swift-docc-plugin; SwiftPM
resolves package-level dependencies even when their targets are unused, so the Vapor 4 requirement conflicts with this
server's Vapor 5 and the upstream package cannot be resolved here.

Changes: `Package.swift` keeps only the `SwiftSMTP` library and its swift-nio / swift-nio-ssl / swift-nio-extras /
swift-algorithms dependencies (all already in the server's graph); the `SwiftSMTPVapor` and `SwiftSMTPCLI` targets, the
tests, the DocC catalogue and the older-toolchain manifests are not copied. `Sources/SwiftSMTP` is upstream's, unchanged.
Drop this directory and depend on the upstream tag again once upstream supports Vapor 5 (or splits off its Vapor target).
