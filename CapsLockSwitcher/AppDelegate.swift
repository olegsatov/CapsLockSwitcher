import Cocoa
import InputMethodKit
import Carbon.HIToolbox
import Accessibility
import ServiceManagement
import OSLog // Make sure this is imported for OSAllocatedUnfairLock too

// MARK: - Logger Categories

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.example.CapsLockSwitcherRemap"
    static let app = Logger(subsystem: subsystem, category: "Application")
    static let state = Logger(subsystem: subsystem, category: "StateManagement")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let eventTap = Logger(subsystem: subsystem, category: "EventTap")
    static let hid = Logger(subsystem: subsystem, category: "HIDUtil")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    // Add Timer category for clarity
    static let timer = Logger(subsystem: subsystem, category: "PermissionTimer")
}

// MARK: - Global Event Tap Callback (SYNCHRONOUS - Listens for CapsLock/LANG1 and Fn/Globe)

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type == .keyDown || type == .flagsChanged else {
        return Unmanaged.passRetained(event)
    }

    guard let refcon = refcon else {
        Logger.eventTap.error("FATAL: refcon is nil in eventTapCallback") // Use Logger
        // Cannot access AppDelegate instance here safely, so just pass through
        return Unmanaged.passRetained(event)
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    Logger.eventTap.debug("Tap event: \(type == .keyDown ? "keyDown" : "flagsChanged"), code: \(keyCode), flags: \(event.flags.rawValue)")

    // --- Caps Lock (remapped by hidutil to LANG1, keycode 104): activate layout slot 1 ---
    if type == .keyDown && keyCode == Int64(delegate.triggerKeyCode) {
        // *** SAFETY CHECK: skip TIS calls if permissions are known to be missing ***
        guard delegate.checkKnownPermissionsFlag() else {
            // Log already happens inside checkKnownPermissionsFlag if false
            return Unmanaged.passRetained(event) // Pass LANG through if permissions are known to be missing
        }
        // Direct selection is idempotent: key repeats can never cause a double switch
        let shouldConsume = delegate.performSwitchSync(slot: 1)
        if shouldConsume {
            return nil // Consume the LANG event
        } else {
            return Unmanaged.passRetained(event) // Pass through (e.g., if state wasn't .active)
        }
    }

    // --- Fn/Globe key: watch the fn FLAG via flagsChanged ---
    // A long press/hold produces NO keyDown/keyUp events for the Globe key — macOS
    // synthesizes the 179-key pair only for a quick tap, on release. The fn flag,
    // however, announces the physical press and release at once, for any duration.
    if type == .flagsChanged {
        let fnDown = (event.flags.rawValue & (1 << 23)) != 0 // kCGEventFlagMaskSecondaryFn
        if fnDown && !delegate.globeIsDown {
            // fn pressed → switch immediately, remember the pre-press layout
            delegate.globeIsDown = true
            guard delegate.checkKnownPermissionsFlag() else {
                return Unmanaged.passRetained(event)
            }
            delegate.activateGlobeSlotSync()
            return Unmanaged.passRetained(event)
        }
        if !fnDown && delegate.globeIsDown {
            // fn released → chord window over; a plain press keeps the new layout
            delegate.globeIsDown = false
            delegate.globeChordSavedSource = nil
            return Unmanaged.passRetained(event)
        }
        // Other modifier changes while fn is held (e.g. shift down/up) fall through here
        return Unmanaged.passRetained(event)
    }

    // --- Any other key pressed while fn is held → fn+key chord: undo the switch ---
    if delegate.globeChordSavedSource != nil {
        delegate.undoGlobeChordSwitch()
    }

    return Unmanaged.passRetained(event)
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Constants & Core Properties

    private enum PrefKeys {
        static let selectedSourceID1 = "selectedSourceID1"
        static let selectedSourceID2 = "selectedSourceID2"
        static let hasShownWelcome = "hasShownWelcome"
    }

    private let hidCapsLockUsage = 0x700000039
    private let hidLangKeyUsage = 0x700000090 // Keyboard LANG1
    /// Caps Lock is remapped by hidutil to LANG1, which macOS delivers as keyDown keycode 104
    internal let triggerKeyCode = CGKeyCode(104)
    /// Globe/Fn key on Apple keyboards (macOS 10.14+): delivered as keyDown/keyUp keycode 179
    internal let globeKeyCode = CGKeyCode(179)

    fileprivate enum AppOperationalState: String, CustomStringConvertible {
        case permissionsRequired = "Permissions Required"
        case configuring = "Configuring"
        case active = "Active"

        var description: String { self.rawValue }
    }

    private var isShowingPermissionAlert = false

    /// True while the status-bar menu is open. The view-based layout rows keep the menu
    /// open on click, so menu-content rebuilds are deferred until menuDidClose.
    private var isMenuOpen = false

    /// The layout that was active before the last Globe (Fn) press. While fn is held,
    /// any other keyDown (an fn+key chord) restores this layout.
    fileprivate var globeChordSavedSource: TISInputSource?
    /// True from the fn-down flagsChanged until the fn-up flagsChanged.
    fileprivate var globeIsDown = false

    private var statusItem: NSStatusItem?
    private var appMenu: NSMenu?
    private var statusMenuItem: NSMenuItem?

    fileprivate struct AppState {
        var selectedSourceID1: String? = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID1)
        var selectedSourceID2: String? = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID2)
        var targetSource1Ref: TISInputSource? = nil
        var targetSource2Ref: TISInputSource? = nil
        var availableSelectionCount: Int = 0
        var allSelectableSources: [TISInputSource] = []
        var eventTap: CFMachPort? = nil
        var runLoopSource: CFRunLoopSource? = nil
        var currentOperationalState: AppOperationalState = .permissionsRequired // Start assuming permissions are needed
        var isHidRemappingApplied: Bool = false
    }
    fileprivate var state = AppState()

    // --- NEW: Properties for Periodic Permission Check (Option 1) ---
    private let permissionCheckLock = OSAllocatedUnfairLock()
    private var hasKnownAccessibilityPermissions: Bool = false // Protected by lock
    private var permissionCheckTimer: Timer?
    private let permissionCheckInterval: TimeInterval = 3.0 // Check every 3 seconds
    // ----------------------------------------------------------------

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Logger.app.info("CapsLockSwitcher (HID Remap): Did Finish Launching")
        manageHidRemapping(enable: false, context: "Launch Initial Reset") // Ensure reset on launch

        // Perform initial state check and UI setup
        determineStateAndSetupUI(context: "Launch")

        // --- NEW: Start Periodic Permission Check ---
        // Perform an immediate check to initialize the flag correctly
        checkPermissionsAndUpdateFlag()
        // Schedule the timer
        setupPermissionCheckTimer()
        // --------------------------------------------
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Logger.app.info("CapsLockSwitcher (HID Remap): Will Terminate")

        // --- NEW: Stop Periodic Permission Check ---
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        Logger.timer.info("Permission check timer invalidated.")
        // -------------------------------------------

        // Perform cleanup
        manageHidRemapping(enable: false, context: "Terminate")
        destroyEventTap()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Periodic Permission Check Logic (Option 1)

    private func setupPermissionCheckTimer() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard permissionCheckTimer == nil else { return } // Don't create multiple timers
        Logger.timer.info("Setting up periodic permission check timer (Interval: \(self.permissionCheckInterval)s).")
        permissionCheckTimer = Timer.scheduledTimer(
            timeInterval: permissionCheckInterval,
            target: self,
            selector: #selector(checkPermissionsPeriodically),
            userInfo: nil,
            repeats: true
        )
        // Ensure it runs even when modal panels are up (like save dialogs)
        RunLoop.current.add(permissionCheckTimer!, forMode: .common)
    }

    /// Checks permissions and updates the thread-safe flag.
    /// Should be called on the main thread.
    private func checkPermissionsAndUpdateFlag() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let currentPermissions = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
        permissionCheckLock.lock()
        hasKnownAccessibilityPermissions = currentPermissions
        permissionCheckLock.unlock()
        Logger.permissions.debug("Updated hasKnownAccessibilityPermissions flag to: \(currentPermissions)")
    }

    /// Called by the timer to check for permission changes.
    @objc private func checkPermissionsPeriodically() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Logger.timer.debug("Timer fired: Checking permissions...")

        let currentPermissions = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
        var previousPermissions: Bool = false

        // Safely read previous and update current
        permissionCheckLock.lock()
        previousPermissions = hasKnownAccessibilityPermissions
        if previousPermissions != currentPermissions {
            hasKnownAccessibilityPermissions = currentPermissions // Update the flag
            Logger.permissions.info("Permission status changed: \(previousPermissions) -> \(currentPermissions)")
        }
        permissionCheckLock.unlock()

        // If status changed, trigger a full state update
        if previousPermissions != currentPermissions {
            Logger.state.info("Permission change detected by timer, triggering state update.")
            determineStateAndSetupUI(context: "Permission Change Detected")
        } else {
             // Logger.timer.debug("No permission change detected.")
        }
    }

    /// Thread-safe check of the known permission status flag.
    /// Called from the synchronous event tap callback. Returns true if permissions are known to be granted.
    fileprivate func checkKnownPermissionsFlag() -> Bool {
        permissionCheckLock.lock()
        let permissionsKnown = hasKnownAccessibilityPermissions
        permissionCheckLock.unlock()

        if !permissionsKnown {
            Logger.permissions.warning("SYNC Event Check: Blocking action because hasKnownAccessibilityPermissions is false.")
        }
        return permissionsKnown
    }


    // MARK: - Core State Determination & UI Setup (Manages HID Remapping)

    private func determineStateAndSetupUI(context: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.state.debug("Determining state (Context: \(context))...")

        // 1. Check Permissions
        let hasPermissions = checkAccessibilityPermissions(promptUserIfNeeded: false)

        // --- NEW: Update the shared flag whenever we do a check ---
        permissionCheckLock.lock()
        let flagChanged = (hasKnownAccessibilityPermissions != hasPermissions)
        hasKnownAccessibilityPermissions = hasPermissions
        permissionCheckLock.unlock()
        if flagChanged {
             Logger.permissions.info("Updated hasKnownAccessibilityPermissions flag to \(hasPermissions) during state determination (Context: \(context))")
        }
        // -------------------------------------------------------


        // 2. Fetch Sources & Check Selections (only if permissions OK)
        var determinedSelectionCount = 0
        if hasPermissions {
            fetchAllSelectableSources()
            updateActiveTargetRefsAndAvailabilityCount()
            determinedSelectionCount = state.availableSelectionCount
        } else {
            // Ensure these are cleared if permissions are lost
            state.availableSelectionCount = 0
            state.targetSource1Ref = nil
            state.targetSource2Ref = nil
            state.allSelectableSources = []
        }

        // 3. Determine Operational State
        let determinedState = determineCurrentOperationalState(
            hasPermissions: hasPermissions,
            availableSelectionCount: determinedSelectionCount
        )
        let previousState = state.currentOperationalState
        let stateChanged = (previousState != determinedState)
        Logger.state.info("State Check: Prev=\(previousState.description), New=\(determinedState.description), Changed=\(stateChanged)")


        // --- 4. Manage HID Remapping based on State Transition ---
        if stateChanged {
            if determinedState == .active {
                // Only enable if not already applied (safety check)
                if !state.isHidRemappingApplied {
                    manageHidRemapping(enable: true, context: "Entering Active State")
                } else {
                     Logger.hid.warning("State changed to Active, but HID remapping was already applied. Skipping enable.")
                }
            } else { // Moving to Configuring or PermissionsRequired
                // Only disable if currently applied (safety check)
                if state.isHidRemappingApplied {
                    manageHidRemapping(enable: false, context: "Exiting Active State (To \(determinedState.description))")
                } else {
                    Logger.hid.warning("State changed away from Active (\(determinedState.description)), but HID remapping was not applied. Skipping disable.")
                }
            }
        } else {
            // Handle cases where state *didn't* change but remapping might be inconsistent
             if determinedState == .active && !state.isHidRemappingApplied {
                 Logger.hid.warning("State is Active, but remapping wasn't applied. Attempting to apply now (Context: \(context)).")
                 manageHidRemapping(enable: true, context: "Re-applying Active State (\(context))")
             } else if determinedState != .active && state.isHidRemappingApplied {
                 Logger.hid.warning("State is NOT Active (\(determinedState.description)), but remapping is still applied. Attempting to remove now (Context: \(context)).")
                 manageHidRemapping(enable: false, context: "Forced Reset Non-Active (\(context))")
             }
        }


        // --- 5. Update Internal State variable ---
        state.currentOperationalState = determinedState

        // --- 6. Setup Status Bar (Icon & Base Menu Structure) ---
        setupStatusBar() // Updates icon based on new state

        // --- 7. Setup/Destroy Event Tap ---
        // Setup if permissions OK, state allows switching, and tap doesn't exist
        if hasPermissions && (determinedState == .active || determinedState == .configuring) && state.eventTap == nil {
             Logger.eventTap.info("Conditions met to set up event tap (Permissions OK, State=\(determinedState.description), Tap is nil)")
             setupEventTap()
        }
        // Destroy if permissions lost OR state doesn't require it anymore, and tap exists
        else if (!hasPermissions || determinedState == .permissionsRequired) && state.eventTap != nil {
             Logger.eventTap.info("Conditions met to destroy event tap (Permissions: \(hasPermissions), State=\(determinedState.description), Tap exists)")
             destroyEventTap()
        }

        // --- 8. Update Dynamic Menu Content ---
        // This needs to happen *after* setupStatusBar which might recreate the menu
        if determinedState == .configuring || determinedState == .active {
             updateMenuState() // Populates layout list, updates status text
        }


        // --- 9. Trigger Alerts ASYNCHRONOUSLY ---
        // Only show permission alert if needed AND state actually requires it AND not already showing
        if determinedState == .permissionsRequired && !isShowingPermissionAlert && (context == "Launch" || stateChanged) {
            isShowingPermissionAlert = true // Prevent spamming alerts
            Logger.permissions.info("Queueing Permission Alert (Context: \(context), State Changed: \(stateChanged))")
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.showAccessibilityInstructionsAlert(triggeredByUserAction: false)
                // Reset flag only *after* alert is dismissed (or potentially immediately if runModal blocks)
                // Doing it here allows re-triggering if needed after dismissal
                strongSelf.isShowingPermissionAlert = false
            }
        } else if determinedState == .configuring && context == "Launch" {
             // Show welcome only on first launch into configuring state
             DispatchQueue.main.async { [weak self] in
                 self?.showWelcomeMessageIfNeeded()
             }
        }
        Logger.state.debug("State determination and UI setup complete (Context: \(context)).")
    }

    // Simplified state determination
    private func determineCurrentOperationalState(hasPermissions: Bool, availableSelectionCount: Int) -> AppOperationalState {
        if !hasPermissions { return .permissionsRequired }
        // Only Active if permissions are granted AND exactly 2 layouts are selected AND available
        if availableSelectionCount == 2 { return .active }
        // Otherwise, if permissions are granted but setup isn't complete, it's Configuring
        return .configuring
    }

    // MARK: - Synchronous Event Handling (Called from C callback)

    /// Directly activates the layout bound to `slot` (1 = Caps Lock, 2 = Fn/Globe) if the app is Active.
    /// Called SYNCHRONOUSLY from the event tap callback. Must be non-blocking.
    /// Assumes permission check (`checkKnownPermissionsFlag`) already passed.
    /// Idempotent: selecting the layout that is already active is a no-op, so repeated
    /// events (key repeat, extra flagsChanged) can never cause a double switch.
    fileprivate func performSwitchSync(slot: Int) -> Bool {
        // 1. Check Operational State (Primary check after permission flag)
        guard state.currentOperationalState == .active else {
            // This log indicates a trigger key was pressed but the app wasn't fully ready (e.g., configuring)
            Logger.eventTap.debug("SYNC Switch(slot \(slot)): Pass through. State is not Active (\(self.state.currentOperationalState.description)).")
            return false // State not active, pass event through
        }

        // 2. Resolve the target layout for this slot (safety check, should always be valid in .active state)
        let targetSource: TISInputSource?
        let targetIdLog: String
        if slot == 1 {
            targetSource = state.targetSource1Ref
            targetIdLog = state.selectedSourceID1 ?? "Target1 (ID unknown)"
        } else {
            targetSource = state.targetSource2Ref
            targetIdLog = state.selectedSourceID2 ?? "Target2 (ID unknown)"
        }

        guard let target = targetSource else {
             Logger.eventTap.error("SYNC Switch(slot \(slot)) FAIL: Missing target ref for '\(targetIdLog)' in Active state. This shouldn't happen.")
             // Consume the event to prevent unexpected trigger-key behavior.
             return true
        }

        // 3. Get Current Input Source (to skip the switch if the requested layout is already active)
        guard let currentSourceUnmanaged = TISCopyCurrentKeyboardInputSource() else {
             Logger.eventTap.error("SYNC Switch(slot \(slot)) FAIL: TISCopyCurrentKeyboardInputSource returned nil.")
             return true // Consume event on failure
        }
        let currentSource = currentSourceUnmanaged.takeRetainedValue() // Balance the retain

        let targetID = (slot == 1) ? state.selectedSourceID1 : state.selectedSourceID2
        if let currentSourceID = getInputSourceID(currentSource), currentSourceID == targetID {
            Logger.eventTap.debug("SYNC Switch(slot \(slot)): Already on '\(currentSourceID)'. No-op.")
            return true // Consume the event, nothing to switch
        }

        Logger.eventTap.debug("SYNC Switch(slot \(slot)): Current='\(self.getInputSourceID(currentSource) ?? "?")', Selecting='\(targetIdLog)'")

        // 4. Perform the Switch
        let status = TISSelectInputSource(target)

        // 5. Log Result
        if status != noErr {
             // Log the specific Carbon error code
             Logger.eventTap.error("SYNC Switch(slot \(slot)) FAILED: TISSelectInputSource returned error \(status).")
        } else {
             Logger.eventTap.debug("SYNC Switch(slot \(slot)): Success.")
        }
        // Consume the event either way: an attempt was made based on app state
        return true
    }

    // MARK: - Fn/Globe Chord Undo

    /// Globe press: remember the currently active layout (for a possible chord-undo)
    /// and switch to the Fn/Globe layout (slot 2) right away.
    fileprivate func activateGlobeSlotSync() {
        guard state.currentOperationalState == .active else {
            Logger.eventTap.debug("Globe press: pass through. State is not Active.")
            return
        }
        // Save the currently active source so that an fn+key chord can undo the switch
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            globeChordSavedSource = current
        }
        _ = performSwitchSync(slot: 2)
    }

    /// Another key was pressed while the Globe key was still held (fn+key chord):
    /// restore the layout that was active before the Globe press. Idempotent —
    /// repeated chord keyDowns just re-select the saved layout.
    fileprivate func undoGlobeChordSwitch() {
        guard state.currentOperationalState == .active, let saved = globeChordSavedSource else { return }
        let status = TISSelectInputSource(saved)
        if status != noErr {
            Logger.eventTap.error("Globe chord undo FAILED: TISSelectInputSource error \(status).")
        } else {
            Logger.eventTap.debug("Globe chord undo: restored the pre-press layout.")
        }
    }


    // MARK: - HID Remapping Management (Main Thread Only)

    private func manageHidRemapping(enable: Bool, context: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Avoid redundant calls
        guard state.isHidRemappingApplied != enable else {
            Logger.hid.debug("Skipping hidutil (\(context)): Remapping state already \(enable ? "Enabled" : "Disabled")")
            return
        }

        Logger.hid.info("Attempting hidutil (\(context)): \(enable ? "ENABLE CapsLock->LANG" : "REVERT CapsLock->CapsLock") remapping...")

        let jsonPayload: String
        if enable {
            // Map CapsLock to LANG
            let mapping = "[{\"HIDKeyboardModifierMappingSrc\":\(hidCapsLockUsage),\"HIDKeyboardModifierMappingDst\":\(hidLangKeyUsage)}]"
            jsonPayload = "{\"UserKeyMapping\":\(mapping)}"
            Logger.hid.debug("hidutil payload (ENABLE): \(jsonPayload)")
        } else {
            // Explicitly map CapsLock back to CapsLock to restore default behavior
            // Using an empty array "[]" might also work but explicit revert is safer.
            let revertMapping = "[{\"HIDKeyboardModifierMappingSrc\":\(hidCapsLockUsage),\"HIDKeyboardModifierMappingDst\":\(hidCapsLockUsage)}]"
            jsonPayload = "{\"UserKeyMapping\":\(revertMapping)}"
            Logger.hid.debug("hidutil payload (REVERT): \(jsonPayload)")
        }

        // Run hidutil asynchronously off the main thread
        Task(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            process.arguments = ["property", "--set", jsonPayload]
            let outputPipe = Pipe()
            let errorPipe = Pipe() // Separate pipes for clarity
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            var commandOutput = "" // Collect output for logging

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let outStr = String(data: outputData, encoding: .utf8), !outStr.isEmpty { commandOutput += "Output:\n\(outStr)\n" }
                if let errStr = String(data: errorData, encoding: .utf8), !errStr.isEmpty { commandOutput += "Error Output:\n\(errStr)" }
                commandOutput = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)


                if process.terminationStatus == 0 {
                    Logger.hid.info("Hidutil: OK (\(context)) - Remapping \(enable ? "ENABLED (->LANG)" : "REVERTED (->CapsLock)").")
                    // Update internal tracking state *only on success*
                    await MainActor.run { [weak self] in
                        self?.state.isHidRemappingApplied = enable
                    }
                } else {
                    Logger.hid.error("Hidutil: FAILED (status \(process.terminationStatus)) (\(context)) - Could not \(enable ? "enable" : "revert") remapping.")
                    if !commandOutput.isEmpty { Logger.hid.error("Hidutil details: \(commandOutput)") }
                    // Don't change isHidRemappingApplied on failure, as the system state is now uncertain.
                    // Consider showing an alert?
                }
            } catch {
                Logger.hid.critical("Hidutil process EXCEPTION (\(context)): \(error.localizedDescription)")
                 // Don't change isHidRemappingApplied on exception.
                 // Consider showing an alert?
            }
        } // End Task
    }


    // MARK: - System Settings & Permissions Checks (Main Thread Only)

    /// Checks Accessibility Permissions. Main thread only.
    /// - Parameter promptUserIfNeeded: If true, system may prompt user if not trusted.
    /// - Returns: True if process is trusted, false otherwise.
    private func checkAccessibilityPermissions(promptUserIfNeeded: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let optionsKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionsKey: promptUserIfNeeded] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Logger.permissions.debug("AXIsProcessTrustedWithOptions (prompt=\(promptUserIfNeeded)) -> \(trusted)")
        return trusted
    }


    // MARK: - Globe (Fn) Key System Action ("Press 🌐 key to")

    private enum GlobeMenuItemTag {
        static let status = "globeStatus"
        static let fix = "globeFix"
        static let openSettings = "globeOpenSettings"
    }

    /// System setting "Press 🌐 key to" (com.apple.HIToolbox, AppleFnUsageType).
    private enum GlobeKeySystemAction: Int, CustomStringConvertible {
        case doNothing = 0
        case showEmoji = 1
        case changeInputSource = 2
        case startDictation = 3

        var description: String {
            switch self {
            case .doNothing: return "Do Nothing"
            case .showEmoji: return "Show Emoji & Symbols"
            case .changeInputSource: return "Change Input Source"
            case .startDictation: return "Start Dictation"
            }
        }
    }

    /// Reads the current "Press 🌐 key to" system setting.
    private var currentGlobeKeyAction: GlobeKeySystemAction {
        guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) else {
            return .showEmoji // macOS default when the preference has never been set
        }
        let raw = (value as? NSNumber)?.intValue ?? -1
        return GlobeKeySystemAction(rawValue: raw) ?? .showEmoji
    }

    /// The Fn (Globe) key only reaches the app's event tap (and does nothing on its own)
    /// when the system action for it is "Do Nothing".
    private func updateGlobeKeyMenuItems(in menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Remove previous globe items (rebuilt fresh on every menu update)
        for item in menu.items where (item.representedObject as? String)?.hasPrefix("globe") == true {
            menu.removeItem(item)
        }

        // Insert right after the second separator (between the layout list and app options)
        let separatorIndexes = menu.items.enumerated().filter { $0.element.isSeparatorItem }.map { $0.offset }
        guard separatorIndexes.count >= 2 else {
            Logger.ui.error("Globe menu: expected at least 2 separators, found \(separatorIndexes.count).")
            return
        }
        var insertIndex = separatorIndexes[1] + 1

        let action = currentGlobeKeyAction
        let isConfigured = (action == .doNothing)

        let statusLine = NSMenuItem(
            title: isConfigured ? "Fn (Globe) key: Do Nothing ✓" : "Fn (Globe) key: \(action.description) ⚠️",
            action: nil,
            keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.representedObject = GlobeMenuItemTag.status
        menu.insertItem(statusLine, at: insertIndex)
        insertIndex += 1

        if !isConfigured {
            let fixItem = NSMenuItem(title: "Fix: Set to “Do Nothing”", action: #selector(fixGlobeKeyAction(_:)), keyEquivalent: "")
            fixItem.target = self
            fixItem.isEnabled = true
            fixItem.representedObject = GlobeMenuItemTag.fix
            menu.insertItem(fixItem, at: insertIndex)
            insertIndex += 1

            let openItem = NSMenuItem(title: "Open Keyboard Settings", action: #selector(openKeyboardSettingsAction), keyEquivalent: "")
            openItem.target = self
            openItem.isEnabled = true
            openItem.representedObject = GlobeMenuItemTag.openSettings
            menu.insertItem(openItem, at: insertIndex)
        }
    }

    /// Sets the system "Press 🌐 key to" option to "Do Nothing" (AppleFnUsageType = 0)
    /// so that Globe/Fn taps reach the event tap instead of the system handlers.
    @objc func fixGlobeKeyAction(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.settings.info("Setting com.apple.HIToolbox AppleFnUsageType → 0 (Do Nothing)")

        CFPreferencesSetValue("AppleFnUsageType" as CFString,
                              NSNumber(value: GlobeKeySystemAction.doNothing.rawValue),
                              "com.apple.HIToolbox" as CFString,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)

        // Verify the change actually landed (a successful call ≠ applied value)
        let applied = currentGlobeKeyAction == .doNothing

        // Defer the alert so we don't run a modal loop inside menu tracking
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.showGlobeKeyFixResult(applied: applied)
        }
    }

    private func showGlobeKeyFixResult(applied: Bool) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard NSApplication.shared.modalWindow == nil else {
            Logger.ui.warning("Globe key fix alert skipped: Another modal window is already visible.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = applied ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Keyboard Settings")
        if applied {
            alert.messageText = "Globe key setting updated"
            alert.informativeText = "'Press 🌐 key to' is now 'Do Nothing'.\n\nIf pressing Fn still doesn't switch the layout right away, log out and back in so macOS picks up the new setting."
        } else {
            alert.messageText = "Could not update the setting automatically"
            alert.informativeText = "Please set 'Press 🌐 key to' to 'Do Nothing' manually in System Settings > Keyboard."
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openKeyboardSettingsAction()
        }
        determineStateAndSetupUI(context: "GlobeKeyActionFix")
    }

    @objc func openKeyboardSettingsAction() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    // MARK: - Alert Logic (Called Asynchronously from Main Thread)

    private func showAccessibilityInstructionsAlert(triggeredByUserAction: Bool) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Prevent multiple alerts stacking up
        guard NSApplication.shared.modalWindow == nil else {
            Logger.permissions.warning("Accessibility alert skipped: Another modal window (likely an alert) is already visible.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "\(Bundle.main.appName) needs Accessibility access to monitor Caps Lock key.\n\nPlease go to System Settings > Privacy & Security > Accessibility, find and enable \(Bundle.main.appName), or add it manually using the '+' button."
        if triggeredByUserAction {
            alert.informativeText += "\n\nIf it's enabled but not working, try removing \(Bundle.main.appName) using the '-' button, then add it back again."
            alert.informativeText += "\n\nAfter granting/fixing permissions, click the menu bar icon again."
        } else {
             alert.informativeText += "\n\nAfter granting permissions, click the menu bar icon to continue setup, or wait a few seconds for the app to re-check." // Updated text
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")
        
        Logger.permissions.info("Displaying Accessibility Instructions Alert.")
        let response = alert.runModal() // This blocks until dismissed

        if response == .alertFirstButtonReturn {
            // Try opening the specific pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                Logger.permissions.info("Accessibility Alert: Opened settings pane.")
            } else {
                Logger.permissions.error("Failed to create URL for settings pane.")
                // Fallback to opening System Settings main page
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        }
        Logger.permissions.info("Accessibility Alert: Dismissed (response: \(response.rawValue)).")

        // Re-check state immediately after dismissal, maybe permissions were granted
        // No need for the isShowing flag reset here as runModal was blocking
        isShowingPermissionAlert = false // Reset flag here after alert is gone
        Logger.state.info("Re-determining state after permission alert dismissed.")
        determineStateAndSetupUI(context: "Permission Alert Dismissed")

    }

    private func showWelcomeAlert() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard NSApplication.shared.modalWindow == nil else {
            Logger.ui.warning("Welcome alert skipped: Another modal window (likely an alert) is already visible.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Welcome to \(Bundle.main.appName)!"
        alert.informativeText = "Ready to configure!\n\n1. Click the \(Bundle.main.appName) menu bar icon.\n\n2. Select exactly two keyboard layouts: the first is activated by Caps Lock, the second by the Fn (Globe) key.\n\n3. Make sure the system setting 'Press 🌐 key to' is set to 'Do Nothing' (the app's menu can fix this for you).\n\n4. Press Caps Lock or Fn to instantly activate the layout you need!"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        Logger.ui.info("Displaying Welcome alert.")
        alert.runModal()
        Logger.ui.info("Welcome Alert dismissed.")
    }

    private func showWelcomeMessageIfNeeded() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: PrefKeys.hasShownWelcome) {
             Logger.ui.info("Welcome message needed, showing.")
             showWelcomeAlert() // Assumes this runs modally
             defaults.set(true, forKey: PrefKeys.hasShownWelcome)
        } else {
             Logger.ui.debug("Welcome message already shown previously.")
        }
    }

    // MARK: - Menu Actions (Main Thread)

     @objc func showWelcomeGuideAction() { showWelcomeAlert() }
     @objc func openAccessibilitySettings() {
        // No longer need the isShowing flag management here, showAccessibilityInstructionsAlert handles it
        DispatchQueue.main.async { [weak self] in // Ensure it runs after current event loop cycle
             self?.showAccessibilityInstructionsAlert(triggeredByUserAction: true)
        }
    }

    // MARK: - Status Bar & Menu UI Setup (Main Thread Only)

    private func setupStatusBar() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.ui.debug("Setting up status bar for state: \(self.state.currentOperationalState.description)")

        // Create Status Item if it doesn't exist
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            guard let button = statusItem?.button else { // Check button directly
                Logger.app.critical("Status bar item button creation failed.")
                terminateApp() // Use helper to terminate cleanly
                return
            }
            button.imagePosition = .imageOnly // Ensure only image shows
            Logger.ui.info("Status bar item created.")
        }

        // Create Menu if it doesn't exist
        if appMenu == nil {
           appMenu = NSMenu()
           appMenu?.delegate = self
           appMenu?.autoenablesItems = false // We manage enabled state manually
           statusItem?.menu = appMenu // Assign menu to status item
           Logger.ui.info("App menu created and assigned.")
        }

        updateStatusIcon(for: state.currentOperationalState) // Set the icon

        if isMenuOpen {
            // The menu is currently open (view-based layout rows keep it open on click).
            // Tearing down the item tree during tracking would break the open menu,
            // so the content rebuild is deferred to menuDidClose.
            Logger.ui.debug("Menu is open; deferring menu content rebuild until menuDidClose.")
            return
        }

        // Always clear and rebuild the menu content based on current state
        appMenu?.removeAllItems()
        statusMenuItem = nil // Reset status menu item reference

        // Build menu items based on state
        switch state.currentOperationalState {
            case .permissionsRequired:
                let statusItem = NSMenuItem(title: "Permissions Required", action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                appMenu?.addItem(statusItem)
                self.statusMenuItem = statusItem // Store reference if needed later

                appMenu?.addItem(NSMenuItem.separator()) // Separator

                let guideItem = NSMenuItem(title: "Show Permissions Guide", action: #selector(openAccessibilitySettings), keyEquivalent: "")
                guideItem.target = self // Target is self
                guideItem.isEnabled = true
                appMenu?.addItem(guideItem)

            case .configuring, .active:
                // Add status item (title updated in updateMenuState)
                let statusItem = NSMenuItem(title: "Loading Status...", action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                appMenu?.addItem(statusItem)
                self.statusMenuItem = statusItem // Store reference

                appMenu?.addItem(NSMenuItem.separator()) // Separator

                // Placeholder for layout items (added in updateMenuState)
                appMenu?.addItem(NSMenuItem.separator()) // Separator

                // Add common items
                let launchItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleLaunchOnStartup(_:)), keyEquivalent: "l")
                launchItem.target = self
                launchItem.isEnabled = true // Always enabled if permissions are OK
                appMenu?.addItem(launchItem)

                let welcomeItem = NSMenuItem(title: "Show Welcome Guide", action: #selector(showWelcomeGuideAction), keyEquivalent: "w")
                welcomeItem.target = self
                welcomeItem.isEnabled = true
                appMenu?.addItem(welcomeItem)
        }

        // Add Quit item always
        appMenu?.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(Bundle.main.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp // Target is NSApp for terminate
        quitItem.isEnabled = true
        appMenu?.addItem(quitItem)

        Logger.ui.info("Status bar menu rebuilt for state: \(self.state.currentOperationalState.description)")
    }


    private func updateStatusIcon(for operationalState: AppOperationalState) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard let button = statusItem?.button else {
             Logger.ui.error("Cannot update status icon: button is nil")
             return
        }

        let iconName: String
        let accessibilityDescription: String
        let fallbackTitle: String // Use emojis as simple fallbacks

        switch operationalState {
            case .permissionsRequired:
                iconName = "exclamationmark.triangle.fill" // SF Symbol name
                fallbackTitle = "⚠️"
                accessibilityDescription = "\(Bundle.main.appName): Permissions Required"
            case .configuring:
                iconName = "keyboard.badge.ellipsis"
                fallbackTitle = "⚙️" // Gear emoji
                accessibilityDescription = "\(Bundle.main.appName): Configuring - Select Layouts"
            case .active:
                iconName = "keyboard.fill"
                fallbackTitle = "⌨️" // Keyboard emoji
                accessibilityDescription = "\(Bundle.main.appName): Active (Caps Lock → Layout 1, Fn/Globe → Layout 2)"
        }

        // Attempt to use SF Symbol first
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) { // Don't set accessibility here, use tooltip/button property
            image.isTemplate = true // Ensures it respects dark/light mode
            button.image = image
            button.title = "" // Clear title when using image
            Logger.ui.debug("Set status icon using SF Symbol: \(iconName)")
        } else {
            // Fallback to text/emoji if symbol not found
            button.image = nil
            button.title = fallbackTitle
            Logger.ui.warning("SF Symbol '\(iconName)' failed. Using fallback text '\(fallbackTitle)'. Check macOS version compatibility.")
        }
        // Set tooltip regardless
        button.toolTip = accessibilityDescription
    }


    private func updateMenuState() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard !isMenuOpen else {
            // The menu is open: content changes are deferred to menuDidClose. Clicks on
            // layout rows refresh the visible rows in place instead (refreshOpenMenuContent).
            Logger.ui.debug("Skipping menu state update: menu is currently open.")
            return
        }
        guard state.currentOperationalState == .configuring || self.state.currentOperationalState == .active,
              let menu = appMenu else {
            Logger.ui.debug("Skipping menu state update (not in configuring/active state or menu nil)")
            return
        }
        Logger.ui.debug("Updating dynamic menu content (State: \(self.state.currentOperationalState.description))...")

        // Update Status Text
        if let statusItem = self.statusMenuItem { // Use the stored reference
            statusItem.title = currentStatusLineTitle()
             Logger.ui.debug("Status menu item text set to: \(statusItem.title)")
        } else {
             Logger.ui.warning("Cannot update status text: statusMenuItem reference is nil.")
        }

        // Update Layout List Items
        updateLayoutMenuItems(in: menu)

        // Update Globe (Fn) key status section
        updateGlobeKeyMenuItems(in: menu)
    }

    /// Title for the status line at the top of the menu, based on the current operational state.
    private func currentStatusLineTitle() -> String {
        switch state.currentOperationalState {
        case .active:
            return "Active: Caps Lock → \(displayName(forSourceID: state.selectedSourceID1)), Fn → \(displayName(forSourceID: state.selectedSourceID2))"
        case .configuring:
            return (state.availableSelectionCount == 1) ? "Select 1 more layout..." : "Select 2 layouts..."
        default:
            return "Status: Unknown"
        }
    }


    private func updateLayoutMenuItems(in menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Find the separators that bracket the layout items
        // Assumes structure: Status -> Sep -> Layouts... -> Sep -> Options...
        guard let firstSepIndex = menu.items.firstIndex(where: { $0.isSeparatorItem }),
              let secondSep = menu.items[(firstSepIndex + 1)...].first(where: { $0.isSeparatorItem }),
              let secondSepIndex = menu.items.firstIndex(of: secondSep) else {
            Logger.ui.error("Layout separators not found correctly for updateLayoutMenuItems. Menu structure might be wrong.")
            return
        }

        // Remove existing items between the separators
        let rangeToRemove = (firstSepIndex + 1)..<secondSepIndex
        if !rangeToRemove.isEmpty {
            Logger.ui.debug("Removing \(rangeToRemove.count) old layout items between indices \(rangeToRemove.lowerBound) and \(rangeToRemove.upperBound).")
            for i in rangeToRemove.reversed() { // Remove from end to start
                menu.removeItem(at: i)
            }
        } else {
             Logger.ui.debug("No existing layout items found to remove.")
        }

        let insertIndex = firstSepIndex + 1 // Index where new items will start
        Logger.ui.debug("Adding \(self.state.allSelectableSources.count) view-based layout rows (click keeps the menu open) at index \(insertIndex)...")

        // Rows are VIEW-based menu items: clicking a row does not dismiss the menu, so the
        // user can try each layout live and watch the checkmarks move in place.
        var rowWidth: CGFloat = 260
        for source in state.allSelectableSources {
            if let name = getInputSourceLocalizedName(source) {
                rowWidth = max(rowWidth, LayoutMenuItemView.preferredWidth(forTitle: name))
            }
        }

        for (offset, source) in state.allSelectableSources.enumerated() {
            guard let name = getInputSourceLocalizedName(source), let id = getInputSourceID(source) else {
                Logger.ui.warning("Skipping layout item: Could not get name or ID for a source.")
                continue
            }

            let rowView = LayoutMenuItemView(title: name, sourceID: id, width: rowWidth)
            rowView.toolTip = "Keyboard Layout: \(name) (\(id))"
            rowView.onActivate = { [weak self] in
                self?.handleLayoutSelection(source: source, id: id)
            }
            refreshLayoutRow(rowView)

            let menuItem = NSMenuItem()
            menuItem.view = rowView
            menu.insertItem(menuItem, at: insertIndex + offset)
        }

        // Add instruction text if configuring
        if state.currentOperationalState == .configuring && state.allSelectableSources.isEmpty {
             let noSourcesItem = NSMenuItem(title: "(No keyboard layouts found)", action: nil, keyEquivalent: "")
             noSourcesItem.isEnabled = false
             menu.insertItem(noSourcesItem, at: insertIndex)
        }

        Logger.ui.debug("Layout menu rows update complete.")
    }

    /// Recomputes the visual state (checkmark, hot-key annotation, dimming) of one layout row.
    private func refreshLayoutRow(_ rowView: LayoutMenuItemView) {
        let slot = slotForSourceID(rowView.sourceID)
        // A row is clickable when it is already selected (to deselect it)
        // or when there is still a free slot for it.
        let canSelectMore = (state.targetSource1Ref == nil || state.targetSource2Ref == nil)
        rowView.refresh(slot: slot, enabled: slot != 0 || canSelectMore)
    }

    /// Which slot activates a layout: 0 = not selected, 1 = Caps Lock, 2 = Fn/Globe.
    private func slotForSourceID(_ id: String) -> Int {
        if id == state.selectedSourceID1 { return 1 }
        if id == state.selectedSourceID2 { return 2 }
        return 0
    }

    /// Refreshes the visible layout rows and status line in place while the menu stays open.
    private func refreshOpenMenuContent() {
        guard isMenuOpen, let menu = appMenu else { return }
        for item in menu.items {
            if let rowView = item.view as? LayoutMenuItemView {
                refreshLayoutRow(rowView)
            }
        }
        if let statusItem = self.statusMenuItem {
            statusItem.title = currentStatusLineTitle()
        }
    }


    // MARK: - Launch on Startup Logic (Using SMAppService)

    // Updated to handle potential SMAppService errors more gracefully
    private func performLaunchOnStartupUpdate(enable: Bool) async -> (status: SMAppService.Status, error: Error?) {
        do {
            if enable {
                try SMAppService.mainApp.register()
                Logger.app.info("Launch on Startup: Registered successfully.")
            } else {
                try await SMAppService.mainApp.unregister() // Ensure await here
                Logger.app.info("Launch on Startup: Unregistered successfully.")
            }
            // Return current status after successful operation, no error
            return (SMAppService.mainApp.status, nil)
        } catch {
            Logger.app.error("Launch on Startup: \(enable ? "Registration" : "Unregistration") failed: \(error.localizedDescription)")
            // Return current status and the error
            return (SMAppService.mainApp.status, error)
        }
    }

    @objc func toggleLaunchOnStartup(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        let shouldEnable = (sender.state == .off) // Determine desired state
        let targetSelector = #selector(toggleLaunchOnStartup(_:)) // For finding the item later

        Task(priority: .userInitiated) { // Use userInitiated as it's a direct user action
            // Perform the update and capture the result (status and potential error)
            let result = await performLaunchOnStartupUpdate(enable: shouldEnable)

            // Switch back to the main actor to update the UI safely
            await MainActor.run { [weak self] in
                 self?.updateLaunchOnStartupMenuItem(selector: targetSelector, status: result.status, error: result.error)
            }
        }
     }

    // Update UI based on the result of the SMAppService operation
    private func updateLaunchOnStartupMenuItem(selector: Selector, status: SMAppService.Status, error: Error?) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Update the checkmark state based on the reported status
        if let menuItem = self.appMenu?.items.first(where: { $0.action == selector }) {
            menuItem.state = (status == .enabled) ? .on : .off
            Logger.ui.debug("Launch on Startup menu item state updated to: \(menuItem.state == .on ? "ON" : "OFF") (Status: \(status.rawValue))")
        } else {
             Logger.ui.error("Could not find Launch on Startup menu item to update state.")
        }

        // Show an alert if an error occurred
        if let error = error {
            Logger.ui.error("Presenting Launch on Startup error alert.")
            // Avoid showing if another alert is up
            guard NSApplication.shared.modalWindow == nil else {
                 Logger.ui.warning("Skipped Launch on Startup error alert: Another modal window (likely an alert) is visible.")
                 return
            }
            let alert = NSAlert()
            alert.messageText = "Launch on Startup Error"
            alert.informativeText = "Could not update the 'Launch on Startup' setting.\n\nError: \(error.localizedDescription)\n\nYou may need to manage this manually in System Settings > General > Login Items."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
     }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Logger.ui.debug("Menu Will Open...")
        // Always run the full state check when menu opens to ensure UI is correct.
        // This rebuilds the menu content while it is still safe to do so
        // (isMenuOpen is set only afterwards, before any item clicks can arrive).
        determineStateAndSetupUI(context: "MenuOpen")
        isMenuOpen = true
        // Update launch item state *after* determineState sets up the menu
        if state.currentOperationalState == .configuring || state.currentOperationalState == .active {
            updateLaunchOnStartupItemState(menu) // Update based on current SMAppService status
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        Logger.ui.debug("Menu Did Close.")
        isMenuOpen = false
        // Content changes were deferred while the menu stayed open (view-based layout
        // rows); rebuild the menu now that tracking has ended.
        determineStateAndSetupUI(context: "MenuDidClose")
    }

    // Helper to specifically update the launch item state when menu opens
    private func updateLaunchOnStartupItemState(_ menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Find the specific menu item
        if let launchItem = menu.items.first(where: { $0.action == #selector(toggleLaunchOnStartup(_:)) }) {
            let currentStatus = SMAppService.mainApp.status // Get current status
            launchItem.state = (currentStatus == .enabled) ? .on : .off // Set checkmark
            Logger.ui.debug("Launch item state refreshed on menu open: \(launchItem.state == .on ? "ON" : "OFF")")
        }
    }


    // MARK: - Input Source (TIS) Handling (Main Thread Only)

    private func fetchAllSelectableSources() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Define filter properties for TIS
        let filter = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as String, // Use as String
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as String, // Use as String
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue! // Use CFBoolean literal
        ] as CFDictionary // Explicitly cast to CFDictionary

        // Create the list
        guard let sourcesListUntyped = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else {
            Logger.settings.error("TISCreateInputSourceList returned nil. Cannot fetch input sources.")
            state.allSelectableSources = []
            return
        }

        // Cast to Swift array
        guard let sourcesList = sourcesListUntyped as? [TISInputSource] else {
            Logger.settings.error("Could not cast CFArray of input sources to [TISInputSource].")
            state.allSelectableSources = []
            return
        }

        // Filter out any potentially problematic sources (e.g., "null" layout if seen)
        state.allSelectableSources = sourcesList.filter { source in
            if let id = getInputSourceID(source), id.lowercased() == "null" {
                 Logger.settings.warning("Filtering out source with ID 'null'.")
                 return false
            }
            // Also ensure it has a valid localized name
            if getInputSourceLocalizedName(source) == nil {
                Logger.settings.warning("Filtering out source without a localized name (ID: \(self.getInputSourceID(source) ?? "N/A")).")
                return false
            }
            return true
        }

        Logger.settings.debug("Fetched \(self.state.allSelectableSources.count) valid, selectable keyboard layouts.")
     }

    private func updateActiveTargetRefsAndAvailabilityCount() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Reset refs and count before checking
        state.targetSource1Ref = nil
        state.targetSource2Ref = nil
        state.availableSelectionCount = 0

        let id1 = state.selectedSourceID1
        let id2 = state.selectedSourceID2

        // If neither ID is set, we're done.
        guard id1 != nil || id2 != nil else {
            Logger.state.debug("No layouts selected in UserDefaults, available count is 0.")
            return
        }

        var count = 0
        var foundRef1: TISInputSource? = nil
        var foundRef2: TISInputSource? = nil

        // Iterate through all *currently enabled* sources
        for source in state.allSelectableSources {
            guard let sourceID = getInputSourceID(source) else { continue } // Skip if source has no ID

            // Check if this source matches one of our selected IDs
            if sourceID == id1 {
                foundRef1 = source
                count += 1
                Logger.state.debug("Found match for selected ID 1: \(id1!)")
            } else if sourceID == id2 { // Use 'else if' assuming IDs are unique
                foundRef2 = source
                count += 1
                 Logger.state.debug("Found match for selected ID 2: \(id2!)")
            }

            // Optimization: If we've found both, no need to check further
            if foundRef1 != nil && foundRef2 != nil {
                 break
            }
        }

        // Update the state
        state.targetSource1Ref = foundRef1
        state.targetSource2Ref = foundRef2
        // Crucially, availableSelectionCount is how many *selected* layouts are *currently usable*
        state.availableSelectionCount = count

        // Log mismatches if an ID was selected but no matching source was found
        if id1 != nil && foundRef1 == nil {
             Logger.state.warning("Selected layout ID '\(id1!)' is not currently enabled or available.")
        }
        if id2 != nil && foundRef2 == nil {
             Logger.state.warning("Selected layout ID '\(id2!)' is not currently enabled or available.")
        }

        Logger.state.info("Updated available selection count: \(count). (Ref1: \(foundRef1 != nil), Ref2: \(foundRef2 != nil))")
     }


    private func handleLayoutSelection(source: TISInputSource, id: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.ui.info("Layout Item Clicked: '\(id)' (menu stays open)")

        let userDefaults = UserDefaults.standard
        let wasSelected = (slotForSourceID(id) != 0) // Was it selected *before* the click?

        if wasSelected {
            // --- DESELECTING ---
            Logger.ui.debug("Deselecting layout: \(id)")
            if state.selectedSourceID1 == id {
                state.selectedSourceID1 = nil
                userDefaults.removeObject(forKey: PrefKeys.selectedSourceID1)
                Logger.settings.info("Removed selectedSourceID1 (\(id))")
            } else if state.selectedSourceID2 == id {
                state.selectedSourceID2 = nil
                userDefaults.removeObject(forKey: PrefKeys.selectedSourceID2)
                Logger.settings.info("Removed selectedSourceID2 (\(id))")
            } else {
                 // This case should ideally not happen if UI state is correct
                Logger.ui.warning("Layout '\(id)' was selected but didn't match stored ID1 ('\(self.state.selectedSourceID1 ?? "nil")') or ID2 ('\(self.state.selectedSourceID2 ?? "nil")'). Clearing from UserDefaults anyway.")
                 if userDefaults.string(forKey: PrefKeys.selectedSourceID1) == id { userDefaults.removeObject(forKey: PrefKeys.selectedSourceID1)}
                 if userDefaults.string(forKey: PrefKeys.selectedSourceID2) == id { userDefaults.removeObject(forKey: PrefKeys.selectedSourceID2)}
            }

        } else {
            // --- SELECTING ---
            // Recalculate available slots based on current state *before* assigning
            // This uses the *live* TIS Refs, which is more accurate than just checking IDs
            let slot1Filled = state.targetSource1Ref != nil
            let slot2Filled = state.targetSource2Ref != nil
            let totalFilledSlots = (slot1Filled ? 1 : 0) + (slot2Filled ? 1 : 0)

            guard totalFilledSlots < 2 else {
                Logger.ui.warning("Cannot select more than 2 layouts. Currently filled: \(totalFilledSlots). Beeping.")
                NSSound.beep()
                return // Already have 2 valid selections
            }

            // Assign to the first available slot (prefer slot 1 = Caps Lock)
            if !slot1Filled {
                Logger.ui.debug("Selecting for Slot 1 (Caps Lock): \(id)")
                state.selectedSourceID1 = id
                userDefaults.set(id, forKey: PrefKeys.selectedSourceID1)
                 Logger.settings.info("Set selectedSourceID1 = \(id)")
            } else if !slot2Filled { // Only try slot 2 if slot 1 is already filled
                 Logger.ui.debug("Selecting for Slot 2 (Fn/Globe): \(id)")
                 state.selectedSourceID2 = id
                 userDefaults.set(id, forKey: PrefKeys.selectedSourceID2)
                 Logger.settings.info("Set selectedSourceID2 = \(id)")
            } else {
                 // This case should be caught by the 'totalFilledSlots < 2' guard
                 Logger.ui.error("Logic Error: Tried to select layout \(id) but both slots seem filled despite guard passing.")
                 NSSound.beep()
                 return
            }
        }

        // Persist changes immediately
        userDefaults.synchronize()

        // Re-run the state determination logic (hidutil remap, event tap, icon, etc.).
        // While the menu is open the menu-content rebuild inside is deferred to
        // menuDidClose; the visible rows are refreshed in place below instead.
        Logger.ui.info("Re-determining state after layout selection change for ID: \(id)")
        determineStateAndSetupUI(context: wasSelected ? "LayoutDeselected" : "LayoutSelected")

        // Refresh the open menu in place with the updated state (checkmarks, status text)
        refreshOpenMenuContent()

     }

    // MARK: - Event Tap Lifecycle (Main Thread for Setup/Teardown)

    private func setupEventTap() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard state.eventTap == nil else {
            Logger.eventTap.debug("Tap setup skipped: Tap already exists.")
            return
        }
        // Check permissions again right before creating, though state logic should ensure this
        guard checkAccessibilityPermissions(promptUserIfNeeded: false) else {
            Logger.eventTap.warning("Tap setup skipped: Permissions missing at time of setup.")
            // Ensure state reflects this if it somehow got here
            if state.currentOperationalState != .permissionsRequired {
                Logger.state.warning("State mismatch: setupEventTap called without permissions, forcing state update.")
                determineStateAndSetupUI(context: "Tap Setup Permission Fail")
            }
            return
        }

        Logger.eventTap.info("Creating synchronous event tap (Listening for VK=\(self.triggerKeyCode) [CapsLock/LANG1] and the fn flag via flagsChanged [Fn/Globe])...")
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) // fn flag press/release; any hold duration

        // Pass self as userInfo (refcon)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Create the tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, // Monitor system-wide events
            place: .headInsertEventTap, // Insert tap early
            options: .listenOnly, // Change to .listenOnly initially, callback decides consumption
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            Logger.eventTap.critical("Failed to create event tap! Switching will not work.")
            // This is critical, maybe try to revert state?
             determineStateAndSetupUI(context: "Event Tap Creation Failed")
            return
        }
        Logger.eventTap.debug("CGEvent.tapCreate successful.")

        // Create the run loop source
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Logger.eventTap.critical("Failed to create run loop source for event tap!")
            // Tap was created but source failed, need to invalidate the tap
            CFMachPortInvalidate(tap) // Clean up the created tap port
            determineStateAndSetupUI(context: "RunLoop Source Creation Failed")
            return
        }
         Logger.eventTap.debug("CFMachPortCreateRunLoopSource successful.")

        // Add source to the current run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        Logger.eventTap.debug("Run loop source added to current run loop for common modes.")

        // Store references
        state.eventTap = tap
        state.runLoopSource = runLoopSource

        // Enable the tap (start listening)
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
             Logger.eventTap.info("Synchronous event tap created, added to run loop, and ENABLED.")
        } else {
             Logger.eventTap.error("Event tap created and added, but FAILED TO ENABLE.")
             // Clean up if enable failed
             destroyEventTap()
             determineStateAndSetupUI(context: "Event Tap Enable Failed")
        }
     }

    private func destroyEventTap() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard let tap = state.eventTap, let source = state.runLoopSource else {
             Logger.eventTap.debug("Destroy event tap skipped: No tap or source found in state.")
             return
        }
        Logger.eventTap.info("Destroying event tap...")

        // Check if tap is valid before trying to disable/invalidate
        // Note: CFMachPortIsValid might not be reliable after invalidation elsewhere. Rely on tapEnable state.
        if CGEvent.tapIsEnabled(tap: tap) {
             CGEvent.tapEnable(tap: tap, enable: false)
             Logger.eventTap.debug("Event tap disabled.")
        } else {
             Logger.eventTap.debug("Event tap was already disabled.")
        }

        // Remove source from run loop *before* invalidating the tap
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        Logger.eventTap.debug("Run loop source removed.")

        // Invalidate the tap port itself - releases resources associated with the tap
        // Note: According to docs, CFMachPortInvalidate does not release the userInfo pointer.
        // Since we used Unmanaged.passUnretained, this is correct behavior.
        // CFMachPortInvalidate(tap) // This might be redundant if tapEnable(false) cleans up enough, test carefully.
        // Let's keep invalidate for good measure if it doesn't cause issues.
        // Update: Let's try *without* explicit invalidate first, as tapEnable(false) and removing source *should* be enough.
        // Re-add CFMachPortInvalidate(tap) if issues arise with tap recreation.

        // Clear state references
        state.eventTap = nil
        state.runLoopSource = nil
        Logger.eventTap.info("Event tap destroyed and state references cleared.")
     }

    // MARK: - Helper Functions (Main Thread Safe unless noted)

    /// Safely gets the Input Source ID (e.g., "com.apple.keylayout.US")
    private func getInputSourceID(_ source: TISInputSource) -> String? {
        // Use TISGetInputSourceProperty which returns UnsafeMutableRawPointer?
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
             Logger.settings.warning("TISGetInputSourceProperty returned nil for kTISPropertyInputSourceID")
             return nil
        }
        // Cast the pointer to the expected CFType (CFString)
        let cfString = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        // Bridge to Swift String
        return cfString as String
    }

    /// Safely gets the Input Source Localized Name (e.g., "U.S.")
    private func getInputSourceLocalizedName(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            Logger.settings.warning("TISGetInputSourceProperty returned nil for kTISPropertyLocalizedName (ID: \(self.getInputSourceID(source) ?? "N/A"))")
             return nil
        }
        let cfString = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        return cfString as String
    }

    /// Human-readable name for a stored input source ID (falls back to the ID itself)
    private func displayName(forSourceID id: String?) -> String {
        guard let id = id else { return "?" }
        if let source = state.allSelectableSources.first(where: { self.getInputSourceID($0) == id }),
           let name = getInputSourceLocalizedName(source) {
            return name
        }
        return id
    }

    /// Helper to cleanly terminate the application.
    private func terminateApp() {
        Logger.app.critical("Terminating application NOW due to critical error!")
        // Ensure cleanup runs on main thread if called from elsewhere (though usually won't be)
        DispatchQueue.main.async {
            // Explicitly try to revert HID mapping one last time
            self.manageHidRemapping(enable: false, context: "Critical Terminate")
            self.destroyEventTap() // Clean up tap
            self.permissionCheckTimer?.invalidate() // Stop timer
            NSApplication.shared.terminate(self) // Terminate
        }
    }

} // End of AppDelegate class

// MARK: - View-Based Layout Row (keeps the menu open when clicked)

/// A menu item view for a keyboard layout row. Because the row is a view (not a
/// standard menu item with an action), clicking it does NOT dismiss the menu —
/// the user can try each layout live and see the checkmarks update in place.
final class LayoutMenuItemView: NSView {

    var onActivate: (() -> Void)?

    let sourceID: String
    private var titleText: String
    private var slot: Int          // 0 = not selected, 1 = Caps Lock, 2 = Fn/Globe
    private var rowEnabled: Bool

    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(title: String, sourceID: String, width: CGFloat) {
        self.titleText = title
        self.sourceID = sourceID
        self.slot = 0
        self.rowEnabled = true
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func preferredWidth(forTitle title: String) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        // Checkmark column + room for the trailing hot-key annotation + padding
        return max(260, ceil(titleWidth) + 150)
    }

    /// Updates the row's visual state in place (no menu rebuild needed).
    func refresh(slot newSlot: Int, enabled: Bool) {
        slot = newSlot
        rowEnabled = enabled
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        // .activeAlways so the hover highlight works while the menu is tracking.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard rowEnabled, wasPressed else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = rowEnabled && (isHovered || isPressed)

        if highlighted {
            let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1.5), xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.setFill()
            background.fill()
        }

        let font = NSFont.menuFont(ofSize: 0)
        let textColor: NSColor = !rowEnabled
            ? .disabledControlTextColor
            : (highlighted ? .alternateSelectedControlTextColor : .labelColor)
        let secondaryColor: NSColor = !rowEnabled
            ? .disabledControlTextColor
            : (highlighted ? textColor.withAlphaComponent(0.85) : .secondaryLabelColor)

        // Checkmark column (always reserved, so rows don't shift when selected)
        let checkmark = NSAttributedString(
            string: slot != 0 ? "✓" : " ",
            attributes: [.font: font, .foregroundColor: textColor])
        checkmark.draw(at: NSPoint(x: 14, y: (bounds.height - checkmark.size().height) / 2 + 0.5))

        // Layout name
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let titleString = NSAttributedString(
            string: titleText,
            attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph])

        let annotationText = slot == 1 ? "⇪ Caps Lock" : (slot == 2 ? "🌐 Fn" : nil)
        var annotationWidth: CGFloat = 0
        if let annotationText = annotationText {
            let annotation = NSAttributedString(string: annotationText,
                                                attributes: [.font: font, .foregroundColor: secondaryColor])
            annotationWidth = annotation.size().width
        }

        var titleRect = bounds
        titleRect.origin.x = 34
        titleRect.origin.y = (bounds.height - titleString.size().height) / 2 + 0.5
        titleRect.size.height = titleString.size().height
        titleRect.size.width = bounds.width - 34 - (annotationWidth > 0 ? annotationWidth + 24 : 16)
        titleString.draw(in: titleRect)

        // Trailing hot-key annotation for the selected layouts
        if let annotationText = annotationText {
            let annotation = NSAttributedString(string: annotationText,
                                                attributes: [.font: font, .foregroundColor: secondaryColor])
            annotation.draw(at: NSPoint(x: bounds.width - annotationWidth - 16,
                                        y: (bounds.height - annotation.size().height) / 2 + 0.5))
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appName: String {
        // Prefer display name, fallback to bundle name, then a default
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        object(forInfoDictionaryKey: "CFBundleName") as? String ??
        "CapsLockSwitcher"
    }
}

// MARK: - NSAlertPanel Helper (Example of checking for existing alerts)
// Note: This uses internal class name, might be fragile across OS versions. Use with caution.
extension NSApplication {
    var isAlertShowing: Bool {
        // Check if any window is an instance of the private NSAlertPanel class
        return self.windows.contains { $0.className == "NSAlertPanel" }
    }
}


// MARK: - main.swift Entry Point (Assumed to be separate)
/*
 // main.swift
 import Cocoa

 // Create the application instance
 let app = NSApplication.shared

 // Create the AppDelegate
 let delegate = AppDelegate()
 app.delegate = delegate

 // Start the main event loop
 app.run()

 */
