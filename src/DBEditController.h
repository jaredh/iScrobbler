//
//  DBEditController.h
//  iScrobbler
//
//  Created by Brian Bergstrand on 1/05/08.
//  Copyright 2008-2009 Brian Bergstrand.
//
//  Released under the GPL, license details available in res/gpl.txt
//

#import <Cocoa/Cocoa.h>

@interface DBEditController : NSWindowController
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
<NSWindowDelegate>
#endif
{
    IBOutlet NSView *contentView;
    IBOutlet NSProgressIndicator *progress;
    
    NSManagedObjectContext *moc;
    NSManagedObjectID *moid;
    BOOL isBusy;
}

- (void)setObject:(NSDictionary*)objectInfo;

- (IBAction)performClose:(id)sender;

@end

@interface DBRenameController : DBEditController {
    IBOutlet NSTextField *renameText;
}

- (IBAction)performRename:(id)sender;

@end

@interface DBRemoveController : DBEditController {
    IBOutlet NSArrayController *playEvents;
    
    NSMutableArray *playEventsContent;
    NSMutableDictionary *playEventBeingRemoved;
}

- (IBAction)performRemove:(id)sender;

@end

@interface DBAddHistoryController : DBEditController {
    IBOutlet NSTextField *dateText;
}

- (IBAction)performAdd:(id)sender;

@end
