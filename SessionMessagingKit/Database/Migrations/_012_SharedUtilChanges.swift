// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration makes the neccessary changes to support the updated user config syncing system
enum _012_SharedUtilChanges: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "SharedUtilChanges"
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        // Add `markedAsUnread` to the thread table
        try db.alter(table: SessionThread.self) { t in
            t.add(.markedAsUnread, .boolean)
            t.add(.pinnedPriority, .integer)
        }
        
        // SQLite doesn't support adding a new primary key after creation so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        struct TmpGroupMember: Codable, TableRecord, FetchableRecord, PersistableRecord, ColumnExpressible {
            static var databaseTableName: String { "tmpGroupMember" }
            
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case groupId
                case profileId
                case role
                case isHidden
            }

            public let groupId: String
            public let profileId: String
            public let role: GroupMember.Role
            public let isHidden: Bool
        }
        
        try db.create(table: TmpGroupMember.self) { t in
            // Note: Since we don't know whether this will be stored against a 'ClosedGroup' or
            // an 'OpenGroup' we add the foreign key constraint against the thread itself (which
            // shares the same 'id' as the 'groupId') so we can cascade delete automatically
            t.column(.groupId, .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references(SessionThread.self, onDelete: .cascade)   // Delete if Thread deleted
            t.column(.profileId, .text)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.role, .integer).notNull()
            t.column(.isHidden, .boolean)
                .notNull()
                .defaults(to: false)
            
            t.primaryKey([.groupId, .profileId, .role])
        }
        
        // Retrieve the non-duplicate group member entries from the old table
        let nonDuplicateGroupMembers: [TmpGroupMember] = try GroupMember
            .select(.groupId, .profileId, .role, .isHidden)
            .group(GroupMember.Columns.groupId, GroupMember.Columns.profileId, GroupMember.Columns.role)
            .asRequest(of: TmpGroupMember.self)
            .fetchAll(db)
        
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try nonDuplicateGroupMembers.forEach { try $0.save(db) }
        try db.drop(table: GroupMember.self)
        try db.rename(table: TmpGroupMember.databaseTableName, to: GroupMember.databaseTableName)
        
        // SQLite doesn't support removing unique constraints so we need to create a new table with
        // the setup we want, copy data from the old table over, drop the old table and rename the new table
        struct TmpClosedGroupKeyPair: Codable, TableRecord, FetchableRecord, PersistableRecord, ColumnExpressible {
            static var databaseTableName: String { "tmpClosedGroupKeyPair" }
            
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case threadId
                case publicKey
                case secretKey
                case receivedTimestamp
                case threadKeyPairHash
            }
            
            public let threadId: String
            public let publicKey: Data
            public let secretKey: Data
            public let receivedTimestamp: TimeInterval
            public let threadKeyPairHash: String
        }
        
        try db.alter(table: ClosedGroupKeyPair.self) { t in
            t.add(.threadKeyPairHash, .text).defaults(to: "")
        }
        try db.create(table: TmpClosedGroupKeyPair.self) { t in
            t.column(.threadId, .text)
                .notNull()
                .indexed()                                            // Quicker querying
                .references(ClosedGroup.self, onDelete: .cascade)     // Delete if ClosedGroup deleted
            t.column(.publicKey, .blob).notNull()
            t.column(.secretKey, .blob).notNull()
            t.column(.receivedTimestamp, .double)
                .notNull()
                .indexed()                                            // Quicker querying
            t.column(.threadKeyPairHash, .integer)
                .notNull()
                .unique()
                .indexed()
        }
        // Insert into the new table, drop the old table and rename the new table to be the old one
        try ClosedGroupKeyPair
            .fetchAll(db)
            .map { keyPair in
                ClosedGroupKeyPair(
                    threadId: keyPair.threadId,
                    publicKey: keyPair.publicKey,
                    secretKey: keyPair.secretKey,
                    receivedTimestamp: keyPair.receivedTimestamp
                )
            }
            .map { keyPair in
                TmpClosedGroupKeyPair(
                    threadId: keyPair.threadId,
                    publicKey: keyPair.publicKey,
                    secretKey: keyPair.secretKey,
                    receivedTimestamp: keyPair.receivedTimestamp,
                    threadKeyPairHash: keyPair.threadKeyPairHash
                )
            }
            .forEach { try? $0.insert(db) } // Ignore duplicate values
        try db.drop(table: ClosedGroupKeyPair.self)
        try db.rename(table: TmpClosedGroupKeyPair.databaseTableName, to: ClosedGroupKeyPair.databaseTableName)
        
        // Add an index for the 'ClosedGroupKeyPair' so we can lookup existing keys more easily
        try db.createIndex(
            on: ClosedGroupKeyPair.self,
            columns: [.threadId, .threadKeyPairHash]
        )
        
        // New table for storing the latest config dump for each type
        try db.create(table: ConfigDump.self) { t in
            t.column(.variant, .text)
                .notNull()
            t.column(.publicKey, .text)
                .notNull()
                .indexed()
            t.column(.data, .blob)
                .notNull()
            
            t.primaryKey([.variant, .publicKey])
        }
        
        // Migrate the 'isPinned' value to 'pinnedPriority'
        try SessionThread
            .filter(SessionThread.Columns.isPinned == true)
            .updateAll(
                db,
                SessionThread.Columns.pinnedPriority.set(to: 1)
            )
        
        // If we don't have an ed25519 key then no need to create cached dump data
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // There was previously a bug which allowed users to fully delete the 'Note to Self'
        // conversation but we don't want that, so create it again if it doesn't exists
        try SessionThread
            .fetchOrCreate(db, id: userPublicKey, variant: .contact, shouldBeVisible: false)
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
