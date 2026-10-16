include $(THEOS)/makefiles/common.mk

APPEX_NAME = StickersMessages

CREATOR_FILES = $(wildcard ../Shared/Creator/*.m)

StickersMessages_FILES = STKMessagesViewController.m ../Shared/STKStore.m $(CREATOR_FILES)
StickersMessages_RESOURCE_DIRS = Resources
StickersMessages_INSTALL_PATH = /Applications/Stickers.app/PlugIns
StickersMessages_CFLAGS = -fobjc-arc -I../Shared -I../Shared/Creator
StickersMessages_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO AVFoundation CoreMedia Messages Photos PhotosUI UniformTypeIdentifiers
StickersMessages_CODESIGN_FLAGS = -SEntitlements.plist

include $(THEOS_MAKE_PATH)/appex.mk
