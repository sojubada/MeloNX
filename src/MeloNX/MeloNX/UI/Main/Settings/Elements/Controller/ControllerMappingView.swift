//
//  ControllerMappingView.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import SwiftUI
import GameController
import Melo_Controller

private enum BindingTarget: Hashable {
    case button(String)
    case leftStickSource
    case rightStickSource
}

struct ControllerMappingView: View {
    let controller: BaseController
    let playerIndex: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ryujinxController: RyujinxController

    @State private var mapping: ControllerMapping = .standard()
    @State private var listening: BindingTarget?
    @State private var controllerType: ControllerType = .proController
    
    @State private var visualizer: StickVisualizer

    init(controller: BaseController, playerIndex: Int) {
        self.controller = controller
        self.playerIndex = playerIndex

        _visualizer = State(wrappedValue: StickVisualizer(controller: controller as? NativeController))
    }

    private var nativeController: NativeController? {
        controller as? NativeController
    }

    var body: some View {
        NavigationStack {
            List {
                hintSection

                controllerTypeSection

                stickPreviewSection

                if nativeController != nil {
                    Section("Left Joy-Con") {
                        ForEach(VirtualControllerButton.bindableLeft, id: \.id) { button in
                            bindingRow(for: button)
                        }
                    }

                    Section("Left Stick") {
                        stickSourceRow(target: .leftStickSource, stick: $mapping.leftStick)
                        bindingRow(for: .leftStick)
                        stickOptions($mapping.leftStick)
                    }

                    Section("Right Joy-Con") {
                        ForEach(VirtualControllerButton.bindableRight, id: \.id) { button in
                            bindingRow(for: button)
                        }
                    }

                    Section("Right Stick") {
                        stickSourceRow(target: .rightStickSource, stick: $mapping.rightStick)
                        bindingRow(for: .rightStick)
                        stickOptions($mapping.rightStick)
                    }

                    Section("Triggers") {
                        SliderRow(
                            String(localized: "Trigger Threshold"),
                            value: $mapping.triggerThreshold,
                            range: 0...1,
                            step: 0.05,
                            minLabel: String(localized: "Light"),
                            maxLabel: String(localized: "Firm"),
                            suffix: ""
                        )
                    }

                    motionSection
                }
            }
            .navigationTitle(nativeController == nil ? String(localized: "Controller") : String(localized: "Controller Mapping"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") { reset() }
                }
            }
            .onAppear {
                mapping = ControllerMappingStore.shared.mapping(for: controller)
                controllerType = controller.controllerType

                visualizer.start()
            }
            .onDisappear {
                visualizer.stop()

                stopListening()
            }
            .onChange(of: mapping) { _ in
                save()
            }
            .onChange(of: controllerType) { type in
                controller.controllerType = type

                Options.updateControllerType(index: playerIndex, to: type, options: &ryujinxController.settings)
            }
            .onChange(of: mapping.motionEnabled) { _ in
                nativeController?.refreshMotion()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var hintSection: some View {
        if nativeController != nil {
            Section {
                Text("Tap a binding, then press the button on \(controller.name) you want to use. Long-press a binding to pick one from a list.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var controllerTypeSection: some View {
        Section("Controller Type") {
            Picker(selection: $controllerType) {
                ForEach(ControllerType.allCases) { (type: ControllerType) in
                    Text(type.displayName).tag(type)
                }
            } label: {
                Text("Type")
            }
        }
    }

    
    @ViewBuilder
    private var motionSection: some View {
        if controller.nativeController?.motion != nil, !controller.usesDeviceHandlers {
            Section {
                Toggle("Controller Motion", isOn: $mapping.motionEnabled)
            } footer: {
                Text("Uses \(controller.name)'s own gyro and accelerometer. Turning it off can reduce input delay in games that do not use motion.")
            }
        }
    }

    @ViewBuilder
    private var stickPreviewSection: some View {
        if nativeController != nil {
            Section {
                HStack(spacing: 28) {
                    Spacer(minLength: 0)

                    StickPreview(
                        title: String(localized: "Left Stick"),
                        visualizer: visualizer,
                        mapping: mapping.leftStick
                    )

                    StickPreview(
                        title: String(localized: "Right Stick"),
                        visualizer: visualizer,
                        mapping: mapping.rightStick
                    )

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func bindingRow(for button: VirtualControllerButton) -> some View {
        let isListening = listening == .button(button.id)

        Button {
            startListening(.button(button.id))
        } label: {
            HStack {
                Image(systemName: button.iconName)
                    .foregroundColor(.accentColor)

                Text(button.switchDisplayName)
                    .foregroundColor(.primary)

                Spacer()

                Text(isListening ? String(localized: "Press any button…") : mapping[button].displayName)
                    .foregroundColor(isListening ? .accentColor : .secondary)
            }
        }
        .contextMenu {
            ForEach(PhysicalInput.assignable) { input in
                Button(input.displayName) {
                    stopListening()
                    mapping[button] = input
                }
            }
        }
    }

    @ViewBuilder
    private func stickSourceRow(target: BindingTarget, stick: Binding<StickMapping>) -> some View {
        let isListening = listening == target

        Button {
            startListening(target)
        } label: {
            HStack {
                Image(systemName: "l.joystick.tilt.left.fill")
                    .foregroundColor(.accentColor)

                Text("Stick")
                    .foregroundColor(.primary)

                Spacer()

                Text(isListening ? String(localized: "Move a stick…") : stick.wrappedValue.source.displayName)
                    .foregroundColor(isListening ? .accentColor : .secondary)
            }
        }
        .contextMenu {
            ForEach(PhysicalStick.allCases) { source in
                Button(source.displayName) {
                    stopListening()
                    stick.wrappedValue.source = source
                }
            }
        }
    }

    @ViewBuilder
    private func stickOptions(_ stick: Binding<StickMapping>) -> some View {
        Toggle("Invert X Axis", isOn: stick.invertX)
        Toggle("Invert Y Axis", isOn: stick.invertY)
        Toggle("Rotate 90°", isOn: stick.rotate90)

        SliderRow(
            String(localized: "Deadzone"),
            value: stick.deadzone,
            range: 0...1,
            step: 0.01,
            minLabel: String(localized: "None"),
            maxLabel: String(localized: "Max"),
            suffix: ""
        )

        SliderRow(
            String(localized: "Range"),
            value: stick.range,
            range: 0.1...2,
            step: 0.01,
            minLabel: String(localized: "Short"),
            maxLabel: String(localized: "Long"),
            suffix: ""
        )
    }

    private func startListening(_ target: BindingTarget) {
        guard let nativeController else { return }
        
        if listening == target {
            stopListening()
            return
        }

        listening = target

        nativeController.beginCapture { captured in
            defer { stopListening() }

            switch (target, captured) {
            case (.button(let id), .button(let input)):
                guard let button = VirtualControllerButton.bindable(id: id) else { return }

                mapping[button] = input

            case (.leftStickSource, .stick(let source)):
                mapping.leftStick.source = source

            case (.rightStickSource, .stick(let source)):
                mapping.rightStick.source = source

            default:
                break
            }
        }
    }

    private func stopListening() {
        listening = nil

        nativeController?.endCapture()
    }

    

    private func save() {
        ControllerMappingStore.shared.setMapping(mapping, for: controller)

        if listening == nil {
            nativeController?.applyMapping(mapping)
        }
    }

    private func reset() {
        stopListening()

        ControllerMappingStore.shared.resetMapping(for: controller)

        mapping = ControllerMappingStore.shared.mapping(for: controller)
    }
}
