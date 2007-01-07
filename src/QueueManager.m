//
//  QueueManager.m
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/31/2004.
//  Copyright 2004-2006 Brian Bergstrand.
//
//  Released under the GPL, license details available at
//  http://iscrobbler.sourceforge.net
//

#import "QueueManager.h"
#import "SongData.h"
#import "iScrobblerController.h"
#import "ProtocolManager.h"

static QueueManager *g_QManager = nil;

@implementation QueueManager

+ (QueueManager*)sharedInstance
{
    if (!g_QManager)
        g_QManager = [[QueueManager alloc] init];
    return (g_QManager);
}

+ (id)allocWithZone:(NSZone *)zone
{
    @synchronized(self) {
        if (g_QManager == nil) {
            return ([super allocWithZone:zone]);
        }
    }

    return (g_QManager);
}

- (id)copyWithZone:(NSZone *)zone
{
    return (self);
}

- (id)retain
{
    return (self);
}

- (unsigned)retainCount
{
    return (UINT_MAX);  //denotes an object that cannot be released
}

- (void)release
{
}

- (id)autorelease
{
    return (self);
}

// Queues a song and immediately tries to send it.
- (QueueResult_t)queueSong:(SongData*)song
{
    return ([self queueSong:song submit:YES]);
}

- (QueueResult_t)queueSong:(SongData*)song submit:(BOOL)submit
{
    SongData *found;
    NSEnumerator *en = [songQueue objectEnumerator];
    
    if (![song canSubmit]) {
        ScrobLog(SCROB_LOG_TRACE, @"Track '%@ [%@ of %@]' failed submission rules. Not queuing.\n",
            [song brief], [song position], [song duration]);
        return (kqFailed);
    }
    
    if([song hasQueued]) {
        ScrobLog(SCROB_LOG_TRACE, @"Track '%@' is already queued for submission. Ignoring.\n", song);
        return (kqIsQueued);
    }
    
    while ((found = [en nextObject])) {
        if ([found isEqualToSong:song])
            break;
    }
    
    if (found) {
        // Found in queue
        // Check to see if the song has been played again
        if (![found hasPlayedAgain:song]) {
            ScrobLog(SCROB_LOG_TRACE, @"Track '%@' found in queue as '%@'. Ignoring.\n", song, found);
            return (kqIsQueued);
        }
        // Otherwise, the song will be in the queue twice,
        // on the assumption that it has been played again
    }
    
    ScrobLog(SCROB_LOG_VERBOSE, @"Queuing track '%@' for submission\n", [song brief]);
    
    // Add to top of list
    [song setHasQueued:YES];
    [songQueue addObject:song];
    ++totalSubmissions;
    totalSubmissionSeconds += [[song duration] unsignedIntValue];
    
    [[NSNotificationCenter defaultCenter]
        postNotificationName:QM_NOTIFICATION_SONG_QUEUED
        object:self
        userInfo:[NSDictionary dictionaryWithObject:song forKey:QM_NOTIFICATION_USERINFO_KEY_SONG]]; 
    
    if (submit) {
        [song setPostDate:[song startTime]];
        [self submit];
    }
    
    return (kqSuccess);
}

- (void)submit
{
    // Wake the protocol mgr
    if ([songQueue count]) {
        [self syncQueue:nil];
        [[ProtocolManager sharedInstance] submit:nil];
    }
}

- (BOOL)isSongQueued:(SongData*)song unique:(BOOL)unique
{
    SongData *found;
    NSEnumerator *en = [songQueue objectEnumerator];
    
    while ((found = [en nextObject])) {
        if ([found isEqualToSong:song]) {
            if (unique && ![[found songID] isEqualToNumber:[song songID]])
                continue;
            else
                break;
        }
    }
    
    return ((found ? YES : NO));
}

- (void)removeSong:(SongData*)song
{
    [self removeSong:song sync:YES];
}

- (void)removeSong:(SongData*)song sync:(BOOL)sync
{
    SongData *found;
    unsigned int idx;
    
    for (idx = 0; idx < [songQueue count]; ++idx) {
        found = [songQueue objectAtIndex:idx];
        if ([found isEqualToSong:song] &&
             [[found songID] isEqualToNumber:[song songID]]) {
            
            [found retain];
            [songQueue removeObjectAtIndex:idx];
            
            [[NSNotificationCenter defaultCenter]
                postNotificationName:QM_NOTIFICATION_SONG_DEQUEUED
                object:self
                userInfo:[NSDictionary dictionaryWithObject:song forKey:QM_NOTIFICATION_USERINFO_KEY_SONG]];
        
            [found release];
            
            if (sync)
                [self syncQueue:nil];
            break;
        }
    }
}

// Unsorted array of songs
- (NSArray*)songs
{
    return ([[songQueue copy] autorelease]);
}

- (unsigned)count
{
    return ([songQueue count]);
}

- (unsigned)totalSubmissionsCount
{
    return (totalSubmissions);
}

- (NSNumber*)totalSubmissionsPlayTimeInSeconds
{
    return ([NSNumber numberWithUnsignedInt:totalSubmissionSeconds]);
}

// Aliases for Protocol Manager methods
- (unsigned)submissionAttemptsCount
{
    return ([[ProtocolManager sharedInstance] submissionAttemptsCount]);
}

- (unsigned)successfulSubmissionsCount
{
    return ([[ProtocolManager sharedInstance] successfulSubmissionsCount]);
}

#define CACHE_SIG_KEY @"Persistent Cache Sig"

- (BOOL)writeToFile:(NSString*)path atomically:(BOOL)atomic
{
    NSMutableArray *songs = [NSMutableArray array];
    NSDictionary *songData;
    SongData *song;
    NSEnumerator *en = [songQueue objectEnumerator];
    
    if (0 == [songQueue count])
        return (NO);
    
    while ((song = [en nextObject])) {
        if ((songData = [song songData]))
            [songs addObject:songData];
        else
            ScrobLog(SCROB_LOG_ERR, @"Failed to add '%@' to persitent store.\n", [song brief]);
    }
    
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:songs
        format:NSPropertyListBinaryFormat_v1_0
        errorDescription:nil];
    if (data && [data writeToFile:path atomically:atomic]) {
        NSString *md5 = [[NSApp delegate] md5hash:data];
        [[NSUserDefaults standardUserDefaults] setObject:md5 forKey:CACHE_SIG_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return (YES);
    }
    
    return (NO);
}

- (NSArray*)restoreQueueWithPath:(NSString*)path
{
    NSString *md51, *md52;
    NSData *data;
    NSArray *pCache = nil;
    
    //data = [NSString stringWithContentsOfFile:queuePath];
    data = [NSData dataWithContentsOfFile:queuePath];
    md51 = [[NSUserDefaults standardUserDefaults] stringForKey:CACHE_SIG_KEY];
    md52 = data ? [[NSApp delegate] md5hash:data] : @"";
    if (data && [md51 isEqualToString:md52]) {
        NSPropertyListFormat format;
        pCache = [NSPropertyListSerialization propertyListFromData:data
            mutabilityOption:NSPropertyListImmutable
            format:&format
            errorDescription:nil];
        if (NO == [pCache isKindOfClass:[NSArray class]])
            pCache = nil;
    } else if (data) {
        ScrobLog(SCROB_LOG_WARN, @"Ignoring persistent cache: it's corrupted.");
        // This will remove the file, since the queue is 0
    #ifdef notyet
        [self syncQueue:nil];
    #endif
    }
    return (pCache);
}

- (void)syncQueue:(id)sender
{
    if (0 == [songQueue count]) {
        [[NSUserDefaults standardUserDefaults] setObject:@"" forKey:CACHE_SIG_KEY];
        [[NSFileManager defaultManager] removeFileAtPath:queuePath handler:nil];
    } else if (NO == [self writeToFile:queuePath atomically:YES]) {
        ScrobLog(SCROB_LOG_ERR, @"Failed to create queue file: %@!\n", queuePath);
    }
}

- (void)profileDidReset:(NSNotification*)note
{
    totalSubmissions = 0;
    totalSubmissionSeconds = 0;
}

- (id)init
{
    if ((self = [super init])) {
        FSRef appSupport;
        
        if (noErr == FSFindFolder(kUserDomain, kApplicationSupportFolderType, kCreateFolder, &appSupport)) {
            NSURL *url = (NSURL*)CFURLCreateFromFSRef(kCFAllocatorSystemDefault, &appSupport);
            NSString *dirPath  = (NSString*)CFURLCopyFileSystemPath((CFURLRef)url, kCFURLPOSIXPathStyle);
            [url release];
            if (dirPath) {
                queuePath = [[dirPath stringByAppendingPathComponent:@"net_sourceforge_iscrobbler_cache.plist"] retain];
                [dirPath release];
            }
        }

        songQueue = [[NSMutableArray alloc] init];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(profileDidReset:) name:RESET_PROFILE object:nil];
        
        // Read in the persistent cache
        if (queuePath) {
            NSArray *pCache = [self restoreQueueWithPath:queuePath];
            if ([pCache count]) {
                NSEnumerator *en = [pCache objectEnumerator];
                SongData *song;
                NSDictionary *data;
                while ((data = [en nextObject])) {
                    song = [[SongData alloc] init];
                    if ([song setSongData:data]) {
                        ScrobLog(SCROB_LOG_VERBOSE, @"Restoring '%@' from persistent store.\n", [song brief]);
                        // Make sure the song passes submission rules
                        [song setStartTime:[song postDate]];
                        [song setPosition:[song duration]];
                        (void)[self queueSong:song submit:NO]; 
                    } else {
                        ScrobLog(SCROB_LOG_ERR, @"Failed to restore song from persistent store: %@\n", data); 
                    }
                    [song release];
                }
            }
        } else {
            ScrobLog(SCROB_LOG_ERR, @"Persistent cache disabled: could not find path.");
        }
    }
    
    return (self);
}

- (void)dealloc
{
    [queuePath release];
    [songQueue release];
    [super dealloc];
}

@end