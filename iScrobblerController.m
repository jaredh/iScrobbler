//
//  iScrobblerController.m
//  iScrobbler
//
//  Created by Sam Ley on Feb 14, 2003.
//  Released under the GPL, license details available at
//  http://iscrobbler.sourceforge.net/

#import <openssl/md5.h>

#import "iScrobblerController.h"
#import <CURLHandle/CURLHandle.h>
#import <CURLHandle/CURLHandle+extras.h>
#import "PreferenceController.h"
#import "SongData.h"
#import "keychain.h"
#import "NSString+parse.h"
#import "QueueManager.h"
#import "ProtocolManager.h"
#import "ScrobLog.h"
#import "StatisticsController.h"

@interface iScrobblerController ( private )

- (void) restoreITunesLastPlayedTime;
- (void) setITunesLastPlayedTime:(NSDate*)date;

- (void)showNewVersionExistsDialog;

- (void) volumeDidMount:(NSNotification*)notification;
- (void) volumeDidUnmount:(NSNotification*)notification;

- (void)iTunesPlaylistUpdate:(NSTimer*)timer;

@end

// See iTunesPlayerInfoHandler: for why this is needed
@interface ProtocolManager (NoCompilerWarnings)
    - (float)minTimePlayed;
@end

#define CLEAR_MENUITEM_TAG          1
#define SUBMIT_IPOD_MENUITEM_TAG    4

#define MAIN_TIMER_INTERVAL 10.0

@implementation iScrobblerController

- (BOOL)validateMenuItem:(NSMenuItem *)anItem
{
    ScrobTrace(@"%@", [anItem title]);
    if(CLEAR_MENUITEM_TAG == [anItem tag])
        [self mainTimer:nil];
    else if(SUBMIT_IPOD_MENUITEM_TAG == [anItem tag] &&
         (!iPodMountPath || ![prefs boolForKey:@"Sync iPod"]))
        return NO;
    return YES;
}

- (void)handshakeCompleteHandler:(NSNotification*)note
{
    ProtocolManager *pm = [note object];
    
    if (([pm updateAvailable] && ![prefs boolForKey:@"Disable Update Notification"]))
        [self showNewVersionExistsDialog];
    else if ([[pm lastHandshakeResult] isEqualToString:HS_RESULT_BADAUTH])
        [self showBadCredentialsDialog];
}

- (void)badAuthHandler:(NSNotification*)note
{
    [self showBadCredentialsDialog];
}

// This method handles firing mainTimer: at the appropos time so we don't need to poll
// iTunes constantly.
- (void)iTunesPlayerInfoHandler:(NSNotification*)note
{
    NSDictionary *info = [note userInfo];
    ScrobLog(SCROB_LOG_TRACE, @"iTunes notification received: %@\n", [info objectForKey:@"Player State"]);
    
    // We got a notification, kill the current timer
    [mainTimer invalidate];
    [mainTimer release];
    mainTimer = nil;
    
    [self mainTimer:nil]; // Update state
    
    SongData *curSong = nil;
    if ([songList count] > 0)
        curSong = [songList objectAtIndex:0];
    
    BOOL isPlaying = [@"Playing" isEqualToString:[info objectForKey:@"Player State"]];
    //ScrobLog(SCROB_LOG_VERBOSE, @"\t %@ hasQueued: %i\n", [curSong brief], [curSong hasQueued]);
    if (isPlaying && ![curSong hasQueued]) {
        // iTunes gives us the track time as a quad int containing milliseconds, we need seconds
        double trackTime = [[info objectForKey:@"Total Time"] doubleValue] / 1000.0;
        
        // Fire the main timer again in half the track time to get it queued.
        // Ack! Protocol implementation details exposed! Don't know how else to do this though.
        trackTime = ceil(trackTime / 2.0); // Adjust the fire time to compensate for sub-seconds...
        if (trackTime > [[ProtocolManager sharedInstance] minTimePlayed])
            trackTime = [[ProtocolManager sharedInstance] minTimePlayed];
        trackTime -= [[curSong position] doubleValue]; // and elapsed time.
        
        ScrobLog(SCROB_LOG_TRACE, @"Firing mainTimer: in %0.2lf seconds for track %@.\n", trackTime, [curSong brief]);
        mainTimer = [[NSTimer scheduledTimerWithTimeInterval:trackTime
                        target:self
                        selector:@selector(mainTimer:)
                        userInfo:nil
                        repeats:NO] retain];
    }
}

- (void)enableStatusItemMenu:(BOOL)enable
{
    if (enable) {
        if (!statusItem) {
            statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength] retain];
            
            // 0x266B == UTF8 barred eigth notes
            [statusItem setTitle:[NSString stringWithFormat:@"%C",0x266B]];
            [statusItem setHighlightMode:YES];
            [statusItem setMenu:theMenu];
            [statusItem setEnabled:YES];
        }
    } else if (statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
        [statusItem setMenu:nil];
        [statusItem release];
        statusItem = nil;
    }
}

-(id)init
{
    // Read in a defaults.plist preferences file
    NSString * file = [[NSBundle mainBundle]
        pathForResource:@"defaults" ofType:@"plist"];
	
    NSDictionary * defaultPrefs = [NSDictionary dictionaryWithContentsOfFile:file];
	
    prefs = [[NSUserDefaults standardUserDefaults] retain];
    [prefs registerDefaults:defaultPrefs];
    
    // One user has reported the version # showing up in his personal prefs.
    // I don't know how this is happening, but I've never seen it myself. So here,
    // we just force the version # from the defaults into the personal prefs.
    [prefs setObject:[defaultPrefs objectForKey:@"version"] forKey:@"version"];
    
    [SongData setSongTimeFudge:MAIN_TIMER_INTERVAL + (MAIN_TIMER_INTERVAL / 2.0)];
	
    // Request the password and lease it, this will force it to ask
    // permission when loading, so it doesn't annoy you halfway through
    // a song.
    (void)[[KeyChain defaultKeyChain] genericPasswordForService:@"iScrobbler"
        account:[prefs stringForKey:@"username"]];
	
	// Create an instance of the preferenceController
    if(!preferenceController)
        preferenceController=[[PreferenceController alloc] init];
	
	// Set the script locations
    NSURL *url=[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath]
                stringByAppendingPathComponent:@"Scripts/controlscript.scpt"] ];
	
    // Get our iPod update script as text
    file = [[[NSBundle mainBundle] resourcePath]
                stringByAppendingPathComponent:@"iPodUpdate.applescript"];
    iPodUpdateScript = [[NSString alloc] initWithContentsOfFile:file];
    if (!iPodUpdateScript)
        ScrobLog(SCROB_LOG_CRIT, @"Failed to load iPodUpdateScript!\n");
    
    [self restoreITunesLastPlayedTime];
    
    if(self=[super init])
    {
        [NSApp setDelegate:self];
        
        script=[[NSAppleScript alloc] initWithContentsOfURL:url error:nil];
        nc=[NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(handlePrefsChanged:)
                   name:SCROB_PREFS_CHANGED
                 object:nil];
        
        // Register for mounts and unmounts (iPod support)
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
            selector:@selector(volumeDidMount:) name:NSWorkspaceDidMountNotification object:nil];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
            selector:@selector(volumeDidUnmount:) name:NSWorkspaceDidUnmountNotification object:nil];
        
        // Register for iTunes track change notifications (4.7 and greater)
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
            selector:@selector(iTunesPlayerInfoHandler:) name:@"com.apple.iTunes.playerInfo"
            object:nil];
        
        // Create protocol mgr
        (void)[ProtocolManager sharedInstance];
        
        // Register for PM notifications
        [nc addObserver:self
                selector:@selector(handshakeCompleteHandler:)
                name:PM_NOTIFICATION_HANDSHAKE_COMPLETE
                object:nil];
        [nc addObserver:self
                selector:@selector(badAuthHandler:)
                name:PM_NOTIFICATION_BADAUTH
                object:nil];
        
        // Create queue mgr
        (void)[QueueManager sharedInstance];
        if ([[QueueManager sharedInstance] count])
            [[QueueManager sharedInstance] submit];
    }
    return self;
}

- (void)awakeFromNib
{
    songList=[[NSMutableArray alloc ]init];
	
    mainTimer = [[NSTimer scheduledTimerWithTimeInterval:(MAIN_TIMER_INTERVAL)
                                                  target:self
                                                selector:@selector(mainTimer:)
                                                userInfo:nil
                                                 repeats:YES] retain];
    
    // Timer to update our internal copy of iTunes playlists
    [[NSTimer scheduledTimerWithTimeInterval:300.0
        target:self
        selector:@selector(iTunesPlaylistUpdate:)
        userInfo:nil
        repeats:YES] fire];
    
    [self enableStatusItemMenu:
        [[NSUserDefaults standardUserDefaults] boolForKey:@"Display Control Menu"]];
	
    [self mainTimer:nil];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    [[QueueManager sharedInstance] syncQueue:nil];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationDidFinishLaunching:(NSNotification*)aNotification
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:OPEN_STATS_WINDOW_AT_LAUNCH]) {
        [self openStatistics:nil];
    }
}

- (void)updateMenu
{
    NSMenuItem *item;
    NSEnumerator *enumerator = [[theMenu itemArray] objectEnumerator];
    SongData *song;
    // ScrobTrace(@"updating menu");
	
    // remove songs from menu
    while(item=[enumerator nextObject])
        if([item action]==@selector(playSong:))
            [theMenu removeItem:item];
    
    // add songs from songList array to menu
    enumerator=[songList reverseObjectEnumerator];
    while ((song = [enumerator nextObject]))
    {
        //ScrobTrace(@"Corrupted song:\n%@",song);
        item = [[[NSMenuItem alloc] initWithTitle:[song title]
                                           action:@selector(playSong:)
                                    keyEquivalent:@""] autorelease];
        
        [item setTarget:self];
        [theMenu insertItem:item atIndex:0];
		//    ScrobTrace(@"added item to menu");
    }
}

// Caller must release
- (SongData*)createSong:(NSArray*)data
{
    if (10 != [data count]) {
        ScrobLog(SCROB_LOG_WARN, @"Bad song data received.\n");
        ScrobTrace("%@\n", data);
        return (nil);
    }
    
    SongData * song = [[SongData alloc] init];
    [song setTrackIndex:[NSNumber numberWithFloat:[[data objectAtIndex:0]
        floatValue]]];
    [song setPlaylistIndex:[NSNumber numberWithFloat:[[data objectAtIndex:1]
        floatValue]]];
    [song setTitle:[data objectAtIndex:2]];
    [song setDuration:[NSNumber numberWithFloat:[[data objectAtIndex:3] floatValue]]];
    [song setPosition:[NSNumber numberWithFloat:[[data objectAtIndex:4] floatValue]]];
    [song setArtist:[data objectAtIndex:5]];
    [song setAlbum:[data objectAtIndex:6]];
    [song setPath:[data objectAtIndex:7]];
    [song setLastPlayed:[NSDate dateWithNaturalLanguageString:[data objectAtIndex:8]
        locale:[[NSUserDefaults standardUserDefaults] dictionaryRepresentation]]];
    [song setRating:[NSNumber numberWithInt:[[data objectAtIndex:9] intValue]]];
    
    [song setStartTime:[NSDate dateWithTimeIntervalSinceNow:-[[song position] doubleValue]]];
    //ScrobTrace(@"SongData allocated and filled");
    return (song);
}

-(void)mainTimer:(NSTimer *)timer
{
    // micah_modell@users.sourceforge.net
    // Check for null and branch to avoid having the application hang.
    NSAppleEventDescriptor * executionResult = [ script executeAndReturnError: nil ] ;
    
    if( nil != executionResult )
    {
        NSString *result=[[NSString alloc] initWithString:[ executionResult stringValue]];
        SongData *nowPlaying = nil;
        
    //ScrobTrace(@"timer fired");
    //ScrobTrace(@"%@",result);
    
    // If the script didn't return an error, continue
    if([result hasPrefix:@"NOT PLAYING"]) {
		
    } else if([result hasPrefix:@"RADIO"]) {
		
    } else if([result hasPrefix:@"INACTIVE"]) {
        
    } else {
        // Parse the result and create an array
        NSArray *parsedResult = [[NSArray alloc] initWithArray:[result componentsSeparatedByString:@"***"]];
		NSDate *now;
        
        // Make a SongData object out of the array
        SongData *song = [self createSong:parsedResult];
        [parsedResult release];
        
        if (NO == [prefs boolForKey:@"Shared Music Submission"] &&
             [[song path] isEqualToString:@"Shared Track"]) {
            [song release];
            goto mainTimerReleaseResult;
        }
        
        // iPod sync date management, the goal is to detect the valid songs to sync
		now = [NSDate date];
        // XXX We need to do something fancy here, because this assumes
        // the user will sync the iPod before playing anything in iTunes.
        [self setITunesLastPlayedTime:now];
        
        // If the songlist is empty, then simply add the song object to the songlist
        if([songList count]==0)
        {
            ScrobLog(SCROB_LOG_VERBOSE, @"adding first item");
            [songList insertObject:song atIndex:0];
            nowPlaying = song;
        }
        else
        {
            SongData *firstSongInList = [songList objectAtIndex:0];
            // Is the track equal to the track that's
            // currently in first place in the song list? If so, update the
            // play time, and queue a submission.
            if ([song isEqualToSong:firstSongInList]) {
                // Determine if the song is being played twice (or more in a row)
                float pos = [[song position] floatValue];
                nowPlaying = firstSongInList;
                
                if (pos <  [[firstSongInList position] floatValue] &&
                     (pos <= [SongData songTimeFudge]) &&
                     // Could be a new play, or they could have seek'd back in time. Make sure it's not the latter.
                     (([[firstSongInList duration] floatValue] - [[firstSongInList position] floatValue])
                     <= [SongData songTimeFudge]) ) {
                    [songList insertObject:song atIndex:0];
                    nowPlaying = song;
                } else {
                    [firstSongInList setPosition:[song position]];
                    [firstSongInList setLastPlayed:[song lastPlayed]];
                    [firstSongInList setRating:[song rating]];
                    [[QueueManager sharedInstance] queueSong:firstSongInList];
                }
            } else {
                // Check to see if the current track is anywhere in the songlist
                // If it is, we set found equal to the index position where it was found
                // ScrobTrace(@"Looking for track");
                int j;
                int found = 0;
                for(j = 0; j < [songList count]; j++) {
                    if([[songList objectAtIndex:j] isEqualToSong:song])
                    {
                        found = j;
                        break;
                    }
                }
                //ScrobTrace(@"Found = %i",j);
				
                // If the track wasn't found anywhere in the list, we add a new item
                if(!found)
                {
                    ScrobLog(SCROB_LOG_VERBOSE, @"adding new item");
                    [songList insertObject:song atIndex:0];
                }
                // If the trackname was found elsewhere in the list, we remove the old
                // item, and add the new one onto the beginning of the list.
                else
                {
                    //ScrobTrace(@"removing old, adding new");
                    [songList removeObjectAtIndex:found];
                    [songList insertObject:song atIndex:0];
                }
                
                nowPlaying = song;
            }
        }
        // If there are more items in the list than the user wanted
        // Then we remove the last item in the songlist
        while([songList count]>[prefs integerForKey:@"Number of Songs to Save"]) {
            //ScrobTrace(@"Removed an item from songList");
            [songList removeObject:[songList lastObject]];
        }
		
        [self updateMenu];
        [song release];
    }
    
mainTimerReleaseResult:

    [[NSNotificationCenter defaultCenter] postNotificationName:@"Now Playing"
        object:nowPlaying userInfo:nil];

    [result release];
    //ScrobTrace(@"result released");
    }
}

- (void)iTunesPlaylistUpdate:(NSTimer*)timer
{
    static NSAppleScript *iTunesPlaylistScript = nil;
    
    if (!iTunesPlaylistScript) {
        NSURL *file = [NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath]
                    stringByAppendingPathComponent:@"Scripts/iTunesGetPlaylists.scpt"]];
        iTunesPlaylistScript = [[NSAppleScript alloc] initWithContentsOfURL:file error:nil];
        if (!iTunesPlaylistScript) {
            ScrobLog(SCROB_LOG_CRIT, @"Could not load iTunesGetPlaylists.scpt!\n");
            [self showApplicationIsDamagedDialog];
        }
    }
    
    NSAppleEventDescriptor *executionResult = [iTunesPlaylistScript executeAndReturnError:nil];
    if(executionResult ) {
        NSArray *parsedResult = [[executionResult stringValue] componentsSeparatedByString:@"$$$"];
        NSEnumerator *en = [parsedResult objectEnumerator];
        NSString *playlist;
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:[parsedResult count]];
        
        while ((playlist = [en nextObject])) {
            NSArray *properties = [playlist componentsSeparatedByString:@"***"];
            NSString *name = [properties objectAtIndex:0];
            
            if (name && [name length] > 0)
                [names addObject:name];
        }
        
        if ([names count]) {
            [self setValue:[names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]
                forKey:@"iTunesPlaylists"];
        }
    }
}

-(IBAction)playSong:(id)sender{
    SongData *songInfo;
    NSString *scriptText;
    NSAppleScript *play;
    int index=[[sender menu] indexOfItem:sender];
	
    songInfo = [songList objectAtIndex:index];
	
	
    scriptText=[NSString stringWithFormat: @"tell application \"iTunes\" to play track %d of playlist %d",[[songInfo trackIndex] intValue],[[songInfo playlistIndex] intValue]];
	
    play=[[NSAppleScript alloc] initWithSource:scriptText];
	
    [play executeAndReturnError:nil];
    
    [play release];
    [self mainTimer:nil];
}

-(IBAction)clearMenu:(id)sender{
    NSMenuItem *item;
    NSEnumerator *enumerator = [[theMenu itemArray] objectEnumerator];
	
	ScrobTrace(@"clearing menu");
    [songList removeAllObjects];
    
	while(item=[enumerator nextObject])
        if([item action]==@selector(playSong:))
            [theMenu removeItem:item];
	
	[self mainTimer:nil];
}

-(IBAction)openPrefs:(id)sender{
    // ScrobTrace(@"opening prefs");
    if(!preferenceController)
        preferenceController=[[PreferenceController alloc] init];
	
    [NSApp activateIgnoringOtherApps:YES];
    [preferenceController showPreferencesWindow];
}

-(IBAction)openScrobblerHomepage:(id)sender
{
    NSURL *url = [NSURL URLWithString:@"http://www.audioscrobbler.com"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (IBAction)openiScrobblerDownloadPage:(id)sender {
	//NSLog(@"openiScrobblerDownloadPage");
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://www.audioscrobbler.com/download.php"]];
}

-(IBAction)openUserHomepage:(id)sender
{
    NSString *prefix = @"http://www.audioscrobbler.com/user/";
    NSURL *url = [NSURL URLWithString:[prefix stringByAppendingString:[prefs stringForKey:@"username"]]];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

-(IBAction)openStatistics:(id)sender
{
    [[StatisticsController sharedInstance] showWindow:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

-(void) handlePrefsChanged:(NSNotification *)aNotification
{
    // Song Count
    while([songList count]>[prefs integerForKey:@"Number of Songs to Save"])
        [songList removeObject:[songList lastObject]];
    [self updateMenu];

// We don't have a UI to control this pref because it would cause support nightmares
// with noobs enabling it w/o actually knowing what it does. If a UI is ever added,
// enable the following code block.
#ifdef notyet
    // Status menu
    [self enableStatusItemMenu:
        [[NSUserDefaults standardUserDefaults] boolForKey:@"Display Control Menu"]];
#endif
}

-(void)dealloc{
	[nc removeObserver:self];
	[nc release];
	[statusItem release];
	[songList release];
	[script release];
	[mainTimer invalidate];
	[mainTimer release];
	[prefs release];
	[preferenceController release];
	[super dealloc];
}

- (NSString *)md5hash:(NSString *)input
{
	unsigned char *hash = MD5([input cString], [input cStringLength], NULL);
	int i;
    
	NSMutableString *hashString = [NSMutableString string];
	
    // Convert the binary hash into a string
    for (i = 0; i < MD5_DIGEST_LENGTH; i++) {
		//ScrobTrace(@"Appending %X to hashString (currently %@)", *hash, hashString);
		[hashString appendFormat:@"%02x", *hash++];
	}
	
    //ScrobTrace(@"Returning hash... %@ for input: %@", hashString, input);
    return hashString;
}

-(IBAction)cleanLog:(id)sender
{
    ScrobLogTruncate();
}

- (void)showBadCredentialsDialog
{	
	[NSApp activateIgnoringOtherApps:YES];
	
	// we should give them the option to ignore
	// these messages, and only update the menu icon... -- ECS 10/30/04
	int result = NSRunAlertPanel(NSLocalizedString(@"Authentication Failure", nil),
								NSLocalizedString(@"Audioscrobbler.com did not accept your username and password.  Please update your user credentials in the iScrobbler preferences.", nil),
								NSLocalizedString(@"Open iScrobbler Preferences", nil),
								NSLocalizedString(@"New Account", nil),
								nil); // NSLocalizedString(@"Ignore", nil)
	
	if (result == NSAlertDefaultReturn)
		[self openPrefs:self];
	else if (result == NSAlertAlternateReturn)
		[self openScrobblerHomepage:self];
	//else
	//	ignoreBadCredentials = YES;
}

- (void)showNewVersionExistsDialog
{
	if (!haveShownUpdateNowDialog) {
		[NSApp activateIgnoringOtherApps:YES];
		int result = NSRunAlertPanel(NSLocalizedString(@"New Plugin Available", nil),
									 NSLocalizedString(@"A new version (%@) of the iScrobbler iTunes plugin is now available.  It strongly suggested you update to the latest version.", nil),
									 NSLocalizedString(@"Open Download Page", nil),
									 NSLocalizedString(@"Ignore", nil),
									 nil); // NSLocalizedString(@"Ignore", nil)
		if (result == NSAlertDefaultReturn)
			[self openiScrobblerDownloadPage:self];
		
		haveShownUpdateNowDialog = YES;
	}
}

- (void)showApplicationIsDamagedDialog
{
	[NSApp activateIgnoringOtherApps:YES];
	int result = NSRunCriticalAlertPanel(NSLocalizedString(@"Critical Error", nil),
										 NSLocalizedString(@"The iScrobbler application appears to be damaged.  Please download a new copy from the iScrobbler homepage.", nil),
										 NSLocalizedString(@"Quit", nil),
										 NSLocalizedString(@"Open iScrobbler Homepage", nil), nil);
	if (result == NSAlertAlternateReturn)
		[self openScrobblerHomepage:self];
	
	[NSApp terminate:self];
}

#define ONE_WEEK (3600.0 * 24.0 * 7.0)
- (void) restoreITunesLastPlayedTime
{
    NSTimeInterval ti = [[prefs stringForKey:@"iTunesLastPlayedTime"] doubleValue];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSDate *tr = [NSDate dateWithTimeIntervalSince1970:ti];

    if (!ti || ti > (now + MAIN_TIMER_INTERVAL) || ti < (now - ONE_WEEK)) {
        ScrobLog(SCROB_LOG_WARN, @"Discarding invalid iTunesLastPlayedTime value (ti=%.0lf, now=%.0lf).\n",
            ti, now);
        tr = [NSDate date];
    }
    
    [self setITunesLastPlayedTime:tr];
}

- (void) setITunesLastPlayedTime:(NSDate*)date
{
    [date retain];
    [iTunesLastPlayedTime release];
    iTunesLastPlayedTime = date;
    // Update prefs
    [prefs setObject:[NSString stringWithFormat:@"%.2lf", [iTunesLastPlayedTime timeIntervalSince1970]]
        forKey:@"iTunesLastPlayedTime"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/*
Validate all of the post dates. We do this, because there seems
to be a iTunes bug that royally screws up last played times during daylight
savings changes.

Scenario: Unplug iPod on 10/30, play a lot of songs, then sync the next day (10/31 - after 0200)
and some of the last played dates will be very bad.
*/
- (NSMutableArray*)validateIPodSync:(NSArray*)songs
{
    NSMutableArray *sorted = [[songs sortedArrayUsingSelector:@selector(compareSongPostDate:)] mutableCopy];
    int i;
    
validate:
    for (i = 1; i < [sorted count]; ++i) {
        SongData *thisSong = [sorted objectAtIndex:i];
        SongData *lastSong = [sorted objectAtIndex:i-1];
        NSTimeInterval thisPost = [[thisSong postDate] timeIntervalSince1970];
        NSTimeInterval lastPost = [[lastSong postDate] timeIntervalSince1970];
        
        if ((lastPost + [[lastSong duration] doubleValue]) > thisPost) {
            ScrobLog(SCROB_LOG_WARN, @"iPodSync: Discarding '%@' because of invalid play time.\n\t'%@' = Start: %@, Duration: %@"
                "\n\t'%@' = Start: %@, Duration: %@\n", [thisSong brief], [lastSong brief], [lastSong postDate], [lastSong duration],
                [thisSong brief], [thisSong postDate], [thisSong duration]);
            [sorted removeObjectAtIndex:i];
            goto validate;
        }
    }
    
    return ([sorted autorelease]);
}

//#define IPOD_UPDATE_SCRIPT_DATE_FMT @"%A, %B %d, %Y %I:%M:%S %p"
#define IPOD_UPDATE_SCRIPT_DATE_TOKEN @"Thursday, January 1, 1970 12:00:00 AM"
#define IPOD_UPDATE_SCRIPT_SONG_TOKEN @"$$$"
#define IPOD_UPDATE_SCRIPT_DEFAULT_PLAYLIST @"Recently Played"

- (void)syncIPod:(id)sender
{
    ScrobTrace (@"syncIpod: called: script=%p, sync pref=%i\n", iPodUpdateScript, [prefs boolForKey:@"Sync iPod"]);
    
    if (iPodUpdateScript && [prefs boolForKey:@"Sync iPod"]) {
        // Copy the script
        NSMutableString *text = [iPodUpdateScript mutableCopy];
        NSAppleScript *iuscript;
        NSAppleEventDescriptor *result;
        NSDictionary *errInfo, *localeInfo;
        NSTimeInterval now, fudge;
        unsigned int added;
        
        // Our main timer loop is only fired every 10 seconds, so we have to
        // make sure to adjust our time
        fudge = [iTunesLastPlayedTime timeIntervalSince1970]+MAIN_TIMER_INTERVAL;
        now = [[NSDate date] timeIntervalSince1970];
        if (now > fudge) {
            [self setITunesLastPlayedTime:[NSDate dateWithTimeIntervalSince1970:fudge]];
        } else {
            [self setITunesLastPlayedTime:[NSDate date]];
        }
        
        // AppleScript expects the date string formated according to the users's system settings
        localeInfo = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
        
        // Replace the date token with our last update
        [text replaceOccurrencesOfString:IPOD_UPDATE_SCRIPT_DATE_TOKEN
            withString:[iTunesLastPlayedTime descriptionWithCalendarFormat:
                [localeInfo objectForKey:NSTimeDateFormatString] timeZone:nil locale:localeInfo]
            options:0 range:NSMakeRange(0, [text length])];
        
        // Replace the default playlist with the user's choice
        [text replaceOccurrencesOfString:IPOD_UPDATE_SCRIPT_DEFAULT_PLAYLIST
            withString:[prefs stringForKey:@"iPod Submission Playlist"]
            options:0 range:NSMakeRange(0, [text length])];
        
        ScrobLog(SCROB_LOG_VERBOSE, @"syncIPod: Requesting songs played after '%@'\n",
            [iTunesLastPlayedTime descriptionWithCalendarFormat:[localeInfo objectForKey:NSTimeDateFormatString]
                timeZone:nil locale:localeInfo]);
        // Run script
        iuscript = [[NSAppleScript alloc] initWithSource:text];
        if ((result = [iuscript executeAndReturnError:&errInfo])) {
            if (![[result stringValue] hasPrefix:@"INACTIVE"]) {
                NSArray *songs = [[result stringValue]
                    componentsSeparatedByString:IPOD_UPDATE_SCRIPT_SONG_TOKEN];
                NSEnumerator *en = [songs objectEnumerator];
                NSString *data;
                SongData *song;
                NSMutableArray *iqueue = [NSMutableArray array];
                
                if ([[result stringValue] hasPrefix:@"ERROR"]) {
                    NSString *errmsg, *errnum;
                NS_DURING
                    errmsg = [songs objectAtIndex:1];
                    errnum = [songs objectAtIndex:2];
                NS_HANDLER
                    errmsg = errnum = @"UNKNOWN";
                NS_ENDHANDLER
                    // Display dialog instead of logging?
                    ScrobLog(SCROB_LOG_ERR, @"syncIPod: iPodUpdateScript returned error: \"%@\" (%@)\n",
                        errmsg, errnum);
                    goto sync_ipod_script_release;
                }
                
                added = 0;
                while ((data = [en nextObject])) {
                    NSArray *components = [data componentsSeparatedByString:@"***"];
                    NSTimeInterval postDate;
                    
                    if ([components count] > 1) {
                        ScrobLog(SCROB_LOG_TRACE, @"syncIPod: Song components from script: %@\n", components);
                        
                        song = [self createSong:components];
                        // Since this song was played "offline", we set the post date
                        // in the past 
                        postDate = [[song lastPlayed] timeIntervalSince1970] - [[song duration] doubleValue];
                        [song setPostDate:[NSCalendarDate dateWithTimeIntervalSince1970:postDate]];
                        // Make sure the song passes submission rules                            
                        [song setStartTime:[NSDate dateWithTimeIntervalSince1970:postDate]];
                        [song setPosition:[song duration]];
                        
                        [iqueue addObject:song];
                        [song release];
                    }
                }
                
                iqueue = [self validateIPodSync:iqueue];
                
                en = [iqueue objectEnumerator];
                while ((song = [en nextObject])) {
                    if (![[song postDate] isGreaterThan:iTunesLastPlayedTime]) {
                        ScrobLog(SCROB_LOG_WARN,
                            @"Anachronistic post date for song '%@'. Discarding -- possible date parse error.\n\t"
                            "Post Date: %@, Last Played: %@, Duration: %.0lf, iTunesLastPlayed: %@.\n",
                            [song brief], [song postDate], [song lastPlayed], [[song duration] doubleValue],
                            iTunesLastPlayedTime);
                        continue;
                    }
                    ScrobLog(SCROB_LOG_VERBOSE, @"syncIPod: Queuing '%@' with postDate '%@'\n", [song brief], [song postDate]);
                    [[QueueManager sharedInstance] queueSong:song submit:NO];
                    ++added;
                }
                
                [self setITunesLastPlayedTime:[NSDate date]];
                if (added > 0) {
                    [[QueueManager sharedInstance] submit];
                }
            }
        } else if (!result) {
            // Script error
            ScrobLog(SCROB_LOG_ERR, @"iPodUpdateScript execution error: %@\n", errInfo);
        }
        
sync_ipod_script_release:
        [iuscript release];
        [text release];
    } else {
        ScrobLog(SCROB_LOG_CRIT, @"iPodUpdateScript missing\n");
    }
}

// NSWorkSpace mount notifications
- (void)volumeDidMount:(NSNotification*)notification
{
    NSDictionary *info = [notification userInfo];
	NSString *mountPath = [info objectForKey:@"NSDevicePath"];
    NSString *iPodControlPath = [mountPath stringByAppendingPathComponent:@"iPod_Control"];
	
    ScrobTrace(@"Volume mounted: %@", info);
    
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:iPodControlPath isDirectory:&isDir] && isDir) {
        [self setValue:mountPath forKey:@"iPodMountPath"];
        [self setValue:[NSNumber numberWithBool:YES] forKey:@"isIPodMounted"];
    }
}

- (void)volumeDidUnmount:(NSNotification*)notification
{
    NSDictionary *info = [notification userInfo];
	NSString *mountPath = [info objectForKey:@"NSDevicePath"];
	
    ScrobTrace(@"Volume unmounted: %@.\n", info);
    
    if ([iPodMountPath isEqualToString:mountPath]) {
        [self syncIPod:nil]; // now that we're sure iTunes synced, we can sync...
        [self setValue:nil forKey:@"iPodMountPath"];
        [self setValue:[NSNumber numberWithBool:NO] forKey:@"isIPodMounted"];
    }
}

@end
