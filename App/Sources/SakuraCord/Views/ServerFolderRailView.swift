import SakuraCordModels
import SwiftUI

struct ServerFolderRailView: View {
    let entry: ServerRailFolderEntry
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let expansionChanged: () -> Void

    @AppStorage private var isExpanded: Bool
    @Environment(ServerRailDragController.self) private var drag

    init(
        entry: ServerRailFolderEntry,
        selectGuild: @escaping (GuildID?) -> Void,
        contextMenuActions: ServerRailContextMenuActions,
        expansionChanged: @escaping () -> Void
    ) {
        self.entry = entry
        self.selectGuild = selectGuild
        self.contextMenuActions = contextMenuActions
        self.expansionChanged = expansionChanged
        _isExpanded = AppStorage(
            wrappedValue: false,
            Self.expansionKey(entry.folder.id),
            store: PRBuildProfile.defaults
        )
    }

    static func expansionKey(_ folderID: Int64) -> String {
        "GuildFolders.\(folderID).isExpanded"
    }

    var body: some View {
        VStack(spacing: InterfaceScale.metric(8)) {
            ServerFolderRailHeader(
                entry: entry,
                isExpanded: isExpanded,
                contextMenuActions: contextMenuActions
            ) {
                guard !drag.swallowsClick else { return }
                withAnimation(ServerRailAnimations.folderExpansion) {
                    isExpanded.toggle()
                    expansionChanged()
                }
            }
            .modifier(ServerRailDraggableRow(id: entry.id, isExpandedFolder: isExpanded))

            if isExpanded {
                ExpandedFolderGuilds(
                    folderID: entry.folder.id,
                    guildEntries: entry.guildEntries,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions
                )
                .transition(.offset(y: -InterfaceScale.metric(10)).combined(with: .opacity))
            }
        }
        .padding(.top, isExpanded ? InterfaceScale.metric(4) : 0)
        .padding(.bottom, isExpanded ? InterfaceScale.metric(3) : 0)
        .background {
            if isExpanded {
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(17), style: .continuous)
                    .fill(Color(hex: entry.folder.colorHex ?? ServerFolderSettingsView.defaultColor).opacity(0.12))
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .transition(.opacity)
            }
        }
    }
}

/// A folder's button. It is also drawn on its own while the folder is dragged.
struct ServerFolderRailHeader: View {
    let entry: ServerRailFolderEntry
    let isExpanded: Bool
    let contextMenuActions: ServerRailContextMenuActions
    let toggle: () -> Void
    var loadsImageWhenOffscreen = false
    @State private var isHovering = false
    @State private var iconIsVisible = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            ServerRailSelectionIndicator(
                isSelected: entry.containsSelectedGuild,
                isHovering: isHovering,
                hasNotification: showsUnreadIndicators && entry.hasUnreadGuild
            )
            Button(action: toggle) {
                ServerRailBadgedIcon(
                    mentionCount: showsUnreadIndicators ? entry.mentionCount : 0
                ) {
                    Group {
                        if isExpanded {
                            Image(systemName: "folder.fill")
                                .font(.interfaceSystem(size: 19, weight: .semibold))
                                .foregroundStyle(folderColor.opacity(0.8))
                                .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                        } else {
                            collapsedPreview
                                .mask {
                                    ConcentricRectangle(cornerRadius: InterfaceScale.metric(13), style: .continuous)
                                        .padding(InterfaceScale.metric(4))
                                }
                        }
                    }
                    .background(folderColor.opacity(isExpanded ? 0.18 : 0.12))
                    .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(isExpanded ? 13 : 17), style: .continuous))
                    .frame(width: InterfaceScale.metric(isExpanded ? 46 : 52), height: InterfaceScale.metric(isExpanded ? 46 : 52))
                }
            }
            .buttonStyle(.plain)
            .offset(x: isExpanded ? 0 : InterfaceScale.metric(-3))
            .overlay {
                ServerFolderContextMenuBridge(
                    isUnread: entry.hasUnreadGuild || entry.mentionCount > 0,
                    markRead: { contextMenuActions.markFolderRead(entry.guildEntries.map(\.id)) },
                    openSettings: { contextMenuActions.openFolderSettings(entry.folder) }
                )
            }
            .accessibilityLabel(displayName)
            .accessibilityValue(
                "\(isExpanded ? "Expanded" : "Collapsed")"
                    + (showsUnreadIndicators && entry.mentionCount > 0
                        ? ", \(entry.mentionCount) unread mentions" : "")
                    + (showsUnreadIndicators && entry.mentionCount == 0
                        && entry.hasUnreadGuild ? ", Unread" : "")
            )
            .accessibilityHint("Toggles the server folder")
            .help(displayName)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(isExpanded ? 46 : 54), alignment: .leading)
        .contentShape(Rectangle())
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onScrollVisibilityChange(threshold: 0.01) { iconIsVisible = $0 }
        .onModalHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }

    private var collapsedPreview: some View {
        let preview = entry.previewGuilds
        return VStack(spacing: InterfaceScale.metric(2)) {
            HStack(spacing: InterfaceScale.metric(2)) {
                previewIcon(preview[safe: 0])
                previewIcon(preview[safe: 1])
            }
            HStack(spacing: InterfaceScale.metric(2)) {
                previewIcon(preview[safe: 2])
                previewIcon(preview[safe: 3])
            }
        }
        .frame(width: InterfaceScale.metric(52), height: InterfaceScale.metric(52))
    }

    @ViewBuilder
    private func previewIcon(_ guild: Guild?) -> some View {
        if let guild {
            GuildIconView(
                name: guild.name,
                iconURL: guild.iconURL,
                size: InterfaceScale.metric(21),
                cornerRadius: InterfaceScale.metric(6),
                animates: false,
                loadsImage: loadsImageWhenOffscreen || iconIsVisible
            )
        } else {
            Color.clear.frame(width: InterfaceScale.metric(21), height: InterfaceScale.metric(21))
        }
    }

    private var displayName: String {
        guard let name = entry.folder.name, !name.isEmpty else { return "Server Folder" }
        return name
    }

    private var showsUnreadIndicators: Bool {
        !isExpanded
    }

    private var folderColor: Color {
        Color(hex: entry.folder.colorHex ?? ServerFolderSettingsView.defaultColor)
    }
}

private struct ExpandedFolderGuilds: View {
    let folderID: Int64
    let guildEntries: [ServerRailGuildEntry]
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions

    var body: some View {
        VStack(spacing: InterfaceScale.metric(8)) {
            ForEach(guildEntries) { entry in
                ServerRailGuildItemView(
                    entry: entry,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions
                )
                .modifier(ServerRailDraggableRow(id: .guild(entry.id), folderID: folderID))
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
