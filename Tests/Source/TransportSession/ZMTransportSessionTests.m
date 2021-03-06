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


@import XCTest;
@import ZMCSystem;
@import OCMock;
@import ZMTesting;


#if TARGET_OS_IPHONE
@import MobileCoreServices;
@import UIKit;
#else
@import Cocoa;
#endif


#import "ZMTransportSession+internal.h"
#import "ZMTransportCodec.h"
#import "ZMAccessToken.h"
#import "ZMTransportRequest+Internal.h"
#import "ZMPersistentCookieStorage.h"
#import "ZMPushChannelConnection.h"
#import "ZMReachability.h"
#import "NSError+ZMTransportSession.h"
#import "ZMUserAgent.h"
#import "ZMURLSession.h"
#import "ZMURLSessionSwitch.h"
#import "Fakes.h"

#import "XCTestCase+Images.h"

/// the JSON Content-Type header
static NSString *JSONContentType = @"application/json";



@interface TestResponse : NSObject

+ (instancetype)testResponse;

@property (nonatomic) NSData *body;
@property (nonatomic) NSInteger statusCode;
@property (nonatomic) NSDictionary *headers;
@property (nonatomic) NSError *error;

- (void)setBodyFromTransportData:(id<ZMTransportData>)data;

@end




@implementation TestResponse

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.body = [NSData data];
        self.statusCode = 200;
        self.headers = @{@"Content-Type": @"application/json"};
        self.error = nil;
    }

    return self;
}

+ (instancetype)testResponse
{
    return [[self alloc] init];
}

- (void)setBodyFromTransportData:(id<ZMTransportData>)object;
{
    if (object == nil) {
        self.body = nil;
    } else {
        NSError *error = nil;
        self.body = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
        RequireString(self.body != nil, "Failed to serialize JSON: %lu", (long) error.code);
    }
}

- (void)setError:(NSError *)error;
{
    CheckString(error == nil || [error.domain isEqualToString:NSURLErrorDomain],
                "At this API level errors are supposed to be 'NSURLErrorDomain'.");
    _error = error;
}

@end


//////////////////////////////////////////////////
//
#pragma mark - Request Scheduler
//
//////////////////////////////////////////////////

@interface FakeTransportRequestScheduler : NSObject <ZMReachabilityObserver>

@property (atomic) NSInteger concurrentRequestCountLimit;

@property (nonatomic) ZMTransportRequestSchedulerState schedulerState;
@property (nonatomic) int tearDownCount;
@property (nonatomic) NSMutableArray *addedItems;
@property (nonatomic) NSMutableArray *processedResponses;
@property (nonatomic) int accessTokenCount;
@property (nonatomic) int enterForegroundCount;
@property (nonatomic) int reachabilityChangedCount;
@property (nonatomic) id reachability;

@end



@implementation FakeTransportRequestScheduler

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.concurrentRequestCountLimit = 1000;
        self.addedItems = [NSMutableArray array];
        self.processedResponses = [NSMutableArray array];
    }
    return self;
}

- (void)tearDown;
{
    ++self.tearDownCount;
}

- (void)performGroupedBlock:(dispatch_block_t)block;
{
    block();
}

- (void)addItem:(id<ZMTransportRequestSchedulerItem>)item;
{
    [self.addedItems addObject:(id) item ?: [NSNull null]];
}

- (void)processCompletedURLTask:(NSURLSessionTask *)task;
{
    [self processCompletedURLResponse:(id) task.response URLError:task.error];
}

- (void)processCompletedURLResponse:(NSHTTPURLResponse *)response URLError:(NSError *)error;
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (response != nil) {
        dict[@"response"] = response;
    }
    if (error != nil) {
        dict[@"error"] = error;
    }
    [self.processedResponses addObject:dict];
}

- (void)sessionDidReceiveAccessToken:(id<ZMTransportRequestSchedulerSession>)session;
{
    NOT_USED(session);
    ++self.accessTokenCount;
}

- (BOOL)canSendRequests;
{
    return YES;
}

- (void)applicationWillEnterForeground;
{
    ++self.enterForegroundCount;
}

- (void)reachabilityDidChange:(ZMReachability *)reachability;
{
    NOT_USED(reachability);
    ++self.reachabilityChangedCount;
}

@end

//////////////////////////////////////////////////
//
#pragma mark - Fake Push Channel
//
//////////////////////////////////////////////////

@interface FakePushChannel : NSObject

- (instancetype)initWithScheduler:(ZMTransportRequestScheduler *)scheduler userAgentString:(NSString *)userAgentString URL:(NSURL *)URL;

- (void)setPushChannelConsumer:(id<ZMPushChannelConsumer>)consumer groupQueue:(id<ZMSGroupQueue>)groupQueue;

- (void)createPushChannelWithAccessToken:(ZMAccessToken *)accessToken clientID:(NSString *)clientID;
- (void)closeAndRemoveConsumer;
- (void)scheduleOpenPushChannel;
- (void)reachabilityDidChange:(ZMReachability *)reachability;


@property (nonatomic, weak) id <ZMNetworkStateDelegate> networkStateDelegate;
@property (nonatomic) ZMTransportRequestScheduler *scheduler;
@property (nonatomic, copy) NSString *userAgentString;
@property (nonatomic) NSURL *URL;

@property (nonatomic) ZMAccessToken *lastAccessToken;
@property (nonatomic) NSString *lastClientID;

@property (nonatomic) NSUInteger createPushChannelCount;
@property (nonatomic) NSUInteger setConsumerCount;
@property (nonatomic) NSUInteger closeAndRemoveConsumerCount;
@property (nonatomic) NSUInteger closeCount;
@property (nonatomic) NSUInteger scheduleOpenPushChannelCount;
@property (nonatomic) NSUInteger reachabilityChangeCount;


@end

static FakePushChannel *currentFakePushChannel;

@implementation FakePushChannel

- (instancetype)initWithScheduler:(ZMTransportRequestScheduler *)scheduler userAgentString:(NSString *)userAgentString URL:(NSURL *)URL;
{
    self = [super init];
    if (self) {
        self.scheduler = scheduler;
        self.userAgentString = userAgentString;
        self.URL = URL;
    }
    currentFakePushChannel = self;
    return self;
}

- (void)setPushChannelConsumer:(id<ZMPushChannelConsumer>)consumer groupQueue:(id<ZMSGroupQueue>)groupQueue;
{
    NOT_USED(consumer);
    NOT_USED(groupQueue);
    self.setConsumerCount++;
}

- (void)createPushChannelWithAccessToken:(ZMAccessToken *)accessToken clientID:(NSString *)clientID;
{
    self.lastAccessToken = accessToken;
    self.lastClientID = clientID;
    self.createPushChannelCount++;
}

- (void)closeAndRemoveConsumer;
{
    self.closeAndRemoveConsumerCount++;
}

- (void)close;
{
    self.closeCount++;
}

- (void)scheduleOpenPushChannel;
{
    self.scheduleOpenPushChannelCount++;
}

- (void)reachabilityDidChange:(ZMReachability *)reachability;
{
    NOT_USED(reachability);
    self.reachabilityChangeCount++;
}
@end

//////////////////////////////////////////////////
//
#pragma mark - Reachability
//
//////////////////////////////////////////////////


static XCTestCase *currentTestCase;

#define ReachabilityAssert(a) \
	do { \
		BOOL _a = a; \
		if (! _a) { \
			NSString *d = [NSString stringWithFormat: @"Assertion failed: %s", #a ]; \
			_XCTRegisterFailure(currentTestCase, d); \
		} \
	} while (0)


/// C.f. ZMReachability
@interface FakeReachability : NSObject

- (instancetype)initWithServerNames:(NSArray *)names observer:(id<ZMReachabilityObserver>)observer queue:(NSOperationQueue *)observerQueue group:(ZMSDispatchGroup *)group;

- (void)tearDown;

@property (atomic) BOOL mayBeReachable;

@property (nonatomic) BOOL wasTornDown;
@property (nonatomic, copy) NSArray *names;
@property (nonatomic, weak) id<ZMReachabilityObserver> observer;
@property (nonatomic) NSOperationQueue * observerQueue;
@property (nonatomic) ZMSDispatchGroup *group;

@end


static __weak FakeReachability *currentReachability;



@implementation FakeReachability


- (instancetype)initWithServerNames:(NSArray *)names observer:(id<ZMReachabilityObserver>)observer queue:(NSOperationQueue *)observerQueue group:(ZMSDispatchGroup *)group;
{
    self = [super init];
    if (self) {
        self.names = names;
        self.observer = observer;
        self.observerQueue = observerQueue;
        self.group = group;
        self.mayBeReachable = YES;
    }
    currentReachability = self;
    return self;
}

- (void)tearDown;
{
    self.wasTornDown = YES;
}

- (void)dealloc
{
    ReachabilityAssert(self.wasTornDown);
}

@end



//////////////////////////////////////////////////
//
#pragma mark - Tests
//
//////////////////////////////////////////////////



@interface ZMTransportSessionTests : ZMTBaseTest

@property (atomic, copy) ZMCompletionHandlerBlock failedAuthHandler;
@property (nonatomic) ZMURLSession *URLSession;
@property (nonatomic) id dataTask;
@property (nonatomic) ZMTransportSession *sut;
@property (nonatomic) NSURL *baseURL;
@property (nonatomic) NSURL *webSocketURL;
@property (nonatomic) NSString *dummyPath;
@property (nonatomic) NSDictionary *dummyTokenPayload;
@property (nonatomic) NSOperationQueue *queue;
@property (nonatomic) ZMAccessToken *validAccessToken;
@property (nonatomic) ZMAccessToken *expiredAccessToken;
@property (nonatomic) NSUInteger nextTaskIdentifier;
@property (nonatomic) FakeTransportRequestScheduler *scheduler;
@property (nonatomic) ZMURLSessionSwitch *URLSessionSwitch;


@end



@interface ZMTransportSessionTests (Helper)

- (NSURLSessionTask *)mockURLSessionTaskWithResponseGenerator:(TestResponse *(^)(NSURLRequest *, NSData *))responseGenerator;

- (void)invokeAccessTokenRenewalFailureHandler:(ZMTransportResponse *)response;

@end



@implementation ZMTransportSessionTests

- (void)setUp
{
    currentTestCase = self;
    [super setUp];

    self.scheduler = [[FakeTransportRequestScheduler alloc] init];
    
    self.dataTask = [OCMockObject mockForClass:FakeDataTask.class];
    [[[self.dataTask stub] andReturnValue:OCMOCK_VALUE((NSUInteger) 0)] taskIdentifier];

    self.queue = [NSOperationQueue zm_serialQueueWithName:self.name];
    
    self.URLSession = [OCMockObject mockForClass:ZMURLSession.class];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    (void)[(ZMURLSession *) [[(id) self.URLSession stub] andReturn:config] configuration];
    [[[(id)self.URLSession stub] andReturnValue:@NO] isBackgroundSession];
    [self verifyMockLater:self.URLSession];
    
    self.URLSessionSwitch = [OCMockObject mockForClass:ZMURLSessionSwitch.class];
    [[[(id)self.URLSessionSwitch stub] andReturn:self.URLSession] currentSession];
    [self verifyMockLater:self.URLSessionSwitch];
    
    self.baseURL = [NSURL URLWithString:@"http://base.example.com"];
    self.webSocketURL = [NSURL URLWithString:@"http://websocket.example.com"];
    self.sut = [[ZMTransportSession alloc]
                initWithURLSessionSwitch:self.URLSessionSwitch
                requestScheduler:(id) self.scheduler
                reachabilityClass:[FakeReachability class]
                queue:self.queue
                group:self.dispatchGroup
                baseURL:self.baseURL
                websocketURL:self.webSocketURL
                pushChannelClass:FakePushChannel.class
                keyValueStore:[[FakeKeyValueStore alloc] init]];
    __weak id weakSelf = self;
    [self.sut setAccessTokenRenewalFailureHandler:^(ZMTransportResponse *response) {
        id strongSelf = weakSelf;
        if(strongSelf) {
            [strongSelf invokeAccessTokenRenewalFailureHandler:response];
        }
    }];
    self.dummyPath = @"/dummy";
    self.validAccessToken = [[ZMAccessToken alloc] initWithToken:@"valid-token" type:@"valid-type" expiresInSeconds:4321];
    self.expiredAccessToken = [[ZMAccessToken alloc] initWithToken:@"expired-token" type:@"expired-type" expiresInSeconds:0];
    self.sut.clientID = @"9019oj3qauosdasd";
    
    self.dummyTokenPayload = @{
        @"access_token": @"DummyToken",
        @"token_type": @"Dummy",
        @"expires_in": @(7777)
    };
    
    [self verifyMockLater:self.URLSession];
    
    [ZMPersistentCookieStorage deleteAllKeychainItems];
}

- (void)tearDown
{
    currentFakePushChannel = nil;
    self.queue = nil;
    self.failedAuthHandler = nil;
    [super tearDown];
    currentTestCase = nil;
}

- (void)setAuthenticationCookieData;
{
    NSURL *URL = [NSURL URLWithString:@"http://www.example.com"];
    NSDictionary *headers = @{@"Set-Cookie": @"zuid=bar; Expires=Sun, 21-Jul-2024 09:06:45 GMT; Domain=example.com; HttpOnly; Secure"};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:URL
                                                              statusCode:200
                                                             HTTPVersion:@""
                                                            headerFields:headers];
    [self.sut.cookieStorage setCookieDataFromResponse:response forURL:URL];
    XCTAssertNotNil(self.sut.cookieStorage.authenticationCookieData);
}

- (BOOL)requestMethodShouldHavePayload:(ZMTransportRequestMethod)method {
    switch(method) {
        case ZMMethodDELETE:
        case ZMMethodGET:
        case ZMMethodHEAD:
            return NO;
        case ZMMethodPOST:
        case ZMMethodPUT:
            return YES;
    }
}

- (void)testThatTheCookieStorageIsNotNil
{
    XCTAssertNotNil(self.sut.cookieStorage);
}

- (void)testThatItConvertsMethodToString
{
    // given
    NSArray *expected = @[@"GET", @"POST", @"DELETE", @"PUT", @"HEAD"];
    NSArray *input = @[
                       [NSNumber numberWithInt:ZMMethodGET],
                       [NSNumber numberWithInt:ZMMethodPOST],
                       [NSNumber numberWithInt:ZMMethodDELETE],
                       [NSNumber numberWithInt:ZMMethodPUT],
                       [NSNumber numberWithInt:ZMMethodHEAD],
                       ];
    
    // when
    NSArray *output = [input mapWithBlock:^(NSNumber *intMethod) {
        ZMTransportRequestMethod method = (ZMTransportRequestMethod) intMethod.integerValue;
        return [ZMTransportRequest stringForMethod:method];
    }];
    
    // then
    XCTAssertEqualObjects(expected, output);
}

- (void)testThatItConvertsStringToMethod
{
    // given
    NSArray *input = @[@"GET", @"POST", @"DELETE", @"PUT", @"HEAD"];
    NSArray *expected = @[
                       [NSNumber numberWithInt:ZMMethodGET],
                       [NSNumber numberWithInt:ZMMethodPOST],
                       [NSNumber numberWithInt:ZMMethodDELETE],
                       [NSNumber numberWithInt:ZMMethodPUT],
                       [NSNumber numberWithInt:ZMMethodHEAD],
                       ];
    
    // when
    NSArray *output = [input mapWithBlock:^(NSString *stringMethod) {
        return [NSNumber numberWithInt:[ZMTransportRequest methodFromString:stringMethod]];
    }];
    
    // then
    XCTAssertEqualObjects(expected, output);
}


- (void)testThatItUsesTheBaseURL
{
    // given
    NSURL *url = [NSURL URLWithString:@"http://test1.example.com"];
    NSURL *url2 = [NSURL URLWithString:@"http://test2.example.com"];
    [[(id) self.URLSessionSwitch stub] tearDown];
    [self.sut tearDown];
    self.sut = [[ZMTransportSession alloc]
                initWithURLSessionSwitch:self.URLSessionSwitch
                requestScheduler:(id) self.scheduler
                reachabilityClass:[FakeReachability class]
                queue:self.queue
                group:self.dispatchGroup
                baseURL:url
                websocketURL:url2
                pushChannelClass:nil
                keyValueStore:[[FakeKeyValueStore alloc] init]];
    
    self.sut.accessToken = self.validAccessToken;
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    NSString *path = @"path/to/something/interesting";
    NSURL *expectedURL = [url URLByAppendingPathComponent:path];
    
    // expect
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects(expectedURL, request.URL);
        return [TestResponse testResponse];
    }];
    
    ZMTransportRequest *request =[ZMTransportRequest requestWithPath:path method:ZMMethodGET payload:nil];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED){
        [expectation fulfill];
    }]];
    
    // when
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}


- (void)testThatItEnqueuesSearchRequests;
{
    // given
    ZMTransportRequest *request =[ZMTransportRequest requestWithPath:@"foo" method:ZMMethodGET payload:nil];
    
    // when
    [self.sut enqueueSearchRequest:request];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.scheduler.addedItems.count, 1u);
    XCTAssertEqual(self.scheduler.addedItems.firstObject, request);
}

- (void)testThatItEnqueuesRequests;
{
    // given
    ZMTransportRequest *request =[ZMTransportRequest requestWithPath:@"foo" method:ZMMethodGET payload:nil];
    
    // when
    [self.sut attemptToEnqueueSyncRequestWithGenerator:^(){
        return request;
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.scheduler.addedItems.count, 1u);
    XCTAssertEqual(self.scheduler.addedItems.firstObject, request);
}

- (void)testThatItSendsARequestWithAMethod
{
    // given
    self.sut.accessToken = self.validAccessToken;
    ZMTransportRequestMethod const methods[] = {
        ZMMethodGET,
        ZMMethodPOST,
        ZMMethodDELETE,
        ZMMethodPUT,
        ZMMethodHEAD,
    };
    
    for (size_t i = 0; i < sizeof(methods) / sizeof(*methods); ++i) {
        ZMTransportRequestMethod const method = methods[i];
        
        __block ZMTransportRequestMethod requestMethod;
        id<ZMTransportData> payload = ([self requestMethodShouldHavePayload:method] ? @[@3] : nil);
        [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
            requestMethod = [ZMTransportRequest methodFromString:request.HTTPMethod];
            return nil;
        }];

        // when
        ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:method payload:payload];
        [self.sut sendSchedulerItem:request];
        WaitForAllGroupsToBeEmpty(0.5);
        
        // then
        XCTAssertEqual(requestMethod, method);
    }
}


- (void)testThatItSendsARequestWithJSONContentType
{
    // given
    self.sut.accessToken = self.validAccessToken;
    __block NSDictionary *requestHeaders;
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
        requestHeaders = request.allHTTPHeaderFields;
        return [TestResponse testResponse];
    }];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodPOST payload:@{}];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    XCTAssertEqualObjects(requestHeaders[@"Content-Type"], JSONContentType);
}


- (void)testThatItSetsTheAcceptHeaderToJSON
{
    // given
    self.sut.accessToken = self.validAccessToken;
    __block NSDictionary *requestHeaders;
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
        requestHeaders = request.allHTTPHeaderFields;
        return [TestResponse testResponse];
    }];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    // when
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    XCTAssertEqualObjects(requestHeaders[@"Accept"], JSONContentType);
}


- (void)testThatItSetsTheAcceptHeaderToImageTypes
{
    // given
    self.sut.accessToken = self.validAccessToken;
    __block NSDictionary *requestHeaders;
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
        requestHeaders = request.allHTTPHeaderFields;
        return [TestResponse testResponse];
    }];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest imageGetRequestFromPath:self.dummyPath];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    NSString *accept = requestHeaders[@"Accept"];
    XCTAssertNotNil(accept);
    NSArray *types = [accept componentsSeparatedByString:@", "];
    XCTAssertGreaterThan(types.count, 0u);
    for (NSString *t in types) {
        XCTAssertTrue([t hasPrefix:@"image/"], @"type '%@'", t);
    }
}


- (void)testThatItSendsARequestWithPayload
{
    // given
    self.sut.accessToken = self.validAccessToken;
    id<ZMTransportData> payload = @{@"numbers": @[@4, @8, @15, @16, @23, @42]};
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    __block NSData *requestData;
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data) {
        requestData = data;
        return [TestResponse testResponse];
    }];
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodPOST payload:payload];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    XCTAssertEqualObjects(payload, [NSJSONSerialization JSONObjectWithData:requestData options:0 error:NULL]);
}

- (void)testThatItSendsARequestThatShuouldUseForegroundSessionOnlyOnForegroundSessionWhenURLSwitchIsInBackground
{
    // given
    NSURL *url = [NSURL URLWithString:@"http://test1.example.com"];
    ZMURLSession *foregroundSession = [OCMockObject niceMockForClass:ZMURLSession.class];
    ZMURLSession *backgroundSession = [OCMockObject niceMockForClass:ZMURLSession.class];
    ZMURLSession *voipSession = [OCMockObject niceMockForClass:ZMURLSession.class];

    ZMURLSessionSwitch *urlSwitch = [[ZMURLSessionSwitch alloc] initWithForegroundSession:foregroundSession backgroundSession:backgroundSession voipSession:voipSession];
    ZMTransportSession *sut = [[ZMTransportSession alloc]
                initWithURLSessionSwitch:urlSwitch
                requestScheduler:(id) self.scheduler
                reachabilityClass:[FakeReachability class]
                queue:self.queue
                group:self.dispatchGroup
                baseURL:url
                websocketURL:url
                pushChannelClass:nil
                keyValueStore:[[FakeKeyValueStore alloc] init]];
    
    sut.accessToken = self.validAccessToken;
    id<ZMTransportData> payload = @{@"numbers": @[@4, @8, @15, @16, @23, @42]};
    [urlSwitch switchToBackgroundSession];
    
    // expect
    [[(id)foregroundSession reject] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:OCMOCK_ANY];
    [[[(id)backgroundSession expect] andReturn:nil] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:OCMOCK_ANY];
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodPOST payload:payload];
    [sut sendSchedulerItem:request];
    
    // then
    [sut tearDown];
    [(id)foregroundSession verify];
    [(id)backgroundSession verify];
}

- (void)testThatItSendsARequestOnBackgroundSessionWhenURLSwitchIsOnBackground
{
    // given
    NSURL *url = [NSURL URLWithString:@"http://test1.example.com"];
    ZMURLSession *foregroundSession = [OCMockObject niceMockForClass:ZMURLSession.class];
    ZMURLSession *backgroundSession = [OCMockObject niceMockForClass:ZMURLSession.class];
    ZMURLSession *voipSession = [OCMockObject niceMockForClass:ZMURLSession.class];

    ZMURLSessionSwitch *urlSwitch = [[ZMURLSessionSwitch alloc] initWithForegroundSession:foregroundSession backgroundSession:backgroundSession voipSession:voipSession];
    ZMTransportSession *sut = [[ZMTransportSession alloc]
                               initWithURLSessionSwitch:urlSwitch
                               requestScheduler:(id) self.scheduler
                               reachabilityClass:[FakeReachability class]
                               queue:self.queue
                               group:self.dispatchGroup
                               baseURL:url
                               websocketURL:url
                               pushChannelClass:nil
                               keyValueStore:[[FakeKeyValueStore alloc] init]];
    
    sut.accessToken = self.validAccessToken;
    id<ZMTransportData> payload = @{@"numbers": @[@4, @8, @15, @16, @23, @42]};
    [urlSwitch switchToBackgroundSession];
    
    // expect
    [[(id)backgroundSession expect] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:OCMOCK_ANY];
    [[[(id)foregroundSession reject] andReturn:nil] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:OCMOCK_ANY];
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodPOST payload:payload];
    [request forceToBackgroundSession];
    [sut sendSchedulerItem:request];
    
    // then
    [sut tearDown];
    [(id)foregroundSession verify];
    [(id)backgroundSession verify];
}


- (void)testThatItCallsTheCompletionHandler
{
    // given
    self.sut.accessToken = self.validAccessToken;
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        return [TestResponse testResponse];
    }];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    // when
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}


- (void)testThatItCallsTheCompletionHandlerWithResponseData
{
    // given
    self.sut.accessToken = self.validAccessToken;
    NSArray *expectedPayload = @[@"this is my test data", @213143];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.body = [NSJSONSerialization dataWithJSONObject:expectedPayload options:0 error:nil];
        return testResponse;
    }];

    // when
    __block id<ZMTransportData> receivedPayload;
    
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        receivedPayload = response.payload;
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    XCTAssertEqualObjects(expectedPayload, receivedPayload);
}

- (void)testThatItSetsTheContentDisposition;
{
    // given
    self.sut.accessToken = self.validAccessToken;
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Content-Type"], @"image/jpeg");
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Content-Disposition"], @"conv_id=912c7fc66cfb;width=2");
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Accept"], @"application/json");
        
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.body = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:nil];
        return testResponse;
    }];
    NSData *binaryData = [@"foo" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *contentDisposition = @{@"conv_id": @"912c7fc66cfb", @"width": @2};
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodPOST binaryData:binaryData type:(__bridge NSString *) kUTTypeJPEG contentDisposition:contentDisposition];
    __block id<ZMTransportData> receivedPayload;
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        receivedPayload = response.payload;
        [expectation fulfill];
    }]];
    
    // when
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)testThatItPassesAStatusCodeToTheCompletionHandler
{
    // given
    self.sut.accessToken = self.validAccessToken;
    NSInteger expectedStatusCode = 432;
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.statusCode = expectedStatusCode;
        return testResponse;
    }];

    // when
    __block NSInteger receivedStatusCode;
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        receivedStatusCode = response.HTTPStatus;
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    XCTAssertEqual(expectedStatusCode, receivedStatusCode);
}


- (void)testThatItReturns_DidGenerateNonNullRequest_WithNullRequest
{
    
    // given
    self.sut.maximumConcurrentRequests = 4;
    
    // when
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        ZMTransportRequest *request =  nil;
        return request;
    };
    
    ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
    
    // then
    XCTAssertFalse(result.didGenerateNonNullRequest);
}

- (void)testThatItDoesNotReturn_DidGenerateNonNullRequest_WithNonNullRequest
{
    
    // given
    self.sut.maximumConcurrentRequests = 4;
    
    // when
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
        return request;
    };
    
    ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
    
    // then
    XCTAssertTrue(result.didGenerateNonNullRequest);
}


- (void)testThatItReturns_HasLessRequestThanMax_WithNullRequest
{
    
    // given
    self.sut.maximumConcurrentRequests = 4;
    
    // when
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        ZMTransportRequest *request =  nil;
        return request;
    };
    
    ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
    
    // then
    XCTAssertTrue(result.didHaveLessRequestThanMax);
}

- (void)testThatItReturns_HasLessRequestThanMax_WithNonNullRequest
{
    
    // given
    self.sut.maximumConcurrentRequests = 4;
    
    // when
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
        return request;
    };
    
    ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
    
    // then
    XCTAssertTrue(result.didHaveLessRequestThanMax);
}

- (void)testThatItDoesNotGenerateARequestWhenTheSchedulerIsLimitedToZero
{
    
    // given
    self.sut.maximumConcurrentRequests = 4;
    self.scheduler.concurrentRequestCountLimit = 0;
    
    // when
    ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:^(){
        return [ZMTransportRequest requestGetFromPath:@"/foo"];
    }];
    
    // then
    XCTAssertFalse(result.didGenerateNonNullRequest);
    XCTAssertFalse(result.didHaveLessRequestThanMax);
}

- (void)testThatItEnforcesTheConcurrentRequestLimitOfTheScheduler
{
    
    // given
    self.sut.maximumConcurrentRequests = 12;
    self.scheduler.concurrentRequestCountLimit = 4;
    
    // when
    for (int i = 0; i < 20; ++i) {
        [self.sut attemptToEnqueueSyncRequestWithGenerator:^(){
            return [ZMTransportRequest requestGetFromPath:@"/foo"];
        }];
    }
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.scheduler.addedItems.count, (NSUInteger) self.scheduler.concurrentRequestCountLimit);
}

- (void)testThatItGenerateARequestIfItCouldSendTheRequest
{
    
    // given
    
    // when
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
        [request addCompletionHandler:
         [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        }]];
        return request;
    };
    
    ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
    
    // then
    XCTAssertTrue(result.didGenerateNonNullRequest);
    XCTAssertTrue(result.didHaveLessRequestThanMax);
}


- (void)testThatItDoesNotGenrateARequestWhenThereAreTooManyRequests
{
    // given
    int const maxRequests = TARGET_OS_IPHONE ? 6 : 10;
    XCTAssertEqual((int) self.sut.maximumConcurrentRequests, maxRequests);
    
    // when
    for(int i = 0; i < maxRequests + 1; ++i) {
        ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
            ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
            [request addCompletionHandler:
             [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
            }]];
            return request;
        };
        ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
        
        // then
        if(i < maxRequests) {
            XCTAssertTrue(result.didGenerateNonNullRequest);
            XCTAssertTrue(result.didHaveLessRequestThanMax);
        }
        else {
            XCTAssertFalse(result.didHaveLessRequestThanMax);
        }
    }
}

- (void)testThatNullRequestsDoNotCountInTheMaxRequestsLimit
{
    // given
    int const maxRequests = TARGET_OS_IPHONE ? 6 : 10;
    XCTAssertEqual((int) self.sut.maximumConcurrentRequests, maxRequests);
    
    self.sut.accessToken = self.validAccessToken;
    
    // when
    for(int i = 0; i < maxRequests + 1; ++i) {
        ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
            return nil;
        };
        ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:generator];
        
        // then
        XCTAssertFalse(result.didGenerateNonNullRequest, @"Iteration %d", i);
        XCTAssertTrue(result.didHaveLessRequestThanMax, @"Iteration %d", i);
    }
}

- (void)testThatItNotifiesTheOperationLoopWhenTheNumberOfRequestsDropsBelowTheMaximum
{
    // given
    int const maxRequests = TARGET_OS_IPHONE ? 6 : 10;
    XCTAssertEqual((int) self.sut.maximumConcurrentRequests, maxRequests);
    
    self.sut.accessToken = self.validAccessToken;
    
    // expect
    for (int i = 0; i < (maxRequests + 1); ++i) {
        [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
            TestResponse *r = [TestResponse testResponse];
            [r setBodyFromTransportData:@{@"i": @(i)}];
            r.statusCode = 200;
            return r;
        }];
    }
    
    // This is what will get called on the ZMOperationLoop:
    [self expectationForNotification:ZMTransportSessionNewRequestAvailableNotification object:nil handler:nil];
    
    // when
    // enqueuing max + 1 requests
    for (int i = 0; i < (maxRequests + 1); ++i) {
        NSString *path = [NSString stringWithFormat:@"/A/%d", i];
        ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:^(){
            ZMTransportRequest *r = [[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
            [r addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:self.fakeUIContext block:^(ZMTransportResponse * ZM_UNUSED response) {
            }]];
            return r;
        }];
        if (i < maxRequests - 1) {
            XCTAssertTrue(result.didGenerateNonNullRequest);
            XCTAssertTrue(result.didHaveLessRequestThanMax);
        } else if (i == maxRequests - 1) {
            XCTAssertTrue(result.didGenerateNonNullRequest);
            XCTAssertTrue(result.didHaveLessRequestThanMax);
        } else {
            XCTAssertFalse(result.didGenerateNonNullRequest);
            XCTAssertFalse(result.didHaveLessRequestThanMax);
        }
    }
    
    // then
    WaitForAllGroupsToBeEmpty(0.5);
    [self.scheduler.addedItems removeObject:[[ZMOpenPushChannelRequest alloc] init]];
    XCTAssertEqual(self.scheduler.addedItems.count, (NSUInteger) maxRequests);
    
    // when (2)
    NSMutableArray *originalRequests = [self.scheduler.addedItems mutableCopy];
    [self.scheduler.addedItems removeAllObjects];
    [self.sut sendSchedulerItem:originalRequests.firstObject];
    [originalRequests removeObjectAtIndex:0];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    {
        ZMTransportEnqueueResult *result = [self.sut attemptToEnqueueSyncRequestWithGenerator:^(){
            ZMTransportRequest *r = [[ZMTransportRequest alloc] initWithPath:@"/B" method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
            return r;
        }];
        WaitForAllGroupsToBeEmpty(0.5);
        
        // then (2)
        XCTAssertTrue(result.didGenerateNonNullRequest);
        XCTAssertTrue(result.didHaveLessRequestThanMax);
        [self.scheduler.addedItems removeObject:[[ZMOpenPushChannelRequest alloc] init]];
        XCTAssertEqual(self.scheduler.addedItems.count, 1u);
    }
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // finally (to make the mocks happy)
    [self.scheduler.addedItems addObjectsFromArray:originalRequests];
    for (id i in self.scheduler.addedItems) {
        [self.sut sendSchedulerItem:i];
    }
}

@end



@implementation ZMTransportSessionTests (AccessTokens_Cookies_Login)


- (void)testThatARequestsThatNeedAuthenticationGeneratesAuthenticationHeaders
{
    // given
    ZMTransportRequest *transportRequest = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNeedsAccess];
    
    self.sut.accessToken = [[ZMAccessToken alloc] initWithToken:@"token-213" type:@"tokentype" expiresInSeconds:100000];
    
    NSURLSessionTask *task = [OCMockObject niceMockForClass:FakeDataTask.class];
    __block NSURLRequest *request;
    [(ZMURLSession *)[[(id) self.URLSession expect] andReturn:task] taskWithRequest:ZM_ARG_SAVE(request) bodyData:nil transportRequest:transportRequest];
    
    // when
    [self.sut sendSchedulerItem:transportRequest];
    [self.queue waitUntilAllOperationsAreFinishedWithTimeout:0.2];
    
    // then
    XCTAssertNotNil(request);
    NSDictionary *headers = [request allHTTPHeaderFields];
    XCTAssertNotNil(headers);
    NSString *authHeader = headers[@"Authorization"];
    XCTAssertNotNil(authHeader);
    XCTAssertEqualObjects(authHeader, self.sut.accessToken.httpHeaders[@"Authorization"]);
}

- (void)testThatARequestsThatDoesNotNeedAuthenticationDoesNotGenerateAuthenticationHeaders
{
    // given
    ZMTransportRequest *transportRequest = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
    
    self.sut.accessToken = [[ZMAccessToken alloc] initWithToken:@"token-213" type:@"tokentype" expiresInSeconds:100000];
    
    NSURLSessionTask *task = [OCMockObject niceMockForClass:FakeDataTask.class];
    __block NSURLRequest *request;
    [(ZMURLSession *)[[(id)self.URLSession expect] andReturn:task] taskWithRequest:ZM_ARG_SAVE(request) bodyData:nil transportRequest:transportRequest];
    
    // when
    [self.sut sendSchedulerItem:transportRequest];
    [self.queue waitUntilAllOperationsAreFinishedWithTimeout:0.2];
    
    // then
    XCTAssertNotNil(request);
    NSDictionary *headers = [request allHTTPHeaderFields];
    XCTAssertNotNil(headers);
    XCTAssertNil(headers[@"Authorization"]);
}

- (void)testThatARequestThatCreatesAnAccessTokenDoesNotGenerateAuthenticationHeaders
{
    // given
    ZMTransportRequest *transportRequest = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken];
    
    self.sut.accessToken = [[ZMAccessToken alloc] initWithToken:@"token-213" type:@"tokentype" expiresInSeconds:100000];
    
    NSURLSessionTask *task = [OCMockObject niceMockForClass:FakeDataTask.class];
    __block NSURLRequest *request;
    [(ZMURLSession *)[[(id)self.URLSession expect] andReturn:task] taskWithRequest:ZM_ARG_SAVE(request) bodyData:nil transportRequest:transportRequest];
    
    // when
    [self.sut sendSchedulerItem:transportRequest];
    [self.queue waitUntilAllOperationsAreFinishedWithTimeout:0.2];
    
    // then
    XCTAssertNotNil(request);
    NSDictionary *headers = [request allHTTPHeaderFields];
    XCTAssertNotNil(headers);
    XCTAssertNil(headers[@"Authorization"]);
}

- (void)testThatItDoesNotAssertIfAPOSTRequestDoesNotHaveAPayload
{
    // given
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        return [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodPOST payload:nil authentication:ZMTransportRequestAuthNone];
    };
    
    // then
    XCTAssertNoThrow([self.sut attemptToEnqueueSyncRequestWithGenerator:generator]);
    
}

- (void)testThatItDoesNotAssertIfAPOSTRequestDoesHaveAPayload
{
    // given
    ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
        return [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodPUT payload:@[@34] authentication:ZMTransportRequestAuthNone];
    };
    
    // then
    XCTAssertNoThrow([self.sut attemptToEnqueueSyncRequestWithGenerator:generator]);
    
}

- (void)testThatItDoesNotAssertIfARequestTypeWithPayloadHasAPayload
{
    // given
    static const ZMTransportRequestMethod methodsWithPayload [] = {ZMMethodPOST, ZMMethodPUT};
    static const size_t size = sizeof(methodsWithPayload)/sizeof(methodsWithPayload[0]);
    
    for(size_t i = 0; i < size; ++i)
    {
        ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
            return [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:methodsWithPayload[i] payload:@[@42] authentication:ZMTransportRequestAuthNone];
        };
        
        // then
        XCTAssertNoThrow([self.sut attemptToEnqueueSyncRequestWithGenerator:generator]);
    }
}

- (void)testThatItDoesNotAssertIfARequestTypeWithoutPayloadDoesNotHaveAPayload
{
    // given
    static const ZMTransportRequestMethod methodsWithoutPayload [] = {ZMMethodHEAD, ZMMethodGET, ZMMethodDELETE};
    static const size_t size = sizeof(methodsWithoutPayload)/sizeof(methodsWithoutPayload[0]);
    
    for(size_t i = 0; i < size; ++i)
    {
        ZMTransportRequestGenerator generator = ^ZMTransportRequest*(void) {
            return [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:methodsWithoutPayload[i] payload:nil authentication:ZMTransportRequestAuthNone];
        };
        
        // then
        XCTAssertNoThrow([self.sut attemptToEnqueueSyncRequestWithGenerator:generator]);
    }
}


// 1 TODO testThatTheCookieIsSavedInAnAccessTokenResponseWithACookie


@end



@implementation ZMTransportSessionTests (Helper)


- (NSURLSessionTask *)mockURLSessionTaskWithResponseGenerator:(TestResponse *(^)(NSURLRequest *, NSData *))responseGenerator;
{
    
    __block NSURLRequest *request;
    __block NSData *requestData;
    __block ZMTransportRequest *transportRequest;
    
    NSUInteger const taskID = self.nextTaskIdentifier++;
    
    id task = [OCMockObject mockForClass:[FakeDataTask class]];
    
    [(ZMURLSession *)[[(id)self.URLSession expect] andReturn:task] taskWithRequest:ZM_ARG_SAVE(request)
                                                                          bodyData:ZM_ARG_SAVE(requestData)
                                                                  transportRequest:ZM_ARG_SAVE(transportRequest)
     ];
    
    void (^callCompletionHandler)(NSInvocation *) = ^(NSInvocation *invocation ZM_UNUSED) {
        
        TestResponse *testResponse = responseGenerator(request, requestData);
        if (testResponse == nil) {
            return; // Never completes
        }
        
        NSHTTPURLResponse *URLResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                     statusCode:testResponse.statusCode
                                                                    HTTPVersion:@"HTTP/1.1"
                                                                   headerFields:testResponse.headers];
        (void)[(NSURLSessionTask *)[[task stub] andReturn:URLResponse] response];
        (void)[(NSURLSessionTask *)[[task stub] andReturn:testResponse.error] error];
        
        [self.dispatchGroup enter];
        [self.queue addOperationWithBlock:^{
            id<ZMURLSessionDelegate> delegate = (id) self.sut;
            [delegate URLSessionDidReceiveData:self.URLSession];
            [delegate URLSession:self.URLSession taskDidComplete:task transportRequest:transportRequest responseData:testResponse.body];
            [self.dispatchGroup leave];
        }];
    };
    
    [[[task stub] andReturnValue:OCMOCK_VALUE(taskID)] taskIdentifier];
    [(NSURLSessionDataTask *)[[task expect] andDo:callCompletionHandler] resume];
    
    return task;
}

- (void)invokeAccessTokenRenewalFailureHandler:(ZMTransportResponse *)response
{
    ZMCompletionHandlerBlock strongHandler = self.failedAuthHandler;
    if(strongHandler) {
        strongHandler(response);
    }
}

@end



@implementation ZMTransportSessionTests (URLResponseForwardingToTheScheduler)

- (void)testThatItForwards_didReceiveResponse_toTheRequestScheduler;
{
    // given
    NSURL *URL = [NSURL URLWithString:@"https://baz.example.com/"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:URL statusCode:123 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    NSURLSessionDataTask *task = [OCMockObject niceMockForClass:FakeDataTask.class];
    (void)[(NSURLSessionDataTask *) [[(id) task stub] andReturn:response] response];
    (void)[(NSURLSessionDataTask *) [[(id) task stub] andReturn:nil] error];
    
    // when
    id<ZMURLSessionDelegate> d = (id) self.sut;
    [d URLSession:self.URLSession dataTask:task didReceiveResponse:response completionHandler:^(NSURLSessionResponseDisposition disposition) {
        XCTAssertEqual(disposition, NSURLSessionResponseAllow);
    }];
    
    // then
    XCTAssertEqual(self.scheduler.processedResponses.count, 1u);
    NSDictionary *expected = @{@"response": response};
    XCTAssertEqualObjects(self.scheduler.processedResponses.firstObject, expected);
}

- (void)testThatItForwards_didCompleteWithError_toTheRequestScheduler;
{
    // given
    NSURL *URL = [NSURL URLWithString:@"https://baz.example.com/"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:URL statusCode:123 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDNSLookupFailed userInfo:nil];
    NSURLSessionTask *task = [OCMockObject niceMockForClass:FakeDataTask.class];
    (void)[(NSURLSessionTask *) [[(id) task stub] andReturn:response] response];
    (void)[(NSURLSessionTask *) [[(id) task stub] andReturn:error] error];
    
    // when
    id<ZMURLSessionDelegate> d = (id) self.sut;
    [d URLSession:self.URLSession taskDidComplete:task transportRequest:nil responseData:nil];
    
    // then
    XCTAssertEqual(self.scheduler.processedResponses.count, 1u);
    NSDictionary *expected = @{@"response": response, @"error": error};
    XCTAssertEqualObjects(self.scheduler.processedResponses.firstObject, expected);
}

@end



@implementation ZMTransportSessionTests (CookieAndAccessTokenRenewal)


- (void)testThatItNotifiesTheSchedulerWhenItReceivesAnAccessToken;
{
    // given
    self.sut.cookieStorage.authenticationCookieData = [@"valid-cookie" dataUsingEncoding:NSUTF8StringEncoding];
    
    // The access token request:
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects(request.URL.path, @"/access");
        XCTAssertEqualObjects(request.HTTPMethod, @"POST");
        TestResponse *testResponse = [TestResponse testResponse];
        [testResponse setBodyFromTransportData:@{@"access_token": @"FakeToken",
                                                 @"token_type": @"FakeType",
                                                 @"expires_in": @3000}];
        [testResponse setStatusCode:200];
        return testResponse;
    }];
    
    // expect
    [[[(id)self.URLSessionSwitch expect] andReturn:self.URLSession ] foregroundSession];

    // when
    [self.sut sendAccessTokenRequest];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertNotNil(self.sut.accessToken);
    XCTAssertEqual(self.scheduler.accessTokenCount, 1);
}


- (void)testThatItDoesNotDeleteTheCookieWhenEncounteringANetworkErrorAfterLogin
{
    // given
    self.sut.accessToken = nil;
    [self setAuthenticationCookieData];
    
    // The 1st request that fails:
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects(request.URL.path, @"/access");
        XCTAssertEqualObjects(request.HTTPMethod, @"POST");
        
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotFindHost userInfo:nil];
        testResponse.statusCode = 0;
        
        // ignore following requests
        [(ZMURLSession *)[(id)self.URLSession stub] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:OCMOCK_ANY];
        
        return testResponse;
    }];
    
    // expect
    [[[(id)self.URLSessionSwitch expect] andReturn:self.URLSession ] foregroundSession];
    
    // when
    [self.sut sendAccessTokenRequest];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertNotNil(self.sut.cookieStorage.authenticationCookieData);
}


- (void)testThatItFailsARequestWith_TryAgainLater_IfTheAccessTokenWasInvalid
{
    // given
    self.sut.accessToken = self.validAccessToken;
    self.sut.cookieStorage.authenticationCookieData = [@"valid-cookie" dataUsingEncoding:NSUTF8StringEncoding];
    
    // The request will fail with a 401:
    NSDictionary *dummyPayload = @{@"b": @"B"};
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects(request.URL.path, self.dummyPath);
        XCTAssertEqualObjects(request.HTTPMethod, @"PUT");
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Authorization"],
                              @"valid-type valid-token",
                              @"This must use the original access token.");
        XCTAssertEqualObjects([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], dummyPayload);
        TestResponse *testResponse = [TestResponse testResponse];
        [testResponse setBodyFromTransportData:@{@"description": @"Oh, no!"}];
        [testResponse setStatusCode:401];
        return testResponse;
    }];
    WaitForAllGroupsToBeEmpty(0.1);
    
    __block ZMTransportResponse *response;
    XCTestExpectation *requestCompletedExpectation = [self expectationWithDescription:@"request completed"];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodPUT payload:dummyPayload];
    [request addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *r) {
        response = r;
        [requestCompletedExpectation fulfill];
    }]];
    
    // when
    [self.sut sendSchedulerItem:request];
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(response.result, ZMTransportResponseStatusTryAgainLater);
}

- (void)testThatItStoresCookiesFor_ZMTransportRequestAuthCreatesCookieAndAccessToken
{
    // given
    NSData *cookieData = [@"valid-cookie" dataUsingEncoding:NSUTF8StringEncoding];
    self.sut.cookieStorage.authenticationCookieData = cookieData;
    
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.body = [NSJSONSerialization dataWithJSONObject:@{@"a": @"A"} options:0 error:NULL];
        testResponse.headers = @{@"Set-Cookie": @"zuid=bar; Expires=Sun, 21-Jul-2024 09:06:45 GMT; Domain=example.com; HttpOnly; Secure",
                                 @"Content-Type": @"application/json"};
        return testResponse;
    }];
    
    // when
    ZMTransportRequest *request =  [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken];
    
    [self.sut sendSchedulerItem:request];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    AssertNotEqualData(self.sut.cookieStorage.authenticationCookieData, cookieData);
    XCTAssertNotNil(self.sut.cookieStorage.authenticationCookieData);
}


- (void)testThatItStoresCookiesFor_ZMTransportRequestAuthNeedsAccess
{
    // given
    NSData *cookieData = [@"valid-cookie" dataUsingEncoding:NSUTF8StringEncoding];
    self.sut.cookieStorage.authenticationCookieData = cookieData;

    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.body = [NSJSONSerialization dataWithJSONObject:@{@"a": @"A"} options:0 error:NULL];
        testResponse.headers = @{@"Set-Cookie": @"zuid=bar; Expires=Sun, 21-Jul-2024 09:06:45 GMT; Domain=example.com; HttpOnly; Secure",
                                 @"Content-Type": @"application/json"};
        return testResponse;
    }];
    
    // when
    ZMTransportRequest *request =  [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNeedsAccess];
    
    [self.sut sendSchedulerItem:request];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    AssertNotEqualData(self.sut.cookieStorage.authenticationCookieData, cookieData);
    XCTAssertNotNil(self.sut.cookieStorage.authenticationCookieData);
}


- (void)testThatItStoresCookiesBeforeCallingTheCompletionHandler;
{
    // TODO
    // given
    self.sut.accessToken = nil;
    XCTAssertNil(self.sut.cookieStorage.authenticationCookieData);
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.body = [NSJSONSerialization dataWithJSONObject:@{@"a": @"A"} options:0 error:NULL];
        testResponse.headers = @{@"Set-Cookie": @"zuid=bar; Expires=Sun, 21-Jul-2024 09:06:45 GMT; Domain=example.com; HttpOnly; Secure",
                                 @"Content-Type": @"application/json"};
        return testResponse;
    }];
    
    // when
    XCTestExpectation *didRun = [self expectationWithDescription:@"completion handler"];
    ZMTransportRequest *request =  [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken];
    ZMPersistentCookieStorage *cookieStorage = self.sut.cookieStorage;
    [request addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:self.fakeUIContext block:^(ZMTransportResponse * ZM_UNUSED r) {
        XCTAssertNotNil(cookieStorage.authenticationCookieData);
        [didRun fulfill];
    }]];
    
    [self.sut sendSchedulerItem:request];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)setCookieData;
{
    // Set cookie on cookie storage:
    NSDictionary *originalHeaders = @{@"Set-Cookie": @"zuid=bar; Expires=Sun, 21-Jul-2024 09:06:45 GMT; Domain=example.com; HttpOnly; Secure"};
    NSURL *URL = [NSURL URLWithString:@"http://www.example.com"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:originalHeaders];
    [self.sut.cookieStorage setCookieDataFromResponse:response forURL:URL];
}


@end


@implementation ZMTransportSessionTests (PushChannel)

- (void)testThatItCreatesAPushChannelInstance;
{
    XCTAssertNotNil(currentFakePushChannel);
    XCTAssertEqualObjects(currentFakePushChannel.URL, self.webSocketURL);
    XCTAssertEqualObjects(currentFakePushChannel.userAgentString, [ZMUserAgent userAgentValue]);
    XCTAssertEqualObjects(currentFakePushChannel.scheduler, self.scheduler);
}


- (void)testThatItDoesNotOpenThePushChannelConnectionWhenItSetsTheAccessTokenToNil
{
    // when
    [self.sut setAccessToken:nil];
    
    // then
    XCTAssertEqual(currentFakePushChannel.createPushChannelCount, 0u);
}

- (void)testThatItSchedulesOpeningThePushChannelWhenTHeMaximumNumberOfConcurrentRequestsIncrease
{
    // when
    [self.sut schedulerIncreasedMaximumNumberOfConcurrentRequests:(id)self.scheduler];
    
    // then
    XCTAssertEqual(currentFakePushChannel.scheduleOpenPushChannelCount, 1u);
}

- (void)testThatItForwardsReachabilityDidChangeToThePushChannel
{
    // when
    XCTAssertEqual(currentFakePushChannel.reachabilityChangeCount, 0u);
    [self.sut reachabilityDidChange:[OCMockObject niceMockForClass:ZMReachability.class]];
    
    // then
    XCTAssertEqual(currentFakePushChannel.reachabilityChangeCount, 1u);
}

- (void)testThatItForwardsOpenPushChannel
{
    // given
    XCTAssertEqual(currentFakePushChannel.setConsumerCount, 0u);

    // when
    id consumer = [OCMockObject niceMockForProtocol:@protocol(ZMPushChannelConsumer)];
    [self.sut openPushChannelWithConsumer:consumer groupQueue:self.fakeUIContext];
    
    // then
    XCTAssertEqual(currentFakePushChannel.setConsumerCount, 1u);
}

- (void)testThatItForwardsClosePushChannel
{
    // given
    XCTAssertEqual(currentFakePushChannel.closeAndRemoveConsumerCount, 0u);
    
    // when
    [self.sut closePushChannelAndRemoveConsumer];
    
    // then
    XCTAssertEqual(currentFakePushChannel.closeAndRemoveConsumerCount, 1u);
}

- (void)testThatItCreatesAPushChannelConnectionWhenWeAreReceivingAnOpenPushChannelItemAndHaveAnAccessToken
{
    // given
    self.sut.accessToken = self.validAccessToken;
    NSUInteger const originalCount = currentFakePushChannel.createPushChannelCount;
    
    // when
    [self.sut sendSchedulerItem:[[ZMOpenPushChannelRequest alloc] init]];
    
    // then
    XCTAssertEqual(currentFakePushChannel.createPushChannelCount, originalCount + 1u);
    XCTAssertEqualObjects(currentFakePushChannel.lastAccessToken, self.validAccessToken);
    XCTAssertEqualObjects(currentFakePushChannel.lastClientID, self.sut.clientID);
}

- (void)testThatItDoesNotCreatesAPushChannelConnectionWhenWeAreBackgroundedAndThereIsNoActiveCall
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    self.sut.accessToken = self.validAccessToken;
    NSUInteger const originalCount = currentFakePushChannel.createPushChannelCount;
    
    // when
    [self.sut enterBackground];
    [self.sut sendSchedulerItem:[[ZMOpenPushChannelRequest alloc] init]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(currentFakePushChannel.createPushChannelCount, originalCount + 1u);
}

- (void)testThatItCreatesAPushChannelConnectionWhenWeAreBackgroundedAndThereIsAnActiveCall
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    self.sut.accessToken = self.validAccessToken;
    NSUInteger const originalCount = currentFakePushChannel.createPushChannelCount;
    
    // when
    [self.sut enterBackground];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:nil userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey : @YES}];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.sut sendSchedulerItem:[[ZMOpenPushChannelRequest alloc] init]];
    
    // then
    XCTAssertEqual(currentFakePushChannel.createPushChannelCount, originalCount+1);
}

- (void)testThatItDoesNotCreatAPushChannelConnectionWhenWeAreReceivingAnOpenPushChannelItemAndDoNotHaveAnAccessToken
{
    // given
    self.sut.accessToken = nil;
    NSUInteger const originalCount = currentFakePushChannel.createPushChannelCount;
    
    // when
    [self.sut sendSchedulerItem:[[ZMOpenPushChannelRequest alloc] init]];
    
    // then
    XCTAssertEqual(currentFakePushChannel.createPushChannelCount, originalCount);
}


- (void)testThatItDoesNotAttemptToOpenThePushChannelWhenLoginFails
{
    // given
    self.sut.cookieStorage.authenticationCookieData = nil;
    self.sut.accessToken = nil;
    id consumer = [OCMockObject niceMockForProtocol:@protocol(ZMPushChannelConsumer)];
    [self verifyMockLater:consumer];
    
    // when
    [self.sut openPushChannelWithConsumer:consumer groupQueue:self.fakeSyncContext];
    
    WaitForAllGroupsToBeEmpty(0.5);
    [self.scheduler.addedItems removeAllObjects];
    
    NSString *path = @"/activate/send";
    NSDictionary *payload = @{@"label": @"pending-activation"};
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects(request.URL.path, path);
        TestResponse *testResponse = [TestResponse testResponse];
        testResponse.statusCode = 403;
        [testResponse setBodyFromTransportData:payload];
        return testResponse;
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.sut sendSchedulerItem:[[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken]];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // after
    XCTAssertFalse([self.scheduler.addedItems containsObject:[[ZMOpenPushChannelRequest alloc] init]]);
}
 

@end



@implementation ZMTransportSessionTests (ImageDownload)

- (void)testThatItCanDownloadBinaryImageData;
{
    // given
    NSData *jpegData = [self verySmallJPEGData];
    self.sut.accessToken = self.validAccessToken;
    
    // expect
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *response = [TestResponse testResponse];
        response.body = jpegData;
        response.statusCode = 200;
        response.headers = @{@"Content-Length": [NSString stringWithFormat:@"%lld", (long long) response.body.length],
                             @"Content-Type": @"image/jpeg"};
        return response;
    }];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    
    // when
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:self.dummyPath method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNone];
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response ZM_UNUSED) {
        XCTAssertEqualObjects(response.imageData, jpegData);
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
}

@end



@implementation ZMTransportSessionTests (Timeout)


- (void)testThatItCancelsATaskAfterATimeout
{
    // given
    self.sut.accessToken = self.validAccessToken;
    NSURLSessionTask *dataTask = [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        return nil;
    }];

    
    [[(id)self.URLSession expect] setTimeoutTimer:OCMOCK_ANY forTask:dataTask];
    XCTestExpectation *expectation = [self expectationWithDescription:@"did cancel task"];
    
    // expect
    [[[(id)self.URLSession expect] andDo:^(NSInvocation * ZM_UNUSED i) {
        [expectation fulfill];
    }] cancelTaskWithIdentifier:dataTask.taskIdentifier completionHandler:OCMOCK_ANY]; //this is the important part
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestGetFromPath:@"/foo"];
    [request expireAfterInterval:0.2];

    [self.sut sendSchedulerItem:request];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)testThatItDoesNotSetTheTimoutIntervalOnARequestWhenInTheBackgroundAndUsingTheBackgroundSession
{
    // when
    NSURLSessionTask *task = [self suspendedTaskForBackgroundSession:YES applicationInBackground:YES];
    
    // then
    XCTAssertEqual(task.originalRequest.timeoutInterval, 60);
}

- (void)testThatItDoesNotSetTheTimoutIntervalOnARequestWhenInTheForegroundAndUsingTheBackgroundSession
{
    // when
    NSURLSessionTask *task = [self suspendedTaskForBackgroundSession:YES applicationInBackground:NO];
    
    // then
    XCTAssertEqual(task.originalRequest.timeoutInterval, 60);
}

- (void)testThatItDoesNotSetTheTimoutIntervalOnARequestWhenInTheForegroundAndNotUsingTheBackgroundSession
{
    // when
    NSURLSessionTask *task = [self suspendedTaskForBackgroundSession:NO applicationInBackground:NO];
    
    // then
    XCTAssertEqual(task.originalRequest.timeoutInterval, 60);
}

- (void)testThatItSetsTheTimoutIntervalOnARequestWhenInTheBackgroundAndNotUsingTheBackgroundSession
{
    // when
    NSURLSessionTask *task = [self suspendedTaskForBackgroundSession:NO applicationInBackground:YES];
    
    // then
    XCTAssertEqual(task.originalRequest.timeoutInterval, 25);
}

- (NSURLSessionTask *)suspendedTaskForBackgroundSession:(BOOL)backgroundSession applicationInBackground:(BOOL)applicationInBackground
{
    ZMTransportRequest *request = [ZMTransportRequest requestGetFromPath:@"/foo"];
    
    if (applicationInBackground) {
        [[(id)self.URLSessionSwitch expect] switchToBackgroundSession];
        [self.sut enterBackground];
    }
    
    id delegate = [OCMockObject niceMockForProtocol:@protocol(ZMURLSessionDelegate)];
    
    NSURLSessionConfiguration *configuration;
    if (backgroundSession) {
        configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:ZMURLSessionBackgroundIdentifier];
    } else {
        configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    }
    
    ZMURLSession *session = [ZMURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:NSOperationQueue.mainQueue identifier:nil];
    if (backgroundSession) {
        XCTAssertTrue(session.isBackgroundSession);
    }
    
    NSURLSessionTask *task = [self.sut suspendedTaskForRequest:request onSession:session];
    [session tearDown];
    return task;
}

- (void)testThatItSendsAnAppropriateResponseWhenATaskWasCancelled
{
    // given
    self.sut.accessToken = self.validAccessToken;
    NSURLSessionTask *task = [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        TestResponse *response = [TestResponse testResponse];
        response.statusCode = 0;
        response.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        return response;
    }];
    
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    __block ZMTransportResponse *receivedResponse;
    
    // expect
    __block ZMTimer *timer;
    [[(id) self.URLSession expect] setTimeoutTimer:ZM_ARG_SAVE(timer) forTask:task];
    
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestGetFromPath:@"/foo"];
    [request expireAfterInterval:0.5];
    
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response) {
        receivedResponse = response;
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];

    
    // then
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForAllGroupsToBeEmpty(0.5);
    [timer cancel];
    
    XCTAssertNotNil(receivedResponse.transportSessionError);
    XCTAssertEqualObjects(receivedResponse.transportSessionError.domain, ZMTransportSessionErrorDomain);
    XCTAssertEqual(receivedResponse.transportSessionError.code, (long)ZMTransportSessionErrorCodeTryAgainLater);
    XCTAssertEqual(receivedResponse.result, ZMTransportResponseStatusTryAgainLater);
    XCTAssertNil(receivedResponse.payload);
    
}

//TODO with our current setup we can't really test the result of timing out a request.

//- (void)testThatItSendsAnAppropriateResponseWhenATaskWasCancelledBecauseOfTimeout
//{
//    
//    self.sut.accessToken = self.validAccessToken;
//    NSURLSessionTask *dataTask = [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
//        return nil;
//    }];
//    
//    
//    [[self.URLSession stub] getTasksWithCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
//        void (^block)(NSArray *, NSArray *, NSArray *) = obj;
//        block(@[dataTask], @[], @[]);
//        return YES;
//    }]];
//    
//    XCTestExpectation *expectation = [self expectationWithDescription:@"did cancel task"];
//    
//    // expect
//    [[[(id)dataTask expect] andDo:^(NSInvocation * ZM_UNUSED i) {
//        [expectation fulfill];
//    }] cancel]; //this is the important part
//    
//    // when
//    ZMTransportRequest *request = [ZMTransportRequest requestGetFromPath:@"/foo"];
//    
//    __block ZMTransportResponse *receivedResponse;
//    [request addCompletionHandler:
//     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response) {
//        receivedResponse = response;
//    }]];
//    [request expireAfterInterval:0.05];
//    
//    [self.sut sendSchedulerItem:request];
//    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
//    WaitForAllGroupsToBeEmpty(0.5);
//    
//    XCTAssertNotNil(receivedResponse.transportSessionError);
//    XCTAssertEqualObjects(receivedResponse.transportSessionError.domain, ZMTransportSessionErrorDomain);
//    XCTAssertEqual(receivedResponse.transportSessionError.code, (long)ZMTransportSessionErrorCodeRequestExpired);
//    XCTAssertEqual(receivedResponse.result, ZMTransportResponseStatusExpired);
//    XCTAssertNil(receivedResponse.payload);
// 
//}

@end



@implementation ZMTransportSessionTests (Backoff)

- (void)testThatItCorrectlyInterpretsURLErrors;
{
    NSInteger const cancelledErrors[] = {
        NSURLErrorCancelled,
    };
    NSInteger const timedOutErrors[] = {
        NSURLErrorTimedOut,
    };
    NSInteger const networkErrors[] = {
        NSURLErrorUnknown,
        NSURLErrorBadURL,
        NSURLErrorUnsupportedURL,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorHTTPTooManyRedirects,
        NSURLErrorResourceUnavailable,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorRedirectToNonExistentLocation,
        NSURLErrorBadServerResponse,
        NSURLErrorUserCancelledAuthentication,
        NSURLErrorUserAuthenticationRequired,
        NSURLErrorZeroByteResource,
        NSURLErrorCannotDecodeRawData,
        NSURLErrorCannotDecodeContentData,
        NSURLErrorCannotParseResponse,
        NSURLErrorFileDoesNotExist,
        NSURLErrorFileIsDirectory,
        NSURLErrorNoPermissionsToReadFile,
        NSURLErrorDataLengthExceedsMaximum,
        
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
        NSURLErrorCannotLoadFromNetwork,
        
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
        NSURLErrorRequestBodyStreamExhausted,
        
        NSURLErrorBackgroundSessionRequiresSharedContainer,
        NSURLErrorBackgroundSessionInUseByAnotherProcess,
        NSURLErrorBackgroundSessionWasDisconnected,
    };
    for (size_t i = 0; i < sizeof(cancelledErrors)/sizeof(*cancelledErrors); ++i) {
        NSError *sut = [NSError errorWithDomain:NSURLErrorDomain code:cancelledErrors[i] userInfo:nil];
        XCTAssertTrue(sut.isCancelledURLTaskError, @"%@", sut);
        XCTAssertFalse(sut.isTimedOutURLTaskError, @"%@", sut);
        XCTAssertFalse(sut.isURLTaskNetworkError, @"%@", sut);
    }
    for (size_t i = 0; i < sizeof(timedOutErrors)/sizeof(*timedOutErrors); ++i) {
        NSError *sut = [NSError errorWithDomain:NSURLErrorDomain code:timedOutErrors[i] userInfo:nil];
        XCTAssertFalse(sut.isCancelledURLTaskError, @"%@", sut);
        XCTAssertTrue(sut.isTimedOutURLTaskError, @"%@", sut);
        XCTAssertFalse(sut.isURLTaskNetworkError, @"%@", sut);
    }
    for (size_t i = 0; i < sizeof(networkErrors)/sizeof(*networkErrors); ++i) {
        NSError *sut = [NSError errorWithDomain:NSURLErrorDomain code:networkErrors[i] userInfo:nil];
        XCTAssertFalse(sut.isCancelledURLTaskError, @"%@", sut);
        XCTAssertFalse(sut.isTimedOutURLTaskError, @"%@", sut);
        XCTAssertTrue(sut.isURLTaskNetworkError, @"%@", sut);
    }
    {
        NSError *sut = [NSError errorWithDomain:NSCocoaErrorDomain code:timedOutErrors[0] userInfo:nil];
        XCTAssertFalse(sut.isCancelledURLTaskError, @"%@", sut);
        XCTAssertFalse(sut.isTimedOutURLTaskError, @"%@", sut);
        XCTAssertFalse(sut.isURLTaskNetworkError, @"%@", sut);
    }
}

- (void)testThatItFailsRequestsWith_TryAgain_WhenTheErrorIsNetworkRelated
{
    // given
    self.sut.accessToken = self.validAccessToken;
    currentReachability.mayBeReachable = YES;
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodGET payload:nil];
    
    // expect
    XCTestExpectation *didComplete = [self expectationWithDescription:@"did complete response"];
    [request addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:self.fakeUIContext block:^(ZMTransportResponse *response){
        XCTAssertEqualObjects(response.transportSessionError.domain, ZMTransportSessionErrorDomain);
        XCTAssertEqual(response.transportSessionError.code, ZMTransportSessionErrorCodeTryAgainLater);
        XCTAssertEqual(response.result, ZMTransportResponseStatusTryAgainLater);
        [didComplete fulfill];
    }]];
    [self mockURLSessionTaskWithResponseGenerator:^(NSURLRequest * ZM_UNUSED r2, NSData * ZM_UNUSED data) {
        TestResponse *r = [TestResponse testResponse];
        r.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotFindHost userInfo:nil];
        return r;
    }];
    
    // when
    [self.sut sendSchedulerItem:request];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatItFailsRequestsWith_TryAgain_WhenTheServerAsksUsToBackOff
{
    [self checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:420 failureRecorder:NewFailureRecorder()];
    [self checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:429 failureRecorder:NewFailureRecorder()];
}

- (void)testThatItFailsRequestsWith_TryAgain_WhenTheServerReturnsAnInternalError
{
    [self checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:500 failureRecorder:NewFailureRecorder()];
    [self checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:512 failureRecorder:NewFailureRecorder()];
    [self checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:578 failureRecorder:NewFailureRecorder()];
    [self checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:599 failureRecorder:NewFailureRecorder()];
}

- (void)checkThatItFailsTheRequestsWith_TryAgain_WhenTheServerReturnsStatusCode:(NSInteger)statusCode failureRecorder:(ZMTFailureRecorder *)fr;
{
    // given
    self.sut.accessToken = self.validAccessToken;
    currentReachability.mayBeReachable = YES;
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:self.dummyPath method:ZMMethodGET payload:nil];
    
    // expect
    XCTestExpectation *didComplete = [self expectationWithDescription:@"did complete response"];
    [request addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:self.fakeUIContext block:^(ZMTransportResponse *response){
        FHAssertEqualObjects(fr, response.transportSessionError.domain, ZMTransportSessionErrorDomain);
        FHAssertEqual(fr, response.transportSessionError.code, ZMTransportSessionErrorCodeTryAgainLater);
        FHAssertEqual(fr, response.result, ZMTransportResponseStatusTryAgainLater);
        [didComplete fulfill];
    }]];
    [self mockURLSessionTaskWithResponseGenerator:^(NSURLRequest * ZM_UNUSED r2, NSData * ZM_UNUSED data) {
        TestResponse *r = [TestResponse testResponse];
        r.statusCode = statusCode;
        r.headers = @{@"Content-Type": @"application/json"};
        r.body = [@"We're busy" dataUsingEncoding:NSUTF8StringEncoding];
        return r;
    }];
    
    // when
    [self.sut sendSchedulerItem:request];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatItForwardsReachabilityChangesToTheScheduler;
{
    // given
    ZMReachability *reachability = (id) currentReachability;
    
    // when
    [self.sut reachabilityDidChange:reachability];
    
    //then
    XCTAssertEqual(self.scheduler.reachabilityChangedCount, 1);

    // when
    [self.sut reachabilityDidChange:reachability];
    
    //then
    XCTAssertEqual(self.scheduler.reachabilityChangedCount, 2);
}

@end



@implementation ZMTransportSessionTests (Reachability)

- (void)testThatItCallsDidReceiveDataOnTheReachabilityDelegate
{
    // given
    id observer = [OCMockObject mockForProtocol:@protocol(ZMNetworkStateDelegate)];
    [[observer expect] didReceiveData];
    self.sut.networkStateDelegate = observer;
    
    // expect
    [[observer expect] didReceiveData];
    
    // when
    [self.sut updateNetworkStatusFromDidReadDataFromNetwork];
    
    // then
    [observer verify];
}

- (void)testThatItCallsDidFailRequestOnTheReachabilityDelegate
{
    // given
    id observer = [OCMockObject mockForProtocol:@protocol(ZMNetworkStateDelegate)];
    [[observer expect] didReceiveData];
    self.sut.networkStateDelegate = observer;
    
    // expect
    [[observer expect] didGoOffline];
    
    // when
    [self.sut schedulerWentOffline:nil];
    
    // then
    [observer verify];
}

- (void)testThatItSendsTransportSessionReachabilityChangeNotificationOnReachabilityChanges
{
    // expect
    [self expectationForNotification:ZMTransportSessionReachabilityChangedNotificationName object:nil handler:nil];
    
    // when
    [self.sut reachabilityDidChange:self.sut.reachability];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)testThatItSendsTransportSessionReachabilityChangeNotificationOnReachabilityChangesToOffline
{
    // given
    id reachbilityMock = [OCMockObject mockForClass:[ZMReachability class]];
    [[[reachbilityMock stub] andReturnValue:@NO] mayBeReachable];

    // expect
    [self expectationForNotification:ZMTransportSessionReachabilityChangedNotificationName object:nil handler:nil];

    // when
    [self.sut reachabilityDidChange:reachbilityMock];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)testThatWhenSettingTheNetworkStateDelegateItIsCalledWithTheCurrentStatus
{
    // given
    FakeReachability *reachability = currentReachability;
    id mockDelegate = [OCMockObject mockForProtocol:@protocol(ZMNetworkStateDelegate)];
    
    {
        // given
        reachability.mayBeReachable = NO;
        
        // expect
        [[mockDelegate expect] didGoOffline];
        
        // when
        [self.sut setNetworkStateDelegate:mockDelegate];
    }
    
    {
        // given
        reachability.mayBeReachable = YES;
        
        // expect
        [[mockDelegate expect] didReceiveData];
        
        // when
        [self.sut setNetworkStateDelegate:mockDelegate];
    }

    [mockDelegate verify];
}

@end



@implementation ZMTransportSessionTests (Background)

- (void)testThatItSendsAnAccessTokenRequestInPreparationForSuspendedStateIfThereAreRunningTasks;
{
    // given
    [self setCookieData];
    
    // expect (1)
    __block void(^countHandler)(NSUInteger);
    XCTestExpectation *countExpectation = [self expectationWithDescription:@"get task count"];
    [[(id) self.URLSession stub] countTasksWithCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
        countHandler = obj;
        [countExpectation fulfill];
        return YES;
    }]];
    [(id<ZMBackgroundable>) self.sut prepareForSuspendedState];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    
    // expect
    XCTestExpectation *accessToken = [self expectationWithDescription:@"access token requested"];
    [self mockURLSessionTaskWithResponseGenerator:^(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        XCTAssertEqualObjects(request.URL.path, @"/access");
        XCTAssertEqualObjects(request.HTTPMethod, @"POST");
        TestResponse *testResponse = [TestResponse testResponse];
        [testResponse setBodyFromTransportData:@{@"access_token": @"FakeToken",
                                                 @"token_type": @"FakeType",
                                                 @"expires_in": @3000}];
        [testResponse setStatusCode:200];
        [accessToken fulfill];
        return testResponse;
    }];
    
    // expect
    [[[(id)self.URLSessionSwitch expect] andReturn:self.URLSession ] foregroundSession];
    
    // when
    countHandler(1);
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatItDoesNotSendAnAccessTokenRequestInPreparationForSuspendedStateIfThereAreNoRunningTasks;
{
    // given
    [self setCookieData];
    
    // expect (1)
    __block void(^countHandler)(NSUInteger);
    XCTestExpectation *countExpectation = [self expectationWithDescription:@"get task count"];
    [[(id) self.URLSession stub] countTasksWithCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
        countHandler = obj;
        [countExpectation fulfill];
        return YES;
    }]];
    [(id<ZMBackgroundable>) self.sut prepareForSuspendedState];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    
    // reject
    [(ZMURLSession *)[(id)self.URLSession reject] taskWithRequest:OCMOCK_ANY
                                                         bodyData:OCMOCK_ANY
                                                 transportRequest:OCMOCK_ANY];
    
    // when
    countHandler(0);
    WaitForAllGroupsToBeEmpty(0.5);
}


- (void)testThatItClosesThePushChannelWhenTheApplicationSuspends;
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    NSUInteger const originalCount = currentFakePushChannel.closeCount;
    
    // when
    [self.sut enterBackground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertGreaterThan(currentFakePushChannel.closeCount, originalCount);
}


- (void)testThatItDoesNotCloseThePushChannelWhenItReceivedAShouldKeepWebsocketOpenNotification_YES
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    NSUInteger const originalCount = currentFakePushChannel.closeCount;
    
    // when
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:nil userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey : @YES}];
    [self.sut enterBackground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(currentFakePushChannel.closeCount, originalCount);
}

- (void)testThatItClosesThePushChannelWhenItReceivedAShouldKeepWebsocketOpenNotification_NO
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    NSUInteger const originalCount = currentFakePushChannel.closeCount;
    
    // when
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:nil userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey : @YES}];
    [self.sut enterBackground];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:nil userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey : @NO}];

    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertGreaterThan(currentFakePushChannel.closeCount, originalCount);
}

- (void)testThatItOpensThePushChannelWhenItReceivedAShouldKeepWebsocketOpenNotification_YES
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    NSUInteger const originalCount = currentFakePushChannel.scheduleOpenPushChannelCount;
    
    // when
    [self.sut enterBackground];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:nil userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey : @YES}];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertGreaterThan(currentFakePushChannel.scheduleOpenPushChannelCount, originalCount);
}

- (void)testThatItOpensThePushChannelWhenTheApplicationWillEnterForeground;
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    
    // when
    [self.sut enterBackground];
    WaitForAllGroupsToBeEmpty(0.5);
    NSUInteger const originalCount = currentFakePushChannel.scheduleOpenPushChannelCount;
    
    // when
    [self.sut enterForeground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertGreaterThan(currentFakePushChannel.scheduleOpenPushChannelCount, originalCount);
}


- (void)testThatItNotifiesTheSchedulerWhenTheApplicationWillEnterForeground;
{
    // given
    [[(id)self.URLSessionSwitch stub] switchToBackgroundSession];
    [[(id)self.URLSessionSwitch stub] switchToForegroundSession];
    
     [self.sut enterBackground];
    WaitForAllGroupsToBeEmpty(0.5);
    int const originalCount = self.scheduler.enterForegroundCount;
    
    // when
     [self.sut enterForeground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertGreaterThan(self.scheduler.enterForegroundCount, originalCount);
}

- (void)testThatItNotifiesTheSwitchWhenItEntersBackground
{
    // expect
    [[(id)self.URLSessionSwitch expect] switchToBackgroundSession];
    
    // when
    [self.sut enterBackground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [(id)self.URLSessionSwitch verify];
}

- (void)testThatItNotifiesTheSwitchWhenItEntersForeground
{
    // expect
    [[(id)self.URLSessionSwitch expect] switchToForegroundSession];
    
    // when
    [self.sut enterForeground];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    [(id)self.URLSessionSwitch verify];
}

- (void)testThatItStoresAndCallsTheCompletionHandlerWhen_URLSessionDidFinishEventsForBackgroundURLSession_IsCalled
{
    // given
    __block NSUInteger callCount = 0;
    __block NSThread *callThread;
    
    id mockDelegate = [OCMockObject niceMockForProtocol:@protocol(ZMURLSessionDelegate)];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:self.name];
    ZMURLSession *session = [ZMURLSession sessionWithConfiguration:configuration delegate:mockDelegate delegateQueue:self.queue identifier:@"test-session"];
    XCTestExpectation *expectation = [self expectationWithDescription:@"It should call the completion handler on the main thread"];
    
    // when
    [self.sut addCompletionHandlerForBackgroundSessionWithIdentifier:configuration.identifier handler:^{
        callCount++;
        callThread = NSThread.currentThread;
        [expectation fulfill];
    }];
    
    // then
    [self spinMainQueueWithTimeout:0.1];
    XCTAssertEqual(callCount, 0lu);
    
    // when
    [self.sut URLSessionDidFinishEventsForBackgroundURLSession:session];
    [self.sut URLSessionDidFinishEventsForBackgroundURLSession:session];
    
    // then
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
    XCTAssertEqual(callCount, 1lu);
    XCTAssertNotNil(callThread);
    XCTAssertTrue(callThread.isMainThread);
    [session tearDown];
}

- (void)testThatItGetsTheCurrentTasksForTheBackgroundSession
{
    // given
    XCTestExpectation *expectation = [self expectationWithDescription:@"It should get the resumed background session tasks"];
    ZMTransportRequest *foregroundRequest = [ZMTransportRequest requestGetFromPath:@"/some/path/foreground"];
    ZMTransportRequest *backgroundRequest = [ZMTransportRequest requestGetFromPath:@"/some/path/background"];
    
    // expect
    NSURLSessionTask *expectedTask = [NSURLSessionTask new];
    id backgroundSessionMock = [OCMockObject mockForClass:ZMURLSession.class];
    [[(id)backgroundSessionMock expect] isBackgroundSession];
    [[[backgroundSessionMock stub] andReturn:[NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:self.name]] configuration];
    [[[(id)self.URLSessionSwitch stub] andReturn:backgroundSessionMock] backgroundSession];
    [[(id)self.URLSession expect] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:foregroundRequest];
    [[(id)backgroundSessionMock expect] taskWithRequest:OCMOCK_ANY bodyData:OCMOCK_ANY transportRequest:backgroundRequest];
    
    [(ZMURLSession *)[backgroundSessionMock expect] getTasksWithCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
        void (^block)(NSArray <NSURLSessionTask *>*) = obj;
        block(@[expectedTask]);
        return YES;
    }]];
    
    [self mockURLSessionTaskWithResponseGenerator:^TestResponse *(NSURLRequest *request ZM_UNUSED, NSData *data ZM_UNUSED) {
        return [TestResponse testResponse];
    }];
    
    [backgroundRequest forceToBackgroundSession];
    
    [self.sut sendSchedulerItem:foregroundRequest];
    [self.sut sendSchedulerItem:backgroundRequest];
    
    // when
    [self.sut getBackgroundTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *backgroundTasks) {
        XCTAssertEqualObjects(expectedTask, backgroundTasks.firstObject);
        XCTAssertEqual(backgroundTasks.count, 1lu);
        [expectation fulfill];
    }];
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)testThatItCancelsATaskOnTheCorrectURLSession_Identifier
{
    // given
    ZMTaskIdentifier *identifier = [ZMTaskIdentifier identifierWithIdentifier:42 sessionIdentifier:@"background-session"];
    
    // expect
    id backgroundSessionMock = [OCMockObject niceMockForClass:ZMURLSession.class];
    id foregroundSessionMock = [OCMockObject niceMockForClass:ZMURLSession.class];

    [[[(id)self.URLSessionSwitch stub] andReturn:@[foregroundSessionMock, backgroundSessionMock]] allSessions];
    [[(id)backgroundSessionMock expect] cancelTaskWithIdentifier:42 completionHandler:OCMOCK_ANY];
    [(ZMURLSession *)[[backgroundSessionMock stub] andReturn:@"background-session"] identifier];
    [[(id)foregroundSessionMock reject] cancelTaskWithIdentifier:42 completionHandler:OCMOCK_ANY];
    [(ZMURLSession *)[[foregroundSessionMock stub] andReturn:@"foreground-session"] identifier];
    
    // when
    [self.sut cancelTaskWithIdentifier:identifier];
    
    // then
    [backgroundSessionMock verify];
    [foregroundSessionMock verify];
}

@end


@implementation ZMTransportSessionTests (ExpirationDate)

- (void)testThatItCompletesAnExpiredTransportRequestWithErrorCodeRequestExpired
{
    // given
    XCTestExpectation *expectation = [self expectationWithDescription:@"Completion handler called"];
    __block ZMTransportResponse *receivedResponse;
        
    // when
    ZMTransportRequest *request = [ZMTransportRequest requestGetFromPath:@"/foo"];
    [request expireAfterInterval:0];
    
    [request addCompletionHandler:
     [ZMCompletionHandler handlerOnGroupQueue:self.fakeSyncContext block:^(ZMTransportResponse *response) {
        receivedResponse = response;
        [expectation fulfill];
    }]];
    [self.sut sendSchedulerItem:request];
    
    // then
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
    WaitForAllGroupsToBeEmpty(0.5);
    
    XCTAssertNotNil(receivedResponse.transportSessionError);
    XCTAssertEqualObjects(receivedResponse.transportSessionError.domain, ZMTransportSessionErrorDomain);
    XCTAssertEqual(receivedResponse.transportSessionError.code, (long)ZMTransportSessionErrorCodeRequestExpired);
    XCTAssertEqual(receivedResponse.result, ZMTransportResponseStatusExpired);
}

@end
