#import <Foundation/Foundation.h>

__attribute__((constructor))
static void CompatibilityInitialize(void) {
    NSLog(@"[S2Compat] Library loaded successfully");
    NSLog(@"[S2Compat] Diagnostic mode enabled");
}
