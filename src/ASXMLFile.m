//
//  ASXMLFile.m
//  iScrobbler
//
//  Created by Brian Bergstrand on 9/20/2007.
//  Copyright 2007 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import "ASXMLFile.h"
#import "ProtocolManager.h"

#define ASXML_DEFAULT_CACHE_TTL 300
static NSMutableDictionary *xmlCache = nil;

@implementation ASXMLFile

// private
- (id)initWithDelegate:(id)del
{
    delegate = del;
    return (self);
}

- (void)downloadWithURL:(NSURL*)durl
{
    ISASSERT(url == nil, "url already initialized!");
    url = [durl retain];
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30.0];
    [req setValue:[[ProtocolManager sharedInstance] userAgent] forHTTPHeaderField:@"User-Agent"];
    conn = [[NSURLConnection connectionWithRequest:req delegate:self] retain];
}

- (void)setXML:(NSXMLDocument*)data
{
    if (data != xml) {
        [xml release];
        xml = [data retain];
    }
}

- (void)sendDidFinishLoadingForCacheFill
{
    id o = delegate;
    if (o) {
        delegate = nil; // no more messages now that we have finished
        [o xmlFileDidFinishLoading:self];
    }
}

+ (void)reaper:(NSTimer*)timer
{
    NSEnumerator *en = [xmlCache keyEnumerator];
    NSDictionary *d;
    id key;
    NSMutableArray *keysToRemove = [NSMutableArray array];
    NSDate *now = [NSDate date];
    while ((key = [en nextObject])) {
        d = [xmlCache objectForKey:key];
        // if there's no xml data yet, then the object is still being setup
        if ([d objectForKey:@"xml"] && [now isGreaterThanOrEqualTo:[d objectForKey:@"expires"]])
            [keysToRemove addObject:key];
    }
    if ([keysToRemove count] > 0)
        [xmlCache removeObjectsForKeys:keysToRemove];
}

// public
+ (ASXMLFile*)xmlFileWithURL:(NSURL*)url delegate:(id)delegate cachedForSeconds:(NSInteger)seconds
{
    if (!url)
        return (nil);
    
    if (!xmlCache) {
        xmlCache = [[NSMutableDictionary alloc] init];
        (void)[NSTimer scheduledTimerWithTimeInterval:ASXML_DEFAULT_CACHE_TTL * 2
            target:[ASXMLFile class] selector:@selector(reaper:)
            userInfo:nil repeats:YES];
    }

    ASXMLFile *f = [[ASXMLFile alloc] initWithDelegate:delegate];
    
    NSMutableDictionary *d;
    NSDate *now = [NSDate date];
    if (seconds > 0 && (d = [xmlCache objectForKey:url]) && [[d objectForKey:@"expires"] isGreaterThan:now]) {
        ISASSERT([d objectForKey:@"xml"] != nil, "cache entry with nil xml!");
        ScrobDebug(@"found cached entry for: %@", url);
        @try {
        [f setXML:[d objectForKey:@"xml"]];
        f->cached = YES;
        f->delegate = delegate;
        #ifdef ISDEBUG
        f->url = [url retain];
        #endif
        } @catch (id e) {
            ScrobLog(SCROB_LOG_ERR, @"exception creating ASXMLFile (%@) from cache: %@", url, e);
            (void)[f autorelease];
            return (nil);
        }
        
        [f performSelector:@selector(sendDidFinishLoadingForCacheFill) withObject:nil afterDelay:0.0];
        return ([f autorelease]);
    }
    
    // not found in cache, setup a cache entry and fetch it
    d = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithLongLong:seconds], @"cacheTime",
        [NSDate distantPast], @"expires",
        nil];
    [xmlCache setObject:d forKey:url];
    [d release];
    [f downloadWithURL:url];
    return ([f autorelease]);
}

+ (ASXMLFile*)xmlFileWithURL:(NSURL*)url delegate:(id)delegate cached:(BOOL)cached
{
    return ([ASXMLFile xmlFileWithURL:url delegate:delegate cachedForSeconds:cached ? ASXML_DEFAULT_CACHE_TTL : 0]);
}

+ (ASXMLFile*)xmlFileWithURL:(NSURL*)url delegate:(id)delegate
{
    return ([ASXMLFile xmlFileWithURL:url delegate:delegate cached:YES]);
}

+ (void)expireCacheEntryForURL:(NSURL*)url
{
    @try {
    [xmlCache removeObjectForKey:url];
    } @catch (id e) {}
}

+ (void)expireAllCacheEntries
{
    @try {
    [xmlCache removeAllObjects];
    } @catch (id e) {}
}


- (BOOL)cached
{
    return (cached);
}

- (NSXMLDocument*)xml
{
    return (xml);
}

- (void)cancel
{
    delegate = nil;
    [responseData release];
    responseData = nil;
    if (conn) {
        [conn cancel];
        [conn autorelease];
        conn = nil;
        
        [xmlCache removeObjectForKey:url];
    }
}

- (NSArray*)tags
{
    NSMutableArray *tags = [NSMutableArray array];
    @try {
        NSArray *names = [[xml rootElement] elementsForName:@"tag"];
        NSEnumerator *en = [names objectEnumerator];
        NSString *tagName;
        NSXMLElement *e;
        while ((e = [en nextObject])) {
            // user/artist tags have elements, global tags have attributes, why?
            if ((tagName = [[e attributeForName:@"name"] stringValue])
                || (tagName = [[[e elementsForName:@"name"] objectAtIndex:0] stringValue])) {
                
                id e2;
                NSURL *turl;
                @try {
                if (!(e2 = [e attributeForName:@"url"]))
                    e2 = [[e elementsForName:@"url"] objectAtIndex:0];
                turl = [NSURL URLWithString:[e2 stringValue]];
                } @catch(id ex) {
                turl = nil;
                ScrobDebug(@"exception '%@' processing URL for %@", ex, tagName);
                }
                
                NSNumber *count;
                @try {
                if (!(e2 = [e attributeForName:@"count"]))
                    e2 = [[e elementsForName:@"count"] objectAtIndex:0];
                count = [NSNumber numberWithLong:[e2 integerValue]];
                } @catch(id ex) {
                count = [NSNumber numberWithUnsignedInt:0];
                ScrobDebug(@"exception '%@' processing count for %@", ex, tagName);
                }
                
                NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                    [tagName stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding], @"name",
                    count, @"count",
                    turl, @"url",
                    nil];
                [tags addObject:entry];
            }
        }
    } @catch (NSException *e) {
        ScrobLog(SCROB_LOG_ERR, @"ASXMLFile: Exception processing xml data as tags: %@", e);
    }
    
    return (tags);
}

- (NSArray*)users
{
    NSMutableArray *users = [NSMutableArray array];
    @try {
        NSArray *names = [[xml rootElement] elementsForName:@"user"];
        NSEnumerator *en = [names objectEnumerator];
        NSString *user;
        NSXMLElement *e;
        while ((e = [en nextObject])) {
            if ((user = [[[e attributeForName:@"username"] stringValue]
                stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding])) {
                
                NSURL *uurl, *iurl;
                @try {
                uurl = [NSURL URLWithString:[[[e elementsForName:@"url"] objectAtIndex:0] stringValue]];
                } @catch(id ex) {
                uurl = nil;
                ScrobDebug(@"exception '%@' processing URL for %@", ex, user);
                }
                @try {
                iurl = [NSURL URLWithString:[[[e elementsForName:@"image"] objectAtIndex:0] stringValue]];
                } @catch(id ex) {
                iurl = nil;
                ScrobDebug(@"exception '%@' processing image URL for %@", ex, user);
                }
                
                NSString *match;
                @try {
                match = [[[e elementsForName:@"match"] objectAtIndex:0] stringValue];;
                } @catch(id ex) {
                match = nil;
                ScrobDebug(@"exception '%@' processing image URL for %@", ex, user);
                }
                
                NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                    [user stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding], @"name",
                    uurl, @"url",
                    iurl, @"image",
                    // only valid for neighbors, will be nil for friends
                    match ? [NSNumber numberWithUnsignedInt:[match floatValue]] : nil, @"match",
                    nil];
                [users addObject:entry];
            }
        }
    } @catch (NSException *e) {
        ScrobLog(SCROB_LOG_ERR, @"ASXMLFile: Exception processing xml data as users: %@", e);
    }
    
    return (users);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!responseData) {
        responseData = [[NSMutableData alloc] initWithData:data];
    } else {
        [responseData appendData:data];
    }
}

-(void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)reason
{
    [conn autorelease];
    conn = nil;
    ScrobLog(SCROB_LOG_TRACE, @"Connection failure: %@\n", reason);
    [responseData release];
    responseData = nil;
    
    id o = delegate;
    delegate = nil; // no more messages now that we have finished
    [o xmlFile:self didFailWithError:reason];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    [conn autorelease];
    conn = nil;
    NSError *err = nil;
    
    [self setXML:nil];
    NSUInteger len;
    if (responseData && (len = [responseData length]) > 0) {
        const char *bytes = [responseData bytes];
        NSString *head = [[[NSString alloc] initWithBytes:bytes length:MIN(len,500) encoding:NSUTF8StringEncoding] autorelease];
        // There's some crashers in NSXMLDocument, so avoid passing HTML and run the parser with lint enabled
        if (NSNotFound == [head rangeOfString:@"<html>" options:NSLiteralSearch].location) {
            id x = [[NSXMLDocument alloc] initWithData:responseData
                options:NSXMLDocumentTidyXML // attempts to correct invalid XML
                error:&err];
            [self setXML:x];
            [x release];
        }
    }
    
    if (!xml)
        err = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
    if (err) {
        [self connection:connection didFailWithError:err];
        return;
    }
    
    [responseData release];
    responseData = nil;
    
    // Cache the response
    NSMutableDictionary *d = [xmlCache objectForKey:url];
    ISASSERT(d != nil, "missing cache entry!");
    
    NSDate *expires = [[NSDate date] addTimeInterval:[[d objectForKey:@"cacheTime"] doubleValue]];
    [d setObject:xml forKey:@"xml"];
    [d setObject:expires forKey:@"expires"];
    ScrobDebug(@"added cached entry for: %@ expiring at %@", url, expires);
    
    id o = delegate;
    delegate = nil; // no more messages now that we have finished
    [o xmlFileDidFinishLoading:self];
}

- (void)dealloc
{
    [conn cancel];
    [conn autorelease];
    [url release];
    [xml release];
    [super dealloc];
}

@end
