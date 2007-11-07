//
//  ISProxy.m
//  iScrobbler
//
//  Created by Brian Bergstrand on 11/6/2007.
//  Copyright 2007 Brian Bergstrand.
//
//  Released under the GPL, license details available res/gpl.txt
//

#import "ISProxy.h"
#import "KFAppleScriptHandlerAdditionsCore.h"
#import "KFASHandlerAdditions-TypeTranslation.h"

@implementation ISProxy

- (NSDictionary*)runScriptWithURL:(in NSURL*)url handler:(in NSString*)handler args:(in NSArray*)args;
{
    id result = nil;
    @try {
        NSAppleScript *script = [compiledScripts objectForKey:[url path]];
        if (!script) {
            if (!(script = [[[NSAppleScript alloc] initWithContentsOfURL:url error:nil] autorelease])) {
                return ([NSDictionary dictionaryWithObject:@"script failed to initialize" forKey:@"error"]);
            }
            
            if (![script compileAndReturnError:nil]) {
                return ([NSDictionary dictionaryWithObject:@"script failed to compile" forKey:@"error"]);
            }
            
            [compiledScripts setObject:script forKey:[url path]];
        }
        
        result = [script executeHandler:handler withParametersFromArray:args];
        return ([NSDictionary dictionaryWithObject:result forKey:@"result"]);
        
    } @catch (NSException *e) {
        return ([NSDictionary dictionaryWithObject:
            [@"script failed to initialize" stringByAppendingString:[e description]] forKey:@"error"]);
    }
    
    return (nil);
}

- (oneway void)kill
{
    [NSApp terminate:nil];
}

- (id)init
{
    self = [super init];
    compiledScripts = [[NSMutableDictionary alloc] init];
}

@end


int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApp = [NSApplication sharedApplication];
    
    NSConnection *conn = [[NSConnection alloc] init];
    [conn setRootObject:[[ISProxy alloc] init]];
    [conn registerName:ISProxyName];
    
    [NSApp finishLaunching];
    do {
        [pool release];
        pool = [[NSAutoreleasePool alloc] init];
        @try {
        [[NSRunLoop currentRunLoop] acceptInputForMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        } @catch (id e) {
            //ScrobLog(SCROB_LOG_TRACE, @"[sessionManager:] uncaught exception: %@", e);
        }
    } while (1);
    
    return (0);
}