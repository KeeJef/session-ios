// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SessionSnodeKit

@objc(LKClosedGroupPoller)
public final class ClosedGroupPoller: NSObject {
    private var isPolling: Atomic<[String: Bool]> = Atomic([:])
    private var timers: [String: Timer] = [:]
    private let internalQueue: DispatchQueue = DispatchQueue(label: "isPollingQueue")

    // MARK: - Settings
    
    private static let minPollInterval: Double = 2
    private static let maxPollInterval: Double = 30

    // MARK: - Error
    
    private enum Error: LocalizedError {
        case insufficientSnodes
        case pollingCanceled

        internal var errorDescription: String? {
            switch self {
                case .insufficientSnodes: return "No snodes left to poll."
                case .pollingCanceled: return "Polling canceled."
            }
        }
    }

    // MARK: - Initialization
    
    public static let shared = ClosedGroupPoller()

    private override init() { }

    // MARK: - Public API
    
    @objc public func start() {
        #if DEBUG
        assert(Thread.current.isMainThread) // Timers don't do well on background queues
        #endif
        
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        GRDBStorage.shared
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                    )
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .forEach { [weak self] groupPublicKey in
                self?.startPolling(for: groupPublicKey)
            }
    }

    public func startPolling(for groupPublicKey: String) {
        guard isPolling.wrappedValue[groupPublicKey] != true else { return }
        
        // Might be a race condition that the setUpPolling finishes too soon,
        // and the timer is not created, if we mark the group as is polling
        // after setUpPolling. So the poller may not work, thus misses messages.
        isPolling.mutate { $0[groupPublicKey] = true }
        setUpPolling(for: groupPublicKey)
    }

    @objc public func stop() {
        GRDBStorage.shared
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .forEach { [weak self] groupPublicKey in
                self?.stopPolling(for: groupPublicKey)
            }
    }

    public func stopPolling(for groupPublicKey: String) {
        isPolling.mutate { $0[groupPublicKey] = false }
        timers[groupPublicKey]?.invalidate()
    }

    // MARK: - Private API
    
    private func setUpPolling(for groupPublicKey: String) {
        Threading.pollerQueue.async {
            self.poll(groupPublicKey)
                .done(on: Threading.pollerQueue) { [weak self] _ in
                    self?.pollRecursively(groupPublicKey)
                }
                .catch(on: Threading.pollerQueue) { [weak self] error in
                    // The error is logged in poll(_:)
                    self?.pollRecursively(groupPublicKey)
                }
        }
    }

    private func pollRecursively(_ groupPublicKey: String) {
        guard
            isPolling.wrappedValue[groupPublicKey] == true,
            let thread: SessionThread = GRDBStorage.shared.read({ db in try SessionThread.fetchOne(db, id: groupPublicKey) })
        else { return }
        
        // Get the received date of the last message in the thread. If we don't have any messages yet, pick some
        // reasonable fake time interval to use instead
        
        let lastMessageDate: Date = GRDBStorage.shared
            .read { db in
                try thread
                    .interactions
                    .select(.receivedAtTimestampMs)
                    .order(Interaction.Columns.timestampMs.desc)
                    .asRequest(of: Int64.self)
                    .fetchOne(db)
            }
            .map { receivedAtTimestampMs -> Date? in
                guard receivedAtTimestampMs > 0 else { return nil }
                
                return Date(timeIntervalSince1970: (TimeInterval(receivedAtTimestampMs) / 1000))
            }
            .defaulting(to: Date().addingTimeInterval(-5 * 60))
        let timeSinceLastMessage: TimeInterval = Date().timeIntervalSince(lastMessageDate)
        let minPollInterval: Double = ClosedGroupPoller.minPollInterval
        let limit: Double = (12 * 60 * 60)
        let a = (ClosedGroupPoller.maxPollInterval - minPollInterval) / limit
        let nextPollInterval = a * min(timeSinceLastMessage, limit) + minPollInterval
        SNLog("Next poll interval for closed group with public key: \(groupPublicKey) is \(nextPollInterval) s.")
        timers[groupPublicKey] = Timer.scheduledTimerOnMainThread(withTimeInterval: nextPollInterval, repeats: false) { [weak self] timer in
            timer.invalidate()
            Threading.pollerQueue.async {
                self?.poll(groupPublicKey).done(on: Threading.pollerQueue) { _ in
                    self?.pollRecursively(groupPublicKey)
                }.catch(on: Threading.pollerQueue) { error in
                    // The error is logged in poll(_:)
                    self?.pollRecursively(groupPublicKey)
                }
            }
        }
    }

    private func poll(_ groupPublicKey: String) -> Promise<Void> {
        guard isPolling.wrappedValue[groupPublicKey] == true else { return Promise.value(()) }
        
        let promise: Promise<Void> = SnodeAPI.getSwarm(for: groupPublicKey)
            .then2 { [weak self] swarm -> Promise<(Snode, [SnodeReceivedMessage])> in
                // randomElement() uses the system's default random generator, which is cryptographically secure
                guard let snode = swarm.randomElement() else { return Promise(error: Error.insufficientSnodes) }
                guard self?.isPolling.wrappedValue[groupPublicKey] == true else {
                    return Promise(error: Error.pollingCanceled)
                }
                
                return SnodeAPI.getMessages(from: snode, associatedWith: groupPublicKey)
                    .map2 { messages in (snode, messages) }
            }
            .done2 { [weak self] snode, messages in
                guard self?.isPolling.wrappedValue[groupPublicKey] == true else { return }
                
                if !messages.isEmpty {
                    var messageCount: Int = 0
                    
                    GRDBStorage.shared.write { db in
                        var jobDetailMessages: [MessageReceiveJob.Details.MessageInfo] = []
                        
                        messages.forEach { message in
                            guard let envelope = SNProtoEnvelope.from(message) else { return }
                            
                            do {
                                let serialisedData: Data = try envelope.serializedData()
                                _ = try message.info.inserted(db)
                                
                                // Ignore hashes for messages we have previously handled
                                guard try SnodeReceivedMessageInfo.filter(SnodeReceivedMessageInfo.Columns.hash == message.info.hash).fetchCount(db) == 1 else {
                                    throw MessageReceiverError.duplicateMessage
                                }
                                
                                jobDetailMessages.append(
                                    MessageReceiveJob.Details.MessageInfo(
                                        data: serialisedData,
                                        serverHash: message.info.hash,
                                        serverExpirationTimestamp: (TimeInterval(message.info.expirationDateMs) / 1000)
                                    )
                                )
                            }
                            catch {
                                switch error {
                                    // Ignore duplicate messages
                                    case .SQLITE_CONSTRAINT_UNIQUE, MessageReceiverError.duplicateMessage: break
                                    default: SNLog("Failed to deserialize envelope due to error: \(error).")
                                }
                            }
                        }
                        
                        messageCount = jobDetailMessages.count
                        
                        JobRunner.add(
                            db,
                            job: Job(
                                variant: .messageReceive,
                                behaviour: .runOnce,
                                threadId: groupPublicKey,
                                details: MessageReceiveJob.Details(
                                    messages: jobDetailMessages,
                                    isBackgroundPoll: false
                                )
                            )
                        )
                    }
                    
                    SNLog("Received \(messageCount) new message\(messageCount == 1 ? "" : "s") in closed group with public key: \(groupPublicKey) (\(messages.count - messageCount) duplicates)")
                }
            }
            .map { _ in }
        
        promise.catch2 { error in
            SNLog("Polling failed for closed group with public key: \(groupPublicKey) due to error: \(error).")
        }
        
        return promise
    }
}
