#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(FieldPrinter, NSObject)

RCT_EXTERN_METHOD(discover
                  : (nonnull NSNumber *)timeoutMs includeUnpaired
                  : (BOOL)includeUnpaired resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(connect
                  : (NSString *)deviceId timeoutMs
                  : (nonnull NSNumber *)timeoutMs resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(disconnect
                  : (nonnull NSNumber *)timeoutMs resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(status
                  : (nonnull NSNumber *)timeoutMs resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(reconnect
                  : (nonnull NSNumber *)timeoutMs resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(writeBytes
                  : (NSArray *)bytes timeoutMs
                  : (nonnull NSNumber *)timeoutMs resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)

@end
