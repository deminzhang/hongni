@tool
extends EditorPlugin

var export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(export_plugin)
	export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name = "hongni_plugin"

	func _supports_platform(platform):
		if platform is EditorExportPlatformAndroid:
			return true
		return false

	func _get_android_libraries(platform, debug):
		if debug:
			return PackedStringArray(["res://addons/hongni_plugin/bin/hongni-plugin-debug.aar"])
		return PackedStringArray(["res://addons/hongni_plugin/bin/hongni-plugin-release.aar"])

	func _get_android_dependencies(platform, debug):
		return PackedStringArray([
			"androidx.biometric:biometric:1.1.0",
			"androidx.work:work-runtime-ktx:2.9.1",
			"androidx.core:core-ktx:1.15.0",
		])

	func _get_android_dependencies_maven_repos(platform, debug):
		return PackedStringArray([
			"https://maven.google.com",
			"https://repo1.maven.org/maven2",
		])

	func _get_name():
		return _plugin_name
