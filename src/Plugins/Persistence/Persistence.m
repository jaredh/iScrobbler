//
//  Persistence.m
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/3/2007.
//  Copyright 2007-2009 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import <libkern/OSAtomic.h>

#import "Persistence.h"
#import "PersistentSessionManager.h"
#import "PersistenceImport.h"
#import "SongData.h"
#import "ISThreadMessenger.h"

/**
Simple CoreDate overview: http://cocoadevcentral.com/articles/000086.php
Important CoreData behaviors:
http://www.cocoadev.com/index.pl?CoreDataInheritanceIssues
http://www.cocoadev.com/index.pl?CoreDataQuestions
**/

__private_extern__ BOOL version3 = NO;

@interface PersistentSessionManager (Private)
- (void)recreateRatingsCacheForSession:(NSManagedObject*)session songs:(NSArray*)songs moc:(NSManagedObjectContext*)moc;
@end

@interface PersistentSessionManager (Editors)
// generic interface to execute an edit
- (void)editObject:(NSDictionary*)args;
// specfic editors -- these are private
- (NSError*)rename:(NSManagedObjectID*)moid to:(NSString*)newName;
- (NSError*)removeObject:(NSManagedObjectID*)moid;
- (NSError*)addHistoryEvents:(NSArray*)playDates forObject:(NSManagedObjectID*)moid;
- (NSError*)removeHistoryEvent:(NSManagedObjectID*)eventID forObject:(NSManagedObjectID*)moid;
@end

@interface PersistentProfile (SessionManagement)
- (BOOL)performSelectorOnSessionMgrThread:(SEL)selector withObject:(id)object;
- (void)pingSessionManager;
- (BOOL)addSongPlaysToAllSessions:(NSArray*)queue;
@end

@interface PersistentProfile (ExportAdditions)
- (BOOL)exportDatabaseAsXMLWithModel:(NSManagedObjectModel*)model from:(NSURL*)from to:(NSURL*)to;
@end

@interface PersistentSessionManager (ExportAdditions)
- (void)exportDatabase:(NSString*)path;
@end

@implementation PersistentProfile

- (NSString*)currentStoreVersion
{    
    return ([self isVersion3] ? @"3" : @"2");
}

- (void)displayErrorWithTitle:(NSString*)title message:(NSString*)msg
{
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
        [[NSApp delegate] methodSignatureForSelector:@selector(displayErrorWithTitle:message:)]];
    [inv retainArguments];
    [inv setTarget:[NSApp delegate]]; // arg 0
    [inv setSelector:@selector(displayErrorWithTitle:message:)]; // arg 1
    [inv setArgument:&title atIndex:2];
    [inv setArgument:&msg atIndex:3];
    [inv performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:NO];
}

- (void)displayWarningWithTitle:(NSString*)title message:(NSString*)msg
{
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
        [[NSApp delegate] methodSignatureForSelector:@selector(displayWarningWithTitle:message:)]];
    [inv retainArguments];
    [inv setTarget:[NSApp delegate]]; // arg 0
    [inv setSelector:@selector(displayWarningWithTitle:message:)]; // arg 1
    [inv setArgument:&title atIndex:2];
    [inv setArgument:&msg atIndex:3];
    [inv performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:NO];
}

- (void)postNoteWithArgs:(NSDictionary*)args
{
    @try {
    [[NSNotificationCenter defaultCenter] postNotificationName:[args objectForKey:@"name"] object:self
        userInfo:[args objectForKey:@"info"]];
    } @catch (id e) {
        ScrobLog(SCROB_LOG_ERR, @"exception while posting notification '%@': %@", [args objectForKey:@"name"], e);
    }
}

- (void)postNote:(NSString*)name
{
    @try {
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self];
    } @catch (id e) {
        ScrobLog(SCROB_LOG_ERR, @"exception while posting notification '%@': %@", name, e);
    }
}

- (void)profileDidChangeWithUpdatedObjects:(NSSet*)updatedObjects
{   
    // we assume all changes are done from a bg thread
    // refault sessions
    [[self allSessions] makeObjectsPerformSelector:@selector(refreshSelf)];
    (void)[self allSessions]; // fault the data back in
    
    if (updatedObjects) {
        [self postNoteWithArgs:[NSDictionary dictionaryWithObjectsAndKeys:
            PersistentProfileDidUpdateNotification, @"name",
            [NSDictionary dictionaryWithObject:updatedObjects forKey:NSUpdatedObjectsKey], @"info",
            nil]];
    } else
        [self postNote:PersistentProfileDidUpdateNotification];
}

- (BOOL)save:(NSManagedObjectContext*)moc withNotification:(BOOL)notify error:(NSError**)failure
{
    NSError *error;
    NSSet *updateObjects = notify ? [[moc updatedObjects] valueForKey:@"objectID"] : nil;
    int retries = 0;
    do {
        if ([moc save:&error]) {
            if (notify)
                [self performSelectorOnMainThread:@selector(profileDidChangeWithUpdatedObjects:) withObject:updateObjects waitUntilDone:NO];
            if (failure)
                failure = nil;
            return (YES);
        }
        
        // An error can occur if Time Machine is backing up our DB at the moment we try to save.
        ++retries;
        if (retries <= 2 && NO == [NSThread isMainThread]) {
            ScrobLog(SCROB_LOG_WARN, @"failed to save persistent db (%@ -- %@) - retrying in %d seconds", error,
                [[error userInfo] objectForKey:NSDetailedErrorsKey], retries * 5);
            sleep(retries * 5);
        } else
            break;
    } while (1);
    
    if (failure)
        *failure = error;
    NSString *title = NSLocalizedStringFromTableInBundle(@"Local Charts Could Not Be dd", nil, [NSBundle bundleForClass:[self class]], "");
    NSString *msg = NSLocalizedStringFromTableInBundle(@"The local charts database could not be saved. This may be an indication of corruption. See the log file for more information.", nil, [NSBundle bundleForClass:[self class]], "");
    [self displayErrorWithTitle:title message:msg];
    
    ScrobLog(SCROB_LOG_ERR, @"failed to save persistent db (%@ -- %@)", error,
        [[error userInfo] objectForKey:NSDetailedErrorsKey]);
    [moc rollback];
    return (NO);
}

- (BOOL)save:(NSManagedObjectContext*)moc withNotification:(BOOL)notify
{
    return ([self save:moc withNotification:notify error:nil]);
}

- (BOOL)save:(NSManagedObjectContext*)moc
{
    return ([self save:moc withNotification:YES error:nil]);
}

- (void)resetMain
{
    // Prevent access while we are reseting
    NSManagedObjectContext *moc = mainMOC;
    mainMOC = nil;
    
    // so clients can prepae to refresh themselves
    [self postNote:PersistentProfileWillResetNotification];
    
    @try {
    [moc reset];
    } @catch (id e) {
        ScrobLog(SCROB_LOG_TRACE, @"resetMain: reset generated an exception: %@", e);
    }
    mainMOC = moc;
    
    // so clients can refresh themselves
    [self postNote:PersistentProfileDidResetNotification];
}

- (NSManagedObjectContext*)mainMOC
{
    return (mainMOC);
}

- (id)storeMetadataForKey:(NSString*)key moc:(NSManagedObjectContext*)moc
{
    id store = [[[moc persistentStoreCoordinator] persistentStores] objectAtIndex:0];
    return ([[[moc persistentStoreCoordinator] metadataForPersistentStore:store] objectForKey:key]);
}

- (void)setStoreMetadata:(id)object forKey:(NSString*)key moc:(NSManagedObjectContext*)moc
{
    id store = [[[moc persistentStoreCoordinator] persistentStores] objectAtIndex:0];
    NSMutableDictionary *d = [[[[moc persistentStoreCoordinator] metadataForPersistentStore:store] mutableCopy] autorelease];
    if (object)
        [d setObject:object forKey:key];
    else
        [d removeObjectForKey:key];
    [[moc persistentStoreCoordinator] setMetadata:d forPersistentStore:store];
    (void)[self save:moc withNotification:NO];
}

//******* public API ********//

- (PersistentSessionManager*)sessionManager
{
    return (sessionMgr);
}

- (BOOL)importInProgress
{
     OSMemoryBarrier();
     return (importing > 0);
}

- (void)setImportInProgress:(BOOL)import
{
    if (import) {
        OSMemoryBarrier();
        ++importing;
    } else {
        OSMemoryBarrier();
        --importing;
    }
    ISASSERT(importing >= 0, "importing went south!");
}

- (void)addSongPlay:(SongData*)song
{
    static NSMutableArray *queue = nil;
    if (!queue)
        queue = [[NSMutableArray alloc] init];
    
    if (song)
        [queue addObject:song];
    
    // the importer makes the assumption that no one else will modify the DB (so it doesn't have to search as much)
    if (![self importInProgress] && [queue count] > 0) {
        if ([self addSongPlaysToAllSessions:queue])
            [queue removeAllObjects];
    }
}

- (void)rename:(NSManagedObjectID*)moid to:(NSString*)newTitle
{
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
        moid, @"oid",
        NSStringFromSelector(@selector(rename:to:)), @"method",
        [NSArray arrayWithObjects:moid, newTitle, nil], @"args",
        @"rename", @"what",
        nil];

    [self performSelectorOnSessionMgrThread:@selector(editObject:) withObject:args];
}

- (void)removeObject:(NSManagedObjectID*)moid
{
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
        moid, @"oid",
        NSStringFromSelector(@selector(removeObject:)), @"method",
        [NSArray arrayWithObjects:moid, nil], @"args",
        @"remove", @"what",
        nil];

    [self performSelectorOnSessionMgrThread:@selector(editObject:) withObject:args];
}

- (void)addHistoryEvents:(NSArray*)playDates forObject:(NSManagedObjectID*)moid
{
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
        moid, @"oid",
        NSStringFromSelector(@selector(addHistoryEvents:forObject:)), @"method",
        [NSArray arrayWithObjects:playDates, moid, nil], @"args",
        @"addhist", @"what",
        nil];

    [self performSelectorOnSessionMgrThread:@selector(editObject:) withObject:args];
}

- (void)removeHistoryEvent:(NSManagedObjectID*)eventID forObject:(NSManagedObjectID*)moid
{
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
        moid, @"oid",
        NSStringFromSelector(@selector(removeHistoryEvent:forObject:)), @"method",
        [NSArray arrayWithObjects:eventID, moid, nil], @"args",
        @"remhist", @"what",
        nil];

    [self performSelectorOnSessionMgrThread:@selector(editObject:) withObject:args];
}

- (NSArray*)allSessions
{
    return ([[sessionMgr activeSessionsWithMOC:mainMOC] arrayByAddingObjectsFromArray:
        [sessionMgr archivedSessionsWithMOC:mainMOC weekLimit:10]]);
}

- (NSArray*)songsForSession:(id)session
{
    NSError *error;
    NSManagedObjectContext *moc = [session managedObjectContext];
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PSessionSong" inManagedObjectContext:moc];
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:entity];
    [request setPredicate:[NSPredicate predicateWithFormat:@"(itemType == %@) AND (session == %@)",
            ITEM_SONG, session]];
    [request setReturnsObjectsAsFaults:NO];
    return ([moc executeFetchRequest:request error:&error]);
}

- (NSArray*)ratingsForSession:(id)session
{
    NSError *error;
    NSManagedObjectContext *moc = [session managedObjectContext];
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PRatingCache" inManagedObjectContext:moc];
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:entity];
    [request setPredicate:[NSPredicate predicateWithFormat:@"(itemType == %@) AND (session == %@)",
            ITEM_RATING_CCH, session]];
    [request setReturnsObjectsAsFaults:NO];
    return ([moc executeFetchRequest:request error:&error]);
}

- (NSArray*)hoursForSession:(id)session
{
    NSError *error;
    NSManagedObjectContext *moc = [session managedObjectContext];
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PHourCache" inManagedObjectContext:moc];
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:entity];
    [request setPredicate:[NSPredicate predicateWithFormat:@"(itemType == %@) AND (session == %@)",
            ITEM_HOUR_CCH, session]];
    [request setReturnsObjectsAsFaults:NO];
    return ([moc executeFetchRequest:request error:&error]);
}

#if 0
- (NSArray*)playHistoryForSong:(SongData*)song ignoreAlbum:(BOOL)ignoreAlbum
{
    NSError *error;
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PSongLastPlayed" inManagedObjectContext:mainMOC];
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:entity];
    
    [request setSortDescriptors:[NSArray arrayWithObject:
        [[[NSSortDescriptor alloc] initWithKey:@"lastPlayed" ascending:NO] autorelease]]];
    
    NSString *format = @"(itemType == %@) AND (song.name LIKE[cd] %@) AND (song.artist.name LIKE[cd] %@)";
    NSString *album = [song album];
    if (!ignoreAlbum && album && [album length] > 0)
        format = [format stringByAppendingString:@" AND (song.album.name LIKE[cd] %@)"];
    else
        album = nil;
    [request setPredicate:[NSPredicate predicateWithFormat:format, ITEM_SONG,
        [[song title] stringByEscapingNSPredicateReserves], [[song artist] stringByEscapingNSPredicateReserves],
        [album stringByEscapingNSPredicateReserves]]];
    
    return ([mainMOC executeFetchRequest:request error:&error]);
}

- (NSNumber*)playCountForSong:(SongData*)song
{
    NSError *error;
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PSong" inManagedObjectContext:mainMOC];
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:entity];
    
    NSString *format = @"(itemType == %@) AND (name LIKE[cd] %@) AND (artist.name LIKE[cd] %@)";
    NSString *album = [song album];
    if (album && [album length] > 0)
        format = [format stringByAppendingString:@" AND (album.name LIKE[cd] %@)"];
    else
        album = nil;
    [request setPredicate:[NSPredicate predicateWithFormat:format, ITEM_SONG,
        [[song title] stringByEscapingNSPredicateReserves], [[song artist] stringByEscapingNSPredicateReserves],
        [album stringByEscapingNSPredicateReserves]]];
    
    NSArray *result = [mainMOC executeFetchRequest:request error:&error];
    if (1 == [result count]) {
        return ([[result objectAtIndex:0] valueForKey:@"playCount"]);
    } else if ([result count] > 0) {
        if (!album) {
            ScrobLog(SCROB_LOG_WARN, @"playCountForSong: multiple songs for '%@' found in chart database", [song brief]);
            return ([[result objectAtIndex:0] valueForKey:@"playCount"]);
        } else
            ISASSERT(0, "multiple songs found!");
    }
    return (nil);
}
#endif

//******* end public API ********//

- (NSManagedObject*)playerWithName:(NSString*)name moc:(NSManagedObjectContext*)moc
{
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:[NSEntityDescription entityForName:@"PPlayer" inManagedObjectContext:moc]];
    [request setPredicate:[NSPredicate predicateWithFormat:@"name LIKE[cd] %@", [name stringByEscapingNSPredicateReserves]]];
    
    NSArray *result = [moc executeFetchRequest:request error:nil];
    if (1 == [result count])
        return ([result objectAtIndex:0]);
    
    return (nil);
}

- (void)didWake:(NSNotification*)note
{
    [self pingSessionManager];
}

- (void)importDidFinish:(id)obj
{
    if (nil == [self storeMetadataForKey:@"ISWillImportiTunesLibrary" moc:mainMOC]) {
        // kill our XML dump
        [[NSFileManager defaultManager] removeItemAtPath:PERSISTENT_STORE_XML error:nil];
    }

    [self setImportInProgress:NO];
    //[self setValue:[NSNumber numberWithBool:NO] forKey:@"importInProgress"];
    
    // Reset so any cached objects are forced to refault
    ISASSERT(NO == [mainMOC hasChanges], "somebody modifed the DB during an import");
    [self resetMain];
    
    [self pingSessionManager]; // this makes sure the sessions are properly setup before adding any songs
    [self performSelector:@selector(addSongPlay:) withObject:nil afterDelay:0.10]; // process any queued songs
}

- (void)persistentProfileDidEditObject:(NSNotification*)note
{
    ISASSERT(mainMOC != nil, "missing thread moc!");
    ISASSERT([NSThread isMainThread], "!mainThread!");
    
    NSManagedObjectID *oid = [[note userInfo] objectForKey:@"oid"];
    NSManagedObject *obj = [mainMOC objectRegisteredForID:oid];
    if (obj) {
        [obj refreshSelf];
    }
}

- (void)addSongPlaysDidFinish:(id)obj
{
    [self addSongPlay:nil]; // process any queued songs
}

- (NSArray*)dataModelBundles
{
    return ([NSArray arrayWithObjects:[NSBundle bundleForClass:[self class]], nil]);
}

- (void)backupDatabase
{
    NSString *backup = [PERSISTENT_STORE_DB stringByAppendingString:@"-backup"];
    (void)[[NSFileManager defaultManager] removeItemAtPath:[backup stringByAppendingString:@"-1"] error:nil];
    (void)[[NSFileManager defaultManager] moveItemAtPath:backup toPath:[backup stringByAppendingString:@"-1"] error:nil];
    (void)[[NSFileManager defaultManager] copyItemAtPath:PERSISTENT_STORE_DB toPath:backup error:nil];
}

- (void)createDatabase
{
    NSDate *dbEpoch = [self storeMetadataForKey:(NSString*)kMDItemContentCreationDate moc:mainMOC];
    
    // Create sessions
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PSession" inManagedObjectContext:mainMOC];
    NSEnumerator *en = [[NSArray arrayWithObjects:
        @"all", @"lastfm", @"pastday", @"pastweek", @"pastmonth", @"past3months", @"pastsixmonths", @"pastyear", @"temp", nil] objectEnumerator];
    NSArray *displayNames = [NSArray arrayWithObjects:
        NSLocalizedString(@"Overall", ""), NSLocalizedString(@"Last.fm Weekly", ""),
        NSLocalizedString(@"Today", ""), NSLocalizedString(@"Past Week", ""),
        NSLocalizedString(@"Past Month", ""), NSLocalizedString(@"Past Three Months", ""),
        NSLocalizedString(@"Past Six Months", ""),
        NSLocalizedString(@"Past Year", ""), NSLocalizedString(@"Internal", ""),
        nil];
    NSString *name;
    NSManagedObject *obj;
    NSUInteger i = 0;
    NSNumber *one = [NSNumber numberWithUnsignedInt:1];
    while ((name = [en nextObject])) {
        obj = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:mainMOC];
        [obj setValue:ITEM_SESSION forKey:@"itemType"];
        [obj setValue:name forKey:@"name"];
        [obj setValue:dbEpoch forKey:@"epoch"];
        [obj setValue:[displayNames objectAtIndex:i] forKey:@"localizedName"];
        if (version3)
            [obj setValue:one forKey:@"generation"];
        ++i;
        [obj release];
    }
    
    // Create player entries
    entity = [NSEntityDescription entityForName:@"PPlayer" inManagedObjectContext:mainMOC];
    obj = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:mainMOC];
    [obj setValue:@"iTunes" forKey:@"name"];
    [obj release];
    
    obj = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:mainMOC];
    [obj setValue:@"iTunes Shared Library" forKey:@"name"];
    [obj release];
    
    obj = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:mainMOC];
    [obj setValue:@"Last.fm Radio" forKey:@"name"];
    [obj release];
    
    // This is used for PSessionItem.item when the item has no other relationship (currently the caches)
    entity = [NSEntityDescription entityForName:@"PItem" inManagedObjectContext:mainMOC];
    obj = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:mainMOC];
    [obj setValue:@"-DB-Orphans-" forKey:@"name"];
    // type is left at unknown
    [obj release];
}

- (void)databaseDidInitialize:(NSDictionary*)metadata
{
    ISASSERT([NSThread isMainThread], "!mainThread!");
    
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(persistentProfileDidEditObject:)
        name:PersistentProfileDidEditObject
        object:nil];
    
    ScrobLog(SCROB_LOG_TRACE, @"Opened Local Charts database version %@. Internal version is %@.",
            [metadata objectForKey:(NSString*)kMDItemVersion], [self currentStoreVersion]);
    ScrobLog(SCROB_LOG_TRACE, @"Local Charts epoch is '%@'", [metadata objectForKey:(NSString*)kMDItemContentCreationDate]);
    
    id ver = [metadata objectForKey:(NSString*)kMDItemCreator];
    ScrobLog(SCROB_LOG_TRACE, @"Local Charts creator is '%@'", ver ? ver : @"pre-2.1.1");
    
    ver = [metadata objectForKey:(NSString*)kMDItemEditors];
    ScrobLog(SCROB_LOG_TRACE, @"Local Charts were last opened by '%@'", ver ? ver : @"pre-2.1.1");
    [self setStoreMetadata:[NSArray arrayWithObject:[mProxy applicationVersion]] forKey:(NSString*)kMDItemEditors moc:mainMOC];
    
    if (NO == [[metadata objectForKey:@"ISDidImportiTunesLibrary"] boolValue]) {
        // Import from our XML dump (from a failed migration)?
        NSDictionary *importArgs = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:PERSISTENT_STORE_XML]) {
            importArgs = [NSDictionary dictionaryWithObjectsAndKeys:
                PERSISTENT_STORE_XML, @"xmlFile",
                nil];
        }
        
        PersistentProfileImport *import = [[PersistentProfileImport alloc] init];
        [NSThread detachNewThreadSelector:@selector(importiTunesDB:) toTarget:import withObject:importArgs];
        [import release];
    } else {
        [self performSelector:@selector(pingSessionManager) withObject:nil afterDelay:0.0];
    }
    
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
        selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    
    CFURLRef url = (CFURLRef)[NSURL fileURLWithPath:[PERSISTENT_STORE_DB stringByAppendingString:@"-backup-1"]];
    if (NO == CSBackupIsItemExcluded(url, NULL))
        (void)CSBackupSetItemExcluded(url, YES, YES);
    
    [self postNote:PersistentProfileDidFinishInitialization];
}

- (void)databaseDidFailInitialize:(id)arg
{
    ISASSERT([NSThread isMainThread], "!mainThread!");
    
    [mainMOC release];
    mainMOC = nil;
    sessionMgr = nil;
}

#if IS_STORE_V2

- (BOOL)exportDatabaseAsXMLWithModel:(NSManagedObjectModel*)model from:(NSURL*)from to:(NSURL*)to
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    BOOL exported = NO;
    
    if (!to)
        to = [NSURL fileURLWithPath:PERSISTENT_STORE_XML];
    
    NSString *errMsg;
    NSManagedObjectContext *moc = nil;
    NSError *error;
    
    @try {
    
    moc = [[NSManagedObjectContext alloc] init];
    [moc setUndoManager:nil];
    
    NSPersistentStoreCoordinator *psc;
    psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    [moc setPersistentStoreCoordinator:psc];
    [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:from options:nil error:&error];
    [psc release];
    
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"PSong" inManagedObjectContext:moc];
    NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
    [request setEntity:entity];
    [request setReturnsObjectsAsFaults:NO];
    [request setRelationshipKeyPathsForPrefetching:[NSArray arrayWithObjects:@"artist", @"album", nil]];
    
    NSArray *results = [moc executeFetchRequest:request error:nil];
    NSManagedObject *song;
    unsigned trackID = 0;
    NSMutableDictionary *trackEntries = [NSMutableDictionary dictionaryWithCapacity:[results count]];
    NSMutableDictionary *library = [NSMutableDictionary dictionaryWithObject:trackEntries forKey:@"Tracks"];
    for (song in results) {
        NSAutoreleasePool *trackPool = [[NSAutoreleasePool alloc] init];
        
        NSNumber *entryID = [NSNumber numberWithUnsignedInt:trackID];
        NSMutableDictionary *trackEntry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            entryID, @"Track ID",
            [song valueForKey:@"name"], @"Name",
            [song valueForKeyPath:@"artist.name"], @"Artist",
            nil];
        
        id value = [song valueForKeyPath:@"album.name"];
        if (value)
            [trackEntry setObject:value forKey:@"Album"];
        value = [song valueForKey:@"duration"];
        if (value) {
            value = [NSNumber numberWithUnsignedLongLong:[value unsignedLongLongValue]*1000ULL];
            [trackEntry setObject:value forKey:@"Total Time"];
        }
        value = [song valueForKey:@"playCount"];
        if (value)
            [trackEntry setObject:value forKey:@"Play Count"];
        value = [song valueForKey:@"lastPlayed"];
        if (value)
            [trackEntry setObject:[value GMTDate] forKey:@"Play Date UTC"];
        value = [song valueForKey:@"rating"];
        if (value)
            [trackEntry setObject:value forKey:@"Rating"];
        value = [song valueForKey:@"trackNumber"];
        if (value)
            [trackEntry setObject:value forKey:@"Track Number"];
        value = [song valueForKey:@"playHistory"];
        if (value) {
            value = [[value valueForKey:@"lastPlayed"] valueForKey:@"GMTDate"];
            [trackEntry setObject:[value allObjects] forKey:@"org.iScrobbler.PlayHistory"];
        }
        
        if (version3) {
            if ((value = [song valueForKey:@"lastPlayedTZO"]))
                [trackEntry setObject:value forKey:@"org.iScrobbler.lastPlayedTZO"];
            // best way to store lastPlayedTZO for playHistory?
            
            if ((value = [song valueForKey:@"year"]))
                [trackEntry setObject:value forKey:@"Year"];
        }
        
        [trackEntries setObject:trackEntry forKey:[entryID stringValue]];
        
        [trackPool release];
        ++trackID;
    }
    
    NSArray *archives = [sessionMgr archivedSessionsWithMOC:moc weekLimit:0];
    NSMutableArray *archiveEntries = [NSMutableArray arrayWithCapacity:[archives count]];
    for (NSManagedObject *archive in archives) {
        NSMutableDictionary *archiveEntry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            [archive valueForKey:@"name"], @"name",
            [archive valueForKey:@"epoch"], @"epoch",
            [archive valueForKey:@"localizedName"], @"localizedName",
            [archive valueForKey:@"term"], @"term",
            [archive valueForKeyPath:@"archive.created"], @"created",
            nil];
        
        [archiveEntries addObject:archiveEntry];
    }
    if ([archiveEntries count] > 0) {
        [library setObject:archiveEntries forKey:@"org.iScrobbler.Archives"];
    }
    
    // iTunes uses "Library Persistent ID"
    NSDate *epoch = [[[[self sessionManager] sessionWithName:@"all" moc:moc] valueForKey:@"epoch"] GMTDate];
    [library setObject:epoch forKey:@"org.iScrobbler.PlayEpoch"];
    [library setObject:[self storeMetadataForKey:NSStoreUUIDKey moc:moc] forKey:NSStoreUUIDKey];
    [library setObject:[self storeMetadataForKey:(NSString*)kMDItemContentCreationDate moc:moc] forKey:(NSString*)kMDItemContentCreationDate];
    exported = [library writeToURL:to atomically:NO];
    
    } @catch (NSException *e) {
        ScrobLog(SCROB_LOG_ERR, @"excpetion exporting database: %@", e);
    }
    
    [moc release];
    [pool release];
    return (exported);
}

- (void)migrationDidComplete:(NSDictionary*)metadata
{   
    ISASSERT([NSThread isMainThread], "!mainThread!");
    
    [self databaseDidInitialize:metadata];
    [self postNote:PersistentProfileDidMigrateNotification];
    [self profileDidChangeWithUpdatedObjects:nil];
    [self performSelector:@selector(addSongPlay:) withObject:nil afterDelay:0.10]; // process any queued songs
}

- (void)migrateDatabase:(id)arg
{
    ISElapsedTimeInit();
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSManagedObjectContext *moc = nil;
    NSError *error = nil;
    BOOL migrated = NO, reimport = NO;
    
    [self performSelectorOnMainThread:@selector(postNote:) withObject:PersistentProfileWillMigrateNotification waitUntilDone:NO];
    
    [self setImportInProgress:YES];
    
    NSURL *dburl = [NSURL fileURLWithPath:PERSISTENT_STORE_DB];
    NSDictionary *metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
        URL:dburl error:nil];
    NSDate *createDate = [metadata objectForKey:(NSString*)kMDItemContentCreationDate];
    if (!createDate) {
        ISASSERT(0, "missing creation date!");
        createDate = [NSDate date];
    }
    ISASSERT(nil != [metadata objectForKey:@"ISDidImportiTunesLibrary"], "missing import state!");
    
    NSString *curVer = [metadata objectForKey:(NSString*)kMDItemVersion];
    ScrobLog(SCROB_LOG_TRACE, @"Migrating Local Charts database version %@ to version %@.",
            curVer, [self currentStoreVersion]);
    
    BOOL v2tov3 = [@"2" isEqualToString:curVer];
    NSAutoreleasePool *tempPool = [[NSAutoreleasePool alloc] init];
    @try {
    
    NSArray *searchBundles = [self dataModelBundles];
    NSURL *tmpURL;
    tmpURL = [NSURL fileURLWithPath:[[searchBundles objectAtIndex:0]
        pathForResource:(v2tov3 ? @"iScrobblerV2" : @"iScrobbler")
        ofType:@"mom" inDirectory:@"iScrobbler.momd"]];
    NSManagedObjectModel *source = [[[NSManagedObjectModel alloc] initWithContentsOfURL:tmpURL] autorelease];
    if (!source)
        ScrobLog(SCROB_LOG_ERR, @"Migration: Failed to load v1 mom from: %@", [tmpURL path]);
    
    tmpURL = [NSURL fileURLWithPath:[[searchBundles objectAtIndex:0]
        pathForResource:(v2tov3 ? @"iScrobblerV3" : @"iScrobblerV2")
        ofType:@"mom" inDirectory:@"iScrobbler.momd"]];
    NSManagedObjectModel *dest = [[[NSManagedObjectModel alloc] initWithContentsOfURL:tmpURL] autorelease];
    if (!dest)
        ScrobLog(SCROB_LOG_ERR, @"Migration: Failed to load v2 mom from: %@", [tmpURL path]);
    
    NSMappingModel *map = [NSMappingModel mappingModelFromBundles:searchBundles forSourceModel:source destinationModel:dest];
    if (!map)
        ScrobLog(SCROB_LOG_ERR, @"Migration: Failed to create mapping model");
    
    NSMigrationManager *migm = [[[NSMigrationManager alloc] initWithSourceModel:source destinationModel:dest] autorelease];
    if (migm) {
        tmpURL = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ISMIG_%d", random()]]];
        ISStartTime();
        migrated = [migm migrateStoreFromURL:dburl
            type:NSSQLiteStoreType
            options:nil
            withMappingModel:map
            toDestinationURL:tmpURL
            destinationType:NSSQLiteStoreType
            destinationOptions:nil
            error:&error];
        ISEndTime();
        ScrobDebug(@"Migration finished in %.4lf seconds", (abs2clockns / 1000000000.0));
        NSString *dbpath = [dburl path];
        if (migrated) {
            // swap the files as [addPersistentStoreWithType:] would
            migrated = NO;
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *tmppath = [tmpURL path];
            NSString *backup = [[[dbpath stringByDeletingPathExtension] stringByAppendingString:@"~"]
                stringByAppendingPathExtension:[dbpath pathExtension]];
            (void)[fm removeItemAtPath:backup error:nil];
            if ([fm linkItemAtPath:dbpath toPath:backup error:&error]) {
                if ([fm removeItemAtPath:dbpath error:&error]) {
                    if ([fm copyItemAtPath:tmppath toPath:dbpath error:&error]) {
                        migrated = YES;
                    }
                }
            }
            (void)[fm removeItemAtPath:tmppath error:nil];
        } else if ([self exportDatabaseAsXMLWithModel:source from:dburl to:nil]) {
            NSString *backup = [[[dbpath stringByDeletingPathExtension] stringByAppendingString:@"~v1"]
                stringByAppendingPathExtension:[dbpath pathExtension]];
            if ([[NSFileManager defaultManager] linkItemAtPath:dbpath toPath:backup error:nil]) {
                if ([[NSFileManager defaultManager] removeItemAtPath:dbpath error:nil]) {
                    reimport = YES;
                }
            }
        }
    } else
        ScrobLog(SCROB_LOG_ERR, @"Migration: Failed to create migration manager");
    
    } @catch (NSException *e) {
        migrated = NO;
        error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
            NSLocalizedString(@"An exception occurred during database migration.", ""),
            NSLocalizedDescriptionKey,
            nil]];
        ScrobLog(SCROB_LOG_ERR, @"Migration: an exception occurred during database migration. (%@)", e);
    }
    (void)[error retain];
    [tempPool release];
    tempPool = nil;
    (void)[error autorelease];
    
    NSPersistentStore *store;
    NSPersistentStoreCoordinator *psc = nil;
    if (migrated) {
        psc = [mainMOC persistentStoreCoordinator];
        store = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:dburl options:nil error:&error];
        moc = [[[NSManagedObjectContext alloc] init] autorelease];
        [moc setPersistentStoreCoordinator:psc];
        [moc setUndoManager:nil];
        
        if (![NSThread isMainThread])
            [[[NSThread currentThread] threadDictionary] setObject:moc forKey:@"moc"];
    } else {
        store = nil;
        migrated = NO;
    }
    
    if (store) {
        metadata = [NSDictionary dictionaryWithObjectsAndKeys:
            [self currentStoreVersion], (NSString*)kMDItemVersion,
            createDate, (NSString*)kMDItemContentCreationDate, // epoch
            [metadata objectForKey:@"ISDidImportiTunesLibrary"], @"ISDidImportiTunesLibrary",
            [mProxy applicationVersion], (NSString*)kMDItemCreator,
            // NSStoreTypeKey and NSStoreUUIDKey are always added
            nil];
        [psc setMetadata:metadata forPersistentStore:store];
        
        tempPool = [[NSAutoreleasePool alloc] init];
        // force scrub the db -- this reduces the size of the dub
        // it also fixes a cache bug in the 'all' session caused during a 2.0 import
        ISStartTime();
        [sessionMgr performSelector:@selector(performScrub:) withObject:nil];
        ISEndTime();
        ScrobDebug(@"Migration: scrubbed db in in %.4lf seconds", (abs2clockns / 1000000000.0));
        [tempPool release];
        
        // update session ratings
        if (!v2tov3) {
            tempPool = [[NSAutoreleasePool alloc] init];
            ISStartTime();
            NSEnumerator *en = [[[sessionMgr activeSessionsWithMOC:moc] arrayByAddingObjectsFromArray:
                [sessionMgr archivedSessionsWithMOC:moc weekLimit:0]] objectEnumerator];
            NSManagedObject *mobj;
            while ((mobj = [en nextObject])) {
                #ifndef ISDEBUG
                if ([@"all" isEqualToString:[mobj valueForKey:@"name"]])
                    continue; // this was performed in the db scrub
                #endif
                @try {
                [sessionMgr recreateRatingsCacheForSession:mobj songs:[self songsForSession:mobj] moc:moc];
                [self save:moc withNotification:NO];
                } @catch (NSException *e) {
                    ScrobLog(SCROB_LOG_ERR, @"Migration: exception updating ratings for %@. (%@)",
                        [mobj valueForKey:@"name"], e);
                }
            }
            ISEndTime();
            ScrobDebug(@"Migration: ratings update in in %.4lf seconds", (abs2clockns / 1000000000.0));
            
            [tempPool release];
            tempPool = nil;
        
            NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
            NSEntityDescription *entity;
            // set Artist firstPlayed times (non-import only)
            @try {
                ISStartTime();
                entity = [NSEntityDescription entityForName:@"PArtist" inManagedObjectContext:moc];
                [request setEntity:entity];
                [request setPredicate:[NSPredicate predicateWithFormat:@"(itemType == %@)", ITEM_ARTIST]];
                [request setReturnsObjectsAsFaults:NO];
                [request setRelationshipKeyPathsForPrefetching:[NSArray arrayWithObjects:@"songs", nil]];
                en = [[moc executeFetchRequest:request error:&error] objectEnumerator];
                
                tempPool = [[NSAutoreleasePool alloc] init];
                while ((mobj = [en nextObject])) {
                    if ([[mobj valueForKeyPath:@"songs.importedPlayCount.@sum.unsignedIntValue"] unsignedIntValue] > 0)
                        continue;
                    entity = [NSEntityDescription entityForName:@"PSong" inManagedObjectContext:moc];
                    [request setEntity:entity];
                    [request setPredicate:[NSPredicate predicateWithFormat:
                        @"(itemType == %@) && (firstPlayed != nil) && (artist == %@)", ITEM_SONG, mobj]];
                    NSArray *songs = [moc executeFetchRequest:request error:&error];
                    if ([songs count] > 0) {
                        NSNumber *firstPlayed = [songs valueForKeyPath:@"firstPlayed.@min.timeIntervalSince1970"];
                        if (firstPlayed) {
                            [mobj setValue:[NSDate dateWithTimeIntervalSince1970:[firstPlayed doubleValue]]
                                forKey:@"firstPlayed"];
                        }
                        error = nil;
                        [tempPool release];
                        tempPool = [[NSAutoreleasePool alloc] init];
                    }
                }
                ISEndTime();
                ScrobDebug(@"Migration: artist update in in %.4lf seconds", (abs2clockns / 1000000000.0));
            } @catch (NSException *e) {
                ScrobLog(SCROB_LOG_ERR, @"Migration: exception updating artists. (%@)", e);
            }
            
            error = nil;
            [tempPool release];
            tempPool = nil;
        } // (!v2tov3)
        [self save:moc withNotification:NO];
    } else
        migrated = NO;
    [self setImportInProgress:NO];
    
    [moc reset];
    
    if (migrated) {
        [self performSelectorOnMainThread:@selector(migrationDidComplete:) withObject:metadata waitUntilDone:NO];
    } else {
        ScrobLog(SCROB_LOG_ERR, @"Migration failed with: %@", (id)error ? (id)error : (id)@"unknown");
        [self performSelectorOnMainThread:@selector(databaseDidFailInitialize:) withObject:nil waitUntilDone:YES];
        if (reimport)
            [self performSelectorOnMainThread:@selector(initDatabase:) withObject:nil waitUntilDone:NO];
        else
            [self performSelectorOnMainThread:@selector(postNote:) withObject:PersistentProfileMigrateFailedNotification waitUntilDone:NO];
            
        
    }
    
    [pool release];
    if (![NSThread isMainThread])
        [NSThread exit];
}
#endif // IS_STORE_V2

- (BOOL)moveDatabaseToNewSupportFolder
{
    NSString *oldPath = PERSISTENT_STORE_DB_21X;
    
    NSURL *url = [NSURL fileURLWithPath:oldPath];
    NSDictionary *metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:nil URL:url error:nil];
    if (metadata && nil == [metadata objectForKey:@"ISStoreLocationVersion"]) {
        NSString *newPath = PERSISTENT_STORE_DB;
        BOOL good = [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:nil];
        if (good) {
            // move the most recent backup and create a symlink for the old file
            NSString *backup = [oldPath stringByAppendingString:@"-backup"];
            NSString *newBackup = [newPath stringByAppendingString:@"-backup"];
            NSString *symlinkDest = [NSString stringWithFormat:@"./%@/%@",
                [[newPath stringByDeletingLastPathComponent] lastPathComponent],
                [newPath lastPathComponent]];
            
            (void)[[NSFileManager defaultManager] moveItemAtPath:backup toPath:newBackup error:nil];
            (void)[[NSFileManager defaultManager] removeItemAtPath:[backup stringByAppendingString:@"-1"] error:nil];
            (void)[[NSFileManager defaultManager] createSymbolicLinkAtPath:oldPath withDestinationPath:symlinkDest error:nil];
            
            return (YES);
        }
    } else if (metadata) {
        // remove stale backups
        NSString *backup = [oldPath stringByAppendingString:@"-backup"];
        (void)[[NSFileManager defaultManager] removeItemAtPath:backup error:nil];
        (void)[[NSFileManager defaultManager] removeItemAtPath:[backup stringByAppendingString:@"-1"] error:nil];
    }
    
    return (NO);
}

- (void)switchToV3
{
    #if defined(IS_STORE_V2) && defined(ISDEBUG)
    NSURL *momURL = [NSURL fileURLWithPath:[[[self dataModelBundles] objectAtIndex:0]
        pathForResource:@"iScrobblerV3" ofType:@"mom" inDirectory:@"iScrobbler.momd"]];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:
        [[[NSManagedObjectModel alloc] initWithContentsOfURL:momURL] autorelease]];
    [mainMOC setPersistentStoreCoordinator:psc];
    [psc release];
    version3 = YES;
    #endif
}

- (BOOL)initDatabase:(NSError**)failureReason
{
    NSError *error = nil;
    NSPersistentStore *mainStore;
    mainMOC = [[NSManagedObjectContext alloc] init];
    [mainMOC setUndoManager:nil];
    
    if (!failureReason)
        failureReason = &error;
    
    *failureReason = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
        userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
            NSLocalizedString(@"The database could not be opened. An unknown error occurred.", ""),
            NSLocalizedDescriptionKey,
            nil]];
    
    NSPersistentStoreCoordinator *psc;
    psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:
        [NSManagedObjectModel mergedModelFromBundles:[self dataModelBundles]]];
    [mainMOC setPersistentStoreCoordinator:psc];
    [psc release];
    psc = nil;
    // we don't allow the user to make changes and the session mgr background thread handles all internal changes
    [mainMOC setMergePolicy:NSRollbackMergePolicy];
    
    sessionMgr = [PersistentSessionManager sharedInstance];
    
    BOOL didLocationMove = [self moveDatabaseToNewSupportFolder];
    
    NSURL *url = [NSURL fileURLWithPath:PERSISTENT_STORE_DB];
    // NSXMLStoreType is slow and keeps the whole object graph in mem, but great for looking at the DB internals (debugging)
    NSDictionary *metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType URL:url error:nil];
    if (metadata && nil != [metadata objectForKey:@"ISWillImportiTunesLibrary"]) {
        // import was interrupted, reset everything
        ScrobLog(SCROB_LOG_ERR, @"The iTunes import failed, removing corrupt database.");
        (void)[[NSFileManager defaultManager] removeItemAtPath:PERSISTENT_STORE_DB error:nil];
        // try and remove any SQLite journal as well
        (void)[[NSFileManager defaultManager] removeItemAtPath:
            [PERSISTENT_STORE_DB stringByAppendingString:@"-journal"] error:nil];
        metadata = nil;
    }
    if (!metadata) {
        [self switchToV3];
        
        NSCalendarDate *now = [NSCalendarDate date];
        psc = [mainMOC persistentStoreCoordinator];
        mainStore = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:nil error:&error];
        [psc setMetadata:
            [NSDictionary dictionaryWithObjectsAndKeys:
                [self currentStoreVersion], (NSString*)kMDItemVersion,
                now, (NSString*)kMDItemContentCreationDate, // epoch
                [NSNumber numberWithBool:NO], @"ISDidImportiTunesLibrary",
                [NSNumber numberWithLongLong:[[NSTimeZone defaultTimeZone] secondsFromGMT]], @"ISTZOffset",
                [mProxy applicationVersion], (NSString*)kMDItemCreator,
                PERSISTENT_STORE_DB_LOCATION_VERSION, @"ISStoreLocationVersion",
                // NSStoreTypeKey and NSStoreUUIDKey are always added
                nil]
            forPersistentStore:mainStore];
        
        [self createDatabase];
        
        NSManagedObject *allSession = [sessionMgr sessionWithName:@"all" moc:mainMOC];
        ISASSERT(allSession != nil, "missing all session!");
        [allSession setValue:now forKey:@"epoch"];
        
        [mainMOC save:nil];
    } else {
        psc = [mainMOC persistentStoreCoordinator];
        #if IS_STORE_V2
        if ([@"3" isEqualToString:[metadata objectForKey:(NSString*)kMDItemVersion]]
            || [[NSUserDefaults standardUserDefaults] boolForKey:@"WantsV3Charts"])
            [self switchToV3];
        if (![[psc managedObjectModel] isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
        #else
        if (![[metadata objectForKey:(NSString*)kMDItemVersion] isEqualTo:[self currentStoreVersion]]) {
        #endif
            #if IS_STORE_V2
            [NSThread detachNewThreadSelector:@selector(migrateDatabase:) toTarget:self withObject:nil];
            return (YES);
            #else
            [self databaseDidFailInitialize:nil];
            *failureReason = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
                userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                    NSLocalizedString(@"The database could not be opened because it was created with a different design model. You need to upgrade iScrobbler or Mac OS X.", ""),
                    NSLocalizedDescriptionKey,
                    nil]];
            return (NO);
            #endif
        }
        
        NSDictionary *storeOptions;
        #if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DBOptimize"]) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"DBOptimize"];
            storeOptions = [NSDictionary dictionaryWithObjectsAndKeys:
                //[NSNumber numberWithBool:YES], NSSQLiteAnalyzeOption,
                [NSNumber numberWithBool:YES], NSSQLiteManualVacuumOption,
                nil];
            ScrobLog(SCROB_LOG_TRACE, @"Database optimization task will run.");
        } else
        #endif
            storeOptions = nil;
        
        mainStore = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:storeOptions error:&error];
        if (!mainStore) {
            [self databaseDidFailInitialize:nil];
            *failureReason = error;
            return (NO);
        }
    }
    
    const char *appSig = [[[mProxy applicationBundle] objectForInfoDictionaryKey:@"CFBundleSignature"]
        cStringUsingEncoding:NSASCIIStringEncoding];
    if (appSig && strlen(appSig) >= 4) {
        OSType ccode = appSig[0] << 24 | appSig[1] << 16 | appSig[2] << 8 | appSig[3];
        NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithUnsignedInt:ccode], NSFileHFSCreatorCode,
            nil];
        if (0 == [[[[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:nil] objectForKey:NSFileHFSCreatorCode] intValue]) {
            (void)[[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:[url path] error:nil];
        }
    }
    
    [self databaseDidInitialize:metadata];
    if (didLocationMove) {
        [self setStoreMetadata:PERSISTENT_STORE_DB_LOCATION_VERSION forKey:@"ISStoreLocationVersion" moc:mainMOC];
        [self save:mainMOC withNotification:NO];
    }
    *failureReason = nil;
    return (YES);
}

- (BOOL)isVersion2
{
    return (IS_STORE_V2);
}

- (BOOL)isVersion3
{
    return (version3);
}

#ifdef ISDEBUG
- (void)log:(NSString*)msg
{
    msg = [msg stringByAppendingString:@"\n"];
    [mLog writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
}
#endif

// singleton support
static PersistentProfile *shared = nil;
+ (PersistentProfile*)sharedInstance
{
    return (shared);
}

- (id)copyWithZone:(NSZone *)zone
{
    return (self);
}

- (id)retain
{
    return (self);
}

- (NSUInteger)retainCount
{
    return (NSUIntegerMax);  //denotes an object that cannot be released
}

- (void)release
{
}

- (id)autorelease
{
    return (self);
}

// ISPlugin protocol

- (id)initWithAppProxy:(id<ISPluginProxy>)proxy
{
    self = [super init];
    ISASSERT(shared == nil, "double load!");
    shared = self;
    mProxy = proxy;

#if 0
    __private_extern__ NSFileHandle* ScrobLogCreate_(NSString*, unsigned, unsigned);
    mLog = [ScrobLogCreate_(@"ISPersistence.log", 0, 1) retain];
#endif
    
    return (self);
}

- (NSString*)description
{
    return (NSLocalizedString(@"Persistence Plugin", ""));
}

- (void)applicationWillTerminate
{
#ifdef ISDEBUG
    [mLog closeFile];
    [mLog release];
    mLog = nil;
#endif
}

@end

@implementation PersistentProfile (SessionManagement)

- (BOOL)performSelectorOnSessionMgrThread:(SEL)selector withObject:(id)object
{
    ISASSERT([NSThread mainThread], "wrong thread!");
    
    if (![sessionMgr threadMessenger])
        return (NO);
    
    [ISThreadMessenger makeTarget:[sessionMgr threadMessenger] performSelector:selector withObject:object];
    return (YES);
}

- (void)pingSessionManager
{
    static BOOL init = YES;
    if (init && ![self importInProgress]) {
        init = NO;
        [NSThread detachNewThreadSelector:@selector(sessionManagerThread:) toTarget:sessionMgr withObject:self];
    } else if (![self importInProgress]) {
        (void)[self performSelectorOnSessionMgrThread:@selector(sessionManagerUpdate) withObject:nil];
    }
}

- (BOOL)addSongPlaysToAllSessions:(NSArray*)queue
{
    ISASSERT([sessionMgr threadMessenger] != nil, "nil send port!");
    return ([self performSelectorOnSessionMgrThread:@selector(processSongPlays:) withObject:[[queue copy] autorelease]]);
}

@end

@implementation PersistentProfile (PItemAdditions)

- (BOOL)isSong:(NSManagedObject*)item
{
    return ([ITEM_SONG isEqualTo:[item valueForKey:@"itemType"]]);
}

- (BOOL)isArtist:(NSManagedObject*)item
{
    return ([ITEM_ARTIST isEqualTo:[item valueForKey:@"itemType"]]);
}

- (BOOL)isAlbum:(NSManagedObject*)item
{
    return ([ITEM_ALBUM isEqualTo:[item valueForKey:@"itemType"]]);
}

@end

@implementation PersistentSessionManager (ExportAdditions)

- (void)exportDatabase:(NSString*)path
{
    NSManagedObjectContext *moc = [[[NSThread currentThread] threadDictionary] objectForKey:@"moc"];
    ISASSERT(moc != nil, "missing moc");
    
    PersistentProfile *profile = [PersistentProfile sharedInstance];
    
    [profile setImportInProgress:YES];
    
    BOOL exported;
    @try {
    
    if (!path)
        path = PERSISTENT_STORE_XML;
    
    [profile postNote:PersistentProfileWillExportNotification];
    
    id model = [[moc persistentStoreCoordinator] managedObjectModel];
    exported = [profile exportDatabaseAsXMLWithModel:model
        from:[NSURL fileURLWithPath:PERSISTENT_STORE_DB] to:[NSURL fileURLWithPath:path]];
    
    } @catch (NSException *e) {
        exported = NO;
    }
    
    [profile setImportInProgress:NO];
    
    if (exported)
        [profile postNoteWithArgs:[NSDictionary dictionaryWithObjectsAndKeys:
            PersistentProfileDidExportNotification, @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:path, @"exportPath", nil], @"info",
            nil]];
    else
        [profile postNote:PersistentProfileExportFailedNotification];
}

@end

@implementation NSManagedObject (ISProfileAdditions)

- (void)refreshSelf
{
    @try {
    [[self managedObjectContext] refreshObject:self mergeChanges:NO];
    } @catch (id e) {
        ScrobDebug(@"exception: %@", e);
    }
}

@end

#import "iTunesImport.m"

@implementation NSString (ISNSPredicateEscape)

- (NSString*)stringByEscapingNSPredicateReserves
{
    NSMutableString *s = [self mutableCopy];
    NSRange r;
    r.location = 0;
    r.length = [s length];
    NSUInteger replaced;
    replaced = [s replaceOccurrencesOfString:@"?" withString:@"\\?" options:NSLiteralSearch range:r];
    r.length = [s length];
    replaced += [s replaceOccurrencesOfString:@"*" withString:@"\\*" options:NSLiteralSearch range:r];
    if (replaced > 0) {
        return ([s autorelease]);
    }
    
    [s release];
    return (self);
}

@end
