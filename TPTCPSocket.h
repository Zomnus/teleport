//
//  TPTCPSocket.h
//  teleport
//
//  Created by JuL on Thu Jan 08 2004.
//  Copyright (c) 2003-2005 abyssoft. All rights reserved.
//

#import <Foundation/Foundation.h>

#include <IOKit/network/IOEthernetController.h>

#define DEBUG_SOCKET 0

#ifndef DebugLog
#define DebugLog(logString, args...) NSLog(logString , ##args)
#endif

typedef struct {
	UInt8 bytes[kIOEthernetAddressSize];
} IOEthernetAddress;

typedef NS_ENUM(NSInteger, TPSocketState) {
	TPSocketDisconnectedState,
	TPSocketListeningState,
	TPSocketConnectingState,
	TPSocketConnectedState,
	TPSocketErrorState
} ;

@interface TPTCPSocket : NSObject
{
	id _delegate;
	
	CFSocketRef _cfSocket;
	CFRunLoopRef _runLoopRef;
	CFRunLoopSourceRef _sourceRef;
	
	int _maxSndBufferSize;
	BOOL _noDelay;
	NSLock * _lock;
	
	NSMutableArray * _sendQueue;
	NSCondition * _sendCondition;
	NSUInteger _sendQueueBytes;
	BOOL _sendThreadRunning;
	BOOL _stopSendThread;
	BOOL _sendFailed;
	
	/* Data can arrive before a delegate is attached (for sockets accepted from
	   a listening socket). Buffer it instead of dropping it. */
	NSMutableData * _pendingReceivedData;
	
	TPSocketState _socketState;
}

+ (BOOL)wakeUpHostWithMACAddress:(IOEthernetAddress)macAddress;

- (instancetype) initWithDelegate:(id)delegate NS_DESIGNATED_INITIALIZER;

@property (nonatomic, unsafe_unretained) id delegate;

- (void)setNoDelay:(BOOL)noDelay;

- (BOOL)listenOnPort:(int*)port tries:(int)tries;
- (BOOL)listenOnPort:(int)port;
- (BOOL)connectToHost:(NSString*)host onPort:(int)port;
- (void)setNativeSocket:(CFSocketNativeHandle)native;

@property (nonatomic, readonly, copy) NSString *localAddress;
@property (nonatomic, readonly, copy) NSString *remoteAddress;
@property (nonatomic, readonly) CFSocketNativeHandle nativeHandle;

- (BOOL)sendData:(NSData*)data;
@property (nonatomic, readonly) TPSocketState socketState;
- (void)close;

- (void)_setRunLoop:(CFRunLoopRef)runLoop;

/* Subclasses override this to provide the actual transport (e.g. TLS). It is
   always called on the dedicated writer thread, never on the main thread. */
- (BOOL)_writeData:(NSData*)data;

@end

@interface NSObject (TPTCPSocket_delegate)

- (void)tcpSocket:(TPTCPSocket*)tcpSocket gotData:(NSData*)data;
- (void)tcpSocketDidSendData:(TPTCPSocket*)tcpSocket;
- (void)tcpSocket:(TPTCPSocket*)listenSocket connectionAccepted:(TPTCPSocket*)childSocket;
- (void)tcpSocketConnectionSucceeded:(TPTCPSocket*)tcpSocket;
- (void)tcpSocketConnectionFailed:(TPTCPSocket*)tcpSocket;
- (void)tcpSocketConnectionClosed:(TPTCPSocket*)tcpSocket;

@end
