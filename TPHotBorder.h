//
//  TPHotBorder.h
//  Teleport
//
//  Created by JuL on Sun Dec 07 2003.
//  Copyright (c) 2003-2005 abyssoft. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TPHostSnapping.h"

#define DEBUG_HOTBORDER 0

#if DEBUG_HOTBORDER
#define BORDER_SIZE 4.0
#else
#define BORDER_SIZE 3.0
#endif

@class TPHotBorderView;

typedef NS_ENUM(NSInteger, TPHotBorderState) {
	TPHotBorderInactiveState,
	TPHotBorderActivatingState,
	TPHotBorderActiveState
} ;

@interface TPHotBorder : NSWindow
{
	TPHotBorderState _state;
	BOOL _doubleTap;
	BOOL _acceptDrags;
	id _hotDelegate;
	NSString * identifier;
	NSTrackingRectTag _trackingRectTag;
	NSTimer * _fireTimer;
	NSTimer * _tapTimer;
	NSTimer * _activateTimer;
	BOOL _hasPendingFire;
	NSEvent * _pendingFireEvent;
	NSPoint _pendingFireLocation;
	TPSide _side;
}

+ (TPHotBorder*)hotBorderRepresentingRect:(NSRect)representedRect inRect:(NSRect)parentRect;
+ (NSRect)hotRectWithRepresentingRect:(NSRect)representedRect inRect:(NSRect)parentRect;

- (instancetype) initWithRepresentingRect:(NSRect)representedRect inRect:(NSRect)parentRect NS_DESIGNATED_INITIALIZER;

- (void)updateWithRepresentingRect:(NSRect)representedRect inRect:(NSRect)parentRect;

@property (nonatomic) BOOL doubleTap;
@property (nonatomic) BOOL acceptDrags;
- (void)setDelegate:(id)delegate;
@property (nonatomic, copy) NSString *identifier;
- (void)setOpaqueToMouseEvents:(BOOL)opaque;
@property (nonatomic, readonly) NSRect hotRect;
@property (nonatomic, readonly) TPSide side;

- (void)activate;
- (void)delayedActivate;
- (void)deactivate;
@property (nonatomic, readonly) TPHotBorderState state;

- (void)fireAtLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo;

/* Used when the cursor is clamped at the screen edge while the raw delta
   keeps pushing outward: the user clearly intends to cross even if the
   window server never delivered a mouseEntered event. */
- (void)fireFromOutwardPushAtScreenPoint:(NSPoint)screenPoint;

- (NSPoint)screenPointFromLocalPoint:(NSPoint)localPoint flipped:(BOOL)flipped;

@end

@interface TPHotBorder (Private)

- (void)_fireAtLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo;

@end

@interface NSObject (TPHotBorder_delegate)

- (float)hotBorderSwitchDelay:(TPHotBorder*)hotBorder;
- (BOOL)hotBorder:(TPHotBorder*)hotBorder canFireWithEvent:(NSEvent*)event;
- (BOOL)hotBorder:(TPHotBorder*)hotBorder firedAtLocation:(NSPoint)location withDraggingInfo:(id <NSDraggingInfo>)draggingInfo;

@end