// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
// 


@import ZMCSystem;
#import "ZMWebSocket.h"
#import "ZMNetworkSocket.h"
#import "ZMDataBuffer.h"
#import "ZMWebSocketHandshake.h"
#import "ZMWebSocketFrame.h"
#import "TransportTracing.h"

#import <libkern/OSAtomic.h>
#import "ZMTLogging.h"


static char* const ZMLogTag ZM_UNUSED = ZMT_LOG_TAG_PUSHCHANNEL;

@interface ZMWebSocket ()
{
    int32_t _isOpen;
}

@property (nonatomic) NSURL *URL;
@property (nonatomic) NSMutableArray *dataPendingTransmission;
@property (nonatomic, weak) id<ZMWebSocketConsumer> consumer;
@property (atomic) dispatch_queue_t consumerQueue;
@property (atomic) ZMSDispatchGroup *consumerGroup;
@property (nonatomic) ZMNetworkSocket *networkSocket;
@property (nonatomic) BOOL handshakeCompleted;
@property (nonatomic) ZMDataBuffer *inputBuffer;
@property (nonatomic) ZMWebSocketHandshake *handshake;
@property (nonatomic, copy) NSDictionary* additionalHeaderFields;
@property (nonatomic) NSHTTPURLResponse *response;

@end



@implementation ZMWebSocket

- (instancetype)init
{
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"You should not use -init" userInfo:nil];
    return [self initWithConsumer:nil queue:nil group:nil networkSocket:nil url:nil additionalHeaderFields:nil];
}

- (instancetype)initWithConsumer:(id<ZMWebSocketConsumer>)consumer queue:(dispatch_queue_t)queue group:(ZMSDispatchGroup *)group url:(NSURL *)url additionalHeaderFields:(NSDictionary *)additionalHeaderFields;
{
    return [self initWithConsumer:consumer queue:queue group:group networkSocket:nil url:url additionalHeaderFields:additionalHeaderFields];
}

- (instancetype)initWithConsumer:(id<ZMWebSocketConsumer>)consumer queue:(dispatch_queue_t)queue group:(ZMSDispatchGroup *)group networkSocket:(ZMNetworkSocket *)networkSocket url:(NSURL *)url additionalHeaderFields:(NSDictionary *)additionalHeaderFields;
{
    VerifyReturnNil(consumer != nil);
    VerifyReturnNil(queue != nil);
    self = [super init];
    if (self) {
        self.URL = url;
        self.consumer = consumer;
        self.consumerQueue = queue;
        self.consumerGroup = group;
        if (networkSocket == nil) {
            networkSocket = [[ZMNetworkSocket alloc] initWithURL:url delegate:self delegateQueue:self.consumerQueue group:self.consumerGroup];
            ZMTraceWebSocketEvent(self, networkSocket, 100, 0);
        }
        self.inputBuffer = [[ZMDataBuffer alloc] init];
        self.networkSocket = networkSocket;
        self.handshake = [[ZMWebSocketHandshake alloc] initWithDataBuffer:self.inputBuffer];
        self.dataPendingTransmission = [NSMutableArray array];
        self.additionalHeaderFields = additionalHeaderFields;
        [self open];
    }
    return self;
}

- (void)safelyDispatchOnQueue:(void (^)(void))block
{
    dispatch_queue_t consumerQueue = self.consumerQueue;
    ZMSDispatchGroup *consumerGroup = self.consumerGroup;
    
    if(consumerGroup == nil || consumerQueue == nil) {
        return;
    }
    [consumerGroup asyncOnQueue:consumerQueue block:block];
}

- (void)open;
{
    ZMTraceWebSocketEvent(self, 0, 0, 0);
    RequireString(OSAtomicCompareAndSwap32Barrier(0, 1, &_isOpen), "Trying to open %p multiple times.", (__bridge void *) self);
    
    [self.networkSocket open];
}

- (dispatch_data_t)handshakeRequestData
{
    // The Opening Handshake:
    // C.f. <http://tools.ietf.org/html/rfc6455#section-1.3>
    
    Require(self.URL != nil);
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (__bridge CFStringRef) @"GET", (__bridge CFURLRef) self.URL, kCFHTTPVersion1_1);
    Require(message != NULL);
    NSMutableDictionary *headers = [@{@"Upgrade": @"websocket",
                              @"Host": self.URL.host,
                              @"Connection": @"Upgrade",
                              @"Sec-WebSocket-Key": @"dGhlIHNhbXBsZSBub25jZQ==",
                              @"Sec-WebSocket-Version": @"13"} mutableCopy];
    [headers addEntriesFromDictionary:self.additionalHeaderFields];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *headerField, NSString *headerValue, BOOL * ZM_UNUSED stop){
        CFHTTPMessageSetHeaderFieldValue(message, (__bridge CFStringRef) headerField, (__bridge CFStringRef) headerValue);
    }];
    //CFHTTPMessageSetBody(message, (__bridge CFDataRef) [NSData data]);
    NSData *requestData = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(message));
    Require(requestData != nil);
    CFRelease(message);
    
    CFDataRef cfdata = (CFDataRef) CFBridgingRetain(requestData);
    dispatch_data_t handshakeRequestData = dispatch_data_create(requestData.bytes, requestData.length, dispatch_get_global_queue(0, 0), ^{
        CFRelease(cfdata);
    });
    return handshakeRequestData;
}

- (ZMWebSocketHandshakeResult)didParseHandshakeInBuffer
{
    NSError *error;
    ZMWebSocketHandshakeResult handshakeCompleted = [self.handshake parseAndClearBufferIfComplete:YES error:&error];
    ZMTraceWebSocketEvent(self, 0, 1, (int) handshakeCompleted);
    self.response = self.handshake.response;
    if (handshakeCompleted == ZMWebSocketHandshakeCompleted) {
        for (NSData *data in self.dataPendingTransmission) {
            CFDataRef cfdata = (CFDataRef) CFBridgingRetain(data);
            dispatch_data_t d = dispatch_data_create(data.bytes, data.length, dispatch_get_global_queue(0, 0), ^{
                CFRelease(cfdata);
            });
            [self.networkSocket writeDataToNetwork:d];
        }
        self.dataPendingTransmission = nil;
    } else if (handshakeCompleted == ZMWebSocketHandshakeError) {
        ZMLogError(@"Failed to parse WebSocket handshake response: %@", error);
    }
    return handshakeCompleted;
}

- (void)close;
{
    // The compare & swap ensure that the code only runs if the values of isClosed was 0 and sets it to 1.
    // The check for 0 and setting it to 1 happen as a single atomic operation.
    ZMTraceWebSocketEvent(self, 0, 2, 0);
    if (OSAtomicCompareAndSwap32Barrier(1, 0, &_isOpen)) {
        dispatch_queue_t queue = self.consumerQueue;
        ZMSDispatchGroup *group = self.consumerGroup;
        self.consumerQueue = nil;
        self.consumerGroup = nil;
        ZMTraceWebSocketEvent(self, 0, 3, 0);
        [self.networkSocket close];
        NSHTTPURLResponse *response = self.response;
        self.response = nil;
        [group asyncOnQueue:queue block:^{
            [self.consumer webSocketDidClose:self HTTPResponse:response];
            self.consumer = nil; // Stop sending anything
        }];
    }
}

- (void)sendTextFrameWithString:(NSString *)string;
{
    ZMWebSocketFrame *frame = [[ZMWebSocketFrame alloc] initWithTextFrameWithPayload:string];
    [self sendFrame:frame];
}

- (void)sendBinaryFrameWithData:(NSData *)data;
{
    ZMWebSocketFrame *frame = [[ZMWebSocketFrame alloc] initWithBinaryFrameWithPayload:data];
    [self sendFrame:frame];
}

- (void)sendPingFrame;
{
    ZMLogDebug(@"Sending ping");
    ZMWebSocketFrame *frame = [[ZMWebSocketFrame alloc] initWithPingFrame];
    [self sendFrame:frame];
}

- (void)sendPongFrame;
{
    ZMLogDebug(@"Sending PONG");
    ZMWebSocketFrame *frame = [[ZMWebSocketFrame alloc] initWithPongFrame];
    [self sendFrame:frame];
}

- (void)sendFrame:(ZMWebSocketFrame *)frame;
{
    ZMTraceWebSocketEvent(self, 0, 4, frame.frameType);
    dispatch_data_t frameData = frame.frameData;
    if (frameData != nil) {
        [self safelyDispatchOnQueue:^{
            if (self.handshakeCompleted) {
                [self.networkSocket writeDataToNetwork:frameData];
            } else {
                RequireString(self.dataPendingTransmission != nil, "Was already sent & cleared?");
                ZMTraceWebSocketEvent(self, 0, 5, 0);
                [self.dataPendingTransmission addObject:frameData];
            }
        }];
    }
}

- (void)didReceivePing;
{
    [self sendPongFrame];
    ZMLogDebug(@"Received ping");
}

- (void)didReceivePong;
{
    ZMLogDebug(@"Received PONG");
}

@end


@implementation ZMWebSocket (ZMNetworkSocket)

- (void)networkSocketDidOpen:(ZMNetworkSocket *)socket;
{
    ZMTraceWebSocketEvent(self, socket, 101, 0);
    VerifyReturn(socket == self.networkSocket);
    dispatch_data_t headerData = self.handshakeRequestData;
    [self.networkSocket writeDataToNetwork:headerData];
}

- (void)networkSocket:(ZMNetworkSocket *)socket didReceiveData:(dispatch_data_t)data;
{
    ZMTraceWebSocketEvent(self, socket, 102, 0);
    VerifyReturn(socket == self.networkSocket);
    [self.inputBuffer addData:data];
    
    if(!self.handshakeCompleted) {
        ZMWebSocketHandshakeResult parseResult = [self didParseHandshakeInBuffer];
        switch (parseResult) {
            case ZMWebSocketHandshakeCompleted:
                {
                    NSHTTPURLResponse *response = self.response;
                    self.response = nil;
                    self.handshakeCompleted = YES;
                    [self safelyDispatchOnQueue:^{
                        [self.consumer webSocketDidCompleteHandshake:self HTTPResponse:response];
                        self.response = nil;
                    }];
                }
                break;
            case ZMWebSocketHandshakeNeedsMoreData:
                break;
            case ZMWebSocketHandshakeError:
                [self close];
                break;
                
        }
        return;
    }
    
    // Parse frames until the input is empty or contains a partial frame:
    while ([self parseFrameFromInputBufferForSocket:socket]) {
        // nothing
    }
}

- (BOOL)parseFrameFromInputBufferForSocket:(ZMNetworkSocket *)socket
{
    if (self.inputBuffer.isEmpty) {
        return NO;
    }
    
    NSError *frameError;
    ZMWebSocketFrame *frame = [[ZMWebSocketFrame alloc] initWithDataBuffer:self.inputBuffer error:&frameError];
    if (frame == nil) {
        ZMTraceWebSocketEvent(self, socket, 105, 0);
        if (![frameError.domain isEqualToString:ZMWebSocketFrameErrorDomain] ||
            (frameError.code != ZMWebSocketFrameErrorCodeDataTooShort))
        {
            [self close];
        }
        return NO;
    } else {
        ZMTraceWebSocketEvent(self, socket, 103, frame.frameType);
        switch (frame.frameType) {
            case ZMWebSocketFrameTypeText: {
                [self safelyDispatchOnQueue:^{
                    NSString *text = [[NSString alloc] initWithData:frame.payload encoding:NSUTF8StringEncoding];
                    [self.consumer webSocket:self didReceiveFrameWithText:text];
                }];
                break;
            }
            case ZMWebSocketFrameTypeBinary: {
                [self safelyDispatchOnQueue:^{
                    [self.consumer webSocket:self didReceiveFrameWithData:frame.payload];
                }];
                break;
            }
            case ZMWebSocketFrameTypePing: {
                [self didReceivePing];
                break;
            }
            case ZMWebSocketFrameTypePong: {
                [self didReceivePong];
                break;
            }
            case ZMWebSocketFrameTypeClose: {
                [self close];
                return NO;
                break;
            }
            default:
                break;
        }
        return YES;
    }
}

- (void)networkSocketDidClose:(ZMNetworkSocket *)socket;
{
    ZMTraceWebSocketEvent(self, socket, 104, 0);
    VerifyReturn(socket == self.networkSocket);
    [self close];
}

@end
