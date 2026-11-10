import AppKit
import SwiftUI

// MARK: - Norton Commander palette

enum NC {
    static let blue = Color(red: 0.0, green: 0.0, blue: 0.66)
    static let cyan = Color(red: 0.33, green: 1.0, blue: 1.0)
    static let teal = Color(red: 0.0, green: 0.66, blue: 0.66)
    static let yellow = Color(red: 1.0, green: 1.0, blue: 0.33)
    static let white = Color.white
    static let gray = Color(red: 0.75, green: 0.75, blue: 0.75)
    static let green = Color(red: 0.33, green: 1.0, blue: 0.33)
    static let font = Font.custom("Menlo", size: 14)
    static let bold = Font.custom("Menlo-Bold", size: 14)

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH:mm"
        return f
    }()
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject var cmd: Commander
    @State private var monitor: Any?

    init(cmd: Commander) {
        self.cmd = cmd
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PanelView(cmd: cmd, index: 0)
                PanelView(cmd: cmd, index: 1)
            }
            KeyBar(cmd: cmd)
        }
        .background(NC.blue)
        .overlay {
            if let d = cmd.dialog {
                ZStack {
                    Color.black.opacity(0.35)
                    DialogView(cmd: cmd, dialog: d)
                }
            }
        }
        .overlay {
            if let a = cmd.alert {
                ZStack {
                    Color.black.opacity(0.35)
                    MessageBox(text: a) { cmd.alert = nil }
                }
            }
        }
        .onAppear {
            let c = cmd
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if c.isModal { return e }
                return c.handle(e) ? nil : e
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var cmd: Commander
    let index: Int

    var body: some View {
        let p = cmd.panels[index]
        let isActive = cmd.active == index
        VStack(spacing: 0) {
            Text(" " + cmd.title(index) + " ")
                .font(NC.font)
                .foregroundColor(isActive ? .black : NC.cyan)
                .background(isActive ? NC.cyan : NC.blue)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.top, 6)
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .center)
                Text("Type").frame(width: 44, alignment: .leading)
                Text("Size").frame(width: 92, alignment: .trailing)
                Text("Modified").frame(width: 130, alignment: .center)
            }
            .font(NC.font)
            .foregroundColor(NC.yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(p.items.enumerated()), id: \.offset) { i, it in
                            Row(item: it,
                                isCursor: isActive && i == p.cursor,
                                isTagged: p.tagged.contains(it.name))
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    cmd.click(index, i)
                                    cmd.enter()
                                }
                                .onTapGesture { cmd.click(index, i) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
                .onChange(of: cmd.panels[index].cursor) { _, new in
                    proxy.scrollTo(new)
                }
                .onChange(of: cmd.panels[index].location) { _, _ in
                    proxy.scrollTo(cmd.panels[index].cursor)
                }
            }

            Rectangle().fill(NC.cyan).frame(height: 1).padding(.horizontal, 10)
            Text(cmd.infoText(index))
                .font(NC.font)
                .foregroundColor(NC.cyan)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            Text(" " + cmd.freeText(index) + " ")
                .font(NC.font)
                .foregroundColor(NC.cyan)
                .padding(.bottom, 6)
        }
        .overlay(
            ZStack {
                Rectangle().stroke(NC.cyan, lineWidth: 1).padding(4)
                Rectangle().stroke(NC.cyan, lineWidth: 1).padding(7)
            }
            .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onTapGesture { cmd.active = index }
    }
}

struct Row: View {
    let item: Item
    let isCursor: Bool
    let isTagged: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(item.name + (item.locked ? "*" : ""))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.typeText).frame(width: 44, alignment: .leading)
            Text(sizeText).frame(width: 92, alignment: .trailing)
            Text(item.date.map { NC.dateFormat.string(from: $0) } ?? "").frame(width: 130, alignment: .trailing)
        }
        .font(isTagged ? NC.bold : NC.font)
        .lineLimit(1)
        .foregroundColor(fg)
        .background(isCursor ? NC.teal : Color.clear)
    }

    var sizeText: String {
        switch item.kind {
        case .up: return "UP--DIR"
        case .folder: return "SUB-DIR"
        default: return "\(item.size)"
        }
    }

    var fg: Color {
        if isTagged { return NC.yellow }
        if isCursor { return .black }
        switch item.kind {
        case .up, .folder: return NC.white
        case .image: return NC.green
        case .file: return NC.cyan
        }
    }
}

// MARK: - Key bar

struct KeyBar: View {
    @ObservedObject var cmd: Commander

    var body: some View {
        HStack(spacing: 6) {
            key("1", "Help") { cmd.dialog = .help }
            key("3", "View") { cmd.view() }
            key("5", "Copy") { cmd.copy() }
            key("6", "RenMov") { cmd.copy(move: true) }
            key("7", "Mkdir") { cmd.makeDirectory() }
            key("8", "Delete") { cmd.delete() }
            key("9", "NewImg") { cmd.newImage() }
            key("10", "Quit") { NSApp.terminate(nil) }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black)
    }

    func key(_ n: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(n).foregroundColor(.white)
                Text(label.padding(toLength: 6, withPad: " ", startingAt: 0))
                    .foregroundColor(.black)
                    .background(NC.teal)
            }
            .font(NC.font)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dialogs

struct NCBox<Content: View>: View {
    let title: String
    var background: Color = NC.gray
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 10) {
            Text(" \(title) ").font(NC.bold).foregroundColor(.black)
            content
        }
        .padding(18)
        .frame(minWidth: 420)
        .background(background)
        .overlay(
            ZStack {
                Rectangle().stroke(Color.black, lineWidth: 1).padding(5)
                Rectangle().stroke(Color.black, lineWidth: 1).padding(8)
            }
            .allowsHitTesting(false)
        )
        .shadow(radius: 10)
    }
}

struct NCButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(" \(label) ").font(NC.font).foregroundColor(.black).background(NC.teal)
        }
        .buttonStyle(.plain)
    }
}

struct DialogView: View {
    @ObservedObject var cmd: Commander
    let dialog: Dialog

    /// Closes the dialog, then runs the action (which may open another dialog).
    func run(_ f: @escaping () -> Void) {
        cmd.dialog = nil
        DispatchQueue.main.async(execute: f)
    }

    var body: some View {
        switch dialog {
        case let .confirm(title, message, ok, action, alt):
            NCBox(title: title) {
                Text(message).font(NC.font).foregroundColor(.black).multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    NCButton(label: ok) { run(action) }.keyboardShortcut(.defaultAction)
                    if let alt { NCButton(label: alt.label) { run(alt.action) } }
                    NCButton(label: "Cancel") { cmd.dialog = nil }.keyboardShortcut(.cancelAction)
                }
            }
        case let .input(title, prompt, text, action):
            InputDialog(cmd: cmd, title: title, prompt: prompt, initial: text, action: action)
        case let .overwrite(count, action):
            NCBox(title: "Overwrite") {
                Text("\(count) item(s) already exist in the destination.").font(NC.font).foregroundColor(.black)
                HStack(spacing: 14) {
                    NCButton(label: "Overwrite") { run { action(true) } }.keyboardShortcut(.defaultAction)
                    NCButton(label: "Skip existing") { run { action(false) } }
                    NCButton(label: "Cancel") { cmd.dialog = nil }.keyboardShortcut(.cancelAction)
                }
            }
        case let .newImage(action):
            NewImageDialog(cmd: cmd, action: action)
        case let .view(title, text):
            NCBox(title: title, background: NC.blue) {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(NC.font)
                        .foregroundColor(NC.cyan)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 480)
                NCButton(label: "Close") { cmd.dialog = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(30)
        case let .message(title, text):
            NCBox(title: title) {
                Text(text).font(NC.font).foregroundColor(.black).multilineTextAlignment(.leading)
                NCButton(label: "OK") { cmd.dialog = nil }
                    .keyboardShortcut(.defaultAction)
            }
        case .help:
            NCBox(title: "YANC for Mac – Help") {
                Text(helpText).font(NC.font).foregroundColor(.black).frame(alignment: .leading)
                NCButton(label: "OK") { cmd.dialog = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    var helpText: String {
        """
        Left panel / right panel: a Mac folder or the inside of a ProDOS
        or DOS 3.3 disk image (.po .hdv .2mg .dsk .do). Return opens it.

        Arrows        move           Tab           other panel
        PgUp/PgDn     page           Return        enter / open
        Home/End      first/last     Esc, Delete   go up
        Space         tag            + - *         tag all/none/invert
        Ctrl-R        re-read        Ctrl-U        swap panels
        Typing        jump to name

        F1/1 Help   F3/3 View   F5/5 Copy   F6/6 Move or rename
        F7/7 Mkdir  F8/8 Delete  F9/9 New blank disk image  F10/0 Quit

        File > New Disk Image (Cmd-N) creates a blank disk. To make a ProDOS disk
        bootable, open a bootable ProDOS disk in the other panel and choose
        File > Make Bootable (Cmd-B): it copies the boot blocks, PRODOS and a
        .SYSTEM program.

        Files copied to the Mac keep their ProDOS type in the name,
        e.g. PRODOS#FF2000 (CiderPress style). Files copied back use it.
        """
    }
}

struct InputDialog: View {
    @ObservedObject var cmd: Commander
    let title: String
    let prompt: String
    let action: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(cmd: Commander, title: String, prompt: String, initial: String, action: @escaping (String) -> Void) {
        self.cmd = cmd
        self.title = title
        self.prompt = prompt
        self.action = action
        _text = State(initialValue: initial)
    }

    var body: some View {
        NCBox(title: title) {
            Text(prompt).font(NC.font).foregroundColor(.black).frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: $text)
                .font(NC.font)
                .textFieldStyle(.plain)
                .padding(4)
                .background(NC.teal)
                .foregroundColor(.black)
                .focused($focused)
                .onSubmit(ok)
            HStack(spacing: 14) {
                NCButton(label: "OK", action: ok).keyboardShortcut(.defaultAction)
                NCButton(label: "Cancel") { cmd.dialog = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { focused = true }
    }

    func ok() {
        let t = text.trimmingCharacters(in: .whitespaces)
        cmd.dialog = nil
        DispatchQueue.main.async { action(t) }
    }
}

struct NewImageDialog: View {
    @ObservedObject var cmd: Commander
    let action: (String, Int) -> Void
    @State private var name = "NEWDISK"
    @State private var blocks = 1600
    @FocusState private var focused: Bool

    var body: some View {
        NCBox(title: "New blank disk image") {
            HStack {
                Text("Volume name:").font(NC.font).foregroundColor(.black)
                TextField("", text: $name)
                    .font(NC.font)
                    .textFieldStyle(.plain)
                    .padding(4)
                    .background(NC.teal)
                    .foregroundColor(.black)
                    .focused($focused)
            }
            Picker("Size:", selection: $blocks) {
                Text("140K (5.25\")").tag(280)
                Text("800K (3.5\")").tag(1600)
                Text("32 MB (hard disk)").tag(65535)
                Text("140K DOS 3.3 (.dsk)").tag(-1)
            }
            .pickerStyle(.radioGroup)
            .font(NC.font)
            .foregroundColor(.black)
            Text("New disks are empty. Use File > Make Bootable to add a ProDOS boot loader.")
                .font(NC.font).foregroundColor(.black)
            HStack(spacing: 14) {
                NCButton(label: "Create") {
                    let n = name, b = blocks
                    cmd.dialog = nil
                    DispatchQueue.main.async { action(n, b) }
                }
                .keyboardShortcut(.defaultAction)
                NCButton(label: "Cancel") { cmd.dialog = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { focused = true }
    }
}

struct MessageBox: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        NCBox(title: "Error", background: Color(red: 0.66, green: 0, blue: 0)) {
            Text(text).font(NC.font).foregroundColor(.white).multilineTextAlignment(.leading)
            NCButton(label: "OK", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
    }
}
