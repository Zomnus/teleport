//
//  TPClientController.h
//  Teleport
//
//  Created by JuL on Wed Dec 03 2003.
//  Copyright (c) 2003-2005 abyssoft. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "TPConnectionController.h"
#import "TPEventsController.h"

typedef NS_ENUM(NSInteger, TPClientState) {
	TPClientIdleState,
	TPClientConnectingState,
	TPClientControllingState
} ;

@class TPRemoteHost;

@interface TPClientController : TPConnectionController <TPEventsListener>
{
	TPClientState _state;
	NSMutableDictionary * _hotBorders;
	NSMutableDictionary * _hotKeys;
	NSDictionary * _infoDict;

	io_object_t _sleepNotifier;
	io_connect_t _sleepService;
	IONotificationPortRef _sleepNotifyPortRef;
	
	/* Control request watchdog: a stale TCP connection (e.g. after the Mac
	   slept) can swallow the request without any error, leaving the client
	   stuck in the connecting state forever. */
	NSTimer * _controlRequestTimer;
	NSInteger _controlRequestRetries;
	TPRemoteHost * _pendingControlHost;
	NSPoint _pendingControlLocation;
	
	/* Controller whose tap buffers movement while the switch is negotiated. */
	TPEventsController * _bufferingEventsController;
	
	/* Optional UDP pointer channel (see the server side for the token). */
	int _pointerSocket;
	uint32_t _pointerAddress;
	uint16_t _pointerPort;
	uint64_t _pointerToken;
	uint32_t _pointerSequence;
	uint32_t _pointerSendFailures;
	BOOL _pointerChannelActive;
}

+ (TPClientController*)defaultController;

- (void)updateTriggersAndShowVisualHint:(BOOL)showVisualHint;

- (BOOL)requestStartControlOnHost:(TPRemoteHost*)remoteHost atLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo;
- (BOOL)sendStartControlRequestForConnection:(TPNetworkConnection*)connection withInfoDict:(NSDictionary*)infoDict;
- (void)startControl;

- (void)requestedStopControlWithInfoDict:(NSDictionary*)infoDict;
- (void)stopControlWithDisconnect:(BOOL)disconnect;
@property (nonatomic, getter=isControlling, readonly) BOOL controlling;

@end
