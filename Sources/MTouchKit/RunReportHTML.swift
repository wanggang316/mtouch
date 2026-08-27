import Foundation

/// Renders a run bundle as ONE self-contained `report.html`.
///
/// Four properties are load-bearing and each is tested:
///
///   - **Offline.** Every byte is inline: the stylesheet, and each screenshot as
///     a `data:` URI. The page opens from `file://` with the network off — no
///     CDN, no web font, no external image. (A screen recording is referenced by
///     its run-relative path instead: inlining a multi-minute capture would
///     produce an unopenable document.)
///   - **Deterministic.** Nothing in the body comes from the moment of
///     rendering — no "generated at", no locale, no time zone. Two renders of one
///     bundle are byte-identical, so a report can be diffed and checked in.
///   - **Total.** A missing `run.json`, an absent or empty trajectory, a damaged
///     line, a missing PNG, and an absent `video/` each render as a plain
///     statement of what is absent, never as a broken page.
///   - **Escaped.** Every value that came from the target application — AX
///     titles, values, diffs, typed text — goes through `escape`, because those
///     strings routinely contain `<`, `&`, quotes, CJK, and emoji.
public enum RunReportHTML {
    /// Render `bundle`. With `redact`, screenshots and recordings are omitted
    /// entirely and only the structured log remains.
    public static func render(_ bundle: RunReportBundle, redact: Bool = false) -> String {
        var out = ""
        out += "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
        out += "<meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        out += "<title>mtouch run report</title>\n"
        out += "<style>\n\(stylesheet)</style>\n</head>\n<body>\n"
        out += header(bundle, redact: redact)
        out += banner(redact: redact)
        out += videoSection(bundle, redact: redact)
        out += timeline(bundle, redact: redact)
        out += legend(redact: redact)
        out += "</body>\n</html>\n"
        return out
    }

    // MARK: - Header

    private static func header(_ bundle: RunReportBundle, redact: Bool) -> String {
        var rows: [(String, String)] = []
        rows.append(("run directory", bundle.root))
        rows.append(("label", bundle.metadata?.label ?? "(none)"))
        if let metadata = bundle.metadata {
            rows.append(("created", metadata.createdAtWallClock > 0 ? utcText(metadata.createdAtWallClock) : "(unknown)"))
            rows.append(("mtouch version", metadata.mtouchVersion.isEmpty ? "(unknown)" : metadata.mtouchVersion))
            rows.append(("macOS version", metadata.macOSVersion.isEmpty ? "(unknown)" : metadata.macOSVersion))
            rows.append(("steps allocated", String(metadata.stepCount)))
        } else {
            rows.append(("run.json", "absent or unreadable — the run's own metadata is missing"))
        }
        rows.append(("duration", bundle.durationSeconds.map(secondsText) ?? "(not measurable)"))
        rows.append(("records", String(bundle.records.count)))
        rows.append(("passed", String(bundle.passedCount)))
        rows.append(("failed", String(bundle.failedCount)))
        if bundle.unreadableCount > 0 {
            rows.append(("unreadable lines", String(bundle.unreadableCount)))
        }
        if redact {
            rows.append(("redacted", "screenshots and recordings omitted"))
        }

        var tally = "<span class=\"tally pass\">\(bundle.passedCount) passed</span>"
        if bundle.failedCount > 0 {
            tally += "<span class=\"tally fail\">\(bundle.failedCount) failed</span>"
        }

        var out = "<header>\n<h1>mtouch run report</h1>\n<p class=\"tallies\">\(tally)</p>\n<dl class=\"summary\">\n"
        for (key, value) in rows {
            out += "<dt>\(escape(key))</dt><dd>\(escape(value))</dd>\n"
        }
        out += "</dl>\n</header>\n"
        return out
    }

    // MARK: - Sensitive-content banner

    /// Always shown unless the report is redacted. It states BOTH hazards,
    /// because an operator learns them from the artifact or not at all.
    private static func banner(redact: Bool) -> String {
        guard !redact else {
            return "<section class=\"banner redacted\"><h2>Redacted</h2><p>Screenshots and screen"
                + " recordings were omitted from this render. Only the structured log remains;"
                + " the bundle on disk still contains them.</p></section>\n"
        }
        return """
        <section class="banner">
        <h2>Sensitive content</h2>
        <p>The screenshots and recordings below capture <strong>whatever was on screen</strong> at the time \
        — other applications, notifications, message previews, and anything else visible.</p>
        <p>The structured log strips the payload arguments (<code>text</code>, <code>combo</code>, \
        <code>value</code>) only from <strong>failed</strong> records. A <strong>successful</strong> \
        <code>act type &lt;secret&gt;</code> is therefore stored verbatim in <code>trajectory.jsonl</code> \
        and appears in this report.</p>
        <p>Treat this bundle as sensitive, or re-render it with <code>--redact</code> to keep the log \
        without the imagery.</p>
        </section>

        """
    }

    // MARK: - Video

    private static func videoSection(_ bundle: RunReportBundle, redact: Bool) -> String {
        var out = "<section class=\"video\">\n<h2>Screen recording</h2>\n"
        if redact {
            out += "<p class=\"absent\">Omitted (--redact).</p>\n"
        } else if bundle.videoFiles.isEmpty {
            out += "<p class=\"absent\">No screen recording in this run "
                + "(<code>\(escape(RunBundle.videoDirectoryName))/</code> is empty or absent).</p>\n"
        } else {
            for file in bundle.videoFiles {
                out += "<figure>\n<video controls preload=\"none\" src=\"\(escape(file))\"></video>\n"
                out += "<figcaption>\(escape(file)) — resolved relative to the run directory, "
                out += "so it plays when this report sits inside the bundle.</figcaption>\n</figure>\n"
            }
        }
        out += "</section>\n"
        return out
    }

    // MARK: - Timeline

    private static func timeline(_ bundle: RunReportBundle, redact: Bool) -> String {
        var out = "<section class=\"timeline\">\n<h2>Timeline</h2>\n"
        if !bundle.trajectoryPresent {
            out += "<p class=\"absent\"><code>\(escape(RunBundle.trajectoryFileName))</code> is absent — this"
                + " bundle recorded no structured log. A command may have been run with"
                + " <code>MTOUCH_TRAJECTORY</code> pointed elsewhere, which wins over the bundle's own"
                + " stream.</p>\n"
        } else if bundle.entries.isEmpty {
            out += "<p class=\"absent\"><code>\(escape(RunBundle.trajectoryFileName))</code> is empty — this"
                + " run recorded no commands.</p>\n"
        } else {
            out += "<ol class=\"steps\">\n"
            for entry in bundle.entries {
                switch entry {
                case let .record(record): out += step(record, root: bundle.root, redact: redact)
                case let .unreadable(line, raw): out += unreadable(line: line, raw: raw)
                }
            }
            out += "</ol>\n"
        }
        out += "</section>\n"
        return out
    }

    private static func step(_ record: RunReportRecord, root: String, redact: Bool) -> String {
        let state = record.ok ? "pass" : "fail"
        var out = "<li class=\"step \(state)\">\n"
        out += "<div class=\"head\">"
        out += "<span class=\"ordinal\">\(escape(record.ordinalText))</span>"
        out += "<span class=\"cmd\">\(escape(record.command))</span>"
        out += "<span class=\"outcome \(state)\">\(record.ok ? "ok" : "failed")</span>"
        out += "<span class=\"exit\">\(record.exit.map { "exit \($0)" } ?? "exit n/a")</span>"
        if let errorClass = record.errorClass {
            out += "<span class=\"errclass\">\(escape(errorClass))</span>"
        }
        out += "</div>\n"

        out += "<dl class=\"meta\">"
        out += "<dt>wall clock</dt><dd>\(escape(record.wallClock.map(utcText) ?? "(absent)"))"
        if let wall = record.wallClock {
            out += " <span class=\"epoch\">(\(escape(JSONText.number(wall))))</span>"
        }
        out += "</dd>"
        out += "<dt>monotonic</dt><dd>\(escape(record.monotonic.map { JSONText.number($0) + " s" } ?? "(absent)"))</dd>"
        out += "</dl>\n"

        if record.args.isEmpty {
            out += "<p class=\"absent\">no arguments</p>\n"
        } else {
            out += "<table class=\"args\"><tbody>\n"
            for arg in record.args {
                out += "<tr><th>\(escape(arg.key))</th><td>\(escape(arg.value))</td></tr>\n"
            }
            out += "</tbody></table>\n"
        }

        if let diff = record.diff, !diff.isEmpty {
            out += "<h3>diff</h3>\n<pre class=\"diff\">\(escape(diff))</pre>\n"
        }
        if let path = record.screenshotPath {
            out += "<p class=\"wrote\">wrote screenshot <code>\(escape(path))</code></p>\n"
        }
        out += shots(record, root: root, redact: redact)
        out += "</li>\n"
        return out
    }

    private static func shots(_ record: RunReportRecord, root: String, redact: Bool) -> String {
        guard !redact else { return "" }
        var out = ""
        var rendered = 0
        for slot in RunStepSlot.allCases {
            guard let relative = record.evidence[slot] else { continue }
            rendered += 1
            out += figure(relative: relative, slot: slot, root: root)
        }
        if let error = record.evidence.captureError {
            out += "<p class=\"capture-error\">capture failed — \(escape(error))"
            out += " The command itself was unaffected and kept its own exit code.</p>\n"
        }
        if rendered == 0, record.evidence.captureError == nil {
            out += "<p class=\"absent\">No screenshots for this step (captures were not enabled).</p>\n"
        }
        return out.isEmpty ? out : "<div class=\"shots\">\n" + out + "</div>\n"
    }

    private static func figure(relative: String, slot: RunStepSlot, root: String) -> String {
        // Only ever inline a file the bundle itself owns. The recorded path is
        // normally one this tool wrote, but a report must not become a way to
        // read `../../somewhere` into an HTML document.
        let absolute = URL(fileURLWithPath: root).appendingPathComponent(relative).standardized.path
        let contained = absolute.hasPrefix(URL(fileURLWithPath: root).standardized.path + "/")
        guard contained,
              let data = try? Data(contentsOf: URL(fileURLWithPath: absolute)), !data.isEmpty
        else {
            return "<p class=\"absent\">\(escape(slot.rawValue)) screenshot missing: "
                + "<code>\(escape(relative))</code></p>\n"
        }
        var out = "<figure class=\"shot \(slot.rawValue)\">\n"
        out += "<img alt=\"\(escape(slot.rawValue)) screenshot\" src=\"data:image/png;base64,"
        out += data.base64EncodedString()
        out += "\">\n"
        out += "<figcaption>\(escape(slot.rawValue)) — <code>\(escape(relative))</code></figcaption>\n"
        out += "</figure>\n"
        return out
    }

    private static func unreadable(line: Int, raw: String) -> String {
        var out = "<li class=\"step unreadable\">\n"
        out += "<div class=\"head\"><span class=\"ordinal\">—</span>"
        out += "<span class=\"cmd\">unreadable line \(line)</span>"
        out += "<span class=\"outcome unreadable\">not JSON</span></div>\n"
        out += "<pre class=\"raw\">\(escape(truncate(raw)))</pre>\n</li>\n"
        return out
    }

    // MARK: - Legend

    private static func legend(redact: Bool) -> String {
        var out = "<footer>\n<p>Times are UTC. <em>monotonic</em> is the machine's uptime clock, used for "
        out += "ordering; it is not a wall time. Records appear in the order they were appended "
        out += "(completion order); the leading number is the order in which the step was allocated, so "
        out += "concurrent commands stay distinguishable.</p>\n"
        if !redact {
            out += "<p>Screenshots are embedded in this file, so it is self-contained and needs no "
            out += "network access.</p>\n"
        }
        out += "</footer>\n"
        return out
    }

    // MARK: - Text helpers

    /// HTML-escape arbitrary text from the target application.
    ///
    /// The five markup-significant characters become entities. C0/C1 control
    /// characters — which a raw AX value can carry and which HTML cannot
    /// represent at all — become U+FFFD, keeping the document well-formed;
    /// newline and tab survive because they are meaningful inside a `<pre>`.
    /// Everything else, including CJK and emoji, passes through unchanged under
    /// the document's UTF-8 charset.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\n", "\t": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) {
                    out += "\u{FFFD}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Cap a damaged line so one runaway record cannot bloat the page, marking
    /// the cut so the truncation is never mistaken for the whole line.
    static func truncate(_ raw: String, limit: Int = 500) -> String {
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit)) + "… (\(raw.count - limit) more characters)"
    }

    /// `YYYY-MM-DD HH:MM:SS.mmm UTC` from epoch seconds, computed with `gmtime_r`
    /// rather than a `DateFormatter`: no locale, no time zone, no shared mutable
    /// formatter — the same input renders the same bytes on any machine.
    static func utcText(_ epoch: Double) -> String {
        guard epoch.isFinite, epoch.magnitude < 1e12 else { return "(out of range)" }
        let whole = epoch.rounded(.down)
        var seconds = time_t(whole)
        var parts = tm()
        guard gmtime_r(&seconds, &parts) != nil else { return "(out of range)" }
        let millis = min(999, max(0, Int(((epoch - whole) * 1000).rounded(.down))))
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d UTC",
            parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
            parts.tm_hour, parts.tm_min, parts.tm_sec, millis
        )
    }

    static func secondsText(_ seconds: Double) -> String {
        String(format: "%.3f s", seconds)
    }

    // MARK: - Stylesheet

    /// Inlined wholesale: a linked stylesheet would make the report depend on a
    /// second file, and a remote one would make it depend on the network.
    private static let stylesheet = """
    :root { color-scheme: light dark; }
    body { font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 0 auto; max-width: 60rem; padding: 1.5rem; }
    h1 { font-size: 1.4rem; margin: 0 0 .5rem; }
    h2 { font-size: 1.1rem; margin: 1.5rem 0 .5rem; }
    h3 { font-size: .95rem; margin: .75rem 0 .25rem; }
    code, pre { font-family: ui-monospace, Menlo, monospace; font-size: .85em; }
    pre { background: rgba(127,127,127,.12); border-radius: 6px; overflow-x: auto; padding: .6rem .8rem; white-space: pre-wrap; word-break: break-word; }
    dl.summary { display: grid; gap: .1rem .8rem; grid-template-columns: max-content 1fr; margin: 0; }
    dl.summary dt { color: #777; }
    dl.summary dd { margin: 0; word-break: break-word; }
    .tallies { margin: 0 0 .75rem; }
    .tally { border-radius: 999px; display: inline-block; font-weight: 600; margin-right: .4rem; padding: .1rem .6rem; }
    .tally.pass { background: rgba(40,160,80,.18); }
    .tally.fail { background: rgba(200,60,60,.20); }
    .banner { background: rgba(220,160,40,.16); border-left: 4px solid rgba(200,140,20,.8); border-radius: 4px; margin: 1.25rem 0; padding: .75rem 1rem; }
    .banner h2 { margin-top: 0; }
    .banner.redacted { background: rgba(120,120,120,.16); border-left-color: rgba(120,120,120,.8); }
    ol.steps { list-style: none; margin: 0; padding: 0; }
    li.step { border: 1px solid rgba(127,127,127,.35); border-radius: 8px; margin: .75rem 0; padding: .75rem 1rem; }
    li.step.fail { border-color: rgba(200,60,60,.65); }
    li.step.unreadable { border-style: dashed; }
    .head { align-items: baseline; display: flex; flex-wrap: wrap; gap: .5rem; }
    .ordinal { font-family: ui-monospace, Menlo, monospace; font-weight: 700; }
    .cmd { font-weight: 600; }
    .outcome { border-radius: 999px; font-size: .8rem; padding: .05rem .5rem; }
    .outcome.pass { background: rgba(40,160,80,.18); }
    .outcome.fail, .outcome.unreadable { background: rgba(200,60,60,.20); }
    .exit, .errclass, .epoch { color: #777; font-size: .8rem; }
    dl.meta { display: grid; gap: 0 .8rem; grid-template-columns: max-content 1fr; margin: .5rem 0 0; }
    dl.meta dt { color: #777; }
    dl.meta dd { margin: 0; }
    table.args { border-collapse: collapse; margin: .5rem 0 0; width: 100%; }
    table.args th { color: #777; font-weight: 400; padding: .1rem .8rem .1rem 0; text-align: left; vertical-align: top; white-space: nowrap; width: 1%; }
    table.args td { padding: .1rem 0; word-break: break-word; }
    .shots { display: flex; flex-wrap: wrap; gap: .75rem; margin-top: .75rem; }
    .shots figure { flex: 1 1 18rem; margin: 0; }
    .shots img, .video video { border: 1px solid rgba(127,127,127,.35); border-radius: 6px; max-width: 100%; }
    figcaption { color: #777; font-size: .8rem; margin-top: .25rem; }
    .absent { color: #777; font-style: italic; }
    .capture-error { color: #b04040; }
    footer { border-top: 1px solid rgba(127,127,127,.35); color: #777; font-size: .8rem; margin-top: 2rem; padding-top: .75rem; }

    """
}
