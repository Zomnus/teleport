//
//  TPEventsController.m
//  teleport
//
//  Created by JuL on 09/11/05.
//  Copyright 2005 abyssoft. All rights reserved.
//

#import "TPEventsController.h"

#import "TPDirectEventTapsController.h"
#import "TPEventTapsController.h"
#import "TPPreferencesManager.h"

#import "TPRemoteHost.h"
#import "TPLocalHost.h"
#import "TPServerController.h"
#import "TPHotBorder.h"
#import "TPScreenLockWatcher.h"

#define THREADED_EVENT_POSTING 0

extern CGEventTimestamp CGSCurrentEventTimestamp(void);

@implementation TPEventsController

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
	
	[self _deliverEventToListener:(__bridge id)event];
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

- (void)dealloc
{
	if(_pendingMouseEvent != NULL) {
		CFRelease(_pendingMouseEvent);
		_pendingMouseEvent = NULL;
	}
	[_mouseFlushTimer invalidate];
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
	_lastPostedEventDate = 0.0;
	_mouseLocationValid = NO;
	[self invalidateScreenCache];
}

- (void)stopPostingEvents
{
	
}

- (void)_threadedPostEventWithEventData:(NSData*)eventData
{
	@autoreleasepool {
		[self _postEventWithEventData:eventData];
	}
}

- (void)postEventWithEventData:(NSData*)eventData
{
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
		
	if (now - _lastPostedEventDate > 60.0) { // if last event occurred more than a minute ago
		[[TPLocalHost localHost] wakeUpScreen];
	}
	
	_lastPostedEventDate = now;
	
#if THREADED_EVENT_POSTING
	[NSThread detachNewThreadSelector:@selector(_threadedPostEventWithEventData:) toTarget:self withObject:eventData];
#else
	[self _postEventWithEventData:eventData];
#endif
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
	
	if(!_mouseLocationValid) {
		NSPoint location = [NSEvent mouseLocation];
		_currentMouseLocation.x = location.x;
		_currentMouseLocation.y = _cachedMainScreenHeight - location.y;
		_mouseLocationValid = YES;
	}
	
	/* Integrate deltas only: never re-read the system cursor position here.
	   CGEventPost is asynchronous, so reading it per event can double-count
	   movement and cause jitter. */
	_currentMouseLocation.x += mouseDelta.x;
	_currentMouseLocation.y += mouseDelta.y;
	
	NSUInteger i = 0;
	for(NSValue * value in _cachedScreenFrames) {
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
	NSUInteger screenCount = [_cachedScreenFrames count];
	if(screenCount == 0)
		return;
	
	if(_currentScreenIndex < 0 || (NSUInteger)_currentScreenIndex >= screenCount)
		_currentScreenIndex = 0;
	
	NSRect screenFrame = [[_cachedScreenFrames objectAtIndex:_currentScreenIndex] rectValue];
	_currentMouseLocation.x = MAX(NSMinX(screenFrame), MIN(_currentMouseLocation.x, NSMaxX(screenFrame) - 1.0));
	_currentMouseLocation.y = MAX(NSMinY(screenFrame), MIN(_currentMouseLocation.y, NSMaxY(screenFrame) - 1.0));
	
	// When the cursor is clamped at the edge but the raw delta keeps pushing
	// outward, treat it as a switch request even if no mouseEntered event was
	// delivered (fast movement can jump over the 3pt strip). This also covers
	// the locked-screen case below.
	TPHotBorder *border = [[TPServerController defaultController] currentHotBorder];
	if(border != nil) {
		NSScreen * screen = (NSUInteger)_currentScreenIndex < [_cachedScreens count] ? [_cachedScreens objectAtIndex:_currentScreenIndex] : nil;
		if (screen == [border screen]) {
			// _currentMouseLocation is relative to the left-top corner of the main screen.
			// while borderRect is relative to the left-bottom corner of the main screen.
			CGPoint mouseLocationInvertY = CGPointMake(_currentMouseLocation.x, _cachedMainScreenHeight - _currentMouseLocation.y);
			/* Inset by -1 so that clamping exactly onto a border edge
			   (notably the top edge) still counts as inside. */
			if (CGRectContainsPoint(CGRectInset(border.frame, -1.0, -1.0), mouseLocationInvertY)) {
				[border fireFromOutwardPushAtScreenPoint:NSPointFromCGPoint(mouseLocationInvertY)];
			}
		}
	}
}

- (void)invalidateScreenCache
{
	_screenCacheValid = NO;
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
	if(_screenCacheValid)
		return;
	
	NSArray * screens = [NSScreen screens];
	NSScreen * mainScreen = [screens count] > 0 ? [screens objectAtIndex:0] : nil;
	_cachedMainScreenHeight = (mainScreen != nil) ? NSHeight([mainScreen frame]) : 0.0;
	
	NSMutableArray * frames = [NSMutableArray arrayWithCapacity:[screens count]];
	NSEnumerator * screenEnum = [screens objectEnumerator];
	NSScreen * screen;
	
	while((screen = [screenEnum nextObject]) != nil) {
		NSRect frame = [screen frame];
		/* Store frames in the top-left origin space used by
		   _currentMouseLocation and CGEvent deltas. */
		NSRect flippedFrame = NSMakeRect(NSMinX(frame),
										 _cachedMainScreenHeight - NSMaxY(frame),
										 NSWidth(frame),
										 NSHeight(frame));
		[frames addObject:[NSValue valueWithRect:flippedFrame]];
	}
	
	_cachedScreens = [screens copy];
	_cachedScreenFrames = frames;
	_screenCacheValid = YES;
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
