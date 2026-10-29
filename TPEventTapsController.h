//
//  TPEventTapsController.h
//  teleport
//
//  Created by JuL on 09/11/05.
//  Copyright 2005 abyssoft. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "TPEventsController.h"

@interface TPEventTapsController : TPEventsController
{
	CFMachPortRef _eventPort;
	CFRunLoopSourceRef _eventSourceRef;
	CGEventSourceRef _eventSource;
	
	NSThread * _eventThread;
	CFRunLoopRef _eventRunLoop;
	NSCondition * _threadCondition;
	BOOL _tapInstalled;
	BOOL _tapInstallSucceeded;
	BOOL _stopRequestedFromCallback;
	BOOL _tapOnMainRunLoop;
	NSInteger _sessionGeneration;
	NSTimer * _tapHealthTimer;
	
	/* How many times we hid the local cursor: some apps and full-screen spaces
	   show it again while we are controlling, so the count has to be balanced
	   when control ends. */
	NSInteger _cursorHidesIssued;
}

/* Rebuilds the capture tap after the system wakes. The system can invalidate a
   session tap while the screen is locked, and CGEventTapEnable cannot revive an
   invalidated port, so the tap thread is disposed of and a fresh tap is
   installed on the next capture session. */
- (void)rebuildTapAfterWake;

@end
