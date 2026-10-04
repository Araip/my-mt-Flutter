import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// key.properties 位于项目根目录（android/ 的上一级）。
// 本地由开发者自行创建；CI 由 workflow 从仓库 Secret 还原后生成。
val keystoreProperties = Properties()
val keystoreFile = rootProject.file("../key.properties")
if (keystoreFile.exists()) {
    keystoreProperties.load(FileInputStream(keystoreFile))
}

// 只有「key.properties 存在」且「它指向的 keystore 文件真的存在」时才启用正式签名。
// 这样在没配签名的环境（CI 未注入 Secret、或换了台机器）里依然能构建出 APK，
// 而不是卡死在 "SigningConfig 'release' is missing required property 'storeFile'"。
val releaseKeystore: File? = run {
    val path = keystoreProperties.getProperty("storeFile") ?: return@run null
    val f = File(path)
    // 相对路径按 app 模块目录解析，与 Gradle file() 的行为保持一致
    val resolved = if (f.isAbsolute) f else file(f.path)
    resolved.takeIf { it.exists() }
}

android {
    namespace = "com.binmt.mtforum"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.binmt.mtforum"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseKeystore != null) {
                storeFile = releaseKeystore
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 拿不到正式 keystore 就退回 debug 签名，保证产物始终可安装。
            // 注意：debug 签名的包无法覆盖已发布版本，仅供测试，正式发版务必配置签名。
            signingConfig = if (releaseKeystore != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
