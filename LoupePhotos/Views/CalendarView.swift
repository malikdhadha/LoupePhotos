import SwiftUI

/// The Calendar (carried over from the Electron version): Day, Week, Month, Year and All Years,
/// with covers or a heatmap. ← → move through time, ↑ ↓ zoom out and in, click a day to open it.
enum CalMode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month", year = "Year", years = "All Years"; var id: String { rawValue } }

/// Photos grouped by day, worked out once per change.
final class CalData {
    var byDay: [Int: [Photo]] = [:]          // key: y*10000 + m*100 + d
    var days: [Int] = []                      // sorted keys that have photos
    static func key(_ y: Int, _ m: Int, _ d: Int) -> Int { y * 10000 + m * 100 + d }
    static func key(_ date: Date) -> Int { let c = Calendar.current.dateComponents([.year, .month, .day], from: date); return key(c.year!, c.month!, c.day!) }
    static func date(_ k: Int) -> Date { Calendar.current.date(from: DateComponents(year: k / 10000, month: k / 100 % 100, day: k % 100)) ?? Date() }

    private static var memo: (String, CalData)?
    static func make(_ list: [Photo], key: String) -> CalData {
        if let m = memo, m.0 == key { return m.1 }
        let c = CalData()
        for p in list where !p.quickNoDate { let d = p.ymd; c.byDay[CalData.key(d.y, d.m, d.d), default: []].append(p) }
        c.days = c.byDay.keys.sorted()
        memo = (key, c)
        return c
    }
    func photos(_ k: Int) -> [Photo] { byDay[k] ?? [] }
    func count(year y: Int, month m: Int? = nil) -> Int {
        byDay.reduce(0) { s, e in (e.key / 10000 == y && (m == nil || e.key / 100 % 100 == m!)) ? s + e.value.count : s }
    }
    static func cover(_ ps: [Photo]) -> Photo? { ps.max { a, b in (a.quickRating, a.quickFlag ? 1 : 0) < (b.quickRating, b.quickFlag ? 1 : 0) } }
}

extension UIState {
    var calDay: Date { calDate ?? Date() }
    /// ← / →: the next day with photos (Day), or the next week, month or year.
    func calShift(_ dir: Int, _ data: CalData) {
        let cal = Calendar.current, d = calDay
        switch calMode {
        case .day:
            let k = CalData.key(d)
            if let n = dir > 0 ? data.days.first(where: { $0 > k }) : data.days.last(where: { $0 < k }) { calDate = CalData.date(n) }
            else { NSSound.beep() }
        case .week: calDate = cal.date(byAdding: .day, value: 7 * dir, to: d)
        case .month: calDate = cal.date(byAdding: .month, value: dir, to: cal.date(from: cal.dateComponents([.year, .month], from: d))!)
        case .year: calDate = cal.date(byAdding: .year, value: dir, to: d)
        case .years: break
        }
    }
    func calZoom(_ dir: Int) {
        let all = CalMode.allCases, i = all.firstIndex(of: calMode) ?? 2
        calMode = all[max(0, min(all.count - 1, i + dir))]
    }
    /// Opens one photo in the Viewer; Esc comes back to the Calendar.
    func calOpen(_ p: Photo, _ lib: Library) { select(p, in: visible(lib), extend: false, toggle: false); returnMode = .calendar; mode = .viewer }
    /// Double-clicking a day shows just that day in the Browser.
    func calBrowse(_ k: Int) { source = .date(k / 10000, k / 100 % 100, k % 100); browse = .all; mode = .browser }
}

struct CalendarView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui

    var body: some View {
        let list = ui.visible(lib)
        let data = CalData.make(list, key: ui.visibleKey)
        VStack(spacing: 0) {
            header(data)
            Divider()
            Group {
                switch ui.calMode {
                case .month: MonthCal(data: data)
                case .year: YearCal(data: data)
                case .years: YearsCal(data: data)
                case .week: WeekCal(data: data)
                case .day: DayCal(data: data)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { if ui.calDate == nil { ui.calDate = data.days.last.map(CalData.date) ?? Date() } }
    }

    func header(_ data: CalData) -> some View {
        @Bindable var ui = ui
        let d = ui.calDay, cal = Calendar.current
        return HStack(spacing: 10) {
            if ui.calMode != .years {
                ControlGroup {
                    Button { ui.calShift(-1, data) } label: { Image(systemName: "chevron.left") }.help("Earlier (←)")
                    Button { ui.calShift(1, data) } label: { Image(systemName: "chevron.right") }.help("Later (→)")
                }
                .frame(width: 64)
            }
            title(d).font(.system(size: 20, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(2)
            if ui.calMode != .years { Button("Today") { ui.calDate = cal.startOfDay(for: Date()) }.controlSize(.small) }
            Spacer(minLength: 8)
            Picker("", selection: $ui.calMode) { ForEach(CalMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().help("↑ ↓ to zoom out and in")
            if ui.calMode == .year || ui.calMode == .years {
                Picker("", selection: $ui.calHeat) { Text("Photos").tag(false); Text("Heatmap").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text("\(count(data).formatted()) photos").foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder func title(_ d: Date) -> some View {
        let cal = Calendar.current, y = cal.component(.year, from: d)
        switch ui.calMode {
        case .day: Text(d.formatted(.dateTime.weekday(.wide).day().month(.wide))) + Text("  \(String(y))").foregroundColor(.secondary)
        case .week:
            let a = cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d, b = cal.date(byAdding: .day, value: 6, to: a)!
            Text("\(a.formatted(.dateTime.day().month(.abbreviated))) – \(b.formatted(.dateTime.day().month(.abbreviated)))") + Text("  \(String(cal.component(.year, from: b)))").foregroundColor(.secondary)
        case .month: Text(d.formatted(.dateTime.month(.wide))) + Text("  \(String(y))").foregroundColor(.secondary)
        case .year: Text(String(y))
        case .years: Text("All Years")
        }
    }

    func count(_ data: CalData) -> Int {
        let cal = Calendar.current, d = ui.calDay, y = cal.component(.year, from: d)
        switch ui.calMode {
        case .day: return data.photos(CalData.key(d)).count
        case .week:
            let a = cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            return (0..<7).reduce(0) { $0 + data.photos(CalData.key(cal.date(byAdding: .day, value: $1, to: a)!)).count }
        case .month: return data.count(year: y, month: cal.component(.month, from: d))
        case .year: return data.count(year: y)
        case .years: return data.byDay.values.reduce(0) { $0 + $1.count }
        }
    }
}

// MARK: - pieces

/// A cover thumbnail filling its frame (mini size for tiny cells).
struct CalThumb: View {
    let photo: Photo
    var mini = false
    @Environment(Library.self) private var lib
    @State private var img: CGImage?
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color(white: 0.16)
                if let img { Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height).clipped() }
            }
        }
        .task(id: "\(photo.id)-\(photo.rot)-\(mini)") { img = await Images.shared.cg(photo, mini ? .mini : .thumb) }
    }
}

private let heatColors: [Double] = [0, 0.22, 0.42, 0.65, 0.92]
private func heatLevel(_ n: Int, _ maxN: Int) -> Int { n == 0 ? 0 : max(1, Int(ceil(log(Double(n + 1)) / log(Double(maxN + 1)) * 4))) }
private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
/// Monday-first offset of the 1st of a month.
private func mondayOffset(_ first: Date) -> Int { (Calendar.current.component(.weekday, from: first) + 5) % 7 }

struct MonthCal: View {
    let data: CalData
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let cal = Calendar.current, d = ui.calDay
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        let first = cal.date(from: DateComponents(year: y, month: m, day: 1))!
        let off = mondayOffset(first), n = cal.range(of: .day, in: .month, for: first)!.count
        let weeks = (off + n + 6) / 7, today = CalData.key(Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                monthChips(y, m)
                HStack(spacing: 6) { ForEach(weekdays, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(0..<(weeks * 7), id: \.self) { i in
                        let day = cal.date(byAdding: .day, value: i - off, to: first)!
                        let k = CalData.key(day), ps = data.photos(k)
                        dayCell(day, k, ps, inMonth: cal.component(.month, from: day) == m, today: k == today)
                    }
                }
                Text("Click a day to see it in Day view. Double-click to open its photos in the Browser.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
    func monthChips(_ y: Int, _ m: Int) -> some View {
        var counts: [Int: Int] = [:]
        for (k, ps) in data.byDay { counts[(k / 10000) * 12 + (k / 100 % 100) - 1, default: 0] += ps.count }
        let cur = y * 12 + m - 1
        let keys = counts.keys.sorted().filter { abs($0 - cur) <= 7 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { k in
                    let date = Calendar.current.date(from: DateComponents(year: k / 12, month: k % 12 + 1, day: 1))!
                    Button { ui.calDate = date } label: {
                        HStack(spacing: 5) { Text(date.formatted(.dateTime.month(.abbreviated).year())); Text("\(counts[k]!)").fontWeight(.semibold).foregroundStyle(.secondary) }
                            .font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(k == cur ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    func dayCell(_ day: Date, _ k: Int, _ ps: [Photo], inMonth: Bool, today: Bool) -> some View {
        let num = Text("\(Calendar.current.component(.day, from: day))").font(.system(size: 13, weight: .semibold))
        return ZStack(alignment: .topLeading) {
            if let c = CalData.cover(ps) {
                CalThumb(photo: c)
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                num.foregroundStyle(.white).padding(7)
                Text("\(ps.count)").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(7).frame(maxWidth: .infinity, alignment: .trailing)
                HStack {
                    Text(ps.lazy.map(\.placeLabel).first { !$0.isEmpty }.flatMap { $0.split(separator: ",").first.map(String.init) } ?? "").lineLimit(1)
                    Spacer(minLength: 2)
                    let r = ps.map(\.rating).max() ?? 0
                    if r > 0 { Text(String(repeating: "★", count: r)) }
                }
                .font(.caption2).foregroundStyle(.white).padding(6).frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                Color.primary.opacity(inMonth ? 0.05 : 0.02)
                num.foregroundStyle(inMonth ? .secondary : .tertiary).padding(7)
            }
        }
        .aspectRatio(1.2, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: today ? 2 : 0))
        .opacity(inMonth || !ps.isEmpty ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !ps.isEmpty { ui.calBrowse(k) } }
        .simultaneousGesture(TapGesture().onEnded { if !ps.isEmpty { ui.calDate = day; ui.calMode = .day } })
        .help(ps.isEmpty ? "" : "\(day.formatted(date: .complete, time: .omitted)) · \(ps.count) photo\(ps.count == 1 ? "" : "s")")
    }
}

struct YearCal: View {
    let data: CalData
    @Environment(UIState.self) private var ui
    var body: some View {
        let cal = Calendar.current, y = cal.component(.year, from: ui.calDay), today = CalData.key(Date())
        let maxN = max(1, data.byDay.filter { $0.key / 10000 == y }.map { $0.value.count }.max() ?? 1)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 22)], spacing: 22) {
                ForEach(1...12, id: \.self) { m in
                    let first = cal.date(from: DateComponents(year: y, month: m, day: 1))!
                    let off = mondayOffset(first), days = cal.range(of: .day, in: .month, for: first)!.count
                    let total = data.count(year: y, month: m)
                    VStack(alignment: .leading, spacing: 6) {
                        Button { ui.calDate = first; ui.calMode = .month } label: {
                            HStack { Text(first.formatted(.dateTime.month(.wide))).fontWeight(.semibold); Spacer(); if total > 0 { Text(total.formatted()).foregroundStyle(.secondary) } }
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 2) { ForEach(Array("MTWTFSS".enumerated()), id: \.offset) { Text(String($0.element)).font(.system(size: 9)).foregroundStyle(.tertiary).frame(maxWidth: .infinity) } }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                            ForEach(0..<(off + days), id: \.self) { i in
                                if i < off { Color.clear.aspectRatio(1, contentMode: .fit) }
                                else { cell(y, m, i - off + 1, maxN: maxN, today: today) }
                            }
                        }
                    }
                    .opacity(total == 0 ? 0.5 : 1)
                }
            }
            .padding(18)
        }
    }
    func cell(_ y: Int, _ m: Int, _ d: Int, maxN: Int, today: Int) -> some View {
        let k = CalData.key(y, m, d), ps = data.photos(k)
        return ZStack {
            if ps.isEmpty {
                Text("\(d)").font(.system(size: 9)).foregroundStyle(.tertiary)
            } else if ui.calHeat {
                Color.accentColor.opacity(heatColors[heatLevel(ps.count, maxN)])
                Text("\(d)").font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
            } else if let c = CalData.cover(ps) {
                CalThumb(photo: c, mini: true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: k == today ? 1.5 : 0))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !ps.isEmpty { ui.calBrowse(k) } }
        .simultaneousGesture(TapGesture().onEnded { if !ps.isEmpty { ui.calDate = CalData.date(k); ui.calMode = .day } })
        .help(ps.isEmpty ? "" : "\(CalData.date(k).formatted(date: .complete, time: .omitted)) · \(ps.count) photo\(ps.count == 1 ? "" : "s")")
    }
}

struct YearsCal: View {
    let data: CalData
    @Environment(UIState.self) private var ui
    var body: some View {
        var by: [Int: [[Photo]]] = [:]
        for (k, ps) in data.byDay { let y = k / 10000, m = k / 100 % 100; by[y, default: Array(repeating: [], count: 12)][m - 1] += ps }
        let years = by.keys.sorted(by: >)
        let maxN = max(1, by.values.flatMap { $0.map(\.count) }.max() ?? 1)
        let months = (1...12).map { Calendar.current.date(from: DateComponents(year: 2000, month: $0, day: 1))!.formatted(.dateTime.month(.abbreviated)) }
        return ScrollView {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Color.clear.frame(width: 70, height: 1)
                    ForEach(months, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(years, id: \.self) { y in
                    GridRow {
                        Button { ui.calDate = Calendar.current.date(from: DateComponents(year: y, month: 1, day: 1)); ui.calMode = .year } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(y)).font(.headline)
                                Text(by[y]!.reduce(0) { $0 + $1.count }.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 70, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        ForEach(0..<12, id: \.self) { m in cell(y, m + 1, by[y]![m], maxN) }
                    }
                }
            }
            .padding(18)
        }
    }
    func cell(_ y: Int, _ m: Int, _ ps: [Photo], _ maxN: Int) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if ps.isEmpty { Color.primary.opacity(0.04) }
            else if ui.calHeat {
                Color.accentColor.opacity(heatColors[heatLevel(ps.count, maxN)])
                Text(ps.count.formatted()).font(.caption.weight(.semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let c = CalData.cover(ps) {
                CalThumb(photo: c)
                Text(ps.count.formatted()).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3)).padding(3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if !ps.isEmpty { ui.calDate = Calendar.current.date(from: DateComponents(year: y, month: m, day: 1)); ui.calMode = .month } }
        .help(ps.isEmpty ? "" : "\(Calendar.current.date(from: DateComponents(year: y, month: m, day: 1))!.formatted(.dateTime.month(.wide).year())) · \(ps.count) photos")
    }
}

struct WeekCal: View {
    let data: CalData
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let cal = Calendar.current, a = cal.dateInterval(of: .weekOfYear, for: ui.calDay)?.start ?? ui.calDay, today = CalData.key(Date())
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<7, id: \.self) { i in
                let day = cal.date(byAdding: .day, value: i, to: a)!, k = CalData.key(day)
                let ps = data.photos(k).sorted { $0.date < $1.date }
                VStack(alignment: .leading, spacing: 6) {
                    Button { if !ps.isEmpty { ui.calDate = day; ui.calMode = .day } } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated).day())).fontWeight(.semibold).foregroundStyle(k == today ? Color.accentColor : .primary)
                            Text(ps.isEmpty ? "No photos" : "\(ps.count) photo\(ps.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(ps) { p in
                                CalThumb(photo: p).aspectRatio(1.4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: ui.selection.contains(p.id) ? 2 : 0))
                                    .onTapGesture { ui.calOpen(p, lib) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
    }
}

struct DayCal: View {
    let data: CalData
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let k = CalData.key(ui.calDay), ps = data.photos(k).sorted { $0.date < $1.date }
        let hours = Dictionary(grouping: ps) { Calendar.current.component(.hour, from: $0.captureDate) }
        if ps.isEmpty {
            VStack(spacing: 8) {
                Text("No photos on this day").font(.title3)
                Text("Use ← → to jump to the nearest day with photos.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let places = Array(Set(ps.compactMap { $0.placeLabel.split(separator: ",").first.map(String.init) })).sorted().prefix(3)
                    if !places.isEmpty { Text(places.joined(separator: ", ")).foregroundStyle(.secondary) }
                    ForEach(hours.keys.sorted(), id: \.self) { h in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Calendar.current.date(from: DateComponents(hour: h))!.formatted(.dateTime.hour())).font(.headline)
                                Text("\(hours[h]!.count) photo\(hours[h]!.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 70, alignment: .leading)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], spacing: 6) {
                                ForEach(hours[h]!) { p in
                                    CalThumb(photo: p).aspectRatio(1.4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: ui.selection.contains(p.id) ? 2 : 0))
                                        .onTapGesture { ui.calOpen(p, lib) }
                                        .help(p.captureDate.formatted(date: .omitted, time: .shortened))
                                }
                            }
                        }
                    }
                    Button("Open This Day in the Browser") { ui.calBrowse(k) }
                }
                .padding(18)
            }
        }
    }
}
