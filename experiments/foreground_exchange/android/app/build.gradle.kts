plugins {
    id("com.android.application")
}

android {
    namespace = "org.trailmesh.foregroundprobe"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.trailmesh.foregroundprobe"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-nearby:19.5.0")

    testImplementation("junit:junit:4.13.2")
}
