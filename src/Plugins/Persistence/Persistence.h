//
//  Persistence.h
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/3/2007.
//  Copyright 2007,2008 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import <Cocoa/Cocoa.h>
#import "ISPlugin.h"

@class SongData;
@class PersistentSessionManager;

ISEXPORT_CLASS
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
// versions are cumulative, so [isVersion2] will be true for for a V3 DB
- (BOOL)isVersion2;
- (BOOL)isVersion3;

// write
- (void)addSongPlay:(SongData*)song; // adds the song, and updates all sessions
- (void)rename:(NSManagedObjectID*)moid to:(NSString*)newTitle;
- (void)removeObject:(NSManagedObjectID*)moid;
- (void)addHistoryEvents:(NSArray*)playDates forObject:(NSManagedObjectID*)moid;
- (void)removeHistoryEvent:(NSManagedObjectID*)eventID forObject:(NSManagedObjectID*)moid;

// read
- (NSArray*)allSessions;
- (NSArray*)songsForSession:(id)session;
- (NSArray*)ratingsForSession:(id)session;
- (NSArray*)hoursForSession:(id)session;

@end

@interface PersistentProfile (PItemAdditions)
- (BOOL)isSong:(NSManagedObject*)item;
- (BOOL)isArtist:(NSManagedObject*)item;
- (BOOL)isAlbum:(NSManagedObject*)item;
@end

#define PersistentProfileDidFinishInitialization @"PersistentProfileDidFinishInitialization"
#define PersistentProfileDidUpdateNotification @"ISPersistentProfileDidUpdateNotification"
#define PersistentProfileDidResetNotification @"ISPersistentProfileDidResetNotification"
#define PersistentProfileWillResetNotification @"PersistentProfileWillResetNotification"
#define PersistentProfileImportProgress @"ISPersistentProfileImportProgress"
#define PersistentProfileDidMigrateNotification @"PersistentProfileDidMigrateNotification"
#define PersistentProfileWillMigrateNotification @"PersistentProfileWillMigrateNotification"
#define PersistentProfileMigrateFailedNotification @"PersistentProfileMigrateFailedNotification"
#define PersistentProfileDidExportNotification @"PersistentProfileDidExportNotification"
#define PersistentProfileWillExportNotification @"PersistentProfileWillExportNotification"
#define PersistentProfileExportFailedNotification @"PersistentProfileExportFailedNotification"

#define PersistentProfileWillEditObject @"PersistentProfileWillEditObject"
#define PersistentProfileDidEditObject @"PersistentProfileDidEditObject"
#define PersistentProfileFailedEditObject @"PersistentProfileFailedEditObject"

@interface NSString (ISNSPredicateEscape)
- (NSString*)stringByEscapingNSPredicateReserves;
@end

// Private, exposed only for TopListsController
#define PERSISTENT_STORE_DB_21X \
[@"~/Library/Application Support/org.bergstrand.iscrobbler.persistent.toplists.data" stringByExpandingTildeInPath]

#define PERSISTENT_STORE_DB \
[[[NSFileManager defaultManager] iscrobblerSupportFolder] stringByAppendingPathComponent:@"toplists.data"]

#define PERSISTENT_STORE_XML \
[[[NSFileManager defaultManager] iscrobblerSupportFolder] stringByAppendingPathComponent:@"iScrobbler Music.xml"]

#define PERSISTENT_STORE_DB_LOCATION_VERSION @"22X"

#define IS_STORE_V2 1
