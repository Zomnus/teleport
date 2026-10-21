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

#include <Carbon/Carbon.h>

#define DEBUG_EVENTTAP 0
#define MAX_STRING 20

void CGSSetConnectionProperty(int, int, CFStringRef, CFBooleanRef);
int _CGSDefaultConnection();

static TPEventTapsController * _eventTapsController = nil;

/* Temporary self-test hooks (removed after validation). */
@interface TPTapSelfTestListener : NSObject <TPEventsListener>
@property (nonatomic, weak) TPEventTapsController * controller;
@end

@implementation TPTapSelfTestListener
- (void)gotEventWithEventData:(NSData*)eventData {
    self.controller.selfTestEventCount = self.controller.selfTestEventCount + 1;
}
- (void)gotEmergencyStopEvent {}
- (BOOL)shouldStopWithEvent:(NSEvent*)event { return NO; }
- (BOOL)isStopControlEvent:(NSEvent*)event { return NO; }
@end

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

- (BOOL)_shouldSkipFirstEvent:(id)e;
- (BOOL)_isEmergencyStopEvent:(id)e;

@end

@implementation TPEventTapsController

static void setCursorVisibility(BOOL visible) {
	static CGError error;
	if (visible) {
		error = CGDisplayShowCursor(kCGDirectMainDisplay);
	} else {
		error = CGDisplayHideCursor(kCGDirectMainDisplay);
	}
	DebugLog(@"setCursorVisibility: %@ -> %@", @(visible), @(error));

	if (error != kCGErrorSuccess) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			if (error != kCGErrorSuccess) {
				setCursorVisibility(visible);
			}
		});
	}
}

+ (TPEventsController*)defaultController
{
	if(_eventTapsController == nil)
		_eventTapsController = [[TPEventTapsController alloc] init];
	return _eventTapsController;
}

static CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
	TPEventTapsController * self = (__bridge TPEventTapsController*)refcon;
	
#if DEBUG_EVENTTAP
	NSLog(@"Callback: %@", [TPEventTapsController _eventNameFromType:type]);
#endif

	if(type >= kCGEventTapDisabledByTimeout) {
		[self _startGettingsEvents];
		return NULL;
	}
	
	if(![[TPClientController defaultController] isControlling] && !self->_selfTestActive) {
		/* Never touch AppKit or the run loop from inside the tap callback:
		   hand control back to the main thread. */
		[self _requestStopFromCallback];
		return NULL;
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
	
	setCursorVisibility(NO);
	[self invalidateScreenCache];
	
	if(_eventPort != NULL) {
		[self _startGettingsEvents];
		return;
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
		[self _installEventTapOnRunLoop:CFRunLoopGetCurrent() mode:kCFRunLoopCommonModes];
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
	@synchronized(self) {
		if(_stopRequestedFromCallback)
			return;
		_stopRequestedFromCallback = YES;
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		@synchronized(self) {
			_stopRequestedFromCallback = NO;
		}
		[self stopGettingEvents];
	});
}

- (void)runSelfTestForSeconds:(double)seconds
{
	_selfTestActive = YES;
	self.selfTestEventCount = 0;
	
	TPTapSelfTestListener * listener = [[TPTapSelfTestListener alloc] init];
	listener.controller = self;
	
	[self startGettingEventsForListener:listener onScreen:[NSScreen mainScreen]];
	
	/* Feed synthetic events so the capture -> encode -> listener path is
	   exercised even when nobody touches the mouse. */
	for(int i = 0; i < 5; i++) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.4 + 0.2 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			CGEventRef synthetic = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(300 + 20 * i, 300), 0);
			if(synthetic != NULL) {
				CGEventPost(kCGHIDEventTap, synthetic);
				CFRelease(synthetic);
			}
		});
	}
	
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self stopGettingEvents];
		self->_selfTestActive = NO;
		NSLog(@"TAP SELFTEST RESULT: events=%ld threadAlive=%d", (long)self.selfTestEventCount, self->_eventThread != nil);
		[NSApp terminate:nil];
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

- (void)_stopGettingEvents
{
	if([NSThread currentThread] == _eventThread) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _stopGettingEvents];
		});
		return;
	}
	
	if(_eventPort != NULL && CGEventTapIsEnabled(_eventPort)) {
		CGEventTapEnable(_eventPort, false);
	}
	
	BOOL mainThreadFallback = (_eventThread == nil && _eventPort != NULL);
	
	if(_eventThread != nil && _eventRunLoop != NULL) {
		CFRunLoopStop(_eventRunLoop);
		CFRunLoopWakeUp(_eventRunLoop);
		
		[_threadCondition lock];
		NSDate * deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
		while(_eventThread != nil && [deadline timeIntervalSinceNow] > 0)
			[_threadCondition waitUntilDate:deadline];
		BOOL stillRunning = (_eventThread != nil);
		[_threadCondition unlock];
		
		if(stillRunning)
			NSLog(@"teleport: event tap thread did not stop in time");
	}
	else if(mainThreadFallback) {
		[self _teardownEventTap];
	}
	
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
		
	setCursorVisibility(YES);
}


#pragma mark -
#pragma mark Posting events

- (void)startPostingEvents
{
	_eventSource = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
	_mouseLocationValid = NO;
	[self invalidateScreenCache];
}

- (void)stopPostingEvents
{
	if(_eventSource != NULL) {
		CFRelease(_eventSource);
		_eventSource = NULL;
	}
	
	_mouseLocationValid = NO;
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
			event = CGEventCreate(_eventSource);
			CGEventSetType(event, eventType); // there's a bug on Tiger
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
