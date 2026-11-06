TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Xixu

Xixu_FILES = $(wildcard Sources/*.swift) $(wildcard Sources/*.m) $(wildcard Shared/*.swift)
Xixu_CFLAGS = -fobjc-arc
Xixu_SWIFTFLAGS = -parse-as-library
Xixu_SWIFT_BRIDGING_HEADER = Shared/Bridge.h
Xixu_FRAMEWORKS = UIKit QuickLook QuickLookThumbnailing PhotosUI UniformTypeIdentifiers
Xixu_LIBRARIES = archive sqlite3
Xixu_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
