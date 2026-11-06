// Catches Objective-C exceptions thrown by private frameworks so that a
// misbehaving LaunchServices proxy can't take the whole app down.
#import <Foundation/Foundation.h>

BOOL XXTry(void (NS_NOESCAPE ^block)(void), NSString **reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (reason) *reason = exception.reason;
        return NO;
    }
}
