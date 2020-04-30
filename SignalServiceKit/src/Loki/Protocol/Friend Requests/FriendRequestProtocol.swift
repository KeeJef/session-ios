import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • Consider making it the caller's responsibility to manage the database transaction (this helps avoid nested or unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.
// • Document the expected cases for everything.
// • Express those cases in tests.

/// See [The Session Friend Request Protocol](https://github.com/loki-project/session-protocol-docs/wiki/Friend-Requests) for more information.
@objc(LKFriendRequestProtocol)
public final class FriendRequestProtocol : NSObject {

    internal static var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }

    // MARK: - General
    @objc(shouldInputBarBeEnabledForThread:)
    public static func shouldInputBarBeEnabled(for thread: TSThread) -> Bool {
        // Friend requests have nothing to do with groups, so if this isn't a contact thread the input bar should be enabled
        guard let thread = thread as? TSContactThread else { return true }
        // If this is a note to self, the input bar should be enabled
        if SessionMetaProtocol.isMessageNoteToSelf(thread) { return true }
        let contactID = thread.contactIdentifier()
        var linkedDeviceThreads: Set<TSContactThread> = []
        storage.dbReadConnection.read { transaction in
            linkedDeviceThreads = LokiDatabaseUtilities.getLinkedDeviceThreads(for: contactID, in: transaction)
        }
        // If the current user is friends with any of the other user's devices, the input bar should be enabled
        if linkedDeviceThreads.contains(where: { $0.isContactFriend }) { return true }
        // If no friend request has been sent, the input bar should be enabled
        if !linkedDeviceThreads.contains(where: { $0.hasPendingFriendRequest }) { return true }
        // There must be a pending friend request
        return false
    }

    @objc(shouldAttachmentButtonBeEnabledForThread:)
    public static func shouldAttachmentButtonBeEnabled(for thread: TSThread) -> Bool {
        // Friend requests have nothing to do with groups, so if this isn't a contact thread the attachment button should be enabled
        guard let thread = thread as? TSContactThread else { return true }
        // If this is a note to self, the attachment button should be enabled
        if SessionMetaProtocol.isMessageNoteToSelf(thread) { return true }
        let contactID = thread.contactIdentifier()
        var linkedDeviceThreads: Set<TSContactThread> = []
        storage.dbReadConnection.read { transaction in
            linkedDeviceThreads = LokiDatabaseUtilities.getLinkedDeviceThreads(for: contactID, in: transaction)
        }
        // If the current user is friends with any of the other user's devices, the attachment button should be enabled
        if linkedDeviceThreads.contains(where: { $0.isContactFriend }) { return true }
        // If no friend request has been sent, the attachment button should be disabled
        if !linkedDeviceThreads.contains(where: { $0.hasPendingFriendRequest }) { return false }
        // There must be a pending friend request
        return false
    }

    // MARK: - Sending
    @objc(acceptFriendRequestFrom:in:using:)
    public static func acceptFriendRequest(from hexEncodedPublicKey: String, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        // Accept all outstanding friend requests associated with this user and try to establish sessions with the
        // subset of their devices that haven't sent a friend request.
        let linkedDeviceThreads = LokiDatabaseUtilities.getLinkedDeviceThreads(for: hexEncodedPublicKey, in: transaction) // This doesn't create new threads if they don't exist yet
        // FIXME: Capture send failures
        for thread in linkedDeviceThreads {
            if thread.hasPendingFriendRequest {
                sendFriendRequestAcceptanceMessage(to: thread.contactIdentifier(), in: thread, using: transaction) // NOT hexEncodedPublicKey
                thread.saveFriendRequestStatus(.friends, with: transaction)
            } else {
                MultiDeviceProtocol.getAutoGeneratedMultiDeviceFRMessageSend(for: thread.contactIdentifier(), in: transaction) // NOT hexEncodedPublicKey
                .done(on: OWSDispatch.sendingQueue()) { autoGeneratedFRMessageSend in
                    let messageSender = SSKEnvironment.shared.messageSender
                    messageSender.sendMessage(autoGeneratedFRMessageSend)
                }
            }
        }
    }

    @objc(sendFriendRequestAcceptanceMessageToHexEncodedPublicKey:in:using:)
    public static func sendFriendRequestAcceptanceMessage(to hexEncodedPublicKey: String, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        let ephemeralMessage = EphemeralMessage(in: thread)
        let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
        messageSenderJobQueue.add(message: ephemeralMessage, transaction: transaction)
    }

    @objc(declineFriendRequest:in:using:)
    public static func declineFriendRequest(_ friendRequest: TSIncomingMessage, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        thread.saveFriendRequestStatus(.none, with: transaction)
        // Delete the pre key bundle for the given contact. This ensures that if we send a
        // new message after this, it restarts the friend request process from scratch.
        let senderID = friendRequest.authorId
        storage.removePreKeyBundle(forContact: senderID, transaction: transaction)
    }

    // MARK: - Receiving
    @objc(isFriendRequestFromBeforeRestoration:)
    public static func isFriendRequestFromBeforeRestoration(_ envelope: SSKProtoEnvelope) -> Bool {
        // The envelope type is set during UD decryption
        let restorationTimeInMs = UInt64(storage.getRestorationTime() * 1000)
        return (envelope.type == .friendRequest && envelope.timestamp < restorationTimeInMs)
    }

    @objc(canFriendRequestBeAutoAcceptedForHexEncodedPublicKey:in:using:)
    public static func canFriendRequestBeAutoAccepted(for hexEncodedPublicKey: String, in thread: TSThread, using transaction: YapDatabaseReadTransaction) -> Bool {
        if thread.hasCurrentUserSentFriendRequest {
            // This can happen if Alice sent Bob a friend request, Bob declined, but then Bob changed his
            // mind and sent a friend request to Alice. In this case we want Alice to auto-accept the request
            // and send a friend request accepted message back to Bob. We don't check that sending the
            // friend request accepted message succeeds. Even if it doesn't, the thread's current friend
            // request status will be set to LKThreadFriendRequestStatusFriends for Alice making it possible
            // for Alice to send messages to Bob. When Bob receives a message, his thread's friend request status
            // will then be set to LKThreadFriendRequestStatusFriends. If we do check for a successful send
            // before updating Alice's thread's friend request status to LKThreadFriendRequestStatusFriends,
            // we can end up in a deadlock where both users' threads' friend request statuses are
            // LKThreadFriendRequestStatusRequestSent.
            return true
        }
        // Auto-accept any friend requests from the user's own linked devices
        let userLinkedDeviceHexEncodedPublicKeys = LokiDatabaseUtilities.getLinkedDeviceHexEncodedPublicKeys(for: getUserHexEncodedPublicKey(), in: transaction)
        if userLinkedDeviceHexEncodedPublicKeys.contains(hexEncodedPublicKey) { return true }
        // Auto-accept if the user is friends with any of the sender's linked devices.
        let senderLinkedDeviceThreads = LokiDatabaseUtilities.getLinkedDeviceThreads(for: hexEncodedPublicKey, in: transaction)
        if senderLinkedDeviceThreads.contains(where: { $0.isContactFriend }) { return true }
        // We can't auto-accept
        return false
    }

    @objc(handleFriendRequestAcceptanceIfNeeded:in:)
    public static func handleFriendRequestAcceptanceIfNeeded(_ envelope: SSKProtoEnvelope, in transaction: YapDatabaseReadWriteTransaction) {
        // The envelope source is set during UD decryption
        let hexEncodedPublicKey = envelope.source!
        // The envelope type is set during UD decryption.
        guard !envelope.isGroupChatMessage && envelope.type != .friendRequest else { return }
        // If we get an envelope that isn't a friend request, then we can infer that we had to use
        // Signal cipher decryption and thus that we have a session with the other person.
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        // We shouldn't be able to skip from none to friends
        guard thread.friendRequestStatus != .none else { return }
        // Become friends
        thread.saveFriendRequestStatus(.friends, with: transaction)
        if let existingFriendRequestMessage = thread.getLastInteraction(with: transaction) as? TSOutgoingMessage,
            existingFriendRequestMessage.isFriendRequest {
            existingFriendRequestMessage.saveFriendRequestStatus(.accepted, with: transaction)
        }
        /*
        // Send our P2P details
        if let addressMessage = LokiP2PAPI.onlineBroadcastMessage(forThread: thread) {
            let messageSenderJobQueue = SSKEnvironment.shared.messageSenderJobQueue
            messageSenderJobQueue.add(message: addressMessage, transaction: transaction)
        }
         */
    }

    @objc(handleFriendRequestMessageIfNeeded:associatedWith:wrappedIn:in:using:)
    public static func handleFriendRequestMessageIfNeeded(_ dataMessage: SSKProtoDataMessage, associatedWith message: TSIncomingMessage, wrappedIn envelope: SSKProtoEnvelope, in thread: TSThread, using transaction: YapDatabaseReadWriteTransaction) {
        guard !envelope.isGroupChatMessage else {
            print("[Loki] Ignoring friend request in group chat.")
            return
        }
        // The envelope source is set during UD decryption
        let hexEncodedPublicKey = envelope.source!
        // The envelope type is set during UD decryption.
        guard envelope.type == .friendRequest else {
            print("[Loki] Ignoring friend request logic for non friend request type envelope.")
            return
        }
        if canFriendRequestBeAutoAccepted(for: hexEncodedPublicKey, in: thread, using: transaction) {
            thread.saveFriendRequestStatus(.friends, with: transaction)
            var existingFriendRequestMessage: TSOutgoingMessage?
            thread.enumerateInteractions(with: transaction) { interaction, _ in
                if let outgoingMessage = interaction as? TSOutgoingMessage, outgoingMessage.isFriendRequest {
                    existingFriendRequestMessage = outgoingMessage
                }
            }
            if let existingFriendRequestMessage = existingFriendRequestMessage {
                existingFriendRequestMessage.saveFriendRequestStatus(.accepted, with: transaction)
            }
            sendFriendRequestAcceptanceMessage(to: hexEncodedPublicKey, in: thread, using: transaction)
        } else if !thread.isContactFriend {
            // Checking that the sender of the message isn't already a friend is necessary because otherwise
            // the following situation can occur: Alice and Bob are friends. Bob loses his database and his
            // friend request status is reset to LKThreadFriendRequestStatusNone. Bob now sends Alice a friend
            // request. Alice's thread's friend request status is reset to
            // LKThreadFriendRequestStatusRequestReceived.
            thread.saveFriendRequestStatus(.requestReceived, with: transaction)
            // Except for the message.friendRequestStatus = LKMessageFriendRequestStatusPending line below, all of this is to ensure that
            // there's only ever one message with status LKMessageFriendRequestStatusPending in a thread (where a thread is the combination
            // of all threads belonging to the linked devices of a user).
            let linkedDeviceThreads = LokiDatabaseUtilities.getLinkedDeviceThreads(for: hexEncodedPublicKey, in: transaction)
            for thread in linkedDeviceThreads {
                thread.enumerateInteractions(with: transaction) { interaction, _ in
                    guard let incomingMessage = interaction as? TSIncomingMessage, incomingMessage.friendRequestStatus != .none else { return }
                    incomingMessage.saveFriendRequestStatus(.none, with: transaction)
                }
            }
            message.friendRequestStatus = .pending
            // Don't save yet. This is done in finalizeIncomingMessage:thread:masterThread:envelope:transaction.
        }
    }
}
