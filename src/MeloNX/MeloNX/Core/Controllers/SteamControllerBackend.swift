//
//  SteamControllerBackend.swift
//  MeloNX
//
//  Created by Stossy11 on 02/10/2026.
//

import CoreBluetooth
import UIKit

nonisolated final class SteamControllerBackend: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    @MainActor static let shared = SteamControllerBackend()
    
    @MainActor private(set) var controllers: [SteamController] = []
    
    private let queue = DispatchQueue(label: "com.stossy11.melonx.steam-ble", qos: .userInteractive)
    
    private var central: CBCentralManager?
    private var sessions: [UUID: SteamBLESession] = [:]
    private var retryAfter: [UUID: TimeInterval] = [:]
    private var scanWork: DispatchWorkItem?
    private var foreground = true
    
    @MainActor private var started = false
    @MainActor private var observers: [NSObjectProtocol] = []
    
    private let knownKey = "steamControllerBLEIdentifiers"
    private static let service = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")
    
    @MainActor func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        guard !started else { return }
        
        started = true
        
        let active = UIApplication.shared.applicationState != .background
        
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.queue.async { [weak self] in self?.suspend() } })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.foreground = true
                self.beginScan()
            }
        })
        
        
        queue.async {
            self.foreground = active
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }
    
    private func beginScan() {
        guard foreground, let central, central.state == .poweredOn else { return }
        scanWork?.cancel()
        
        let known = (UserDefaults.standard.stringArray(forKey: knownKey) ?? []).compactMap(UUID.init(uuidString:))
        for peripheral in central.retrievePeripherals(withIdentifiers: known) { connect(peripheral) }
        
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
            connect(peripheral)
        }
        
        for peripheral in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180A")]) {
            if peripheral.name?.lowercased().hasPrefix("steam") == true { connect(peripheral) }
        }
        
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let stop = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.central?.stopScan()
            let restart = DispatchWorkItem { [weak self] in self?.beginScan() }
            self.scanWork = restart
            self.queue.asyncAfter(deadline: .now() + 15, execute: restart)
        }
        
        scanWork = stop
        queue.asyncAfter(deadline: .now() + 15, execute: stop)
    }
    
    private func suspend() {
        foreground = false
        scanWork?.cancel()
        central?.stopScan()
        for session in Array(sessions.values) {
            removeController(session)
            session.shutdown { [weak self, weak session] in
                guard let self, let session else { return }
                self.central?.cancelPeripheralConnection(session.peripheral)
            }
        }
    }
    
    private func connect(_ peripheral: CBPeripheral) {
        guard foreground, sessions[peripheral.identifier] == nil, sessions.count < 8,
              (retryAfter[peripheral.identifier] ?? 0) <= ProcessInfo.processInfo.systemUptime else { return }
        
        let session = SteamBLESession(peripheral: peripheral, queue: queue)
        
        sessions[peripheral.identifier] = session
        
        session.onReady = { [weak self, weak session] in
            guard let self, let session, self.foreground,
                  self.sessions[peripheral.identifier] === session else { return }
            
            var known = UserDefaults.standard.stringArray(forKey: self.knownKey) ?? []
            
            if !known.contains(peripheral.identifier.uuidString) {
                known.append(peripheral.identifier.uuidString)
                UserDefaults.standard.set(Array(known.suffix(8)), forKey: self.knownKey)
            }
            
            let identifier = peripheral.identifier
            
            DispatchQueue.main.async { [session] in
                let controller = SteamController(peripheralID: identifier,
                                                 setMotionEnabled: { [weak session] enabled in
                    self.queue.async { [weak session] in session?.setMotion(enabled) }
                }, sendRumble: { [weak session] data in
                    self.queue.async { [weak session] in session?.rumble(data) }
                })
                
                self.controllers.append(controller)
                
                ControllerManager.shared.refreshControllersList()
                
                self.queue.async {
                    guard self.sessions[identifier] === session, !session.stopping else { return }
                    session.controller = controller
                    session.deliverLatestState()
                }
            }
        }
        session.onFailure = { [weak self, weak session] reason in
            guard let self, let session, self.sessions[peripheral.identifier] === session else { return }
            NSLog("Steam Controller BLE: %@", reason)
            session.invalidate()
            self.removeController(session)
            
            self.retryAfter[peripheral.identifier] = ProcessInfo.processInfo.systemUptime + 15
            self.central?.cancelPeripheralConnection(peripheral)
        }
        central?.connect(peripheral)
        session.armConnectionTimeout()
    }
    
    private func removeController(_ session: SteamBLESession) {
        session.controller = nil
        let identifier = session.peripheral.identifier
        
        DispatchQueue.main.async {
            let removed = self.controllers.filter { $0.peripheralID == identifier }
            guard !removed.isEmpty else { return }
            
            self.controllers.removeAll { $0.peripheralID == identifier }
            
            for controller in removed { controller.cleanup() }
            
            ControllerManager.shared.refreshControllersList()
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("Steam Controller BLE: central state %ld.", central.state.rawValue)
        if central.state == .poweredOn {
            beginScan()
        } else {
            scanWork?.cancel()
            
            for session in sessions.values {
                session.invalidate()
                removeController(session)
            }
            
            sessions.removeAll()
            retryAfter.removeAll()
            if central.state == .unauthorized {
                NSLog("Steam Controller BLE: Bluetooth permission is unavailable.")
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let names = [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name].compactMap { $0 }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        
        guard names.contains(where: { $0.lowercased().hasPrefix("steam") }) || services.contains(Self.service) else { return }
        
        
        connect(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard foreground, let session = sessions[peripheral.identifier], !session.stopping else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        NSLog("Steam Controller BLE: connected; discovering Valve service.")
        peripheral.discoverServices([Self.service])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("Steam Controller BLE: connection failed: %@", error?.localizedDescription ?? "unknown error")
        disconnected(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        NSLog("Steam Controller BLE: disconnected: %@", error?.localizedDescription ?? "connection closed")
        disconnected(peripheral)
    }
    
    private func disconnected(_ peripheral: CBPeripheral) {
        guard let session = sessions.removeValue(forKey: peripheral.identifier) else { return }
        session.invalidate()
        removeController(session)
        retryAfter[peripheral.identifier] = ProcessInfo.processInfo.systemUptime + 5
    }
}

private nonisolated final class SteamBLESession: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let peripheral: CBPeripheral
    let queue: DispatchQueue
    weak var controller: SteamController?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var latestState: SteamControllerState?
    private(set) var stopping = false
    private var decoder = SteamControllerDecoder()
    
    private var reportID: UInt8 = 0
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private var rumbleOutput: CBCharacteristic?
    private var configuring = false
    private var configured = false
    private var motionEnabled = true
    private var loggedInput = false
    private var loggedRumbleError = false
    private var timeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?
    private var closeCompletion: (() -> Void)?
    private var outputTimer: DispatchSourceTimer?
    private var nextLizardUpdate: TimeInterval = 0
    private var rumbleUntil: TimeInterval = 0
    private var rumblePayload: Data?
    
    private enum Purpose { case lizard, motion, rumble }
    private struct Write {
        let characteristic: CBCharacteristic
        let data: Data
        let purpose: Purpose
    }
    private var writes: [Write] = []
    private var inFlight: Write?
    
    private static let serviceUUID = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")
    private static let input45 = CBUUID(string: "100F6C7A-1735-4313-B402-38567131E5F3")
    private static let input47 = CBUUID(string: "100F6C7C-1735-4313-B402-38567131E5F3")
    private static let outputUUID = CBUUID(string: "100F6C34-1735-4313-B402-38567131E5F3")
    
    // Valve maps output report IDs to characteristic suffix 0x35 + report ID.
    private static let rumbleUUID = CBUUID(string: "100F6CB5-1735-4313-B402-38567131E5F3")
    
    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.queue = queue
        super.init()
        peripheral.delegate = self
    }
    
    func armConnectionTimeout() {
        let work = DispatchWorkItem { [weak self] in self?.fail("Connection or pairing timed out.") }
        timeout = work
        queue.asyncAfter(deadline: .now() + 60, execute: work)
    }
    
    func invalidate() {
        stopping = true
        timeout?.cancel()
        writeTimeout?.cancel()
        
        outputTimer?.cancel()
        outputTimer = nil
        
        writes.removeAll()
        
        inFlight = nil
        controller = nil
        peripheral.delegate = nil
        closeCompletion = nil
    }
    
    func shutdown(_ completion: @escaping () -> Void) {
        guard !stopping else { completion(); return }
        
        stopping = true
        timeout?.cancel()
        
        outputTimer?.cancel()
        outputTimer = nil
        
        writes.removeAll()
        
        if configured, let output {
            if let rumbleOutput {
                writes.append(Write(characteristic: rumbleOutput, data: SteamControllerProtocol.rumble(left: 0, right: 0), purpose: .rumble))
            }
            
            writes.append(Write(characteristic: output, data: SteamControllerProtocol.setting(48, value: 0), purpose: .motion))
            
            writes.append(Write(characteristic: output, data: SteamControllerProtocol.setting(9, value: 1), purpose: .lizard))
        }
        
        closeCompletion = completion
        let work = DispatchWorkItem { [weak self] in self?.finishClosing() }
        
        timeout = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
        writeNext()
    }
    
    private func finishClosing() {
        guard let completion = closeCompletion else { return }
        closeCompletion = nil
        timeout?.cancel()
        writeTimeout?.cancel()
        completion()
    }
    
    private func fail(_ message: String) {
        if stopping { finishClosing() } else { onFailure?(message) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopping else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail("Valve service discovery failed: \(error?.localizedDescription ?? "service missing")"); return
        }
        
        NSLog("Steam Controller BLE: found Valve service; discovering characteristics.")
        peripheral.discoverCharacteristics([Self.input45, Self.input47, Self.outputUUID, Self.rumbleUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopping else { return }
        let characteristics = service.characteristics ?? []
        NSLog("Steam Controller BLE: characteristics %@", characteristics.map { $0.uuid.uuidString }.joined(separator: ", "))
        
        input = characteristics.first { $0.uuid == Self.input47 } ?? characteristics.first { $0.uuid == Self.input45 }
        output = characteristics.first { $0.uuid == Self.outputUUID }
        
        rumbleOutput = characteristics.first { $0.uuid == Self.rumbleUUID && $0.properties.contains(.write) }
        
        guard error == nil, let input, let output,
              input.properties.contains(.notify), output.properties.contains(.write) else {
            fail("New Steam Controller input/configuration characteristics are missing."); return
        }
        
        reportID = input.uuid == Self.input47 ? 0x47 : 0x45
        
        peripheral.setNotifyValue(true, for: input)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopping, characteristic === input else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("Could not subscribe to input: \(error?.localizedDescription ?? "notifications disabled")"); return
        }
        
        NSLog("Steam Controller BLE: subscribed to report 0x%02x; configuring.", Int(reportID))
        
        configure()
    }
    
    private func configure() {
        guard !configuring, !configured, !stopping, let output else { return }
        configuring = true
        
        // Triton uses raw feature payloads
        writes = [
            Write(characteristic: output, data: SteamControllerProtocol.disableLizardMode, purpose: .lizard),
            Write(characteristic: output, data: SteamControllerProtocol.setting(48, value: 0x18), purpose: .motion),
        ]
        
        writeNext()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopping, characteristic === input else { return }
        
        guard error == nil, let data = characteristic.value else { fail("Input notification failed."); return }
        
        if !loggedInput {
            loggedInput = true
            NSLog("Steam Controller BLE: first 0x%02x input (%ld bytes).", Int(reportID), data.count)
        }
        
        guard let state = decoder.decode(data, reportID: reportID) else { return }
        
        latestState = state
        configure()
        deliverLatestState()
    }
    
    func deliverLatestState() {
        guard let state = latestState, let controller else { return }
        
        DispatchQueue.main.async { [weak controller] in controller?.receive(state) }
    }
    
    private func writeNext() {
        guard inFlight == nil else { return }
        
        guard !writes.isEmpty else {
            if stopping { finishClosing() }
            
            else if configuring {
                configuring = false
                configured = true
                
                timeout?.cancel()
                
                startOutputTimer()
                onReady?()
            }
            return
        }
        
        guard peripheral.state == .connected else { fail("Disconnected during output."); return }
        
        let write = writes.removeFirst()
        
        guard write.data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            fail("Controller's negotiated write length is too small for a feature report."); return
        }
        
        inFlight = write
        
        peripheral.writeValue(write.data, for: write.characteristic, type: .withResponse)
        
        let work = DispatchWorkItem { [weak self] in self?.fail("Controller write timed out.") }
        
        writeTimeout = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let write = inFlight, characteristic === write.characteristic else { return }
        
        writeTimeout?.cancel()
        inFlight = nil
        
        if let error {
            if write.purpose == .rumble {
                if !loggedRumbleError { NSLog("Steam Controller BLE: rumble unavailable: %@", error.localizedDescription) }
                
                loggedRumbleError = true
                rumblePayload = nil
                
                writes.removeAll { $0.purpose == .rumble }
            } else {
                fail("Controller rejected configuration: \(error.localizedDescription)")
                return
            }
        }
        writeNext()
    }
    
    private func enqueue(_ data: Data, on characteristic: CBCharacteristic, purpose: Purpose) {
        writes.removeAll { $0.purpose == purpose }
        writes.append(Write(characteristic: characteristic, data: data, purpose: purpose))
        writeNext()
    }
    
    private func startOutputTimer() {
        nextLizardUpdate = ProcessInfo.processInfo.systemUptime + 3
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.updateOutput() }
        outputTimer = timer
        timer.resume()
    }
    
    private func updateOutput() {
        guard configured, !stopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        
        if now >= nextLizardUpdate, let output {
            nextLizardUpdate = now + 3
            enqueue(SteamControllerProtocol.disableLizardMode, on: output, purpose: .lizard)
        }
        
        if let payload = rumblePayload, let rumbleOutput {
            if now < rumbleUntil {
                // Triton rumble expires unless resent every 40 ms.
                enqueue(payload, on: rumbleOutput, purpose: .rumble)
            } else {
                rumblePayload = nil
                enqueue(SteamControllerProtocol.rumble(left: 0, right: 0), on: rumbleOutput, purpose: .rumble)
            }
        }
    }
    
    func setMotion(_ enabled: Bool) {
        guard configured, !stopping, enabled != motionEnabled, let output else { return }
        motionEnabled = enabled
        enqueue(SteamControllerProtocol.setting(48, value: enabled ? 0x18 : 0), on: output, purpose: .motion)
    }
    
    func rumble(_ data: RumbleData) {
        guard configured, !stopping, !loggedRumbleError, let rumbleOutput else { return }
        
        let payload = SteamControllerProtocol.rumble(left: data.lowFrequency, right: data.highFrequency)
        let active = data.durationMs > 0 && (data.lowFrequency > 0 || data.highFrequency > 0)
        
        rumbleUntil = ProcessInfo.processInfo.systemUptime + Double(data.durationMs) / 1000
        rumblePayload = active ? payload : nil
        
        enqueue(active ? payload : SteamControllerProtocol.rumble(left: 0, right: 0), on: rumbleOutput, purpose: .rumble)
    }
}
