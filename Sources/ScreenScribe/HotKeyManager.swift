import AppKit
import Carbon
import SwiftUI

enum GlobalAction: String, CaseIterable, Identifiable {
    case live, freeze, hide, snip, spotlight, lens, board
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "实时批注"
        case .freeze: return "冻结并批注"
        case .hide: return "显示 / 隐藏批注"
        case .snip: return "区域截图"
        case .spotlight: return "聚光灯"
        case .lens: return "放大镜"
        case .board: return "白板"
        }
    }
    var defaultKey: UInt32 { [18, 19, 29, 20, 21, 23, 22][Self.allCases.firstIndex(of: self)!] }
}

struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        let labels: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1"]
        return prefix + (labels[keyCode] ?? "Key \(keyCode)")
    }
    static func from(_ event: NSEvent) -> HotKeyBinding {
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        return HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: flags)
    }
}

@MainActor
final class HotKeyManager: ObservableObject {
    @Published var bindings: [String: HotKeyBinding] = [:]
    @Published var registrationError: String?
    var onAction: ((GlobalAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    init() {
        if let data = UserDefaults.standard.data(forKey: "hotkeys"), let values = try? JSONDecoder().decode([String: HotKeyBinding].self, from: data) { bindings = values }
        for action in GlobalAction.allCases where bindings[action.rawValue] == nil {
            bindings[action.rawValue] = HotKeyBinding(keyCode: action.defaultKey, modifiers: UInt32(controlKey | optionKey))
        }
    }
    func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                let index = Int(id.id) - 1
                if GlobalAction.allCases.indices.contains(index) { manager.onAction?(GlobalAction.allCases[index]) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        registrationError = nil
        for (index, action) in GlobalAction.allCases.enumerated() {
            guard let binding = bindings[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x53435242, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { registrationError = "\(action.title)快捷键已被其他应用占用，请重新设置。" }
        }
    }
    func set(_ binding: HotKeyBinding, for action: GlobalAction) {
        guard binding.modifiers != 0 || (96...122).contains(binding.keyCode) else { registrationError = "全局快捷键需要修饰键或功能键。"; return }
        guard !bindings.contains(where: { $0.key != action.rawValue && $0.value == binding }) else { registrationError = "此快捷键已分配给另一项功能。"; return }
        bindings[action.rawValue] = binding
        if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: "hotkeys") }
        register()
    }
    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    let onRecord: (HotKeyBinding) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) { if !button.recording { button.title = title } }
}

final class RecorderButton: NSButton {
    var recording = false
    var onRecord: ((HotKeyBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() { recording = true; title = "按下快捷键…"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        recording = false
        if event.keyCode != 53 { onRecord?(HotKeyBinding.from(event)) }
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
}
