//
//  SongData.h
//  iScrobbler
//
//  Created by Sam Ley on Thu Mar 20 2003.
//  Copyright (c) 2003 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SongData : NSObject {
    NSNumber * trackIndex;
    NSNumber * playlistIndex;
    NSString * title;
    NSNumber * duration;
    NSNumber * position;
    NSString * artist;
    NSString * path;
    NSDate * startTime;
    BOOL hasQueued;
    NSNumber * pausedTime;
}

// returns a float value between 0 and 100 indicating how much of the song
// has been played as a percent
- (NSNumber *)percentPlayed;

// returns the amount of time, in seconds, that the song has been playing.
- (NSNumber *)timePlayed;

// returns an NSMutableDictionary object that is packaged and ready for submission.
// postDict adds URL escaped title, artist and filename, and duration and time of
// submission field.
// The receiver is still responsible for adding the username, password and version
// fields to the dict.
- (NSMutableDictionary *)postDict;

////// Accessors Galore ///////

// trackIndex is the number corresponding to the track within the playlist
- (NSNumber *)trackIndex;
- (void)setTrackIndex:(NSNumber *)newTrackIndex;

// playlistIndex is the number corresponding to the playlist the track is in
- (NSNumber *)playlistIndex;
- (void)setPlaylistIndex:(NSNumber *)newPlaylistIndex;

// title is the title of the song
- (NSString *)title;
- (void)setTitle:(NSString *)newTitle;

// duration is the length of the song in seconds
- (NSNumber *)duration;
- (void)setDuration:(NSNumber *)newDuration;

// position is the current track position within the song
- (NSNumber *)position;
- (void)setPosition:(NSNumber *)newPosition;

// artist is the artist of the track
- (NSString *)artist;
- (void)setArtist:(NSString *)newArtist;

// path is the filesystem path of the track
- (NSString *)path;
- (void)setPath:(NSString *)newPath;

// startTime is the system time at which the track began playing
- (NSDate *)startTime;
- (void)setStartTime:(NSDate *)newStartTime;

// hasQueued is a bool value indicating whether the song has been queued or not
- (BOOL)hasQueued;
- (void)setHasQueued:(BOOL)newHasQueued;

// pausedTime is the total length of time the song has been paused for
- (NSNumber *)pausedTime;
- (void)setPausedTime:(NSNumber *)newPausedTime;


@end
