// Keep every private LaunchServices call and its exception handler in
// Objective-C. An Objective-C exception must never unwind through Swift.
#import <Foundation/Foundation.h>
#import <objc/message.h>

static id XXWorkspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

NSArray<NSObject *> *XXInstalledApplications(void) {
    @try {
        id workspace = XXWorkspace();
        SEL selector = NSSelectorFromString(@"allInstalledApplications");
        if (!workspace || ![workspace respondsToSelector:selector]) return @[];
        id list = ((id (*)(id, SEL))objc_msgSend)(workspace, selector);
        return [list isKindOfClass:[NSArray class]] ? list : @[];
    } @catch (NSException *exception) {
        return @[];
    }
}

id XXSafeValueForKey(NSObject *object, NSString *key) {
    @try {
        if (![object respondsToSelector:NSSelectorFromString(key)]) return nil;
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

BOOL XXOpenApplication(NSString *bundleID) {
    @try {
        id workspace = XXWorkspace();
        SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (!workspace || ![workspace respondsToSelector:selector]) return NO;
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleID);
    } @catch (NSException *exception) {
        return NO;
    }
}
