plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ee.nekoko.nbridge"
    compileSdk = 36

    defaultConfig {
        applicationId = "ee.nekoko.nbridge"
        minSdk = 28
        targetSdk = 36
        versionCode = 5
        versionName = "1.2.2"
    }

    // The already-public community key gives repeatable, upgradeable builds.
    signingConfigs {
        create("community") {
            storeFile = rootProject.file("../android/app/community.jks")
            storePassword = "CommunityKey"
            keyAlias = "communitykey"
            keyPassword = "CommunityKey"
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("community")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.highcapable.yukihookapi:api:1.2.0")
    compileOnly("de.robv.android.xposed:api:82")
    testImplementation("junit:junit:4.13.2")
}
