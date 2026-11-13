import SwiftUI
import NetworkExtension
import UIKit

// MARK: - Theme & helpers

enum Theme {
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.38, green: 0.56, blue: 1.0)
    static let good = Color(red: 0.25, green: 0.84, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.40)

    static func score(_ s: Double?) -> Color {
        guard let s else { return .gray }
        if s >= 75 { return good }
        if s >= 50 { return warn }
        return bad
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

struct ScoreRing: View {
    var score: Double?
    var size: CGFloat = 56
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: size / 9)
            Circle()
                .trim(from: 0, to: CGFloat((score ?? 0) / 100))
                .stroke(Theme.score(score), style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(score.map { String(Int($0.rounded())) } ?? "—")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
        }
        .frame(width: size, height: size)
    }
}

struct Sparkline: View {
    var dots: [ProbeDot]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(dots.suffix(16).enumerated()), id: \.offset) { _, d in
                Capsule()
                    .fill(d.ok ? Theme.good : Theme.bad)
                    .frame(width: 4, height: d.ok ? 10 : 16)
            }
        }
        .frame(height: 16, alignment: .bottom)
    }
}

func fmtRate(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .binary) + "/с"
}
func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
}
func fmtTime(_ t: Double) -> String {
    Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .standard)
}
func linesBinding(_ b: Binding<[String]>) -> Binding<String> {
    Binding(
        get: { b.wrappedValue.joined(separator: "\n") },
        set: { text in
            b.wrappedValue = text
                .components(separatedBy: CharacterSet(charactersIn: "\n, "))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    )
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var m: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Главная", systemImage: "bolt.shield.fill") }.tag(0)
            ServersView()
                .tabItem { Label("Серверы", systemImage: "server.rack") }.tag(1)
            MonitorView()
                .tabItem { Label("Монитор", systemImage: "waveform.path.ecg") }.tag(2)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(Theme.accent)
        .onChange(of: m.profile) { _ in m.persist() }
        .overlay(alignment: .top) {
            if let t = m.toast {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: m.toast)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var m: AppModel
    @Binding var tab: Int
    @State private var pulse = false

    private var accent: Color {
        switch m.status {
        case .connected: return Theme.good
        case .connecting, .reasserting: return Theme.warn
        default: return Color.white.opacity(0.45)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                connectButton
                banners
                if m.isOn, let st = m.state, st.phase == "running" {
                    activeCard(st)
                    servicesCard(st)
                    trafficCard(st)
                    controlsCard(st)
                    eventsCard(st)
                } else if !m.isOn {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Умный мониторинг", systemImage: "sparkles").font(.headline)
                            Text("После подключения здесь появятся оценки Instagram, WhatsApp и других сервисов по каждому серверу, живые события и автоматическое переключение при деградации.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var connectButton: some View {
        VStack(spacing: 14) {
            Button { m.toggle() } label: {
                ZStack {
                    Circle().stroke(accent.opacity(0.35), lineWidth: 2)
                        .frame(width: 196, height: 196)
                        .scaleEffect(pulse ? 1.07 : 1.0)
                    Circle()
                        .fill(RadialGradient(colors: [accent.opacity(0.35), accent.opacity(0.08)],
                                             center: .center, startRadius: 4, endRadius: 90))
                        .frame(width: 170, height: 170)
                    Circle().stroke(accent, lineWidth: 3).frame(width: 170, height: 170)
                    if m.working {
                        ProgressView().scaleEffect(1.6)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 58, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .onChange(of: m.status) { s in pulse = (s == .connecting || s == .reasserting) }
            .animation(pulse ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : Animation.default, value: pulse)

            VStack(spacing: 4) {
                Text(m.statusTitle).font(.title3.weight(.semibold))
                if let st = m.state, m.isOn, let a = m.server(st.activeID) {
                    Text(a.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if m.needsRestart {
            Card {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.warn)
                    Text("Настройки изменены").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Применить") { Task { await m.restart() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        if let e = m.startError, !m.isOn {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ошибка запуска", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                    Text(e).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        if let e = m.storeError {
            Card { Label(e, systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(Theme.bad) }
        }
    }

    private func activeCard(_ st: TunnelState) -> some View {
        let h = st.activeID.flatMap { st.health[$0] }
        let a = m.server(st.activeID)
        return Card {
            HStack(spacing: 14) {
                ScoreRing(score: h?.overall, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(a?.name ?? "—").font(.headline).lineLimit(1)
                    Text(a?.subtitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if let id = st.activeID, let r = m.role(of: id) { Pill(text: r, color: Theme.accent) }
                        if st.observing { Pill(text: "наблюдение", color: Theme.warn) }
                        if let b = st.busy { Pill(text: b, color: .gray) }
                    }
                }
                Spacer()
            }
        }
    }

    private func servicesCard(_ st: TunnelState) -> some View {
        let active = st.activeID
        let services = m.profile.settings.services.filter { $0.enabled }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(services) { svc in
                let sc = active.flatMap { st.health[$0]?.services[svc.id] }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: svc.icon).foregroundStyle(Theme.score(sc?.score))
                            Text(svc.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(sc.map { String(Int($0.score.rounded())) } ?? "—")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.score(sc?.score))
                            if let ms = sc?.latencyMs { Text("\(ms) мс").font(.caption).foregroundStyle(.secondary) }
                        }
                        Sparkline(dots: st.history[svc.id] ?? [])
                    }
                }
            }
        }
    }

    private func trafficCard(_ st: TunnelState) -> some View {
        Card {
            VStack(spacing: 10) {
                HStack {
                    Label(fmtRate(st.downBps), systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.good)
                    Spacer()
                    Label(fmtRate(st.upBps), systemImage: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
                }
                .font(.subheadline.weight(.semibold))
                Divider().overlay(Theme.stroke)
                HStack {
                    Text("Всего ↓ \(fmtBytes(st.totalDown)) · ↑ \(fmtBytes(st.totalUp))")
                    Spacer()
                    Text("\(st.conns) соед.")
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Сеть: \(netName(st.net))")
                    Spacer()
                    if let mem = st.availMemMB { Text("Свободно памяти: \(mem) МБ") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func controlsCard(_ st: TunnelState) -> some View {
        Card {
            VStack(spacing: 12) {
                Toggle(isOn: Binding(get: { st.auto }, set: { m.setAuto($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умное автопереключение").font(.subheadline.weight(.semibold))
                        Text("По реальной работе сервисов, а не по пингу").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button { m.probeNow() } label: { Label("Проверить", systemImage: "stethoscope").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { m.resetConnections() } label: { Label("Сбросить соед.", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func eventsCard(_ st: TunnelState) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("События").font(.headline)
                    Spacer()
                    Button("Все") { tab = 2 }.font(.subheadline)
                }
                ForEach(Array(st.events.suffix(3).reversed())) { e in EventRow(e: e) }
                if st.events.isEmpty { Text("Пока тихо").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func netName(_ n: String) -> String {
        switch n {
        case "wifi": return "Wi-Fi"
        case "cellular": return "Сотовая"
        case "wired": return "Проводная"
        case "none": return "нет сети"
        default: return n
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EventRow: View {
    var e: EventLine
    private var icon: (String, Color) {
        switch e.level {
        case "ok": return ("checkmark.circle.fill", Theme.good)
        case "warn": return ("exclamationmark.triangle.fill", Theme.warn)
        case "err": return ("xmark.octagon.fill", Theme.bad)
        default: return ("info.circle.fill", Theme.accent)
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.0).foregroundStyle(icon.1).font(.caption).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(fmtTime(e.t)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Servers

struct ServersView: View {
    @EnvironmentObject var m: AppModel
    @State private var selected: String?
    @State private var showSub = false
    @State private var subName = ""
    @State private var subURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(m.profile.servers) { s in
                        Button { selected = s.id } label: { ServerRow(server: s) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.card)
                    }
                    .onDelete { idx in m.delete(idx.map { m.profile.servers[$0].id }) }
                    .onMove { m.profile.servers.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Первый включённый сервер — основной, следующие \(m.profile.settings.maxBackups) — резервные")
                        .textCase(nil)
                }
                if m.profile.servers.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Серверов нет").font(.headline)
                            Text("Скопируй ссылки vless:// vmess:// trojan:// ss:// hysteria2:// и нажми «+» → «Вставить из буфера».")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                    }
                }
                if !m.profile.subscriptions.isEmpty {
                    Section("Подписки") {
                        ForEach(m.profile.subscriptions) { sub in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.name).font(.subheadline.weight(.semibold))
                                Text(sub.updated.map { "обновлено " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "не обновлялась")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .listRowBackground(Theme.card)
                            .swipeActions {
                                Button(role: .destructive) { m.removeSubscription(sub.id) } label: { Label("Удалить", systemImage: "trash") }
                                Button { Task { await m.refreshSubscription(sub.id) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                                    .tint(Theme.accent)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Серверы")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { m.pasteFromClipboard() } label: { Label("Вставить из буфера", systemImage: "doc.on.clipboard") }
                        Button { showSub = true } label: { Label("Добавить подписку", systemImage: "link.badge.plus") }
                        Button {
                            Task { for s in m.profile.subscriptions { await m.refreshSubscription(s.id) } }
                        } label: { Label("Обновить подписки", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(item: Binding(get: { selected.map { IDBox(id: $0) } }, set: { selected = $0?.id })) { box in
                ServerDetailView(id: box.id).environmentObject(m)
            }
            .alert("Подписка", isPresented: $showSub) {
                TextField("Название (необязательно)", text: $subName)
                TextField("https://…", text: $subURL)
                Button("Добавить") {
                    let n = subName, u = subURL
                    subName = ""; subURL = ""
                    Task { await m.addSubscription(name: n, url: u) }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }
}

struct IDBox: Identifiable { var id: String }

struct ServerRow: View {
    @EnvironmentObject var m: AppModel
    var server: Server

    var body: some View {
        let h = m.state?.health[server.id]
        let isActive = m.isOn && m.state?.activeID == server.id
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.score(h?.overall).opacity(0.18)).frame(width: 38, height: 38)
                Text(h?.overall.map { String(Int($0.rounded())) } ?? "·")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.score(h?.overall))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(server.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let u = server.unsupported {
                    Text(u).font(.caption2).foregroundStyle(Theme.bad).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isActive { Pill(text: "активен", color: Theme.good) }
                if let r = m.role(of: server.id) { Pill(text: r, color: Theme.accent) }
                else if server.unsupported == nil, !server.enabled { Pill(text: "выкл", color: .gray) }
                if let q = h?.quarantineLeft, q > 0 { Pill(text: "карантин \(q) с", color: Theme.warn) }
            }
        }
        .contentShape(Rectangle())
    }
}

struct ServerDetailView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    var id: String

    private var idx: Int? { m.profile.servers.firstIndex { $0.id == id } }

    var body: some View {
        NavigationStack {
            if let i = idx {
                let s = m.profile.servers[i]
                let h = m.state?.health[id]
                Form {
                    Section("Сервер") {
                        TextField("Название", text: Binding(get: { m.profile.servers[i].name },
                                                            set: { m.profile.servers[i].name = $0 }))
                        LabeledContent("Протокол", value: s.kind.title)
                        LabeledContent("Адрес", value: "\(s.host):\(s.port)")
                        if !s.securityLabel.isEmpty { LabeledContent("Транспорт", value: s.securityLabel) }
                        Toggle("Включён", isOn: Binding(get: { m.profile.servers[i].enabled },
                                                        set: { m.profile.servers[i].enabled = $0 && s.unsupported == nil }))
                            .disabled(s.unsupported != nil)
                        if let u = s.unsupported { Text(u).font(.caption).foregroundStyle(Theme.bad) }
                    }
                    if let h {
                        Section("Здоровье") {
                            LabeledContent("Общая оценка", value: h.overall.map { String(Int($0)) } ?? "нет данных")
                            ForEach(m.profile.settings.services.filter { $0.enabled }) { svc in
                                if let sc = h.services[svc.id] {
                                    LabeledContent(svc.name, value: "\(Int(sc.score))" + (sc.latencyMs.map { " · \($0) мс" } ?? ""))
                                } else {
                                    LabeledContent(svc.name, value: "—")
                                }
                            }
                        }
                    }
                    Section {
                        Button("Сделать основным") { m.setPrimary(id) }
                            .disabled(s.unsupported != nil)
                        if m.isOn, m.profile.pool.contains(where: { $0.id == id }), m.state?.activeID != id {
                            Button("Переключиться сейчас") { m.select(id); dismiss() }
                        }
                        Button("Удалить", role: .destructive) { m.delete([id]); dismiss() }
                    }
                }
                .navigationTitle(s.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
            } else {
                Text("Сервер удалён").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Monitor

struct MonitorView: View {
    @EnvironmentObject var m: AppModel
    @State private var mode = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Оценки").tag(0)
                    Text("События").tag(1)
                    Text("Лог ядра").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(16)

                ScrollView {
                    VStack(spacing: 14) {
                        if mode == 0 { scores }
                        else if mode == 1 { events }
                        else { coreLog }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 20)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Монитор")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { m.probeNow() } label: { Image(systemName: "stethoscope") }.disabled(!m.isOn)
                }
            }
        }
    }

    @ViewBuilder private var scores: some View {
        let services = m.profile.settings.services.filter { $0.enabled }
        let pool = m.profile.pool
        if pool.isEmpty {
            Text("Нет серверов в пуле").foregroundStyle(.secondary)
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Матрица сервер × сервис").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("").frame(width: 90, alignment: .leading)
                                ForEach(services) { s in
                                    Text(s.id == ServiceTarget.baselineID ? "Сеть" : s.name)
                                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text("Итог").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(pool) { s in
                                let h = m.state?.health[s.id]
                                GridRow {
                                    HStack(spacing: 4) {
                                        if m.state?.activeID == s.id { Circle().fill(Theme.good).frame(width: 6, height: 6) }
                                        Text(s.name).font(.caption).lineLimit(1)
                                    }
                                    .frame(width: 90, alignment: .leading)
                                    ForEach(services) { svc in
                                        let sc = h?.services[svc.id]
                                        Text(sc.map { String(Int($0.score)) } ?? "—")
                                            .font(.system(.footnote, design: .rounded).weight(.bold))
                                            .foregroundStyle(Theme.score(sc?.score))
                                    }
                                    Text(h?.overall.map { String(Int($0)) } ?? "—")
                                        .font(.system(.footnote, design: .rounded).weight(.bold))
                                        .foregroundStyle(Theme.score(h?.overall))
                                }
                            }
                        }
                    }
                    Text("Оценка 0–100: доступность и задержка с затуханием (полураспад 10 мин) минус штраф за зависания. Итог = 35% среднее + 65% худший критичный сервис.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(services) { svc in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: svc.icon)
                            Text(svc.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Sparkline(dots: m.state?.history[svc.id] ?? [])
                        }
                        ForEach(svc.probes, id: \.self) { u in
                            Text(URL(string: u)?.host ?? u).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var events: some View {
        let list = Array((m.state?.events ?? []).reversed())
        if list.isEmpty {
            Text(m.isOn ? "Событий пока нет" : "Туннель не запущен").foregroundStyle(.secondary).padding(.top, 30)
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list) { e in EventRow(e: e) }
                }
            }
        }
    }

    @ViewBuilder private var coreLog: some View {
        HStack {
            Button { m.fetchCoreLog() } label: { Label("Обновить", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
            Button { UIPasteboard.general.string = m.coreLog; m.flash("Скопировано") } label: { Label("Копировать", systemImage: "doc.on.doc") }
                .buttonStyle(.bordered)
            Spacer()
        }
        Card {
            Text(m.coreLog.isEmpty ? "Нажми «Обновить»" : m.coreLog)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
        .onAppear { m.fetchCoreLog() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var showConfig = false
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Умное автопереключение", isOn: Binding(get: { m.profile.settings.autoFailover },
                                                                   set: { m.setAuto($0) }))
                    Picker("Режим", selection: $m.profile.settings.preset) {
                        ForEach(Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(m.profile.settings.preset.hint).font(.caption).foregroundStyle(.secondary)
                    Stepper("Резервных серверов: \(m.profile.settings.maxBackups)", value: $m.profile.settings.maxBackups, in: 1...3)
                } header: { Text("Failover") }

                Section {
                    ForEach($m.profile.settings.services) { $svc in
                        NavigationLink {
                            ServiceEditor(svc: $svc)
                        } label: {
                            HStack {
                                Image(systemName: svc.icon).frame(width: 22)
                                Text(svc.name)
                                Spacer()
                                Toggle("", isOn: $svc.enabled).labelsHidden()
                            }
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { m.profile.settings.services[$0] }.filter { !$0.builtin }.map { $0.id }
                        m.profile.settings.services.removeAll { ids.contains($0.id) }
                    }
                    Button { showAdd = true } label: { Label("Добавить сервис", systemImage: "plus") }
                } header: { Text("Отслеживаемые сервисы") }
                  footer: { Text("Для каждого сервиса: домены для пассивного анализа и 2+ независимых адреса для активных проверок.") }

                Section {
                    Picker("MTU", selection: $m.profile.settings.mtu) {
                        Text("1280").tag(1280); Text("1360").tag(1360); Text("1400").tag(1400); Text("1500").tag(1500)
                    }
                    Toggle("Блокировать QUIC (быстрый откат на TCP)", isOn: $m.profile.settings.blockQUIC)
                    Toggle("Предпочитать IPv4 в DNS", isOn: $m.profile.settings.preferIPv4)
                    Toggle("FakeIP", isOn: $m.profile.settings.fakeIP)
                    LabeledContent("Bootstrap DNS") {
                        TextField("1.1.1.1", text: $m.profile.settings.bootstrapDNS)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("Удалённый DNS") {
                        TextField("https://1.1.1.1/dns-query", text: $m.profile.settings.remoteDNS)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("Сеть и DNS") }
                  footer: { Text("Изменения применяются после перезапуска туннеля.") }

                Section {
                    TextEditor(text: linesBinding($m.profile.settings.directDomains))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Напрямую, без прокси (домены)") }

                Section {
                    Button("Показать конфиг sing-box") { showConfig = true }
                    if let mem = m.state?.availMemMB {
                        LabeledContent("Свободно памяти у туннеля", value: "\(mem) МБ")
                    }
                    Button("Сбросить настройки сервисов", role: .destructive) {
                        m.profile.settings.services = ServiceTarget.defaults
                    }
                } header: { Text("Диагностика") }
                  footer: { Text("Ядро: sing-box 1.11.x (libbox). Лимит памяти расширения зависит от устройства и iOS — смотри значение выше.") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Настройки")
            .sheet(isPresented: $showConfig) {
                NavigationStack {
                    ScrollView {
                        Text(Store.loadConfigPreview() ?? "Конфиг появится после первого запуска туннеля")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).padding()
                    }
                    .navigationTitle("Конфиг (секреты скрыты)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { showConfig = false } } }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddServiceSheet { svc in m.profile.settings.services.append(svc) }
            }
        }
    }
}

struct ServiceEditor: View {
    @Binding var svc: ServiceTarget

    var body: some View {
        Form {
            Section("Основное") {
                TextField("Название", text: $svc.name)
                Toggle("Включён", isOn: $svc.enabled)
                Toggle("Критичный (влияет на итоговую оценку)", isOn: $svc.critical)
                Stepper("Вес: \(String(format: "%.1f", svc.weight))", value: $svc.weight, in: 0.2...2, step: 0.1)
            }
            Section {
                TextEditor(text: linesBinding($svc.suffixes))
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 80)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Домены (пассивный анализ)") }
              footer: { Text("Суффиксы имён хостов, например instagram.com. Нужен SNI/Host-sniffing ядра.") }
            Section {
                TextEditor(text: linesBinding($svc.probes))
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 100)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Адреса активных проверок") }
              footer: { Text("Минимум два независимых https-адреса. Любой HTTP-ответ считается успехом; ошибка засчитывается только если адрес хоть раз отвечал через какой-либо сервер.") }
        }
        .navigationTitle(svc.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (ServiceTarget) -> Void
    @State private var name = ""
    @State private var domains = ""
    @State private var probes = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                Section("Домены (по одному в строке)") {
                    TextEditor(text: $domains).frame(minHeight: 70)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Адреса проверок https://… (2+)") {
                    TextEditor(text: $probes).frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle("Новый сервис")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Добавить") {
                        let split: (String) -> [String] = {
                            $0.components(separatedBy: CharacterSet(charactersIn: "\n, "))
                                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                        let svc = ServiceTarget(id: "c-" + String(UUID().uuidString.prefix(6)).lowercased(),
                                                name: name.isEmpty ? "Сервис" : name, icon: "globe",
                                                suffixes: split(domains), probes: split(probes),
                                                enabled: true, critical: false, weight: 0.7, builtin: false)
                        onAdd(svc)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
