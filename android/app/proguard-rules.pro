# Flutter's engine contains optional Play Store "deferred components" code that
# refers to Google Play Core classes. We don't use that feature or include
# Play Core, so tell the release-build code shrinker (R8) not to fail on the
# missing classes.
-dontwarn com.google.android.play.core.**

# App.kt starts ML Kit by name (instead of ML Kit's own start-up provider).
-keep class com.google.mlkit.common.sdkinternal.MlKitContext { *; }

# ML Kit's model download uses Android WorkManager, which starts at launch and
# opens its own Room database. The release shrinker (R8) removed the
# database's generated constructor, so the app crashed at start-up
# ("Failed to create an instance of androidx.work.impl.WorkDatabase").
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# MyScript iink: native code calls into these classes, and the owner's
# certificate class is only loaded by name, so keep both.
-keep class com.myscript.iink.** { *; }
-keep class com.myscript.certificate.** { *; }

# ML Kit finds its parts ("component registrars") by the class names listed in
# the app manifest. The shrinker removed them, so ML Kit started with nothing
# registered: the ink plugin failed to load and the model download button gave
# "MissingPluginException ... vision#manageInkModels".
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.mlkit.**.*Registrar { <init>(); }

# ONNX Runtime (reading scanned PDFs): its native code looks up its own Java
# classes and fields by name. The shrinker renamed them, so the first page
# read stopped the app ("JNI DETECTED ERROR ... java_class == null ... in
# OrtSession.run").
-keep class ai.onnxruntime.** { *; }
