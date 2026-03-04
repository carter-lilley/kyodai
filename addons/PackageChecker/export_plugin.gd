@tool
extends EditorPlugin

var export_plugin : AndroidExportPlugin

func _enter_tree():
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)

func _exit_tree():
	remove_export_plugin(export_plugin)
	export_plugin = null

class AndroidExportPlugin extends EditorExportPlugin:
	func _get_name():
		return "PackageChecker"
	
	func _get_android_manifest_application_element_content(platform: EditorExportPlatform, debug: bool) -> String:
		# Add the plugin metadata to the manifest
		return """
		<meta-data android:name="org.godotengine.plugin.v2.PackageChecker" android:value="com.heckpoint.kyodai.PackageCheckerPlugin"/>
		"""