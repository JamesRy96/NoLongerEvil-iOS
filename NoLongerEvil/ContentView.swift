
// NoLongerEvil iOS App
// Native SwiftUI client for the NoLongerEvil hosted service
//
// API Documentation: https://docs.nolongerevil.com/api-reference/introduction
// Base URL: https://nolongerevil.com/api/v1
// Authentication: Bearer token (Authorization: Bearer nle_xxx)
//
// Xcode Setup:
//   1. New Project: iOS App → SwiftUI lifecycle
//   2. Replace ContentView.swift with this file
//   3. Build & Run on device or simulator

import SwiftUI
import Combine

// MARK: - Settings (persisted to UserDefaults)

class AppSettings: ObservableObject {
    @Published var apiURL: String {
        didSet { UserDefaults.standard.set(apiURL, forKey: "apiURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }

    init() {
        let ud = UserDefaults.standard
        apiURL = ud.string(forKey: "apiURL") ?? "https://nolongerevil.com/api/v1"
        apiKey = ud.string(forKey: "apiKey") ?? ""
    }
}

// MARK: - API Response Models

struct DeviceListResponse: Decodable {
    let devices: [DeviceBasicInfo]
}

struct DeviceBasicInfo: Decodable {
    let id: String          // UUID
    let serial: String
    let name: String?
    let accessType: String?
}

struct ThermostatStatusResponse: Decodable {
    let device: DeviceBasicInfo
    let state: [String: StateObject]
}

struct StateObject: Decodable {
    let value: AnyCodable
}

// Helper for decoding arbitrary JSON
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    subscript(key: String) -> Any? {
        (value as? [String: Any])?[key]
    }
}

// MARK: - Live Thermostat State

class ThermostatState: ObservableObject, Identifiable {
    let deviceId: String    // UUID for API calls
    let serial: String

    @Published var name: String?
    @Published var currentTemperature: Double?
    @Published var targetTemperature: Double?
    @Published var targetTemperatureLow: Double?
    @Published var targetTemperatureHigh: Double?
    @Published var hvacMode: String = "off"
    @Published var fanTimerActive: Bool = false
    @Published var away: Bool = false
    @Published var isAvailable: Bool = true
    @Published var temperatureScale: String = "F"
    @Published var canHeat: Bool = true
    @Published var canCool: Bool = true
    @Published var hasFan: Bool = false
    @Published var hasEmerHeat: Bool = false

    var id: String { deviceId }

    var modeKey: String {
        let m = hvacMode.lowercased()
        return (m == "heat-cool" || m == "range") ? "auto" : m
    }

    init(deviceId: String, serial: String, name: String? = nil) {
        self.deviceId = deviceId
        self.serial = serial
        self.name = name
    }

    func update(from state: [String: Any]) {
        // Parse shared state
        if let shared = state["shared.\(serial)"] as? [String: Any],
           let sharedValue = shared["value"] as? [String: Any] {
            currentTemperature = sharedValue["current_temperature"] as? Double
            targetTemperature = sharedValue["target_temperature"] as? Double
            targetTemperatureLow = sharedValue["target_temperature_low"] as? Double
            targetTemperatureHigh = sharedValue["target_temperature_high"] as? Double
            hvacMode = (sharedValue["target_temperature_type"] as? String) ?? "off"
            canHeat = (sharedValue["can_heat"] as? Bool) ?? true
            canCool = (sharedValue["can_cool"] as? Bool) ?? true
            // Thermostat's friendly name lives in shared state
            if let sharedName = sharedValue["name"] as? String, !sharedName.isEmpty {
                name = sharedName
            }
        }

        // Parse device state
        if let device = state["device.\(serial)"] as? [String: Any],
           let deviceValue = device["value"] as? [String: Any] {
            temperatureScale = (deviceValue["temperature_scale"] as? String) ?? "F"
            hasFan = (deviceValue["has_fan"] as? Bool) ?? false
            hasEmerHeat = (deviceValue["has_emer_heat"] as? Bool) ?? false

            // Fan is active if fan_timer_timeout > 0
            let fanTimeout = deviceValue["fan_timer_timeout"] as? Int ?? 0
            fanTimerActive = fanTimeout > 0
        }

        // Parse structure state (for away + fallback name)
        for (key, val) in state {
            if key.hasPrefix("structure."),
               let structDict = val as? [String: Any],
               let structValue = structDict["value"] as? [String: Any] {
                away = (structValue["away"] as? Bool) ?? false
                // Use structure name as fallback if thermostat has no name
                if name == nil, let structName = structValue["name"] as? String, !structName.isEmpty {
                    name = structName
                }
                break
            }
        }
    }
}

// MARK: - App Store (manages API calls and state)

class AppStore: ObservableObject {
    @Published var devices: [ThermostatState] = []
    @Published var isLoadingDevices = false
    @Published var deviceListError: String?
    @Published var isConnected = false

    let settings: AppSettings
    private var pollTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.refreshAllDevices() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Device Loading

    func loadDevices() async {
        await MainActor.run { isLoadingDevices = true; deviceListError = nil }
        do {
            let data = try await apiGET("/devices")
            let response = try JSONDecoder().decode(DeviceListResponse.self, from: data)

            let newDevices: [ThermostatState] = response.devices.map {
                ThermostatState(deviceId: $0.id, serial: $0.serial, name: $0.name)
            }

            await MainActor.run {
                self.devices = newDevices
                self.isConnected = true
            }

            // Fetch full status for each device
            await refreshAllDevices()

        } catch {
            await MainActor.run {
                self.deviceListError = error.localizedDescription
                self.isConnected = false
            }
        }
        await MainActor.run { isLoadingDevices = false }
    }

    func refreshAllDevices() async {
        for device in devices {
            await refreshDevice(device)
        }
    }

    func refreshDevice(_ device: ThermostatState) async {
        do {
            let data = try await apiGET("/thermostat/\(device.deviceId)/status")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let stateDict = json?["state"] as? [String: Any] {
                let parsedState: [String: Any] = stateDict.compactMapValues { $0 as? [String: Any] }
                await MainActor.run {
                    device.update(from: parsedState)
                    device.isAvailable = true
                }
            }
        } catch {
            await MainActor.run { device.isAvailable = false }
        }
    }

    // MARK: Commands

    func setTemperature(device: ThermostatState, celsius: Double) async {
        let scale = device.temperatureScale
        let value = scale == "F" ? c2f(celsius) : celsius
        let body: [String: Any] = ["value": value, "scale": scale]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await apiPOST("/thermostat/\(device.deviceId)/temperature", body: data)
            await refreshDevice(device)
        } catch { }
    }

    func setTemperatureRange(device: ThermostatState, lowCelsius: Double, highCelsius: Double) async {
        let scale = device.temperatureScale
        let body: [String: Any] = [
            "low": scale == "F" ? c2f(lowCelsius) : lowCelsius,
            "high": scale == "F" ? c2f(highCelsius) : highCelsius,
            "scale": scale
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await apiPOST("/thermostat/\(device.deviceId)/temperature/range", body: data)
            await refreshDevice(device)
        } catch { }
    }

    @discardableResult
    func setMode(device: ThermostatState, mode: String) async -> String? {
        // The NLE server uses "heat-cool" for auto mode (mirrors Nest's target_temperature_type)
        let apiMode = mode == "range" ? "heat-cool" : mode
        let body: [String: Any] = ["mode": apiMode]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await apiPOST("/thermostat/\(device.deviceId)/mode", body: data)
            await refreshDevice(device)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func setFan(device: ThermostatState, on: Bool) async -> String? {
        let body: [String: Any] = ["enabled": on]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await apiPOST("/thermostat/\(device.deviceId)/fan", body: data)
            await refreshDevice(device)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func setAway(device: ThermostatState, away: Bool) async -> String? {
        let body: [String: Any] = ["away": away]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await apiPOST("/thermostat/\(device.deviceId)/away", body: data)
            await refreshDevice(device)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: API Helpers

    private func makeRequest(_ path: String, method: String, body: Data? = nil) throws -> URLRequest {
        let urlStr = settings.apiURL.trimmed + path
        guard let url = URL(string: urlStr) else { throw AppError("Bad URL: \(urlStr)") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    func apiGET(_ path: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(path, method: "GET"))
        try assertOK(resp, data: data)
        return data
    }

    func apiPOST(_ path: String, body: Data) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(path, method: "POST", body: body))
        try assertOK(resp, data: data)
        return data
    }

    func apiDELETE(_ path: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(path, method: "DELETE"))
        try assertOK(resp, data: data)
        return data
    }

    private func assertOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            throw AppError("Unauthorized – check your API key in Settings")
        }
        if http.statusCode == 403 {
            throw AppError("Access denied – this API key may not have permission")
        }
        if http.statusCode >= 400 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                throw AppError(error)
            }
            throw AppError("Request failed (HTTP \(http.statusCode))")
        }
    }
}

struct AppError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Temperature Helpers

func c2f(_ c: Double) -> Double { c * 9 / 5 + 32 }
func f2c(_ f: Double) -> Double { (f - 32) * 5 / 9 }

func displayTemp(_ celsius: Double?, scale: String) -> String {
    guard let c = celsius else { return "--" }
    let val = scale == "F" ? c2f(c) : c
    let r = scale == "F" ? round(val) : (round(val * 2) / 2)
    return r == floor(r) ? "\(Int(r))°" : String(format: "%.1f°", r)
}

// MARK: - Color Palette

extension Color {
    static let nleGreen = Color(red: 0.06, green: 0.73, blue: 0.51)
    static let nleHeat  = Color(red: 0.98, green: 0.45, blue: 0.09)
    static let nleCool  = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let nleAuto  = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let nleEco   = Color(red: 0.09, green: 0.64, blue: 0.27)
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            DeviceListView()
                .navigationTitle("NoLongerEvil")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { statusBadge }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 14) {
                            Button { Task { await store.loadDevices() } } label: {
                                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                            }
                            Button { showSettings = true } label: {
                                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .medium))
                            }
                        }
                    }
                }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            await store.loadDevices()
            store.startPolling()
        }
        .onDisappear { store.stopPolling() }
    }

    var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.isConnected ? Color.nleGreen : Color.red)
                .frame(width: 7, height: 7)
                .shadow(color: store.isConnected ? Color.nleGreen.opacity(0.6) : .clear, radius: 3)
            Text(store.isConnected ? "Connected" : "Offline")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(store.isConnected ? Color.nleGreen : Color.red)
        }
    }
}

// MARK: - Device List

struct DeviceListView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.isLoadingDevices && store.devices.isEmpty {
                    loadingView
                } else if store.devices.isEmpty {
                    emptyState
                } else {
                    ForEach(store.devices) { state in
                        DeviceCard(state: state)
                    }
                }

                if let err = store.deviceListError {
                    errorBanner(err)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
        .refreshable { await store.loadDevices() }
    }

    func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
            Text(msg).font(.caption).foregroundStyle(.red)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading devices…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(48)
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "thermometer.medium").font(.system(size: 52)).foregroundStyle(.quaternary)
            Text("No devices yet").font(.headline).foregroundStyle(.secondary)
            Text("Register your Nest thermostat at nolongerevil.com")
                .font(.subheadline).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(48)
    }
}

// MARK: - Device Card

struct DeviceCard: View {
    @ObservedObject var state: ThermostatState
    @EnvironmentObject var store: AppStore
    @State private var feedback: String?

    var scale: String { state.temperatureScale }
    var mk: String { state.modeKey }

    var glowColor: Color? {
        switch mk {
        case "heat": return .nleHeat
        case "cool": return .nleCool
        case "auto": return .nleAuto
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().padding(.horizontal, 4).opacity(0.5)
            climateRow.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            controlRow.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
            if let fb = feedback {
                Text(fb).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(glowColor?.opacity(0.4) ?? Color.clear, lineWidth: 1.5))
        .shadow(color: (glowColor ?? .black).opacity(0.1), radius: 12, x: 0, y: 4)
    }

    // MARK: Header Row

    var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(state.isAvailable ? Color.nleGreen.opacity(0.2) : .clear)
                    .frame(width: 14, height: 14)
                Circle().fill(state.isAvailable ? Color.nleGreen : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
            }.padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.name ?? state.serial)
                    .font(.system(.body).weight(.semibold))
                Text(state.serial)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }

            Spacer()

            if state.away {
                Label("Away", systemImage: "house.slash.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
    }

    // MARK: Climate Row

    var climateRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(displayTemp(state.currentTemperature, scale: scale))
                    .font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: state.currentTemperature)
                Text("°\(scale)").font(.system(size: 18, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.bottom, 10)
            }
            Spacer()
            targetSection
        }
    }

    @ViewBuilder
    var targetSection: some View {
        if mk == "off" || mk == "emergency" {
            VStack(spacing: 4) {
                Image(systemName: mk == "emergency" ? "exclamationmark.triangle.fill" : "powersleep")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                Text(mk == "off" ? "Off" : "Emergency Heat")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        } else if mk == "auto" {
            rangeControls
        } else {
            singleTargetControls
        }
    }

    var singleTargetControls: some View {
        HStack(spacing: 16) {
            CircleBtn(symbol: "minus") { adjustSingle(delta: -1) }
            VStack(spacing: 2) {
                Text("Target").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .textCase(.uppercase).tracking(0.5)
                Text(displayTemp(state.targetTemperature, scale: scale))
                    .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: state.targetTemperature)
                RoundedRectangle(cornerRadius: 2).fill(modeAccentColor)
                    .frame(width: 28, height: 3)
            }
            CircleBtn(symbol: "plus") { adjustSingle(delta: 1) }
        }
    }

    var rangeControls: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Text("Low").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .textCase(.uppercase).tracking(0.5)
                HStack(spacing: 5) {
                    SmallCircleBtn(symbol: "minus") { adjustRange(field: "low", delta: -1) }
                    Text(displayTemp(state.targetTemperatureLow, scale: scale))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: state.targetTemperatureLow)
                    SmallCircleBtn(symbol: "plus") { adjustRange(field: "low", delta: 1) }
                }
            }
            Text("–").foregroundStyle(.tertiary).font(.callout)
            VStack(spacing: 2) {
                Text("High").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .textCase(.uppercase).tracking(0.5)
                HStack(spacing: 5) {
                    SmallCircleBtn(symbol: "minus") { adjustRange(field: "high", delta: -1) }
                    Text(displayTemp(state.targetTemperatureHigh, scale: scale))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: state.targetTemperatureHigh)
                    SmallCircleBtn(symbol: "plus") { adjustRange(field: "high", delta: 1) }
                }
            }
        }
    }

    var modeAccentColor: Color {
        switch mk {
        case "heat": return .nleHeat
        case "cool": return .nleCool
        case "auto": return .nleAuto
        default: return .clear
        }
    }

    // MARK: Control Row

    var controlRow: some View {
        VStack(spacing: 10) {
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                modeSegment
                Spacer(minLength: 4)
                if state.hasFan { fanToggle }
                ecoToggle
            }
        }
    }

    var modeSegment: some View {
        let modes = buildModes()
        return HStack(spacing: 2) {
            ForEach(modes, id: \.label) { m in
                Button {
                    Task {
                        if let err = await store.setMode(device: state, mode: m.nestMode) {
                            showFeedback("✗ \(err)")
                        } else {
                            showFeedback("→ \(m.label)")
                        }
                    }
                } label: {
                    Text(m.label).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(
                            isActive(m.nestMode) ? m.color.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(isActive(m.nestMode) ? m.color : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    var ecoToggle: some View {
        Button {
            Task {
                if let err = await store.setAway(device: state, away: !state.away) {
                    showFeedback("✗ \(err)")
                } else {
                    showFeedback(state.away ? "Eco off" : "Eco on")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "leaf.fill").font(.system(size: 10))
                Text("Eco").font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                state.away ? Color.nleEco.opacity(0.15) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .foregroundStyle(state.away ? Color.nleEco : Color.secondary)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(state.away ? Color.nleEco.opacity(0.4) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    var fanToggle: some View {
        HStack(spacing: 2) {
            ForEach([("Auto", false), ("On", true)], id: \.0) { label, isOn in
                Button {
                    Task {
                        if let err = await store.setFan(device: state, on: isOn) {
                            showFeedback("✗ \(err)")
                        } else {
                            showFeedback("Fan \(label)")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isOn { Image(systemName: "fan.fill").font(.system(size: 9)) }
                        Text(label).font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(
                        state.fanTimerActive == isOn ? Color.nleGreen.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(state.fanTimerActive == isOn ? Color.nleGreen : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Helpers

    struct ModeOption { let label: String; let nestMode: String; let color: Color }

    func buildModes() -> [ModeOption] {
        var modes: [ModeOption] = []
        if state.canHeat { modes.append(.init(label: "Heat", nestMode: "heat", color: .nleHeat)) }
        if state.canCool { modes.append(.init(label: "Cool", nestMode: "cool", color: .nleCool)) }
        if state.canHeat && state.canCool {
            modes.append(.init(label: "Auto", nestMode: "range", color: .nleAuto))
        }
        if state.hasEmerHeat { modes.append(.init(label: "Emer", nestMode: "emergency", color: .red)) }
        modes.append(.init(label: "Off", nestMode: "off", color: .secondary))
        return modes
    }

    func isActive(_ nestMode: String) -> Bool {
        let curr = state.hvacMode.lowercased()
        let n = nestMode.lowercased()
        if n == "range" { return curr == "range" || curr == "heat-cool" }
        return curr == n
    }

    func adjustSingle(delta: Int) {
        let step: Double = scale == "F" ? 1.0 : 0.5
        let base = state.targetTemperature ?? 20
        let display = scale == "F" ? round(c2f(base)) : (round(base * 2) / 2)
        let newDisplay = display + Double(delta) * step
        let newC = scale == "F" ? f2c(newDisplay) : newDisplay
        state.targetTemperature = newC  // optimistic update
        Task { await store.setTemperature(device: state, celsius: newC) }
    }

    func adjustRange(field: String, delta: Int) {
        let step: Double = scale == "F" ? 1.0 : 0.5
        func bump(_ val: Double?) -> Double {
            let base = val ?? 20
            let disp = scale == "F" ? round(c2f(base)) : (round(base * 2) / 2)
            return scale == "F" ? f2c(disp + Double(delta) * step) : disp + Double(delta) * step
        }
        let low = field == "low" ? bump(state.targetTemperatureLow) : (state.targetTemperatureLow ?? 18)
        let high = field == "high" ? bump(state.targetTemperatureHigh) : (state.targetTemperatureHigh ?? 22)
        if field == "low" { state.targetTemperatureLow = low } else { state.targetTemperatureHigh = high }
        Task { await store.setTemperatureRange(device: state, lowCelsius: low, highCelsius: high) }
    }

    func showFeedback(_ msg: String) {
        feedback = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { feedback = nil }
    }
}

// MARK: - Reusable Button Components

struct CircleBtn: View {
    let symbol: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: Circle())
        }.buttonStyle(.plain)
    }
}

struct SmallCircleBtn: View {
    let symbol: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color(.secondarySystemBackground), in: Circle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var apiURL = ""
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledRow("API URL") {
                        TextField("https://nolongerevil.com/api/v1", text: $apiURL)
                            .keyboardType(.URL).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    }
                    LabeledRow("API Key") {
                        SecureField("nle_xxx...", text: $apiKey)
                            .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("NoLongerEvil API")
                } footer: {
                    Text("Get your API key at nolongerevil.com/settings")
                }

                Section {
                    HStack {
                        Circle()
                            .fill(store.isConnected ? Color.nleGreen : Color.red)
                            .frame(width: 8, height: 8)
                        Text(store.isConnected ? "Connected" : "Disconnected")
                            .font(.subheadline)
                            .foregroundStyle(store.isConnected ? Color.nleGreen : Color.red)
                    }

                    Button { Task { await testConnection() } } label: {
                        HStack {
                            if testing { ProgressView().padding(.trailing, 4) }
                            Text("Test Connection")
                        }
                    }.disabled(testing)

                    if let r = testResult {
                        Text(r).font(.caption)
                            .foregroundStyle(r.hasPrefix("✓") ? Color.nleGreen : .red)
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    Link(destination: URL(string: "https://nolongerevil.com")!) {
                        Label("Open nolongerevil.com", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://docs.nolongerevil.com/api-reference/introduction")!) {
                        Label("API Documentation", systemImage: "book")
                    }
                } header: {
                    Text("Links")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { save() }.bold() }
            }
            .onAppear { loadDrafts() }
        }
    }

    func loadDrafts() {
        apiURL = settings.apiURL
        apiKey = settings.apiKey
    }

    func save() {
        settings.apiURL = apiURL.trimmed.isEmpty ? "https://nolongerevil.com/api/v1" : apiURL.trimmed
        settings.apiKey = apiKey.trimmed
        dismiss()
        Task { await store.loadDevices() }
    }

    func testConnection() async {
        testResult = nil; testing = true
        let savedURL = settings.apiURL, savedKey = settings.apiKey
        settings.apiURL = apiURL; settings.apiKey = apiKey
        do {
            let data = try await store.apiGET("/devices")
            let response = try JSONDecoder().decode(DeviceListResponse.self, from: data)
            testResult = "✓ Connected — found \(response.devices.count) device(s)"
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
        settings.apiURL = savedURL; settings.apiKey = savedKey
        testing = false
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).font(.subheadline)
            content
        }
    }
}
