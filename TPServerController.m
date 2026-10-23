//
//  TPServerController.m
//  Teleport
//
//  Created by JuL on Thu Dec 04 2003.
//  Copyright (c) 2003-2005 abyssoft. All rights reserved.
//

#import "TPServerController.h"
#import "TPMainController.h"
#import "TPClientController.h"
#import "TPAuthenticationManager.h"
#import "TPEventsController.h"
#import "TPNetworkConnection.h"
#import "TPTransfersManager.h"
#import "TPHotBorder.h"
#import "TPMessage.h"
#import "TPLocalHost.h"
#import "TPRemoteHost.h"
#import "TPStatusItemController.h"
#import "TPPreferencesManager.h"
#import "TPConnectionsManager.h"
#import "TPTCPSecureSocket.h"
#import "TPHostsManager.h"

#import "TPBonjourController.h"
#import "TPPasteboardTransfer.h"
#import "TPBackgroundImageTransfer.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <libkern/OSByteOrder.h>

/* Short receive timeout so the listener can notice shutdown and idle periods
   without spinning. */
#define POINTER_RECV_TIMEOUT_US 200000

static TPServerController * _defaultServerController = nil;

@interface TPServerController (PointerChannel)

- (void)_startPointerListenerIfNeeded;
- (void)_pointerThreadMain;
- (void)_beginPointerSession;
- (void)_endPointerSession;
- (TPMessage*)_pointerControlSuccessMessage;
- (uint64_t)_currentPointerToken;
- (void)_setPointerToken:(uint64_t)token;
- (uint32_t)_currentPointerPeerAddress;

@end

@implementation TPServerController

+ (TPServerController*)defaultController
{
	if(_defaultServerController == nil)
		_defaultServerController = [[TPServerController alloc] init];
	
	return _defaultServerController;
}

- (instancetype) init
{
	self = [super init];
	
	_state = TPServerIdleState;
	_pointerSocket = -1;
	
	[self bind:@"allowControl" toPref:ALLOW_CONTROL];
	
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(sessionDidResignActive:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
	
	return self;
}

- (void)dealloc
{
	if(_state == TPServerSharedState)
		[self stopSharing];
	else if(_state == TPServerControlledState)
		[self stopControl];
	
	
}


#pragma mark -
#pragma mark Sharing

- (void)startSharing
{
#if DEBUG_GENERAL
	DebugLog(@"server: startWaiting");
#endif
	int port = [[TPPreferencesManager sharedPreferencesManager] portForPref:COMMAND_PORT];
	
	if([[TPConnectionsManager manager] startListeningWithDelegate:self onPort:&port]) {
		DebugLog(@"listening on port %d", port);
		[[TPBonjourController defaultController] publishWithPort:port];
	}
	
	[self _startPointerListenerIfNeeded];
}

- (void)stopSharing
{
#if DEBUG_GENERAL
	DebugLog(@"server: stopWaiting");
#endif
	
	[self stopControl];
	[[TPBonjourController defaultController] unpublish];
	[[TPConnectionsManager manager] stopListening];
}


#pragma mark -
#pragma mark Hot border

- (TPHotBorder*)currentHotBorder
{
	return _clientHotBorder;
}

- (void)setupHotBorder:(TPHotBorder*)hotBorder forHost:(TPRemoteHost*)host
{
	[hotBorder setDoubleTap:[[self optionForRemoteHost:host key:SWITCH_WITH_DOUBLE_TAP] boolValue]];
	[hotBorder setAcceptDrags:[[self optionForRemoteHost:host key:COPY_FILES] boolValue]];
}

- (float)hotBorderSwitchDelay:(TPHotBorder*)hotBorder
{
	if(![[self optionForRemoteHost:nil key:DELAYED_SWITCH] boolValue]) {
		return 0.0;
	}
	else {
		return [[self optionForRemoteHost:nil key:SWITCH_DELAY] floatValue];
	}
}

- (BOOL)hotBorder:(TPHotBorder*)hotBorder canFireWithEvent:(NSEvent*)event
{
	NSAssert(hotBorder == _clientHotBorder, @"Hot border should be the client hot border");
	BOOL requireKey = [[self optionForRemoteHost:nil key:REQUIRE_KEY] boolValue];
	int keyTag = [[self optionForRemoteHost:nil key:SWITCH_KEY_TAG] intValue];
	return [[self eventsController] event:event hasRequiredKeyIfNeeded:requireKey withTag:keyTag];
}

- (BOOL)hotBorder:(TPHotBorder*)hotBorder firedAtLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo
{
	//DebugLog(@"loc=%d", location);
	[self requestStopControlAtLocation:location withDraggingInfo:draggingInfo];
	
	return [super hotBorder:hotBorder firedAtLocation:location withDraggingInfo:draggingInfo];
}


#pragma mark -
#pragma mark Switch options

- (void)setSwitchOptions:(NSDictionary*)switchOptions
{
	if(switchOptions != _switchOptions) {
		_switchOptions = switchOptions;
	}
}

- (id)optionForRemoteHost:(TPRemoteHost*)remoteHost key:(NSString*)key
{
	id option = (_switchOptions == nil) ? nil : _switchOptions[key];
	if(option == nil) {
		option = [[TPPreferencesManager sharedPreferencesManager] valueForPref:key];
	}
	return option;
}


#pragma mark -
#pragma mark Start control

- (void)requestedStartControlByHost:(TPRemoteHost*)host onConnection:(TPNetworkConnection*)connection withInfoDict:(NSDictionary*)infoDict
{
#if DEBUG_GENERAL
	DebugLog(@"server: startControl");
#endif
	
	BOOL connectionIsCurrent = (connection == [self currentConnection]);
	
	/* Reject if host is not controllable */
	if(![(TPMainController*)[NSApp delegate] canBeControlledByHostWithIdentifier:[host identifier]]) {
		[connection sendMessage:[TPMessage messageWithType:TPControlFailureMsgType
											   andInfoDict:@{@"reason": NSLocalizedString(@"Host not controllable.", @"Reason for control failure")}]];
		if(connectionIsCurrent)
			[self setCurrentConnection:nil];
		else
			;
		DebugLog(@"Rejecting control: host not controllable");
		return;
	}
	
	/* Reject if client not trusted */
	if(![[TPAuthenticationManager defaultManager] isHostTrusted:host]) {
		[connection sendMessage:[TPMessage messageWithType:TPControlFailureMsgType
											   andInfoDict:@{@"reason": NSLocalizedString(@"Host not trusted.", @"Reason for control failure")}]];
		if(connectionIsCurrent)
			[self setCurrentConnection:nil];
		else
			;
		DebugLog(@"Rejecting control: remote host not trusted");
		return;
	}
	
	/* Duplicated or retried request while already controlling this connection:
	   acknowledge it instead of rebuilding the whole session (which would leak
	   the previous hot border and event source). */
	if(connectionIsCurrent && _state == TPServerControlledState) {
		[connection sendMessage:[self _pointerControlSuccessMessage]];
		DebugLog(@"Ignoring duplicate control request");
		return;
	}
	
	/* Accept control. A fresh token per session gates the UDP pointer channel:
	   packets from anyone who did not receive this acknowledgement are ignored. */
	[self _beginPointerSession];
	[connection sendMessage:[self _pointerControlSuccessMessage]];

	if(!connectionIsCurrent) {
		[self setCurrentConnection:connection];
	}
	
	[self updateEventsController];
	
	[self startControlWithInfoDict:infoDict];
}

- (void)startControlWithInfoDict:(NSDictionary*)infoDict
{
#if DEBUG_GENERAL
	DebugLog(@"server: startPlaying");
#endif

	_state = TPServerControlledState;
	
	TPRemoteHost * host = [[self currentConnection] connectedHost];
	
	/* Update status menu */
	[[TPStatusItemController defaultController] updateWithStatus:TPStatusControlled host:host];

	/* Remove hot borders for controlling */
	[[TPClientController defaultController] updateTriggersAndShowVisualHint:NO];
	
	/* Setup the hotborder for the return */
	NSRect screenPlacement = [infoDict[TPScreenPlacementKey] rectValue];
	int sharedScreenIndex = [infoDict[TPScreenIndexKey] intValue];
	NSRect sharedScreenFrame = [[[TPLocalHost localHost] screenAtIndex:sharedScreenIndex] frame];
	screenPlacement.origin.x += NSMinX(sharedScreenFrame);
	screenPlacement.origin.y += NSMinY(sharedScreenFrame);
	
	/* Defensive: never leave a previous return border alive. */
	if(_clientHotBorder != nil) {
		[self takeDownHotBorder:_clientHotBorder];
		[_clientHotBorder close];
		_clientHotBorder = nil;
	}
	
	_clientHotBorder = [[TPHotBorder alloc] initWithRepresentingRect:screenPlacement inRect:sharedScreenFrame];
	[self setupHotBorder:_clientHotBorder forHost:host];
	[_clientHotBorder setDelegate:self];
	[_clientHotBorder delayedActivate];
	
	[[self eventsController] startPostingEvents];
	
	/* Move mouse */
	BOOL shouldWarp = NO;
	NSPoint mousePosition = [infoDict[TPMousePositionKey] pointValue];
	if(mousePosition.x >= 0.0 && mousePosition.y >= 0.0) {
		shouldWarp = YES;
		DebugLog(@"mousePosition=%@", NSStringFromPoint(mousePosition));
		mousePosition = [_clientHotBorder screenPointFromLocalPoint:mousePosition flipped:YES];
	}
	
	if([_clientHotBorder state] != TPHotBorderInactiveState) {
		[_clientHotBorder deactivate];
		if(shouldWarp) {
			[[self eventsController] warpMouseToPosition:mousePosition];
		}
		[_clientHotBorder delayedActivate];
	}
	else if(shouldWarp) {
		[[self eventsController] warpMouseToPosition:mousePosition];
	}
	
	/* Get switch options */
	[self setSwitchOptions:infoDict[TPSwitchOptionsKey]];
	
	/* Send the background image (low priority transfer) */
	if([[TPLocalHost localHost] hasCustomBackgroundImage])
		[[TPTransfersManager manager] beginTransfer:[TPOutgoingBackgroundImageTransfer transfer] usingConnection:[self currentConnection]];
	
	/* Wake up display. wakeUpScreen already performs the IODisplayWrangler
	   tweak; doing it twice made the first mouse events wait on IOPM calls. */
	[[TPLocalHost localHost] wakeUpScreen];
	
//	[eventsPlayer releaseAllKeys];
	
	DebugLog(@"hotBorderRect=%@", NSStringFromRect([_clientHotBorder hotRect]));
}


#pragma mark -
#pragma mark Stop control

- (void)requestStopControlAtLocation:(NSPoint)location withDraggingInfo:(id<NSDraggingInfo>)draggingInfo
{
	NSMutableDictionary * infoDict = [NSMutableDictionary dictionaryWithObject:[NSData dataWithPoint:location] forKey:TPMousePositionKey];
	[self addDraggingInfo:draggingInfo toInfoDict:infoDict];
	[self beginTransfersWithInfoDict:infoDict];

	TPMessage * message = [TPMessage messageWithType:TPControlStopMsgType
										 andInfoDict:infoDict];
	
	[[self currentConnection] sendMessage:message];	
	
	/* Do the fake mouse up */
	if(draggingInfo != nil)
		[[TPEventsController defaultController] mouseUpAtPosition:[NSEvent mouseLocation]];
}

- (void)stopControlWithDisconnect:(BOOL)disconnect
{
#if DEBUG_GENERAL
	DebugLog(@"server: stopPlaying: %d", disconnect);
#endif

	[super stopControlWithDisconnect:disconnect];
	
	if(_state == TPServerControlledState) {
		_state = TPServerSharedState;
		
		/* Invalidate the pointer-channel token: late UDP packets from the old
		   session must not move the cursor any more. */
		[self _endPointerSession];
		
		if([[TPPreferencesManager sharedPreferencesManager] boolForPref:WRAP_ON_STOP_CONTROL])
			[[self eventsController] warpMouseToCenter];
		
		[[self eventsController] stopPostingEvents];
		
		[self takeDownHotBorder:_clientHotBorder];
		[_clientHotBorder close];
		_clientHotBorder = nil;
		
		/* Update status menu */
		[[TPStatusItemController defaultController] updateWithStatus:TPStatusIdle host:nil];
		
		/* Re-add hot borders for controlling */
		[[TPClientController defaultController] updateTriggersAndShowVisualHint:NO];
	}
}


#pragma mark -
#pragma mark Pointer channel (UDP)

- (void)_startPointerListenerIfNeeded
{
	if(_pointerListenerStarted)
		return;
	
	int sock = socket(AF_INET, SOCK_DGRAM, 0);
	if(sock < 0) {
		DebugLog(@"pointer channel: cannot create socket (%d)", errno);
		return;
	}
	
	int reuse = 1;
	setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
	
	struct timeval timeout;
	timeout.tv_sec = 0;
	timeout.tv_usec = POINTER_RECV_TIMEOUT_US;
	setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	
	int port = [[TPPreferencesManager sharedPreferencesManager] portForPref:COMMAND_PORT] + TP_POINTER_CHANNEL_PORT_OFFSET;
	
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_ANY);
	address.sin_port = htons(port);
	
	if(bind(sock, (struct sockaddr *)&address, sizeof(address)) < 0) {
		DebugLog(@"pointer channel: cannot bind udp port %d (%d)", port, errno);
		close(sock);
		return;
	}
	
	_pointerSocket = sock;
	_pointerListenerStarted = YES;
	
	[NSThread detachNewThreadSelector:@selector(_pointerThreadMain) toTarget:self withObject:nil];
	
	DebugLog(@"pointer channel: listening on udp port %d", port);
}

- (void)_beginPointerSession
{
	uint64_t token = 0;
	arc4random_buf(&token, sizeof(token));
	if(token == 0)
		token = 1;
	
	[self _setPointerToken:token];
}

- (void)_setPointerToken:(uint64_t)token
{
	@synchronized(self) {
		_pointerToken = token;
		_pointerPeerValid = NO;
		_pointerPeerAddress = 0;
		_pointerPeerPort = 0;
		_pointerLastSequence = 0;
	}
}

- (void)_endPointerSession
{
	@synchronized(self) {
		_pointerToken = 0;
		_pointerPeerValid = NO;
		_pointerPeerAddress = 0;
		_pointerPeerPort = 0;
	}
}

- (uint64_t)_currentPointerToken
{
	@synchronized(self) {
		return _pointerToken;
	}
}

- (uint32_t)_currentPointerPeerAddress
{
	@synchronized(self) {
		return _pointerPeerValid ? _pointerPeerAddress : 0;
	}
}

- (TPMessage*)_pointerControlSuccessMessage
{
	uint64_t token = [self _currentPointerToken];
	if(token == 0)
		return [TPMessage messageWithType:TPControlSuccessMsgType];
	
	/* Old clients ignore the dictionary; new ones use the token to open the
	   UDP pointer channel. */
	NSData * tokenData = [NSData dataWithBytes:&token length:sizeof(token)];
	return [TPMessage messageWithType:TPControlSuccessMsgType andInfoDict:@{TPMsgPointerTokenKey: tokenData}];
}

- (void)_pointerThreadMain
{
	@autoreleasepool {
		for(;;) {
			@autoreleasepool {
				int sock = _pointerSocket;
				if(sock < 0)
					break;
				
				TPPointerPacket packet;
				struct sockaddr_in from;
				socklen_t fromLength = sizeof(from);
				ssize_t length = recvfrom(sock, &packet, sizeof(packet), 0, (struct sockaddr *)&from, &fromLength);
				
				if(length < 0) {
					int error = errno;
					if(error == EAGAIN || error == EWOULDBLOCK || error == EINTR)
						continue;
					
					DebugLog(@"pointer channel: recvfrom failed (%d)", error);
					break;
				}
				
				if(length < (ssize_t)sizeof(TPPointerPacket))
					continue;
				
				uint64_t token = [self _currentPointerToken];
				if(token == 0 || OSSwapBigToHostInt64(packet.token) != token)
					continue;
				
				if(packet.kind == TPPointerPacketHello) {
					@synchronized(self) {
						_pointerPeerValid = YES;
						_pointerPeerAddress = from.sin_addr.s_addr;
						_pointerPeerPort = from.sin_port;
					}
					
					TPPointerPacket ack = packet;
					ack.kind = TPPointerPacketHelloAck;
					ack.sequence = 0;
					ack.ageMs = 0;
					ack.deltaX = 0;
					ack.deltaY = 0;
					ack.buttons = 0;
					
					sendto(sock, &ack, sizeof(ack), 0, (struct sockaddr *)&from, fromLength);
				}
				else if(packet.kind == TPPointerPacketMove) {
					uint32_t expectedAddress = [self _currentPointerPeerAddress];
					if(expectedAddress != 0 && from.sin_addr.s_addr != expectedAddress)
						continue;
					
					/* UDP can reorder: ignore anything older than the last packet
					   so the cursor never jumps backwards. */
					uint32_t sequence = OSSwapBigToHostInt32(packet.sequence);
					@synchronized(self) {
						if(_pointerLastSequence != 0 && (int32_t)(sequence - _pointerLastSequence) <= 0)
							continue;
						_pointerLastSequence = sequence;
					}
					
					TPPointerDelta delta;
					delta.x = (int16_t)OSSwapBigToHostInt16((uint16_t)packet.deltaX);
					delta.y = (int16_t)OSSwapBigToHostInt16((uint16_t)packet.deltaY);
					delta.buttons = packet.buttons;
					delta.ageMs = OSSwapBigToHostInt32(packet.ageMs);
					
					[[self eventsController] queuePointerDelta:delta];
				}
			}
		}
	}
}


#pragma mark -
#pragma mark Network connection delegate

- (void)connectionFromClientAccepted:(TPNetworkConnection*)connection
{
	[connection setDelegate:self];
}

- (void)sessionDidResignActive:(NSNotification*)notification
{
	[self stopControl];
}

- (void)connection:(TPNetworkConnection*)connection receivedMessage:(TPMessage*)message
{
	TPMsgType type = [message msgType];

#if DEBUG_GENERAL
	DebugLog(@"slave receive msg %ld", type);
#endif

	switch(type) {
		case TPControlSleepType:
			DebugLog(@"received sleep msg");
			if ([[TPPreferencesManager sharedPreferencesManager] boolForPref:SYNC_SLEEP_STATUS]) {
			[[TPLocalHost localHost] sleepScreen];
			}
			break;
		case TPControlWakeType:
			DebugLog(@"received wake msg");
			[[TPLocalHost localHost] wakeUpScreen];
			break;
		case TPControlLockType:
			DebugLog(@"received lock msg");
			if ([[TPPreferencesManager sharedPreferencesManager] boolForPref:SYNC_LOCK_STATUS]) {
				/* Forward declare this function. It is a part of login.framework, which is a private framework we link against specifically to get locking semantics. Since it's private this can change, but this is the best we can do. */
				extern int SACLockScreenImmediate ( void );
				SACLockScreenImmediate();
			}
			break;

		case TPControlRequestMsgType:
		{
			[self requestedStartControlByHost:[connection connectedHost] onConnection:connection withInfoDict:[message infoDict]];
			break;
		}
		case TPControlStopMsgType:
		{
			[self stopControlWithDisconnect:DISCONNECT_WHEN_STOP_CONTROL];
			break;
		}
		case TPAuthenticationRequestMsgType:
		{
			[[TPAuthenticationManager defaultManager] authenticationRequestedFromHost:[connection connectedHost] onConnection:connection];
			break;
		}
		case TPEventMsgType:
			[[self eventsController] postEventWithEventData:[message data]];
			break;
		default:
			[super connection:connection receivedMessage:message];
	}
}




#pragma mark -
#pragma mark Setters and getters

- (void)setAllowControl:(BOOL)allowControl
{
	if(allowControl && _state != TPServerSharedState) {
		[self startSharing];
		_state = TPServerSharedState;
	}
	else if(!allowControl && _state != TPServerIdleState) {
		[self stopSharing];
		_state = TPServerIdleState;
	}
}

- (BOOL)allowControl
{
	return (_state != TPServerIdleState);
}

- (BOOL)isControlled
{
	return (_state == TPServerControlledState);
}

@end
