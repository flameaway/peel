#import "STKAppDelegate.h"
#import "STKLibraryViewController.h"
#import "STKStore.h"

@implementation STKAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	[STKStore.sharedStore migrateFromAppGroup];
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[STKLibraryViewController new]];
	navigation.navigationBar.prefersLargeTitles = YES;
	self.window.rootViewController = navigation;
	[self.window makeKeyAndVisible];
	return YES;
}

// josh-stickers://new, opened from the "Make a Sticker" button in the iMessage app.
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
	if (![url.host isEqualToString:@"new"]) {
		return NO;
	}
	UINavigationController *navigation = (UINavigationController *)self.window.rootViewController;
	[navigation dismissViewControllerAnimated:NO completion:nil];
	[navigation popToRootViewControllerAnimated:NO];
	[(STKLibraryViewController *)navigation.viewControllers.firstObject pickPhoto];
	return YES;
}

@end
