/**
 * Copyright (c) 2015-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTPushNotificationManager.h"

#import <UserNotifications/UserNotifications.h>

#import <React/RCTBridge.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTUtils.h>

NSString *const RCTLocalNotificationReceived = @"LocalNotificationReceived";
NSString *const RCTRemoteNotificationReceived = @"RemoteNotificationReceived";
NSString *const RCTRemoteNotificationsRegistered = @"RemoteNotificationsRegistered";
NSString *const RCTRegisterUserNotificationSettings = @"RegisterUserNotificationSettings";

NSString *const RCTErrorUnableToRequestPermissions = @"E_UNABLE_TO_REQUEST_PERMISSIONS";
NSString *const RCTErrorRemoteNotificationRegistrationFailed = @"E_FAILED_TO_REGISTER_FOR_REMOTE_NOTIFICATIONS";

@implementation RCTConvert (NSUserNotification)

+ (NSUserNotification *)NSUserNotification:(id)json
{
  NSDictionary<NSString *, id> *details = [self NSDictionary:json];
  NSUserNotification *notification = [NSUserNotification new];
  notification.deliveryDate = [RCTConvert NSDate:details[@"fireDate"]] ?: [NSDate date];
  notification.informativeText = [RCTConvert NSString:details[@"alertBody"]];
  notification.soundName = [RCTConvert NSString:details[@"soundName"]] ?: NSUserNotificationDefaultSoundName;
  notification.userInfo = [RCTConvert NSDictionary:details[@"userInfo"]];
  if (details[@"title"]) {
    notification.title = [RCTConvert NSString:details[@"title"]];
  }
  return notification;
}

@end

@implementation RCTPushNotificationManager
{
  RCTPromiseResolveBlock _requestPermissionsResolveBlock;
}

static NSDictionary *RCTFormatLocalNotification(NSUserNotification *notification)
{
  NSMutableDictionary *formattedLocalNotification = [NSMutableDictionary dictionary];
  if (notification.actualDeliveryDate) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"];
    NSString *fireDateString = [formatter stringFromDate:notification.actualDeliveryDate];
    formattedLocalNotification[@"fireDate"] = fireDateString;
  }
  formattedLocalNotification[@"alertAction"] = RCTNullIfNil(notification.actionButtonTitle);
  formattedLocalNotification[@"alertBody"] = RCTNullIfNil(notification.informativeText);
//  formattedLocalNotification[@"applicationIconBadgeNumber"] = @(notification.applicationIconBadgeNumber);
//  formattedLocalNotification[@"category"] = RCTNullIfNil(notification.category);
  formattedLocalNotification[@"soundName"] = RCTNullIfNil(notification.soundName);
  formattedLocalNotification[@"userInfo"] = RCTNullIfNil(RCTJSONClean(notification.userInfo));
  formattedLocalNotification[@"remote"] = @NO;
  return formattedLocalNotification;
}

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

- (void)setBridge:(RCTBridge *)bridge
{
  _bridge = bridge;
}

- (void)startObserving
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleLocalNotificationReceived:)
                                               name:RCTLocalNotificationReceived
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleRemoteNotificationReceived:)
                                               name:RCTRemoteNotificationReceived
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleRemoteNotificationsRegistered:)
                                               name:RCTRemoteNotificationsRegistered
                                             object:nil];

  [NSUserNotificationCenter defaultUserNotificationCenter].delegate = self;
}

- (NSArray<NSString *> *)supportedEvents
{
  return @[@"localNotificationReceived",
           @"remoteNotificationReceived",
           @"remoteNotificationsRegistered",
           @"remoteNotificationRegistrationError"];
}

- (NSDictionary<NSString *, id> *)constantsToExport
{
  NSDictionary<NSString *, id> *initialNotification =
    [_bridge.launchOptions[NSApplicationLaunchUserNotificationKey] copy];
  return @{@"initialNotification": RCTNullIfNil(initialNotification)};
}


+ (void)didRegisterUserNotificationSettings
{
  if ([NSApplication instancesRespondToSelector:@selector(registerForRemoteNotifications)]) {
    //[[NSApplication sharedApplication] registerForRemoteNotifications];
  }
}

+ (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
  NSMutableString *hexString = [NSMutableString string];
  NSUInteger deviceTokenLength = deviceToken.length;
  const unsigned char *bytes = deviceToken.bytes;
  for (NSUInteger i = 0; i < deviceTokenLength; i++) {
    [hexString appendFormat:@"%02x", bytes[i]];
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTRemoteNotificationsRegistered
                                                      object:self
                                                    userInfo:@{@"deviceToken" : [hexString copy]}];
}

+ (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTErrorRemoteNotificationRegistrationFailed
                                                      object:self
                                                    userInfo:@{@"error": error}];
}

+ (void)didReceiveRemoteNotification:(NSDictionary *)notification
{
  NSDictionary *userInfo = @{@"notification": notification};
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTRemoteNotificationReceived
                                                      object:self
                                                    userInfo:userInfo];
}

+ (void)didReceiveLocalNotification:(NSUserNotification*)notification
{
  NSMutableDictionary *details = [NSMutableDictionary new];
  if (notification.informativeText) {
    details[@"alertBody"] = notification.informativeText;
  }
  if (notification.userInfo) {
    details[@"userInfo"] = RCTJSONClean(notification.userInfo);
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTLocalNotificationReceived
                                                      object:self
                                                    userInfo:RCTFormatLocalNotification(notification)];
}

- (void)handleLocalNotificationReceived:(NSNotification *)notification
{
  [self sendEventWithName:@"localNotificationReceived" body:notification.userInfo];
}

- (void)handleRemoteNotificationReceived:(NSNotification *)notification
{
  NSMutableDictionary *remoteNotification = [NSMutableDictionary dictionaryWithDictionary:notification.userInfo[@"notification"]];
  RCTRemoteNotificationCallback completionHandler = notification.userInfo[@"completionHandler"];
  NSString *notificationId = [[NSUUID UUID] UUIDString];
  remoteNotification[@"notificationId"] = notificationId;
  remoteNotification[@"remote"] = @YES;
  if (completionHandler) {
    if (!self.remoteNotificationCallbacks) {
      // Lazy initialization
      self.remoteNotificationCallbacks = [NSMutableDictionary dictionary];
    }
    self.remoteNotificationCallbacks[notificationId] = completionHandler;
  }

  [self sendEventWithName:@"remoteNotificationReceived" body:remoteNotification];
}

- (void)handleRemoteNotificationsRegistered:(NSNotification *)notification
{
  [self sendEventWithName:@"remoteNotificationsRegistered" body:notification.userInfo];
}

- (void)handleRemoteNotificationRegistrationError:(NSNotification *)notification
{
  NSError *error = notification.userInfo[@"error"];
  NSDictionary *errorDetails = @{
    @"message": error.localizedDescription,
    @"code": @(error.code),
    @"details": error.userInfo,
  };
  [self sendEventWithName:@"remoteNotificationRegistrationError" body:errorDetails];
}

- (void)handleRegisterUserNotificationSettings:(NSNotification *)notification
{
  if (_requestPermissionsResolveBlock == nil) {
    return;
  }

  UIUserNotificationSettings *notificationSettings = notification.userInfo[@"notificationSettings"];
  NSDictionary *notificationTypes = @{
    @"alert": @((notificationSettings.types & UIUserNotificationTypeAlert) > 0),
    @"sound": @((notificationSettings.types & UIUserNotificationTypeSound) > 0),
    @"badge": @((notificationSettings.types & UIUserNotificationTypeBadge) > 0),
  };

  _requestPermissionsResolveBlock(notificationTypes);
  // Clean up listener added in requestPermissions
  [self removeListeners:1];
  _requestPermissionsResolveBlock = nil;
}

RCT_EXPORT_METHOD(onFinishRemoteNotification:(NSString *)notificationId fetchResult:(UIBackgroundFetchResult)result) {
  RCTRemoteNotificationCallback completionHandler = self.remoteNotificationCallbacks[notificationId];
  if (!completionHandler) {
    RCTLogError(@"There is no completion handler with notification id: %@", notificationId);
    return;
  }
  completionHandler(result);
  [self.remoteNotificationCallbacks removeObjectForKey:notificationId];
}

/**
 * Update the application icon badge number on the home screen
 */
RCT_EXPORT_METHOD(setApplicationIconBadgeNumber:(NSInteger)number)
{
  RCTSharedApplication().dockTile.badgeLabel = @(number);
}

/**
 * Get the current application icon badge number on the home screen
 */
RCT_EXPORT_METHOD(getApplicationIconBadgeNumber:(RCTResponseSenderBlock)callback)
{
  callback(@[RCTSharedApplication().dockTile.badgeLabel]);
}

RCT_EXPORT_METHOD(requestPermissions:(NSDictionary *)permissions
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
  if (RCTRunningInAppExtension()) {
    reject(RCTErrorUnableToRequestPermissions, nil, RCTErrorWithMessage(@"Requesting push notifications is currently unavailable in an app extension"));
    return;
  }
//
//  UIUserNotificationType types = UIUserNotificationTypeNone;
//  if (permissions) {
//    if ([RCTConvert BOOL:permissions[@"alert"]]) {
//      types |= UIUserNotificationTypeAlert;
//    }
//    if ([RCTConvert BOOL:permissions[@"badge"]]) {
//      types |= UIUserNotificationTypeBadge;
//    }
//    if ([RCTConvert BOOL:permissions[@"sound"]]) {
//      types |= UIUserNotificationTypeSound;
//    }
//  } else {
//    types = UIUserNotificationTypeAlert | UIUserNotificationTypeBadge | UIUserNotificationTypeSound;
//  }
//
//  UIApplication *app = RCTSharedApplication();
//  if ([app respondsToSelector:@selector(registerUserNotificationSettings:)]) {
//    UIUserNotificationSettings *notificationSettings =
//      [UIUserNotificationSettings settingsForTypes:(NSUInteger)types categories:nil];
//    [app registerUserNotificationSettings:notificationSettings];
//  } else {
//    [app registerForRemoteNotificationTypes:(NSUInteger)types];
//  }
}

RCT_EXPORT_METHOD(abandonPermissions)
{
  [RCTSharedApplication() unregisterForRemoteNotifications];
}

RCT_EXPORT_METHOD(checkPermissions:(RCTResponseSenderBlock)callback)
{
  if (RCTRunningInAppExtension()) {
    callback(@[@{@"alert": @NO, @"badge": @NO, @"sound": @NO}]);
    return;
  }

  NSUInteger types = [RCTSharedApplication() currentUserNotificationSettings].types;
  callback(@[@{
    @"alert": @((types & UIUserNotificationTypeAlert) > 0),
    @"badge": @((types & UIUserNotificationTypeBadge) > 0),
    @"sound": @((types & UIUserNotificationTypeSound) > 0),
  }]);
}

RCT_EXPORT_METHOD(presentLocalNotification:(NSUserNotification *)notification)
{
  [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

RCT_EXPORT_METHOD(scheduleLocalNotification:(NSUserNotification *)notification)
{
  [[NSUserNotificationCenter defaultUserNotificationCenter] scheduleNotification:notification];
}

RCT_EXPORT_METHOD(cancelAllLocalNotifications)
{
  for (NSUserNotification *notification in [NSUserNotificationCenter defaultUserNotificationCenter].scheduledNotifications) {
    [[NSUserNotificationCenter defaultUserNotificationCenter] removeScheduledNotification:notification];
  }
}

RCT_EXPORT_METHOD(cancelLocalNotifications:(NSDictionary<NSString *, id> *)userInfo)
{
  for (UILocalNotification *notification in RCTSharedApplication().scheduledLocalNotifications) {
    __block BOOL matchesAll = YES;
    NSDictionary<NSString *, id> *notificationInfo = notification.userInfo;
    // Note: we do this with a loop instead of just `isEqualToDictionary:`
    // because we only require that all specified userInfo values match the
    // notificationInfo values - notificationInfo may contain additional values
    // which we don't care about.
    [userInfo enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
      if (![notificationInfo[key] isEqual:obj]) {
        matchesAll = NO;
        *stop = YES;
      }
    }];
    if (matchesAll) {
      [[NSUserNotificationCenter defaultUserNotificationCenter] removeScheduledNotification:notification];
    }
  }
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification {
  return YES;
}

@end
