plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.difysf.dify_sf_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.difysf.dify_sf_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val keystore = System.getenv("DIFYSF_ANDROID_KEYSTORE_PATH")
    // Explicitly opted-in, optimized preview APKs can replace the existing .dev
    // test app. Production releases still require the publisher's own key.
    val previewRelease = System.getenv("DIFYSF_ANDROID_PREVIEW_RELEASE") == "true"
    if (!keystore.isNullOrBlank()) {
        signingConfigs.create("difyRelease") {
            storeFile = file(keystore)
            storePassword = System.getenv("DIFYSF_ANDROID_STORE_PASSWORD")
                ?: throw GradleException("DIFYSF_ANDROID_STORE_PASSWORD is required")
            keyAlias = System.getenv("DIFYSF_ANDROID_KEY_ALIAS")
                ?: throw GradleException("DIFYSF_ANDROID_KEY_ALIAS is required")
            keyPassword = System.getenv("DIFYSF_ANDROID_KEY_PASSWORD")
                ?: throw GradleException("DIFYSF_ANDROID_KEY_PASSWORD is required")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
        }
        release {
            if (previewRelease) {
                applicationIdSuffix = ".dev"
                signingConfig = signingConfigs.getByName("debug")
            } else {
                // Never silently sign a production APK with a development key.
                signingConfig = signingConfigs.findByName("difyRelease")
            }
        }
        matching { it.name == "profile" }.configureEach { applicationIdSuffix = ".qa" }
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
