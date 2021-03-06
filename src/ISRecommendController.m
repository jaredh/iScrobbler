//
//  ISRecommendController.m
//  iScrobbler
//
//  Created by Brian Bergstrand on 1/8/2007.
//  Copyright 2007 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import "ISRecommendController.h"
#import "ProtocolManager.h"
#import "ASXMLFile.h"

@implementation ISRecommendController

- (IBAction)ok:(id)sender
{
    [[self window] endEditingFor:nil]; // force any editor to resign first-responder and commit
    send = YES;
    [self performSelector:@selector(performClose:) withObject:sender];
}

- (NSString*)who
{
    return (toUser ? toUser : @"");
}

- (NSString*)message
{
    return (msg ? msg : @"");
}

- (ISTypeToRecommend_t)type
{
    return (what);
}

- (void)setType:(ISTypeToRecommend_t)newtype
{
    what = newtype;
}

- (BOOL)send
{
    return (send);
}

- (id)representedObject
{
    return (representedObj);
}

- (void)setRepresentedObject:(id)obj
{
    if (obj != representedObj) {
        [representedObj release];
        representedObj = [obj retain];
    }
}

-(void)xmlFile:(ASXMLFile *)connection didFailWithError:(NSError *)reason
{
    [conn autorelease];
    conn = nil;
    [progress stopAnimation:nil];
}

- (void)xmlFileDidFinishLoading:(ASXMLFile *)connection
{
    NSXMLDocument *xml = [connection xml];

    [conn autorelease];
    conn = nil;
    
    @try {
        if ([[friends content] count])
            [friends removeObjects:[friends content]];
            
        NSArray *users = [[xml rootElement] elementsForName:@"user"];
        NSEnumerator *en = [users objectEnumerator];
        NSString *user;
        NSXMLElement *e;
        while ((e = [en nextObject])) {
            if ((user = [[[e attributeForName:@"username"] stringValue]
                stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding])) {
                
                NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                    user, @"name",
                    nil];
                [friends addObject:entry];
            }
        }
    } @catch (NSException *e) {
        ScrobLog(SCROB_LOG_ERR, @"Exception processing friends.xml: %@", e);
    }
    
    [progress stopAnimation:nil];
}

- (void)tableViewSelectionDidChange:(NSNotification*)note
{
    NSTableView *table = [note object];
    if (100 != [table tag])
        return;
    
    @try {
        NSArray *users = [friends selectedObjects];
        if ([users count] > 0) {
            id user = [users objectAtIndex:0];
            if ([user isKindOfClass:[NSDictionary class]]) {
                [self setValue:[user objectForKey:@"name"] forKey:@"toUser"];
            }
        }
    } @catch (id e) {}
}

- (void)closeWindow
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSTableViewSelectionDidChangeNotification object:nil];
    if ([[self window] isSheet])
        [NSApp endSheet:[self window]];
    [[self window] close];
    [[NSNotificationCenter defaultCenter] postNotificationName:ISRecommendDidEnd object:self];
}

- (IBAction)performClose:(id)sender
{
    [self closeWindow];
}

- (IBAction)showWindow:(id)sender
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tableViewSelectionDidChange:)
        name:NSTableViewSelectionDidChangeNotification object:nil];
    
    if (sender)
        [NSApp beginSheet:[self window] modalForWindow:sender modalDelegate:self didEndSelector:nil contextInfo:nil];
    else
        [super showWindow:nil];
    [progress startAnimation:nil];
    
    // Get the friends list
    NSString *user = [[[ProtocolManager sharedInstance] userName]
        stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSString *url = [[[NSUserDefaults standardUserDefaults] stringForKey:@"WS URL"]
        stringByAppendingFormat:@"user/%@/friends.xml", user];
    conn = [[ASXMLFile xmlFileWithURL:[NSURL URLWithString:url] delegate:self cachedForSeconds:600] retain];
}

- (void)windowDidLoad
{
    [[self window] setAlphaValue:IS_UTIL_WINDOW_ALPHA];
}

- (void)setArtistEnabled:(BOOL)enabled
{
    artistEnabled = enabled;
}

- (void)setTrackEnabled:(BOOL)enabled
{
    trackEnabled = enabled;
}

- (void)setAlbumEnabled:(BOOL)enabled
{
    albumEnabled = enabled;
}

- (id)init
{
    artistEnabled = trackEnabled = albumEnabled = YES;
    return ((self = [super initWithWindowNibName:@"Recommend"]));
}

- (void)dealloc
{
    [conn cancel];
    [conn release];
    [toUser release];
    [msg release];
    [super dealloc];
}

@end
