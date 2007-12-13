//
//  ISISiTunesLibrary.m
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/27/2007.
//  Copyright 2007 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import <unistd.h>
#import <libKern/OSAtomic.h>

#import "ISiTunesLibrary.h"
#import "ISThreadMessenger.h"

@interface ISiTunesLibrary (TunesPrivate)
- (BOOL)createThread;
@end

@implementation ISiTunesLibrary

- (NSString*)pathToXMLFile
{
    NSString *path = [@"~/Music/iTunes/iTunes Music Library.xml" stringByExpandingTildeInPath];
    path = [[NSFileManager defaultManager] destinationOfAliasAtPath:path error:nil];
    #ifdef obsolete
    // is this even valid since iTunes 5 or so?
    if (NO == [[NSFileManager defaultManager] fileExistsAtPath:path])
        path = [@"~/Documents/iTunes/iTunes Music Library.xml" stringByExpandingTildeInPath];
    #endif
    return (path);
}

#ifdef notyet
- (NSDate*)creationDate
{
    NSString *path = [self pathToXMLFile];
    NSDictionary *attrs;
    #if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
    if (NO == [[NSFileManager defaultManager] respondsToSelector:@selector(attributesOfItemAtPath:error:)])
        attrs = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:YES];
    else
    #endif
        attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return ([attrs objectForKey:NSFileCreationDate]);
}
#endif

- (NSDictionary*)load
{
    NSDictionary *iTunesLib = [self loadFromPath:[self pathToXMLFile]];
    return (iTunesLib);
}

- (NSDictionary*)loadFromPath:(NSString*)path
{
    return ([NSDictionary dictionaryWithContentsOfFile:path]);
}

// selector takes a single arg of type NSDictionary
- (void)loadInBackgroundWithDelegate:(id)delegate didFinishSelector:(SEL)selector context:(id)context
{
    NSString *path = [self pathToXMLFile];
    [self loadInBackgroundFromPath:path withDelegate:delegate didFinishSelector:selector context:context];
}

- (void)loadInBackgroundFromPath:(NSString*)path withDelegate:(id)delegate didFinishSelector:(SEL)selector context:(id)context
{
    if (![self createThread]) {
        [delegate performSelector:selector withObject:nil];
        return;
    }
    
    // send load msg
    NSInvocation *arg = [NSInvocation invocationWithMethodSignature:[delegate methodSignatureForSelector:selector]];
    [arg retainArguments];
    [arg setTarget:delegate]; // arg 0
    [arg setSelector:selector]; // arg 1
    [arg setArgument:&context atIndex:2];
    [ISThreadMessenger makeTarget:thMsgr performSelector:@selector(readiTunesLib:)
        withObject:[NSArray arrayWithObjects:path, arg, nil]];
}

- (BOOL)copyToPath:(NSString*)path
{
    NSString *libPath = [self pathToXMLFile];
    if (![[NSFileManager defaultManager] fileExistsAtPath:libPath] || ![self createThread])
        return (NO);
    
    [ISThreadMessenger makeTarget:thMsgr performSelector:@selector(copyiTunesLib:) withObject:path];
    return (YES);
}

- (void)releaseiTunesLib:(NSDictionary*)lib
{
    [ISThreadMessenger makeTarget:thMsgr performSelector:@selector(releaseObject:) withObject:lib];
}

// private
- (void)releaseObject:(id)obj
{
    [obj release];
}

- (void)copyiTunesLib:(NSString*)dest
{
    NSString *libPath = [self pathToXMLFile];
    (void)[[NSFileManager defaultManager] removeFileAtPath:dest handler:nil];
    if ([[NSFileManager defaultManager] copyPath:libPath toPath:dest handler:nil])
        ScrobLog(SCROB_LOG_TRACE, @"Copied iTunes library.");
    
}

- (void)readiTunesLib:(NSArray*)args
{
    NSDictionary *upcallArg;
    NSInvocation *didEnd = nil;
    @try {
    didEnd = [args objectAtIndex:1];
    
    NSDictionary *lib = [self loadFromPath:[args objectAtIndex:0]];
    
    NSDictionary *context;
    [didEnd getArgument:&context atIndex:2];
    upcallArg = [NSDictionary dictionaryWithObjectsAndKeys:
        context, @"context",
        lib, @"iTunesLib",
        nil];
    } @catch (id e) {
        ScrobLog(SCROB_LOG_ERR, @"readiTunesLib: exception %@", e);
        upcallArg = nil;
    }
    ISASSERT(didEnd != nil, "nil target!");
    [[didEnd target] performSelectorOnMainThread:[didEnd selector] withObject:upcallArg waitUntilDone:NO];
}

- (void)readiTunesLibThread:(id)arg
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    id msg = [[ISThreadMessenger scheduledMessengerWithDelegate:self] retain];
    @synchronized (self) {
        thMsgr = msg;
    }
    do {
        [pool release];
        pool = [[NSAutoreleasePool alloc] init];
        @try {
        [[NSRunLoop currentRunLoop] acceptInputForMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        } @catch (id e) {
            ScrobLog(SCROB_LOG_TRACE, @"[readiTunesLib:] uncaught exception: %@", e);
        }
    } while (1);
    
    ISASSERT(0, "readiTunesLib run loop exited!");
    [thMsgr release];
    thMsgr = nil;
    [pool release];
    [NSThread exit];
}

- (BOOL)createThread
{
    OSMemoryBarrier();
    if (thMsgr) {
         // thMsgr could be NSNull, but this should only be called from the main thread, which goes through the wait
        // loop below the first time, so that should not happen.
        ISASSERT(NO == [thMsgr isKindOfClass:[NSNull class]], "bad messenger");
        return (YES);
    }
    
    BOOL createth;
    @synchronized (self) {
        if (thMsgr)
            createth = NO;
        else {
            createth = YES;
            thMsgr = (id)[NSNull null];
        }
    }
    if (createth) {
        [NSThread detachNewThreadSelector:@selector(readiTunesLibThread:) toTarget:self withObject:self];
        useconds_t uWait = 0;
        id msg;
        do {
            usleep(50000);
            OSMemoryBarrier();
            msg = thMsgr;
        } while ([msg isKindOfClass:[NSNull class]] && (uWait += 50000) <= 500000);
        if ([msg isKindOfClass:[NSNull class]]) {
            @synchronized (self) {
                thMsgr = nil;
            }
            ScrobLog(SCROB_LOG_ERR, @"Timed out while waiting for creation of iTunes reader thread.");
            return (NO);
        }
    }
    return (YES);
}

// singleton support

+ (ISiTunesLibrary*)sharedInstance
{
    static ISiTunesLibrary *shared = nil;
    return (shared ? shared : (shared = [[ISiTunesLibrary alloc] init]));
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

@end
