import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Load release signing config from android/key.properties (kept OUT of git).
// File format:
//   storeFile=/absolute/path/to/sandesh-release.keystore
//   storePassword=...
//   keyAlias=sandesh
//   keyPassword=...
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) load(FileInputStream(keystorePropsFile))
}

android {
    // TODO PRODUCTION: rename this to your own package (e.g. com.codewithag.sandesh)
    // and rebuild google-services.json + the Google Sign-In OAuth client.
    namespace = "com.example.sandesh"
    compileSdk = 36
    ndkVersion = "27.3.13750724"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO PRODUCTION: must NOT remain com.example.* on the Play Store.
        applicationId = "com.example.sandesh"
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        // The app only ships English strings (see supportedLocales in main.dart),
        // so strip every other locale's resources that libraries like Firebase,
        // Google Play services and AndroidX bundle. Trims a few MB from the APK.
        resourceConfigurations += listOf("en")

        // Ship arm64-v8a only. This app is validated for arm64 at runtime
        // (see UpdateWorker / UpdateService ABI checks), so bundling armeabi-v7a
        // and x86_64 just bloated the APK. Guarantees arm64-only even for a
        // plain `flutter build apk` that omits --target-platform.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    // Drop large Agora RTC native extension libraries that this chat/calling
    // app does not use (super-resolution, beauty/video-process, AI denoise,
    // virtual-background/segmentation, spatial audio, content-inspect, DRM).
    // These optional .so files add tens of MB each; removing them is the single
    // biggest APK-size win. Do NOT exclude a library for a feature you actually use.
    packaging {
        jniLibs {
            excludes += listOf(
                "**/libagora_super_resolution_extension.so",
                "**/libagora_video_process_extension.so",
                "**/libagora_ai_denoise_extension.so",
                "**/libagora_segmentation_extension.so",
                "**/libagora_spatial_audio_extension.so",
                "**/libagora_content_inspect_extension.so",
                "**/libagora_drm_loader_extension.so",
                "**/libagora_udrm3_extension.so",
                "**/libagora_face_detection_extension.so",
                "**/libagora_pvc_extension.so",
                "**/libagora_clear_vision_extension.so"
            )
        }
    }

    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                storeFile = keystoreProps["storeFile"]?.toString()?.let { file(it) }
                storePassword = keystoreProps["storePassword"]?.toString()
                keyAlias = keystoreProps["keyAlias"]?.toString()
                keyPassword = keystoreProps["keyPassword"]?.toString()
            }
        }
    }

    buildTypes {
        release {
            // Use the release keystore if key.properties is present; otherwise fall
            // back to debug so `flutter run --release` keeps working in dev. The
            // Play Store will reject debug-signed APKs anyway.
            signingConfig = if (keystoreProps.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else if (System.getenv("CI") != null) {
                throw GradleException("Release signing credentials not found. CI builds must be release-signed.")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            ndk { debugSymbolLevel = "none" }
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime-ktx:2.9.0")
}

flutter {
    source = "../.."
}
