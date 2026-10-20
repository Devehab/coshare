import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Version from the release tag (android-v1.2.3 → -PappVersion=1.2.3); local builds are 1.0.0.
val appVersion = (findProperty("appVersion") as String?)?.takeIf { it.matches(Regex("""\d+\.\d+\.\d+""")) } ?: "1.0.0"
val (major, minor, patch) = appVersion.split(".").map { it.toInt() }

// Release signing comes from the environment (CI secrets); without it the release APK is left unsigned.
val keystoreFile = System.getenv("COSHARE_KEYSTORE")?.let { file(it) }?.takeIf { it.isFile }

android {
    namespace = "com.ehabk.coshare"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.ehabk.coshare"
        minSdk = 26
        targetSdk = 37
        versionCode = major * 10000 + minor * 100 + patch
        versionName = appVersion
    }

    signingConfigs {
        if (keystoreFile != null) {
            create("release") {
                storeFile = keystoreFile
                storePassword = System.getenv("COSHARE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("COSHARE_KEY_ALIAS") ?: "coshare"
                keyPassword = System.getenv("COSHARE_KEY_PASSWORD") ?: System.getenv("COSHARE_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (keystoreFile != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += setOf("META-INF/versions/**", "META-INF/*.kotlin_module", "META-INF/LICENSE*", "META-INF/NOTICE*")
    }

    lint {
        // Arabic copy is deliberate; don't block CI on wording or newer-version hints.
        disable += setOf("MissingTranslation", "OldTargetApi", "GradleDependency", "NewerVersionAvailable")
        abortOnError = true
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    // QR codes: reading (with CameraX frames) and drawing invites. Pure Java, no Google Play services needed.
    implementation("com.google.zxing:core:3.5.4")
}
