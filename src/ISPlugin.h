//
//  ISPlugin.h
//  iScrobbler
//
//  Created by Brian Bergstrand on 10/1/2007.
//  Copyright 2007,2008 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//


@protocol ISPluginProxy

- (NSBundle*)applicationBundle;
- (NSString*)applicationVersion;
- (NSString*)nowPlayingNotificationName;

- (void)addMenuItem:(NSMenuItem*)item;

@end

@protocol ISPlugin

- (id)initWithAppProxy:(id<ISPluginProxy>)proxy;
- (NSString*)description;
- (void)applicationWillTerminate;

@end
