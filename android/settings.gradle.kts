pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "CoShare"
// core: the protocol, network and sync engine in plain Kotlin (tested on the JVM against the Swift
// vectors and the Node peer); app: the Android shell around it.
include(":core", ":app")
