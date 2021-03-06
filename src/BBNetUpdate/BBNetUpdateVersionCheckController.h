/*
* Copyright 2002,2007-2009 Brian Bergstrand.
*
* Redistribution and use in source and binary forms, with or without modification, 
* are permitted provided that the following conditions are met:
*
* 1.	Redistributions of source code must retain the above copyright notice, this list of
*     conditions and the following disclaimer.
* 2.	Redistributions in binary form must reproduce the above copyright notice, this list of
*     conditions and the following disclaimer in the documentation and/or other materials provided
*     with the distribution.
* 3.	The name of the author may not be used to endorse or promote products derived from this
*     software without specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
* WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
* AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE
* FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
* OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
* CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
* THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*/

#import <Cocoa/Cocoa.h>

@interface BBNetUpdateVersionCheckController : NSWindowController {
    IBOutlet id boxDontCheck;
    IBOutlet id buttonDownload;
    IBOutlet id fieldMoreInfo;
    IBOutlet id fieldText;
    IBOutlet id fieldTitle;
    IBOutlet id progressBar;
    
    NSURLConnection *connection;
    NSMutableData *verData;
    NSDictionary *verInfo;
    NSString *bundleName;
    BOOL checkingVersion, _interact, _didDownload, installSelf, appDataOnly;
}

// 'appName' can (and probably should) be nil. If it is, the app bundle will be queried
// for it's name.
+ (void)checkForNewVersion:(NSString*)appName interact:(BOOL)interact;
+ (BOOL)isCheckInProgress;
// Will return nil if a check has never been performed.
+ (NSDate*)lastCheck;
+ (NSString*)userAgent;

- (IBAction)download:(id)sender;

// This is an alternative to [checkForNewVersion:interact:].
// It performs the same as the latter, except the version data is ignored.
// Instead it simply passes on any new application data via the BBNetUpdateHasApplicationData notification
+ (void)checkForApplicationData;

@end

// Update notifications
__private_extern__ NSString* const BBNetUpdateDidFinishUpdateCheck;
__private_extern__ NSString* const BBNetUpdateWillInstallUpdateAndRelaunch;
// App specific data - not interpreted by the updater.
__private_extern__ NSString* const BBNetUpdateHasApplicationData;
