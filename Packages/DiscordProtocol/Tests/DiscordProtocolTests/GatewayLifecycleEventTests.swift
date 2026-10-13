@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct GatewayLifecycleEventTests {
    private let guildID = GuildID(rawValue: 100)
    private let textChannelID = ChannelID(rawValue: 200)
    private let forumChannelID = ChannelID(rawValue: 201)
    private let voiceChannelID = ChannelID(rawValue: 202)
    private let currentUserID = UserID(rawValue: 1)

    @Test func `media channel decodes as a non-text forum surface`() throws {
        let data = Data(
            #"""
            {
              "id":"203","guild_id":"100","type":16,"name":"media",
              "permission_overwrites":[]
            }
            """#.utf8
        )

        let channel = try JSONDecoder().decode(ChannelDTO.self, from: data)
            .domain(guildID: guildID)

        #expect(channel.kind == .forum)
    }

    @Test func `thread-shaped channel dispatch stays out of guild channels`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )

        let threadID = ChannelID(rawValue: 250)
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: channel(
                id: threadID.description,
                type: 11,
                name: "Loose forum post",
                parentID: forumChannelID.description
            )
        )

        #expect(await provider.cachedChannelForTesting(channelID: threadID) == nil)
        #expect(
            await provider.cachedForumPostForTesting(threadID: threadID)?.thread.parentID
                == forumChannelID
        )
    }

    @Test func `guild channel projection excludes thread records`() throws {
        let data = Data(
            #"""
            [
              {"id":"201","guild_id":"100","type":15,"name":"forum"},
              {
                "id":"250","guild_id":"100","type":11,
                "name":"Loose forum post","parent_id":"201"
              }
            ]
            """#.utf8
        )
        let values = try JSONDecoder().decode([ChannelDTO].self, from: data)

        let channels = try DiscordRESTProvider.domainChannels(values, guildID: guildID)

        #expect(channels.map(\.id) == [forumChannelID])
    }

    @Test(arguments: [
        (#"[{"id":"1","name":"Bug"},{"id":2,"name":null},"tag"]"#, ["Bug"]),
        (#"{"unexpected":"object"}"#, []),
        (#""tags""#, []),
    ])
    func `forum with malformed tag and reaction metadata still decodes`(
        tags: String, expectedNames: [String]
    ) throws {
        let data = Data(
            #"""
            [
              {
                "id":"201","guild_id":"100","type":15,"name":"forum",
                "available_tags":\#(tags),
                "default_reaction_emoji":"🌸",
                "default_sort_order":"latest",
                "default_forum_layout":{},
                "default_tag_setting":7
              }
            ]
            """#.utf8
        )
        let values = try JSONDecoder().decode([ChannelDTO].self, from: data)

        let channels = try DiscordRESTProvider.domainChannels(values, guildID: guildID)

        #expect(channels.map(\.id) == [forumChannelID])
        #expect(channels.first?.availableTags.map(\.name) == expectedNames)
        #expect(channels.first?.defaultReaction == nil)
    }

    @Test func `guild channel role member and user lifecycle reconciles cached state`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "before", globalName: "Before"),
                "guilds": .array([]),
            ])
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Lifecycle Guild")
        #expect(await provider.cachedGuildsForTesting().map(\.id) == [guildID])
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID)?.category == "Info")
        #expect(
            await provider.cachedChannelForTesting(channelID: textChannelID)?
                .permissionOverwrites?.first?.allow == 1_024
        )
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 2)
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleName == "Reader")

        await verifyCreateDispatches(on: provider)

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: channel(
                id: "200", type: 0, name: "renamed", parentID: "299",
                overwrites: [["id": .string("100"), "type": .number(0),
                              "allow": .string("2048"), "deny": .string("1024")]]
            )
        )
        let updatedChannel = await provider.cachedChannelForTesting(channelID: textChannelID)
        #expect(updatedChannel?.name == "renamed")
        #expect(updatedChannel?.permissionOverwrites?.first?.allow == 2_048)
        #expect(updatedChannel?.permissionOverwrites?.first?.deny == 1_024)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "role": role(id: "101", name: "Updated Reader", position: 3, hoist: true),
            ])
        )
        #expect(
            await provider.cachedGuildRolesForTesting(guildID: guildID)
                .first(where: { $0.id == RoleID(rawValue: 101) })?.name == "Updated Reader"
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleName == "Updated Reader")

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "before", globalName: "Before"),
                "nick": .string("Guild Nick"),
                "roles": .array([.string("101")]),
            ])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.user.displayName == "Guild Nick")
        #expect(
            await provider.currentQuickSwitcherGuildMemberUserIDs()[guildID]
                == [UserID(rawValue: 1)]
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "USER_UPDATE",
            data: user(id: "1", username: "after", globalName: "After")
        )
        #expect(await provider.currentUserForTesting()?.username == "after")
        let memberAfterUserUpdate = await provider.cachedMembersForTesting(guildID: guildID).first
        #expect(memberAfterUserUpdate?.user.displayName == "Guild Nick")
        #expect(memberAfterUserUpdate?.globalDisplayName == "After")

        await provider.cacheForwardSearchMessageAliases([
            Message(
                id: MessageID(rawValue: 500),
                channelID: textChannelID,
                author: User(
                    id: currentUserID,
                    username: "after",
                    displayName: "After"
                ),
                content: "cached alias",
                guildID: guildID
            )
        ])
        #expect(
            await provider.currentUserSearchAliasesByUserID()[currentUserID]
                == ["Guild Nick"]
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_DELETE",
            data: .object(["guild_id": .string("100"), "role_id": .string("101")])
        )
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 1)
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleIDs.isEmpty == true)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_REMOVE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "after", globalName: "After"),
            ])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).isEmpty)
        #expect(await provider.currentQuickSwitcherGuildMemberUserIDs()[guildID]?.isEmpty == true)
    }

    @Test func `guild unavailable differs from leaving and create adds a new guild`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload())

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_UPDATE",
            data: .object([
                "id": .string("100"), "name": .string("Renamed Guild"),
                "rules_channel_id": .string("200"),
            ])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Renamed Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.rulesChannelID == textChannelID)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE",
            data: .object(["id": .string("100"), "unavailable": .bool(true)])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.isUnavailable == true)
        #expect(await provider.cachedGuildsForTesting().map(\.id) == [guildID])

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.isUnavailable == false)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE",
            data: .object(["id": .string("100")])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID) == nil)
        #expect(await provider.cachedGuildsForTesting().isEmpty)
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) == nil)
    }

    @Test func `permission scoped member lists remain isolated when revisited`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "current", globalName: "Current"),
                "guilds": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE", data: guildCreatePayload()
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: "everyone", userIDs: ["1", "2", "3"], groupCount: 3
            )
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: "restricted", userIDs: ["1"], groupCount: 1
            )
        )

        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "restricted"
        ) == [UserID(rawValue: 1)])
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "everyone"
        ) == [UserID(rawValue: 1), UserID(rawValue: 2), UserID(rawValue: 3)])
        #expect(await provider.memberListGroupsForTesting(
            guildID: guildID, memberListID: "restricted"
        ).map(\.count) == [1])
        #expect(await provider.memberListGroupsForTesting(
            guildID: guildID, memberListID: "everyone"
        ).map(\.count) == [3])

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "id": .string("everyone"),
                "ops": .array([
                    .object([
                        "op": .string("UPDATE"),
                        "index": .number(1),
                        "item": .object([
                            "member": .object([
                                "user": user(
                                    id: "2",
                                    username: "updated-member-2",
                                    globalName: "Updated Member 2"
                                ),
                                "roles": .array([]),
                            ])
                        ]),
                    ])
                ]),
            ])
        )
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "everyone"
        ) == [UserID(rawValue: 1), UserID(rawValue: 2), UserID(rawValue: 3)])
        #expect(await provider.cachedMembersForTesting(guildID: guildID)
            .first(where: { $0.id == UserID(rawValue: 2) })?.user.displayName
            == "Updated Member 2")

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "id": .string("everyone"),
                "ops": .array([
                    .object(["op": .string("DELETE"), "index": .number(1)])
                ]),
            ])
        )
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "everyone"
        ) == [UserID(rawValue: 1), UserID(rawValue: 3)])
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "restricted"
        ) == [UserID(rawValue: 1)])
    }

    @Test func `overlapping INVALIDATE keeps rows and renews the member-list subscription`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: memberListID, userIDs: ["1", "2", "3"], groupCount: 3, range: 0 ... 99
            )
        )
        let subscriptionSends = await socket.sentPayloadCount(opcode: 37)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "id": .string(memberListID),
                "ops": .array([
                    .object([
                        "op": .string("INVALIDATE"),
                        "range": .array([.number(0), .number(99)]),
                    ])
                ]),
            ])
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == subscriptionSends + 1)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 1), UserID(rawValue: 2), UserID(rawValue: 3)])

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: memberListID, userIDs: ["4", "5"], groupCount: 2, range: 0 ... 99
            )
        )
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 4), UserID(rawValue: 5)])
        var otherChannel = try #require(await provider.cachedChannelForTesting(channelID: forumChannelID))
        otherChannel.memberListID = "other-list"
        await provider.seedGuildChannelForTesting(otherChannel)
        try await provider.subscribeToMemberList(guildID: guildID, channelID: forumChannelID)
        let beforeUnselectedInvalidation = await socket.sentPayloadCount(opcode: 37)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE", data: memberListInvalidation(id: memberListID)
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == beforeUnselectedInvalidation)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] != nil)
        try await provider.updateMemberListViewport(
            in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == beforeUnselectedInvalidation + 1)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        await provider.disconnect()
    }

    @Test func `concurrent member subscriptions preserve the latest ranges and thread selection`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 199]
            )
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let second = Task {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 299]
            )
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        let secondID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let thread = Task {
            try await provider.threadMembers(in: MessageThreadSummary(
                id: ChannelID(rawValue: 400), guildID: guildID,
                parentID: textChannelID, name: "Fixture Thread"
            ))
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: secondID)
        await socket.releaseHeldSend()
        try await first.value
        try await second.value
        _ = try await thread.value
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID]?.ranges == [0 ... 299])
        let sentPayloads = await socket.sentPayloads
        let bodies = sentPayloads.compactMap { data -> [String: Any]? in
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["op"] as? NSNumber)?.intValue == 37,
                  let body = payload["d"] as? [String: Any],
                  let subscriptions = body["subscriptions"] as? [String: Any]
            else { return nil }
            return subscriptions["100"] as? [String: Any]
        }
        let latestFull = try #require(bodies.last { $0["channels"] != nil })
        #expect((latestFull["channels"] as? [String: [[Int]]])?["200"] == [[0, 299]])
        #expect(latestFull["thread_member_lists"] as? [String] == ["400"])
        #expect(bodies.last?["thread_member_lists"] as? [String] == ["400"])
        await provider.disconnect()
    }

    @Test func `member SYNC received before subscription completion is published after commit`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        var channel = try #require(await provider.cachedChannelForTesting(channelID: forumChannelID))
        channel.memberListID = "early-sync"
        await provider.seedGuildChannelForTesting(channel)
        let events = await provider.eventStream()
        await socket.holdNextSend(opcode: 37)
        let subscription = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: forumChannelID)
        }
        await socket.waitForHeldSend()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: "early-sync", userIDs: ["2", "3"], groupCount: 2)
        )
        await socket.releaseHeldSend()
        try await subscription.value
        await provider.disconnect()
        var publishedMemberIDs: [[UserID]] = []
        for await event in events {
            if case let .membersChanged(eventGuildID, members, _) = event,
               eventGuildID == guildID {
                publishedMemberIDs.append(members.map(\.id))
            }
        }
        #expect(publishedMemberIDs.last == [UserID(rawValue: 2), UserID(rawValue: 3)])
    }

    @Test(arguments: ["INVALIDATE", "RATE_LIMITED"])
    func `member-list recovery includes the first subscription before it commits`(eventName: String) async throws {
        let fixture = try await makeMemberListProvider(subscribeInitially: false)
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
        )
        let sends = await socket.sentPayloadCount(opcode: 37)
        if eventName == "INVALIDATE" {
            let invalidation = Task {
                await provider.receiveGatewayDispatchForTesting(
                    name: "GUILD_MEMBER_LIST_UPDATE", data: memberListInvalidation(id: memberListID)
                )
            }
            await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
            #expect(await provider.orderedMemberListIDsForTesting(
                guildID: guildID, memberListID: memberListID
            ) == [UserID(rawValue: 2), UserID(rawValue: 3)])
            await socket.releaseHeldSend()
            try await first.value
            await invalidation.value
        } else {
            // No guild metadata: include requested guilds even when the
            // committed subscription map is still empty.
            await provider.receiveGatewayDispatchForTesting(
                name: "RATE_LIMITED",
                data: .object(["opcode": .number(37), "retry_after": .number(60)])
            )
            let refresh = try #require(await provider.memberListsNeedingRefresh[guildID]?[memberListID])
            await socket.releaseHeldSend()
            try await first.value
            #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == refresh)
            #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        }
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 2), UserID(rawValue: 3)])
        await provider.disconnect()
    }

    @Test(arguments: ["INVALIDATE", "RATE_LIMITED"])
    func `selection changes retain recovery for the first subscription still sending`(eventName: String) async throws {
        let fixture = try await makeMemberListProvider(subscribeInitially: false)
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object(["id": .string("201"), "guild_id": .string("100"), "type": .number(15),
                           "name": .string("forum"),
                           "member_list_id": .string("other-list")])
        )
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let second = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: forumChannelID)
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
        )
        await provider.receiveGatewayDispatchForTesting(
            name: eventName == "INVALIDATE" ? "GUILD_MEMBER_LIST_UPDATE" : "RATE_LIMITED",
            data: eventName == "INVALIDATE" ? memberListInvalidation(id: memberListID)
                : .object(["opcode": .number(37), "retry_after": .number(60)])
        )
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] != nil)
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 2), UserID(rawValue: 3)])
        await socket.releaseHeldSend()
        try await first.value
        if eventName == "RATE_LIMITED" {
            await #expect(throws: ChatProviderError.self) { try await second.value }
            // The selected list has never committed. Its empty inspector has
            // no native viewport callback to restart the rejected subscription.
            #expect(await provider.memberListSubscriptions[guildID]?["other-list"] == nil)
            #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
            #expect(await provider.memberListSubscriptions[guildID]?["other-list"]?.channelID == forumChannelID)
            #expect(await provider.memberListsNeedingRefresh[guildID]?["other-list"] == nil)
        } else {
            try await second.value
        }
        let sends = await socket.sentPayloadCount(opcode: 37)
        if eventName == "RATE_LIMITED" {
            await provider.receiveGatewayDispatchForTesting(
                name: "RATE_LIMITED",
                data: .object(["opcode": .number(37), "retry_after": .number(60)])
            )
            await #expect(throws: ChatProviderError.self) {
                try await provider.updateMemberListViewport(
                    in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
                )
            }
            #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        } else {
            try await provider.updateMemberListViewport(
                in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
            )
        }
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        await provider.disconnect()
    }

    @Test(arguments: [true, false], [true, false])
    func `access loss during an older send restores the accessible queued viewport`(
        distinctList: Bool, rateLimited: Bool
    ) async throws {
        let fixture = try await makeMemberListProvider(subscribeInitially: false)
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        let nextListID = distinctList ? "other-list" : memberListID
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object(["id": .string("201"), "guild_id": .string("100"), "type": .number(15),
                           "name": .string("forum"),
                           "member_list_id": .string(nextListID)])
        )
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let second = Task {
            try await provider.updateMemberListViewport(
                in: guildID, channelID: forumChannelID, visibleRange: 500 ... 510
            )
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
        )
        if rateLimited {
            await provider.receiveGatewayDispatchForTesting(
                name: "RATE_LIMITED",
                data: .object(["opcode": .number(37), "retry_after": .number(60)])
            )
        }
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object([
                "id": .string("200"), "guild_id": .string("100"), "type": .number(0),
                "name": .string("general"),
                "permission_overwrites": .array([.object([
                    "id": .string("1"), "type": .number(1),
                    "allow": .string("0"), "deny": .string("1024"),
                ])]),
            ])
        )
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ).isEmpty)
        await socket.releaseHeldSend()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        if rateLimited {
            #expect(await provider.memberListSubscriptions[guildID]?[nextListID] == nil)
            #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        }
        #expect(await eventually {
            await provider.memberListSubscriptions[guildID]?[nextListID]?.ranges
                == [0 ... 99, 400 ... 499, 500 ... 599]
        })
        #expect(await provider.memberListSubscriptions[guildID]?[nextListID]?.channelID == forumChannelID)
        if distinctList {
            #expect(await provider.memberListSubscriptions[guildID]?[memberListID] == nil)
        }
        #expect(await provider.selectedMemberListID[guildID] == nextListID)
        await provider.disconnect()
    }

    @Test func `older sends preserve a newer invalidation and cooldown recovery is bounded`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 199]
            )
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let invalidation = Task {
            await provider.receiveGatewayDispatchForTesting(
                name: "GUILD_MEMBER_LIST_UPDATE",
                data: memberListInvalidation(id: memberListID, range: 100 ... 199)
            )
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        let rateLimit: JSONValue = .object([
            "opcode": .number(37), "retry_after": .number(60),
            "meta": .object(["guild_id": .string("100")]),
        ])
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        let refresh = try #require(await provider.memberListsNeedingRefresh[guildID]?[memberListID])
        await socket.releaseHeldSend()
        try await first.value
        await invalidation.value
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == refresh)
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateMemberListViewport(
                in: guildID, channelID: textChannelID, visibleRange: 500 ... 510
            )
        }
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID]?.ranges == [0 ... 199])
        let sends = await socket.sentPayloadCount(opcode: 37)
        #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID]?.ranges
            == [0 ... 99, 400 ... 499, 500 ... 599])
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] != nil)
        #expect(await provider.memberListRefreshRetryTasks[guildID] == nil)
        await provider.disconnect()
    }

    @Test func `a viewable channel changing member-list identity restores its desired viewport`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        try await provider.updateMemberListViewport(
            in: guildID, channelID: textChannelID, visibleRange: 500 ... 510
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
        )
        let sends = await socket.sentPayloadCount(opcode: 37)
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object([
                "id": .string("200"), "guild_id": .string("100"), "type": .number(0),
                "name": .string("general"), "member_list_id": .string("replacement-list"),
            ])
        )
        #expect(await eventually {
            await provider.memberListSubscriptions[guildID]?["replacement-list"]?.ranges
                == [0 ... 99, 400 ... 499, 500 ... 599]
        })
        #expect(await provider.selectedMemberListID[guildID] == "replacement-list")
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID] == nil)
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ).isEmpty)
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        await provider.disconnect()
    }

    @Test func `selection can return to a canceled cooldown refresh without consuming its attempt`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        var otherChannel = try #require(await provider.cachedChannelForTesting(channelID: forumChannelID))
        otherChannel.memberListID = "other-list"
        await provider.seedGuildChannelForTesting(otherChannel)
        try await provider.subscribeToMemberList(guildID: guildID, channelID: forumChannelID)
        try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        let rateLimit: JSONValue = .object([
            "opcode": .number(37), "retry_after": .number(60),
            "meta": .object(["guild_id": .string("100")]),
        ])
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        #expect(await provider.memberListRefreshRetryTasks[guildID] != nil)
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateMemberListViewport(
                in: guildID, channelID: forumChannelID, visibleRange: 0 ... 10
            )
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateMemberListViewport(
                in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
            )
        }
        let sends = await socket.sentPayloadCount(opcode: 37)
        #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] != nil)
        #expect(await provider.memberListRefreshRetryTasks[guildID] == nil)
        await provider.disconnect()
    }

    @Test(arguments: [true, false])
    func `role access loss discards retained member rows while channel metadata remains`(
        initiallySubscribed: Bool
    ) async throws {
        let fixture = try await makeMemberListProvider(
            subscribeInitially: initiallySubscribed
        )
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        var selectedChannel = try #require(await provider.cachedChannelForTesting(channelID: textChannelID))
        selectedChannel.permissionOverwrites = []
        selectedChannel.memberListID = memberListID
        await provider.seedGuildChannelForTesting(selectedChannel)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "role": .object([
                    "id": .string("100"), "name": .string("@everyone"),
                    "position": .number(0), "hoist": .bool(false), "permissions": .string("0"),
                ]),
            ])
        )
        #expect(await provider.isMemberListAccessible(guildID: guildID, memberListID: memberListID)
            == initiallySubscribed)
        await socket.holdNextSend(opcode: 37)
        let earlierSubscription = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        }
        await socket.waitForHeldSend()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3", "4"], groupCount: 3)
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "fixture", globalName: "Fixture"),
                "roles": .array([]),
            ])
        )
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) != nil)
        #expect(await provider.isMemberListAccessible(guildID: guildID, memberListID: memberListID) == false)
        #expect(await provider.orderedMemberListIDsForTesting(guildID: guildID, memberListID: memberListID).isEmpty)
        #expect(try await provider.members(in: guildID).isEmpty)
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID] == nil)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "fixture", globalName: "Fixture"),
                "roles": .array([.string("101")]),
            ])
        )
        await socket.releaseHeldSend()
        await #expect(throws: CancellationError.self) {
            try await earlierSubscription.value
        }
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID] == nil)
        let sendsBeforeRestoredViewport = await socket.sentPayloadCount(opcode: 37)
        try await provider.updateMemberListViewport(
            in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == sendsBeforeRestoredViewport + 1)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3", "4"], groupCount: 3)
        )
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 2), UserID(rawValue: 3), UserID(rawValue: 4)])
        await provider.disconnect()
    }

    @Test func `desktop ETF numeric permissions guild create adds a new guild`() async {
        let provider = makeProvider()

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(permissions: .number(1_024))
        )

        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Lifecycle Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.currentUserPermissions == 1_024)
        #expect(await provider.cachedGuildsForTesting().map(\.id) == [guildID])
        #expect(await provider.cachedGuildRailItemsForTesting() == [.guild(guildID)])
    }

    @Test func `desktop nested properties guild create adds a new guild`() async {
        let provider = makeProvider()

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: desktopGuildCreatePayload()
        )

        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Lifecycle Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.currentUserPermissions == 1_024)
        #expect(await provider.cachedGuildsForTesting().map(\.id) == [guildID])
        #expect(await provider.cachedGuildRailItemsForTesting() == [.guild(guildID)])
    }

    @Test func `partial desktop guild create preserves the existing catalog`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload()
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("100"),
                "data_mode": .string("partial"),
                "properties": .object([
                    "name": .string("Recovered Guild"),
                    "permissions": .number(2_048),
                ]),
            ])
        )

        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Recovered Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.currentUserPermissions == 2_048)
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) != nil)
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 2)
    }

    @Test func `pins bulk deletes thread counts and voice metadata reconcile`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "current", globalName: "Current"),
                "guilds": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload())

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_PINS_UPDATE",
            data: .object([
                "guild_id": .string("100"), "channel_id": .string("200"),
                "last_pin_timestamp": .string("2026-08-03T12:00:00.000000+00:00"),
            ])
        )
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID)?.lastPinTimestamp != nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "VOICE_CHANNEL_STATUS_UPDATE",
            data: .object([
                "guild_id": .string("100"), "id": .string("202"),
                "status": .string("Office hours"),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "VOICE_CHANNEL_START_TIME_UPDATE",
            data: .object([
                "guild_id": .string("100"), "id": .string("202"),
                "voice_start_time": .number(1_775_390_400),
            ])
        )
        let voice = await provider.cachedChannelForTesting(channelID: voiceChannelID)
        #expect(voice?.voiceStatus == "Office hours")
        #expect(voice?.voiceStartTime != nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_CREATE",
            data: .object([
                "id": .string("250"), "guild_id": .string("100"),
                "parent_id": .string("201"), "type": .number(11),
                "name": .string("A thread"), "member_count": .number(2),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_MEMBERS_UPDATE",
            data: .object([
                "id": .string("250"), "guild_id": .string("100"),
                "member_count": .number(7),
                "added_members": .array([
                    .object([
                        "id": .string("250"), "user_id": .string("1"),
                        "flags": .number(4), "muted": .bool(false),
                    ])
                ]),
                "removed_member_ids": .array([]),
            ])
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 250))?
                .thread.memberCount == 7
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 250))?
                .thread.notificationSettings?.flags == 4
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_MEMBERS_UPDATE",
            data: .object([
                "id": .string("250"), "guild_id": .string("100"),
                "member_count": .number(6), "added_members": .array([]),
                "removed_member_ids": .array([.string("1")]),
            ])
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 250))?
                .thread.notificationSettings == nil
        )

        let author = User(id: currentUserID, username: "author", displayName: "Author")
        let firstMessageID = MessageID(rawValue: 301)
        let secondMessageID = MessageID(rawValue: 302)
        await provider.seedMessageForTesting(
            Message(id: firstMessageID, channelID: textChannelID, author: author, content: "one")
        )
        await provider.seedMessageForTesting(
            Message(id: secondMessageID, channelID: textChannelID, author: author, content: "two")
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_DELETE_BULK",
            data: .object([
                "channel_id": .string("200"),
                "ids": .array([.string("301"), .string("302")]),
            ])
        )
        #expect(await provider.cachedMessageForTesting(messageID: firstMessageID) == nil)
        #expect(await provider.cachedMessageForTesting(messageID: secondMessageID) == nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_DELETE",
            data: .object(["id": .string("200"), "guild_id": .string("100")])
        )
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) == nil)
    }

    @Test func `rate limited event records bounded gateway cooldown`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "RATE_LIMITED",
            data: .object([
                "opcode": .number(8), "retry_after": .number(30),
                "meta": .object(["guild_id": .string("100")]),
            ])
        )
        #expect(await provider.gatewayOpcodeIsRateLimitedForTesting(8))
        #expect(!(await provider.gatewayOpcodeIsRateLimitedForTesting(37)))
    }

    @Test func `dispatch reconciliation has zero HTTP request budget`() async {
        GatewayDispatchCountingURLProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayDispatchCountingURLProtocol.self]
        let provider = makeProvider(session: URLSession(configuration: configuration))

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE", data: guildCreatePayload()
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: channel(id: "200", type: 0, name: "renamed")
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "current", globalName: "Current"),
                "roles": .array([.string("101")]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_SCHEDULED_EVENT_UPDATE",
            data: .object(["id": .string("900"), "guild_id": .string("100")])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE", data: .object(["id": .string("100")])
        )

        #expect(GatewayDispatchCountingURLProtocol.requestCount == 0)
    }

    private func verifyCreateDispatches(on provider: DiscordRESTProvider) async {
        let createdChannelID = ChannelID(rawValue: 203)
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_CREATE",
            data: channel(id: "203", type: 0, name: "created")
        )
        #expect(await provider.cachedChannelForTesting(channelID: createdChannelID)?.name == "created")
        #expect(await provider.cachedForwardChannelStoreOrder.contains(createdChannelID))

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_CREATE",
            data: .object([
                "guild_id": .string("100"),
                "role": role(id: "102", name: "New Role", position: 1, hoist: true),
            ])
        )
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 3)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_ADD",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "2", username: "added", globalName: "Added"),
                "roles": .array([.string("102")]),
            ])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).count == 2)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_REMOVE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "2", username: "added", globalName: "Added"),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_DELETE",
            data: .object(["guild_id": .string("100"), "role_id": .string("102")])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).count == 1)
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 2)
    }

    private func makeProvider(
        session: URLSession = URLSession(configuration: .ephemeral)
    ) -> DiscordRESTProvider {
        DiscordRESTProvider(
            credentials: GatewayLifecycleCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: session
        )
    }

    private struct MemberListFixture {
        let provider: DiscordRESTProvider
        let socket: ReadyGatewaySocket
        let memberListID: String
    }

    private func makeMemberListProvider(
        subscribeInitially: Bool = true
    ) async throws -> MemberListFixture {
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(op: 10, data: .object(["heartbeat_interval": .number(60_000)])))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("invalidate-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
            ]),
            sequence: 1, eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: .init(accountID: "1"),
            session: URLSession(configuration: .ephemeral),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            installationID: "fixture"
        )
        try await provider.startGateway()
        #expect(await eventually {
            await provider.gatewayReady
        })
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE", data: guildCreatePayload()
        )
        await provider.seedPrivateChannelsForTesting([], currentUser: User(
            id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture"
        ))
        await provider.setPendingMemberGuildForTesting(guildID)
        if subscribeInitially {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 99]
            )
        }
        let channel = try #require(await provider.cachedChannelForTesting(channelID: textChannelID))
        let roles = await provider.cachedGuildRoles[guildID] ?? []
        let memberListID = DiscordMemberListIdentity.id(for: channel, guildID: guildID, roles: roles)
        return MemberListFixture(provider: provider, socket: socket, memberListID: memberListID)
    }

    private func memberListInvalidation(id: String, range: ClosedRange<Int> = 0 ... 99) -> JSONValue {
        .object([
            "guild_id": .string("100"), "id": .string(id),
            "ops": .array([.object([
                "op": .string("INVALIDATE"),
                "range": .array([.number(Double(range.lowerBound)), .number(Double(range.upperBound))]),
            ])]),
        ])
    }

    private func guildCreatePayload(
        includesUnavailable: Bool = true,
        permissions: JSONValue = .string("1024")
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string("100"), "name": .string("Lifecycle Guild"),
            "permissions": permissions,
            "channels": .array([
                channel(id: "299", type: 4, name: "Info", position: 0),
                channel(
                    id: "200", type: 0, name: "general", parentID: "299",
                    overwrites: [["id": .string("100"), "type": .number(0),
                                  "allow": .string("1024"), "deny": .string("0")]]
                ),
                channel(id: "201", type: 15, name: "forum", position: 2),
                channel(id: "202", type: 2, name: "Voice", position: 3),
            ]),
            "roles": .array([
                role(id: "100", name: "@everyone", position: 0, hoist: false),
                role(id: "101", name: "Reader", position: 2, hoist: true),
            ]),
            "members": .array([
                .object([
                    "user": user(id: "1", username: "before", globalName: "Before"),
                    "roles": .array([.string("101")]),
                ])
            ]),
            "threads": .array([]), "voice_states": .array([]), "emojis": .array([]),
        ]
        if includesUnavailable { payload["unavailable"] = .bool(false) }
        return .object(payload)
    }

    private func desktopGuildCreatePayload() -> JSONValue {
        guard case .object(var payload) = guildCreatePayload() else {
            preconditionFailure("The Guild Create fixture must remain an object.")
        }
        payload["name"] = nil
        payload["permissions"] = nil
        payload["data_mode"] = .string("full")
        payload["properties"] = .object([
            "name": .string("Lifecycle Guild"),
            "permissions": .number(1_024),
        ])
        return .object(payload)
    }

    private func channel(
        id: String, type: Int, name: String, parentID: String? = nil,
        position: Int = 1, overwrites: [[String: JSONValue]] = []
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "guild_id": .string("100"),
            "type": .number(Double(type)), "name": .string(name),
            "position": .number(Double(position)),
            "permission_overwrites": .array(overwrites.map(JSONValue.object)),
        ]
        if let parentID { value["parent_id"] = .string(parentID) }
        return .object(value)
    }

    private func role(id: String, name: String, position: Int, hoist: Bool) -> JSONValue {
        .object([
            "id": .string(id), "name": .string(name),
            "position": .number(Double(position)), "hoist": .bool(hoist),
            "permissions": .string("1024"),
        ])
    }

    private func memberListUpdate(
        id: String, userIDs: [String], groupCount: Int, range: ClosedRange<Int>? = nil
    ) -> JSONValue {
        .object([
            "guild_id": .string("100"),
            "id": .string(id),
            "groups": .array([
                .object(["id": .string("online"), "count": .number(Double(groupCount))])
            ]),
            "ops": .array([
                .object([
                    "op": .string("SYNC"),
                    "range": .array([
                        .number(Double(range?.lowerBound ?? 0)),
                        .number(Double(range?.upperBound ?? max(0, userIDs.count - 1))),
                    ]),
                    "items": .array(userIDs.map { userID in
                        .object([
                            "member": .object([
                                "user": user(
                                    id: userID,
                                    username: "member-\(userID)",
                                    globalName: "Member \(userID)"
                                ),
                                "roles": .array([]),
                            ])
                        ])
                    }),
                ])
            ]),
        ])
    }

    private func user(id: String, username: String, globalName: String) -> JSONValue {
        .object([
            "id": .string(id), "username": .string(username),
            "global_name": .string(globalName),
        ])
    }
}

private actor GatewayLifecycleCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("unused".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private final class GatewayDispatchCountingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.dataNotAllowed)
        )
    }

    override func stopLoading() {}
}
