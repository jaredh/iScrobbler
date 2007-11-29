//
//  Persistence.h
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/3/2007.
//  Copyright 2007 Brian Bergstrand.
//
//  Released under the GPL, license details available res/gpl.txt
//

#import <Cocoa/Cocoa.h>

@class SongData;
@class PersistentSessionManager;

#define PersistentProfileDidUpdateNotification @"ISPersistentProfileDidUpdateNotification"
#define PersistentProfileDidResetNotification @"ISPersistentProfileDidResetNotification"
#define PersistentProfileWillResetNotification @"PersistentProfileWillResetNotification"
#define PersistentProfileImportProgress @"ISPersistentProfileImportProgress"

@interface PersistentProfile : NSObject {
    NSManagedObjectContext *mainMOC;
    PersistentSessionManager *sessionMgr;
    int importing;
}

+ (PersistentProfile*)sharedInstance;
+ (BOOL)newProfile;

- (BOOL)importInProgress;

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
