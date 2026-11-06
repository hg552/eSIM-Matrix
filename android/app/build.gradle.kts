plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Community builds always use the committed public key. Local properties and
// NLPA_* signing overrides belong to private brand builds, not this recipe.

android {
    namespace = "io.github.hg552.esimmatrix"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
        // The QRTR user service is described by an AIDL interface.
        aidl = true
    }


    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    // AGP encrypts this optional record with a fresh nonce. It is outside the
    // signed payload and makes otherwise identical APKs differ between builds.
    // Public Community APKs must be reproducible without Google Play metadata.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("community") {
            storeFile = file("community.jks")
            storePassword = "CommunityKey"
            keyAlias = "communitykey"
            keyPassword = "CommunityKey"
        }
        create("esim9") {
            storeFile = file("9eSIMCommunityKey.jks")
            storePassword = "147258369"
            keyAlias = "key0"
            keyPassword = "147258369"
        }
    }

    flavorDimensions += "version"

    productFlavors {
        create("community") {
            dimension = "version"
            applicationId = "io.github.hg552.esimmatrix.community"
            manifestPlaceholders["appName"] = "NekokoLPA 2 Community"
            signingConfig = signingConfigs.getByName("community")
        }

        create("nexus") {
            dimension = "version"
            applicationId = "io.github.hg552.esimmatrix.nexus"
            manifestPlaceholders["appName"] = "eSIM-Matrix"
            signingConfig = signingConfigs.getByName("community")
        }
        create("m") {
            dimension = "version"
            applicationId = "io.github.hg552.esimmatrix.multi"
            manifestPlaceholders["appName"] = "eSIM-Matrix"
            signingConfig = signingConfigs.getByName("esim9")
        }

        create("privileged") {
            dimension = "version"
            applicationId = "io.github.hg552.esimmatrix.privileged"
            manifestPlaceholders["appName"] = "NekokoLPA 2 Community Rooted"
            signingConfig = signingConfigs.getByName("community")
        }

    }

    // Public rooted builds share the Community dolphin artwork.
    sourceSets {
        getByName("privileged") {
            res.setSrcDirs(listOf("src/community/res"))
        }
        getByName("nexus") {
            res.setSrcDirs(listOf("src/community/res"))
        }
        getByName("m") {
            res.setSrcDirs(listOf("src/community/res"))
        }
    }

    defaultConfig {
        applicationId = "io.github.hg552.esimmatrix"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            
            // Force version code to match flutter.versionCode, preventing ABI splitting logic from changing it
            applicationVariants.all {
                outputs.all {
                    (this as? com.android.build.gradle.internal.api.ApkVariantOutputImpl)?.versionCodeOverride = flutter.versionCode
                }
            }
        }
        debug {
            signingConfig = signingConfigs.getByName("esim9")
        }
    }
    lint {
        checkReleaseBuilds = false
        abortOnError = false
        checkDependencies = false
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Only the `shell` user may open a QRTR socket, so the app asks Shizuku to
    // run a service there and takes the descriptor back over Binder.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
