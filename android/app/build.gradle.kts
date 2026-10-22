plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.writingrecogniser"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.writingrecogniser"
        // Android 16 (API 36) and later only. See docs/DECISIONS.md.
        minSdk = 36
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 64-bit ARM only (every Android 16 tablet). Some libraries (ML Kit)
        // also pack 32-bit ARM and x86_64 copies; dropping them keeps the APK
        // smaller and stops Android choosing a mixed set of libraries.
        // CI's launch check builds a separate test-only x86_64 APK for its
        // emulator by setting APP_ABIS=x86_64.
        ndk {
            abiFilters += (System.getenv("APP_ABIS") ?: "arm64-v8a").split(",")
        }
    }

    // The ABI filter above doesn't reach every library's native files (the
    // MyScript and ML Kit ones still came in for 32-bit ARM and x86_64, about
    // 95 MB the tablet never uses), so leave out every other ABI's folder
    // when packaging too.
    packaging {
        jniLibs {
            val keep = (System.getenv("APP_ABIS") ?: "arm64-v8a").split(",")
            excludes += listOf("arm64-v8a", "armeabi-v7a", "armeabi", "x86", "x86_64")
                .filter { it !in keep }
                .map { "lib/$it/**" }
        }
    }

    // MyScript reads its recognition files straight from the APK, which needs
    // them stored uncompressed.
    androidResources {
        noCompress += listOf("conf", "res")
    }

    // The owner's own signing key, so every build is signed the same way and
    // installs over the previous one (keeping the app's data). CI writes the
    // key file from repo secrets; it is never committed. Without it (e.g. a
    // local build) the throwaway debug key is used.
    val ownerKeystore = System.getenv("APP_KEYSTORE_FILE")?.let { file(it) }
    val ownerKeystorePassword = System.getenv("APP_KEYSTORE_PASSWORD")
    signingConfigs {
        if (ownerKeystore != null && ownerKeystore.exists() && ownerKeystorePassword != null) {
            create("owner") {
                storeFile = ownerKeystore
                storePassword = ownerKeystorePassword
                keyAlias = "writingrecogniser"
                keyPassword = ownerKeystorePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("owner")
                ?: signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // MyScript iink offline handwriting engine (owner's licence; see
    // docs/DECISIONS.md). The certificate and recognition files are added by CI.
    implementation("com.myscript:iink:4.5.1")
    // ONNX Runtime (Microsoft, MIT licence), to run the PaddleOCR models
    // that read scanned PDFs on the tablet (owner, 2026-10-17). No network
    // use of its own. See docs/DECISIONS.md.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.22.0")
    // androidx.graphics (Google, Apache 2.0 licence): draws the line under
    // the pen straight to the screen (front-buffered rendering), so ink
    // keeps up with the pen (owner approved, 2026-10-18). No network use.
    // See docs/DECISIONS.md.
    implementation("androidx.graphics:graphics-core:1.0.2")
}
