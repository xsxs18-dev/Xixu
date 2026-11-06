TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = xixuhelper

xixuhelper_FILES = main.swift $(wildcard Shared/*.swift)
xixuhelper_SWIFT_BRIDGING_HEADER = Shared/Bridge.h
xixuhelper_LIBRARIES = archive
xixuhelper_CODESIGN_FLAGS = -Sentitlements.plist
xixuhelper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
