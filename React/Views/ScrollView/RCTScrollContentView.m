/**
 * Copyright (c) 2015-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTScrollContentView.h"

#import <React/RCTAssert.h>
#import <React/NSView+React.h>

#import "RCTScrollView.h"

@implementation RCTScrollContentView

- (void)reactSetFrame:(CGRect)frame
{
  [super reactSetFrame:frame];

  RCTNativeScrollView *scrollView = (RCTNativeScrollView *)self.superview.superview;

  if (!scrollView) {
    return;
  }

  RCTAssert([scrollView isKindOfClass:[RCTNativeScrollView class]],
            @"Unexpected view hierarchy of RCTScrollView component.");

  // [scrollView updateContentOffsetIfNeeded];
}

@end
