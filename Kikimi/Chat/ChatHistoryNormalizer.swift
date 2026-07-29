import Foundation

// MARK: - ChatHistoryNormalizer

/// Turns the stored chat history into the strictly alternating turn list a prompt can carry
/// (`docs/design/38-session-chat.md` §3.3, CH22).
///
/// A plain "last N turns" slice is not enough. The stored log legitimately contains failed answers
/// (which must not become context for the next question), questions whose answer never arrived
/// (the app quit while waiting), and -- once those are filtered out -- odd-length runs that would
/// start on an `assistant`. Any of these puts two same-role messages next to each other, which some
/// backends reject outright.
enum ChatHistoryNormalizer {
    /// - Returns: an even-length list, strictly alternating, starting with `.user` and ending with
    ///   `.assistant`.
    /// - Parameter maxTurns: turn count, not pair count; an odd value rounds down, because
    ///   alternation matters more than squeezing in one extra turn.
    static func normalize(_ turns: [ChatTurn], maxTurns: Int) -> [ChatTurn] {
        var pairs: [(user: ChatTurn, assistant: ChatTurn)] = []
        var pendingUser: ChatTurn?

        for turn in turns {
            switch turn.role {
            case .user:
                // A previous `pendingUser` still waiting here means its answer never arrived; it is
                // dropped by being overwritten.
                pendingUser = turn
            case .assistant:
                guard let user = pendingUser else {
                    // An answer with no question ahead of it -- only reachable if folding missed
                    // something. Defensive, not expected.
                    continue
                }
                pendingUser = nil
                guard turn.error == nil else {
                    // A failure carries no answer text worth feeding forward, and pairing it would
                    // let "I could not answer that" shape the next reply.
                    continue
                }
                pairs.append((user: user, assistant: turn))
            }
        }

        let maxPairs = max(0, maxTurns / 2)
        return pairs.suffix(maxPairs).flatMap { [$0.user, $0.assistant] }
    }
}
