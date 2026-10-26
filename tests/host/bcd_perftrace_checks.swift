// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// The performance trace's rules, rows, files and digest, compiled on the host by tests/host/check-bcd-perftrace.py with
// app/Madeira/BCDPerfTraceCore.swift.

import Foundation

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok   " : "FAIL ") + what + (ok || detail.isEmpty ? "" : "\n     " + detail))
    if !ok { failures += 1 }
}

func sample(_ t: Int, fps: Double? = 58.1, mem: Int? = 1024, free: Int? = 4890, th: Int = 0) -> BCDTraceSample {
    var s = BCDTraceSample()
    s.t = t; s.fps = fps; s.frameMs = fps.map { 1000 / $0 }; s.worstMs = 33; s.cpu = 41; s.top = 22.3
    s.memoryMB = mem; s.freeMB = free; s.swapMB = 0; s.jitMB = 40; s.thermal = th; s.lowPower = false; s.batteryPercent = 71
    return s
}

@main enum Run {
    static func main() {
        // ---- the row ------------------------------------------------------------------------------------------
        let row = sample(1).row()
        print("note: " + row)
        check("a row is 13 cells in the declared order", row.split(separator: ",", omittingEmptySubsequences: false).count == 13
              && BCDTraceRules.columns.count == 13 && BCDTraceRules.columns.first == "t" && BCDTraceRules.columns.last == "batt")
        check("a row is one short line", !row.contains("\n") && row.utf8.count < 60, row)
        check("reading it back gives the same sample (the numbers it writes)", BCDTraceSample.parse(row).map { $0.row() } == row)
        var unknown = BCDTraceSample(); unknown.t = 0
        check("readings the device could not give are empty cells and read back as nil",
              unknown.row() == "0,,,,,,,,,,0,0," && BCDTraceSample.parse(unknown.row())?.fps == nil && BCDTraceSample.parse(unknown.row())?.memoryMB == nil)
        check("a row with 12 or 14 cells, a non-numeric time or a negative time is no row",
              BCDTraceSample.parse("1,2,3") == nil && BCDTraceSample.parse(row + ",9") == nil
              && BCDTraceSample.parse("x" + row.dropFirst()) == nil && BCDTraceSample.parse("-1" + row.dropFirst()) == nil)
        var hot = sample(5); hot.thermal = 9
        check("the heat is kept to 0...3", BCDTraceSample.parse(hot.row())?.thermal == 3)

        // ---- the frames of an interval -------------------------------------------------------------------------
        let a = BCDTraceFrames.summarize(times: [10.00, 10.02, 10.04, 10.10], previous: 9.99, now: 10.5, elapsed: 1.0)
        check("four frames in a second: 4 fps, the mean gap and the worst gap (60 ms)",
              abs((a.fps ?? 0) - 4) < 1e-9 && abs((a.frameMs ?? 0) - 27.5) < 1e-6 && abs((a.worstMs ?? 0) - 60) < 1e-6,
              "\(a)")
        let first = BCDTraceFrames.summarize(times: [1.0, 1.5, 2.0], previous: nil, now: 2.0, elapsed: 1.0)
        check("the first frames of a session have no gap before the first (two gaps for three frames)",
              abs((first.frameMs ?? 0) - 500) < 1e-6 && abs((first.worstMs ?? 0) - 500) < 1e-6 && abs((first.fps ?? 0) - 3) < 1e-9, "\(first)")
        let stall = BCDTraceFrames.summarize(times: [], previous: 20.0, now: 23.5, elapsed: 1.0)
        check("no frame in an interval that follows frames: 0 fps and the silence so far as the worst gap (a stall shows)",
              stall.fps == 0 && stall.frameMs == nil && abs((stall.worstMs ?? 0) - 3500) < 1e-6, "\(stall)")
        let none = BCDTraceFrames.summarize(times: [], previous: nil, now: 3, elapsed: 1.0)
        check("a session that has never presented a frame (a 2D program) has empty cells, not zeros", none.fps == nil && none.frameMs == nil && none.worstMs == nil)
        check("an interval of no time gives nothing (no division by zero)", BCDTraceFrames.summarize(times: [1], previous: 0.5, now: 1, elapsed: 0).fps == nil)
        let one = BCDTraceFrames.summarize(times: [5.0], previous: nil, now: 5.2, elapsed: 1.0)
        check("one frame, nothing before it: 1 fps, no mean", one.fps == 1 && one.frameMs == nil && one.worstMs == 0)

        // ---- cutting back --------------------------------------------------------------------------------------
        let many = (0..<5000).map { sample($0).row() }
        let cut = BCDTraceRules.cut(many)
        check("5000 rows are cut to an hour: the first 120 and the newest 3480, in order, and the count of those dropped",
              cut.rows.count == 3600 && cut.dropped == 1400 && cut.rows.first == many.first && cut.rows[119] == many[119]
              && cut.rows[120] == many[1520] && cut.rows.last == many.last)
        check("3600 rows or fewer are not touched", BCDTraceRules.cut(Array(many.prefix(3600))).dropped == 0 && BCDTraceRules.cut(Array(many.prefix(10))).rows.count == 10)
        check("a tiny limit still keeps both ends", BCDTraceRules.cut(Array(many.prefix(50)), limit: 10).rows.count == 10
              && BCDTraceRules.cut(Array(many.prefix(50)), limit: 10).rows.first == many.first)
        check("the file may pass the hour by 300 rows before it is cut (one rewrite in 300 seconds)", BCDTraceRules.maxLines == 3600 && BCDTraceRules.slack == 300)
        check("a trace and a switch: either one records, neither does not",
              BCDTraceRules.records(switchOn: true, guidedRun: false) && BCDTraceRules.records(switchOn: false, guidedRun: true)
              && !BCDTraceRules.records(switchOn: false, guidedRun: false))

        // ---- file names ----------------------------------------------------------------------------------------
        check("the trace is named after the session log's inode, and the inode reads back",
              BCDTraceRules.fileName(inode: 12345) == "trace-12345.trace.csv" && BCDTraceRules.inode(ofFileName: "trace-12345.trace.csv") == 12345
              && BCDTraceRules.inode(ofFileName: "bcd-log.txt") == nil && BCDTraceRules.inode(ofFileName: "trace-x.trace.csv") == nil
              && BCDTraceRules.inode(ofFileName: "trace-1.txt") == nil)

        // ---- the store -----------------------------------------------------------------------------------------
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcd-trace-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = BCDTraceStore(folder: dir)
        let header = BCDTraceStore.header(date: "2026-10-25", start: "21:05:03.120", jitTotalMB: 896)
        check("the header names the version, the date, the start, the columns and the pool", header == "#bcd-trace v1 date=2026-10-25 start=21:05:03.120 columns=t,fps,ms,worst,cpu,top,mem,free,swap,jit,th,lp,batt jit_total=896", header)
        check("... and leaves the pool out when it is not known", !BCDTraceStore.header(date: "d", start: "s", jitTotalMB: nil).contains("jit_total"))
        check("a missing trace sends nothing and says nothing", store.linesToSend(inode: 7).isEmpty && store.note(inode: 7) == nil && store.linesToSend(inode: 0).isEmpty)
        let url = store.url(inode: 7)
        let rows = (0..<200).map { sample($0, mem: 1000 + $0).row() }
        try? ([header] + rows + ["3,garbage"]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)   // a last line cut by a crash
        let sent = store.linesToSend(inode: 7)
        print("note: " + sent.prefix(2).joined(separator: " | "))
        check("the sent block is begin, the rows each with the tag, end", sent.first?.hasPrefix("[trace] begin v1 ") == true && sent.last == "[trace] end"
              && sent.count == 202 && sent.dropFirst().dropLast().allSatisfy { $0.hasPrefix("[trace] ") })
        check("a half-written last line is left out", !sent.contains { $0.contains("garbage") })
        check("the begin line carries the header's words and the number of rows",
              sent[0].contains("date=2026-10-25") && sent[0].contains("jit_total=896") && sent[0].contains("rows=200") && !sent[0].contains("dropped"), sent[0])
        check("the note says how long, in seconds under two minutes and minutes after",
              store.note(inode: 7)?.contains("3 minutes") == true && store.note(inode: 7)?.contains("goes with it") == true, store.note(inode: 7) ?? "nil")
        try? ([header] + rows.prefix(60)).joined(separator: "\n").write(to: store.url(inode: 8), atomically: true, encoding: .utf8)
        check("a short trace is counted in seconds", store.note(inode: 8)?.contains("59 seconds") == true, store.note(inode: 8) ?? "nil")
        try? ([header, rows[0]]).joined(separator: "\n").write(to: store.url(inode: 9), atomically: true, encoding: .utf8)
        check("a trace of one row is no trace (nothing to say, but it still goes if asked)", store.note(inode: 9) == nil && store.linesToSend(inode: 9).count == 3)
        try? header.write(to: store.url(inode: 10), atomically: true, encoding: .utf8)
        check("a header alone sends nothing", store.linesToSend(inode: 10).isEmpty)
        let long = (0..<5000).map { sample($0).row() }
        try? ([header] + long).joined(separator: "\n").write(to: store.url(inode: 11), atomically: true, encoding: .utf8)
        let longSent = store.linesToSend(inode: 11)
        check("a file longer than an hour is sent cut (first 120 + newest 3480) and says how many were dropped",
              longSent.count == 3602 && longSent[0].contains("dropped=1400") && longSent[0].contains("rows=3600") && longSent.count <= BCDTraceRules.maxSentLines)

        // ---- keeping a few ---------------------------------------------------------------------------------------
        for i in 100..<130 {
            let u = store.url(inode: UInt64(i))
            try? header.write(to: u, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(i))], ofItemAtPath: u.path)
        }
        try? "keep me".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { BCDTraceRules.inode(ofFileName: $0) != nil }.count ?? 0
        let removed = store.prune(keep: 20)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { BCDTraceRules.inode(ofFileName: $0) != nil }
        check("only the newest 20 traces are kept, by modification time", left.count == 20 && removed == before - 20
              && left.contains("trace-129.trace.csv") && !left.contains("trace-100.trace.csv"), "\(before) \(removed) \(left.count)")
        check("a file that is not a trace is never removed", FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))

        // ---- the digest ---------------------------------------------------------------------------------------
        var samples = (0..<600).map { sample($0, fps: 60, mem: 2000 + $0, free: 3000 - $0) }
        samples[300] = sample(300, fps: 12, mem: 2600, free: 380, th: 2)
        samples[301].worstMs = 450
        let d = BCDTraceDigest.of(samples)
        check("the digest: length, the lowest second, the worst frame, the peak memory, the least left, the first serious heat",
              d.seconds == 599 && d.lowestFPS == 12 && d.lowestFPSAt == 300 && d.worstMs == 450 && d.worstMsAt == 301
              && d.peakMemoryMB == 2600 && d.leastFreeMB == 380 && d.leastFreeAt == 300 && d.thermalPeak == 2 && d.thermalFirstSeriousAt == 300,
              "\(d)")
        check("... and the average is over the seconds that had frames (599 at 60 and one at 12)", abs((d.averageFPS ?? 0) - (599.0 * 60 + 12) / 600) < 0.01, "\(d.averageFPS ?? -1)")
        samples[10].fps = 0
        check("... a second with no frame (0 fps) is not in the average", abs((BCDTraceDigest.of(samples).averageFPS ?? 0) - (598.0 * 60 + 12) / 599) < 0.01)
        // The block Send Log appends, for the Python reader (tools/log-facts.py) to read back.
        if CommandLine.arguments.count > 1 {
            try? sent.joined(separator: "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        print(failures == 0 ? "bcd_perftrace_checks: PASS" : "bcd_perftrace_checks: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
