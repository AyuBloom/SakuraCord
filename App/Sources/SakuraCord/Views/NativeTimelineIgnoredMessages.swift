import Foundation
import SakuraCordModels

struct IgnoredMessageGroup: Equatable {
    let messageIDs: [MessageID]
    let isRevealed: Bool
    let reason: UserContentSuppression
    let day: Date?
    let isUnreadBoundary: Bool
    let contextTitle: String?
    var label: String { messageIDs.count == 1 ? "1 \(reason.rawValue) message" : "\(messageIDs.count) \(reason.rawValue) messages" }
}

extension NativeMessageTimelineCoordinator {
    func messageItems(_ rows: [MessageRowPresentation], from parent: NativeMessageTimelineView) -> [NativeMessageTimelineItem] {
        var result: [NativeMessageTimelineItem] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            guard let reason = parent.model.messageSuppressionReason(row.message) else {
                result.append(messageItem(protectIgnoredReply(row, model: parent.model), from: parent))
                index += 1
                continue
            }
            let wasRevealed = parent.model.ignoredUsers.revealedMessageIDs.contains(row.id)
            var end = index + 1
            while end < rows.count, !rows[end].startsDay,
                  rows[end].id != parent.unreadMessageID,
                  rows[end].message.channelID == row.message.channelID,
                  parent.model.messageSuppressionReason(rows[end].message) == reason,
                  parent.model.ignoredUsers.revealedMessageIDs.contains(rows[end].id) == wasRevealed { end += 1 }
            let ids = rows[index ..< end].map(\.id)
            let revealed = ids.allSatisfy(parent.model.ignoredUsers.revealedMessageIDs.contains)
            result.append(.ignoredMessages(.init(
                messageIDs: ids, isRevealed: revealed, reason: reason,
                day: !revealed && row.startsDay ? row.message.timestamp : nil,
                isUnreadBoundary: !revealed && parent.unreadMessageID.map(ids.contains) == true,
                contextTitle: !revealed ? row.searchContext?.sectionTitle : nil
            )))
            if revealed {
                result.append(contentsOf: rows[index ..< end].map {
                    messageItem(protectIgnoredReply($0, model: parent.model), from: parent)
                })
            }
            index = end
        }
        return result
    }

    private func protectIgnoredReply(_ row: MessageRowPresentation, model: AppModel) -> MessageRowPresentation {
        guard var preview = row.replyPreview, model.isUserIgnored(preview.author.id) else { return row }
        preview.content = "Ignored message"
        preview.mediaKind = nil
        return MessageRowPresentation(message: row.message, startsGroup: row.startsGroup, endsGroup: row.endsGroup,
                                      startsDay: row.startsDay, replyPreview: preview, isReplyAvailable: row.isReplyAvailable,
                                      textPlan: row.textPlan, searchContext: row.searchContext,
                                      pinnedAt: row.pinnedAt, isResource: row.isResource)
    }
}
