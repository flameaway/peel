#import "STKAppDelegate.h"

// The app only hosts the iMessage app and is hidden from the home screen (LSApplicationLaunchProhibited, like
// Messages-only App Store apps). If something launches it anyway, it says where Peel lives.
@implementation STKAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UIViewController *controller = [UIViewController new];
	controller.view.backgroundColor = UIColor.systemBackgroundColor;
	UILabel *label = [UILabel new];
	label.text = @"Peel lives in Messages and the emoji keyboard.\n\nIn Messages, open Peel in the app row to make, send and delete stickers. In any app, switch to the emoji keyboard and tap the sticker icon.";
	label.numberOfLines = 0;
	label.textAlignment = NSTextAlignmentCenter;
	label.textColor = UIColor.secondaryLabelColor;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[controller.view addSubview:label];
	[NSLayoutConstraint activateConstraints:@[
		[label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
		[label.leadingAnchor constraintEqualToAnchor:controller.view.layoutMarginsGuide.leadingAnchor],
		[label.trailingAnchor constraintEqualToAnchor:controller.view.layoutMarginsGuide.trailingAnchor],
	]];
	self.window.rootViewController = controller;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
