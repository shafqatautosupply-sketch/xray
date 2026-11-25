ARCHS = armv7
TARGET = iphone:6.1:6.0

include $(THEOS)/makefiles/common.mk

# The app runs as a normal user (mobile). It never needs setuid.
APPLICATION_NAME = Xray
Xray_FILES = main.m XModel.m XClient.m XKern.m XSkin.m XScreens.m
Xray_FRAMEWORKS = UIKit CoreGraphics QuartzCore Foundation
Xray_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations
include $(THEOS_MAKE_PATH)/application.mk

# The helper is the only setuid-root piece. Installs to /usr/libexec/xrayd.
TOOL_NAME = xrayd
xrayd_FILES = helper.m XModel.m XProc.m XTrace.m
xrayd_FRAMEWORKS = Foundation
xrayd_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations -DXHELPER=1
xrayd_INSTALL_PATH = /usr/libexec
xrayd_CODESIGN_FLAGS = -Sentitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "uicache"
