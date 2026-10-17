import SakuraCordModels
import SwiftUI

struct ServerRailPlaygroundView: View {
    @State private var state = ServerRailPlaygroundState()

    var body: some View {
        HStack(spacing: 0) {
            ServerRailView(
                sidebarWidth: 300,
                items: state.presentation.items,
                directMessages: state.presentation.directMessages,
                home: state.presentation.home,
                selectHome: { state.selectGuild(nil) },
                selectDirectMessage: state.selectDM,
                selectGuild: state.selectGuild,
                joinServer: { if let guild = state.guilds.first(where: { !state.visibleGuildIDs.contains($0.id) }) { state.toggleGuild(guild.id) } },
                moveItems: state.move,
                combineGuilds: state.combine,
                contextMenuActions: ServerRailContextMenuActions(
                    markRead: { _ in }, mute: { _, _ in }, unmute: { _ in },
                    setNotificationLevel: { _, _ in }, setNotificationToggle: { _, _, _ in },
                    leaveServer: { state.toggleGuild($0.id) }
                )
            )
            .padding(.top, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server Rail Playground").font(.largeTitle.bold())
                        Text("Offline · Click controls to change the rail. Drag icons to reorder or make folders.")
                            .foregroundStyle(.secondary)
                    }
                    ServerRailPlaygroundControls(state: state)
                    ServerRailPlaygroundCatalog(state: state)
                    HStack {
                        Spacer()
                        Button("Clear Rail", action: state.clear)
                        Button("Reset Playground", action: state.reset)
                    }
                    if let error = state.iconError {
                        Text("Could not create icons: \(error)").foregroundStyle(.red)
                    }
                }
                .padding(36)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .interfaceScaleRoot()
        .navigationTitle("Server Rail Playground")
    }
}

private struct ServerRailPlaygroundControls: View {
    @Bindable var state: ServerRailPlaygroundState

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            GroupBox("Servers") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Insert at", selection: $state.insertionPosition) {
                        ForEach(ServerRailPlaygroundState.InsertionPosition.allCases, id: \.self) { position in
                            Text(position.rawValue).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button("Add 3", action: state.addServers)
                            .disabled(state.visibleGuildIDs.count == state.guilds.count)
                        Button("Remove 3", action: state.removeServers)
                            .disabled(state.layout.isEmpty)
                    }
                    Button("Remove Selected Server") {
                        if let id = state.selectedGuildID { state.toggleGuild(id) }
                    }
                    .disabled(state.selectedGuildID == nil)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Unread DMs") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Show All DMs") { state.setDMs(Set(state.conversations.map(\.id))) }
                    Button("Dismiss All DMs") { state.setDMs([]) }
                    Button("Read Selected DM") {
                        if let id = state.selectedChannelID { state.toggleDM(id) }
                    }
                    .disabled(state.selectedChannelID == nil)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Folders") {
                VStack(alignment: .leading, spacing: 12) {
                    Button(state.hasFolder ? "Remove Color Club" : "Add Color Club", action: state.toggleFolder)
                    Button("Add Server to Folder", action: state.addToFolder)
                        .disabled(state.visibleGuildIDs.count == state.guilds.count)
                    Button("Remove Server from Folder", action: state.removeFromFolder)
                        .disabled(!state.layout.contains { if case .folder = $0 { true } else { false } })
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
    }
}

private struct ServerRailPlaygroundCatalog: View {
    let state: ServerRailPlaygroundState
    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Servers").font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(state.guilds) { guild in
                        ServerRailPlaygroundTile(name: guild.name, iconURL: guild.iconURL,
                                                 isVisible: state.visibleGuildIDs.contains(guild.id)) {
                            state.toggleGuild(guild.id)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Direct Messages").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                    ForEach(state.conversations.sorted { $0.id < $1.id }) { channel in
                        HStack(spacing: 6) {
                            ServerRailPlaygroundTile(name: channel.name, iconURL: channel.iconURL,
                                                     isVisible: state.unreadDMs.contains(channel.id)) {
                                state.toggleDM(channel.id)
                            }
                            Button("Receive Message", systemImage: "bubble.left.and.bubble.right.fill") {
                                state.receiveDM(channel.id)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Receive a message from \(channel.name)")
                            .help("Receive a message from \(channel.name)")
                        }
                    }
                }
            }
        }
    }
}

private struct ServerRailPlaygroundTile: View {
    let name: String
    let iconURL: URL?
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GuildIconView(name: name, iconURL: iconURL, size: 32, cornerRadius: 10, animates: false)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isVisible ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(isVisible ? Color.secondary : Color.accentColor)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(isVisible ? "Remove" : "Add") \(name)")
        .help(isVisible ? "Remove from rail" : "Add to rail")
    }
}
