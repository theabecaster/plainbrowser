#if canImport(UIKit)
import AVFoundation
import BrowserCore
import CoreLocation
import CoreTelephony
import Foundation
import Network
import UIKit

/// What iOS lets Plain use right now: the camera, microphone and location websites ask for,
/// adding to Photos, and cellular data (docs/research/permissions-states.md).
///
/// WebKit itself denies a site's camera, microphone or location request when Plain is off for it
/// in Settings, without asking Plain (its `UserMediaPermissionRequestManagerProxy` and
/// `CoreLocationGeolocationProvider` check the app's authorization first), so the page only sees
/// an error. The pool reads this to know when to listen for such requests
/// (`AccessRequestWatch`), and the shell to say why in one line.
///
/// Read off the main thread after the first frame and each time the app becomes active: a switch
/// can only change in Settings, while Plain is away, or in a system prompt, which also makes the
/// app inactive. Cellular data reports its own changes. Until the first read every feature is
/// `.notDetermined`, which shows nothing.
@MainActor
public final class SystemAccessMonitor {
    public private(set) var access: [SystemFeature: SystemAccess] = [:]
    /// The features whose access changed, after a read.
    public var onChange: (Set<SystemFeature>) -> Void = { _ in }
    private var network = NetworkSnapshot()
    private var started = false
    private var reading: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private let pathMonitor = NWPathMonitor()
    private var cellularData: CTCellularData?
    private let overrides: [SystemFeature: SystemAccess]

    struct NetworkSnapshot: Sendable, Equatable {
        var cellularDenied = false
        var wifiDenied = false
        var hasWiFi = false
    }

    public init() {
        #if DEBUG
        overrides = Self.debugOverrides(ProcessInfo.processInfo.arguments)
        #else
        overrides = [:]
        #endif
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pathMonitor.cancel()
        cellularData?.cellularDataRestrictionDidUpdateNotifier = nil
    }

    /// What iOS allows for `feature`, as last read.
    public func access(_ feature: SystemFeature) -> SystemAccess {
        access[feature] ?? .notDetermined
    }

    /// Why a load failed for want of the network, when it is a switch of Plain's (cellular data
    /// or Wi-Fi off for Plain) rather than the connection itself.
    public var networkBlock: NetworkBlock? {
        if overrides[.cellular]?.isBlocked == true { return .cellularOffForPlain }
        return NetworkBlock.from(
            cellularDenied: network.cellularDenied, wifiDenied: network.wifiDenied,
            cellularRestricted: access(.cellular) == .denied, hasWiFi: network.hasWiFi
        )
    }

    /// Debug's `-PlainSystemAccess cellular=denied`: the error page treats every connection
    /// failure as the network's, as an offline phone with cellular data off for Plain reports it.
    public var simulatesNetworkBlock: Bool { overrides[.cellular]?.isBlocked == true }

    /// Starts following the app becoming active, the network path and cellular data. Call after
    /// the first frame.
    public func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Both handlers run on other queues: @Sendable, so they don't inherit the main actor.
        pathMonitor.pathUpdateHandler = { @Sendable [weak self] path in
            let snapshot = NetworkSnapshot(
                cellularDenied: path.status != .satisfied && path.unsatisfiedReason == .cellularDenied,
                wifiDenied: path.status != .satisfied && path.unsatisfiedReason == .wifiDenied,
                hasWiFi: path.status == .satisfied && path.usesInterfaceType(.wifi)
            )
            Task { @MainActor in self?.network = snapshot }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Plain.SystemAccess.path", qos: .utility))
        let cellular = CTCellularData()
        // Called on a queue of Core Telephony's when cellular data is turned on or off for Plain.
        cellular.cellularDataRestrictionDidUpdateNotifier = { @Sendable [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        cellularData = cellular
        refresh()
    }

    /// A fresh answer the engine read on its own (Save Image reads Photos before it saves).
    func record(_ feature: SystemFeature, _ value: SystemAccess) {
        let value = overrides[feature] ?? value
        guard access(feature) != value else { return }
        access[feature] = value
        onChange([feature])
    }

    /// Reads every feature off the main thread, then reports those that changed.
    public func refresh() {
        reading?.cancel()
        let overrides = overrides
        let cellular = cellularData
        reading = Task { [weak self] in
            let read = await Self.read(cellular: cellular)
            guard let self, !Task.isCancelled else { return }
            let next = read.merging(overrides) { _, override in override }
            let changed = Set(SystemFeature.allCases.filter { (access[$0] ?? .notDetermined) != (next[$0] ?? .notDetermined) })
            access = next
            if !changed.isEmpty { onChange(changed) }
        }
    }

    @concurrent
    nonisolated private static func read(cellular: CTCellularData?) async -> [SystemFeature: SystemAccess] {
        var result: [SystemFeature: SystemAccess] = [:]
        result[.camera] = map(AVCaptureDevice.authorizationStatus(for: .video))
        result[.microphone] = map(AVCaptureDevice.authorizationStatus(for: .audio))
        // Off the main thread: Core Location warns that this can stall the UI.
        if !CLLocationManager.locationServicesEnabled() {
            result[.location] = .servicesOff
        } else {
            result[.location] = map(CLLocationManager().authorizationStatus)
        }
        result[.photos] = WebViewPool.photosAccess()
        switch cellular?.restrictedState {
        case .restricted?: result[.cellular] = .denied
        case .notRestricted?: result[.cellular] = .allowed
        default: result[.cellular] = .notDetermined
        }
        return result
    }

    nonisolated static func map(_ status: AVAuthorizationStatus) -> SystemAccess {
        switch status {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> SystemAccess {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    #if DEBUG
    /// `-PlainSystemAccess camera=denied,location=servicesOff,cellular=denied`: what iOS reports,
    /// for UI tests and captures of states a simulator can't reach (no camera, no cellular).
    /// Debug builds only; it changes nothing outside the run.
    nonisolated static func debugOverrides(_ arguments: [String]) -> [SystemFeature: SystemAccess] {
        guard let index = arguments.firstIndex(of: "-PlainSystemAccess"), arguments.indices.contains(index + 1) else {
            return [:]
        }
        var result: [SystemFeature: SystemAccess] = [:]
        for pair in arguments[index + 1].split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2, let feature = SystemFeature(rawValue: parts[0]),
                  let access = SystemAccess(rawValue: parts[1]) else { continue }
            result[feature] = access
        }
        return result
    }
    #endif
}
#endif
