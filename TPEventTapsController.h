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
}

@end
