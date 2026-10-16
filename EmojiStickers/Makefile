include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EmojiStickers

EmojiStickers_FILES = Tweak.x STKStickerPanel.m STKMessagesBridge.m ../Shared/STKStore.m ../Shared/STKImageLoading.m
EmojiStickers_CFLAGS = -fobjc-arc -I../Shared
EmojiStickers_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/tweak.mk
