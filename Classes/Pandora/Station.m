#import <AudioStreamer/AudioStreamer.h>

#import "HermesAppDelegate.h"
#import "Pandora/Station.h"
#import "PreferencesController.h"
#import "StationsController.h"

@implementation Station

@synthesize stationId, name, playing, token;

- (id) init {
  songs = [NSMutableArray arrayWithCapacity:10];

  /* Watch for error notifications */
  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(playbackStateChanged:)
    name:ASStatusChangedNotification
    object:nil];

  return self;
}

- (id) initWithCoder:(NSCoder *)aDecoder {
  if ((self = [self init])) {
    [self setStationId:[aDecoder decodeObjectForKey:@"stationId"]];
    [self setName:[aDecoder decodeObjectForKey:@"name"]];
    [self setPlaying:[aDecoder decodeObjectForKey:@"playing"]];
    lastKnownSeekTime = [aDecoder decodeFloatForKey:@"lastKnownSeekTime"];
    [songs addObjectsFromArray:[aDecoder decodeObjectForKey:@"songs"]];
  }
  return self;
}

- (void) encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:stationId forKey:@"stationId"];
  [aCoder encodeObject:name forKey:@"name"];
  [aCoder encodeObject:playing forKey:@"playing"];
  float seek = -1;
  if (playing) {
    seek = [stream progress];
  }
  [aCoder encodeFloat:seek forKey:@"lastKnownSeekTime"];
  [aCoder encodeObject:songs forKey:@"songs"];
}

- (void) stopObserving {
  if (radio != nil) {
    [[NSNotificationCenter defaultCenter]
     removeObserver:self
     name:nil
     object:radio];
  }
}

- (void) dealloc {
  [self stop];

  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL) isEqual:(id)object {
  return [stationId isEqual:[object stationId]];
}

- (void) setRadio:(Pandora *)pandora {
  [self stopObserving];
  radio = pandora;

  NSString *n = [NSString stringWithFormat:@"hermes.fragment-fetched.%@",
      token];

  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(songsLoaded:)
    name:n
    object:pandora];
}

- (void) songsLoaded: (NSNotification*)not {
  NSArray *more = [[not userInfo] objectForKey:@"songs"];

  if (more != nil) {
    [songs addObjectsFromArray: more];
  }

  if (shouldPlaySongOnFetch) {
    shouldPlaySongOnFetch = NO;
    [self play];
  }

  [[NSNotificationCenter defaultCenter]
    postNotificationName:@"songs.loaded" object:self];
}

- (void) clearSongList {
  [songs removeAllObjects];
}

- (void) fetchMoreSongs {
  [radio getFragment: self];
}

- (void) fetchSongsIfNecessary {
  if ([songs count] <= 1) {
    [self fetchMoreSongs];
  }
}

- (void) setAudioStream {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSURL *url;

  NSLogd(@"%ld", [defaults integerForKey:DESIRED_QUALITY]);

  switch ([defaults integerForKey:DESIRED_QUALITY]) {
    case QUALITY_HIGH:
      NSLogd(@"quality high");
      url = [NSURL URLWithString:[playing highUrl]];
      break;
    case QUALITY_LOW:
      NSLogd(@"quality low");
      url = [NSURL URLWithString:[playing lowUrl]];
      break;

    case QUALITY_MED:
    default:
      NSLogd(@"quality med");
      url = [NSURL URLWithString:[playing medUrl]];
      break;
  }
  assert(url != nil);
  stream = [[AudioStreamer alloc] initWithURL: url];
}

- (void) seekToLastKnownTime {
  retrying = NO;
  if (lastKnownSeekTime != 0) {
    [stream seekToTime:lastKnownSeekTime];
  }
}

- (void)playbackStateChanged: (NSNotification *)aNotification {
  [waitingTimeout invalidate];
  waitingTimeout = nil;

  int code = [stream errorCode];
  if (code != 0) {
    /* If we've hit an error, then we want to record out current progress into
       the song. Only do this if we're not in the process of retrying to
       establish a connection, so that way we don't blow away the original
       progress from when the error first happened */
    if (!retrying) {
      lastKnownSeekTime = [stream progress];
    }

    /* If the network connection just outright failed, then we shouldn't be
       retrying with a new auth token because it will never work for that
       reason. Most likely this is some network trouble and we should have the
       opportunity to hit a button to retry this specific connection so we can
       at least hope to regain our current place in the song */
    if (code == AS_NETWORK_CONNECTION_FAILED) {
      NSLogd(@"network error: %@", [stream networkError]);
      [[NSNotificationCenter defaultCenter]
        postNotificationName:@"hermes.stream-error" object:self];

    /* Otherwise, this might be because our authentication token is invalid, but
       just in case, retry the current song automatically a few times before we
       finally give up and clear our cache of songs (see below) */
    } else {
      NSLogd(@"Error on playback stream! count:%lu, Retrying...", tries);
      NSLogd(@"error: %@", [AudioStreamer stringForErrorCode:code]);
      [self retry:TRUE];
    }

  /* If we were already retrying things, then we'll get a notification as soon
     as the stream has enough packets to calculate the bit rate. This means that
     we can correctly seek into the song. After we seek, we've successfully
     re-synced the stream with what it was before the error happened */
  } else if (retrying && [stream calculatedBitRate] != 0) {
    [self seekToLastKnownTime];
  } else {
    [self checkForIndefiniteBuffering];
  }
}

- (void) retry:(BOOL)countTries {
  if (countTries) {
    if (tries > 2) {
      NSLogd(@"Retried too many times, just nexting...");
      /* If we retried a bunch and it didn't work, the most likely cause is that
         the listed URL for the song has since expired. This probably also means
         that anything else in the queue (fetched at the same time) is also
         invalid, so empty the entire thing and have next fetch some more */
      [songs removeAllObjects];
      [self next];
      return;
    }
    tries++;
  }

  retrying = YES;

  [self setAudioStream];
  [stream start];
}

- (void) retryWithCount {
  [self retry:YES];
}

/**
 * @brief Ensure that the stream doesn't indefinitely stay in the 'buffering'
 *        state.
 *
 * Occasionally the AudioStreamer stream will enter a buffering state, and then
 * refuse to ever get back out of the buffering state. For this reason, when
 * this happens, give it a grace period before completely re-opening the
 * connection with the stream by retrying the connection.
 */
- (void) checkForIndefiniteBuffering {
  if ([stream state] == AS_BUFFERING) {
    waitingTimeout =
      [NSTimer scheduledTimerWithTimeInterval:0.3
                                       target:self
                                     selector:@selector(retryWithCount)
                                     userInfo:nil
                                      repeats:NO];
    lastKnownSeekTime = [stream progress];
    NSLogd(@"waiting for more data, will retry again soon...");
  }
}

- (void) play {
  NSLogd(@"Playing %@", name);
  if (stream) {
    [stream play];
    return;
  }

  if ([songs count] == 0) {
    NSLogd(@"no songs, fetching some more");
    shouldPlaySongOnFetch = YES;
    [self fetchMoreSongs];
    return;
  }

  playing = [songs objectAtIndex:0];
  [songs removeObjectAtIndex:0];

  [self setAudioStream];
  tries = 0;
  [stream start];

  [[NSNotificationCenter defaultCenter]
    postNotificationName:@"song.playing" object:self];

  [self fetchSongsIfNecessary];
}

- (void) pause {
  if (stream != nil) {
    [stream pause];
  }
}

- (BOOL) isPaused {
  return stream != nil && [stream isPaused];
}

- (BOOL) isPlaying {
  return stream != nil && [stream isPlaying];
}

- (BOOL) isIdle {
  return stream == nil || [stream isIdle];
}

- (double) progress {
  return [stream progress];
}

- (double) duration {
  return [stream duration];
}

- (void) next {
  lastKnownSeekTime = 0;
  if (playing == nil) {
    [songs removeObjectAtIndex:0];
    retrying = NO;
  } else {
    [self stop];
  }
  [self play];
}

- (void) stop {
  if (!stream || !playing) {
    return;
  }

  [stream stop];
  stream = nil;
  playing = nil;
}

- (NSError*) streamNetworkError {
  return [stream networkError];
}

- (void) setVolume:(double)volume {
  [stream setVolume:volume];
}

- (void) copyFrom: (Station*) other {
  [songs removeAllObjects];
  /* Add the previously playing song to the front of the queue if
     there was one */
  if ([other playing] != nil) {
    [songs addObject:[other playing]];
  }
  [songs addObjectsFromArray:other->songs];
  lastKnownSeekTime = other->lastKnownSeekTime;
  NSLogd(@"lastknown: %f", lastKnownSeekTime);
  if (lastKnownSeekTime > 0) {
    retrying = YES;
  }
}

- (NSScriptObjectSpecifier *) objectSpecifier {
  HermesAppDelegate *delegate = [NSApp delegate];
  StationsController *stationsc = [delegate stations];
  int index = [stationsc stationIndex:self];

  NSScriptClassDescription *containerClassDesc =
      [NSScriptClassDescription classDescriptionForClass:[NSApp class]];

  return [[NSIndexSpecifier alloc]
           initWithContainerClassDescription:containerClassDesc
           containerSpecifier:nil key:@"stations" index:index];
}

@end
