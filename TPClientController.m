//
//  TPClientController.m
//  Teleport
//
//  Created by JuL on Wed Dec 03 2003.
//  Copyright (c) 2003-2005 abyssoft. All rights reserved.
//

#import "TPClientController.h"
#import "TPMainController.h"
#import "TPAuthenticationManager.h"
#import "TPEventsController.h"
#import "TPBezelController.h"
#import "TPStatusItemController.h"
#import "TPNetworkConnection.h"
#import "TPTransfersManager.h"
#import "TPPreferencesManager.h"
#import "TPHostAnimationController.h"
#import "TPRemoteHost.h"
#import "TPLocalHost.h"
#import "TPHotBorder.h"
#import "TPMessage.h"

#import "TPHostsManager.h"
#import "TPConnectionsManager.h"

#import "PTHotKeyCenter.h"
#import "PTKeyBroadcaster.h"

#include <ctype.h>
#include <stdlib.h>
#include <stdio.h>

#include <mach/mach_port.h>
#include <mach/mach_interface.h>
#include <mach/mach_init.h>

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>

#define HOTBORDER_SAFE_MARGIN 3

/* How long to wait for the server to acknowledge a control request before
   assuming the connection is stale and retrying on a fresh socket. */
#define CONTROL_REQUEST_TIMEOUT 2.0
#define CONTROL_REQUEST_MAX_RETRIES 1

static TPClientController * _defaultClientController = nil;

@interface TPClientController (Internal)

- (void)_startSleepPrevention;
- (void)_stopSleepPrevention;
- (NSDictionary*)_clientOptionsForRemoteHost:(TPRemoteHost*)remoteHost;
- (BOOL)_requestStartControlOnHost:(TPRemoteHost*)remoteHost atLocation:(NSPoint)location withDraggingInfo:(id<NSDraggingInfo>)draggingInfo isRetry:(BOOL)isRetry;
- (void)_scheduleControlRequestTimer;
- (void)_cancelControlRequestTimer;
- (void)_controlRequestDidTimeout:(NSTimer*)timer;

@end

@implementation TPClientController

+ (TPClientController*)defaultController
{
	if(_defaultClientController == nil)
		_defaultClientController = [[TPClientController alloc] init];
	
	return _defaultClientController;
}

- (instancetype) init
{
	self = [super init];
	
	_hotBorders = [[NSMutableDictionary alloc] init];
	_hotKeys = [[NSMutableDictionary alloc] init];
	_sleepService = IO_OBJECT_NULL;
	_state = TPClientIdleState;
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateTriggers:) name:TPHostDidUpdateNotification object:nil];
	
	return self;
}



#pragma mark -
#pragma mark Hot borders

- (TPHotBorder*)currentHotBorder
{
	TPNetworkConnection * currentConnection = [self currentConnection];
	if(currentConnection == nil)
		return nil;
	
	TPRemoteHost * host = [currentConnection connectedHost];
	if(host == nil)
		return nil;
	
	return _hotBorders[[host identifier]];
}

- (void)_updateTriggersForHost:(TPRemoteHost*)host showVisualHint:(BOOL)showVisualHint
{
	if(![host isKindOfClass:[TPRemoteHost class]])
		return;
	
	BOOL canControl = [(TPMainController*)[NSApp delegate] canControlHostWithIdentifier:[host identifier]];
	BOOL canWakeOnLAN = [host isInState:TPHostPeeredOfflineState] && [host hasValidMACAddress] && [[TPPreferencesManager sharedPreferencesManager] boolForPref:WAKE_ON_LAN];
	BOOL shouldEnableTriggers = canControl && (([host isInState:TPHostPeeredOnlineState | TPHostControlledState]) || canWakeOnLAN);
	BOOL shouldActivateHotBorder = ![host isInState:TPHostControlledState];
	NSString * identifier = [host identifier];
	
	TPHotBorder * hotBorder = _hotBorders[identifier];
	PTHotKey * hotKey = _hotKeys[identifier];
	
	DebugLog(@"updating hot border %@ for host %@: show: %d activate: %d", hotBorder, host, shouldEnableTriggers, shouldActivateHotBorder);
	
	// Hot border
	if(hotBorder != nil) {
		if(shouldEnableTriggers) {
			[hotBorder updateWithRepresentingRect:[host adjustedHostRect] inRect:[[host localScreen] frame]];
			
			if(shouldActivateHotBorder && [hotBorder state] == TPHotBorderInactiveState) {
				[hotBorder delayedActivate];
			}
			else if(!shouldActivateHotBorder && [hotBorder state] != TPHotBorderInactiveState) {
				[hotBorder deactivate];
			}
		}
		else {
			DebugLog(@"remove hot border %@ with id %@", hotBorder, identifier);
			[hotBorder deactivate];
			[self takeDownHotBorder:hotBorder];
			[hotBorder close];
			[_hotBorders removeObjectForKey:identifier];
		}
	}
	else if(shouldEnableTriggers) {
		hotBorder = [TPHotBorder hotBorderRepresentingRect:[host adjustedHostRect] inRect:[[host localScreen] frame]];
		[hotBorder setDelegate:self];
		[hotBorder setIdentifier:identifier];
		[self setupHotBorder:hotBorder forHost:host];
		_hotBorders[identifier] = hotBorder;
		
		if(shouldActivateHotBorder) {
			[hotBorder delayedActivate];
		}
		
		DebugLog(@"add hot border %@ with id %@", hotBorder, identifier);
	}
	
	if(showVisualHint && shouldEnableTriggers && shouldActivateHotBorder && [host isInState:TPHostPeeredOnlineState] && [host previousHostState] != TPHostControlledState) {
		[[TPHostAnimationController controller] showAppearanceAnimationForHost:host];
	}
	
	// Hot key
	PTKeyCombo * keyCombo = [host keyCombo];
	BOOL isValidKeyCombo = (keyCombo != nil) && ![keyCombo isClearCombo] && [keyCombo isValidHotKeyCombo];
	BOOL enableKeyCombo = shouldEnableTriggers && isValidKeyCombo;

	if(enableKeyCombo) {
		if(hotKey != nil && ![[hotKey keyCombo] isEqual:keyCombo]) {
			[[PTHotKeyCenter sharedCenter] unregisterHotKey:hotKey];
			hotKey = nil;
		}
		
		if(hotKey == nil) {
			hotKey = [[PTHotKey alloc] initWithIdentifier:identifier keyCombo:keyCombo];
			[hotKey setTarget:self];
			[hotKey setAction:@selector(hotKeyPressed:)];
			[[PTHotKeyCenter sharedCenter] registerHotKey:hotKey];
			_hotKeys[identifier] = hotKey;
		}
	}
	else if(hotKey != nil) {
		[[PTHotKeyCenter sharedCenter] unregisterHotKey:hotKey];		
		[_hotKeys removeObjectForKey:identifier];
	}
}

- (void)updateTriggers:(NSNotification*)notification
{
	TPRemoteHost * host = [notification object];
	[self _updateTriggersForHost:host showVisualHint:YES];
}

- (void)updateTriggersAndShowVisualHint:(BOOL)showVisualHint
{
#if DEBUG_GENERAL
	DebugLog(@"client: startWaiting");
#endif
	
	NSArray * hosts = [[TPHostsManager defaultManager] hostsWithState:TPHostAllStates];
	NSEnumerator * hostEnum = [hosts objectEnumerator];
	TPRemoteHost * host;
	
	while((host = [hostEnum nextObject]) != nil) {
		[self _updateTriggersForHost:host showVisualHint:showVisualHint];
	}
}

- (float)hotBorderSwitchDelay:(TPHotBorder*)hotBorder
{
	TPRemoteHost * remoteHost = [[TPHostsManager defaultManager] hostWithIdentifier:[hotBorder identifier]];
	if(![[remoteHost optionForKey:DELAYED_SWITCH] boolValue]) {
		return 0.0;
	}
	else {
		return [[remoteHost optionForKey:SWITCH_DELAY] floatValue];
	}
}

- (BOOL)hotBorder:(TPHotBorder*)hotBorder canFireWithEvent:(NSEvent*)event
{
	if(![(TPMainController*)[NSApp delegate] canControlHostWithIdentifier:[hotBorder identifier]])
		return NO;
	
#if ! LEGACY_BUILD
	NSArray * applicationsIgnoringTeleport = [[TPPreferencesManager sharedPreferencesManager] valueForPref:APPLICATIONS_DISABLING_TELEPORT];
	if(applicationsIgnoringTeleport != nil) {
		NSDictionary * activeApplication = [[NSWorkspace sharedWorkspace] activeApplication];
		NSString * currentApplicationIdentifier = activeApplication[@"NSApplicationBundleIdentifier"];
		if(currentApplicationIdentifier != nil) {
			for(NSString * ignoringApp in applicationsIgnoringTeleport) {
				if([ignoringApp isEqualToString:currentApplicationIdentifier]) {
					DebugLog(@"Ignoring switch because of ignoring app: %@", ignoringApp);
					return NO;
				}
			}
		}
	}
#endif
	
	TPRemoteHost * remoteHost = [[TPHostsManager defaultManager] hostWithIdentifier:[hotBorder identifier]];
	BOOL requireKey = [[remoteHost optionForKey:REQUIRE_KEY] boolValue];
	int keyTag = [[remoteHost optionForKey:SWITCH_KEY_TAG] intValue];
	return [[TPEventsController defaultController] event:event hasRequiredKeyIfNeeded:requireKey withTag:keyTag];
}

- (BOOL)hotBorder:(TPHotBorder*)hotBorder firedAtLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo
{
	TPRemoteHost * remoteHost = [[TPHostsManager defaultManager] hostWithIdentifier:[hotBorder identifier]];
	
	if([remoteHost hostState] == TPHostPeeredOnlineState) {

#if DEBUG_BUILD
		BOOL isLocalHost = [remoteHost isEqual:[TPLocalHost localHost]];
		if(!isLocalHost) {
#endif
			if(![self requestStartControlOnHost:remoteHost atLocation:location withDraggingInfo:draggingInfo]) {
				[hotBorder activate];
			}
#if DEBUG_BUILD
		}
#endif

		
		return [super hotBorder:hotBorder firedAtLocation:location withDraggingInfo:draggingInfo];
	}
	else if([remoteHost hostState] == TPHostPeeredOfflineState && [remoteHost hasValidMACAddress] && [[TPPreferencesManager sharedPreferencesManager] boolForPref:WAKE_ON_LAN]) {
		if(![[TPConnectionsManager manager] wakeUpHost:remoteHost])
			[remoteHost invalidateMACAddress];
		else
			[hotBorder activate];
	}
	
	return NO;
}

- (void)hotKeyPressed:(PTHotKey*)hotKey
{
	NSString * identifier = [hotKey identifier];
	TPRemoteHost * remoteHost = [[TPHostsManager defaultManager] hostWithIdentifier:identifier];
	TPHotBorder * hotBorder = _hotBorders[identifier];
	
	if([remoteHost hostState] == TPHostPeeredOnlineState) {
		NSPoint location = NSMakePoint(-1.0, -1.0);
#if DEBUG_BUILD
		BOOL isLocalHost = [remoteHost isEqual:[TPLocalHost localHost]];
		
		if(!isLocalHost) {
			[self requestStartControlOnHost:remoteHost atLocation:location withDraggingInfo:nil];
		}
#else
		[self requestStartControlOnHost:remoteHost atLocation:location withDraggingInfo:nil];	
#endif
		
		if(hotBorder != nil) {
			[super hotBorder:hotBorder firedAtLocation:NSZeroPoint withDraggingInfo:nil];
		}
	}
	else if([remoteHost hostState] == TPHostPeeredOfflineState && [remoteHost hasValidMACAddress] && [[TPPreferencesManager sharedPreferencesManager] boolForPref:WAKE_ON_LAN]) {
		if(![[TPConnectionsManager manager] wakeUpHost:remoteHost])
			[remoteHost invalidateMACAddress];
		else if(hotBorder != nil) {
			[hotBorder activate];
		}
	}
}


#pragma mark -
#pragma mark Start control

- (BOOL)requestStartControlOnHost:(TPRemoteHost*)remoteHost atLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo
{
	return [self _requestStartControlOnHost:remoteHost atLocation:location withDraggingInfo:draggingInfo isRetry:NO];
}

- (BOOL)_requestStartControlOnHost:(TPRemoteHost*)remoteHost atLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo isRetry:(BOOL)isRetry
{
	DebugLog(@"request start control on %@, _state=%ld", remoteHost, (long)_state);
	
	if(remoteHost == nil || [remoteHost hostState] != TPHostPeeredOnlineState || _state != TPClientIdleState)
		return NO;
	
	if(!isRetry)
		_controlRequestRetries = 0;
	
	_pendingControlHost = remoteHost;
	_pendingControlLocation = location;
	
	NSMutableDictionary * infoDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
									  [NSValue valueWithPoint:location], TPMousePositionKey,
									  nil];
	
	[self addDraggingInfo:draggingInfo toInfoDict:infoDict];
	
	/* Do the fake mouse up */
	if(draggingInfo != nil) {
		[[TPEventsController defaultController] mouseUpAtPosition:[NSEvent mouseLocation]];
	}
	
	/* Re-use existing connection if possible */
	BOOL started = NO;
	TPNetworkConnection * currentConnection = [self currentConnection];
	if(currentConnection != nil) {
		if([currentConnection isValidForHost:remoteHost] &&
		   [self sendStartControlRequestForConnection:currentConnection withInfoDict:infoDict]) {
			started = YES;
		}
		else {
			/* The cached connection is no longer usable (stale socket,
			   disconnect in flight): start over with a fresh one. */
			[self setCurrentConnection:nil];
		}
	}
	
	if(!started && [[TPConnectionsManager manager] connectToHost:remoteHost withDelegate:self infoDict:infoDict])
		started = YES;
	
	if(!started)
		return NO;
	
	/* Stay in the connecting state until the server answers. Otherwise every
	   extra edge hit while the network is slow sends another control request,
	   and the server rebuilds (and previously leaked) its return border. */
	_state = TPClientConnectingState;
	
	return YES;
}

- (void)_scheduleControlRequestTimer
{
	[self _cancelControlRequestTimer];
	
	_controlRequestTimer = [NSTimer timerWithTimeInterval:CONTROL_REQUEST_TIMEOUT
												   target:self
												 selector:@selector(_controlRequestDidTimeout:)
												 userInfo:nil
												  repeats:NO];
	[[NSRunLoop mainRunLoop] addTimer:_controlRequestTimer forMode:NSRunLoopCommonModes];
}

- (void)_cancelControlRequestTimer
{
	[_controlRequestTimer invalidate];
	_controlRequestTimer = nil;
}

- (void)_controlRequestDidTimeout:(NSTimer*)timer
{
	_controlRequestTimer = nil;
	
	if(_state != TPClientConnectingState)
		return;
	
	TPRemoteHost * host = _pendingControlHost;
	NSPoint location = _pendingControlLocation;
	
	DebugLog(@"control request timed out (retries=%ld)", (long)_controlRequestRetries);
	
	/* The connection is either stale (typical after sleep or a network roam)
	   or the peer stopped answering. Drop it so the retry starts from a fresh
	   socket instead of waiting for the kernel to give up. */
	[self setCurrentConnection:nil];
	_state = TPClientIdleState;
	
	if(_controlRequestRetries < CONTROL_REQUEST_MAX_RETRIES && host != nil) {
		_controlRequestRetries++;
		if(![self _requestStartControlOnHost:host atLocation:location withDraggingInfo:nil isRetry:YES]) {
			_controlRequestRetries = 0;
			_pendingControlHost = nil;
			[self updateTriggersAndShowVisualHint:NO];
		}
	}
	else {
		_controlRequestRetries = 0;
		_pendingControlHost = nil;
		[self updateTriggersAndShowVisualHint:NO];
	}
}

- (BOOL)sendStartControlRequestForConnection:(TPNetworkConnection*)connection withInfoDict:(NSDictionary*)infoDict
{
	TPRemoteHost * controlledHost = [connection connectedHost];
	
	NSPoint mousePosition = [infoDict[TPMousePositionKey] pointValue];
	
	[self setCurrentConnection:connection];
	
	NSRect clientScreenRect = [[controlledHost localScreen] frame];
	NSRect serverScreenRect = [controlledHost adjustedHostRect];
	
	NSRect screenPlacement = clientScreenRect;
	screenPlacement.origin.x -= NSMinX(serverScreenRect);
	screenPlacement.origin.y -= NSMinY(serverScreenRect);	

	NSRect hotRect = [TPHotBorder hotRectWithRepresentingRect:clientScreenRect inRect:serverScreenRect];
	
	DebugLog(@"clientRect=%@ serverRect=%@ hotRect=%@ mousePosition=%@", NSStringFromRect(clientScreenRect), NSStringFromRect(serverScreenRect), NSStringFromRect(hotRect), NSStringFromPoint(mousePosition));
	
//	NSPoint mousePosition;
//	mousePosition.x = NSMinX(hotRect) + mouseLocation.x - NSMinX(serverScreenRect);
//	mousePosition.y = NSHeight(serverScreenRect) - (NSMinY(hotRect) + mouseLocation.y - NSMinY(serverScreenRect));
	
	_infoDict = infoDict; // XXX do this better
	
	/* Initiate connection */
	NSDictionary * clientOptions = [self _clientOptionsForRemoteHost:controlledHost];
	TPMessage * message = [TPMessage messageWithType:TPControlRequestMsgType
										 andInfoDict:@{TPScreenIndexKey: [NSData dataWithInt:[controlledHost sharedScreenIndex]],
													  TPScreenPlacementKey: [NSData dataWithRect:screenPlacement],
													  TPMousePositionKey: [NSData dataWithPoint:mousePosition],
													  TPSwitchOptionsKey: clientOptions}];
	
	if(![[self currentConnection] sendMessage:message])
		return NO;
	
	/* The request is on the wire: wait for the acknowledgement. A stale TCP
	   connection can swallow it silently, so never wait indefinitely. */
	[self _scheduleControlRequestTimer];
	
	return YES;
}

- (void)startControl
{
#if DEBUG_GENERAL
	DebugLog(@"client: startControl");
#endif
	
	/* A duplicated acknowledgement (e.g. from a retried request) must not
	   rebuild the session or replay the switch sound. */
	if(_state == TPClientControllingState) {
		[self _cancelControlRequestTimer];
		return;
	}
	
	TPRemoteHost * controlledHost = [[self currentConnection] connectedHost];
	
	/* Update status menu */
	[[TPStatusItemController defaultController] updateWithStatus:TPStatusControlling host:controlledHost];
	
	/* Change state of controlled host */
	[controlledHost setHostState:TPHostControlledState];

	/* Deactivate hot borders */
	[self updateTriggersAndShowVisualHint:NO];
	
	/* Activate bezel */
	if(![[TPPreferencesManager sharedPreferencesManager] boolForPref:HIDE_CONTROL_BEZEL]) {
		[[TPBezelController defaultController] showBezelWithControlledHost:controlledHost];
	}
	
	/* Play sound */
	if([[TPPreferencesManager sharedPreferencesManager] boolForPref:PLAY_SWITCH_SOUND]) {
		[self playSwitchSound];
	}
	
	/* Begin transfers */
	[self beginTransfersWithInfoDict:_infoDict];
	_infoDict = nil;
	
	/* Activate events recorder */
	[self updateEventsController];
	[[self eventsController] startGettingEventsForListener:self onScreen:[controlledHost localScreen]];
	
	/* Start preventing the Mac to go to sleep */
	[self _startSleepPrevention];
	
	[self _cancelControlRequestTimer];
	_controlRequestRetries = 0;
	_pendingControlHost = nil;
	
	_state = TPClientControllingState;
}

- (NSDictionary*)_clientOptionsForRemoteHost:(TPRemoteHost*)remoteHost
{
	NSString * optionKeys[] = {
		REQUIRE_KEY,
		SWITCH_WITH_DOUBLE_TAP,
		SHARE_PASTEBOARD,
		DELAYED_SWITCH,
		SWITCH_DELAY,
		LIMIT_PASTEBOARD_SIZE,
		MAX_PASTEBOARD_SIZE,
		SWITCH_KEY_TAG,
		REQUIRE_PASTEBOARD_KEY,
		PASTEBOARD_KEY_TAG,
		SYNC_FIND_PASTEBOARD,
		DOUBLE_TAP_INTERVAL,
		COPY_FILES
	};
	
	int count = sizeof(optionKeys) / sizeof(NSString*);
	int i;
	
	NSMutableDictionary * clientOptions = [NSMutableDictionary dictionaryWithCapacity:count];
	for(i=0; i<count; i++) {
		NSString * optionKey = optionKeys[i];
		id value = [remoteHost optionForKey:optionKey];
		
		if([optionKey isEqualToString:REQUIRE_KEY]) {
			if(![[TPPreferencesManager sharedPreferencesManager] boolForPref:SYNC_MODIFIERS]) {
				value = @NO;
			}
		}
		
		if(value != nil) {
			[clientOptions setValue:value forKey:optionKey];
		}
	}
	
	return clientOptions;
}

- (void)_updateActivity
{
	UpdateSystemActivity(NetActivity);
}


#pragma mark -
#pragma mark Stop control

- (void)_nudgePositionInward:(NSPoint*)position forHotBorder:(TPHotBorder*)hotBorder
{
	if(position == NULL || hotBorder == nil)
		return;
	
	NSScreen * screen = [hotBorder screen];
	if(screen == nil)
		return;
	
	NSArray * screens = [NSScreen screens];
	if([screens count] == 0)
		return;
	
	CGFloat mainHeight = NSHeight([[screens objectAtIndex:0] frame]);
	NSRect screenFrame = [screen frame];
	
	/* Position is expressed with a top-left origin (see _currentMouseLocation). */
	NSRect flippedScreenFrame = NSMakeRect(NSMinX(screenFrame),
										   mainHeight - NSMaxY(screenFrame),
										   NSWidth(screenFrame),
										   NSHeight(screenFrame));
	
	CGFloat inset = BORDER_SIZE + 2.0;
	position->x = MIN(MAX(position->x, NSMinX(flippedScreenFrame) + inset), NSMaxX(flippedScreenFrame) - inset);
	position->y = MIN(MAX(position->y, NSMinY(flippedScreenFrame) + inset), NSMaxY(flippedScreenFrame) - inset);
}

- (void)requestedStopControlWithInfoDict:(NSDictionary*)infoDict
{
	TPRemoteHost * controlledHost = [[self currentConnection] connectedHost];

	[[self currentConnection] sendMessage:[TPMessage messageWithType:TPControlStopMsgType]];
	
	TPEventsController * eventsController = [self eventsController];
	
	[self stopControlWithDisconnect:DISCONNECT_WHEN_STOP_CONTROL];
	
	/* Warp the mouse cursor to the exiting point */
	NSPoint mousePosition = [infoDict[TPMousePositionKey] pointValue];
	TPHotBorder * hotBorder = _hotBorders[[controlledHost identifier]];
	mousePosition = [hotBorder screenPointFromLocalPoint:mousePosition flipped:YES];
	
	/* Land a few points inside the screen instead of exactly on the edge:
	   sitting inside the trigger strip prevents the border from arming and
	   makes the next switch attempt fail until the cursor leaves the strip. */
	[self _nudgePositionInward:&mousePosition forHotBorder:hotBorder];
	
	if([hotBorder state] != TPHotBorderInactiveState) {
		[hotBorder deactivate];
		[eventsController warpMouseToPosition:mousePosition];
		[hotBorder delayedActivate];
	}
	else {
		[eventsController warpMouseToPosition:mousePosition];
	}
	
	[[self eventsController] cleanupGettingEvents];
}

- (void)stopControl
{
	[super stopControl];
	[[self eventsController] cleanupGettingEvents];
}

- (void)stopControlWithDisconnect:(BOOL)disconnect
{
#if DEBUG_GENERAL
	DebugLog(@"client: stopControl");
#endif
	
	if(_state == TPClientControllingState) {
		/* Deactivate events recorder */
		[[self eventsController] stopGettingEvents];
		
		/* Deactivate bezel */
		[[TPBezelController defaultController] hideBezel];
		
		/* Update status menu */
		[[TPStatusItemController defaultController] updateWithStatus:TPStatusIdle host:nil];
		
		/* Change state of controlled host */
		[[[self currentConnection] connectedHost] setHostState:TPHostPeeredOnlineState];
		
		/* Stop preventing sleep */
		[self _stopSleepPrevention];
		
		/* Play sound */
		if([[TPPreferencesManager sharedPreferencesManager] boolForPref:PLAY_SWITCH_SOUND]) {
			[self playSwitchSound];
		}
	}
	
	_state = TPClientIdleState;
	
	[self _cancelControlRequestTimer];
	_controlRequestRetries = 0;
	_pendingControlHost = nil;
	
	/* Update hot borders */
	[self updateTriggersAndShowVisualHint:NO];
	
	[super stopControlWithDisconnect:disconnect];
}

- (BOOL)isControlling
{
	return (_state == TPClientControllingState);
}


#pragma mark -
#pragma mark Sleep management

void TPSleepCallback(void * refCon, io_service_t service, natural_t messageType, void * messageArgument);

- (void)_startSleepPrevention
{
	if(_sleepService == IO_OBJECT_NULL) {
		_sleepService = IORegisterForSystemPower((__bridge void *)(self), &_sleepNotifyPortRef, TPSleepCallback, &_sleepNotifier);
		
		if(_sleepService == IO_OBJECT_NULL) {
			NSLog(@"IORegisterForSystemPower failed");
		}
		else {
			CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(_sleepNotifyPortRef), kCFRunLoopCommonModes);
		}
	}
}

- (void)_stopSleepPrevention
{
	if(_sleepService != IO_OBJECT_NULL) {
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(_sleepNotifyPortRef), kCFRunLoopCommonModes);
		IONotificationPortDestroy(_sleepNotifyPortRef);
		_sleepNotifyPortRef = NULL;
		
		IODeregisterForSystemPower(&_sleepNotifier);
		_sleepNotifier = IO_OBJECT_NULL;
		
		IOServiceClose(_sleepService);
		_sleepService = IO_OBJECT_NULL;
	}
}

void TPSleepCallback(void * refCon, io_service_t service, natural_t messageType, void * messageArgument)
{
	TPClientController * controller = (__bridge TPClientController*)refCon;
	io_connect_t sleepService = controller->_sleepService;
	
	switch(messageType) {
		case kIOMessageCanSystemSleep:
			DebugLog(@"Preventing sleep");
			IOCancelPowerChange(sleepService, (long)messageArgument);
			break;
		case kIOMessageSystemWillSleep:
			IOAllowPowerChange(sleepService, (long)messageArgument);
			break;
		default:
			break;
	}
}


#pragma mark -
#pragma mark Events listener

- (void)gotEventWithEventData:(NSData*)eventData
{
	//DebugLog(@"got event with event data (%d)", [eventData length]);
	[[self currentConnection] sendMessage:[TPMessage messageWithType:TPEventMsgType andData:eventData]];
}

- (void)gotEmergencyStopEvent
{
	if([NSThread isMainThread])
		[self stopControl];
	else
		dispatch_async(dispatch_get_main_queue(), ^{
			[self stopControl];
		});
}

- (BOOL)isStopControlEvent:(NSEvent*)event
{
	if([event type] == NSKeyDown) {
		TPRemoteHost * connectedHost = [[self currentConnection] connectedHost];
		PTKeyCombo * keyCombo = [connectedHost keyCombo];
		
		if(keyCombo != nil) {
			if(([keyCombo keyCode] == [event keyCode]) && ([keyCombo modifiers] == [PTKeyBroadcaster cocoaModifiersAsCarbonModifiers:[event modifierFlags]])) {
				return YES;
			}
		}		
	}
	
	return NO;
}

- (BOOL)shouldStopWithEvent:(NSEvent*)event
{
	if([self isStopControlEvent:event]) {
		[self stopControlWithDisconnect:DISCONNECT_WHEN_STOP_CONTROL];
		return YES;
	}
	
	return NO;
}


#pragma mark -
#pragma mark Connection

- (void)connectionToServerSucceeded:(TPNetworkConnection*)connection infoDict:(NSDictionary*)infoDict
{
	if(_state != TPClientConnectingState) {
		/* Late success from an attempt that already timed out and was
		   abandoned; do not start a second control session. */
		[connection disconnect];
		return;
	}
	
	if(![self sendStartControlRequestForConnection:connection withInfoDict:infoDict]) {
		/* The connection cannot carry the request: fail the attempt instead of
		   leaving the client stuck in the connecting state. */
		[self setCurrentConnection:nil];
		[self _cancelControlRequestTimer];
		_controlRequestRetries = 0;
		_pendingControlHost = nil;
		_state = TPClientIdleState;
		[self updateTriggersAndShowVisualHint:NO];
	}
}

- (void)connectionToServerFailed:(TPRemoteHost*)host infoDict:(NSDictionary*)infoDict
{
	if (_state == TPClientConnectingState) {
		/* Reset before showing the modal alert so the request watchdog cannot
		   fire while the sheet is up. */
		[self _cancelControlRequestTimer];
		_controlRequestRetries = 0;
		_pendingControlHost = nil;
		_state = TPClientIdleState;
		[self updateTriggersAndShowVisualHint:NO];
		
		NSString * msgTitle = [NSString stringWithFormat:NSLocalizedString(@"Connection to \\U201C%@\\U201D failed.", @"Title for connection failure"), [host computerName]];
		NSAlert * alert = [NSAlert alertWithMessageText:msgTitle defaultButton:NSLocalizedString(@"OK", nil) alternateButton:nil otherButton:nil informativeTextWithFormat:NSLocalizedString(@"The server may be down, or an encryption problem may have occured. If encryption is enabled, please check that the certificate algorithms match.", nil)];
		[(TPMainController*)[NSApp delegate] presentAlert:alert];
	}
}

- (void)connection:(TPNetworkConnection*)connection receivedMessage:(TPMessage*)message
{
	TPMsgType type = [message msgType];
	
#if DEBUG_GENERAL
	DebugLog(@"master receive msg %ld", type);
#endif
	switch(type) {
		case TPControlSuccessMsgType:
			[self startControl];
			break;
		case TPControlFailureMsgType:
		{
			TPRemoteHost * controlledHost = [[self currentConnection] connectedHost];
			
			[controlledHost setHostState:TPHostSharedState];
			
			/* A rejected request must not leave the client stuck in the
			   connecting state: every further switch would be ignored. Reset
			   before the alert so the watchdog cannot fire while it is up. */
			[self _cancelControlRequestTimer];
			_controlRequestRetries = 0;
			_pendingControlHost = nil;
			_state = TPClientIdleState;
			[self updateTriggersAndShowVisualHint:NO];
			
			NSString * msgTitle = [NSString stringWithFormat:NSLocalizedString(@"Host \\U201C%@\\U201D rejected control.", @"Title for control failure"), [controlledHost computerName]];
			NSAlert * alert = [NSAlert alertWithMessageText:msgTitle defaultButton:NSLocalizedString(@"Yes", nil) alternateButton:NSLocalizedString(@"No", nil) otherButton:nil informativeTextWithFormat:NSLocalizedString(@"The host has probably removed this Mac from its trusted hosts list. Do you want to ask for trust again?", nil)];
			int result = [(TPMainController*)[NSApp delegate] presentAlert:alert];
			if(result == NSAlertDefaultReturn) {
				controlledHost = [[TPHostsManager defaultManager] hostWithIdentifier:[controlledHost identifier]];
				[[TPAuthenticationManager defaultManager] requestAuthenticationOnHost:controlledHost];
			}
			
			break;
		}
		case TPControlStopMsgType:
		{
			[self requestedStopControlWithInfoDict:[message infoDict]];
			break;
		}
		default:
			[super connection:connection receivedMessage:message];
	}
}

@end
