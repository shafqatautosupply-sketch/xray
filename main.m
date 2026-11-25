// main.m - app entry
#import "XCore.h"
#include <unistd.h>

@interface XAppDelegate : UIResponder <UIApplicationDelegate> {
    UIWindow *window;
}
@end

@implementation XAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSLog(@"Xray: launching uid=%d euid=%d", getuid(), geteuid());
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    NSLog(@"Xray: building UI");
    window.rootViewController = XMakeRoot();
    NSLog(@"Xray: UI built");
    [window makeKeyAndVisible];
    return YES;
}

// kdebug tracing keeps costing CPU after we're gone, so always switch it off when leaving.
- (void)applicationDidEnterBackground:(UIApplication *)app { [[XTrace shared] stop]; }
- (void)applicationWillTerminate:(UIApplication *)app { [[XTrace shared] stop]; }

@end

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int r = UIApplicationMain(argc, argv, nil, @"XAppDelegate");
    [pool release];
    return r;
}
