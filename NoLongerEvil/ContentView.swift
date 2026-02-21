
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
    @Published var currentHumidity: Double?
    @Published var outsideTemperature: Double?
    @Published var postalCode: String?
    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var outsideTempUpdatedAt: Date?
    @Published var geocodeUpdatedAt: Date?
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
            if let h = sharedValue["current_humidity"] as? Double {
                currentHumidity = h
            } else if let h = sharedValue["current_humidity"] as? Int {
                currentHumidity = Double(h)
            }
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
            if let h = deviceValue["current_humidity"] as? Double {
                currentHumidity = h
            } else if let h = deviceValue["current_humidity"] as? Int {
                currentHumidity = Double(h)
            }
            if let pc = deviceValue["postal_code"] as? String { postalCode = pc }
            if let loc = deviceValue["location"] as? [String: Any] {
                latitude = loc["latitude"] as? Double ?? latitude
                longitude = loc["longitude"] as? Double ?? longitude
            }

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
                if let pc = structValue["postal_code"] as? String { postalCode = pc }
                if let loc = structValue["location"] as? [String: Any] {
                    latitude = loc["latitude"] as? Double ?? latitude
                    longitude = loc["longitude"] as? Double ?? longitude
                }
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
    private let weatherUserAgent = "NoLongerEvil/1.0 (nolongerevil.com)"

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
                await refreshOutsideTempIfNeeded(for: device)
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

    // MARK: Outside Weather (NWS)

    func refreshOutsideTempIfNeeded(for device: ThermostatState) async {
        if (device.latitude == nil || device.longitude == nil),
           let zip = device.postalCode {
            await resolveZipIfNeeded(device: device, postalCode: zip)
        }
        guard let lat = device.latitude, let lon = device.longitude else { return }
        let now = Date()
        if let last = device.outsideTempUpdatedAt, now.timeIntervalSince(last) < 900 {
            return
        }
        do {
            if let temp = try await OpenMeteoService.fetchOutsideTemp(
                lat: lat,
                lon: lon,
                scale: device.temperatureScale
            ) {
                await MainActor.run {
                    device.outsideTemperature = temp
                    device.outsideTempUpdatedAt = Date()
                }
            }
        } catch {
            // Ignore transient weather errors; keep last known value
        }
    }

    func resolveZipIfNeeded(device: ThermostatState, postalCode: String) async {
        let now = Date()
        if let last = device.geocodeUpdatedAt, now.timeIntervalSince(last) < 86_400 {
            return
        }
        let cleaned = postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let coord = try await ZippopotamService.lookupPostalCode(cleaned, userAgent: weatherUserAgent) {
                await MainActor.run {
                    device.latitude = coord.lat
                    device.longitude = coord.lon
                    device.geocodeUpdatedAt = Date()
                }
            }
        } catch {
            await MainActor.run { device.geocodeUpdatedAt = Date() }
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

// MARK: - NWS Weather

enum ZippopotamService {
    struct Response: Decodable {
        struct Place: Decodable {
            let latitude: String
            let longitude: String
        }
        let places: [Place]
    }

    static func lookupPostalCode(_ postalCode: String, userAgent: String) async throws -> (lat: Double, lon: Double)? {
        let zip = postalCode.split(separator: " ").first.map(String.init) ?? postalCode
        guard !zip.isEmpty else { return nil }
        let url = URL(string: "https://api.zippopotam.us/us/\(zip)")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw AppError("ZIP lookup failed (HTTP \(http.statusCode))")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let first = decoded.places.first,
              let lat = Double(first.latitude),
              let lon = Double(first.longitude) else { return nil }
        return (lat: lat, lon: lon)
    }
}

enum OpenMeteoService {
    struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
        }
        struct Units: Decodable {
            let temperature_2m: String?
        }
        let current: Current?
        let current_units: Units?
    }

    static func fetchOutsideTemp(lat: Double, lon: Double, scale: String) async throws -> Double? {
        let unit = scale.uppercased() == "F" ? "fahrenheit" : "celsius"
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m"),
            URLQueryItem(name: "temperature_unit", value: unit)
        ]
        guard let url = comps.url else { return nil }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw AppError("Weather request failed (HTTP \(http.statusCode))")
        }
        let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
        guard let temp = decoded.current?.temperature_2m else { return nil }
        return temp
    }
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
                        NavigationLink {
                            DeviceDetailView(state: state)
                        } label: {
                            DeviceSummaryCard(state: state)
                        }
                        .buttonStyle(.plain)
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

// MARK: - Device Summary Card

struct DeviceSummaryCard: View {
    @ObservedObject var state: ThermostatState

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
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(glowColor?.opacity(0.18) ?? Color(.secondarySystemBackground))
                    .frame(width: 62, height: 62)
                Text(displayTemp(state.currentTemperature, scale: scale))
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(state.name ?? state.serial)
                    .font(.system(.headline, design: .rounded)).lineLimit(1)
                Text(state.serial)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    Text(modeLabel).font(.caption.weight(.semibold))
                        .foregroundStyle(glowColor ?? .secondary)
                    if state.away {
                        Text("Away").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(glowColor?.opacity(0.35) ?? Color.clear, lineWidth: 1.2))
        .shadow(color: (glowColor ?? .black).opacity(0.08), radius: 10, x: 0, y: 4)
    }

    var modeAccentColor: Color {
        switch mk {
        case "heat": return .nleHeat
        case "cool": return .nleCool
        case "auto": return .nleAuto
        default: return .clear
        }
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
    var modeLabel: String {
        switch mk {
        case "heat": return "Heat"
        case "cool": return "Cool"
        case "auto": return "Auto"
        case "emergency": return "Emer"
        default: return "Off"
        }
    }
}

// MARK: - Device Detail (Nest-style)

struct DeviceDetailView: View {
    @ObservedObject var state: ThermostatState
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var feedback: String?
    @State private var showModePicker = false
    @State private var showFanPicker = false

    var scale: String { state.temperatureScale }
    var mk: String { state.modeKey }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                ThermostatDial(
                    state: state,
                    scale: scale,
                    modeColor: modeAccentColor,
                    backgroundColor: modeBackground
                )
                    .padding(.top, 8)

                if mk == "auto" {
                    rangeControls
                } else if mk == "off" || mk == "emergency" {
                    offState
                } else {
                    singleTargetControls
                }

                infoRows

                bottomControls

                if let fb = feedback {
                    Text(fb).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(modeBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showModePicker) {
            ModePickerSheet(
                title: "Mode",
                options: buildModes(),
                isActive: isActive(_:),
                onSelect: { mode in
                    Task {
                        if let err = await store.setMode(device: state, mode: mode) {
                            showFeedback("✗ \(err)")
                        } else {
                            showFeedback("→ \(mode)")
                        }
                    }
                }
            )
            .presentationDetents([.height(150)])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showFanPicker) {
            FanPickerSheet(
                isOn: state.fanTimerActive,
                onSelect: { isOn in
                    Task {
                        if let err = await store.setFan(device: state, on: isOn) {
                            showFeedback("✗ \(err)")
                        } else {
                            showFeedback("Fan \(isOn ? "On" : "Auto")")
                        }
                    }
                }
            )
            .presentationDetents([.height(140)])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    var header: some View {
        VStack(spacing: 6) {
            Text(state.name ?? state.serial)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
            Text(state.serial)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            if state.away {
                Text("Away / Eco")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
        }
    }

    var singleTargetControls: some View {
        HStack(spacing: 18) {
            CircleBtn(symbol: "minus") { adjustSingle(delta: -1) }
            VStack(spacing: 2) {
                Text("Target").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    .textCase(.uppercase).tracking(0.6)
                RoundedRectangle(cornerRadius: 2).fill(modeAccentColor)
                    .frame(width: 30, height: 3)
            }
            CircleBtn(symbol: "plus") { adjustSingle(delta: 1) }
        }
    }

    var rangeControls: some View {
        HStack(spacing: 16) {
            rangeColumn(title: "Low", value: state.targetTemperatureLow, field: "low")
            Text("–").foregroundStyle(.tertiary).font(.callout)
            rangeColumn(title: "High", value: state.targetTemperatureHigh, field: "high")
        }
    }

    func rangeColumn(title: String, value: Double?, field: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                .textCase(.uppercase).tracking(0.6)
            HStack(spacing: 6) {
                SmallCircleBtn(symbol: "minus") { adjustRange(field: field, delta: -1) }
                Text(displayTemp(value, scale: scale))
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: value)
                SmallCircleBtn(symbol: "plus") { adjustRange(field: field, delta: 1) }
            }
        }
    }

    var offState: some View {
        VStack(spacing: 6) {
            Image(systemName: mk == "emergency" ? "exclamationmark.triangle.fill" : "powersleep")
                .font(.system(size: 26)).foregroundStyle(.secondary)
            Text(mk == "off" ? "Off" : "Emergency Heat")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    var infoRows: some View {
        VStack(spacing: 10) {
            InfoRow(label: "Inside Humidity", value: humidityDisplay)
            InfoRow(label: "Outside Temp.", value: outsideTempDisplay)
        }
    }

    var bottomControls: some View {
        VStack(spacing: 10) {
            Divider().opacity(0.25)
            HStack(spacing: 28) {
                ControlIconButton(
                    symbol: "dial.medium",
                    label: "Mode",
                    isActive: true
                ) { showModePicker = true }

                ControlIconButton(
                    symbol: "leaf.fill",
                    label: "Eco",
                    isActive: state.away
                ) {
                    Task {
                        if let err = await store.setAway(device: state, away: !state.away) {
                            showFeedback("✗ \(err)")
                        } else {
                            showFeedback(state.away ? "Eco off" : "Eco on")
                        }
                    }
                }

                if state.hasFan {
                    ControlIconButton(
                        symbol: "fan.fill",
                        label: "Fan",
                        isActive: state.fanTimerActive
                    ) { showFanPicker = true }
                }
            }
            .padding(.vertical, 8)
        }
    }

    var humidityDisplay: String {
        guard let h = state.currentHumidity else { return "--" }
        return "\(Int(round(h)))%"
    }

    var outsideTempDisplay: String {
        guard let t = state.outsideTemperature else { return "--" }
        let r = round(t)
        return "\(Int(r))°"
    }

    var modeAccentColor: Color {
        switch mk {
        case "heat": return .nleHeat
        case "cool": return .nleCool
        case "auto": return .nleAuto
        default: return .white.opacity(0.7)
        }
    }

    var modeBackground: Color {
        switch mk {
        case "heat": return Color(red: 0.94, green: 0.42, blue: 0.14)
        case "cool": return Color(red: 0.12, green: 0.53, blue: 0.98)
        case "auto": return Color(red: 0.33, green: 0.25, blue: 0.95)
        case "emergency": return Color(red: 0.62, green: 0.10, blue: 0.14)
        default: return Color(red: 0.14, green: 0.16, blue: 0.20)
        }
    }

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
        state.targetTemperature = newC
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

struct ThermostatDial: View {
    @ObservedObject var state: ThermostatState
    let scale: String
    let modeColor: Color
    let backgroundColor: Color

    var mk: String { state.modeKey }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, 300)
            let radius = size * 0.48
            let arcRadius = radius - 8
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: size, height: size)
                    .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 12)

                DialTicks(radius: radius, color: Color.white.opacity(0.35), tickCount: 240)

                Circle()
                    .stroke(backgroundColor.opacity(0.45), lineWidth: 10)
                    .frame(width: size * 0.92, height: size * 0.92)

                DialArc(start: arcStartAngle, end: arcEndAngle)
                    .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .frame(width: arcRadius * 2, height: arcRadius * 2)

                DialMarker(
                    radius: arcRadius,
                    angle: angleForSetpoint,
                    color: Color.white
                )

                DialMarker(
                    radius: arcRadius,
                    angle: angleForCurrent,
                    color: Color.white.opacity(0.7),
                    length: 12
                )

                currentTempLabel(size: size, radius: arcRadius * 0.98)

                VStack(spacing: 6) {
                    Text(centerDisplay)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                    Text("°\(scale)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))

                    Text(statusLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 300)
    }

    var statusLine: String {
        if mk == "auto" {
            let low = displayTemp(state.targetTemperatureLow, scale: scale)
            let high = displayTemp(state.targetTemperatureHigh, scale: scale)
            return "Auto"
        }
        if mk == "off" { return "Off" }
        if mk == "emergency" { return "Emergency Heat" }
        return modeLabel
    }

    var modeLabel: String {
        switch mk {
        case "heat": return "Heat"
        case "cool": return "Cool"
        case "auto": return "Auto"
        default: return "Off"
        }
    }

    var centerDisplay: String {
        if mk == "auto" {
            let low = displayTemp(state.targetTemperatureLow, scale: scale)
            let high = displayTemp(state.targetTemperatureHigh, scale: scale)
            return "\(low)–\(high)"
        }
        return displayTemp(state.targetTemperature, scale: scale)
    }

    var angleForSetpoint: Angle {
        let temp = setpointValue
        return angle(for: temp)
    }

    var angleForCurrent: Angle {
        angle(for: state.currentTemperature)
    }

    var setpointValue: Double? {
        if mk == "auto" {
            if let low = state.targetTemperatureLow, let high = state.targetTemperatureHigh {
                return (low + high) / 2
            }
            return state.targetTemperatureLow ?? state.targetTemperatureHigh
        }
        return state.targetTemperature
    }

    func angle(for celsius: Double?) -> Angle {
        guard let c = celsius else { return .degrees(-120) }
        let f = scale == "F" ? c2f(c) : c
        let range = tempRange
        let t = min(max(f, range.min), range.max)
        let pct = (t - range.min) / (range.max - range.min)
        return .degrees(-120 + pct * 240)
    }

    var tempRange: (min: Double, max: Double) {
        if scale == "F" { return (min: 50, max: 90) }
        return (min: 10, max: 32)
    }

    var arcStartAngle: Angle {
        let a = angleForSetpoint.degrees
        let b = angleForCurrent.degrees
        return .degrees(min(a, b))
    }

    var arcEndAngle: Angle {
        let a = angleForSetpoint.degrees
        let b = angleForCurrent.degrees
        return .degrees(max(a, b))
    }

    func currentTempLabel(size: CGFloat, radius: CGFloat) -> some View {
        let angle = angleForCurrent
        let angleRad = angle.degrees * .pi / 180
        let center = CGPoint(x: size / 2, y: size / 2)
        let px = center.x + radius * sin(angleRad)
        let py = center.y - radius * cos(angleRad)
        let tx = cos(angleRad)
        let ty = sin(angleRad)
        let offset: CGFloat = 16
        let labelPoint = CGPoint(x: px + tx * offset, y: py + ty * offset)

        return Text(displayTemp(state.currentTemperature, scale: scale))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .position(labelPoint)
    }
}

struct DialTicks: View {
    let radius: CGFloat
    let color: Color
    var tickCount: Int = 180

    var body: some View {
        let step = 240.0 / Double(max(1, tickCount - 1))
        ZStack {
            ForEach(0..<tickCount, id: \.self) { i in
                Rectangle()
                    .fill(color.opacity(0.45))
                    .frame(width: 2, height: 8)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(i) * step - 120))
            }
        }
    }
}

struct DialMarker: View {
    let radius: CGFloat
    let angle: Angle
    let color: Color
    var length: CGFloat = 18

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 3, height: length)
            .offset(y: -radius)
            .rotationEffect(angle)
    }
}

struct DialArc: Shape {
    let start: Angle
    let end: Angle

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var p = Path()
        p.addArc(
            center: center,
            radius: radius,
            startAngle: start - .degrees(90),
            endAngle: end - .degrees(90),
            clockwise: false
        )
        return p
    }
}

struct ControlIconButton: View {
    let symbol: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isActive ? .white : .white.opacity(0.75))
            .frame(width: 70, height: 54)
            .background(
                isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ModePickerSheet: View {
    let title: String
    let options: [DeviceDetailView.ModeOption]
    let isActive: (String) -> Bool
    let onSelect: (String) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            HStack(spacing: 10) {
                ForEach(options, id: \.label) { m in
                    Button {
                        onSelect(m.nestMode)
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: iconName(for: m.nestMode))
                                .font(.system(size: 16, weight: .semibold))
                            Text(m.label)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .frame(width: 64, height: 60)
                        .background(
                            isActive(m.nestMode) ? Color.white.opacity(0.22) : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func iconName(for mode: String) -> String {
        switch mode {
        case "heat": return "flame.fill"
        case "cool": return "snowflake"
        case "range": return "dial.medium"
        case "emergency": return "exclamationmark.triangle.fill"
        default: return "powersleep"
        }
    }
}

struct FanPickerSheet: View {
    let isOn: Bool
    let onSelect: (Bool) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Fan").font(.headline)
            HStack(spacing: 10) {
                Button {
                    onSelect(false)
                    dismiss()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "fan")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Auto")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(width: 64, height: 60)
                    .background(
                        !isOn ? Color.white.opacity(0.22) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button {
                    onSelect(true)
                    dismiss()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "fan.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("On")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(width: 64, height: 60)
                    .background(
                        isOn ? Color.white.opacity(0.22) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
