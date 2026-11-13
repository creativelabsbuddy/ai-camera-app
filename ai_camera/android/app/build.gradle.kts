plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ankush.ai_camera"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // v11.58: flutter_local_notifications (video-ready notification) needs
        // core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ankush.ai_camera"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // v10: ML Kit ships native libs for every ABI and AGP stores them
    // uncompressed. Package only the ABIs Flutter is building for
    // (`flutter build apk --target-platform android-arm64` passes
    // -Ptarget-platform=android-arm64), so the arm64 APK carries arm64
    // libraries only. The Flutter Gradle plugin puts its default ABI list
    // (armeabi-v7a, arm64-v8a, x86_64) on every *build type*, and AGP
    // unions build-type and defaultConfig filters, so the override has to
    // replace the build-type filters themselves.
    val abiFor = mapOf(
        "android-arm64" to "arm64-v8a",
        "android-arm" to "armeabi-v7a",
        "android-x64" to "x86_64",
    )
    val targetAbis = (project.findProperty("target-platform") as String?)
        ?.split(",")
        ?.mapNotNull { abiFor[it.trim()] }
        .orEmpty()
    if (targetAbis.isNotEmpty()) {
        buildTypes.configureEach {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(targetAbis)
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles("proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

// v10 ML Kit footprint: use the Google Play services (unbundled) variants
// where they exist — same Java API, models are downloaded/shared by Play
// services instead of being bundled in the APK (~31 MB raw for arm64:
// barcode 5.4, face 11.6, text OCR 10.8, labeling 3.0). v11 removed selfie
// segmentation and pose detection entirely; the document scanner is
// already Play services.
configurations.all {
    exclude(group = "com.google.mlkit", module = "barcode-scanning")
    exclude(group = "com.google.mlkit", module = "face-detection")
    exclude(group = "com.google.mlkit", module = "text-recognition")
    exclude(group = "com.google.mlkit", module = "text-recognition-bundled-common")
    exclude(group = "com.google.mlkit", module = "image-labeling")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // v11 Portrait (Normal): CameraX vendor BOKEH extension. Same CameraX
    // version as camera_android_camerax 0.7.2 (core/camera2/lifecycle are
    // already in the APK through the plugin; declared here for compiling).
    val cameraxVersion = "1.6.0"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-extensions:$cameraxVersion")
    // ListenableFuture (already in the APK via the camera plugin).
    implementation("com.google.guava:guava:33.5.0-android")
    implementation("com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1")
    implementation("com.google.android.gms:play-services-mlkit-face-detection:17.1.0")
    implementation("com.google.android.gms:play-services-mlkit-text-recognition:19.0.1")
    implementation("com.google.android.gms:play-services-mlkit-image-labeling:16.0.8")
}
