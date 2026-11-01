import java.util.Base64

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    // Ship the native HTTP engine with the app, including on devices without
    // Google Play Services. This flag is consumed only by cronet_http's Gradle
    // dependency selection; it is deliberately fixed for every build variant.
    if (name == "cronet_http") {
        val definitions = (findProperty("dart-defines") as? String).orEmpty()
            .split(',').filter { it.isNotEmpty() }
            .filterNot { String(Base64.getDecoder().decode(it)).startsWith("cronetHttpNoPlay=") }
        extra["dart-defines"] = (definitions + Base64.getEncoder()
            .encodeToString("cronetHttpNoPlay=true".toByteArray())).joinToString(",")
    }
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
