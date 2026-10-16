include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Stickers

CREATOR_FILES = $(wildcard ../Shared/Creator/*.m)

Stickers_FILES = main.m STKAppDelegate.m STKLibraryViewController.m ../Shared/STKStore.m ../Shared/STKImageLoading.m $(CREATOR_FILES)
Stickers_RESOURCE_DIRS = Resources
Stickers_CFLAGS = -fobjc-arc -I../Shared -I../Shared/Creator
Stickers_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO AVFoundation CoreMedia Photos PhotosUI UniformTypeIdentifiers
Stickers_CODESIGN_FLAGS = -SEntitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
