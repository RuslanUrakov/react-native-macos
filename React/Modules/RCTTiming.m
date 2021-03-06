/**
 * Copyright (c) 2015-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTTiming.h"

#import "RCTAssert.h"
#import "RCTBridge+Private.h"
#import "RCTBridge.h"
#import "RCTLog.h"
#import "RCTUtils.h"

static const NSTimeInterval kMinimumSleepInterval = 1;

// These timing contants should be kept in sync with the ones in `JSTimers.js`.
// The duration of a frame. This assumes that we want to run at 60 fps.
static const NSTimeInterval kFrameDuration = 1.0 / 60.0;
// The minimum time left in a frame to trigger the idle callback.
static const NSTimeInterval kIdleCallbackFrameDeadline = 0.001;

@interface _RCTTimer : NSObject

@property (nonatomic, strong, readonly) NSDate *target;
@property (nonatomic, assign, readonly) BOOL repeats;
@property (nonatomic, copy, readonly) NSNumber *callbackID;
@property (nonatomic, assign, readonly) NSTimeInterval interval;

@end

@implementation _RCTTimer

- (instancetype)initWithCallbackID:(NSNumber *)callbackID
                          interval:(NSTimeInterval)interval
                        targetTime:(NSTimeInterval)targetTime
                           repeats:(BOOL)repeats
{
  if ((self = [super init])) {
    _interval = interval;
    _repeats = repeats;
    _callbackID = callbackID;
    _target = [NSDate dateWithTimeIntervalSinceNow:targetTime];
  }
  return self;
}

/**
 * Returns `YES` if we should invoke the JS callback.
 */
- (BOOL)shouldFire:(NSDate *)now
{
  if (_target && [_target timeIntervalSinceDate:now] <= 0) {
    return YES;
  }
  return NO;
}

- (void)reschedule
{
  // The JS Timers will do fine grained calculating of expired timeouts.
  _target = [NSDate dateWithTimeIntervalSinceNow:_interval];
}

@end

@interface _RCTTimingProxy : NSObject

@end

// NSTimer retains its target, insert this class to break potential retain cycles
@implementation _RCTTimingProxy
{
  __weak id _target;
}

+ (instancetype)proxyWithTarget:(id)target
{
  _RCTTimingProxy *proxy = [self new];
  if (proxy) {
    proxy->_target = target;
  }
  return proxy;
}

- (void)timerDidFire
{
  [_target timerDidFire];
}

@end

@implementation RCTTiming
{
  NSMutableDictionary<NSNumber *, _RCTTimer *> *_timers;
  NSTimer *_sleepTimer;
  BOOL _sendIdleEvents;
}

@synthesize bridge = _bridge;
@synthesize paused = _paused;
@synthesize pauseCallback = _pauseCallback;

RCT_EXPORT_MODULE()


- (void)setBridge:(RCTBridge *)bridge
{
  RCTAssert(!_bridge, @"Should never be initialized twice!");

  _paused = YES;
  _timers = [NSMutableDictionary new];

  for (NSString *name in @[NSApplicationWillTerminateNotification]) {

      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(stopTimers)
                                                   name:name
                                                 object:nil];
  }

  _bridge = bridge;
}

- (void)dealloc
{
  [_sleepTimer invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (dispatch_queue_t)methodQueue
{
  return RCTJSThread;
}

- (void)invalidate
{
  [self stopTimers];
  _bridge = nil;
}

- (void)stopTimers
{
  if (!_paused) {
    _paused = YES;
    if (_pauseCallback) {
      _pauseCallback();
    }
  }
}

- (void)startTimers
{
  if (_paused) {
    _paused = NO;
    if (_pauseCallback) {
      _pauseCallback();
    }
  }
}

- (BOOL)hasPendingTimers
{
  return _sendIdleEvents || _timers.count > 0;
}

- (void)didUpdateFrame:(RCTFrameUpdate *)update
{
  NSDate *nextScheduledTarget = [NSDate distantFuture];
  NSMutableArray<_RCTTimer *> *timersToCall = [NSMutableArray new];
  NSDate *now = [NSDate date]; // compare all the timers to the same base time
  for (_RCTTimer *timer in _timers.allValues) {
    if ([timer shouldFire:now]) {
      [timersToCall addObject:timer];
    } else {
      nextScheduledTarget = [nextScheduledTarget earlierDate:timer.target];
    }
  }

  NSArray<NSNumber *> *sortedTimers = [[timersToCall sortedArrayUsingComparator:^(_RCTTimer *a, _RCTTimer *b) {
    return [a.target compare:b.target];
  }] valueForKey:@"callbackID"];

  [_bridge enqueueJSCall:@"JSTimers"
                  method:@"callTimers"
                    args:@[sortedTimers]
              completion:NULL];

  for (_RCTTimer *timer in timersToCall) {
    if (timer.repeats) {
      [timer reschedule];
      nextScheduledTarget = [nextScheduledTarget earlierDate:timer.target];
    } else {
      [_timers removeObjectForKey:timer.callbackID];
    }
  }

  if (_sendIdleEvents) {
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval frameElapsed = currentTimestamp - update.timestamp;
    if (kFrameDuration - frameElapsed >= kIdleCallbackFrameDeadline) {
      NSNumber *absoluteFrameStartMS = @((currentTimestamp - frameElapsed) * 1000);
      [_bridge enqueueJSCall:@"JSTimers"
                      method:@"callIdleCallbacks"
                        args:@[absoluteFrameStartMS]
                  completion:NULL];
    }
  }
}

- (void)scheduleSleepTimer:(NSDate *)sleepTarget
{
  if (!_sleepTimer || !_sleepTimer.valid) {
    _sleepTimer = [[NSTimer alloc] initWithFireDate:sleepTarget
                                           interval:0
                                             target:[_RCTTimingProxy proxyWithTarget:self]
                                           selector:@selector(timerDidFire)
                                           userInfo:nil
                                            repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:_sleepTimer forMode:NSDefaultRunLoopMode];
  } else {
    _sleepTimer.fireDate = [_sleepTimer.fireDate earlierDate:sleepTarget];
  }
}

- (void)timerDidFire
{
  _sleepTimer = nil;
  if (_paused) {
    [self startTimers];

    // Immediately dispatch frame, so we don't have to wait on the displaylink.
    [self didUpdateFrame:nil];
  }
}

/**
 * There's a small difference between the time when we call
 * setTimeout/setInterval/requestAnimation frame and the time it actually makes
 * it here. This is important and needs to be taken into account when
 * calculating the timer's target time. We calculate this by passing in
 * Date.now() from JS and then subtracting that from the current time here.
 */
RCT_EXPORT_METHOD(createTimer:(nonnull NSNumber *)callbackID
                  duration:(NSTimeInterval)jsDuration
                  jsSchedulingTime:(NSDate *)jsSchedulingTime
                  repeats:(BOOL)repeats)
{
  if (jsDuration == 0 && repeats == NO) {
    // For super fast, one-off timers, just enqueue them immediately rather than waiting a frame.
    [_bridge _immediatelyCallTimer:callbackID];
    return;
  }

  NSTimeInterval jsSchedulingOverhead = MAX(-jsSchedulingTime.timeIntervalSinceNow, 0);

  NSTimeInterval targetTime = jsDuration - jsSchedulingOverhead;
  if (jsDuration < 0.018) { // Make sure short intervals run each frame
    jsDuration = 0;
  }

  _RCTTimer *timer = [[_RCTTimer alloc] initWithCallbackID:callbackID
                                                  interval:jsDuration
                                                targetTime:targetTime
                                                   repeats:repeats];
  _timers[callbackID] = timer;
  if (_paused) {
    if ([timer.target timeIntervalSinceNow] > kMinimumSleepInterval) {
      [self scheduleSleepTimer:timer.target];
    } else {
      [self startTimers];
    }
  }
}

RCT_EXPORT_METHOD(deleteTimer:(nonnull NSNumber *)timerID)
{
  [_timers removeObjectForKey:timerID];
}

RCT_EXPORT_METHOD(setSendIdleEvents:(BOOL)sendIdleEvents)
{
  _sendIdleEvents = sendIdleEvents;
  if (sendIdleEvents) {
    [self startTimers];
  }
}

@end
