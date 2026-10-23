//
//  TPEventsController.h
//  teleport
//
//  Created by JuL on 09/11/05.
//  Copyright 2005 abyssoft. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>

#define ESC_KEYCODE 53
#define DISABLE_CONTROL 0

/* Number of bytes prepended to every serialized event: the event's age in
   nanoseconds at capture time. Both peers are required to understand it
   (protocol version 20+). */
#define TP_EVENT_AGE_LENGTH 8

@class TPRemoteHost;

@protocol TPEventsListener <NSObject>

- (void)gotEventWithEventData:(NSData*)eventData;
- (void)gotEmergencyStopEvent;
- (BOOL)shouldStopWithEvent:(NSEvent*)event;

@optional
/* Side-effect free variant, safe to call from the event tap thread. */
- (BOOL)isStopControlEvent:(NSEvent*)event;

@end

@interface TPEventsController : NSObject
{
	id<TPEventsListener> _eventsListener;
	
	int _currentScreenIndex;
	CGPoint _currentMouseLocation;
	BOOL _mouseLocationValid;
	
	NSArray * _cachedScreens;
	NSArray * _cachedScreenFrames;
	CGFloat _cachedMainScreenHeight;
	BOOL _screenCacheValid;
	
	/* Mouse move coalescing (sender side only). */
	CFTypeRef _pendingMouseEvent;
	CGEventType _pendingMouseType;
	int64_t _pendingMouseButton;
	int64_t _pendingDeltaX;
	int64_t _pendingDeltaY;
	NSTimeInterval _lastMouseBatchStart;
	NSTimer * _mouseFlushTimer;
	
	NSTimeInterval _lastPostedEventDate;
	
	/* Separate timestamp for the receiving side: the display wake-up must not
	   depend on the capture-side "skip first event" marker. */
	NSTimeInterval _lastReceivedEventDate;
	
	/* Event injection runs on this serial queue. The socket callback delivers
	   events on the main run loop; posting them from there meant that any UI
	   work on the receiving Mac delayed forwarded input. All receiver-side
	   state below is owned by this queue. */
	dispatch_queue_t _postingQueue;
	NSLock * _screenCacheLock;
	
	/* Movement captured between crossing an edge and the server acknowledging
	   the switch. Replayed once control starts so the transition has no dead
	   time; dropped if the switch fails. */
	NSMutableArray * _pendingSwitchEvents;
	BOOL _bufferingPendingSwitch;
	NSTimeInterval _pendingSwitchStartDate;
	
	/* Receiver side of the optional UDP pointer channel: the socket thread
	   queues deltas here, the posting queue drains and injects them in order. */
	TPPointerDelta _pointerQueue[256];
	NSUInteger _pointerQueueHead;
	NSUInteger _pointerQueueCount;
	NSLock * _pointerQueueLock;
	
	/* Capture side: when set, mouse movement is sent through this block instead
	   of the ordered TCP stream. Returning NO falls back for that event. */
	BOOL (^_pointerDeltaSender)(TPMouseDelta delta, uint8_t buttons, uint32_t ageMs);
}

+ (TPEventsController*)defaultController;
+ (TPEventsController*)eventsControllerForRemoteHost:(TPRemoteHost*)remoteHost;

- (void)startGettingEventsForListener:(id<TPEventsListener>)eventsListener onScreen:(NSScreen*)screen;
- (void)stopGettingEvents;
- (void)cleanupGettingEvents;
@property (nonatomic, readonly, strong) id<TPEventsListener> eventsListener;

/* Switch transition buffering. Only movement is kept (keys and buttons are
   not replayed), and it is bounded in both time and count. */
- (void)beginBufferingForPendingSwitch;
- (void)commitBufferedSwitchEvents;
- (void)cancelBufferedSwitchEvents;

/* Optional UDP pointer channel. The sender block is invoked from the event tap
   thread; it must return NO when the movement has to go through TCP instead. */
- (void)setPointerDeltaSender:(BOOL (^)(TPMouseDelta delta, uint8_t buttons, uint32_t ageMs))sender;
- (void)queuePointerDelta:(TPPointerDelta)delta;

- (void)startPostingEvents;
- (void)stopPostingEvents;
- (void)postEventWithEventData:(NSData*)eventData;

- (void)warpMouseToCenter;
- (void)warpMouseToPosition:(NSPoint)position;
- (void)mouseDownAtPosition:(NSPoint)position;
- (void)mouseUpAtPosition:(NSPoint)position;

- (BOOL)event:(NSEvent*)event hasRequiredKeyIfNeeded:(BOOL)needed withTag:(NSEventType)tag;

/* Screen geometry is cached and only rebuilt when the display configuration
   changes (see TPMainController's applicationDidChangeScreenParameters). */
- (void)invalidateScreenCache;

/* Invalidates the cache on every concrete controller singleton. The client
   may use TPDirectEventTapsController while [self defaultController] returns
   TPEventTapsController, so invalidating only the latter misses the one that
   is actually forwarding events. */
+ (void)invalidateScreenCaches;

@end

@interface TPEventsController (Internal)

- (void)_startGettingEventsOnScreen:(NSScreen*)screen;
- (void)_sendEventToListener:(id)event;
- (void)_stopGettingEvents;

- (BOOL)_shouldSkipFirstEvent:(id)event;
- (BOOL)_isEmergencyStopEvent:(id)event;
- (NSEvent*)_nsEventFromEvent:(id)event;
- (NSData*)_eventDataFromEvent:(id)event;
- (void)_postEventWithEventData:(NSData*)eventData;
- (void)_postEvent:(CGEventRef)event withTimestamp:(CGEventTimestamp)timestamp;

- (void)_updateMouseLocationWithMouseDelta:(TPMouseDelta)mouseDelta;
- (void)_rebuildScreenCacheIfNeeded;
- (void)_rebuildScreenCache;
- (dispatch_queue_t)_postingQueue;
- (void)_drainPointerDeltas;
- (void)_applyPointerDelta:(TPPointerDelta)delta;
- (uint64_t)_eventAgeForEvent:(id)event;
- (CGEventTimestamp)_timestampForEventAge:(uint64_t)age;
- (BOOL)_isCoalescableMouseEvent:(CGEventRef)event;
- (BOOL)_coalesceMouseEvent:(CGEventRef)event;
- (void)_flushPendingMouseEvent;
- (void)_deliverEventToListener:(id)event;

- (BOOL)_isBufferingForPendingSwitch;
- (void)_bufferEventForPendingSwitch:(CGEventRef)event;

@end
