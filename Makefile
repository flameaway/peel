TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Stickers MobileSMS

# Theos picks debug or final build paths when it loads and hands them to the builds below, so decide before that.
ifeq ($(MAKECMDGOALS),release)
FINALPACKAGE = 1
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += StickersApp MessagesExtension EmojiStickers CreatorLibrary

include $(THEOS_MAKE_PATH)/aggregate.mk

# Builds the final package and publishes it as a GitHub release; Flame's repo picks it up from there.
# Release notes come from NOTES="..." or, if unset, are written in your editor.
VERSION := $(shell sed -n 's/^Version: //p' control)
PACKAGE_ID := $(shell sed -n 's/^Package: //p' control)
RELEASE_DEB := packages/$(PACKAGE_ID)_$(VERSION)_iphoneos-arm64.deb

# Theos marks the make it runs in as already started, which would make the builds below skip compiling. The old
# package is removed first so a stale one can never be uploaded.
release:
	@git diff --quiet HEAD -- || { echo "Commit your changes before releasing."; exit 1; }
	rm -f $(RELEASE_DEB)
	env -u _THEOS_TOP_INVOCATION_DONE $(MAKE) clean
	env -u _THEOS_TOP_INVOCATION_DONE $(MAKE) package FINALPACKAGE=1
	@test -f $(RELEASE_DEB) || { echo "$(RELEASE_DEB) wasn't built."; exit 1; }
	git push origin HEAD
	gh release create v$(VERSION) $(RELEASE_DEB) --title "Peel $(VERSION)" $(if $(NOTES),--notes "$$NOTES",)

.PHONY: release
