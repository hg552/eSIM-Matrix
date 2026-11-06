# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in /Users/ieb/flutter/packages/flutter_tools/gradle/flutter_proguard_rules.pro

# The ADB bridge helper is reached only by name: app_process names the starter
# class on the command line, and the helper's binder is reached through the
# AIDL stub. Keep them even if minification is ever turned on.
-keep class io.github.hg552.esimmatrix.AdbBridgeStarter { *; }
-keep class io.github.hg552.esimmatrix.AdbBridgeServer { *; }
-keep class io.github.hg552.esimmatrix.IAdbBridge { *; }
-keep class io.github.hg552.esimmatrix.IAdbBridge$* { *; }
