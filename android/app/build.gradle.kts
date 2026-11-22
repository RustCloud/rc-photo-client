plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.rustcloud.photos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.rustcloud.photos"
        // Android 8.0: simpler background work and notifications (PLAN.md, section 1).
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Signed with the organisation's key, the same as the RustCloud client's, so the phone
    // account (rc-client) trusts this app: it checks that the signers match and only then gives
    // a token without asking and shows its account. The workflows (release.yml, ci.yml) put the
    // key into a file and pass these variables; debug builds use it too then, so the APK from a
    // CI run works with the client. Without them (local builds) the debug key is used: the app
    // installs, but the client treats it as another developer's.
    val keystore = System.getenv("ANDROID_KEYSTORE_FILE")
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                // As apksigner in the client's workflow: the key's password is the store's.
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        val signing = signingConfigs.getByName(if (keystore != null) "release" else "debug")
        debug { signingConfig = signing }
        release {
            signingConfig = signing
            // Flutter shrinks release builds with R8; these keep what libraries create by reflection.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    // The login page in a Custom Tab (MainActivity.browserLogin).
    implementation("androidx.browser:browser:1.8.0")
    // The backup's runs (Backup.kt) and their notification.
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("androidx.core:core-ktx:1.13.1")
}
