//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

package import Tracing

package struct LogTracer: Tracer {
    package typealias Span = NoOpSpan

    package init() {}

    package func startAnySpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> any Tracing.Span {
        print("Starting span")
        return NoOpSpan(context: context())
    }

    package func forceFlush() {
        print("Flushing")
    }

    package func inject<Carrier, Inject>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    )
    where Inject: Injector, Carrier == Inject.Carrier {
        // no-op
    }

    package func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    )
    where Extract: Extractor, Carrier == Extract.Carrier {
        // no-op
    }

    package struct NoOpSpan: Tracing.Span {
        package let context: ServiceContext
        package var isRecording: Bool {
            false
        }

        package var operationName: String {
            get { "noop" }
            nonmutating set {
                // ignore
            }
        }

        package init(context: ServiceContext) {
            self.context = context
        }

        package func setStatus(_ status: SpanStatus) {}

        package func addLink(_ link: SpanLink) {}

        package func addEvent(_ event: SpanEvent) {}

        package func recordError<Instant: TracerInstant>(
            _ error: any Error,
            attributes: SpanAttributes,
            at instant: @autoclosure () -> Instant
        ) {}

        package var attributes: SpanAttributes {
            get { [:] }
            nonmutating set {
                // ignore
            }
        }

        package func end<Instant: TracerInstant>(at instant: @autoclosure () -> Instant) {
            print("Ending span")
        }
    }
}
