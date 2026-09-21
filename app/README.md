此处为app子工程,前后端总工程向上../
app以该文目录为根

# Android 导出环境要求

hongni 的 Android 构建依赖一颗原生插件(`res://addons/hongni_plugin/bin/*.aar`,经
`export_plugin.gd` 注入),因此 `gradle_build/use_gradle_build=true` 是**必需项**,
与 lingwang(纯标准模板导出)不同。任何机器导出前需满足:

- **Godot 4.7.2**(Steam 版,自带导出模板)。版本须与 `.build_version=4.7.2.stable`
  一致,跨机器统一,否则模板不匹配。
- **OpenJDK 17**。
- **Android SDK**:platform-tools 35、build-tools 35、platform 35、NDK 28 + CMake。
  SDK 路径在 `Editor Settings → Android` 配置(机器级,不入库)。

**Gradle 构建模板 `android/`(及导出输出 `.android/`)不入 git**:它是 Godot
`Install Android Build Template` 从本机导出模板解压的可再生拷贝,与 Steam 模板同源
(`config.gradle` 逐字节一致)。新机器只需:
1. 安装 Godot 4.7.2(Steam 自动补齐该版本导出模板);
2. `Project → Install Android Build Template`;
3. 配置好 OpenJDK 17 + Android SDK 路径。

插件源码 `plugin-android/` 与产物 AAR 应入库(该传的),模板与 gradle 输出不入库。