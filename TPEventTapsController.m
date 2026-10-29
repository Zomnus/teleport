//
//  TPEventTapsController.m
//  teleport
//
//  Created by JuL on 09/11/05.
//  Copyright 2005 abyssoft. All rights reserved.
//

#import "TPEventTapsController.h"
#import "TPEventTapsController_Internal.h"

#import "TPPreferencesManager.h"
#import "TPMainController.h"
#import "TPClientController.h"
#import "TPScreenLockWatcher.h"

#include <Carbon/Carbon.h>

#define DEBUG_EVENTTAP 0
#define MAX_STRING 20

void CGSSetConnectionProperty(int, int, CFStringRef, CFBooleanRef);
int _CGSDefaultConnection();

static TPEventTapsController * _eventTapsController = nil;

static const char * eventTypeName[] =
{
	"NullEvent", "LMouseDown", "LMouseUp", "RMouseDown", "RMouseUp",
	"MouseMoved", "LMouseDragged", "RMouseDragged", "MouseEntered",
	"MouseExited", "KeyDown", "KeyUp", "FlagsChanged", "Kitdefined",
	"SysDefined", "AppDefined", "Timer", "CursorUpdate",
	"Journaling", "Suspend", "Resume", "Notification",
	"ScrollWheel", "TabletPointer", "TabletProximity",
	"OtherMouseDown", "OtherMouseUp", "OtherMouseDragged", "Zoom"
};

@interface TPEventTapsController (Internal)

- (void)_startGettingsEvents;
- (void)_postEvent:(CGEventRef)event;
- (void)_postEvent:(CGEventRef)event withTimestamp:(CGEventTimestamp)timestamp;

/* Bodies that touch the event source and the virtual cursor run on the
   posting queue (see TPEventsController's _postingQueue). */
- (void)_postWarpToPosition:(NSPoint)position;
- (void)_postMouseDownAtPosition:(NSPoint)position;
- (void)_postMouseUpAtPosition:(NSPoint)position;

- (BOOL)_shouldSkipFirstEvent:(id)e;
- (BOOL)_isEmergencyStopEvent:(id)e;

@end

@implementation TPEventTapsController

+ (TPEventsController*)defaultController
{
	if(_eventTapsController == nil)
		_eventTapsController = [[TPEventTapsController alloc] init];
	return _eventTapsController;
}

- (void)_hideCursorIfNeeded
{
	/* The local cursor must stay invisible while the remote one is in charge.
	   Some full-screen apps and space changes show it again, so this is polled
	   while capturing instead of being a one-shot call. */
	if(!CGCursorIsVisible())
		return;
	
	CGError error = CGDisplayHideCursor(kCGDirectMainDisplay);
	if(error == kCGErrorSuccess)
		_cursorHidesIssued++;
	
	DebugLog(@"hide cursor -> %@ (issued=%ld)", @(error), (long)_cursorHidesIssued);
}

- (void)_restoreCursor
{
	while(_cursorHidesIssued > 0) {
		CGDisplayShowCursor(kCGDirectMainDisplay);
		_cursorHidesIssued--;
	}
}

static CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
	TPEventTapsController * self = (__bridge TPEventTapsController*)refcon;
	
	if(type >= kCGEventTapDisabledByTimeout) {
		/* Only a real timeout is recoverable. kCGEventTapDisabledByUserInput
		   is set by the system and must be respected; trying to re-enable
		   after it leaves the tap permanently dead after a few cycles. */
		if(type == kCGEventTapDisabledByTimeout)
			[self _startGettingsEvents];
		return NULL;
	}
	
	BOOL controlling = [[TPClientController defaultController] isControlling];
	BOOL capturing = ([self eventsListener] != nil) && controlling;
	
	if(!capturing) {
		/* A switch is being negotiated: keep the movement so it can be replayed
		   when the server acknowledges. The event itself still flows through so
		   a failed switch leaves the local cursor where the user put it. */
		if([self _isBufferingForPendingSwitch]) {
			@autoreleasepool {
				[self _bufferEventForPendingSwitch:event];
			}
		}
		
		/* Not capturing: let the event flow through untouched. The tap stays
		   installed for the lifetime of the process instead of being
		   disabled/re-enabled on every switch. */
		if([self eventsListener] != nil)
			[self _requestStopFromCallback];
		return event;
	}
	
	@autoreleasepool {
		[self _sendEventToListener:(__bridge id)event];
	}
	
	return NULL;
}

+ (NSString*)_eventNameFromType:(CGEventType)type
{
	if(type < (sizeof eventTypeName / sizeof eventTypeName[0])) {
		return @(eventTypeName[type]);
	}
	else {
		return [NSString stringWithFormat:@"Event Type 0x%x", type];
	}
}


#pragma mark -
#pragma mark Getting events

- (void)_startGettingEventsOnScreen:(NSScreen*)screen
{
#if DISABLE_CONTROL
	return;
#endif
	
	if(IsSecureEventInputEnabled()) {
		[(TPMainController*)[NSApp delegate] goFrontmost];
	}
	
	// Hack to make background cursor setting work
	CFStringRef propertyString = CFStringCreateWithCString(NULL, "SetsCursorInBackground", kCFStringEncodingUTF8);
	CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), propertyString, kCFBooleanTrue);
	CFRelease(propertyString);
	
	[self _hideCursorIfNeeded];
	[self invalidateScreenCache];
	
	/* A new capture session starts here. Stale stop requests from a previous
	   session compare against this counter and are ignored. */
	@synchronized(self) {
		_sessionGeneration++;
	}
	
	/* The system can silently disable a tap (timeouts, secure input, lock
	   screen) without delivering anything we can act on. Poll its state while
	   capturing so forwarding recovers on its own. */
	[self _startTapHealthTimer];
	
	if(_eventPort != NULL) {
		if(_eventThread == nil && !_tapOnMainRunLoop) {
			/* The capturing thread died unexpectedly: rebuild from scratch. */
			[self _teardownEventTap];
		}
		else {
			[self _startGettingsEvents];
			return;
		}
	}
	
	if(_threadCondition == nil)
		_threadCondition = [[NSCondition alloc] init];
	
	[_threadCondition lock];
	_tapInstalled = NO;
	_tapInstallSucceeded = NO;
	_eventThread = [[NSThread alloc] initWithTarget:self selector:@selector(_eventThreadMain) object:nil];
	[_eventThread setName:@"teleport.eventtap"];
	[_eventThread start];
	
	while(!_tapInstalled)
		[_threadCondition wait];
	
	BOOL installed = _tapInstallSucceeded;
	[_threadCondition unlock];
	
	if(!installed) {
		/* Fallback: keep the tap on the main run loop, but register it in common
		   modes so that menu tracking / window dragging do not interrupt capture. */
		NSLog(@"teleport: could not install event tap thread, falling back to main run loop");
		[_threadCondition lock];
		_eventThread = nil;
		[_threadCondition unlock];
		_tapOnMainRunLoop = [self _installEventTapOnRunLoop:CFRunLoopGetCurrent() mode:kCFRunLoopCommonModes];
	}
}

- (void)_eventThreadMain
{
	@autoreleasepool {
		CFRunLoopRef runLoop = CFRunLoopGetCurrent();
		BOOL installed = [self _installEventTapOnRunLoop:runLoop mode:kCFRunLoopDefaultMode];
		
		[_threadCondition lock];
		_eventRunLoop = runLoop;
		_tapInstallSucceeded = installed;
		_tapInstalled = YES;
		[_threadCondition broadcast];
		[_threadCondition unlock];
		
		if(installed) {
			/* The tap lives for the lifetime of the process and is only
			   enabled/disabled between sessions. Tearing the thread down on
			   every switch caused races with rapid back-and-forth switching. */
			CFRunLoopRun();
			[self _teardownEventTap];
		}
		
		[_threadCondition lock];
		_eventRunLoop = NULL;
		_eventThread = nil;
		_tapInstalled = NO;
		[_threadCondition broadcast];
		[_threadCondition unlock];
	}
}

- (BOOL)_installEventTapOnRunLoop:(CFRunLoopRef)runLoop mode:(CFStringRef)mode
{
	CFMachPortRef port = CGEventTapCreate(kCGSessionEventTap,
										  kCGHeadInsertEventTap,
										  0,
										  /* Keep this mask broad. Trackpad gestures and
											 several other input events use types outside the
											 public CGEventType list; narrowing the mask made
											 gestures execute on the local Mac while it was
											 controlling another one. */
										  kCGEventMaskForAllEvents & ~(NX_KITDEFINEDMASK |
																	   NX_APPDEFINEDMASK),
										  eventCallback,
										  (__bridge void *)(self));
	if(port == NULL) {
		NSLog(@"Can't create event port");
		return NO;
	}
	
	CFRunLoopSourceRef eventSrc = CFMachPortCreateRunLoopSource(NULL, port, 0);
	if(eventSrc == NULL) {
		NSLog(@"Can't create event src");
		CFRelease(port);
		return NO;
	}
	
	CFRunLoopAddSource(runLoop, eventSrc, mode);
	
	_eventPort = port;
	_eventSourceRef = eventSrc;
	_eventRunLoop = runLoop;
	
	return YES;
}

- (void)_teardownEventTap
{
	[self _stopTapHealthTimer];
	
	if(_eventSourceRef != NULL) {
		if(_eventRunLoop != NULL) {
			CFRunLoopRemoveSource(_eventRunLoop, _eventSourceRef, kCFRunLoopDefaultMode);
			CFRunLoopRemoveSource(_eventRunLoop, _eventSourceRef, kCFRunLoopCommonModes);
		}
		CFRelease(_eventSourceRef);
		_eventSourceRef = NULL;
	}
	
	if(_eventPort != NULL) {
		CGEventTapEnable(_eventPort, false);
		CFMachPortInvalidate(_eventPort);
		CFRelease(_eventPort);
		_eventPort = NULL;
	}
}

- (void)_requestStopFromCallback
{
	NSInteger generation;
	
	@synchronized(self) {
		if(_stopRequestedFromCallback)
			return;
		_stopRequestedFromCallback = YES;
		generation = _sessionGeneration;
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		@synchronized(self) {
			_stopRequestedFromCallback = NO;
		}
		
		/* A new control session may have started in the meantime. Never let
		   a stale stop request kill it. */
		if(generation != _sessionGeneration)
			return;
		if([[TPClientController defaultController] isControlling])
			return;
		
		[self stopGettingEvents];
	});
}

- (void)_sendEventToListener:(id)event
{
	if(CGEventTapIsEnabled(_eventPort)) {
		[super _sendEventToListener:event];
	}
}

- (void)_startGettingsEvents
{
	if(_eventPort != NULL && !CGEventTapIsEnabled(_eventPort)) {
		CGEventTapEnable(_eventPort, true);
	}
}

- (void)_startTapHealthTimer
{
	if(_tapHealthTimer != nil)
		return;
	
	_tapHealthTimer = [NSTimer timerWithTimeInterval:1.0
											  target:self
											selector:@selector(_tapHealthTimerFired:)
											userInfo:nil
											 repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_tapHealthTimer forMode:NSRunLoopCommonModes];
}

- (void)_stopTapHealthTimer
{
	[_tapHealthTimer invalidate];
	_tapHealthTimer = nil;
}

- (void)_tapHealthTimerFired:(NSTimer*)timer
{
	/* Full-screen apps and space changes can bring the local cursor back while
	   we are controlling; keep it hidden. Cheap enough to run at 1 Hz. */
	[self _hideCursorIfNeeded];
	
	if(_eventPort == NULL || CGEventTapIsEnabled(_eventPort))
		return;
	
	/* Never fight the system when it is intentionally withholding events:
	   secure input (password fields) and the lock screen both disable taps. */
	if(IsSecureEventInputEnabled())
		return;
	if([TPScreenLockWatcher isLocked])
		return;
	
	NSLog(@"teleport: event tap was disabled by the system, re-enabling");
	CGEventTapEnable(_eventPort, true);
}

- (void)rebuildTapAfterWake
{
	if(_eventPort == NULL)
		return;
	
	NSLog(@"teleport: rebuilding the event tap after wake");
	
	CFRunLoopRef runLoop = _eventRunLoop;
	if(!_tapOnMainRunLoop && runLoop != NULL && _eventThread != nil) {
		/* Stop the tap thread and wait for it: it disposes of the invalidated
		   port on its way out, and the next capture session installs a fresh
		   one. Waiting avoids a window where a capture session would grab the
		   port that is about to be thrown away. */
		[_threadCondition lock];
		CFRunLoopStop(runLoop);
		/* Stop the timer from the thread that created it; the tap thread calls
		   this again while tearing down, which is then a no-op. */
		[self _stopTapHealthTimer];
		NSDate * deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
		while(_eventThread != nil && [deadline timeIntervalSinceNow] > 0)
			[_threadCondition waitUntilDate:deadline];
		BOOL threadStillRunning = (_eventThread != nil);
		[_threadCondition unlock];
		
		if(threadStillRunning)
			NSLog(@"teleport: event tap thread did not stop, leaving it alone");
		return;
	}
	
	_tapOnMainRunLoop = NO;
	[self _teardownEventTap];
}

- (void)_stopGettingEvents
{
	[self _stopTapHealthTimer];
	
	/* The tap is left installed and enabled, but from now on the callback
	   passes every event through untouched (eventsListener is cleared by the
	   caller right after this method). This avoids the system's
	   "disabled by user input" state that permanently kills a re-enabled tap. */
	TPMainController * mainController = (TPMainController*)[NSApp delegate];
	if([NSThread isMainThread])
		[mainController leaveFrontmost];
	else
		dispatch_async(dispatch_get_main_queue(), ^{
			[mainController leaveFrontmost];
		});
}

- (void)cleanupGettingEvents
{
	[super cleanupGettingEvents];
	
	[self _restoreCursor];
}

#pragma mark -
#pragma mark Posting events

- (void)startPostingEvents
{
	_lastReceivedEventDate = [NSDate timeIntervalSinceReferenceDate];
	
	/* Geometry is rebuilt here, on the main thread, so the posting queue only
	   ever reads a complete snapshot. */
	[self invalidateScreenCache];
	
	dispatch_sync([self _postingQueue], ^{
		if(_eventSource != NULL) {
			CFRelease(_eventSource);
			_eventSource = NULL;
		}
		
		_eventSource = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
		_mouseLocationValid = NO;
		
		[_pointerQueueLock lock];
		_pointerQueueHead = 0;
		_pointerQueueCount = 0;
		[_pointerQueueLock unlock];
	});
	
	[self _startModifierRewriteTap];
}

- (void)stopPostingEvents
{
	/* Wait for the events already queued to be posted, then drop the source. */
	dispatch_sync([self _postingQueue], ^{
		if(_eventSource != NULL) {
			CFRelease(_eventSource);
			_eventSource = NULL;
		}
		
		_mouseLocationValid = NO;
	});
	
	[self _stopModifierRewriteTap];
	[self _updateRemoteModifierFlags:0];
}

- (void)_postEvent:(CGEventRef)event
{
	[self _postEvent:event withTimestamp:CGSCurrentEventTimestamp()];
}

- (void)_postEvent:(CGEventRef)event withTimestamp:(CGEventTimestamp)timestamp
{
	CGEventSetTimestamp(event, timestamp);
	
	if(_eventSource != NULL) {
		CGEventSetSource(event, _eventSource);
	}
	
	/* Remember which modifiers the remote keyboard is holding. Clicks made with
	   the receiving Mac's own trackpad are stamped from its HID keyboard state,
	   which never contains them; the rewrite tap adds them back for local
	   hardware input so Shift-click extends a selection. */
	if(CGEventGetType(event) == kCGEventFlagsChanged) {
		[self _updateRemoteModifierFlags:CGEventGetFlags(event)];
	}
	
	CGEventPost(kCGSessionEventTap, event);
}


#pragma mark -
#pragma mark Conversions

#define APPEND_INTEGER(key) \
{ \
    int64_t value = CGEventGetIntegerValueField(event, key); \
    int64_t swappedValue = NSSwapHostLongLongToBig(value); \
    [eventData appendData:[NSData dataWithBytes:&swappedValue length:sizeof(int64_t)]]; \
}

#define APPEND_DOUBLE(key) \
{ \
    double value = CGEventGetDoubleValueField(event, key); \
    NSSwappedDouble swappedValue = NSSwapHostDoubleToBig(value); \
    [eventData appendData:[NSData dataWithBytes:&swappedValue length:sizeof(NSSwappedDouble)]]; \
}

#define READ_INTEGER(key) \
{ \
    int64_t swappedValue; \
    [eventData _readBytes:&swappedValue withSize:sizeof(int64_t) atPos:&pos]; \
    int64_t value = NSSwapBigLongLongToHost(swappedValue); \
    CGEventSetIntegerValueField(event, key, value); \
}

#define READ_DOUBLE(key) \
{ \
    NSSwappedDouble swappedValue; \
    [eventData _readBytes:&swappedValue withSize:sizeof(NSSwappedDouble) atPos:&pos]; \
    double value = NSSwapBigDoubleToHost(swappedValue); \
    CGEventSetDoubleValueField(event, key, value); \
}

- (NSData*)_eventDataFromEvent:(id)e
{
	CGEventRef event = (__bridge CGEventRef)e;
	
	NSMutableData * eventData = [[NSMutableData alloc] init];
	
	/* Prefix: age of the event in nanoseconds, so that the receiver can
	   restore the original inter-event rhythm without clock synchronisation. */
	uint64_t age = [self _eventAgeForEvent:e];
	uint64_t swappedAge = NSSwapHostLongLongToBig(age);
	[eventData appendData:[NSData dataWithBytes:&swappedAge length:sizeof(uint64_t)]];
	
	CGEventType eventType = CGEventGetType(event);
	CGEventType swappedEventType = NSSwapHostIntToBig(eventType);
	
//	DebugLog(@"postEvent: %d", eventType);
	
	/* Write event type */
	[eventData appendData:[NSData dataWithBytes:&swappedEventType length:sizeof(CGEventType)]];
	
	/* Write event data */
	switch(eventType) {
		case kCGEventMouseMoved:
		case kCGEventLeftMouseDragged:
		case kCGEventRightMouseDragged:
		case kCGEventOtherMouseDragged:
		{
			APPEND_INTEGER(kCGMouseEventNumber)
			APPEND_INTEGER(kCGMouseEventDeltaX)
			APPEND_INTEGER(kCGMouseEventDeltaY)
			APPEND_INTEGER(kCGMouseEventButtonNumber)
			break;
		}
		case kCGEventScrollWheel:
		case NX_ZOOM:
		{
			APPEND_INTEGER(kCGScrollWheelEventDeltaAxis1)
			APPEND_INTEGER(kCGScrollWheelEventDeltaAxis2)
			APPEND_INTEGER(kCGScrollWheelEventDeltaAxis3)

			if(1) {
				APPEND_INTEGER(kCGScrollWheelEventScrollPhase)
				APPEND_INTEGER(kCGScrollWheelEventIsContinuous)
				
				APPEND_DOUBLE(kCGScrollWheelEventFixedPtDeltaAxis1)
				APPEND_DOUBLE(kCGScrollWheelEventFixedPtDeltaAxis2)
				APPEND_DOUBLE(kCGScrollWheelEventFixedPtDeltaAxis3)
				APPEND_DOUBLE(kCGScrollWheelEventPointDeltaAxis1)
				APPEND_DOUBLE(kCGScrollWheelEventPointDeltaAxis2)
				APPEND_DOUBLE(kCGScrollWheelEventPointDeltaAxis3)
			}
			break;
		}
		case kCGEventLeftMouseDown:
		case kCGEventLeftMouseUp:
		case kCGEventRightMouseDown:
		case kCGEventRightMouseUp:
		case kCGEventOtherMouseDown:
		case kCGEventOtherMouseUp:
		{
			APPEND_INTEGER(kCGMouseEventNumber)
			APPEND_INTEGER(kCGMouseEventButtonNumber)
			APPEND_INTEGER(kCGMouseEventClickState)
			APPEND_INTEGER(kCGMouseEventInstantMouser)
			APPEND_INTEGER(kCGMouseEventSubtype)
			APPEND_DOUBLE(kCGMouseEventPressure)
			break;
		}
		case kCGEventKeyUp:
		case kCGEventKeyDown:
		{
			CGKeyCode keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
			CGKeyCode swappedKeyCode = NSSwapHostShortToBig(keyCode);
			[eventData appendData:[NSData dataWithBytes:&swappedKeyCode length:sizeof(CGKeyCode)]];
			
			APPEND_INTEGER(kCGKeyboardEventKeyboardType)
			
			UniChar string[MAX_STRING];
			UniCharCount length;
			CGEventKeyboardGetUnicodeString(event, MAX_STRING, &length, string);
			
//			DebugLog(@"OUT string=%@ eventkbt: %d", [NSString stringWithCharacters:string length:length], keyboardType);
			
			UniCharCount swappedLength = NSSwapHostIntToBig(length);
			[eventData appendData:[NSData dataWithBytes:&swappedLength length:sizeof(UniCharCount)]];
			
			UniCharCount i;
			for(i=0; i<length; i++) {
				UniChar c = string[i];
				UniChar swappedC = NSSwapHostShortToBig(c);
				[eventData appendData:[NSData dataWithBytes:&swappedC length:sizeof(UniChar)]];
			}
			break;
		}
		case kCGEventFlagsChanged:
		{
			/* Modifier keys need their keyCode: replaying flags alone makes some
			   applications treat the event as an unknown modifier. */
			CGKeyCode keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
			CGKeyCode swappedKeyCode = NSSwapHostShortToBig(keyCode);
			[eventData appendData:[NSData dataWithBytes:&swappedKeyCode length:sizeof(CGKeyCode)]];
			break;
		}
		default:
			break;
	}
	
	CGEventFlags flags = CGEventGetFlags(event);
	CGEventFlags swappedFlags = NSSwapHostLongLongToBig(flags);
//	DebugLog(@"flags=%lld", flags);
	[eventData appendData:[NSData dataWithBytes:&swappedFlags length:sizeof(CGEventFlags)]];

	return eventData;
}

- (void)_postEventWithEventData:(NSData*)eventData
{
	int pos = 0;
	bool down = false;
	
	CGEventRef event = NULL;
	
	uint64_t swappedAge;
	[eventData _readBytes:&swappedAge withSize:sizeof(uint64_t) atPos:&pos];
	uint64_t age = NSSwapBigLongLongToHost(swappedAge);
	
	int swappedEventType;
	[eventData _readBytes:&swappedEventType withSize:sizeof(int) atPos:&pos];
	CGEventType eventType = NSSwapBigIntToHost(swappedEventType);
	
	switch(eventType) {
		case kCGEventLeftMouseDown:
		case kCGEventLeftMouseUp:
		case kCGEventRightMouseDown:
		case kCGEventRightMouseUp:
		case kCGEventOtherMouseDown:
		case kCGEventOtherMouseUp:
		{
			event = CGEventCreateMouseEvent(_eventSource, eventType, _currentMouseLocation, 0);
			CGEventSetType(event, eventType); // there's a bug on Tiger
			
			READ_INTEGER(kCGMouseEventNumber)
			READ_INTEGER(kCGMouseEventButtonNumber)
			READ_INTEGER(kCGMouseEventClickState)
			READ_INTEGER(kCGMouseEventInstantMouser)
			READ_INTEGER(kCGMouseEventSubtype)
			READ_DOUBLE(kCGMouseEventPressure)
			break;
		}
		case kCGEventMouseMoved:
		case kCGEventLeftMouseDragged:
		case kCGEventRightMouseDragged:
		case kCGEventOtherMouseDragged:
		{			
			event = CGEventCreateMouseEvent(_eventSource, eventType, _currentMouseLocation, 0);
			CGEventSetType(event, eventType); // there's a bug on Tiger
			
			READ_INTEGER(kCGMouseEventNumber)
			READ_INTEGER(kCGMouseEventDeltaX)
			READ_INTEGER(kCGMouseEventDeltaY)
			READ_INTEGER(kCGMouseEventButtonNumber)

			TPMouseDelta mouseDelta;
			mouseDelta.x = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
			mouseDelta.y = CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
			
			[self _updateMouseLocationWithMouseDelta:mouseDelta];
			
			CGEventSetLocation(event, _currentMouseLocation);
			break;
		}
		case kCGEventScrollWheel:
		case NX_ZOOM:
		{
			event = CGEventCreate(_eventSource);
			CGEventSetType(event, eventType); // there's a bug on Tiger
			
			READ_INTEGER(kCGScrollWheelEventDeltaAxis1)
			READ_INTEGER(kCGScrollWheelEventDeltaAxis2)
			READ_INTEGER(kCGScrollWheelEventDeltaAxis3)
			
			if(1) {
				READ_INTEGER(kCGScrollWheelEventScrollPhase)
				READ_INTEGER(kCGScrollWheelEventIsContinuous)
				
				READ_DOUBLE(kCGScrollWheelEventFixedPtDeltaAxis1)
				READ_DOUBLE(kCGScrollWheelEventFixedPtDeltaAxis2)
				READ_DOUBLE(kCGScrollWheelEventFixedPtDeltaAxis3)
				READ_DOUBLE(kCGScrollWheelEventPointDeltaAxis1)
				READ_DOUBLE(kCGScrollWheelEventPointDeltaAxis2)
				READ_DOUBLE(kCGScrollWheelEventPointDeltaAxis3)
			}
			break;
		}
		case kCGEventKeyDown:
			down = true;
		case kCGEventKeyUp:
		{
			CGKeyCode swappedKeyCode, keyCode;
			
			[eventData _readBytes:&swappedKeyCode withSize:sizeof(CGKeyCode) atPos:&pos];
			keyCode = NSSwapBigShortToHost(swappedKeyCode);
			
			event = CGEventCreateKeyboardEvent(_eventSource, keyCode, down);
			CGEventSetType(event, eventType); // there's a bug on Tiger

			READ_INTEGER(kCGKeyboardEventKeyboardType)
			
			UniCharCount swappedLength, length;
			
			[eventData _readBytes:&swappedLength withSize:sizeof(UniCharCount) atPos:&pos];
			length = NSSwapBigIntToHost(swappedLength);
			
			UniChar string[MAX_STRING];
			UniCharCount i;
			for(i=0; i<length; i++) {
				UniChar c, swappedC;
				[eventData _readBytes:&swappedC withSize:sizeof(UniChar) atPos:&pos];
				c = NSSwapBigShortToHost(swappedC);
				string[i] = c;
			}
			
//			DebugLog(@"IN string=%@ eventkbt: %d sourcekbt: %d", [NSString stringWithCharacters:string length:length], keyboardType, CGEventSourceGetKeyboardType(_eventSource));
//			CGEventKeyboardSetUnicodeString(event, length, string);
//
//			if(CGEventSourceGetKeyboardType(_eventSource) != keyboardType)
//				CGEventSourceSetKeyboardType(_eventSource, keyboardType);
			break;
		}
		case kCGEventFlagsChanged:
		{
			CGKeyCode swappedKeyCode, keyCode;
			
			[eventData _readBytes:&swappedKeyCode withSize:sizeof(CGKeyCode) atPos:&pos];
			keyCode = NSSwapBigShortToHost(swappedKeyCode);
			
			event = CGEventCreateKeyboardEvent(_eventSource, keyCode, false);
			CGEventSetType(event, eventType);
			break;
		}
		default:
			break;
	}
	
	if(event != NULL) {
		CGEventFlags swappedFlags, flags;

		[eventData _readBytes:&swappedFlags withSize:sizeof(CGEventFlags) atPos:&pos];
		flags = NSSwapBigLongLongToHost(swappedFlags);
		
		CGEventSetFlags(event, flags);
		
		[self _postEvent:event withTimestamp:[self _timestampForEventAge:age]];
		CFRelease(event);
	}
}


#pragma mark -
#pragma mark Misc

- (BOOL)_shouldSkipFirstEvent:(id)e
{
	CGEventRef event = (__bridge CGEventRef)e;
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

- (NSEvent*)_nsEventFromEvent:(id)event
{
	return [NSEvent eventWithCGEvent:(CGEventRef)event];
}

- (BOOL)_isEmergencyStopEvent:(id)e
{
	CGEventRef event = (__bridge CGEventRef)e;
	if(CGEventGetType(event) != kCGEventKeyDown)
		return NO;
	CGEventFlags flags = CGEventGetFlags(event);
	if((flags & kCGEventFlagMaskShift) == 0)
		return NO;
	if((flags & kCGEventFlagMaskControl) == 0)
		return NO;
	if((flags & kCGEventFlagMaskAlternate) == 0)
		return NO;
	CGKeyCode keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
	if(keyCode != ESC_KEYCODE)
		return NO;
	
	return YES;
}

- (void)warpMouseToPosition:(NSPoint)position
{
	/* The virtual cursor and the event source are owned by the posting queue. */
	dispatch_sync([self _postingQueue], ^{
		[self _postWarpToPosition:position];
	});
}

- (void)_postWarpToPosition:(NSPoint)position
{
	[super warpMouseToPosition:position];
	
	DebugLog(@"warp to %@", NSStringFromPoint(position));
	
	CGEventSourceStateID sourceState;
	
	if(_eventSource != NULL) {
		sourceState = CGEventSourceGetSourceStateID(_eventSource);
	}
	else {
		sourceState = kCGEventSourceStateCombinedSessionState;
	}
	
	CGEventRef event = NULL;
	
	if(CGEventSourceButtonState(sourceState, kCGMouseButtonLeft)) {
		event = CGEventCreateMouseEvent(_eventSource, kCGEventLeftMouseDragged, *(CGPoint*)&position, kCGMouseButtonLeft);
		CGEventSetType(event, kCGEventLeftMouseDragged); // there's a bug on Tiger
	}
	else if(CGEventSourceButtonState(sourceState, kCGMouseButtonRight)) {
		event = CGEventCreateMouseEvent(_eventSource, kCGEventRightMouseDragged, *(CGPoint*)&position, kCGMouseButtonRight);
		CGEventSetType(event, kCGEventRightMouseDragged); // there's a bug on Tiger
	}
	else if(CGEventSourceButtonState(sourceState, kCGMouseButtonCenter)) {
		event = CGEventCreateMouseEvent(_eventSource, kCGEventOtherMouseDragged, *(CGPoint*)&position, kCGMouseButtonCenter);
		CGEventSetType(event, kCGEventOtherMouseDragged); // there's a bug on Tiger
	}
	else {
		event = CGEventCreateMouseEvent(_eventSource, kCGEventMouseMoved, *(CGPoint*)&position, 0);
		CGEventSetType(event, kCGEventMouseMoved); // there's a bug on Tiger
	}
	
	if(event != NULL) {
		[self _postEvent:event];
		CFRelease(event);
	}
}
	
- (void)mouseDownAtPosition:(NSPoint)position
{
	dispatch_sync([self _postingQueue], ^{
		[self _postMouseDownAtPosition:position];
	});
}

- (void)_postMouseDownAtPosition:(NSPoint)position
{
	[super mouseDownAtPosition:position];

	CGEventRef event = CGEventCreateMouseEvent(_eventSource, kCGEventLeftMouseDown, _currentMouseLocation, kCGMouseButtonLeft);
	CGEventSetType(event, kCGEventLeftMouseDown); // there's a bug on Tiger
	if(event != NULL) {
		[self _postEvent:event];
		CFRelease(event);
	}
}

- (void)mouseUpAtPosition:(NSPoint)position
{
	dispatch_sync([self _postingQueue], ^{
		[self _postMouseUpAtPosition:position];
	});
}

- (void)_postMouseUpAtPosition:(NSPoint)position
{
	[super mouseUpAtPosition:position];
	
	CGEventRef event = CGEventCreateMouseEvent(_eventSource, kCGEventLeftMouseUp, _currentMouseLocation, kCGMouseButtonLeft);
	CGEventSetType(event, kCGEventLeftMouseUp); // there's a bug on Tiger
	if(event != NULL) {
		CGEventPost(kCGSessionEventTap, event);
		CFRelease(event);
	}
}

- (BOOL)event:(NSEvent*)event hasRequiredKeyIfNeeded:(BOOL)needed withTag:(NSEventType)tag
{
	if(_eventSource == NULL)
		return [super event:event hasRequiredKeyIfNeeded:needed withTag:tag];
	else {
		if(!needed)
			return YES;
		else {
			CGEventSourceStateID sourceState = CGEventSourceGetSourceStateID(_eventSource);
			CGEventFlags flags = CGEventSourceFlagsState(sourceState);
			unsigned int keyMask = NSEventMaskFromType(tag);
			return ((flags & keyMask) != 0);
		}
	}
}

@end
