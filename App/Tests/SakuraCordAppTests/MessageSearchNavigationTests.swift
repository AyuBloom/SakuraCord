@testable import SakuraCord
import DiscordProtocol
import SakuraCordModels
import Testing

@MainActor
struct MessageSearchNavigationTests {
    @Test(arguments: [UInt64(300), 400, 220])
    func `search results stay beside the destination until manual navigation`(destinationID: UInt64) async throws {
        let provider = MockChatProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        let destination = try #require(model.snapshot?.channels.first { $0.id.rawValue == destinationID })
        let hit: Message
        var resultChannels: [Channel] = []
        if destination.kind == .forum {
            let posts = try await provider.forumPosts(in: destination.id, query: .init())
            let post = try #require(posts.posts.first)
            hit = try #require(post.firstMessage)
            resultChannels = [Channel(id: post.id, guildID: destination.guildID, name: post.thread.name)]
            model.navigate(to: destination.id)
            await model.guildActivationTask?.value
            await model.channelLoadTask?.value
            _ = model.readState.updatePresentation(
                channelID: destination.id, isPresented: true,
                windowIsActive: true, hasReachedReadBoundary: true
            )
            #expect(model.readState.isActivelyPresentedAtNewest(destination.id))
        } else {
            let page = try await provider.messages(in: destination.id, before: nil, limit: 50)
            hit = try #require(page.messages.first)
        }
        model.messageSearch.submittedQuery = MessageSearchQuery(
            scope: destination.guildID.map(MessageSearchScope.guild) ?? .directMessages,
            content: "fixture"
        )
        model.messageSearch.page = MessageSearchPage(messages: [hit], channels: resultChannels, totalResults: 1)
        model.messageSearch.isPresented = true

        model.navigateToSearchResult(hit)
        await model.guildActivationTask?.value

        #expect(model.messageSearch.isPresented)
        #expect(model.canShowMessageSearch)
        #expect(!model.messageSearch.isNavigatingToResult)
        #expect(model.messageNavigationRequest?.messageID == hit.id)
        #expect(model.messageNavigationRequest?.channelID == hit.channelID)
        if destination.kind == .forum {
            #expect(model.openThread?.id == hit.channelID)
            #expect(model.isThreadFullWidth)
            #expect(!model.readState.isActivelyPresentedAtNewest(destination.id))
            model.presentMessageSearchFromCommand()
            #expect(model.messageSearch.tokens.contains { token in
                if case .channel(let channelID, _) = token.kind { return channelID == hit.channelID }
                return false
            })

            // The sidebar closes the thread before selecting its already-selected parent.
            model.closeThread()
            model.channelSidebarSelection = destination.id
            #expect(!model.messageSearch.isPresented)
            model.messageSearch.isPresented = true
            model.navigateToSearchResult(hit)
            await model.guildActivationTask?.value

            // Another hit must replace the primary thread and retain the results.
            let page = try await provider.messages(in: ChannelID(rawValue: 210), before: nil, limit: 50)
            let rootHit = try #require(page.messages.first)
            model.messageSearch.page = MessageSearchPage(messages: [rootHit], totalResults: 1)
            model.navigateToSearchResult(rootHit)
            await model.guildActivationTask?.value
            #expect(model.openThread == nil)
            #expect(model.selectedChannelID == rootHit.channelID)
            #expect(model.messageSearch.isPresented)
        } else {
            #expect(model.selectedChannelID == destination.id)
        }

        model.navigate(to: ChannelID(rawValue: 211))
        await model.guildActivationTask?.value
        #expect(!model.messageSearch.isPresented)
    }

    @Test func `manual selection cancels pending search result navigation`() async throws {
        let provider = MockChatProvider()
        let model = AppModel(launchMode: .offlineTesting, provider: provider)
        await model.start()
        let page = try await provider.messages(in: ChannelID(rawValue: 300), before: nil, limit: 50)
        let hit = try #require(page.messages.first)
        model.messageSearch.page = MessageSearchPage(messages: [hit], totalResults: 1)
        model.messageSearch.isPresented = true

        model.navigateToSearchResult(hit)
        let pending = model.guildActivationTask
        model.channelSidebarSelection = ChannelID(rawValue: 211)
        await pending?.value

        #expect(model.selectedChannelID == ChannelID(rawValue: 211))
        #expect(!model.messageSearch.isPresented)
        #expect(!model.messageSearch.isNavigatingToResult)
    }
}
