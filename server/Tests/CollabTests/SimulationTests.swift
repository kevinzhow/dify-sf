import Testing
import CollabCore
import CollabInvariants
@testable import CollabSim

@Suite("Named scenarios (S1-S8)")
struct ScenarioTests {
    @Test(arguments: 0..<Scenarios.all.count)
    func scenario(_ i: Int) {
        let r = Scenarios.all[i]()
        for c in r.checks where !c.ok { Issue.record("\(r.name): check failed: \(c.what)") }
        for v in r.violations { Issue.record("\(r.name): invariant violated: \(v)") }
        #expect(r.passed, "\(r.name)")
    }
}

@Suite("Randomised simulation")
struct FuzzTests {
    /// 5 profiles x 2000 seeds = 10,000 runs. Every run must satisfy I1-I5.
    @Test(arguments: Profile.allCases)
    func profileHasNoViolations(_ p: Profile) {
        let base = UInt64(p.rawValue) * 1_000_000 + 1
        let report = Fuzz.runMany(from: base, count: 2000, profile: p)
        for f in report.failures.prefix(3) {
            Issue.record("seed \(f.seed) (\(p.name)): \(f.violations.prefix(3))")
        }
        #expect(report.runs == 2000)
        #expect(report.failureCount == 0)
        // Make sure the profile genuinely exercised the hard paths.
        #expect(report.stats["op.committed"] > 10_000)
        #expect(report.stats["op.rejected"] > 0)
    }

    @Test func runsAreDeterministic() {
        for seed: UInt64 in [3, 44, 555] {
            let a = Fuzz.execute(seed: seed).0
            let b = Fuzz.execute(seed: seed).0
            #expect(a.committedLog == b.committedLog)
            #expect(a.rec.stats.counters == b.rec.stats.counters)
        }
    }
}

/// Mutation tests: with a deliberate bug switched on, the checkers MUST report violations.
/// If these ever pass vacuously the whole validation is meaningless.
@Suite("Invariant checkers detect injected bugs")
struct MutationTests {
    @Test func staleCheckRemovedIsCaughtByI2() {
        let r = Fuzz.runMany(from: 1, count: 300, defects: .skipStaleCheck)
        #expect(r.failureKinds["I2", default: 0] > 100)
    }
    @Test func missingBrokenMarkersCaughtByI4() {
        let r = Fuzz.runMany(from: 1, count: 300, defects: .skipBrokenMarkers)
        #expect(r.failureKinds["I4", default: 0] > 100)
    }
    @Test func noRetransmitCaughtByConvergenceAndI5() {
        let r = Fuzz.runMany(from: 1, count: 300, defects: .clientNeverResends)
        #expect(r.failureKinds["I5", default: 0] > 100 && r.failureKinds["I3", default: 0] > 100)
    }
    @Test func noDedupCaughtByLogChecks() {
        let r = Fuzz.runMany(from: 1, count: 300, defects: .noDedup)
        #expect(r.failureKinds["LOG", default: 0] > 100)
    }
    @Test func sameValueConflictsCaughtByI6() {
        let r = Fuzz.runMany(from: 1, count: 300, defects: .sameValueConflicts)
        #expect(r.failureKinds["I6", default: 0] > 20)
    }
    @Test func equalValueWriteTakingTheStampIsCaughtByI2() {
        let r = Fuzz.runMany(from: 1, count: 4000, defects: .equalValueRestamps)
        #expect(r.failureKinds["I2", default: 0] > 0)
        // ... and the named 3-step regression scenario fails by itself on the mutant, passes on the real thing.
        #expect(!Scenarios.equalValueTrace(defects: .equalValueRestamps).passed)
        #expect(Scenarios.equalValueTrace(defects: []).passed)
    }
    @Test func ackBeforeFsyncCaughtByI1() {
        let r = Fuzz.runMany(from: 1, count: 300, lossyDisk: true)
        #expect(r.failureKinds["I1", default: 0] > 50)
    }
}
