import AppKit
import Observation
import SakuraCordModels
import SwiftUI

/// Local fixture data feeds the production presentation store; no account or provider mutations.
@Observable
final class ServerRailPlaygroundState {
    enum InsertionPosition: String, CaseIterable {
        case top = "Top"
        case middle = "Middle"
        case bottom = "Bottom"
    }

    let presentation = ServerRailPresentationStore()
    private(set) var guilds: [Guild] = []
    private(set) var conversations: [Channel] = []
    private(set) var layout: [GuildRailItem] = []
    private(set) var unreadDMs: Set<ChannelID> = []
    var insertionPosition = InsertionPosition.top
    var selectedGuildID: GuildID?
    var selectedChannelID: ChannelID?
    var iconError: String?
    static let folderID: Int64 = 8_800_001

    init() {
        let names = ["Sakura Garden", "Cosmic Café", "Mint Arcade", "Sunset Studio", "Ocean Club", "Violet Lounge",
                     "Peach Party", "Sky Station", "Coral Reef", "Lemon Grove", "Rose Radio", "Indigo Lab"]
        let symbols = ["leaf.fill", "sparkles", "gamecontroller.fill", "sun.max.fill", "water.waves", "moon.stars.fill",
                       "heart.fill", "paperplane.fill", "fish.fill", "bolt.fill", "music.note", "atom"]
        let colors: [UInt32] = [0xE66DA2, 0x785BE8, 0x26B999, 0xEE8954, 0x258BC7, 0xAC65D5,
                                0xED907F, 0x51A9D6, 0xE36771, 0xC4A52B, 0xD25391, 0x526BD5]
        var icons: [Int: URL] = [:]
        do {
            let directory = FileManager.default.temporaryDirectory.appending(path: "SakuraCord-RailPlayground-Icons")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in names.indices {
                let url = directory.appending(path: "icon-\(index).png")
                let renderer = ImageRenderer(content:
                    ZStack {
                        Rectangle().fill(Color(hex: colors[index]).gradient)
                        Image(systemName: symbols[index])
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 128, height: 128)
                )
                if let tiff = renderer.nsImage?.tiffRepresentation,
                   let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                {
                    try data.write(to: url, options: .atomic)
                    icons[index] = url
                }
            }
        } catch {
            iconError = error.localizedDescription
        }
        guilds = names.indices.map { index in
            Guild(id: GuildID(rawValue: UInt64(880_000 + index)), name: names[index],
                  iconURL: icons[index], accentHex: colors[index],
                  unreadCount: index.isMultiple(of: 2) ? 1 : 0, mentionCount: index.isMultiple(of: 3) ? 2 : 0)
        }
        let people = ["Mika", "Nova", "Jules", "Sunny", "Kai", "Luna", "Friends Night", "Art Club"]
        conversations = people.indices.map { index in
            let kind: ChannelKindValue = index < 6 ? .directMessage : .groupDirectMessage
            let mentions = index.isMultiple(of: 2) ? index + 1 : 0
            return Channel(id: ChannelID(rawValue: UInt64(990_000 + index)), guildID: nil, name: people[index],
                    iconURL: icons[index + 2],
                    kind: kind, unreadCount: 1, mentionCount: mentions)
        }
        reset()
    }

    var visibleGuildIDs: Set<GuildID> { Set(layout.flattenedGuildIDs) }
    var hasFolder: Bool { layout.contains { $0.id == .folder(Self.folderID) } }

    func reset() {
        conversations.sort { $0.id < $1.id }
        for index in conversations.indices {
            conversations[index].lastMessageID = nil
            conversations[index].unreadCount = 1
            conversations[index].mentionCount = index.isMultiple(of: 2) ? index + 1 : 0
        }
        layout = [.guild(guilds[0].id), .guild(guilds[1].id),
                  .folder(GuildFolder(id: Self.folderID, name: "Color Club", colorHex: 0xA96BE8,
                                      guildIDs: guilds[4 ... 8].map(\.id))),
                  .guild(guilds[2].id), .guild(guilds[3].id)]
        unreadDMs = Set(conversations.prefix(2).map(\.id))
        selectGuild(nil)
        refresh()
    }

    func selectGuild(_ id: GuildID?) {
        selectedGuildID = id
        selectedChannelID = nil
        presentation.updateSelection(id, channelID: nil)
    }

    func selectDM(_ id: ChannelID) {
        selectedGuildID = nil
        selectedChannelID = id
        presentation.updateSelection(nil, channelID: id)
    }

    func toggleGuild(_ id: GuildID) {
        if visibleGuildIDs.contains(id) {
            removeGuild(id)
        } else {
            let index: Int = switch insertionPosition {
            case .top: 0
            case .middle: layout.count / 2
            case .bottom: layout.count
            }
            layout.insert(.guild(id), at: index)
        }
        refresh()
    }

    func toggleDM(_ id: ChannelID) {
        if unreadDMs.contains(id) {
            unreadDMs.remove(id)
            refresh()
        } else {
            receiveDM(id)
        }
    }

    /// Mirrors the live provider's activity promotion, retaining the channel's identity.
    func receiveDM(_ id: ChannelID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let nextMessageID = (conversations.compactMap(\.lastMessageID).max()?.rawValue ?? 0) + 1
        var channel = conversations.remove(at: index)
        channel.lastMessageID = MessageID(rawValue: nextMessageID)
        channel.unreadCount += 1
        channel.mentionCount += 1
        conversations.insert(channel, at: 0)
        unreadDMs.insert(id)
        refresh()
    }

    func addServers() {
        for guild in guilds.filter({ !visibleGuildIDs.contains($0.id) }).prefix(3) {
            toggleGuild(guild.id)
        }
    }

    func removeServers() {
        for id in layout.flattenedGuildIDs.prefix(3) { removeGuild(id) }
        refresh()
    }

    func toggleFolder() {
        if hasFolder {
            layout.removeAll { $0.id == .folder(Self.folderID) }
        } else {
            let members = guilds[4 ... 8].map(\.id)
            for id in members { removeGuild(id) }
            layout.insert(.folder(GuildFolder(id: Self.folderID, name: "Color Club", colorHex: 0xA96BE8, guildIDs: members)),
                          at: min(2, layout.count))
        }
        refresh()
    }

    func addToFolder() {
        guard let id = guilds.first(where: { !visibleGuildIDs.contains($0.id) })?.id else { return }
        if let index = layout.firstIndex(where: { $0.id == .folder(Self.folderID) }), case .folder(var folder) = layout[index] {
            folder.guildIDs.insert(id, at: 0)
            layout[index] = .folder(folder)
        } else {
            layout.append(.folder(GuildFolder(id: Self.folderID, name: "Color Club", colorHex: 0xA96BE8, guildIDs: [id])))
        }
        refresh()
    }

    func removeFromFolder() {
        guard let folder = layout.compactMap({ item -> GuildFolder? in
            if case .folder(let folder) = item { folder } else { nil }
        }).first, let id = folder.guildIDs.first else { return }
        removeGuild(id)
        refresh()
    }

    func setDMs(_ ids: Set<ChannelID>) {
        unreadDMs = ids
        refresh()
    }

    func clear() {
        layout = []
        unreadDMs = []
        refresh()
    }

    func move(_ ids: [GuildRailItem.RailIdentifier], to destination: GuildRailDestination) {
        layout = layout.moving(ids, to: destination)
        refresh()
    }

    func combine(_ source: GuildID, onto target: GuildID) {
        layout = layout.combining(source, onto: target, folderID: Int64.random(in: 9_000_000 ... 9_999_999))
        refresh()
    }

    private func removeGuild(_ id: GuildID) {
        layout = layout.compactMap { item in
            switch item {
            case .guild(let existing): return existing == id ? nil : item
            case .folder(var folder):
                folder.guildIDs.removeAll { $0 == id }
                return folder.guildIDs.isEmpty ? nil : .folder(folder)
            }
        }
    }

    private func refresh() {
        let visible = visibleGuildIDs
        presentation.updateGuilds(
            Dictionary(uniqueKeysWithValues: guilds.filter { visible.contains($0.id) }.map { ($0.id, $0) }),
            notificationSettings: { GuildNotificationSettings(guildID: $0.id) },
            isMutationPending: { _ in false }
        )
        presentation.updateLayout(layout)
        presentation.updateDirectMessages(conversations, unacknowledgedChannelIDs: unreadDMs)
        if let selectedGuildID, !visible.contains(selectedGuildID) { selectGuild(nil) }
        if let selectedChannelID, !unreadDMs.contains(selectedChannelID) { selectGuild(nil) }
    }
}
