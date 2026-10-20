import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The CoShare protocol, network and sync engine in plain Kotlin: no Android classes, so the same code
// that ships in the app is tested on the JVM against the Swift vectors and the Node peer.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
    // ChaCha20-Poly1305 and PBKDF2 from the same audited library on every Android version (the
    // platform only has ChaCha20-Poly1305 from Android 9) and in the JVM tests.
    implementation("org.bouncycastle:bcprov-jdk15to18:1.86")
    testImplementation(kotlin("test-junit"))
}

tasks.test {
    // The interop test drives desktop/tools/peer.js; CI sets COSHARE_REQUIRE_INTEROP so it can't skip.
    environment("COSHARE_REPO_ROOT", rootProject.projectDir.parentFile.absolutePath)
    testLogging {
        events("passed", "skipped", "failed")
        showStandardStreams = System.getenv("COSHARE_TEST_VERBOSE") != null
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
