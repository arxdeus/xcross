plugins {
    alias(libs.plugins.kotlinMultiplatform)
}

kotlin {
    iosArm64 {
        binaries.framework {
            baseName = "Shared"
            isStatic = true
        }
    }
}
