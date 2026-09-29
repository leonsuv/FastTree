import SwiftUI

@main struct FastTreeApp: App {
    @StateObject private var model = FastTreeModel()
    @AppStorage("FastTree.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            FastTreeMainView(model: model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .frame(minWidth: 1050, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.startScan(url) }
    }
}

struct FastTreeMainView: View {
    @ObservedObject var model: FastTreeModel

    var body: some View {
        VSplitView {
            HSplitView {
                ExplorerView(model: model)
                    .frame(minWidth: 650)
                FastTreeProductView(model: model)
                    .frame(minWidth: 330, idealWidth: 370, maxWidth: 480)
            }
            .frame(minHeight: 360)
            HSplitView {
                FastTreeTreemapView(model: model)
                    .frame(minWidth: 650)
                ScrollView {
                    FastTreeFileTypesView(model: model) { category in
                        model.selectedFileCategory = category
                    }
                    .padding(10)
                }
                .frame(minWidth: 330, idealWidth: 370, maxWidth: 480)
            }
            .frame(minHeight: 230)
        }
        .navigationTitle("FastTree")
    }
}
