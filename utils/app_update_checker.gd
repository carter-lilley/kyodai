# app_update_checker.gd
extends RefCounted
class_name AppUpdateChecker

## Startup self-update check against Kyodai's own GitHub releases.
##
## Stage 1 (check + notify): compares the newest release on the user's
## configured channel (Stable = non-prerelease only, Experimental = include
## prereleases) against the running build's version and, when a newer one
## exists, shows a dialog whose Download button opens the release page.
## Nothing is downloaded or installed automatically.

const REPO := "carter-lilley/kyodai"
const RELEASE_PAGE_BASE := "https://github.com/" + REPO + "/releases/tag/"

## Fire-and-forget: safe to call during startup. Automatic checks fail
## silently (logged only) so a flaky network can never interrupt boot;
## manual checks (settings "Check Now" button) report every outcome via
## snackbar, since the user is actively waiting on a result.
static func check_for_updates(from_manual_trigger: bool = false) -> void:
	if not DataManager or not SystemManager or not SystemManager.network:
		return

	# Editor/dev runs have no meaningful version relationship to releases.
	if OS.has_feature("editor"):
		if from_manual_trigger:
			_notify("Update checks are disabled in editor builds", SystemManager.notifications.Type.INFO)
		return

	if not from_manual_trigger:
		var toggle: SettingsVar = DataManager.get_setting("update_check_on_startup")
		if toggle and not toggle.value:
			return

		# First run: the OOBE wizard owns the screen, and a fresh install is
		# almost certainly current.
		var first_run: SettingsVar = DataManager.get_setting("first_run_completed")
		if first_run and not first_run.value:
			return

	var current := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	if current == "":
		return

	var asset_pattern := _platform_asset_pattern()
	if asset_pattern == "":
		return  # No release artifacts exist for this platform.

	var channel: SettingsVar = DataManager.get_setting("release_channel")
	# Channel index 1 (Experimental) opts into prereleases; anything else
	# (including a missing setting) stays on Stable.
	var include_prereleases := channel != null and channel.value is int and int(channel.value) == 1

	var on_release := func(_download_url: String, tag: String, error: String, _size: int, _published: String, _asset_updated: String, _sha256: String):
		if error != "":
			print("[AppUpdateChecker] Update check failed: " + error)
			if from_manual_trigger:
				_notify("Update check failed: " + error, SystemManager.notifications.Type.ERROR)
			return
		if tag == "":
			return
		# When every release is a prerelease, /releases/latest 404s and the
		# network fallback returns a prerelease even for Stable users. Tags
		# carry the prerelease marker (v0.7.0-beta.1), so filter it here.
		if not include_prereleases and tag.contains("-"):
			print("[AppUpdateChecker] Up to date on Stable (%s; newest is prerelease %s)" % [current, tag])
			if from_manual_trigger:
				_notify("You're up to date on Stable (%s; %s is an Experimental prerelease)" % [current, tag], SystemManager.notifications.Type.SUCCESS)
			return
		if VersionCompare.is_newer(tag, current):
			print("[AppUpdateChecker] Update available: %s -> %s" % [current, tag])
			# Deferred: the HTTP callback can land during early startup,
			# before the dialog layer is ready to host an M3Dialog.
			_show_update_dialog.call_deferred(tag, current)
		else:
			print("[AppUpdateChecker] Up to date (%s, latest %s)" % [current, tag])
			if from_manual_trigger:
				_notify("You're up to date (v%s)" % current, SystemManager.notifications.Type.SUCCESS)

	SystemManager.network.fetch_repo_release(REPO, asset_pattern, on_release, "", "", include_prereleases)

static func _platform_asset_pattern() -> String:
	if not SystemManager or not SystemManager.platform:
		return ""
	if SystemManager.platform.is_windows():
		return "Kyodai-windows-x64\\.zip"
	if SystemManager.platform.is_linux():
		return "Kyodai-.*\\.AppImage"
	if SystemManager.platform.is_android():
		return "Kyodai.*\\.apk"
	return ""

static func _notify(text: String, type: int) -> void:
	# Deferred for the same reason as the dialog: the HTTP callback can land
	# before the snackbar layer is ready during early startup.
	if SystemManager and SystemManager.notifications:
		SystemManager.notifications.show_notification.call_deferred(text, type)

static func _show_update_dialog(tag: String, current: String) -> void:
	var dialog := M3Dialog.new()
	dialog.title_text = "Update Available"
	dialog.body_text = "Kyodai %s is available (you have %s).\n\nDownload it from the GitHub release page?" % [tag, current]
	dialog.add_action("Later", func(): dialog.dismiss(), false)
	dialog.add_action("Download", func():
		OS.shell_open(RELEASE_PAGE_BASE + tag)
		dialog.dismiss()
	, true)
	M3Dialog.show_dialog(dialog)
