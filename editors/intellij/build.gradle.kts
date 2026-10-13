import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("org.jetbrains.kotlin.jvm") version "2.2.21"
    id("org.jetbrains.intellij.platform") version "2.19.0"
}

group = "com.vaamapps"
version = "0.1.0"

// IntelliJ IDEA 2025.2 is the platform the plugin is compiled against. Android Studio and every
// other IDE built on platform 252 or later loads it, because it depends only on the platform
// (no Java or Kotlin plugin), and `until-build` is left open.
val platformVersion = "2025.2.6.2"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.opentest4j:opentest4j:1.3.0")

    intellijPlatform {
        intellijIdea(platformVersion)
        testFramework(TestFrameworkType.Platform)
    }
}

// The 2025.2 platform is compiled for Java 21, so building against it needs a JDK 21 (the IDE
// itself runs on a JBR 21).
kotlin {
    jvmToolchain(21)
}

intellijPlatform {
    pluginConfiguration {
        name = "fespalier"
        version = project.version.toString()
        ideaVersion {
            sinceBuild = "252"
            untilBuild = provider { null }
        }
    }
    buildSearchableOptions = false
    publishing {
        // A maintainer step: `PUBLISH_TOKEN=... ./gradlew publishPlugin` (see docs/releasing.md, "Releasing").
        token = providers.environmentVariable("PUBLISH_TOKEN")
    }
}
