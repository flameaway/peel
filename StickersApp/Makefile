include $(THEOS)/makefiles/common.mk

# Only a container for the iMessage app; hidden from the home screen.
APPLICATION_NAME = Stickers

Stickers_FILES = main.m STKAppDelegate.m
Stickers_RESOURCE_DIRS = Resources
Stickers_CFLAGS = -fobjc-arc
Stickers_FRAMEWORKS = UIKit
Stickers_CODESIGN_FLAGS = -SEntitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
