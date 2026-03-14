@tool
extends EditorPlugin

var export_plugin: AndroidExportPlugin

func _enter_tree():
	print("[PackageChecker] Editor plugin loading...")
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)
	print("[PackageChecker] Editor plugin loaded successfully!")

func _exit_tree():
	print("[PackageChecker] Editor plugin unloading...")
	remove_export_plugin(export_plugin)
	export_plugin = null
	print("[PackageChecker] Editor plugin unloaded.")

class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name = "PackageChecker"

	func _supports_platform(platform):
		# Only support Android platform
		var is_android = platform is EditorExportPlatformAndroid
		print("[PackageChecker] _supports_platform called, is Android: " + str(is_android))
		return is_android

	func _get_android_libraries(platform, debug):
		# Return the AAR file path relative to addons/
		var aar_path = "res://addons/" + _plugin_name + "/PackageCheckerPlugin.aar"
		print("[PackageChecker] _get_android_libraries called, debug: " + str(debug) + ", returning: " + aar_path)
		return PackedStringArray([aar_path])

	func _get_android_dependencies(platform, debug):
		# Return Android dependencies required by the plugin
		var deps = PackedStringArray([
			"androidx.documentfile:documentfile:1.0.1",
			"androidx.core:core:1.12.0"
		])
		print("[PackageChecker] _get_android_dependencies called, returning: " + str(deps))
		return deps

	func _get_android_permissions(platform, debug):
		# Return Android permissions required by the plugin
		var perms = PackedStringArray([
			"QUERY_ALL_PACKAGES"
		])
		print("[PackageChecker] _get_android_permissions called, returning: " + str(perms))
		return perms

	func _get_name():
		return _plugin_name
