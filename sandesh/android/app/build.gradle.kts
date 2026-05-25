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
    ndkVersion = "27.0.12077973"

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
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
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
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
