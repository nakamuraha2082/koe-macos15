import Foundation

@main
enum TriggerStateMachineCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ behavior: String) {
        print("\(condition ? "PASS" : "FAIL"): \(behavior)")
        if !condition { failures += 1 }
    }

    static func main() {
        checkTriggerStateMachine()
        checkLiveTextReconciler()
        checkCumulativeRecognition()
        checkUserDictionary()
        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("all checks passed")
    }

    typealias Machine = TriggerStateMachine

    static func checkCumulativeRecognition() {
        var transcript = Transcript()
        var reconciler = LiveTextReconciler()
        transcript.receiveCumulative("音声入力のテスト", isFinal: false)
        reconciler.observe(transcript, at: 0)
        _ = reconciler.sync(at: 1)
        transcript.receiveCumulative("", isFinal: false)
        check(transcript.text == "音声入力のテスト", "recognition: empty partial preserves recognized text")
        transcript.receiveCumulative("", isFinal: true)
        reconciler.observe(transcript, at: 2)
        check(transcript.finalized == "音声入力のテスト", "recognition: empty final keeps the recognized sentence")
        check(reconciler.finish().isEmpty, "recognition: releasing the recording key never erases text on an empty final")
        transcript.receiveCumulative("音声入力のテストです。", isFinal: true)
        check(transcript.text == "音声入力のテストです。", "recognition: a nonempty final replaces the cumulative partial without duplication")
        transcript = Transcript()
        transcript.receiveCumulative("  \n", isFinal: true)
        check(transcript.text.isEmpty, "recognition: silence does not invent text")
    }

    static func run(_ steps: [(Machine.Event, TimeInterval)]) -> (Machine, [Machine.Effect]) {
        var machine = Machine()
        var effects: [Machine.Effect] = []
        for (event, time) in steps {
            effects += machine.handle(event, at: time)
        }
        return (machine, effects)
    }

    static func checkTriggerStateMachine() {
        var machine = Machine()
        check(machine.handle(.triggerDown, at: 0) == [.startRecording], "1: trigger down starts recording immediately")
        check(machine.handle(.tick, at: 0.2) == [], "1: overlay stays hidden before 0.25s hold")
        check(machine.handle(.tick, at: 0.26) == [.showOverlay], "1: overlay appears once held 0.25s")
        check(machine.handle(.tick, at: 0.4) == [], "1: overlay is shown only once")
        check(machine.handle(.triggerUp, at: 1.0) == [.commit], "2: release after a hold commits (push-to-talk)")
        check(machine.state == .idle, "2: machine returns to idle after commit")

        var (tap, tapEffects) = run([(.triggerDown, 0), (.triggerUp, 0.1)])
        check(tapEffects == [.startRecording], "3: short tap keeps recording silently without overlay or commit")
        check(tap.handle(.tick, at: 0.4) == [], "3: short tap waits for the double-tap window")
        check(tap.handle(.tick, at: 0.46) == [.cancel], "3: short tap is cancelled when the double-tap window expires")
        check(tap.state == .idle, "3: cancelled short tap returns to idle")

        var (lock, lockEffects) = run([(.triggerDown, 0), (.triggerUp, 0.1), (.triggerDown, 0.3)])
        check(lockEffects == [.startRecording, .lockHandsFree], "3: second tap within the window locks hands-free")
        check(lock.handle(.triggerUp, at: 0.35) == [], "3: release of the locking tap is ignored")
        check(lock.handle(.tick, at: 5) == [], "3: hands-free recording does not time out")
        check({ if case .handsFree = lock.state { return true } else { return false } }(), "3: still hands-free after releasing the key")
        check(lock.handle(.otherKeyDown, at: 6) == [], "5: typing during hands-free does not cancel")
        check(lock.handle(.triggerDown, at: 8) == [.commit], "4: next trigger down in hands-free commits")
        check(lock.handle(.triggerUp, at: 8.1) == [], "4: release matching the committing press is ignored")
        check(lock.state == .idle, "4: idle after the committing press is released, so the next press starts anew")

        var (quiet, _) = run([(.triggerDown, 0), (.triggerUp, 0.1), (.triggerDown, 0.3)])
        check(quiet.handle(.speech, at: 20) == [], "idle: speech in hands-free keeps it open")
        check(quiet.handle(.tick, at: 49.9) == [], "idle: hands-free stays open until 30s after the last speech")
        check(quiet.handle(.tick, at: 50.3) == [.commit], "idle: hands-free commits after 30s without speech")
        check(quiet.state == .idle, "idle: auto-commit returns to idle so the next press starts anew")

        var (silent, _) = run([(.triggerDown, 0), (.triggerUp, 0.1), (.triggerDown, 0.3)])
        check(silent.handle(.tick, at: 30.31) == [.commit], "idle: hands-free with no speech at all commits 30s after the lock")

        var (held, _) = run([(.triggerDown, 0)])
        _ = held.handle(.tick, at: 0.3)
        check(held.handle(.tick, at: 120) == [], "idle: holding the key never auto-commits")

        let (late, lateEffects) = run([(.triggerDown, 0), (.triggerUp, 0.1), (.triggerDown, 0.5)])
        check(lateEffects == [.startRecording, .cancel, .startRecording], "3: press after the window discards the tap and starts anew")
        check(late.state == .pressed(at: 0.5, overlayShown: false), "3: press after the window is a fresh hold")

        let (combo, comboEffects) = run([(.triggerDown, 0), (.otherKeyDown, 0.1), (.triggerUp, 0.3)])
        check(comboEffects == [.startRecording, .cancel], "5: another key while holding the trigger cancels (shortcut)")
        check(combo.state == .idle, "5: trigger release after a cancelled shortcut does nothing")

        let (_, holdComboEffects) = run([(.triggerDown, 0), (.tick, 0.3), (.otherKeyDown, 0.5)])
        check(holdComboEffects == [.startRecording, .showOverlay, .cancel], "5: another key cancels even after the overlay appeared")

        let (_, pendingEsc) = run([(.triggerDown, 0), (.triggerUp, 0.1), (.escape, 0.2)])
        check(pendingEsc == [.startRecording, .cancel], "6: escape cancels while waiting for a second tap")
        let (_, holdEsc) = run([(.triggerDown, 0), (.tick, 0.3), (.escape, 0.5)])
        check(holdEsc == [.startRecording, .showOverlay, .cancel], "6: escape cancels while holding")
        let (_, lockEsc) = run([(.triggerDown, 0), (.triggerUp, 0.1), (.triggerDown, 0.2), (.escape, 3)])
        check(lockEsc == [.startRecording, .lockHandsFree, .cancel], "6: escape cancels hands-free recording")

        var idle = Machine()
        check(idle.handle(.escape, at: 0) == [], "6: escape outside recording has no effect (passes through)")
        check(idle.handle(.otherKeyDown, at: 0) == [], "typing outside recording has no effect")
    }
}
