import SwiftUI

/// The GitHub round trips every thread-card surface shares — reply,
/// resolve/unresolve, reaction toggles, comment edit/delete, and
/// click-away draft persistence. One implementation behind both the PR
/// file views and the overview's review discussion list (spec:
/// pr-review-discussion). Each view supplies its own
/// reader-in-place re-render (`mutatePreservingScroll`) and owns its
/// native delete confirmation; everything below the confirmation is
/// identical across surfaces.
@MainActor
struct ThreadCardActions {
    let state: AppState
    let sessionID: String
    let proxy: WebViewProxy
    /// Disk key for click-away drafts. Draft keys already carry thread
    /// and comment ids, so surfaces can't collide — the overview passes
    /// a pseudo-path no repo file can have.
    let draftPath: String
    /// Re-render wrapper that keeps the reader in place across a model
    /// mutation: the file views capture mode + open cards, the overview
    /// a scroll fraction.
    let mutatePreservingScroll: (@escaping () -> Void) -> Void

    private var session: PRSession? { state.session(sessionID) }

    func sendThreadReply(rootID: Int, body: String, draftKey: String) {
        guard let session else {
            // The page already cleared its composer — never drop the text.
            restoreDraftAfterFailure(key: draftKey, text: body)
            state.lastError = "Could not post the reply — the PR session is "
                + "no longer available. Your text was kept as a draft."
            return
        }
        Task {
            do {
                let posted = try await state.client.replyToReviewComment(
                    session.ref, rootID: rootID, body: body)
                // Fold the returned comment in directly — the list
                // endpoint can lag the write, and a refetch racing it
                // would hide the reply the user just watched post. The
                // reader stays in place through the re-render.
                mutatePreservingScroll {
                    state.applyPostedReply(sessionID: sessionID, comment: posted)
                }
            } catch {
                restoreDraftAfterFailure(key: draftKey, text: body)
                state.lastError = "Could not post the reply: \(error.localizedDescription)"
            }
        }
    }

    func setThreadResolved(rootID: Int, resolved: Bool) {
        guard let session, let meta = session.threadMeta[rootID] else {
            state.lastError = "Thread state unavailable — try refreshing the PR."
            return
        }
        Task {
            do {
                try await state.client.setThreadResolved(nodeID: meta.nodeID, resolved: resolved)
                // Fold locally like every other confirmed mutation — a
                // refetch here reads the lagging list endpoint and can
                // clobber a reply folded in moments earlier.
                mutatePreservingScroll {
                    state.applyThreadResolved(sessionID: sessionID,
                                              rootID: rootID, resolved: resolved)
                }
            } catch {
                state.lastError = error.localizedDescription
            }
        }
    }

    /// A reaction toggle from the page (already flipped optimistically
    /// there). Success folds the confirmed state into the model — the
    /// re-rendered page then agrees with what the chip already shows;
    /// failure reverts the chip and surfaces the error.
    func handleReactionToggle(commentID: Int, content: String, reacted: Bool) {
        guard let session, let kind = ReactionKind(rawValue: content) else { return }
        guard let nodeID = CommentReactions.commentNodeID(of: commentID,
                                                          in: session.threadMeta) else {
            proxy.revertReaction(commentID: commentID, content: content, attempted: reacted)
            state.lastError = "Reaction state unavailable — try refreshing the PR."
            return
        }
        // Serialized per comment id: a rapid double-toggle's add/remove
        // pair must reach GitHub in click order.
        state.serializeReactionWrite(commentID: commentID) {
            do {
                try await state.client.setReaction(subjectID: nodeID, content: kind,
                                                   add: reacted)
                mutatePreservingScroll {
                    state.applyReaction(sessionID: sessionID, commentID: commentID,
                                        content: content, reacted: reacted)
                }
            } catch {
                proxy.revertReaction(commentID: commentID, content: content,
                                     attempted: reacted)
                state.lastError = "Could not update the reaction: \(error.localizedDescription)"
            }
        }
    }

    /// Save from the in-card edit composer. Success reloads comments;
    /// failure puts the text back as the comment's edit draft so nothing
    /// typed is lost.
    func handleCommentEdit(commentID: Int, body: String, draftKey: String) {
        guard let session else { return }
        Task {
            do {
                try await state.client.updateReviewComment(session.ref,
                                                           commentID: commentID, body: body)
                mutatePreservingScroll {
                    state.applyCommentEdit(sessionID: sessionID,
                                           commentID: commentID, body: body)
                }
            } catch {
                restoreDraftAfterFailure(key: draftKey, text: body)
                state.lastError = "Could not save the edit: \(error.localizedDescription)"
            }
        }
    }

    /// Runs after the view's native confirmation. Thread grouping keeps
    /// any surviving replies together (ReviewThreads.group's deleted-root
    /// fallback), so the reloaded page never orphans them.
    func deleteComment(_ commentID: Int) {
        guard let session else { return }
        Task {
            do {
                try await state.client.deleteReviewComment(session.ref, commentID: commentID)
                mutatePreservingScroll {
                    state.applyCommentDelete(sessionID: sessionID, commentID: commentID)
                }
            } catch {
                state.lastError = "Could not delete the comment: \(error.localizedDescription)"
            }
        }
    }

    /// Click-away draft sync from the page; empty text discards.
    func saveComposerDraft(key: String, text: String) {
        guard let session else {
            // No session, no ref/head to key disk persistence to. The page
            // still holds the text in its own draft map — say so instead
            // of silently dropping the sync (empty text is a discard and
            // needs no noise).
            if !text.isEmpty {
                state.lastError = "The PR session is no longer available — "
                    + "the draft could not be saved to disk."
            }
            return
        }
        ComposerDraftStore.save(jsKey: key, text: text, ref: session.ref,
                                headSHA: session.details.head.sha, path: draftPath)
    }

    /// A post failed after the page already cleared its composer: put the
    /// text back on disk AND into the live page so reopening restores it.
    func restoreDraftAfterFailure(key: String, text: String) {
        guard !key.isEmpty else { return }
        saveComposerDraft(key: key, text: text)
        proxy.setComposerDrafts([key: text])
    }
}

/// The native destructive confirmation every thread-card surface runs
/// before a comment delete — page JS never confirms with its own chrome.
struct DeleteCommentConfirmation: ViewModifier {
    @Binding var commentID: Int?
    let onConfirm: (Int) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete this comment?",
                                   isPresented: Binding(
                                       get: { commentID != nil },
                                       set: { if !$0 { commentID = nil } })) {
            Button("Delete comment", role: .destructive) {
                if let id = commentID {
                    commentID = nil
                    onConfirm(id)
                }
            }
        } message: {
            Text("The comment will be removed from GitHub. Replies from others will stay.")
        }
    }
}
