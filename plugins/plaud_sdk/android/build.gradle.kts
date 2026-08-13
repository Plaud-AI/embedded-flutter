group = "ai.plaud.plaud_sdk"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // logback-android ships on JitPack only (transitive dep of the Plaud AAR).
        maven { url = uri("https://jitpack.io") }
    }
}

// Checked-in one-artifact Maven repo holding the vendored Plaud SDK — see
// m2repo/ai/plaud/sdk/plaud-sdk/1.0.0/plaud-sdk-1.0.0.pom for why it isn't a plain
// `files(...)` dependency.
//
// Registered on every project, not just this one: the SDK is an `api` dependency, so the host
// app resolves it onto its own runtime classpath and needs to know where it lives. Doing it here
// rather than in android/build.gradle.kts keeps the plugin self-contained, the way the iOS
// podspec's vendored_frameworks does. `projectDir` is captured outside the closure because
// inside it refers to whichever project is being configured.
val plaudSdkRepo = uri("$projectDir/m2repo")

rootProject.allprojects {
    repositories {
        maven { url = plaudSdkRepo }
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "ai.plaud.plaud_sdk"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // The Plaud AAR declares minSdk 21; 24 matches Flutter's own floor.
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Vendored Plaud Android SDK — byte-identical to ../plaud-sdk-public/sdk/android/plaud-sdk.aar
    // (the iOS counterpart lives in ios/Frameworks/*.xcframework).
    api("ai.plaud.sdk:plaud-sdk:1.0.0")

    // The AAR is consumed as a bare file, so it carries no POM: every dependency it
    // declares with `api` in its own build has to be repeated here or the app fails at
    // runtime with NoClassDefFoundError. List mirrors app/build.gradle in
    // ../plaud-sdk-public/android.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("com.jakewharton.timber:timber:4.7.1")
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.9.3")
    implementation("com.squareup.okhttp3:logging-interceptor:4.9.3")
    implementation("com.github.tony19:logback-android:2.0.0")
    implementation("org.slf4j:slf4j-api:1.7.32")
    implementation("org.bouncycastle:bcprov-jdk15on:1.70")
    implementation("org.conscrypt:conscrypt-android:2.5.2")
    implementation("org.java-websocket:Java-WebSocket:1.5.1")
    implementation("com.google.guava:guava:28.2-android")
}
