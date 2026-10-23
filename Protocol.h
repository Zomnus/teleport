/* teleport protocol definitions */

#define PROTOCOL_VERSION 21

typedef NS_ENUM(NSInteger, TPMsgType) {
	TPIdentificationMsgType,
	
	/* Authentication */
	TPAuthenticationRequestMsgType,
	TPAuthenticationInProgressMsgType,
	TPAuthenticationAbortMsgType,
	TPAuthenticationSuccessMsgType,
	TPAuthenticationFailureMsgType,
	
	/* Control */
	TPControlRequestMsgType,
	TPControlSuccessMsgType,
	TPControlFailureMsgType,
	TPControlStopMsgType,
	TPControlWakeType,
	TPControlSleepType,
	TPControlLockType,
	
	/* Events */
	TPEventMsgType,
	
	/* Transfers */
	TPTransferRequestMsgType,
	TPTransferSuccessMsgType,
	TPTransferFailureMsgType
/*	TPTransferControlMsgType*/
} ;

typedef unsigned char TPMouseButton;
typedef int64_t TPScrollWheelDistance;
typedef float TPPixelPos;
typedef struct _TPMouseDelta {int64_t x; int64_t y;} TPMouseDelta;
typedef struct _TPKey {CGKeyCode keyCode; CGCharCode charCode;} TPKey;
/*typedef enum {TPLeftSide=0, TPRightSide, TPTopSide, TPBottomSide} TPScreenSide;*/
typedef uint64_t TPDataLength;
typedef unsigned short TPProtocolVersion;

/* Optional pointer channel: mouse movement travels over UDP so a single lost
   packet cannot stall the ordered TCP stream that carries keys and buttons.
   The server side stays silent unless a client proves it knows the token that
   was handed out with the control acknowledgement. */
#define TPMsgPointerTokenKey @"pointer-token"
#define TP_POINTER_CHANNEL_PORT_OFFSET 2

typedef NS_ENUM(uint8_t, TPPointerPacketKind) {
	TPPointerPacketHello = 0,
	TPPointerPacketMove = 1,
	TPPointerPacketHelloAck = 2
} ;

typedef struct _TPPointerPacket {
	uint64_t token;      /* big-endian */
	uint32_t sequence;   /* big-endian */
	uint32_t ageMs;      /* big-endian: event age at capture */
	int16_t deltaX;      /* big-endian */
	int16_t deltaY;      /* big-endian */
	uint8_t buttons;     /* bit 0 left, bit 1 right, bit 2 other */
	uint8_t kind;        /* TPPointerPacketKind */
	uint8_t reserved[2];
} TPPointerPacket;

/* One entry of the receiver-side queue. */
typedef struct _TPPointerDelta {
	int16_t x;
	int16_t y;
	uint8_t buttons;
	uint32_t ageMs;
} TPPointerDelta;
