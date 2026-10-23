//
//  TPEventsController.m
//  teleport
//
//  Created by JuL on 09/11/05.
//  Copyright 2005 abyssoft. All rights reserved.
//

#import "TPEventsController.h"

#import <CoreGraphics/CoreGraphics.h>

#import "TPDirectEventTapsController.h"
#import "TPEventTapsController.h"
#import "TPPreferencesManager.h"

#import "TPRemoteHost.h"
#import "TPLocalHost.h"
#import "TPServerController.h"
#import "TPHotBorder.h"
#import "TPScreenLockWatcher.h"

extern CGEventTimestamp CGSCurrentEventTimestamp(void);

/* Keep the switch-transition buffer short: replaying more than ~80ms of stale
   movement would show up as a jump instead of a seamless transition. */
#define TP_PENDING_SWITCH_MAX_AGE 0.08
#define TP_PENDING_SWITCH_MAX_EVENTS 48

#define TP_POINTER_QUEUE_CAPACITY 256

@implementation TPEventsController

- (instancetype) init
{
	self = [super init];
	
	if(self != nil) {
		dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
		_postingQueue = dispatch_queue_create("teleport.eventpost", attributes);
		_screenCacheLock = [[NSLock alloc] init];
		_pointerQueueLock = [[NSLock alloc] init];
	}
	
	return self;
}

- (dispatch_queue_t)_postingQueue
{
	return _postingQueue;
}

+ (TPEventsController*)defaultController
{
	return [TPEventTapsController defaultController];
}

+ (TPEventsController*)eventsControllerForRemoteHost:(TPRemoteHost*)remoteHost
{
	if([[TPLocalHost localHost] pairWithHost:remoteHost hasCapability:TPHostDirectEventTapsCapability]) {
		SInt32 localMajorVersion = [[TPLocalHost localHost] osVersion] & 0xFFF0;
		SInt32 remoteMajorVersion = [remoteHost osVersion] & 0xFFF0;
		// only allow direct event taps between same major OS versions
		if(localMajorVersion == remoteMajorVersion) {
			DebugLog(@"Using TPDirectEventTapsController");
			return [TPDirectEventTapsController defaultController];
		}
		else {
			DebugLog(@"Using TPEventTapsController");
			return [TPEventTapsController defaultController];
		}
	}
	else if([[TPLocalHost localHost] pairWithHost:remoteHost hasCapability:TPHostEventTapsCapability]) {
		DebugLog(@"Using TPEventTapsController");
		return [TPEventTapsController defaultController];
	}
	else {
		return nil;
	}
}

- (void)startGettingEventsForListener:(id<TPEventsListener>)eventsListener onScreen:(NSScreen*)screen
{
	_lastPostedEventDate = 0.0;
	_eventsListener = eventsListener;
	[self invalidateScreenCache];
	
	[self _startGettingEventsOnScreen:screen];
}

- (BOOL)_isCoalescableMouseEvent:(CGEventRef)event
{
	switch(CGEventGetType(event)) {
		case kCGEventMouseMoved:
		case kCGEventLeftMouseDragged:
		case kCGEventRightMouseDragged:
		case kCGEventOtherMouseDragged:
			return YES;
		default:
			return NO;
	}
}

- (BOOL)_coalesceMouseEvent:(CGEventRef)event
{
	BOOL consumed = NO;
	
	@synchronized(self) {
		NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
		CGEventType type = CGEventGetType(event);
		int64_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
		int64_t deltaX = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
		int64_t deltaY = CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
		
		if(_pendingMouseEvent == NULL) {
			_pendingMouseEvent = CFRetain(event);
			_pendingMouseType = type;
			_pendingMouseButton = button;
			_pendingDeltaX = deltaX;
			_pendingDeltaY = deltaY;
			_lastMouseBatchStart = now;
			
			[_mouseFlushTimer invalidate];
			_mouseFlushTimer = [NSTimer scheduledTimerWithTimeInterval:0.004
															   target:self
															 selector:@selector(_mouseFlushTimerFired:)
															 userInfo:nil
															  repeats:NO];
			consumed = YES;
		}
		else if(type == _pendingMouseType && button == _pendingMouseButton) {
			_pendingDeltaX += deltaX;
			_pendingDeltaY += deltaY;
			
			/* Keep the newest event for flags and timestamp; the accumulated
			   delta is written back when the batch is flushed. */
			CFRelease(_pendingMouseEvent);
			_pendingMouseEvent = CFRetain(event);
			consumed = YES;
		}
	}
	
	if(!consumed) {
		/* Type/button changed: flush the previous batch and deliver this one
		   immediately so that ordering and latency are preserved. */
		[self _flushPendingMouseEvent];
	}
	
	return consumed;
}

- (void)_mouseFlushTimerFired:(NSTimer*)timer
{
	@synchronized(self) {
		_mouseFlushTimer = nil;
	}
	[self _flushPendingMouseEvent];
}

- (void)_flushPendingMouseEvent
{
	CGEventRef event = NULL;
	int64_t deltaX = 0;
	int64_t deltaY = 0;
	
	@synchronized(self) {
		if(_pendingMouseEvent == NULL)
			return;
		
		event = (CGEventRef)_pendingMouseEvent;
		_pendingMouseEvent = NULL;
		deltaX = _pendingDeltaX;
		deltaY = _pendingDeltaY;
		
		[_mouseFlushTimer invalidate];
		_mouseFlushTimer = nil;
	}
	
	CGEventSetIntegerValueField(event, kCGMouseEventDeltaX, deltaX);
	CGEventSetIntegerValueField(event, kCGMouseEventDeltaY, deltaY);
	
	/* Prefer the optional UDP pointer channel: it keeps a lost packet from
	   stalling the ordered stream that carries keys and buttons. */
	id sender = nil;
	@synchronized(self) {
		sender = _pointerDeltaSender;
	}
	
	uint8_t buttons = 0;
	switch(_pendingMouseType) {
		case kCGEventLeftMouseDragged:
			buttons = 0x1;
			break;
		case kCGEventRightMouseDragged:
			buttons = 0x2;
			break;
		case kCGEventOtherMouseDragged:
			buttons = 0x4;
			break;
		default:
			break;
	}
	
	BOOL sentOverPointerChannel = NO;
	if(sender != nil && buttons == 0) {
		/* Only hover movement uses the lossy channel. A drag must keep the
		   exact down/drag/up ordering and the original event flags, so it stays
		   on the reliable TCP stream. */
		TPMouseDelta delta = { deltaX, deltaY };
		uint64_t age = [self _eventAgeForEvent:(__bridge id)event];
		
		sentOverPointerChannel = ((BOOL (^)(TPMouseDelta, uint8_t, uint32_t))sender)(delta, buttons, (uint32_t)(age / 1000000ULL));
	}
	
	if(!sentOverPointerChannel) {
		[self _deliverEventToListener:(__bridge id)event];
	}
	else {
		/* Keep the "first event" bookkeeping in sync: the pointer channel is
		   still a delivered event as far as the capture side is concerned. */
		_lastPostedEventDate = [NSDate timeIntervalSinceReferenceDate];
	}
	CFRelease(event);
}

- (void)_sendEventToListener:(id)event
{
	CGEventRef cgEvent = (__bridge CGEventRef)event;
	
	if([self _isCoalescableMouseEvent:cgEvent]) {
		/* Let the very first event through untouched (it is either discarded
		   as the initial jump or delivered immediately). */
		if(_lastPostedEventDate != 0.0 && [self _coalesceMouseEvent:cgEvent])
			return;
	}
	else {
		[self _flushPendingMouseEvent];
	}
	
	[self _deliverEventToListener:event];
}

- (void)_deliverEventToListener:(id)event
{
	id<TPEventsListener> eventsListener = [self eventsListener];
	
	if((_lastPostedEventDate == 0.0) && [self _shouldSkipFirstEvent:event]) {
		DebugLog(@"skipping first event");
	}
	else if(eventsListener != nil) {
		if([self _isEmergencyStopEvent:event]) {
			NSLog(@"emergency stop key sequence detected, disconnecting.");
			[eventsListener gotEmergencyStopEvent];
		}
		else {
			NSEvent * nsEvent = [self _nsEventFromEvent:event];
			
			/* The stop check must not mutate UI state from the event tap thread.
			   Ask the listener with a side-effect free method, then perform the
			   actual stop on the main thread. */
			BOOL shouldStop = NO;
			if([eventsListener respondsToSelector:@selector(isStopControlEvent:)]) {
				shouldStop = [(id<TPEventsListener>)eventsListener isStopControlEvent:nsEvent];
			}
			else {
				shouldStop = [eventsListener shouldStopWithEvent:nsEvent];
			}
			
			if(shouldStop) {
				dispatch_async(dispatch_get_main_queue(), ^{
					[eventsListener shouldStopWithEvent:nsEvent];
				});
			}
			else {
				NSData * eventData = [self _eventDataFromEvent:event];
				[eventsListener gotEventWithEventData:eventData];
			}
		}
	}
	
	_lastPostedEventDate = [NSDate timeIntervalSinceReferenceDate];
}

- (void)stopGettingEvents
{
	[self _flushPendingMouseEvent];
	[self _stopGettingEvents];
	_eventsListener = nil;
}


#pragma mark -
#pragma mark Switch transition buffering

- (void)beginBufferingForPendingSwitch
{
	@synchronized(self) {
		if(_pendingSwitchEvents == nil)
			_pendingSwitchEvents = [[NSMutableArray alloc] init];
		else
			[_pendingSwitchEvents removeAllObjects];
		
		_pendingSwitchStartDate = [NSDate timeIntervalSinceReferenceDate];
		_bufferingPendingSwitch = YES;
	}
}

- (void)commitBufferedSwitchEvents
{
	NSArray * events = nil;
	
	@synchronized(self) {
		_bufferingPendingSwitch = NO;
		events = _pendingSwitchEvents;
		_pendingSwitchEvents = nil;
	}
	
	/* Deliver in order, with the original event ages intact: the receiver
	   restores each timestamp from them. */
	for(id event in events) {
		@autoreleasepool {
			[self _deliverEventToListener:event];
		}
	}
}

- (void)cancelBufferedSwitchEvents
{
	@synchronized(self) {
		_bufferingPendingSwitch = NO;
		_pendingSwitchEvents = nil;
	}
}

- (BOOL)_isBufferingForPendingSwitch
{
	@synchronized(self) {
		return _bufferingPendingSwitch;
	}
}

- (void)_bufferEventForPendingSwitch:(CGEventRef)event
{
	if(event == NULL)
		return;
	
	/* Only movement is replayed. A click or key press that lands during the
	   negotiation already applied locally and must not be duplicated. */
	switch(CGEventGetType(event)) {
		case kCGEventMouseMoved:
		case kCGEventLeftMouseDragged:
		case kCGEventRightMouseDragged:
		case kCGEventOtherMouseDragged:
			break;
		default:
			return;
	}
	
	@synchronized(self) {
		if(!_bufferingPendingSwitch)
			return;
		
		if([NSDate timeIntervalSinceReferenceDate] - _pendingSwitchStartDate > TP_PENDING_SWITCH_MAX_AGE) {
			[_pendingSwitchEvents removeAllObjects];
			_bufferingPendingSwitch = NO;
			return;
		}
		
		if([_pendingSwitchEvents count] >= TP_PENDING_SWITCH_MAX_EVENTS)
			return;
		
		CGEventRef copy = CGEventCreateCopy(event);
		if(copy != NULL)
			[_pendingSwitchEvents addObject:CFBridgingRelease(copy)];
	}
}

- (void)dealloc
{
	if(_pendingMouseEvent != NULL) {
		CFRelease(_pendingMouseEvent);
		_pendingMouseEvent = NULL;
	}
	[_mouseFlushTimer invalidate];
	
	@synchronized(self) {
		_bufferingPendingSwitch = NO;
		[_pendingSwitchEvents removeAllObjects];
		_pendingSwitchEvents = nil;
	}
}

- (void)cleanupGettingEvents
{

}

- (id<TPEventsListener>)eventsListener
{
	return _eventsListener;
}

- (void)_startGettingEventsOnScreen:(NSScreen*)screen
{
	// overloaded
}

- (void)_stopGettingEvents
{
	// overloaded
}

- (void)startPostingEvents
{
	_lastReceivedEventDate = [NSDate timeIntervalSinceReferenceDate];
	
	/* Rebuild the geometry on the main thread, then reset the receiver state
	   on the posting queue so a new session never sees the previous one's
	   cursor position. */
	[self invalidateScreenCache];
	dispatch_sync(_postingQueue, ^{
		_lastPostedEventDate = 0.0;
		_mouseLocationValid = NO;
		
		[_pointerQueueLock lock];
		_pointerQueueHead = 0;
		_pointerQueueCount = 0;
		[_pointerQueueLock unlock];
	});
}

- (void)stopPostingEvents
{
	dispatch_sync(_postingQueue, ^{
		_mouseLocationValid = NO;
	});
}

- (void)setPointerDeltaSender:(BOOL (^)(TPMouseDelta delta, uint8_t buttons, uint32_t ageMs))sender
{
	@synchronized(self) {
		_pointerDeltaSender = [sender copy];
	}
}

- (void)queuePointerDelta:(TPPointerDelta)delta
{
	[_pointerQueueLock lock];
	
	if(_pointerQueueCount < TP_POINTER_QUEUE_CAPACITY) {
		NSUInteger tail = (_pointerQueueHead + _pointerQueueCount) % TP_POINTER_QUEUE_CAPACITY;
		_pointerQueue[tail] = delta;
		_pointerQueueCount++;
	}
	else {
		/* Overrun: drop the oldest so the cursor keeps following recent input. */
		_pointerQueue[_pointerQueueHead] = delta;
		_pointerQueueHead = (_pointerQueueHead + 1) % TP_POINTER_QUEUE_CAPACITY;
	}
	
	[_pointerQueueLock unlock];
	
	dispatch_async(_postingQueue, ^{
		[self _drainPointerDeltas];
	});
}

- (void)_drainPointerDeltas
{
	for(;;) {
		TPPointerDelta delta;
		BOOL hasDelta = NO;
		
		[_pointerQueueLock lock];
		if(_pointerQueueCount > 0) {
			delta = _pointerQueue[_pointerQueueHead];
			_pointerQueueHead = (_pointerQueueHead + 1) % TP_POINTER_QUEUE_CAPACITY;
			_pointerQueueCount--;
			hasDelta = YES;
		}
		[_pointerQueueLock unlock];
		
		if(!hasDelta)
			break;
		
		[self _applyPointerDelta:delta];
	}
}

- (void)_applyPointerDelta:(TPPointerDelta)delta
{
	if(delta.x == 0 && delta.y == 0)
		return;
	
	TPMouseDelta mouseDelta = { delta.x, delta.y };
	[self _updateMouseLocationWithMouseDelta:mouseDelta];
	
	CGEventType type = kCGEventMouseMoved;
	CGMouseButton button = kCGMouseButtonLeft;
	
	if(delta.buttons & 0x1) {
		type = kCGEventLeftMouseDragged;
	}
	else if(delta.buttons & 0x2) {
		type = kCGEventRightMouseDragged;
		button = kCGMouseButtonRight;
	}
	else if(delta.buttons & 0x4) {
		type = kCGEventOtherMouseDragged;
		button = kCGMouseButtonCenter;
	}
	
	/* The event source belongs to the concrete controller and is attached in
	   _postEvent:withTimestamp:. */
	CGEventRef event = CGEventCreateMouseEvent(NULL, type, _currentMouseLocation, button);
	if(event == NULL)
		return;
	
	CGEventSetType(event, type);
	/* Keep the delta fields consistent with the movement: some drag handling
	   relies on them, not only on the absolute location. */
	CGEventSetIntegerValueField(event, kCGMouseEventDeltaX, delta.x);
	CGEventSetIntegerValueField(event, kCGMouseEventDeltaY, delta.y);
	[self _postEvent:event withTimestamp:[self _timestampForEventAge:(uint64_t)delta.ageMs * 1000000ULL]];
	CFRelease(event);
}

- (void)postEventWithEventData:(NSData*)eventData
{
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	
	/* Wake the display only when it is really asleep, and do it after posting
	   this event: IOPM calls on the main thread were visible as a hitch on the
	   first movement of every session. */
	if (now - _lastReceivedEventDate > 60.0 && CGDisplayIsAsleep(CGMainDisplayID())) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[[TPLocalHost localHost] wakeUpScreen];
		});
	}
	
	_lastReceivedEventDate = now;
	
	/* Injection (decode + coordinate update + CGEventPost) runs off the main
	   run loop: a busy main thread on the receiving Mac must not delay input.
	   The queue is serial, so events keep their order. Pointer deltas that
	   arrived before this event are applied first, so the click lands where the
	   user saw the cursor. */
	dispatch_async(_postingQueue, ^{
		@autoreleasepool {
			[self _drainPointerDeltas];
			[self _postEventWithEventData:eventData];
		}
	});
}

- (void)_postEventWithEventData:(NSData*)eventData
{
	// overloaded
}

- (void)warpMouseToCenter
{
	NSArray * screens = [[TPLocalHost localHost] screens];
	NSRect mainScreenRect = [screens[0] frame];

	NSPoint centerPoint = NSMakePoint(NSMidX(mainScreenRect), NSMidY(mainScreenRect));
	return [self warpMouseToPosition:centerPoint];
}

- (void)warpMouseToPosition:(NSPoint)position
{
	_currentMouseLocation = *(CGPoint*)&position;
	_mouseLocationValid = YES;
}

- (void)mouseDownAtPosition:(NSPoint)position
{
	_currentMouseLocation = *(CGPoint*)&position;
	_mouseLocationValid = YES;
}

- (void)mouseUpAtPosition:(NSPoint)position
{
	_currentMouseLocation = *(CGPoint*)&position;
	_mouseLocationValid = YES;
}

- (BOOL)_shouldSkipFirstEvent:(id)event
{
	return NO;
}

- (BOOL)_isEmergencyStopEvent:(id)event
{
	return NO;
}

- (NSEvent*)_nsEventFromEvent:(id)event
{
	return (NSEvent*)event;
}

- (NSData*)_eventDataFromEvent:(id)event
{
	return nil;
}

- (void)_updateMouseLocationWithMouseDelta:(TPMouseDelta)mouseDelta
{
	[self _rebuildScreenCacheIfNeeded];
	
	[_screenCacheLock lock];
	NSArray * screenFrames = _cachedScreenFrames;
	NSArray * screens = _cachedScreens;
	CGFloat mainScreenHeight = _cachedMainScreenHeight;
	[_screenCacheLock unlock];
	
	if(!_mouseLocationValid) {
		NSPoint location = [NSEvent mouseLocation];
		_currentMouseLocation.x = location.x;
		_currentMouseLocation.y = mainScreenHeight - location.y;
		_mouseLocationValid = YES;
	}
	
	/* Integrate deltas only: never re-read the system cursor position here.
	   CGEventPost is asynchronous, so reading it per event can double-count
	   movement and cause jitter. */
	_currentMouseLocation.x += mouseDelta.x;
	_currentMouseLocation.y += mouseDelta.y;
	
	NSUInteger i = 0;
	for(NSValue * value in screenFrames) {
		NSRect screenFrame = [value rectValue];
		NSPoint relativePoint = CGPointMake(_currentMouseLocation.x - NSMinX(screenFrame),
											_currentMouseLocation.y - NSMinY(screenFrame));
		
		if(relativePoint.x >= 0 && relativePoint.y >= 0 && relativePoint.x < NSWidth(screenFrame) && relativePoint.y < NSHeight(screenFrame)) {
			_currentScreenIndex = (int)i;
			return;
		}
		i++;
	}
	
	/* Mouse cursor is outside: clamp it to the current screen. */
	NSUInteger screenCount = [screenFrames count];
	if(screenCount == 0)
		return;
	
	if(_currentScreenIndex < 0 || (NSUInteger)_currentScreenIndex >= screenCount)
		_currentScreenIndex = 0;
	
	NSRect screenFrame = [[screenFrames objectAtIndex:_currentScreenIndex] rectValue];
	_currentMouseLocation.x = MAX(NSMinX(screenFrame), MIN(_currentMouseLocation.x, NSMaxX(screenFrame) - 1.0));
	_currentMouseLocation.y = MAX(NSMinY(screenFrame), MIN(_currentMouseLocation.y, NSMaxY(screenFrame) - 1.0));
	
	/* When the cursor is clamped at the edge but the raw delta keeps pushing
	   outward, treat it as a switch request even if no mouseEntered event was
	   delivered (fast movement can jump over the 3pt strip). This also covers
	   the locked-screen case below.
	   
	   The return border is AppKit UI, so the check runs on the main thread;
	   only clamped edges get here, which is rare. */
	NSScreen * screen = ((NSUInteger)_currentScreenIndex < [screens count]) ? [screens objectAtIndex:_currentScreenIndex] : nil;
	CGPoint mouseLocationInvertY = CGPointMake(_currentMouseLocation.x, mainScreenHeight - _currentMouseLocation.y);
	
	dispatch_async(dispatch_get_main_queue(), ^{
		TPHotBorder * border = [[TPServerController defaultController] currentHotBorder];
		if(border == nil || screen == nil || screen != [border screen])
			return;
		/* Inset by -1 so that clamping exactly onto a border edge (notably the
		   top edge) still counts as inside. */
		if(CGRectContainsPoint(CGRectInset(border.frame, -1.0, -1.0), mouseLocationInvertY))
			[border fireFromOutwardPushAtScreenPoint:NSPointFromCGPoint(mouseLocationInvertY)];
	});
}

- (void)invalidateScreenCache
{
	/* NSScreen queries must stay on the main thread; the posting queue only
	   reads the immutable snapshot built here. */
	if([NSThread isMainThread]) {
		[self _rebuildScreenCache];
	}
	else {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _rebuildScreenCache];
		});
	}
}

- (void)_rebuildScreenCache
{
	NSArray * screens = [NSScreen screens];
	NSScreen * mainScreen = [screens count] > 0 ? [screens objectAtIndex:0] : nil;
	CGFloat mainScreenHeight = (mainScreen != nil) ? NSHeight([mainScreen frame]) : 0.0;
	
	NSMutableArray * frames = [NSMutableArray arrayWithCapacity:[screens count]];
	NSEnumerator * screenEnum = [screens objectEnumerator];
	NSScreen * screen;
	
	while((screen = [screenEnum nextObject]) != nil) {
		NSRect frame = [screen frame];
		/* Store frames in the top-left origin space used by
		   _currentMouseLocation and CGEvent deltas. */
		NSRect flippedFrame = NSMakeRect(NSMinX(frame),
										 mainScreenHeight - NSMaxY(frame),
										 NSWidth(frame),
										 NSHeight(frame));
		[frames addObject:[NSValue valueWithRect:flippedFrame]];
	}
	
	[_screenCacheLock lock];
	_cachedScreens = [screens copy];
	_cachedScreenFrames = frames;
	_cachedMainScreenHeight = mainScreenHeight;
	_screenCacheValid = YES;
	[_screenCacheLock unlock];
}

+ (void)invalidateScreenCaches
{
	[[TPEventTapsController defaultController] invalidateScreenCache];
	[[TPDirectEventTapsController defaultController] invalidateScreenCache];
}

- (uint64_t)_eventAgeForEvent:(id)event
{
	CGEventRef cgEvent = (__bridge CGEventRef)event;
	CGEventTimestamp timestamp = CGEventGetTimestamp(cgEvent);
	CGEventTimestamp now = CGSCurrentEventTimestamp();
	
	if(timestamp == 0 || now <= timestamp)
		return 0;
	
	uint64_t age = (uint64_t)(now - timestamp);
	/* Clamp to one second: a bogus age must not push timestamps far into the
	   past, which would confuse momentum/velocity handling on the receiver. */
	if(age > 1000000000ULL)
		age = 1000000000ULL;
	
	return age;
}

- (CGEventTimestamp)_timestampForEventAge:(uint64_t)age
{
	CGEventTimestamp now = CGSCurrentEventTimestamp();
	return (age >= now) ? now : (now - age);
}

- (void)_rebuildScreenCacheIfNeeded
{
	[_screenCacheLock lock];
	BOOL valid = _screenCacheValid;
	[_screenCacheLock unlock];
	
	if(valid)
		return;
	
	/* Called from the posting queue: geometry has to be queried on the main
	   thread. This event uses the previous snapshot, which is at most one
	   display change old. */
	dispatch_async(dispatch_get_main_queue(), ^{
		[self _rebuildScreenCache];
	});
}

- (BOOL)event:(NSEvent*)event hasRequiredKeyIfNeeded:(BOOL)needed withTag:(NSEventType)tag
{
	if(!needed)
		return YES;
	
	unsigned int keyMask = NSEventMaskFromType(tag);
	DebugLog(@"keyMask: %d modifiersFlags: %d", keyMask, (int)[event modifierFlags]);
	if(([event modifierFlags] & keyMask) != 0)
		return YES;
	
	NSEventModifierFlags flags = [NSEvent modifierFlags];
	DebugLog(@"flags: %lu", flags);
	switch(tag) {
		case COMMAND_KEY_TAG:
			if((flags & NSCommandKeyMask) != 0)
				return YES;
			break;
		case ALT_KEY_TAG:
			if((flags & NSAlternateKeyMask) != 0)
				return YES;
			break;
		case CTRL_KEY_TAG:
			if((flags & NSControlKeyMask) != 0)
				return YES;
			break;
		case SHIFT_KEY_TAG:
			if((flags & NSShiftKeyMask) != 0)
				return YES;
			break;
		case CAPSLOCK_KEY_TAG:
			if((flags & NSAlphaShiftKeyMask) != 0)
				return YES;
			break;
		default:
			break;
		
	}

	return NO;
}

@end
