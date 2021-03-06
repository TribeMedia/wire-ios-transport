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


@import ZMTesting;
@import XCTest;

#import "ZMKeychain.h"

@interface ZMKeychainTests : XCTestCase

@end

@implementation ZMKeychainTests

- (void)testThatItOnlyDeletesItemsOfSpecificAccount
{
    // given
    NSString *accountA = @"foo";
    NSString *accountB = @"bar";
    
    [ZMKeychain setData:[NSData data] forAccount:accountA];
    [ZMKeychain setData:[NSData data] forAccount:accountB];

    XCTAssertNotNil([ZMKeychain dataForAccount:accountA]);
    XCTAssertNotNil([ZMKeychain dataForAccount:accountB]);

    // when
    [ZMKeychain deleteAllKeychainItemsWithAccountName:accountA];
    
    // then
    XCTAssertNil([ZMKeychain dataForAccount:accountA]);
    XCTAssertNotNil([ZMKeychain dataForAccount:accountB]);
    
}


- (void)testThatItDeletesAllItemsOfAllAccounts
{
    // given
    NSString *accountA = @"foo";
    NSString *accountB = @"bar";
    
    [ZMKeychain setData:[NSData data] forAccount:accountA];
    [ZMKeychain setData:[NSData data] forAccount:accountB];
    
    XCTAssertNotNil([ZMKeychain dataForAccount:accountA]);
    XCTAssertNotNil([ZMKeychain dataForAccount:accountB]);
    
    // when
    [ZMKeychain deleteAllKeychainItems];
    
    // then
    XCTAssertNil([ZMKeychain dataForAccount:accountA]);
    XCTAssertNil([ZMKeychain dataForAccount:accountB]);
    
}

@end
