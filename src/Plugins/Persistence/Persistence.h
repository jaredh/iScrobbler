//
//  Persistence.h
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/3/2007.
//  Copyright 2007 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import <Cocoa/Cocoa.h>
#import "ISPlugin.h"

@class SongData;
@class PersistentSessionManager;

#define PersistentProfileDidUpdateNotification @"ISPersistentProfileDidUpdateNotification"
#define PersistentProfileDidResetNotification @"ISPersistentProfileDidResetNotification"
#define PersistentProfileWillResetNotification @"PersistentProfileWillResetNotification"
#define PersistentProfileImportProgress @"ISPersistentProfileImportProgress"
#define PersistentProfileDidMigrateNotification @"PersistentProfileDidMigrateNotification"
#define PersistentProfileWillMigrateNotification @"PersistentProfileWillMigrateNotification"
#define PersistentProfileMigrateFailedNotification @"PersistentProfileMigrateFailedNotification"

@interface PersistentProfile : NSObject <ISPlugin> {
    NSManagedObjectContext *mainMOC;
    PersistentSessionManager *sessionMgr;
    id mProxy;
    int importing;
#ifdef ISDEBUG
    NSFileHandle *mLog;
#endif
}

#ifdef ISDEBUG
- (void)log:(NSString*)msg;
#endif

- (PersistentSessionManager*)sessionManager;

- (BOOL)importInProgress;
- (BOOL)initDatabase:(NSError**)failureReason;
- (BOOL)isVersion2;

// adds the song, and updates all sessions
- (void)addSongPlay:(SongData*)song;
- (NSArray*)allSessions;
- (NSArray*)songsForSession:(id)session;
- (NSArray*)ratingsForSession:(id)session;
- (NSArray*)hoursForSession:(id)session;

@end

@interface NSString (ISNSPredicateEscape)

- (NSString*)stringByEscapingNSPredicateReserves;

@end

// Private, exposed only for TopListsController
#define PERSISTENT_STORE_DB \
[@"~/Library/Application Support/org.bergstrand.iscrobbler.persistent.toplists.data" stringByExpandingTildeInPath]

#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
#define IS_CURRENT_STORE_VERSION @"2"
#define IS_STORE_V2 1
#else
#define IS_CURRENT_STORE_VERSION @"1"
#define IS_STORE_V2 0
#endif
