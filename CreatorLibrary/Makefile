include $(THEOS)/makefiles/common.mk

# The sticker maker for the emoji keyboard. The tweak dlopens this only when "+" is tapped, so apps don't load
# Photos/AVFoundation just because the keyboard appeared. STKStore comes from the already-loaded tweak (looked up by name).
LIBRARY_NAME = STKCreator

STKCreator_FILES = $(wildcard ../Shared/Creator/*.m)
STKCreator_INSTALL_PATH = /Library/Application Support/Stickers
STKCreator_CFLAGS = -fobjc-arc -I../Shared -I../Shared/Creator
STKCreator_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO AVFoundation CoreMedia Photos PhotosUI UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/library.mk
