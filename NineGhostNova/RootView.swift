import SwiftUI
import UIKit

private enum NovaTab: Int, CaseIterable {
    case home, devices, control, settings

    var title: String {
        switch self {
        case .home: "Главная"
        case .devices: "Устройства"
        case .control: "Пульт"
        case .settings: "Настройки"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .devices: "dot.radiowaves.left.and.right"
        case .control: "diamond.fill"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var bluetooth: NovaBluetoothController
    @State private var unlocked = false
    @State private var pin = ""
    @State private var tab: NovaTab = .home
    @Namespace private var navigationNamespace
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("autoResumeSpam") private var autoResumeSpam = false
    @AppStorage("showAllBLE") private var showAllBLE = false
    @AppStorage("ninebotSLDiagnosticsV27") private var ninebotSLCompatibility = true
    @AppStorage("reliableTestModeV210") private var reliableTestMode = true

    var body: some View {
        ZStack {
            NovaBackground(maxEnabled: bluetooth.isMaxMode, profEnabled: bluetooth.isProfMode)
            if unlocked {
                appShell
                    .transition(.asymmetric(insertion: .scale(scale: 1.03).combined(with: .opacity), removal: .opacity))
            } else {
                PinLockView(pin: $pin) {
                    withAnimation(.spring(response: 0.56, dampingFraction: 0.82)) { unlocked = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .tint(NovaTheme.cyan)
        .onAppear { syncSettings() }
        .onChange(of: autoReconnect) { _ in syncSettings() }
        .onChange(of: autoResumeSpam) { _ in syncSettings() }
        .onChange(of: ninebotSLCompatibility) { _ in syncSettings() }
        .onChange(of: reliableTestMode) { enabled in
            if enabled { showAllBLE = true }
            syncSettings()
        }
        .onChange(of: bluetooth.state) { state in
            if state.isReady {
                withAnimation(.spring(response: 0.48, dampingFraction: 0.84)) { tab = .control }
            }
        }
    }

    private var appShell: some View {
        VStack(spacing: 0) {
            NovaTopBar(tab: tab, state: bluetooth.state, mode: bluetooth.operatingMode)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(NovaTheme.surface.opacity(0.58))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), NovaTheme.cyan.opacity(0.09), Color.white.opacity(0.025)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: NovaTheme.cyan.opacity(0.06), radius: 18, y: 7)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)

            ZStack {
                switch tab {
                case .home:
                    DashboardView(tab: $tab)
                        .transition(screenTransition)
                case .devices:
                    DevicesView(tab: $tab, showAll: $showAllBLE)
                        .transition(screenTransition)
                case .control:
                    ControlView(tab: $tab)
                        .transition(screenTransition)
                case .settings:
                    SettingsView(
                        autoReconnect: $autoReconnect,
                        autoResumeSpam: $autoResumeSpam,
                        showAllBLE: $showAllBLE,
                        ninebotSLCompatibility: $ninebotSLCompatibility,
                        reliableTestMode: $reliableTestMode
                    )
                        .transition(screenTransition)
                }
            }
            .animation(.spring(response: 0.46, dampingFraction: 0.86), value: tab)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomNavigation }
    }

    private var screenTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .scale(scale: 0.98))
        )
    }

    private var bottomNavigation: some View {
        HStack(spacing: 4) {
            ForEach(NovaTab.allCases, id: \.rawValue) { item in
                Button {
                    haptic(.light)
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { tab = item }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 9, weight: tab == item ? .semibold : .medium, design: .rounded))
                    }
                    .foregroundStyle(tab == item ? NovaTheme.cyan : NovaTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: [NovaTheme.cyan.opacity(0.19), NovaTheme.electricBlue.opacity(0.11), NovaTheme.violet.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .matchedGeometryEffect(id: "activeTab", in: navigationNamespace)
                                .overlay(alignment: .top) {
                                    Capsule().fill(NovaTheme.auroraGradient).frame(width: 28, height: 2).shadow(color: NovaTheme.cyan, radius: 8)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NovaTheme.cyan.opacity(0.12)))
                        }
                    }
                }
                .novaPressable()
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(NovaTheme.surface.opacity(0.72)))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.18), NovaTheme.cyan.opacity(0.1), Color.white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: Color.black.opacity(0.48), radius: 24, y: 10)
        .shadow(color: NovaTheme.cyan.opacity(0.075), radius: 18, y: -2)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 7)
    }

    private func syncSettings() {
        if reliableTestMode { showAllBLE = true }
        bluetooth.autoReconnect = autoReconnect
        bluetooth.autoResumeSpam = autoResumeSpam
        bluetooth.ninebotSLCompatibility = ninebotSLCompatibility
        bluetooth.reliableTestMode = reliableTestMode
    }
}

private struct PinLockView: View {
    @Binding var pin: String
    let onUnlock: () -> Void
    @State private var error = false
    @State private var shake: CGFloat = 0

    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete.left"]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let pulse = CGFloat(sin(time * 1.8)) * 0.04
                        let bob = CGFloat(sin(time * 1.35)) * 4
                        ZStack {
                            Circle()
                                .fill(NovaTheme.cyan.opacity(0.07))
                                .frame(width: 126, height: 126)
                                .blur(radius: 12)
                                .scaleEffect(0.96 + pulse)
                            NovaGhostMark(size: 74)
                                .offset(y: bob)
                        }
                    }
                    .frame(height: 132)

                    Text("NINEGHOST NOVA")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(2.1)
                        .foregroundStyle(NovaTheme.cyan)
                    Text("Введите код-пароль")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .padding(.top, 34)
                    Text("4 цифры для локального доступа")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(NovaTheme.muted)
                        .padding(.top, 8)

                    HStack(spacing: 20) {
                        ForEach(0..<4, id: \.self) { index in
                            Circle()
                                .fill(index < pin.count ? NovaTheme.cyan : NovaTheme.surfaceRaised)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(NovaTheme.cyan.opacity(index < pin.count ? 0.35 : 0), lineWidth: 7))
                                .scaleEffect(index < pin.count ? 1.08 : 1)
                                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: pin.count)
                        }
                    }
                    .offset(x: shake)
                    .padding(.top, 54)

                    Text(error ? "Неверный код. Попробуйте ещё раз" : " ")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(NovaTheme.rose)
                        .padding(.top, 20)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3), spacing: 20) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                            if key.isEmpty {
                                Color.clear.frame(height: 72)
                            } else {
                                Button { press(key) } label: {
                                    ZStack {
                                        Circle()
                                            .fill(RadialGradient(colors: [NovaTheme.surfaceRaised, NovaTheme.surface.opacity(0.9)], center: .topLeading, startRadius: 0, endRadius: 58))
                                            .overlay(Circle().stroke(NovaTheme.line, lineWidth: 1))
                                        if key == "delete.left" {
                                            Image(systemName: key).font(.system(size: 20, weight: .medium))
                                        } else {
                                            Text(key).font(.system(size: 26, weight: .medium, design: .rounded))
                                        }
                                    }
                                    .foregroundStyle(Color.white)
                                    .frame(width: 72, height: 72)
                                    .shadow(color: NovaTheme.cyan.opacity(0.035), radius: 20)
                                }
                                .novaPressable()
                            }
                        }
                    }
                    .padding(.horizontal, 38)
                    .padding(.top, 18)

                    Label("Локальная защита • без передачи данных", systemImage: "lock.shield.fill")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(NovaTheme.muted.opacity(0.62))
                        .padding(.top, 34)
                        .padding(.bottom, 20)
                }
                .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func press(_ key: String) {
        haptic(.light)
        error = false
        if key == "delete.left" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < 4 else { return }
        pin.append(key)
        guard pin.count == 4 else { return }
        if pin == "0431" {
            haptic(.medium)
            onUnlock()
        } else {
            error = true
            haptic(.heavy)
            withAnimation(.linear(duration: 0.08).repeatCount(5, autoreverses: true)) { shake = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                shake = 0
                pin = ""
            }
        }
    }
}

private struct NovaTopBar: View {
    let tab: NovaTab
    let state: NovaBluetoothController.ConnectionState
    let mode: NovaBluetoothController.OperatingMode

    var body: some View {
        HStack(spacing: 12) {
            NovaGhostMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab == .home ? "NineGhost Nova" : tab.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(NovaTheme.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                if mode == .max {
                    MaxModeBadge(active: state.isReady, compact: true)
                } else if mode == .prof {
                    ProfModeBadge(active: state.isReady, compact: true)
                }
                StatusBadge(
                    text: state.isAuthenticated ? "AUTH OK" : (state.isSLCompatibility ? "KEY NAK" : mode.title),
                    color: state.isAuthenticated ? NovaTheme.green : (state.isSLCompatibility ? NovaTheme.amber : modeColor),
                    pulsing: state.isReady
                )
            }
        }
    }

    private var subtitle: String {
        switch tab {
        case .home:
            switch mode {
            case .standard: "центр управления"
            case .max: "MAX control layer"
            case .prof: "PROF secure network layer"
            }
        case .devices: "обнаружение Nordic UART"
        case .control: "защищённая BLE-сессия"
        case .settings: "приватность и подключение"
        }
    }

    private var modeColor: Color {
        switch mode {
        case .standard: NovaTheme.cyan
        case .max: NovaTheme.max
        case .prof: NovaTheme.prof
        }
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var bluetooth: NovaBluetoothController
    @Binding var tab: NovaTab

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GlassPanel {
                    ZStack(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(LinearGradient(colors: [NovaTheme.cyan.opacity(0.12), NovaTheme.violet.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        AnimatedOrbit(ready: bluetooth.state.isReady, size: 112)
                            .offset(x: 24, y: -8)
                            .opacity(0.74)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 7) {
                                if bluetooth.isMaxMode {
                                    MaxModeBadge(active: bluetooth.state.isReady)
                                } else if bluetooth.isProfMode {
                                    ProfModeBadge(active: bluetooth.state.isReady)
                                }
                                StatusBadge(
                                    text: bluetooth.state.isAuthenticated ? "AUTH OK" : (bluetooth.state.isSLCompatibility ? "KEY NAK" : "НЕ ГОТОВО"),
                                    color: bluetooth.state.isAuthenticated ? NovaTheme.green : NovaTheme.amber,
                                    pulsing: bluetooth.state.isReady
                                )
                            }
                            Text(bluetooth.connectedName)
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .padding(.top, 22)
                            Text(bluetooth.state.label)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(bluetooth.state.isReady ? NovaTheme.green : NovaTheme.muted)
                                .padding(.top, 6)
                            HStack(spacing: 10) {
                                NovaActionButton(title: "Найти", icon: "dot.radiowaves.left.and.right", tint: NovaTheme.cyan) {
                                    withAnimation { tab = .devices }
                                    bluetooth.startScan()
                                }
                                NovaActionButton(title: "Открыть пульт", icon: "slider.horizontal.3", tint: NovaTheme.violet) {
                                    withAnimation { tab = .control }
                                }
                            }
                            .padding(.top, 20)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if bluetooth.isMaxMode {
                    MaxModeCard(
                        state: bluetooth.state,
                        summary: bluetooth.handshakeSummary,
                        notificationActive: bluetooth.notificationChannelActive
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if bluetooth.isProfMode {
                    ProfModeCard(
                        state: bluetooth.state,
                        summary: bluetooth.handshakeSummary,
                        notificationActive: bluetooth.notificationChannelActive,
                        tokenStored: bluetooth.bleKeyStored,
                        scooterIdentifier: bluetooth.profScooterIdentifier
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                HStack(spacing: 12) {
                    MetricCard(label: "ЗАРЯД", value: "—", unit: "%", accent: NovaTheme.cyan)
                    MetricCard(label: "СКОРОСТЬ", value: "—", unit: "км/ч", accent: NovaTheme.violet)
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Быстрые действия")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        Text(commandAvailabilityText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(NovaTheme.muted)
                        HStack(spacing: 10) {
                            QuickButton(title: "Открыть", icon: "lock.open.fill", color: NovaTheme.cyan) { _ = bluetooth.sendUnlock() }
                                .disabled(!bluetooth.canSendCommands)
                                .opacity(bluetooth.canSendCommands ? 1 : 0.42)
                            QuickButton(title: "Закрыть", icon: "lock.fill", color: NovaTheme.violet) { _ = bluetooth.sendLock() }
                                .disabled(!bluetooth.canSendCommands)
                                .opacity(bluetooth.canSendCommands ? 1 : 0.42)
                            QuickButton(title: "Пульт", icon: "diamond.fill", color: NovaTheme.green) { withAnimation { tab = .control } }
                        }
                    }
                    .padding(18)
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Последняя активность")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        LogRow(text: bluetooth.logs.first ?? "Приложение готово", color: NovaTheme.cyan)
                        LogRow(text: "PIN-защита активна • данные остаются локально", color: NovaTheme.green)
                    }
                    .padding(18)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }

    private var commandAvailabilityText: String {
        if bluetooth.state.isSLCompatibility {
            return "Ключ отклонён: доступна только локальная BLE-диагностика"
        }
        if bluetooth.isProfMode && !bluetooth.profScooterNumberIsValid {
            return "Для PROF сначала укажите номер самоката в настройках"
        }
        return "Команды доступны после BLE Auth OK"
    }
}

private struct DevicesView: View {
    @EnvironmentObject private var bluetooth: NovaBluetoothController
    @Binding var tab: NovaTab
    @Binding var showAll: Bool

    private var filtered: [NovaBluetoothController.DiscoveredDevice] {
        bluetooth.devices.filter { showAll || $0.uartCompatible }
    }

    private var duplicateSegwayCount: Int {
        filtered.filter { $0.name.localizedCaseInsensitiveContains("Segway IoT") }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(bluetooth.state == .scanning ? "Поиск выполняется" : "Поиск поблизости")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                Text(bluetooth.state.label)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(bluetooth.state == .scanning ? NovaTheme.cyan : NovaTheme.muted)
                            }
                            Spacer()
                            RadarView(active: bluetooth.state == .scanning)
                        }
                        NovaActionButton(
                            title: bluetooth.state == .scanning ? "Остановить поиск" : "Начать поиск",
                            icon: bluetooth.state == .scanning ? "stop.fill" : "antenna.radiowaves.left.and.right",
                            tint: bluetooth.state == .scanning ? NovaTheme.amber : NovaTheme.cyan
                        ) {
                            if bluetooth.state == .scanning { bluetooth.stopScan() }
                            else { bluetooth.startScan() }
                        }
                    }
                    .padding(18)
                }

                HStack {
                    Text("Найденные устройства")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Button(showAll ? "Все BLE" : "Segway UART") { withAnimation { showAll.toggle() } }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(NovaTheme.cyan.opacity(0.12)))
                        .overlay(Capsule().stroke(NovaTheme.cyan.opacity(0.22)))
                        .novaPressable()
                }

                if duplicateSegwayCount > 1 {
                    GlassPanel {
                        Label(
                            "Найдено устройств Segway IoT: \(duplicateSegwayCount). Выберите своё по ID и уровню сигнала; BLE-ключ привязан к конкретному IoT.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(NovaTheme.amber)
                        .padding(14)
                    }
                }

                if filtered.isEmpty {
                    GlassPanel {
                        VStack(spacing: 14) {
                            RadarView(active: bluetooth.state == .scanning, large: true)
                            Text("Пока ничего не найдено")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                            Text(showAll ? "Включите Bluetooth и начните поиск" : "Показываются устройства с Nordic UART")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(NovaTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                } else {
                    ForEach(filtered) { device in
                        Button {
                            haptic(.medium)
                            bluetooth.connect(device)
                            withAnimation { tab = .control }
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill((device.uartCompatible ? NovaTheme.cyan : NovaTheme.muted).opacity(0.12))
                                    Image(systemName: device.uartCompatible ? "scooter" : "wave.3.right")
                                        .foregroundStyle(device.uartCompatible ? NovaTheme.cyan : NovaTheme.muted)
                                }
                                .frame(width: 46, height: 46)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(device.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                                    Text("ID \(device.shortID) • \(device.rssi) dBm")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(NovaTheme.muted)
                                }
                                Spacer()
                                if device.uartCompatible { StatusBadge(text: "UART", color: NovaTheme.cyan) }
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(NovaTheme.muted)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(NovaTheme.surface.opacity(0.82)))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(NovaTheme.line))
                        }
                        .foregroundStyle(.white)
                        .novaPressable()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ControlView: View {
    @EnvironmentObject private var bluetooth: NovaBluetoothController
    @Binding var tab: NovaTab
    @State private var locked = true
    @State private var lightOn = false
    @State private var gsmOn = true
    @State private var showDiagnostics = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GlassPanel {
                    HStack(spacing: 16) {
                        AnimatedOrbit(ready: bluetooth.state.isReady, size: 72)
                        VStack(alignment: .leading, spacing: 5) {
                            StatusBadge(text: "NORDIC UART", color: NovaTheme.cyan)
                            Text(bluetooth.connectedName)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Text(bluetooth.state.label)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(bluetooth.state.isReady ? NovaTheme.green : NovaTheme.muted)
                        }
                        Spacer()
                        Button {
                            if bluetooth.state.isReady { bluetooth.disconnect() }
                            else { withAnimation { tab = .devices }; bluetooth.startScan() }
                        } label: {
                            Image(systemName: bluetooth.state.isReady ? "power" : "link")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill((bluetooth.state.isReady ? NovaTheme.rose : NovaTheme.green).opacity(0.13)))
                        }
                        .novaPressable()
                    }
                    .padding(16)
                }

                HStack(spacing: 10) {
                    MiniMetric(label: "СКОРОСТЬ", value: "—", unit: "км/ч", color: NovaTheme.cyan)
                    MiniMetric(label: "ЗАРЯД", value: "—", unit: "%", color: NovaTheme.green)
                    MiniMetric(label: "ПРОБЕГ", value: "—", unit: "км", color: NovaTheme.violet)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Управление")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    LazyVGrid(columns: columns, spacing: 10) {
                        CommandTile(title: locked ? "Открыть" : "Открыто", icon: "lock.open.fill", color: NovaTheme.cyan) {
                            if bluetooth.sendUnlock() { locked = false }
                        }
                        CommandTile(title: locked ? "Закрыто" : "Закрыть", icon: "lock.fill", color: NovaTheme.violet) {
                            if bluetooth.sendLock() { locked = true }
                        }
                        CommandTile(title: lightOn ? "Свет: ON" : "Свет: OFF", icon: "lightbulb.fill", color: NovaTheme.amber) {
                            if bluetooth.sendLight(enabled: !lightOn) { lightOn.toggle() }
                        }
                        CommandTile(title: "Батарея", icon: "battery.100percent", color: NovaTheme.green) { _ = bluetooth.sendBatteryCoverUnlock() }
                        CommandTile(title: "Шлем", icon: "bicycle", color: NovaTheme.cyan) { _ = bluetooth.sendHelmetUnlock() }
                        CommandTile(title: gsmOn ? "GSM: ON" : "GSM: OFF", icon: "antenna.radiowaves.left.and.right", color: NovaTheme.violet) {
                            if bluetooth.sendGSM(enabled: !gsmOn) { gsmOn.toggle() }
                        }
                    }
                    .disabled(!bluetooth.canSendCommands)
                    .opacity(bluetooth.canSendCommands ? 1 : 0.42)
                }

                GlassPanel {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill((bluetooth.spamRunning ? NovaTheme.rose : NovaTheme.cyan).opacity(0.12))
                            Image(systemName: bluetooth.spamRunning ? "waveform.path.ecg" : "repeat")
                                .foregroundStyle(bluetooth.spamRunning ? NovaTheme.rose : NovaTheme.cyan)
                        }
                        .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(keepAliveTitle)
                                .font(.system(size: 16, weight: .bold, design: bluetooth.isMaxMode ? .default : .rounded))
                            Text(bluetooth.spamRunning ? "Keep-Alive каждые 900 мс" : "Поддержание готовой BLE-сессии")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(bluetooth.spamRunning ? NovaTheme.cyan : NovaTheme.muted)
                        }
                        Spacer()
                        NovaActionButton(title: bluetooth.spamRunning ? "STOP" : "START", icon: bluetooth.spamRunning ? "stop.fill" : "play.fill", tint: bluetooth.spamRunning ? NovaTheme.rose : NovaTheme.cyan) {
                            haptic(.heavy)
                            bluetooth.toggleSpam()
                        }
                        .frame(width: 104)
                        .disabled(!bluetooth.canSendCommands && !bluetooth.spamRunning)
                    }
                    .padding(16)
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Журнал").font(.system(size: 16, weight: .bold, design: .rounded))
                        HStack(spacing: 8) {
                            Text("Защищённая трассировка • CRC • GATT • \(bluetooth.logs.count) записей")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(NovaTheme.muted)
                            Spacer()
                            Button {
                                showDiagnostics = true
                            } label: {
                                Label("ПОЛНЫЙ", systemImage: "text.alignleft")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(NovaTheme.cyan)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(NovaTheme.cyan.opacity(0.10)))
                            }
                            .novaPressable()
                        }
                        ForEach(Array(bluetooth.logs.prefix(5).enumerated()), id: \.offset) { index, log in
                            LogRow(text: log, color: index == 0 ? NovaTheme.cyan : NovaTheme.muted)
                        }
                    }
                    .padding(16)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
                .environmentObject(bluetooth)
        }
    }

    private var keepAliveTitle: String {
        switch bluetooth.operatingMode {
        case .standard: "Unlock spam"
        case .max: "MAX Keep-Alive"
        case .prof: "PROF Keep-Alive"
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var bluetooth: NovaBluetoothController
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Полная трассировка BLE")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(NovaTheme.cyan)
                    Text("Показаны метаданные RX/TX, CRC, GATT-состояния и коды ошибок. Ключи, сессионные данные и идентификаторы скрыты.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(NovaTheme.muted)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "wave.3.right.circle.fill")
                                .foregroundStyle(NovaTheme.cyan)
                            Text(bluetooth.blePassportStatus)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white)
                            Spacer()
                            Button("Снять BLE-паспорт") {
                                bluetooth.collectBLEPassport()
                                haptic(.light)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(NovaTheme.cyan)
                            .disabled(!bluetooth.canCollectBLEPassport)
                        }
                        if bluetooth.detectedIoTCodePresent {
                            Text("Найден IoT code / IMEI; значение защищено и не отображается")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(NovaTheme.green)
                        }
                        Text("Паспорт автоматически читает только открытые для чтения GATT-поля. Он не извлекает ключ авторизации и не показывает значения идентификаторов.")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(NovaTheme.muted)
                        Divider().overlay(NovaTheme.line)
                        Text("Handshake: \(bluetooth.handshakeSummary)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(bluetooth.state.isAuthenticated ? NovaTheme.green : NovaTheme.amber)
                        Button {
                            bluetooth.retryHandshake()
                            haptic(.medium)
                        } label: {
                            Label("Повторить handshake с текущим ключом", systemImage: "arrow.clockwise.shield")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .buttonStyle(.bordered)
                        .tint(NovaTheme.amber)
                        .disabled(!bluetooth.canRetryHandshake)
                        Divider().overlay(NovaTheme.line)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Аудит защиты")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                Text(bluetooth.securityAuditSummary)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(NovaTheme.muted)
                            }
                            Spacer()
                            Button("Проверить") {
                                bluetooth.runSecurityAudit()
                                haptic(.light)
                            }
                            .buttonStyle(.bordered)
                            .tint(NovaTheme.cyan)
                            .disabled(!bluetooth.canRunSecurityAudit)
                        }
                        ForEach(bluetooth.securityAuditFindings, id: \.self) { finding in
                            Text(finding)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(finding.hasPrefix("FAIL") ? NovaTheme.rose : NovaTheme.muted)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(NovaTheme.cyan.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(NovaTheme.cyan.opacity(0.2)))

                    ForEach(Array(bluetooth.logs.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(index == 0 ? NovaTheme.cyan : NovaTheme.muted)
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(entry)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(index == 0 ? Color.white : NovaTheme.muted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider().overlay(NovaTheme.line.opacity(0.7))
                    }
                }
                .padding(18)
            }
            .background(NovaTheme.background.ignoresSafeArea())
            .navigationTitle("Диагностика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = bluetooth.diagnosticReport
                        copied = true
                        haptic(.light)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        bluetooth.clearLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var bluetooth: NovaBluetoothController
    @Binding var autoReconnect: Bool
    @Binding var autoResumeSpam: Bool
    @Binding var showAllBLE: Bool
    @Binding var ninebotSLCompatibility: Bool
    @Binding var reliableTestMode: Bool
    @State private var revealProfToken = false
    @State private var copiedCredential = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsSection(title: "Режим системы", icon: "switch.2") {
                    Picker(
                        "Режим системы",
                        selection: Binding(
                            get: { bluetooth.operatingMode },
                            set: { mode in
                                haptic(.medium)
                                withAnimation(.spring(response: 0.48, dampingFraction: 0.84)) {
                                    bluetooth.setOperatingMode(mode)
                                }
                            }
                        )
                    ) {
                        ForEach(NovaBluetoothController.OperatingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Divider().overlay(NovaTheme.line)
                    SettingsInfoRow(
                        title: bluetooth.operatingMode.title,
                        subtitle: bluetooth.operatingMode.subtitle,
                        value: bluetooth.operatingMode.title,
                        color: modeAccent
                    )
                    Text("При смене режима активная BLE-сессия завершается. Подключитесь к устройству заново — состояния STANDARD, MAX и PROF не смешиваются.")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(NovaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if bluetooth.isProfMode {
                    SettingsSection(title: "Самокат PROF", icon: "number.square.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                settingsLabel(
                                    "Номер на руле",
                                    "Например, EB-798-T — приложение автоматически подготовит системный идентификатор"
                                )
                                Spacer(minLength: 12)
                                Text(bluetooth.profScooterNumberIsValid ? "READY" : "REQUIRED")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(bluetooth.profScooterNumberIsValid ? NovaTheme.green : NovaTheme.amber)
                            }

                            HStack(spacing: 8) {
                                TextField(
                                    "EB-798-T",
                                    text: Binding(
                                        get: { bluetooth.profScooterNumberText },
                                        set: { bluetooth.updateProfScooterNumber($0) }
                                    )
                                )
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))

                                if !bluetooth.profScooterNumberText.isEmpty {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            bluetooth.clearProfScooterNumber()
                                        }
                                        haptic(.light)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(NovaTheme.muted)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Очистить номер самоката")
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NovaTheme.background.opacity(0.78)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(bluetooth.profScooterNumberIsValid ? NovaTheme.prof.opacity(0.52) : NovaTheme.amber.opacity(0.48))
                            )

                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(bluetooth.profScooterIdentifier ?? "Введите минимум 4 буквы или цифры")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .foregroundStyle(bluetooth.profScooterNumberIsValid ? NovaTheme.prof : NovaTheme.muted)

                            Text("Номер сохраняется локально на этом iPhone и не встраивается в приложение.")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(NovaTheme.muted)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                SettingsSection(title: "Безопасность", icon: "lock.shield.fill") {
                    SettingsInfoRow(title: "Код-пароль", subtitle: "Запрашивается при каждом запуске", value: "••••", color: NovaTheme.cyan)
                    Divider().overlay(NovaTheme.line)
                    credentialEditor
                }
                SettingsSection(title: "Подключение", icon: "link") {
                    Toggle(isOn: $reliableTestMode) {
                        settingsLabel("Надёжный тестовый режим", "30 с поиска, тайм-аут зависшего подключения, до 8 переподключений и 3 повтора того же handshake")
                    }
                    .tint(NovaTheme.green)
                    Divider().overlay(NovaTheme.line)
                    Toggle(isOn: $autoReconnect) {
                        settingsLabel("Автоподключение", "После разрыва BLE-связи")
                    }
                    .tint(NovaTheme.cyan)
                    Divider().overlay(NovaTheme.line)
                    Toggle(isOn: $autoResumeSpam) {
                        settingsLabel("Возобновлять spam", "После успешного переподключения")
                    }
                    .tint(NovaTheme.violet)
                    Divider().overlay(NovaTheme.line)
                    Toggle(isOn: $ninebotSLCompatibility) {
                        settingsLabel("SL BLE-диагностика", "После NAK 00 00 оставить соединение только для паспорта и повтора ключа")
                    }
                    .tint(NovaTheme.amber)
                }
                SettingsSection(title: "BLE-поиск", icon: "dot.radiowaves.left.and.right") {
                    Toggle(isOn: $showAllBLE) {
                        settingsLabel("Показывать все устройства", "Без фильтра Nordic UART")
                    }
                    .tint(NovaTheme.cyan)
                }
                SettingsSection(title: "Локальная сессия", icon: "iphone.gen3") {
                    HStack {
                        AnimatedOrbit(ready: bluetooth.state.isReady, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bluetooth.state.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(bluetooth.isProfMode ? "PROF-токен доступен только из локального Keychain" : "Нет облачных токенов и внешнего входа")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(NovaTheme.muted)
                        }
                        Spacer()
                    }
                }
                Text("NineGhost Nova 2.11.7 • SwiftUI + CoreBluetooth\nТри изолированных профиля, защищённый Keychain и восстановление разрешённого устройства.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(NovaTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var credentialEditor: some View {
        if bluetooth.isProfMode {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    settingsLabel(
                        "Bearer-токен PROF API",
                        "Введите полное значение заголовка Authorization для разрешённого тестового доступа"
                    )
                    Spacer(minLength: 12)
                    Text(bluetooth.bleKeyFingerprint)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(bluetooth.bleKeyIsValid ? NovaTheme.green : NovaTheme.amber)
                }

                HStack(spacing: 8) {
                    Group {
                        if revealProfToken {
                            TextField("Bearer …", text: credentialBinding)
                        } else {
                            SecureField("Bearer …", text: credentialBinding)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            revealProfToken.toggle()
                        }
                        haptic(.light)
                    } label: {
                        Image(systemName: revealProfToken ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NovaTheme.prof)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(NovaTheme.prof.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealProfToken ? "Скрыть токен" : "Показать токен")
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NovaTheme.background.opacity(0.78)))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(bluetooth.bleKeyIsValid ? NovaTheme.prof.opacity(0.50) : NovaTheme.amber.opacity(0.55))
                )

                HStack(spacing: 8) {
                    Button {
                        _ = bluetooth.saveBLEKey()
                        revealProfToken = false
                        haptic(.light)
                    } label: {
                        Label("Сохранить токен", systemImage: "key.fill")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NovaTheme.prof)
                    .disabled(!bluetooth.bleKeyIsValid || bluetooth.bleKeyStored)

                    Button {
                        UIPasteboard.general.string = bluetooth.bleKeyText
                        copiedCredential = true
                        haptic(.light)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copiedCredential = false
                        }
                    } label: {
                        Image(systemName: copiedCredential ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .foregroundStyle(copiedCredential ? NovaTheme.green : NovaTheme.prof)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(NovaTheme.background.opacity(0.24)))
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.bleKeyText.isEmpty)

                    Button(role: .destructive) {
                        bluetooth.forgetBLEKey()
                        revealProfToken = false
                        haptic(.medium)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.bleKeyText.isEmpty)
                }

                Label(
                    bluetooth.bleKeyStored
                        ? "Токен хранится только в Keychain этого iPhone"
                        : "Токен не встроен в приложение и не сохранён",
                    systemImage: bluetooth.bleKeyStored ? "checkmark.shield.fill" : "shield"
                )
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(bluetooth.bleKeyStored ? NovaTheme.green : NovaTheme.muted)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    settingsLabel("Выданный тестовый BLE-ключ", "Ровно 8 латинских букв/цифр для выбранного авторизованного IoT")
                    Spacer()
                    Text(bluetooth.bleKeyFingerprint)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(bluetooth.bleKeyIsValid ? NovaTheme.green : NovaTheme.amber)
                }
                SecureField("8-символьный ключ", text: credentialBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 12).fill(NovaTheme.background.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(bluetooth.bleKeyIsValid ? NovaTheme.green.opacity(0.35) : NovaTheme.amber.opacity(0.55)))
                HStack(spacing: 8) {
                    Button {
                        _ = bluetooth.saveBLEKey()
                        haptic(.light)
                    } label: {
                        Label("Сохранить в Keychain", systemImage: "key.fill")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NovaTheme.cyan)
                    .disabled(!bluetooth.bleKeyIsValid || bluetooth.bleKeyStored)

                    Button {
                        UIPasteboard.general.string = bluetooth.bleKeyText
                        copiedCredential = true
                        haptic(.light)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copiedCredential = false
                        }
                    } label: {
                        Image(systemName: copiedCredential ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .foregroundStyle(copiedCredential ? NovaTheme.green : NovaTheme.cyan)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(NovaTheme.background.opacity(0.24)))
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.bleKeyText.isEmpty)

                    Button(role: .destructive) {
                        bluetooth.forgetBLEKey()
                        haptic(.medium)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.bleKeyText.isEmpty)
                }
                Text(bluetooth.bleKeyStored ? "Ключ хранится в Keychain только на этом iPhone" : "Ключ не сохранён; в приложении нет встроенного ключа")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(bluetooth.bleKeyStored ? NovaTheme.green : NovaTheme.muted)
            }
        }
    }

    private var credentialBinding: Binding<String> {
        Binding(
            get: { bluetooth.bleKeyText },
            set: { bluetooth.updateBLEKey($0) }
        )
    }

    private var modeAccent: Color {
        switch bluetooth.operatingMode {
        case .standard: NovaTheme.cyan
        case .max: NovaTheme.max
        case .prof: NovaTheme.prof
        }
    }

    private func settingsLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(NovaTheme.muted)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: icon)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NovaTheme.cyan)
                content
            }
            .padding(18)
        }
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let subtitle: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(NovaTheme.muted)
            }
            Spacer()
            Text(value).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
    }
}

private struct MaxModeBadge: View {
    let active: Bool
    var compact = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let pulse = active ? 0.5 + sin(timeline.date.timeIntervalSinceReferenceDate * 2.8) * 0.5 : 0
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: compact ? 8 : 9, weight: .black))
                Text("MAX")
                    .font(.system(size: compact ? 9 : 10, weight: .black, design: .default))
                    .tracking(compact ? 0.7 : 1.1)
            }
            .foregroundStyle(NovaTheme.maxGradient)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(Capsule().fill(Color.black.opacity(0.38)))
            .overlay(Capsule().stroke(NovaTheme.max.opacity(0.34 + pulse * 0.18), lineWidth: 1))
            .shadow(color: NovaTheme.max.opacity(0.12 + pulse * 0.12), radius: CGFloat(7 + pulse * 4))
        }
        .accessibilityLabel("Режим MAX")
        .accessibilityValue(active ? "готов" : "ожидает подключения")
    }
}

private struct MaxModeCard: View {
    let state: NovaBluetoothController.ConnectionState
    let summary: String
    let notificationActive: Bool

    var body: some View {
        GlassPanel {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [NovaTheme.max.opacity(0.12), Color.clear, NovaTheme.cyan.opacity(0.055)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        MaxModeBadge(active: state.isReady)
                        Spacer()
                        Text("CORE / 01")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(NovaTheme.muted)
                    }

                    Text("MAX")
                        .font(.system(size: 44, weight: .semibold, design: .default))
                        .tracking(-2.4)
                        .foregroundStyle(NovaTheme.maxGradient)
                        .padding(.top, 16)

                    Text(summary)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                        .padding(.top, 3)

                    Rectangle()
                        .fill(LinearGradient(colors: [NovaTheme.max.opacity(0.7), NovaTheme.line, Color.clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                        .padding(.vertical, 14)

                    HStack(spacing: 20) {
                        MaxDatum(label: "SESSION", value: sessionLabel, color: stateColor)
                        MaxDatum(label: "RX PIPE", value: notificationActive ? "ONLINE" : "STANDBY", color: notificationActive ? NovaTheme.green : NovaTheme.muted)
                        MaxDatum(label: "PROFILE", value: "AIRSHIP", color: NovaTheme.max)
                    }
                }
                .padding(18)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateColor: Color {
        if state.isAuthenticated { return NovaTheme.green }
        if state.isSLCompatibility { return NovaTheme.amber }
        return NovaTheme.muted
    }

    private var sessionLabel: String {
        if state.isAuthenticated { return "READY" }
        if state.isSLCompatibility { return "NAK" }
        if state.isReady { return "DIAG" }
        return "WAIT"
    }
}

private struct MaxDatum: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(NovaTheme.muted)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfModeBadge: View {
    let active: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24)) { timeline in
            let pulse = active && !reduceMotion
                ? 0.5 + sin(timeline.date.timeIntervalSinceReferenceDate * 2.5) * 0.5
                : 0
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                Text("PROF")
                    .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
                    .tracking(compact ? 0.6 : 0.9)
            }
            .foregroundStyle(NovaTheme.profGradient)
            .opacity(active ? 1 : 0.72)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(Capsule().fill(NovaTheme.prof.opacity(0.08 + pulse * 0.07)))
            .overlay(Capsule().stroke(NovaTheme.prof.opacity(0.24 + pulse * 0.24), lineWidth: 1))
            .shadow(color: NovaTheme.prof.opacity(pulse * 0.18), radius: CGFloat(6 + pulse * 4))
            .scaleEffect(CGFloat(1 + pulse * 0.012))
        }
        .accessibilityLabel("Режим PROF")
        .accessibilityValue(active ? "готов" : "ожидает подключения")
    }
}

private struct ProfModeCard: View {
    let state: NovaBluetoothController.ConnectionState
    let summary: String
    let notificationActive: Bool
    let tokenStored: Bool
    let scooterIdentifier: String?

    var body: some View {
        GlassPanel {
            ZStack(alignment: .topTrailing) {
                ProfTelemetryField(active: state.isReady)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        ProfModeBadge(active: state.isReady)
                        Spacer()
                        Label(tokenStored ? "TOKEN SECURED" : "TOKEN REQUIRED", systemImage: tokenStored ? "key.fill" : "key.slash")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.7)
                            .foregroundStyle(tokenStored ? NovaTheme.green : NovaTheme.amber)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Capsule().fill((tokenStored ? NovaTheme.green : NovaTheme.amber).opacity(0.08)))
                            .overlay(Capsule().stroke((tokenStored ? NovaTheme.green : NovaTheme.amber).opacity(0.22)))
                    }

                    Text("PROF")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-1.7)
                        .foregroundStyle(NovaTheme.profGradient)
                        .padding(.top, 16)

                    Text(summary)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                        .padding(.top, 4)

                    Label(
                        scooterIdentifier ?? "TARGET REQUIRED",
                        systemImage: scooterIdentifier == nil ? "number.square" : "scope"
                    )
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.55)
                    .foregroundStyle(scooterIdentifier == nil ? NovaTheme.amber : NovaTheme.prof)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill((scooterIdentifier == nil ? NovaTheme.amber : NovaTheme.prof).opacity(0.08)))
                    .overlay(Capsule().stroke((scooterIdentifier == nil ? NovaTheme.amber : NovaTheme.prof).opacity(0.22)))
                    .padding(.top, 10)

                    Rectangle()
                        .fill(LinearGradient(colors: [NovaTheme.prof.opacity(0.72), NovaTheme.line, Color.clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                        .padding(.vertical, 14)

                    HStack(spacing: 20) {
                        MaxDatum(label: "SESSION", value: sessionLabel, color: stateColor)
                        MaxDatum(label: "RX PIPE", value: notificationActive ? "ONLINE" : "STANDBY", color: notificationActive ? NovaTheme.green : NovaTheme.muted)
                        MaxDatum(label: "PROFILE", value: "STRICT", color: NovaTheme.prof)
                    }
                }
                .padding(18)
            }
            .background(
                LinearGradient(
                    colors: [NovaTheme.prof.opacity(0.10), Color.clear, NovaTheme.violet.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
        .accessibilityElement(children: .combine)
    }

    private var stateColor: Color {
        if state.isAuthenticated { return NovaTheme.green }
        if state.isSLCompatibility { return NovaTheme.amber }
        return NovaTheme.muted
    }

    private var sessionLabel: String {
        if state.isAuthenticated { return "READY" }
        if state.isSLCompatibility { return "NAK" }
        if state.isReady { return "READY" }
        return "WAIT"
    }
}

private struct ProfTelemetryField: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24)) { timeline in
            let rawPhase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
            let phase = CGFloat(reduceMotion ? 0.35 : rawPhase)

            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    ForEach(0..<3, id: \.self) { index in
                        let diameter = CGFloat(76 + index * 34)
                        Circle()
                            .stroke(NovaTheme.prof.opacity(active ? 0.16 - Double(index) * 0.035 : 0.045), lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(active ? 0.96 + phase * 0.07 : 1)
                            .position(x: proxy.size.width - 24, y: 48)
                    }

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.clear, NovaTheme.prof.opacity(active ? 0.44 : 0.10), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .offset(y: phase * max(0, proxy.size.height - 1))
                }
                .clipped()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color
    var pulsing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let pulse = pulsing ? 0.5 + sin(timeline.date.timeIntervalSinceReferenceDate * 3.2) * 0.5 : 0
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(color.opacity(0.22)).frame(width: 11, height: 11)
                    Circle().fill(color).frame(width: 5, height: 5).shadow(color: color, radius: CGFloat(4 + pulse * 4))
                }
                Text(text).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.6)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [color.opacity(0.15 + pulse * 0.035), color.opacity(0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Capsule().stroke(color.opacity(0.28 + pulse * 0.1)))
            .shadow(color: color.opacity(0.08 + pulse * 0.04), radius: 10)
            .scaleEffect(CGFloat(1 + pulse * 0.012))
        }
    }
}

private struct AnimatedOrbit: View {
    let ready: Bool
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let color = ready ? NovaTheme.green : NovaTheme.rose
            ZStack {
                Circle().fill(color.opacity(0.08)).blur(radius: 12)
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 1)
                Circle()
                    .trim(from: 0.08, to: ready ? 0.82 : 0.42)
                    .stroke(AngularGradient(colors: [.clear, color, .clear], center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(time * (ready ? 82 : 34)))
                Circle().fill(color).frame(width: size * 0.09, height: size * 0.09).shadow(color: color, radius: 9)
            }
            .frame(width: size, height: size)
        }
    }
}

private struct RadarView: View {
    let active: Bool
    var large = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            ZStack {
                Circle().stroke(NovaTheme.line)
                Circle().stroke(NovaTheme.cyan.opacity(active ? 0.5 * (1 - phase) : 0.15), lineWidth: 1).scaleEffect(CGFloat(0.42 + phase * 0.58))
                Circle().fill(NovaTheme.cyan).frame(width: 5, height: 5).shadow(color: NovaTheme.cyan, radius: 8)
                if active {
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [NovaTheme.cyan, .clear], center: .center), lineWidth: 2)
                        .rotationEffect(.degrees(phase * 360))
                }
            }
            .frame(width: large ? 88 : 54, height: large ? 88 : 54)
        }
    }
}

private struct NovaActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            haptic(.light)
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.17), tint.opacity(0.065)], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: tint.opacity(0.08), radius: 12, y: 5)
        }
        .novaPressable()
    }
}

private struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    let accent: Color

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(NovaTheme.muted)
                    Spacer()
                    Circle().fill(accent).frame(width: 5, height: 5).shadow(color: accent, radius: 5)
                }
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(value).font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(unit).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(accent)
                }
                Capsule().fill(LinearGradient(colors: [accent, accent.opacity(0.08)], startPoint: .leading, endPoint: .trailing)).frame(height: 2)
                Text("нет телеметрии").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(NovaTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
        }
    }
}

private struct MiniMetric: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(NovaTheme.muted)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(unit).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NovaTheme.surface.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NovaTheme.line))
    }
}

private struct QuickButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            haptic(.medium)
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.14)).frame(width: 34, height: 34)
                    Circle().stroke(color.opacity(0.22), lineWidth: 1).frame(width: 34, height: 34)
                    Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                }
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(LinearGradient(colors: [color.opacity(0.14), NovaTheme.surface.opacity(0.76)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(LinearGradient(colors: [color.opacity(0.34), NovaTheme.line], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: color.opacity(0.07), radius: 12, y: 6)
        }
        .novaPressable()
    }
}

private struct CommandTile: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            haptic(.medium)
            action()
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(color.opacity(0.12)).frame(width: 38, height: 38)
                    Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                }
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(colors: [color.opacity(0.12), NovaTheme.surface.opacity(0.88), NovaTheme.backgroundDeep.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LinearGradient(colors: [color.opacity(0.4), NovaTheme.line], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: color.opacity(0.07), radius: 12, y: 6)
        }
        .novaPressable()
    }
}

private struct LogRow: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 5, height: 5).shadow(color: color, radius: 4)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NovaTheme.muted)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}
