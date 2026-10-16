TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Stickers MobileSMS

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += StickersApp MessagesExtension EmojiStickers CreatorLibrary

include $(THEOS_MAKE_PATH)/aggregate.mk
