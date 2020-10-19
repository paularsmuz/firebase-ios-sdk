/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>
#import "OCMock.h"

#import "FirebaseCore/Sources/Private/FirebaseCoreInternal.h"
#import "FirebaseRemoteConfig/Sources/Private/FIRRemoteConfig_Private.h"
#import "FirebaseRemoteConfig/Sources/Private/RCNConfigFetch.h"
#import "FirebaseRemoteConfig/Sources/RCNConfigConstants.h"
#import "FirebaseRemoteConfig/Sources/RCNConfigDBManager.h"
#import "FirebaseRemoteConfig/Sources/RCNConfigValue_Internal.h"
#import "FirebaseRemoteConfig/Sources/RCNPersonalization.h"
#import "FirebaseRemoteConfig/Tests/Unit/RCNTestUtilities.h"
#import "Interop/Analytics/Public/FIRAnalyticsInterop.h"

@interface RCNConfigFetch (ForTest)
- (NSURLSessionDataTask *)URLSessionDataTaskWithContent:(NSData *)content
                                      completionHandler:
                                          (RCNConfigFetcherCompletion)fetcherCompletion;

- (void)fetchWithUserProperties:(NSDictionary *)userProperties
              completionHandler:(FIRRemoteConfigFetchCompletion)completionHandler;
@end

@interface RCNPersonalizationTest : XCTestCase {
  NSDictionary *_configContainer;
  NSMutableArray<NSDictionary *> *_fakeLogs;
  id _analyticsMock;
  RCNPersonalization *_personalization;
  FIRRemoteConfig *_configInstance;
}
@end

@implementation RCNPersonalizationTest
- (void)setUp {
  [super setUp];

  _configContainer = @{
    RCNFetchResponseKeyEntries : @{
      @"key1" : [[FIRRemoteConfigValue alloc]
          initWithData:[@"value1" dataUsingEncoding:NSUTF8StringEncoding]
                source:FIRRemoteConfigSourceRemote],
      @"key2" : [[FIRRemoteConfigValue alloc]
          initWithData:[@"value2" dataUsingEncoding:NSUTF8StringEncoding]
                source:FIRRemoteConfigSourceRemote],
      @"key3" : [[FIRRemoteConfigValue alloc]
          initWithData:[@"value3" dataUsingEncoding:NSUTF8StringEncoding]
                source:FIRRemoteConfigSourceRemote]
    },
    RCNFetchResponseKeyPersonalizationMetadata :
        @{@"key1" : @{kPersonalizationId : @"id1"}, @"key2" : @{kPersonalizationId : @"id2"}}
  };

  _fakeLogs = [[NSMutableArray alloc] init];
  _analyticsMock = OCMProtocolMock(@protocol(FIRAnalyticsInterop));
  OCMStub([_analyticsMock logEventWithOrigin:kAnalyticsOriginPersonalization
                                        name:kAnalyticsPullEvent
                                  parameters:[OCMArg isKindOfClass:[NSDictionary class]]])
      .andDo(^(NSInvocation *invocation) {
        __unsafe_unretained NSDictionary *bundle;
        [invocation getArgument:&bundle atIndex:4];
        [self->_fakeLogs addObject:bundle];
      });

  _personalization = [[RCNPersonalization alloc] initWithAnalytics:_analyticsMock];

  NSString *DBPath = [RCNTestUtilities remoteConfigPathForTestDatabase];
  id DBMock = OCMClassMock([RCNConfigDBManager class]);
  OCMStub([DBMock remoteConfigPathForDatabase]).andReturn(DBPath);

  id configFetch = OCMClassMock([RCNConfigFetch class]);
  OCMStub([configFetch fetchConfigWithExpirationDuration:0 completionHandler:OCMOCK_ANY])
      .ignoringNonObjectArgs()
      .andDo(^(NSInvocation *invocation) {
        __unsafe_unretained void (^handler)(FIRRemoteConfigFetchStatus status,
                                            NSError *_Nullable error) = nil;
        [invocation getArgument:&handler atIndex:3];
        [configFetch fetchWithUserProperties:[[NSDictionary alloc] init] completionHandler:handler];
      });

  NSDictionary *response = @{
    RCNFetchResponseKeyState : RCNFetchResponseKeyStateUpdate,
    RCNFetchResponseKeyEntries : @{@"key1" : @"value1", @"key2" : @"value2", @"key3" : @"value3"},
    RCNFetchResponseKeyPersonalizationMetadata :
        @{@"key1" : @{kPersonalizationId : @"id1"}, @"key2" : @{kPersonalizationId : @"id2"}}
  };
  id completionBlock = [OCMArg
      invokeBlockWithArgs:[NSJSONSerialization dataWithJSONObject:response options:0 error:nil],
                          [[NSHTTPURLResponse alloc]
                               initWithURL:[NSURL URLWithString:@"https://firebase.com"]
                                statusCode:200
                               HTTPVersion:nil
                              headerFields:@{@"etag" : @"etag1"}],
                          [NSNull null], nil];

  OCMExpect([configFetch URLSessionDataTaskWithContent:[OCMArg any]
                                     completionHandler:completionBlock])
      .andReturn(nil);

  RCNConfigContent *configContent = [[RCNConfigContent alloc] initWithDBManager:DBMock];
  _configInstance = OCMPartialMock([[FIRRemoteConfig alloc]
      initWithAppName:@"testApp"
           FIROptions:[[FIROptions alloc] initWithGoogleAppID:@"1:123:ios:test"
                                                  GCMSenderID:@"testSender"]
            namespace:@"namespace"
            DBManager:DBMock
        configContent:configContent
            analytics:_analyticsMock]);
  [_configInstance setValue:configFetch forKey:@"_configFetch"];
}

- (void)tearDown {
  [super tearDown];
}

- (void)testNonPersonalizationKey {
  [_fakeLogs removeAllObjects];

  [_personalization logArmActive:@"key3" config:_configContainer];

  OCMVerify(never(),
            [_analyticsMock logEventWithOrigin:kAnalyticsOriginPersonalization
                                          name:kAnalyticsPullEvent
                                    parameters:[OCMArg isKindOfClass:[NSDictionary class]]]);
  XCTAssertEqual([_fakeLogs count], 0);
}

- (void)testSinglePersonalizationKey {
  [_fakeLogs removeAllObjects];

  [_personalization logArmActive:@"key1" config:_configContainer];

  OCMVerify(times(1),
            [_analyticsMock logEventWithOrigin:kAnalyticsOriginPersonalization
                                          name:kAnalyticsPullEvent
                                    parameters:[OCMArg isKindOfClass:[NSDictionary class]]]);
  XCTAssertEqual([_fakeLogs count], 1);

  NSDictionary *params = @{kArmKey : @"id1", kArmValue : @"value1"};
  XCTAssertEqualObjects(_fakeLogs[0], params);
}

- (void)testMultiplePersonalizationKeys {
  [_fakeLogs removeAllObjects];

  [_personalization logArmActive:@"key1" config:_configContainer];
  [_personalization logArmActive:@"key2" config:_configContainer];

  OCMVerify(times(2),
            [_analyticsMock logEventWithOrigin:kAnalyticsOriginPersonalization
                                          name:kAnalyticsPullEvent
                                    parameters:[OCMArg isKindOfClass:[NSDictionary class]]]);
  XCTAssertEqual([_fakeLogs count], 2);

  NSDictionary *params1 = @{kArmKey : @"id1", kArmValue : @"value1"};
  XCTAssertEqualObjects(_fakeLogs[0], params1);

  NSDictionary *params2 = @{kArmKey : @"id2", kArmValue : @"value2"};
  XCTAssertEqualObjects(_fakeLogs[1], params2);
}

- (void)testRemoteConfigIntegration {
  [_fakeLogs removeAllObjects];

  FIRRemoteConfigFetchAndActivateCompletion fetchAndActivateCompletion =
      ^void(FIRRemoteConfigFetchAndActivateStatus status, NSError *error) {
        OCMVerify(times(2), [self->_analyticsMock
                                logEventWithOrigin:kAnalyticsOriginPersonalization
                                              name:kAnalyticsPullEvent
                                        parameters:[OCMArg isKindOfClass:[NSDictionary class]]]);
        XCTAssertEqual([self->_fakeLogs count], 2);

        NSDictionary *params1 = @{kArmKey : @"id1", kArmValue : @"value1"};
        XCTAssertEqualObjects(self->_fakeLogs[0], params1);

        NSDictionary *params2 = @{kArmKey : @"id2", kArmValue : @"value2"};
        XCTAssertEqualObjects(self->_fakeLogs[1], params2);
      };

  [_configInstance fetchAndActivateWithCompletionHandler:fetchAndActivateCompletion];
  [_configInstance configValueForKey:@"key1"];
  [_configInstance configValueForKey:@"key2"];
}

@end