import AppKit
import ApplicationServices
import SwiftUI
import UshotCore

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case capture
    case output
    case editor
    case colorPicker
    case shortcuts
    case history
    case advanced

    var id: String { rawValue }

    var title: String {
        let key: String
        switch self {
        case .general: key = "General"
        case .capture: key = "Capture"
        case .output: key = "Output"
        case .editor: key = "Editor"
        case .colorPicker: key = "Color Picker"
        case .shortcuts: key = "Shortcuts"
        case .history: key = "History"
        case .advanced: key = "Advanced"
        }
        return NSLocalizedString(key, comment: "Settings section title")
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "viewfinder"
        case .output: return "square.and.arrow.down"
        case .editor: return "pencil.and.outline"
        case .colorPicker: return "eyedropper"
        case .shortcuts: return "keyboard"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var accessibilityIdentifier: String {
        "settings.sidebar.\(rawValue)"
    }
}

@MainActor
final class SettingsAlertModel: ObservableObject {
    @Published var message: String?

    func present(_ error: Error) {
        message = error.localizedDescription
    }

    func present(message: String) {
        self.message = message
    }
}

struct SettingsRootView: View {
    let environment: AppEnvironment
    @ObservedObject var selectionModel: SettingsSelectionModel
    @ObservedObject private var store: SettingsStore
    @StateObject private var alerts = SettingsAlertModel()

    init(environment: AppEnvironment, selectionModel: SettingsSelectionModel) {
        self.environment = environment
        self.selectionModel = selectionModel
        self._store = ObservedObject(wrappedValue: environment.settingsStore)
    }

    var body: some View {
        // Fixed sidebar (not NavigationSplitView): the system split-view
        // "Hide Sidebar" control lands in the wrong titlebar place inside a
        // hosted NSWindow, and the restored layout is also wrong. Settings
        // should keep the section list always visible in both languages.
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectionModel.selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
                    .accessibilityIdentifier(section.accessibilityIdentifier)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: Self.sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityIdentifier("settings.sidebar")

            Divider()

            settingsDetail(for: selectionModel.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: Self.sidebarWidth + 600, minHeight: 520)
        .environment(\.locale, store.settings.advanced.language.locale)
        .alert(
            "Ushot",
            isPresented: Binding(
                get: { alerts.message != nil },
                set: { if !$0 { alerts.message = nil } }
            ),
            actions: { Button("OK") { alerts.message = nil } },
            message: { Text(alerts.message ?? "") }
        )
    }

    private static let sidebarWidth: CGFloat = 188

    @ViewBuilder
    private func settingsDetail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(environment: environment, alerts: alerts)
        case .capture:
            CaptureSettingsView(environment: environment, alerts: alerts)
        case .output:
            OutputSettingsView(store: environment.settingsStore, alerts: alerts)
        case .editor:
            EditorSettingsView(store: environment.settingsStore, alerts: alerts)
        case .colorPicker:
            ColorPickerSettingsView(store: environment.settingsStore, alerts: alerts)
        case .shortcuts:
            ShortcutsSettingsView(environment: environment, alerts: alerts)
        case .history:
            HistorySettingsView(environment: environment, alerts: alerts)
        case .advanced:
            AdvancedSettingsView(environment: environment, alerts: alerts)
        }
    }
}

private struct GeneralSettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var alerts: SettingsAlertModel
    @ObservedObject private var store: SettingsStore

    init(environment: AppEnvironment, alerts: SettingsAlertModel) {
        self.environment = environment
        self.alerts = alerts
        self._store = ObservedObject(wrappedValue: environment.settingsStore)
    }

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Show menu bar icon", isOn: persistedBinding(
                    store: store,
                    keyPath: \AppSettings.general.showsMenuBarIcon,
                    alerts: alerts
                ))
                Toggle("Show Dock icon", isOn: persistedBinding(
                    store: store,
                    keyPath: \AppSettings.general.showsDockIcon,
                    alerts: alerts
                ))
                .accessibilityIdentifier("settings.showDockIcon")
                Toggle("Launch at login", isOn: Binding(
                    get: { store.settings.general.launchesAtLogin },
                    set: updateLaunchAtLogin
                ))
                Picker("At launch", selection: persistedBinding(
                    store: store,
                    keyPath: \AppSettings.general.startupBehavior,
                    alerts: alerts
                )) {
                    ForEach(StartupBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }

                if !store.settings.general.showsMenuBarIcon && !store.settings.general.showsDockIcon {
                    Label(
                        "The app remains reachable through its registered global shortcuts.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Login Item Status") {
                LabeledContent("Status", value: environment.launchAtLoginManager.status.title)
                if environment.launchAtLoginManager.status == .requiresApproval {
                    Button("Open Login Items Settings") {
                        environment.launchAtLoginManager.openSystemSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let previous = store.settings.general.launchesAtLogin
        do {
            try environment.launchAtLoginManager.setEnabled(enabled)
            do {
                try store.update(\AppSettings.general.launchesAtLogin, to: enabled)
            } catch {
                try environment.launchAtLoginManager.setEnabled(previous)
                throw error
            }
        } catch {
            alerts.present(error)
        }
    }
}

private struct CaptureSettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var alerts: SettingsAlertModel
    @ObservedObject private var store: SettingsStore
    @Environment(\.displayScale) private var displayScale
    @State private var permissionStatus: CapturePermissionStatus = .notAuthorized
    @State private var accessibilityAuthorized = AXIsProcessTrusted()

    init(environment: AppEnvironment, alerts: SettingsAlertModel) {
        self.environment = environment
        self.alerts = alerts
        self._store = ObservedObject(wrappedValue: environment.settingsStore)
    }

    var body: some View {
        Form {
            Section("Screen Recording Permission") {
                LabeledContent(
                    "Status",
                    value: NSLocalizedString(
                        permissionStatus == .authorized ? "Authorized" : "Not Authorized",
                        comment: "Screen recording permission status"
                    )
                )
                Text("Ushot needs screen recording permission only to read pixels for screenshots. It does not record, upload, or analyze your screen.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") { requestPermission() }
                    Button("Open Privacy Settings") { openPrivacySettings() }
                    Button("Check Again") { refreshPermission() }
                }
            }

            InterfaceElementRecognitionSettingsSection(
                isEnabled: persistedBinding(
                    store: store,
                    keyPath: \AppSettings.capture.recognizesInterfaceElements,
                    alerts: alerts
                ),
                isAccessibilityAuthorized: accessibilityAuthorized,
                onRequestAccessibility: requestAccessibilityPermission,
                onOpenAccessibilitySettings: openAccessibilitySettings,
                onRefreshAccessibility: refreshAccessibilityPermission
            )

            Section("After Capture") {
                settingToggle("Automatically pin window and display captures", \AppSettings.capture.presentsPinnedShot)
                settingToggle("Show quick toolbar on automatic pinned shots", \AppSettings.capture.showsQuickToolbar)
                settingToggle("Copy automatically", \AppSettings.capture.automaticallyCopies)
                settingToggle("Save automatically", \AppSettings.capture.automaticallySaves)
                settingToggle("Open Canvas Editor automatically", \AppSettings.capture.automaticallyOpensCanvasEditor)
            }

            Section("Capture Options") {
                settingToggle("Include pointer", \AppSettings.capture.capturesCursor)
                settingToggle("Keep window shadow", \AppSettings.capture.includesWindowShadow)
            }

            Section("Region Corner Radius") {
                HStack(alignment: .center, spacing: 12) {
                    RoundedRectangle(
                        cornerRadius: regionCornerRadiusPreviewValue,
                        style: .continuous
                    )
                    .stroke(.primary, lineWidth: 1.5)
                    .frame(width: 42, height: 28)
                    .accessibilityHidden(true)

                    TextField(
                        "Region corner radius",
                        value: regionCornerRadiusBinding,
                        format: .number.precision(.fractionLength(0...1))
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .accessibilityIdentifier("settings.capture.regionCornerRadius")

                    AnnotationMeasurementUnitPicker(
                        title: "Region corner radius unit",
                        selection: store.settings.capture.regionCornerRadiusUnit,
                        onSelect: setRegionCornerRadiusUnit,
                        accessibilityIdentifier: "settings.capture.regionCornerRadiusUnit"
                    )
                }
                Text("Applies to region selection chrome and Copy / Save / Pin output. Set to 0 for square corners. Window and display captures are unchanged.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await updatePermissionStatus()
            refreshAccessibilityPermission()
        }
    }

    private var regionCornerRadiusBinding: Binding<Double> {
        Binding(
            get: { store.settings.capture.regionCornerRadius },
            set: { value in
                let unit = store.settings.capture.regionCornerRadiusUnit
                let range = EditorMeasurementLimits.displayedCornerRadiusRange(
                    unit: unit,
                    backingScale: displayScale
                )
                guard value.isFinite, range.contains(value) else {
                    alerts.present(message: String(localized:
                        "The region corner radius is outside the supported range for the selected unit.",
                        comment: "Region corner-radius validation error"
                    ))
                    return
                }
                do {
                    try store.update(\AppSettings.capture.regionCornerRadius, to: value)
                } catch {
                    alerts.present(error)
                }
            }
        )
    }

    private var regionCornerRadiusPreviewValue: CGFloat {
        let logicalRadius = store.settings.capture.logicalRegionCornerRadius(
            backingScale: displayScale
        )
        return min(12, max(0, logicalRadius))
    }

    private func setRegionCornerRadiusUnit(_ unit: AnnotationMeasurementUnit) {
        let previousValue = store.settings.capture.regionCornerRadius
        let previousUnit = store.settings.capture.regionCornerRadiusUnit
        do {
            try store.update { settings in
                settings.capture.setRegionCornerRadiusUnit(unit, backingScale: displayScale)
            }
            AppLog.lifecycle.notice(
                "Changed region corner-radius unit: fromValue=\(previousValue, privacy: .public), fromUnit=\(previousUnit.rawValue, privacy: .public), toValue=\(self.store.settings.capture.regionCornerRadius, privacy: .public), toUnit=\(unit.rawValue, privacy: .public), referenceScale=\(self.displayScale, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func settingToggle(
        _ title: LocalizedStringKey,
        _ keyPath: WritableKeyPath<AppSettings, Bool>
    ) -> some View {
        Toggle(title, isOn: persistedBinding(store: store, keyPath: keyPath, alerts: alerts))
    }

    private func requestPermission() {
        Task { permissionStatus = await environment.permissionChecker.requestAccess() }
    }

    private func refreshPermission() {
        Task { await updatePermissionStatus() }
    }

    private func updatePermissionStatus() async {
        permissionStatus = await environment.permissionChecker.authorizationStatus()
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            alerts.present(message: NSLocalizedString(
                "The Screen Recording privacy settings URL is invalid.",
                comment: "Invalid System Settings URL error"
            ))
            return
        }
        if !NSWorkspace.shared.open(url) {
            alerts.present(message: NSLocalizedString(
                "System Settings could not be opened.",
                comment: "System Settings open error"
            ))
        }
    }

    private func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refreshAccessibilityPermission()
    }

    private func refreshAccessibilityPermission() {
        accessibilityAuthorized = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            alerts.present(message: NSLocalizedString(
                "The Accessibility privacy settings URL is invalid.",
                comment: "Invalid Accessibility settings URL error"
            ))
            return
        }
        if !NSWorkspace.shared.open(url) {
            alerts.present(message: NSLocalizedString(
                "System Settings could not be opened.",
                comment: "System Settings open error"
            ))
        }
    }
}

private struct InterfaceElementRecognitionSettingsSection: View {
    @Binding var isEnabled: Bool
    let isAccessibilityAuthorized: Bool
    let onRequestAccessibility: () -> Void
    let onOpenAccessibilitySettings: () -> Void
    let onRefreshAccessibility: () -> Void

    var body: some View {
        Section("Smart Region Snapping") {
            Toggle("Recognize windows and interface elements", isOn: $isEnabled)
                .accessibilityIdentifier("settings.capture.interfaceElementSnapping")
            LabeledContent("Accessibility status") {
                if isAccessibilityAuthorized {
                    Text("Authorized")
                } else {
                    Text("Not Authorized")
                }
            }
            Text("Window snapping works without extra permission. Accessibility access adds controls such as buttons, text fields, sidebars, and panels.")
                .foregroundStyle(.secondary)
            Text("During capture, use Option-Up/Down or Option-scroll to choose a control's parent or child level.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Request Accessibility Access", action: onRequestAccessibility)
                Button("Open Accessibility Settings", action: onOpenAccessibilitySettings)
                Button("Check Again", action: onRefreshAccessibility)
            }
        }
    }
}

private struct OutputSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var alerts: SettingsAlertModel

    var body: some View {
        Form {
            Picker("Default format", selection: persistedBinding(
                store: store,
                keyPath: \AppSettings.output.format,
                alerts: alerts
            )) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            TextField("Filename template", text: persistedBinding(
                store: store,
                keyPath: \AppSettings.output.filenameTemplate,
                alerts: alerts
            ))
            TextField("Default directory", text: Binding(
                get: { store.settings.output.defaultDirectoryPath ?? "" },
                set: { value in
                    do {
                        try store.update(
                            \AppSettings.output.defaultDirectoryPath,
                            to: value.isEmpty ? nil : value
                        )
                    } catch { alerts.present(error) }
                }
            ))
            Toggle("Preserve color profile", isOn: persistedBinding(
                store: store,
                keyPath: \AppSettings.output.preservesColorProfile,
                alerts: alerts
            ))
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var alerts: SettingsAlertModel
    @Environment(\.displayScale) private var displayScale
    @State private var selectedTool: AnnotationTool = .text
    @State private var presentsPaletteManager = false
    @State private var confirmsEditorReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AnnotationPaletteSettingsSection(
                    availableColorHexes: store.settings.editor.availableColorHexes,
                    selection: store.settings.editor.defaultColorHex,
                    onSelect: setDefaultColor,
                    onManage: { presentsPaletteManager = true }
                )

                Divider()

                AnnotationToolDefaultsSettingsSection(
                    editor: store.settings.editor,
                    selectedTool: $selectedTool,
                    onSetColor: setToolDefaultColor,
                    onSetTextFont: setDefaultTextFont,
                    onSetFontSize: setDefaultFontSize,
                    onSetFontSizeUnit: setDefaultFontSizeUnit,
                    onSetLineWidth: setDefaultLineWidth,
                    onSetLineWidthUnit: setDefaultLineWidthUnit,
                    onSetRectangleCornerRadiusUnit: setDefaultRectangleCornerRadiusUnit,
                    rectangleCornerRadius: rectangleCornerRadiusBinding
                )

                AnnotationEffectPreviewSection(
                    editor: store.settings.editor,
                    selectedTool: selectedTool
                )

                EditorSettingsFooter(
                    onReset: { confirmsEditorReset = true }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $presentsPaletteManager) {
            AnnotationPaletteManagerSheet(
                editor: store.settings.editor,
                onAdd: addToolbarColor,
                onRemove: removeToolbarColor,
                onReplaceWithDefaults: replaceToolbarColorsWithFactoryDefaults,
                onRestoreDefaultsKeepingCustomColors: restoreToolbarColorsKeepingCustomColors,
                onColorConversionFailure: {
                    alerts.present(message: String(localized:
                        "The selected color could not be converted to sRGB.",
                        comment: "Annotation palette color conversion error"
                    ))
                }
            )
        }
        .confirmationDialog(
            "Restore editor defaults?",
            isPresented: $confirmsEditorReset,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive, action: resetEditorDefaults)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Toolbar colors and every annotation-tool default will return to their original values.")
        }
    }

    private func setDefaultColor(_ hex: String) {
        do {
            try store.update(\AppSettings.editor.defaultColorHex, to: hex)
        } catch {
            alerts.present(error)
        }
    }

    private func setToolDefaultColor(
        _ hex: String,
        for tool: AnnotationTool
    ) {
        do {
            try store.update { settings in
                switch tool {
                case .text:
                    settings.editor.defaultTextColorHex = hex
                case .rectangle:
                    settings.editor.defaultRectangleColorHex = hex
                case .ellipse:
                    settings.editor.defaultEllipseColorHex = hex
                default:
                    preconditionFailure("Unsupported settings default tool: \(tool.rawValue)")
                }
            }
        } catch {
            alerts.present(error)
        }
    }

    private func setDefaultTextFont(_ fontName: String?) {
        do {
            try store.update(\AppSettings.editor.defaultTextFontName, to: fontName)
        } catch {
            alerts.present(error)
        }
    }

    private func setDefaultFontSize(_ value: Double) {
        let unit = store.settings.editor.defaultFontSizeUnit
        let range = EditorMeasurementLimits.displayedFontSizeRange(
            unit: unit,
            backingScale: displayScale
        )
        guard value.isFinite, range.contains(value) else {
            alerts.present(message: String(localized:
                "The font size is outside the supported range for the selected unit.",
                comment: "Annotation font-size validation error"
            ))
            return
        }
        do {
            try store.update(\AppSettings.editor.defaultFontSize, to: value)
        } catch {
            alerts.present(error)
        }
    }

    private func setDefaultFontSizeUnit(_ unit: AnnotationMeasurementUnit) {
        let previousUnit = store.settings.editor.defaultFontSizeUnit
        let previousValue = store.settings.editor.defaultFontSize
        guard previousUnit != unit else { return }
        do {
            try store.update { settings in
                settings.editor.setDefaultFontSizeUnit(
                    unit,
                    backingScale: displayScale
                )
            }
            AppLog.capture.notice(
                "Changed default font-size unit: fromValue=\(previousValue, privacy: .public), fromUnit=\(previousUnit.rawValue, privacy: .public), toValue=\(self.store.settings.editor.defaultFontSize, privacy: .public), toUnit=\(unit.rawValue, privacy: .public), referenceScale=\(self.displayScale, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func setDefaultLineWidth(_ value: Double) {
        let unit = store.settings.editor.defaultLineWidthUnit
        let range = EditorMeasurementLimits.displayedLineWidthRange(
            unit: unit,
            backingScale: displayScale
        )
        guard value.isFinite, range.contains(value) else {
            alerts.present(message: String(localized:
                "The line width is outside the supported range for the selected unit.",
                comment: "Annotation line-width validation error"
            ))
            return
        }
        do {
            try store.update(\AppSettings.editor.defaultLineWidth, to: value)
        } catch {
            alerts.present(error)
        }
    }

    private func setDefaultLineWidthUnit(_ unit: AnnotationMeasurementUnit) {
        let previousUnit = store.settings.editor.defaultLineWidthUnit
        let previousValue = store.settings.editor.defaultLineWidth
        guard previousUnit != unit else { return }
        do {
            try store.update { settings in
                settings.editor.setDefaultLineWidthUnit(
                    unit,
                    backingScale: displayScale
                )
            }
            AppLog.capture.notice(
                "Changed default line-width unit: fromValue=\(previousValue, privacy: .public), fromUnit=\(previousUnit.rawValue, privacy: .public), toValue=\(self.store.settings.editor.defaultLineWidth, privacy: .public), toUnit=\(unit.rawValue, privacy: .public), referenceScale=\(self.displayScale, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func setDefaultRectangleCornerRadiusUnit(
        _ unit: AnnotationMeasurementUnit
    ) {
        let previousUnit = store.settings.editor.defaultRectangleCornerRadiusUnit
        let previousValue = store.settings.editor.defaultRectangleCornerRadius
        guard previousUnit != unit else { return }
        do {
            try store.update { settings in
                settings.editor.setDefaultRectangleCornerRadiusUnit(
                    unit,
                    backingScale: displayScale
                )
            }
            AppLog.capture.notice(
                "Changed default rectangle-radius unit: fromValue=\(previousValue, privacy: .public), fromUnit=\(previousUnit.rawValue, privacy: .public), toValue=\(self.store.settings.editor.defaultRectangleCornerRadius, privacy: .public), toUnit=\(unit.rawValue, privacy: .public), referenceScale=\(self.displayScale, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func addToolbarColor(_ hex: String) {
        do {
            var editor = store.settings.editor
            try editor.addToolbarColor(hex)
            try store.update(\AppSettings.editor, to: editor)
            AppLog.capture.notice(
                "Added annotation toolbar color: color=\(hex, privacy: .public), count=\(editor.toolbarColorHexes.count, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func removeToolbarColor(_ hex: String, replacementHex: String) -> Bool {
        do {
            var editor = store.settings.editor
            try editor.removeToolbarColor(hex, replacingUsesWith: replacementHex)
            try store.update(\AppSettings.editor, to: editor)
            AppLog.capture.notice(
                "Removed annotation toolbar color: color=\(hex, privacy: .public), replacement=\(replacementHex, privacy: .public), count=\(editor.toolbarColorHexes.count, privacy: .public)"
            )
            return true
        } catch {
            alerts.present(error)
            return false
        }
    }

    private func replaceToolbarColorsWithFactoryDefaults() {
        do {
            var editor = store.settings.editor
            let previousColors = editor.toolbarColorHexes
            editor.restoreFactoryToolbarColors()
            try store.update(\AppSettings.editor, to: editor)
            AppLog.capture.notice(
                "Restored factory annotation toolbar colors: mode=replace, previousCount=\(previousColors.count, privacy: .public), resultCount=\(editor.toolbarColorHexes.count, privacy: .public), removedCustomCount=\(previousColors.filter { !AnnotationColorPalette.factoryDefaultHexColors.contains($0) }.count, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func restoreToolbarColorsKeepingCustomColors() {
        do {
            var editor = store.settings.editor
            let previousColors = editor.toolbarColorHexes
            editor.restoreFactoryToolbarColorsPreservingCustomColors()
            let previousColorSet = Set(previousColors)
            let orderChanged = editor.toolbarColorHexes.filter(previousColorSet.contains) != previousColors
            try store.update(\AppSettings.editor, to: editor)
            AppLog.capture.notice(
                "Restored factory annotation toolbar colors: mode=keep-custom, previousCount=\(previousColors.count, privacy: .public), resultCount=\(editor.toolbarColorHexes.count, privacy: .public), addedFactoryCount=\(editor.toolbarColorHexes.count - previousColors.count, privacy: .public), orderChanged=\(orderChanged, privacy: .public)"
            )
        } catch {
            alerts.present(error)
        }
    }

    private func resetEditorDefaults() {
        do {
            try store.update(\AppSettings.editor, to: EditorSettings())
            selectedTool = .text
        } catch {
            alerts.present(error)
        }
    }

    private var rectangleCornerRadiusBinding: Binding<Double> {
        Binding(
            get: { store.settings.editor.defaultRectangleCornerRadius },
            set: { value in
                let unit = store.settings.editor.defaultRectangleCornerRadiusUnit
                let range = EditorMeasurementLimits.displayedCornerRadiusRange(
                    unit: unit,
                    backingScale: displayScale
                )
                guard value.isFinite, range.contains(value) else {
                    alerts.present(message: String(localized:
                        "The rectangle corner radius is outside the supported range for the selected unit.",
                        comment: "Rectangle corner-radius validation error"
                    ))
                    return
                }
                do {
                    try store.update(\AppSettings.editor.defaultRectangleCornerRadius, to: value)
                } catch {
                    alerts.present(error)
                }
            }
        )
    }
}

private enum EditorMeasurementLimits {
    private static let logicalFontSize: ClosedRange<Double> = 4...96
    private static let logicalLineWidth: ClosedRange<Double> = 0.5...24
    private static let logicalCornerRadius: ClosedRange<Double> = 0...100

    static func displayedFontSizeRange(
        unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) -> ClosedRange<Double> {
        displayedRange(logicalFontSize, unit: unit, backingScale: backingScale)
    }

    static func displayedLineWidthRange(
        unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) -> ClosedRange<Double> {
        displayedRange(logicalLineWidth, unit: unit, backingScale: backingScale)
    }

    static func displayedCornerRadiusRange(
        unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) -> ClosedRange<Double> {
        displayedRange(logicalCornerRadius, unit: unit, backingScale: backingScale)
    }

    static func displayedStep(
        unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) -> Double {
        switch unit {
        case .pixels: 1
        case .points: 1 / Double(backingScale)
        }
    }

    private static func displayedRange(
        _ logicalRange: ClosedRange<Double>,
        unit: AnnotationMeasurementUnit,
        backingScale: CGFloat
    ) -> ClosedRange<Double> {
        let lowerBound = unit.displayedValue(
            forLogicalPoints: CGFloat(logicalRange.lowerBound),
            backingScale: backingScale
        )
        let upperBound = unit.displayedValue(
            forLogicalPoints: CGFloat(logicalRange.upperBound),
            backingScale: backingScale
        )
        return Double(lowerBound)...Double(upperBound)
    }
}

private struct AnnotationPaletteSettingsSection: View {
    let availableColorHexes: [String]
    let selection: String
    let onSelect: (String) -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Toolbar Colors")
                .font(.headline)

            HStack(spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(availableColorHexes, id: \.self) { hex in
                            ToolbarColorButton(
                                hex: hex,
                                isSelected: hex == selection,
                                action: { onSelect(hex) }
                            )
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: 250)

                AnnotationColorMenu(
                    colors: availableColorHexes,
                    selection: selection,
                    onSelect: onSelect
                )
                .accessibilityIdentifier("settings.editor.defaultAnnotationColor")

                Spacer(minLength: 8)

                Button("Manage Palette…", action: onManage)
                    .accessibilityIdentifier("settings.editor.managePalette")
            }

            Text("The toolbar starts with six colors, but every color can be added, removed, or replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AnnotationToolDefaultsSettingsSection: View {
    let editor: EditorSettings
    @Binding var selectedTool: AnnotationTool
    let onSetColor: (String, AnnotationTool) -> Void
    let onSetTextFont: (String?) -> Void
    let onSetFontSize: (Double) -> Void
    let onSetFontSizeUnit: (AnnotationMeasurementUnit) -> Void
    let onSetLineWidth: (Double) -> Void
    let onSetLineWidthUnit: (AnnotationMeasurementUnit) -> Void
    let onSetRectangleCornerRadiusUnit: (AnnotationMeasurementUnit) -> Void
    let rectangleCornerRadius: Binding<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tool Default Styles")
                .font(.headline)

            HStack(spacing: 0) {
                AnnotationToolDefaultsSidebar(
                    editor: editor,
                    selectedTool: $selectedTool
                )
                .frame(width: 190)

                Divider()

                AnnotationToolDefaultsDetail(
                    editor: editor,
                    selectedTool: selectedTool,
                    onSetColor: { onSetColor($0, selectedTool) },
                    onUseGeneralColor: {
                        onSetColor(editor.defaultColorHex, selectedTool)
                    },
                    onSetTextFont: onSetTextFont,
                    onSetFontSize: onSetFontSize,
                    onSetFontSizeUnit: onSetFontSizeUnit,
                    onSetLineWidth: onSetLineWidth,
                    onSetLineWidthUnit: onSetLineWidthUnit,
                    onSetRectangleCornerRadiusUnit: onSetRectangleCornerRadiusUnit,
                    rectangleCornerRadius: rectangleCornerRadius
                )
            }
            .frame(height: 158)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}

private struct ToolbarColorButton: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AnnotationColorSwatch(hex: hex, diameter: 24)
                .padding(4)
                .background(
                    Circle()
                        .stroke(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("\(AnnotationColorPresentation.name(for: hex))  \(hex)")
        .accessibilityLabel("\(AnnotationColorPresentation.name(for: hex)), \(hex)")
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
        .accessibilityIdentifier("settings.editor.palette.\(hex.dropFirst())")
    }
}

private struct AnnotationToolDefaultsSidebar: View {
    private static let tools: [AnnotationTool] = [.text, .rectangle, .ellipse]

    let editor: EditorSettings
    @Binding var selectedTool: AnnotationTool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.tools) { tool in
                AnnotationToolDefaultRow(
                    tool: tool,
                    colorHex: editor.defaultColorHex(for: tool),
                    detail: detail(for: tool),
                    isSelected: selectedTool == tool,
                    action: { selectedTool = tool }
                )
                if tool != Self.tools.last {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
    }

    private func detail(for tool: AnnotationTool) -> String {
        switch tool {
        case .text:
            return AnnotationFontCatalog.displayName(for: editor.defaultTextFontName)
        case .rectangle:
            let width = formattedMeasurement(editor.defaultLineWidth)
            let radius = formattedMeasurement(editor.defaultRectangleCornerRadius)
            return "\(width) \(editor.defaultLineWidthUnit.rawValue) · \(String(localized: "Radius", comment: "Rectangle default summary")) \(radius) \(editor.defaultRectangleCornerRadiusUnit.rawValue)"
        case .ellipse:
            return "\(formattedMeasurement(editor.defaultLineWidth)) \(editor.defaultLineWidthUnit.rawValue)"
        default:
            preconditionFailure("Unsupported settings default tool: \(tool.rawValue)")
        }
    }
}

private struct AnnotationToolDefaultRow: View {
    let tool: AnnotationTool
    let colorHex: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                toolIcon
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .fontWeight(isSelected ? .semibold : .regular)
                    HStack(spacing: 5) {
                        AnnotationColorSwatch(hex: colorHex, diameter: 10)
                        ViewThatFits(in: .horizontal) {
                            Text("\(AnnotationColorPresentation.name(for: colorHex)) · \(detail)")
                            Text(detail)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 51, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tool.title), \(AnnotationColorPresentation.name(for: colorHex)), \(detail)")
        .accessibilityIdentifier("settings.editor.tool.\(tool.rawValue)")
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
    }

    @ViewBuilder
    private var toolIcon: some View {
        switch tool {
        case .text:
            Text(verbatim: "T")
                .font(.system(size: 27, weight: .light, design: .serif))
        case .rectangle:
            Image(systemName: "rectangle")
                .font(.title2)
        case .ellipse:
            Image(systemName: "circle")
                .font(.title2)
        default:
            preconditionFailure("Unsupported settings default tool: \(tool.rawValue)")
        }
    }

    private var iconColor: Color {
        isSelected
            ? Color.accentColor
            : AnnotationColorPresentation.color(for: colorHex)
    }
}

private struct AnnotationToolDefaultsDetail: View {
    let editor: EditorSettings
    let selectedTool: AnnotationTool
    let onSetColor: (String) -> Void
    let onUseGeneralColor: () -> Void
    let onSetTextFont: (String?) -> Void
    let onSetFontSize: (Double) -> Void
    let onSetFontSizeUnit: (AnnotationMeasurementUnit) -> Void
    let onSetLineWidth: (Double) -> Void
    let onSetLineWidthUnit: (AnnotationMeasurementUnit) -> Void
    let onSetRectangleCornerRadiusUnit: (AnnotationMeasurementUnit) -> Void
    let rectangleCornerRadius: Binding<Double>

    var body: some View {
        VStack(spacing: 0) {
            EditorDetailRow(title: "Color") {
                AnnotationColorMenu(
                    colors: editor.availableColorHexes,
                    selection: editor.defaultColorHex(for: selectedTool),
                    onSelect: onSetColor
                )
                .accessibilityIdentifier(colorAccessibilityIdentifier)

                Button(action: onUseGeneralColor) {
                    Label("Use General", systemImage: "link")
                }
                .disabled(editor.defaultColorHex(for: selectedTool) == editor.defaultColorHex)
                .help("Use the current general annotation color for this tool")
            }

            Divider()
                .padding(.leading, 18)

            switch selectedTool {
            case .text:
                TextToolDefaultDetail(
                    fontName: editor.defaultTextFontName,
                    fontSize: editor.defaultFontSize,
                    fontSizeUnit: editor.defaultFontSizeUnit,
                    onSetFont: onSetTextFont,
                    onSetFontSize: onSetFontSize,
                    onSetFontSizeUnit: onSetFontSizeUnit
                )
            case .rectangle:
                ShapeToolDefaultDetail(
                    lineWidth: editor.defaultLineWidth,
                    lineWidthUnit: editor.defaultLineWidthUnit,
                    rectangleCornerRadius: rectangleCornerRadius,
                    rectangleCornerRadiusUnit: editor.defaultRectangleCornerRadiusUnit,
                    onSetLineWidth: onSetLineWidth,
                    onSetLineWidthUnit: onSetLineWidthUnit,
                    onSetRectangleCornerRadiusUnit: onSetRectangleCornerRadiusUnit
                )
            case .ellipse:
                ShapeToolDefaultDetail(
                    lineWidth: editor.defaultLineWidth,
                    lineWidthUnit: editor.defaultLineWidthUnit,
                    rectangleCornerRadius: nil,
                    rectangleCornerRadiusUnit: editor.defaultRectangleCornerRadiusUnit,
                    onSetLineWidth: onSetLineWidth,
                    onSetLineWidthUnit: onSetLineWidthUnit,
                    onSetRectangleCornerRadiusUnit: onSetRectangleCornerRadiusUnit
                )
            default:
                preconditionFailure("Unsupported settings default tool: \(selectedTool.rawValue)")
            }
        }
    }

    private var colorAccessibilityIdentifier: String {
        switch selectedTool {
        case .text: return "settings.editor.defaultTextColor"
        case .rectangle: return "settings.editor.defaultRectangleColor"
        case .ellipse: return "settings.editor.defaultEllipseColor"
        default:
            preconditionFailure("Unsupported settings default tool: \(selectedTool.rawValue)")
        }
    }
}

private struct TextToolDefaultDetail: View {
    let fontName: String?
    let fontSize: Double
    let fontSizeUnit: AnnotationMeasurementUnit
    let onSetFont: (String?) -> Void
    let onSetFontSize: (Double) -> Void
    let onSetFontSizeUnit: (AnnotationMeasurementUnit) -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            EditorDetailRow(title: "Font") {
                AnnotationFontPickerButton(
                    selection: fontName,
                    onSelect: onSetFont
                )
            }

            Divider()
                .padding(.leading, 18)

            EditorDetailRow(title: "Font size") {
                Stepper(
                    value: Binding(get: { fontSize }, set: onSetFontSize),
                    in: EditorMeasurementLimits.displayedFontSizeRange(
                        unit: fontSizeUnit,
                        backingScale: displayScale
                    ),
                    step: EditorMeasurementLimits.displayedStep(
                        unit: fontSizeUnit,
                        backingScale: displayScale
                    )
                ) {
                    Text(fontSize, format: .number.precision(.fractionLength(0...1)))
                        .monospacedDigit()
                        .frame(minWidth: 42, alignment: .trailing)
                }
                .accessibilityIdentifier("settings.editor.defaultFontSize")

                AnnotationMeasurementUnitPicker(
                    title: "Font size unit",
                    selection: fontSizeUnit,
                    onSelect: onSetFontSizeUnit,
                    accessibilityIdentifier: "settings.editor.defaultFontSizeUnit"
                )
            }
        }
    }
}

private struct ShapeToolDefaultDetail: View {
    let lineWidth: Double
    let lineWidthUnit: AnnotationMeasurementUnit
    let rectangleCornerRadius: Binding<Double>?
    let rectangleCornerRadiusUnit: AnnotationMeasurementUnit
    let onSetLineWidth: (Double) -> Void
    let onSetLineWidthUnit: (AnnotationMeasurementUnit) -> Void
    let onSetRectangleCornerRadiusUnit: (AnnotationMeasurementUnit) -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            EditorDetailRow(title: "Line width") {
                Capsule()
                    .fill(.primary)
                    .frame(width: 54, height: linePreviewWidth)
                    .accessibilityHidden(true)

                Stepper(
                    value: Binding(get: { lineWidth }, set: onSetLineWidth),
                    in: EditorMeasurementLimits.displayedLineWidthRange(
                        unit: lineWidthUnit,
                        backingScale: displayScale
                    ),
                    step: EditorMeasurementLimits.displayedStep(
                        unit: lineWidthUnit,
                        backingScale: displayScale
                    )
                ) {
                    Text(lineWidth, format: .number.precision(.fractionLength(0...1)))
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .accessibilityIdentifier("settings.editor.defaultLineWidth")

                AnnotationMeasurementUnitPicker(
                    title: "Line width unit",
                    selection: lineWidthUnit,
                    onSelect: onSetLineWidthUnit,
                    accessibilityIdentifier: "settings.editor.defaultLineWidthUnit"
                )
            }

            Divider()
                .padding(.leading, 18)

            if let rectangleCornerRadius {
                EditorDetailRow(title: "Rectangle corner radius") {
                    RoundedRectangle(cornerRadius: cornerRadiusPreviewValue)
                        .stroke(.primary, lineWidth: 1.5)
                        .frame(width: 42, height: 24)
                        .accessibilityHidden(true)

                    TextField(
                        "Rectangle corner radius",
                        value: rectangleCornerRadius,
                        format: .number.precision(.fractionLength(0...1))
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityIdentifier("settings.editor.rectangleCornerRadius")

                    AnnotationMeasurementUnitPicker(
                        title: "Rectangle corner radius unit",
                        selection: rectangleCornerRadiusUnit,
                        onSelect: onSetRectangleCornerRadiusUnit,
                        accessibilityIdentifier: "settings.editor.rectangleCornerRadiusUnit"
                    )
                }
            } else {
                Color.clear
                    .frame(height: 52)
                    .accessibilityHidden(true)
            }
        }
    }

    private var linePreviewWidth: CGFloat {
        let logicalWidth = lineWidthUnit.logicalPoints(
            fromDisplayedValue: lineWidth,
            backingScale: displayScale
        )
        return max(1, min(8, logicalWidth))
    }

    private var cornerRadiusPreviewValue: CGFloat {
        guard let rectangleCornerRadius else { return 0 }
        let logicalRadius = rectangleCornerRadiusUnit.logicalPoints(
            fromDisplayedValue: rectangleCornerRadius.wrappedValue,
            backingScale: displayScale
        )
        return min(8, logicalRadius)
    }
}

private struct AnnotationMeasurementUnitPicker: View {
    let title: LocalizedStringKey
    let selection: AnnotationMeasurementUnit
    let onSelect: (AnnotationMeasurementUnit) -> Void
    let accessibilityIdentifier: String

    var body: some View {
        Picker(
            title,
            selection: Binding(get: { selection }, set: onSelect)
        ) {
            ForEach(AnnotationMeasurementUnit.allCases, id: \.self) { unit in
                Text(verbatim: unit.rawValue).tag(unit)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 82)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct EditorDetailRow<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 72, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
    }
}

private struct AnnotationColorMenu: View {
    let colors: [String]
    let selection: String
    let onSelect: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                AnnotationColorSwatch(hex: selection, diameter: 18)
                Text(AnnotationColorPresentation.name(for: selection))
                    .lineLimit(1)
                Text(verbatim: selection)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: 190, height: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Annotation color")
        .accessibilityValue("\(AnnotationColorPresentation.name(for: selection)), \(selection)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(colors, id: \.self) { hex in
                            Button {
                                onSelect(hex)
                                isPresented = false
                            } label: {
                                HStack(spacing: 9) {
                                    AnnotationColorSwatch(hex: hex, diameter: 16)
                                    Text(AnnotationColorPresentation.name(for: hex))
                                        .frame(width: 54, alignment: .leading)
                                    Text(verbatim: hex)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .opacity(hex == selection ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(hex)
                            .accessibilityAddTraits(hex == selection ? .isSelected : [])
                            .accessibilityIdentifier("settings.editor.colorOption.\(hex.dropFirst())")
                        }
                    }
                    .padding(6)
                }
                .frame(
                    width: 246,
                    height: CGFloat(min(colors.count, 8) * 32 + 12)
                )
                .onAppear {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }
}

private struct AnnotationFontPickerButton: View {
    let selection: String?
    let onSelect: (String?) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(AnnotationFontCatalog.displayName(for: selection))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "Aa 中文")
                    .font(AnnotationFontCatalog.font(for: selection, size: 13))
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("settings.editor.defaultTextFont")
        .accessibilityValue(AnnotationFontCatalog.displayName(for: selection))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AnnotationFontSearchPopover(
                selection: selection,
                onSelect: { fontName in
                    onSelect(fontName)
                    isPresented = false
                }
            )
        }
    }
}

private struct AnnotationFontSearchPopover: View {
    let selection: String?
    let onSelect: (String?) -> Void
    @State private var searchText = ""
    @State private var visibleOptions = AnnotationFontCatalog.options

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Font")
                .font(.headline)

            TextField("Search Fonts", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleOptions) { option in
                        Button {
                            onSelect(option.fontName)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                    Text(verbatim: "Aa 中文")
                                        .font(AnnotationFontCatalog.font(
                                            for: option.fontName,
                                            size: 13
                                        ))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if option.fontName == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, height: 330)
        .onChange(of: searchText) { _, value in
            visibleOptions = AnnotationFontCatalog.search(value)
        }
    }
}

private struct AnnotationEffectPreviewSection: View {
    let editor: EditorSettings
    let selectedTool: AnnotationTool
    @State private var appearance: EditorPreviewAppearance = .light
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect Preview")
                .font(.headline)

            ZStack {
                HStack(spacing: 0) {
                    Color.white
                    Color.black.opacity(0.78)
                }

                AnnotationEffectPreviewContent(
                    editor: editor,
                    selectedTool: selectedTool,
                    backingScale: displayScale
                )
                .environment(\.colorScheme, appearance.colorScheme)

                VStack {
                    HStack {
                        Spacer()
                        Picker("Preview background", selection: $appearance) {
                            ForEach(EditorPreviewAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 118)
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .accessibilityIdentifier("settings.editor.effectPreview")
        }
    }
}

private struct AnnotationEffectPreviewContent: View {
    let editor: EditorSettings
    let selectedTool: AnnotationTool
    let backingScale: CGFloat

    var body: some View {
        switch selectedTool {
        case .text:
            Text(verbatim: "示例文字  Aa")
                .font(AnnotationFontCatalog.font(
                    for: editor.defaultTextFontName,
                    size: min(48, max(4, editor.logicalDefaultFontSize(backingScale: backingScale)))
                ))
                .fontWeight(.medium)
                .foregroundStyle(AnnotationColorPresentation.color(
                    for: editor.defaultTextColorHex
                ))
        case .rectangle:
            RoundedRectangle(cornerRadius: editor.logicalDefaultRectangleCornerRadius(
                backingScale: backingScale
            ))
                .stroke(
                    AnnotationColorPresentation.color(for: editor.defaultRectangleColorHex),
                    lineWidth: previewLineWidth
                )
                .frame(width: 160, height: 42)
        case .ellipse:
            Ellipse()
                .stroke(
                    AnnotationColorPresentation.color(for: editor.defaultEllipseColorHex),
                    lineWidth: previewLineWidth
                )
                .frame(width: 160, height: 42)
        default:
            preconditionFailure("Unsupported settings default tool: \(selectedTool.rawValue)")
        }
    }

    private var previewLineWidth: CGFloat {
        min(
            8,
            max(
                0.5,
                editor.defaultLineWidthUnit.logicalPoints(
                    fromDisplayedValue: editor.defaultLineWidth,
                    backingScale: backingScale
                )
            )
        )
    }
}

private enum EditorPreviewAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct EditorSettingsFooter: View {
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button("Restore Editor Defaults…", action: onReset)
                .accessibilityIdentifier("settings.editor.restoreDefaults")
            Text("Changes apply immediately. Before a toolbar color is removed, you choose its replacement.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct AnnotationPaletteManagerSheet: View {
    let editor: EditorSettings
    let onAdd: (String) -> Void
    let onRemove: (String, String) -> Bool
    let onReplaceWithDefaults: () -> Void
    let onRestoreDefaultsKeepingCustomColors: () -> Void
    let onColorConversionFailure: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newColor = Color(nsColor: .systemPink)
    @State private var newColorHex = "#FF2D55"
    @State private var pendingRemoval: PendingPaletteRemoval?
    @State private var confirmsPaletteRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Manage Toolbar Palette")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack {
                Text("Toolbar Colors")
                    .font(.headline)
                Spacer()
                Button("Restore Default Colors…") {
                    confirmsPaletteRestore = true
                }
                .disabled(
                    editor.toolbarColorHexes
                        == AnnotationColorPalette.factoryDefaultHexColors
                )
                .accessibilityIdentifier("settings.editor.restorePaletteDefaults")
            }

            LazyVStack(spacing: 0) {
                ForEach(editor.toolbarColorHexes, id: \.self) { hex in
                    PaletteManagerColorRow(
                        hex: hex,
                        canRemove: editor.toolbarColorHexes.count > 1,
                        onRemove: {
                            pendingRemoval = PendingPaletteRemoval(hex: hex)
                        }
                    )
                    if hex != editor.toolbarColorHexes.last {
                        Divider()
                            .padding(.leading, 30)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Color")
                    .font(.headline)
                HStack(spacing: 10) {
                    ColorPicker("New color", selection: $newColor, supportsOpacity: false)
                        .onChange(of: newColor) { _, color in
                            guard let hex = AnnotationColorPresentation.hex(for: color) else {
                                onColorConversionFailure()
                                return
                            }
                            newColorHex = hex
                        }

                    TextField("HEX", text: $newColorHex)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 112)
                        .onSubmit(applyTypedColor)
                        .accessibilityIdentifier("settings.editor.newPaletteHex")

                    Button("Add Color", action: addColor)
                        .disabled(!canAddColor)
                        .accessibilityIdentifier("settings.editor.addAnnotationColor")
                }

                Text(colorValidationMessage)
                    .font(.caption)
                    .foregroundStyle(canAddColor ? Color.secondary : Color.red)
            }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 420, idealHeight: 500)
        .sheet(item: $pendingRemoval) { pending in
            PaletteColorReplacementSheet(
                editor: editor,
                removingHex: pending.hex,
                onReplaceAndRemove: { replacementHex in
                    onRemove(pending.hex, replacementHex)
                }
            )
        }
        .confirmationDialog(
            "Restore the default toolbar colors?",
            isPresented: $confirmsPaletteRestore,
            titleVisibility: .visible
        ) {
            Button("Restore and Keep Custom Colors") {
                onRestoreDefaultsKeepingCustomColors()
            }
            .disabled(keepingCustomColorsWouldNotChangePalette)
            .accessibilityIdentifier("settings.editor.confirmPaletteRestoreKeepingCustom")
            Button("Replace with Default Colors", role: .destructive) {
                onReplaceWithDefaults()
            }
            .accessibilityIdentifier("settings.editor.confirmPaletteRestore")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replacing removes custom palette colors and redirects affected tool defaults to red. Keeping custom colors restores the factory colors in their standard order, then preserves custom colors. Existing annotations are unchanged.")
        }
    }

    private var keepingCustomColorsWouldNotChangePalette: Bool {
        let factoryColors = AnnotationColorPalette.factoryDefaultHexColors
        let factoryColorSet = Set(factoryColors)
        let customColors = editor.toolbarColorHexes.filter {
            !factoryColorSet.contains($0)
        }
        return editor.toolbarColorHexes == factoryColors + customColors
    }

    private var normalizedNewColorHex: String? {
        AnnotationColorPalette.normalizedHex(newColorHex)
    }

    private var canAddColor: Bool {
        guard let normalizedNewColorHex else { return false }
        return !editor.availableColorHexes.contains(normalizedNewColorHex)
    }

    private var colorValidationMessage: LocalizedStringResource {
        guard let normalizedNewColorHex else {
            return "Enter a color in #RRGGBB format."
        }
        if editor.availableColorHexes.contains(normalizedNewColorHex) {
            return "This color is already in the toolbar palette."
        }
        return "The swatch and HEX value will appear together in the toolbar menu."
    }

    private func applyTypedColor() {
        guard let normalizedNewColorHex,
              let color = AnnotationColorPalette.color(fromHex: normalizedNewColorHex)
        else { return }
        newColorHex = normalizedNewColorHex
        newColor = Color(
            .sRGB,
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }

    private func addColor() {
        guard let normalizedNewColorHex, canAddColor else { return }
        onAdd(normalizedNewColorHex)
    }
}

private struct PaletteManagerColorRow: View {
    let hex: String
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            AnnotationColorSwatch(hex: hex, diameter: 18)
            Text(AnnotationColorPresentation.name(for: hex))
            Text(verbatim: hex)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Remove", role: .destructive, action: onRemove)
                .disabled(!canRemove)
                .accessibilityLabel(removeAccessibilityLabel)
                .accessibilityIdentifier("settings.editor.removePaletteColor.\(hex.dropFirst())")
        }
        .frame(maxWidth: .infinity, minHeight: 38)
    }

    private var removeAccessibilityLabel: String {
        String(
            format: NSLocalizedString(
                "Remove color %@, %@",
                comment: "Toolbar-palette remove-button accessibility label"
            ),
            AnnotationColorPresentation.name(for: hex),
            hex
        )
    }
}

private struct PendingPaletteRemoval: Identifiable {
    let hex: String
    var id: String { hex }
}

private struct PaletteColorReplacementSheet: View {
    let editor: EditorSettings
    let removingHex: String
    let onReplaceAndRemove: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var replacementHex: String

    init(
        editor: EditorSettings,
        removingHex: String,
        onReplaceAndRemove: @escaping (String) -> Bool
    ) {
        self.editor = editor
        self.removingHex = removingHex
        self.onReplaceAndRemove = onReplaceAndRemove
        guard let initialReplacement = editor.availableColorHexes.first(where: {
            $0 != removingHex
        }) else {
            preconditionFailure("Removing a toolbar color requires another configured color.")
        }
        self._replacementHex = State(initialValue: initialReplacement)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose Replacement Color")
                    .font(.title3.weight(.semibold))

                Text("Any tool currently using \(removingHex) will use the replacement. Existing annotations will not change.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                EditorDetailRow(title: "Replacement") {
                    AnnotationColorMenu(
                        colors: editor.availableColorHexes.filter { $0 != removingHex },
                        selection: replacementHex,
                        onSelect: { replacementHex = $0 }
                    )
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Replace and Remove", role: .destructive) {
                        if onReplaceAndRemove(replacementHex) {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 220, idealHeight: 260)
    }
}

private struct AnnotationFontOption: Identifiable {
    let title: String
    let fontName: String?

    var id: String { fontName ?? "__system__" }
}

@MainActor
private enum AnnotationFontCatalog {
    static let options: [AnnotationFontOption] = {
        let manager = NSFontManager.shared
        let installed = manager.availableFontFamilies.compactMap { family -> AnnotationFontOption? in
            guard let font = manager.font(
                withFamily: family,
                traits: [],
                weight: 5,
                size: 18
            ) else { return nil }
            return AnnotationFontOption(title: family, fontName: font.fontName)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return [AnnotationFontOption(
            title: String(localized: "System Font", comment: "Default annotation font option"),
            fontName: nil
        )] + installed
    }()

    static func displayName(for fontName: String?) -> String {
        guard let fontName else { return options[0].title }
        return options.first(where: { $0.fontName == fontName })?.title ?? fontName
    }

    static func search(_ query: String) -> [AnnotationFontOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    static func font(for fontName: String?, size: CGFloat) -> Font {
        guard let fontName else { return .system(size: size) }
        return .custom(fontName, size: size)
    }
}

private struct AnnotationColorSwatch: View {
    let hex: String
    var diameter: CGFloat = 15
    var showsCheckmark = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AnnotationColorPresentation.color(for: hex))
                .overlay(Circle().stroke(.primary.opacity(0.22), lineWidth: 1))
            if showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.system(size: max(6, diameter * 0.48), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

private enum AnnotationColorPresentation {
    static func color(for hex: String) -> Color {
        guard let color = AnnotationColorPalette.color(fromHex: hex) else {
            preconditionFailure("Settings supplied an invalid annotation color: \(hex)")
        }
        return Color(
            .sRGB,
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }

    static func name(for hex: String) -> String {
        switch AnnotationColorPalette.normalizedHex(hex) {
        case "#FF3B30": String(localized: "Red", comment: "Annotation color name")
        case "#FF9500": String(localized: "Orange", comment: "Annotation color name")
        case "#FFCC00": String(localized: "Yellow", comment: "Annotation color name")
        case "#34C759": String(localized: "Green", comment: "Annotation color name")
        case "#007AFF": String(localized: "Blue", comment: "Annotation color name")
        case "#AF52DE": String(localized: "Purple", comment: "Annotation color name")
        default: String(localized: "Custom", comment: "Annotation color name")
        }
    }

    static func hex(for color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return AnnotationColorPalette.hexString(for: RGBAColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent
        ))
    }
}

private func formattedMeasurement(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
}

private struct ColorPickerSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var alerts: SettingsAlertModel

    var body: some View {
        Form {
            Picker("Color space", selection: persistedBinding(
                store: store,
                keyPath: \AppSettings.colorPicker.colorSpace,
                alerts: alerts
            )) {
                ForEach(ColorSpacePreference.allCases, id: \.self) { space in
                    Text(space.title).tag(space)
                }
            }
            Picker("Copy format", selection: persistedBinding(
                store: store,
                keyPath: \AppSettings.colorPicker.copyFormat,
                alerts: alerts
            )) {
                ForEach(ColorCopyFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var alerts: SettingsAlertModel
    @ObservedObject private var store: SettingsStore
    @State private var confirmsClear = false

    init(environment: AppEnvironment, alerts: SettingsAlertModel) {
        self.environment = environment
        self.alerts = alerts
        self._store = ObservedObject(wrappedValue: environment.settingsStore)
    }

    var body: some View {
        Form {
            Toggle("Enable screenshot history", isOn: persistedBinding(
                store: store,
                keyPath: \AppSettings.history.isEnabled,
                alerts: alerts
            ))
            Stepper(
                "Keep for \(store.settings.history.retentionDays) days",
                value: persistedBinding(store: store, keyPath: \AppSettings.history.retentionDays, alerts: alerts),
                in: 1...365
            )
            Stepper(
                "Maximum \(store.settings.history.maximumItemCount) items",
                value: persistedBinding(store: store, keyPath: \AppSettings.history.maximumItemCount, alerts: alerts),
                in: 10...5_000,
                step: 10
            )
            Text("History is off by default. Turning it off stops new records and does not delete existing files.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open History Folder") { openHistoryFolder() }
                Button("Clear History", role: .destructive) { confirmsClear = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Clear all screenshot history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved image and editable annotation document will be permanently removed.")
        }
    }

    private func openHistoryFolder() {
        do {
            let directory = environment.historyStore.rootDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else {
                throw ScreenshotAppError.historyPersistenceFailed(
                    description: "Finder could not open the History directory."
                )
            }
        } catch {
            alerts.present(error)
        }
    }

    private func clearHistory() {
        Task {
            do {
                try await environment.historyStore.clear()
            } catch {
                alerts.present(error)
            }
        }
    }
}

private struct AdvancedSettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var alerts: SettingsAlertModel
    @ObservedObject private var store: SettingsStore

    init(environment: AppEnvironment, alerts: SettingsAlertModel) {
        self.environment = environment
        self.alerts = alerts
        self._store = ObservedObject(wrappedValue: environment.settingsStore)
    }

    var body: some View {
        Form {
            Section("Language") {
                Picker(
                    "Language",
                    selection: Binding(
                        get: { store.settings.advanced.language },
                        set: { setLanguage($0) }
                    )
                ) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        Text(language.nativeDisplayName).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.advanced.language")
                Text("Ushot uses this language for its interface. Changing language restarts Ushot so every menu and window updates.")
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Picker("Log level", selection: persistedBinding(
                    store: store,
                    keyPath: \AppSettings.advanced.logLevel,
                    alerts: alerts
                )) {
                    ForEach(AppLogLevel.allCases, id: \.self) { level in
                        Text(NSLocalizedString(level.rawValue.capitalized, comment: "Log level")).tag(level)
                    }
                }

                if let loadError = store.loadError {
                    Label(loadError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Open Data Directory") { openDataDirectory() }
                    Button("Reset Settings", role: .destructive) { resetSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLanguage(_ language: AppLanguagePreference) {
        let previous = store.settings.advanced.language
        guard language != previous else { return }
        do {
            try store.update(\AppSettings.advanced.language, to: language)
            AppLanguagePreference.apply(language)
            AppLog.lifecycle.notice(
                "Changed in-app language preference: from=\(previous.rawValue, privacy: .public), to=\(language.rawValue, privacy: .public); relaunching"
            )
            relaunchApplication()
        } catch {
            alerts.present(error)
        }
    }

    /// Restarts Ushot after a language change.
    ///
    /// `NSWorkspace.openApplication` on a running app only activates the existing
    /// instance; terminating afterward exits without a replacement (looks like a
    /// crash). Schedule a detached helper that waits until this PID exits, then
    /// opens a new instance with `open -n`.
    private func relaunchApplication() {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var environment = ProcessInfo.processInfo.environment
        environment["USHOT_RELAUNCH_APP"] = appPath
        environment["USHOT_RELAUNCH_PID"] = String(pid)
        process.environment = environment
        // nohup + background so the waiter is not killed when this process exits.
        // Env vars expand inside the inner bash (single-quoted body is not
        // expanded by the outer shell).
        process.arguments = [
            "-c",
            #"""
            /usr/bin/nohup /bin/bash -c '
              while /bin/kill -0 "$USHOT_RELAUNCH_PID" 2>/dev/null; do
                /bin/sleep 0.1
              done
              /bin/sleep 0.2
              /usr/bin/open -n "$USHOT_RELAUNCH_APP"
            ' >/dev/null 2>&1 &
            """#
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ScreenshotAppError.captureFailed(
                    description: "Relaunch helper exited with status \(process.terminationStatus)."
                )
            }
            AppLog.lifecycle.notice(
                "Scheduled post-exit relaunch after language change: pid=\(pid, privacy: .public), path=\(appPath, privacy: .public)"
            )
        } catch {
            AppLog.lifecycle.error(
                "Failed to schedule Ushot relaunch after language change: \(error.localizedDescription, privacy: .public)"
            )
            alerts.present(message: String(localized:
                "Ushot could not restart after changing the language. Quit and open Ushot again to apply it.",
                comment: "Language change relaunch failure"
            ))
            return
        }
        NSApp.terminate(nil)
    }

    private func openDataDirectory() {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = root.appendingPathComponent(
                ProductIdentity.applicationSupportDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            alerts.present(error)
        }
    }

    private func resetSettings() {
        let previous = store.settings
        do {
            try environment.hotKeyManager.register(AppSettings.defaults.shortcuts.assignments)
            if previous.general.launchesAtLogin {
                try environment.launchAtLoginManager.setEnabled(false)
            }
            do {
                try store.reset()
            } catch {
                try environment.hotKeyManager.register(previous.shortcuts.assignments)
                if previous.general.launchesAtLogin {
                    try environment.launchAtLoginManager.setEnabled(true)
                }
                throw error
            }
            let language = store.settings.advanced.language
            if language != previous.advanced.language {
                AppLanguagePreference.apply(language)
                AppLog.lifecycle.notice(
                    "Reset settings changed language: from=\(previous.advanced.language.rawValue, privacy: .public), to=\(language.rawValue, privacy: .public); relaunching"
                )
                relaunchApplication()
            }
        } catch {
            alerts.present(error)
        }
    }
}

private func persistedBinding<Value>(
    store: SettingsStore,
    keyPath: WritableKeyPath<AppSettings, Value>,
    alerts: SettingsAlertModel
) -> Binding<Value> {
    Binding(
        get: { @MainActor in store.settings[keyPath: keyPath] },
        set: { @MainActor value in
            do { try store.update(keyPath, to: value) }
            catch { alerts.present(error) }
        }
    )
}
