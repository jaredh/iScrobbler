//
//  PreferenceController.m
//  iScrobbler
//
//  Created by Sam Ley on Feb 14, 2003.
//  Released under the GPL, license details available at
//  http://iscrobbler.sourceforge.net
//

#import "PreferenceController.h"
// PreferenceControllerStrings.h contains definitions of program strings.
#import "PreferenceControllerStrings.h"
#import "keychain.h"

NSString *CDCNumSongsKey=@"Number of Songs to Save";

@implementation PreferenceController

-(id)init
{
	NSLog(@"Preferences init");
    if(self=[super initWithWindowNibName:@"Preferences"]){
        [self setWindowFrameAutosaveName:@"PrefWindow"];
    }
    if(!myKeyChain)
        myKeyChain=[[KeyChain alloc] init];

    songData = nil;

    prefs = [[NSUserDefaults standardUserDefaults] retain];
    nc=[NSNotificationCenter defaultCenter];
    return self;
}

-(void)awakeFromNib
{
    [nc addObserver:self selector:@selector(handleLastResultChanged:)
               name:@"lastResultChanged"
             object:nil];
	[nc addObserver:self selector:@selector(handleLastHandshakeResultChanged:)
               name:@"lastHandshakeResultChanged"
             object:nil];
}

-(void)windowDidLoad
{
    [versionNumber setStringValue:[[prefs stringForKey:@"version"] substringToIndex:5]];
    [self updateFields];
    [window makeMainWindow];
}


-(void)savePrefs
{
    [prefs setObject:[username stringValue] forKey:@"username"];
    [prefs setInteger:[numRecentSongsField intValue] forKey:CDCNumSongsKey];
        
    [prefs synchronize];
    NSLog(@"prefs saved");

    if(![[password stringValue] isEqualToString:@""])
    {
        [myKeyChain setGenericPassword:[password stringValue]
                                 forService:@"iScrobbler"
                                    account:[prefs stringForKey:@"username"]];
        // NSLog(@"password stored as: %@",[myKeyChain genericPasswordForService:@"iScrobbler"
        //                                                account:[prefs stringForKey:@"username"]]);
    }
    [nc postNotificationName:@"CDCNumRecentSongsChanged" object:self];
}

- (void)handleLastResultChanged:(NSNotification *)notification
{
    [self updateFields];
}

- (void)handleLastHandshakeResultChanged:(NSNotification *)notification
{
    [self updateFields];
}

-(void)generateResultText
{
	//NSLog(@"lastHandshakeResult: %@", [self lastHandshakeResult]);
	
	if([self lastHandshakeResult] == nil) {
		//NSLog(@"No connection yet");
        [self setLastResult:@"No connection yet."];
        [self setLastResultLong:NO_CONNECTION_LONG];
        [self setLastResultShort:NO_CONNECTION_SHORT];
    }  else if([[self lastHandshakeResult] hasPrefix:@"UPTODATE"]) {
		//NSLog(@"iScrobbler is Up To Date");
    }  else if([[self lastHandshakeResult] hasPrefix:@"UPDATE"]) {
		//NSLog(@"iScrobbler version is out of date");
        NSMutableDictionary * attribs = [NSMutableDictionary dictionary];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSCenterTextAlignment];
        [attribs setObject:[NSColor colorWithCalibratedRed:1.0
                                                     green:0.0
                                                      blue:0.0
                                                     alpha:1.0]
                    forKey:NSForegroundColorAttributeName];
        [attribs setObject:[style autorelease] forKey:NSParagraphStyleAttributeName];
        NSAttributedString * attribString = [[NSAttributedString alloc] initWithString:NOT_UPTODATE 		attributes:attribs];
        [self setLastResultShort:SUBMISSION_SUCCESS_OUTOFDATE_SHORT];
        [self setLastResultLong:SUBMISSION_SUCCESS_OUTOFDATE_LONG];
        [versionWarning setStringValue:[attribString autorelease]];
        [updateButton setEnabled:YES];
        [self setDownloadURL:[[lastHandshakeResult componentsSeparatedByString:@" "] objectAtIndex:1]];
    } else if([[self lastHandshakeResult] hasPrefix:@"FAILED"]) {
		//NSLog(@"Handshaking Failed");
        [self setLastResultShort:FAILURE_SHORT];
        [self setLastResultLong:FAILURE_LONG];
    } else if([[self lastHandshakeResult] hasPrefix:@"BADUSER"]) {
		//NSLog(@"Bad User!  Bad!");
        [self setLastResultShort:AUTH_SHORT];
        [self setLastResultLong:AUTH_LONG];
    }
	
    //NSLog(@"lastResult: %@", [self lastResult]);
	//Check to see if the script returns OK
    if([[self lastResult] hasPrefix:@"OK"]) {
        [self setLastResultShort:SUBMISSION_SUCCESS_SHORT];
        [self setLastResultLong:SUBMISSION_SUCCESS_LONG];
    } else if([[self lastResult] hasPrefix:@"FAILED"]) {
        [self setLastResultShort:FAILURE_SHORT];
        [self setLastResultLong:FAILURE_LONG];
    } else if([[self lastResult] hasPrefix:@"BADAUTH"]) {
        [self setLastResultShort:AUTH_SHORT];
        [self setLastResultLong:AUTH_LONG];
    } else if([[self lastResult] hasPrefix:@"Couldn't resolve"]) {
        [self setLastResultShort:COULDNT_RESOLVE_SHORT];
        [self setLastResultLong:COULDNT_RESOLVE_LONG];
    } else if([[self lastResult] hasPrefix:@"The requested file was not found"]) {
        [self setLastResultShort:NOT_FOUND_SHORT];
        [self setLastResultLong:NOT_FOUND_LONG];
    }
}    

- (void)updateFields
{
    [self generateResultText];
    [numRecentSongsField setIntValue:[prefs integerForKey:CDCNumSongsKey]];
    [username setStringValue:[prefs stringForKey:@"username"]];
    [lastResultDataField setString:[self lastResult]];
    [lastResultLongField setString:[self lastResultLong]];
    [lastResultShortField setStringValue:[self lastResultShort]];

    NSLog(@"preparing lastSongSubmitted");
    //NSLog(@"songData: %@",songData);
    if([self songData] != nil)
    {
        NSMutableString* unEscapedTitle = [NSMutableString stringWithString:[(NSString*)
        CFURLCreateStringByReplacingPercentEscapes(NULL, (CFStringRef)[[self songData] 		title], (CFStringRef)@"") autorelease]];
        
        if(![[[self songData] artist] isEqualToString:@""])
        {
            [unEscapedTitle insertString:@" - " atIndex:0];
            NSString* unEscapedArtist = [(NSString*) 		CFURLCreateStringByReplacingPercentEscapes(NULL, (CFStringRef)[[self songData] 			artist], (CFStringRef)@"") autorelease];

            [unEscapedTitle insertString:unEscapedArtist atIndex:0];
        }
        [lastSongSubmitted setStringValue:unEscapedTitle];
        [songDataTable reloadData];
        
    }

    if(![[myKeyChain genericPasswordForService:@"iScrobbler"
                                       account:[prefs stringForKey:@"username"]] 			isEqualToString:@""])
    {
        [passwordStored setStringValue:PASS_STORED];
    } else {
        [passwordStored setStringValue:PASS_NOT_STORED];
    }
    
    [password setStringValue:@""];
    //NSLog(@"Fields updated");
}

- (IBAction)forgetPassword:(id)sender
{
    [myKeyChain removeGenericPasswordForService:@"iScrobbler"
                                        account:[prefs stringForKey:@"username"]];
    [self updateFields];
}

- (IBAction)apply:(id)sender
{
    [self savePrefs];
    [self updateFields];
}

- (IBAction)cancel:(id)sender
{
    [self updateFields];
    [[self window] performClose:nil];
}

- (IBAction)OK:(id)sender
{
    [self savePrefs];
    [self updateFields];
    [[self window] performClose:nil];
}

-(IBAction)submitWebBugReport:(id)sender
{
    NSURL *url = [NSURL URLWithString:@"http://sourceforge.net/tracker/?group_id=76514&atid=547327"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

-(IBAction)submitEmailBugReport:(id)sender
{

    NSString* mailtoLink = [NSString stringWithFormat:@"mailto:audioscrobbler-development@lists.sourceforge.net?subject=iScrobbler Bug Report&body=--Please explain the circumstances of the bug here--\nThanks for contributing!\n\nResult Data Dump:\n\n%@\n\n%@",lastResult,songData];
    
    NSURL *url = [NSURL URLWithString:[(NSString*)
        CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)mailtoLink, NULL, NULL, 	kCFStringEncodingUTF8) autorelease]];

    [[NSWorkspace sharedWorkspace] openURL:url];

}


- (void)windowWillClose:(NSNotification *)aNotification
{
    [self savePrefs];
    [self updateFields];
}

-(void)setLastResult: (NSString *)newLastResult
{
    [newLastResult retain];
    [lastResult release];
    lastResult = newLastResult;
}

-(NSString *)lastResult;
{
    return lastResult;
}

-(void)setLastHandshakeResult: (NSString *)newLastHandshakeResult
{
    [newLastHandshakeResult retain];
    [lastHandshakeResult release];
    lastHandshakeResult = newLastHandshakeResult;
}

-(NSString *)lastHandshakeResult;
{
    return lastHandshakeResult;
}
-(void)setLastResultShort: (NSString *)newLastResultShort
{
    [newLastResultShort retain];
    [lastResultShort release];
    lastResultShort = newLastResultShort;
}

-(NSString *)lastResultShort;
{
    return lastResultShort;
}

-(void)setLastResultLong: (NSString *)newLastResultLong
{
    [newLastResultLong retain];
    [lastResultLong release];
    lastResultLong = newLastResultLong;
}

-(NSString *)lastResultLong;
{
    return lastResultLong;
}


-(IBAction)queryiTunes:(id)sender {}
-(IBAction)queryAudion:(id)sender {}

-(void)setSongData: (SongData *)newSongData
{
    [newSongData retain];
    [songData release];
    songData = newSongData;
}

-(SongData *)songData
{
    return songData;
}

-(IBAction)downloadUpdate:(id)sender
{
    NSURL *url = [NSURL URLWithString:[self downloadURL]];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

//-(IBAction)copy:(id)sender
//{
//    NSPasteboard *pb = [NSPasteboard generalPasteboard];
//    NSArray *pb_types = [NSArray arrayWithObjects:NSStringPboardType,NULL];
//    [pb declareTypes:pb_types owner:NULL];
//[pb setData:[self selectedItemsAsData] forType:NSStringPboardType];
//}

-(NSString *)downloadURL
{
    return downloadURL;
}

-(void)setDownloadURL:(NSString *)newDownloadURL 
{
    [newDownloadURL retain];
    [downloadURL release];
    downloadURL = newDownloadURL;
}

- (int)numberOfRowsInTableView:(NSTableView *)tableView
{
    return 4;
}

- (id)tableView:(NSTableView *)tableView
     objectValueForTableColumn:(NSTableColumn *)tableColumn
                           row:(int)row
{
    NSMutableArray * propertyArray = [NSMutableArray array];
    NSMutableArray * valueArray = [NSMutableArray array];
    NSMutableDictionary * attribs = [NSMutableDictionary dictionary];
    [attribs setObject:[NSFont fontWithName:@"Helvetica" size:12]
                forKey:NSFontAttributeName];
    NSAttributedString * attribString = [NSAttributedString alloc];
    
    [propertyArray insertObject:@"Path"
                atIndex:0];
    [propertyArray insertObject:@"Duration"
                atIndex:0];
    [propertyArray insertObject:@"Title"
                atIndex:0];
    [propertyArray insertObject:@"Artist"
                atIndex:0];
    [propertyArray insertObject:@"Album"
                atIndex:0];

    if(songData != nil) {
        [valueArray insertObject:[[self songData] path] atIndex:0];
        [valueArray insertObject:[[[self songData] duration] stringValue] atIndex:0];
        [valueArray insertObject:[[self songData] title] atIndex:0];
        [valueArray insertObject:[[self songData] artist] atIndex:0];
        [valueArray insertObject:[[self songData] album] atIndex:0];
    }

    NSString * identifier = [[[NSString alloc] initWithString:[tableColumn identifier]] 	autorelease];

    if([identifier isEqualToString:@"property"]) {
        attribString = [attribString initWithString:[propertyArray objectAtIndex:row] attributes:attribs];
        [tableColumn setWidth:([[propertyArray objectAtIndex:2] sizeWithAttributes:attribs].width
                               +5)];
        return [attribString autorelease];
    } else {
        if(songData != nil) {
            [tableColumn setWidth:([[[self songData] path] sizeWithAttributes:attribs].width + 5)];

            attribString = [attribString 		initWithString:[(NSString*)CFURLCreateStringByReplacingPercentEscapes(NULL, 	(CFStringRef)[valueArray objectAtIndex:row],
            (CFStringRef)@"") autorelease] attributes:attribs];
        //[tableColumn setWidth:NSMakeSize([attribString size].width];
        return [attribString autorelease];
        } else {
            return nil;
        }
    }
}

- (void)dealloc
{
    [nc removeObserver:self];
    [nc release];
    [downloadURL release];
    [prefs release];
    [lastResult release];
    [songData release];
    [myKeyChain release];
    [lastResultLong release];
    [lastResultShort release];
    [super dealloc];
}

@end
