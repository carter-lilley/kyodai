extends Manager
class_name AudioSubManager

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

# SystemManager.audio - Handles music and SFX playback with pool-based SFX players
# Simple API: play_sfx(), play_music(), stop_music()

const SFX_POOL_SIZE := 4
const DEFAULT_FADE_DURATION := 0.5
const MUSIC_BUS := "Music"
const SFX_BUS := "SFX"
const BGM_BUS := "BGM"

# SFX Assets - Preloaded for instant playback
var _sfx_library: Dictionary[String, AudioStream] = {}

# Audio Players
var _sfx_pool: Array[AudioStreamPlayer] = []
var _music_player: AudioStreamPlayer
var _bgm_player: AudioStreamPlayer
var _loop_player: AudioStreamPlayer
var _loop_check_timer: Timer
var _loop_should_continue: Callable
var _current_loop_stream: AudioStream = null
## Remaining plays before the loop cuts itself off (0 = unlimited). Set via
## the max_loops param of play_loop_while/play_loop_stream_while.
var _loop_plays_remaining: int = 0

# State
var _current_music_stream: AudioStream = null
var _current_bgm_path: String = ""
var _persisting_bgm_path := false
var _is_muted := false
var _sfx_volume := 1.0
var _music_volume := 1.0
## Set when BGM was paused by an app focus loss (Android screen off / app
## switch), so focus return only resumes what it paused. Game-launch pauses
## (LaunchManager.session_activated) are owned by LaunchManager.
var _paused_for_focus := false
## In-flight BGM fade-out tween from pause_background_music(). Tracked so a
## resume can cancel it before its finished callback pauses the stream out
## from under playback that was already resumed (focus-out -> focus-in can
## arrive within the fade window when the device wakes straight into the app).
var _bgm_pause_tween: Tween = null

func _ready() -> void:
	_setup_audio_buses()
	_load_sfx_library()
	_setup_sfx_pool()
	_setup_music_player()
	_setup_bgm_player()
	_setup_loop_player()
	_connect_settings()
	_apply_initial_volumes()
	
	# Play startup sound after a short delay
	get_tree().create_timer(0.5).timeout.connect(_play_startup_sound)

func _setup_audio_buses() -> void:
	# Ensure Music and SFX buses exist
	var music_idx = AudioServer.get_bus_index(MUSIC_BUS)
	if music_idx == -1:
		AudioServer.add_bus(-1)
		AudioServer.set_bus_name(AudioServer.bus_count - 1, MUSIC_BUS)

	var sfx_idx = AudioServer.get_bus_index(SFX_BUS)
	if sfx_idx == -1:
		AudioServer.add_bus(-1)
		AudioServer.set_bus_name(AudioServer.bus_count - 1, SFX_BUS)

	var bgm_idx = AudioServer.get_bus_index(BGM_BUS)
	if bgm_idx == -1:
		AudioServer.add_bus(-1)
		AudioServer.set_bus_name(AudioServer.bus_count - 1, BGM_BUS)

	# Move players to their respective buses
	var music_bus_idx = AudioServer.get_bus_index(MUSIC_BUS)
	var sfx_bus_idx = AudioServer.get_bus_index(SFX_BUS)
	var bgm_bus_idx = AudioServer.get_bus_index(BGM_BUS)

	if music_bus_idx != -1:
		AudioServer.set_bus_send(music_bus_idx, "Master")
	# Route BGM through the Music bus so the music volume slider controls both
	if bgm_bus_idx != -1:
		AudioServer.set_bus_send(bgm_bus_idx, MUSIC_BUS)
	if sfx_bus_idx != -1:
		AudioServer.set_bus_send(sfx_bus_idx, "Master")
		# Add subtle reverb to SFX bus
		var reverb = AudioEffectReverb.new()
		reverb.room_size = 0.3
		reverb.damping = 0.5
		reverb.wet = 0.15
		AudioServer.add_bus_effect(sfx_bus_idx, reverb)

func _load_sfx_library() -> void:
	# Load all SFX from assets/sfx/ directory
	var sfx_files = {
		"click_00": "res://assets/audio/sfx/click_00.wav",
		"click_01": "res://assets/audio/sfx/click_01.wav",
		"click_02": "res://assets/audio/sfx/click_02.wav",
		"click_03": "res://assets/audio/sfx/click_03.wav",
		"click_04": "res://assets/audio/sfx/click_04.wav",
		"click_05": "res://assets/audio/sfx/click_05.wav",
		"affirm_00": "res://assets/audio/sfx/affirm_00.wav",
		"affirm_01": "res://assets/audio/sfx/affirm_01.wav",
		"snap": "res://assets/audio/sfx/snap.wav",
		"loading": "res://assets/audio/sfx/loading.wav",
		"loading_2": "res://assets/audio/sfx/loading_2.wav",
		"error": "res://assets/audio/sfx/error.wav",
		"closing": "res://assets/audio/sfx/closing.wav",
		"return": "res://assets/audio/sfx/return.wav",
		"sfx": "res://assets/audio/sfx/sfx.wav"
	}
	
	for sfx_name in sfx_files.keys():
		var stream = load(sfx_files[sfx_name])
		if stream:
			_sfx_library[sfx_name] = stream
		else:
			push_warning("[SystemManager.audio]: Failed to load SFX: ", sfx_files[sfx_name])

func _setup_sfx_pool() -> void:
	# Create pool of SFX players
	var sfx_bus_idx = AudioServer.get_bus_index(SFX_BUS)
	for i in range(SFX_POOL_SIZE):
		var player = AudioStreamPlayer.new()
		player.name = "SFXPlayer_" + str(i)
		if sfx_bus_idx != -1:
			player.bus = SFX_BUS
		add_child(player)
		_sfx_pool.append(player)

func _setup_music_player() -> void:
	# Create dedicated music player
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "MusicPlayer"
	var music_bus_idx = AudioServer.get_bus_index(MUSIC_BUS)
	if music_bus_idx != -1:
		_music_player.bus = MUSIC_BUS
	add_child(_music_player)

func _setup_bgm_player() -> void:
	# Create dedicated background music player (user-selected looping track)
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BGMPlayer"
	var bgm_bus_idx = AudioServer.get_bus_index(BGM_BUS)
	if bgm_bus_idx != -1:
		_bgm_player.bus = BGM_BUS
	add_child(_bgm_player)
	# Manual looping (stream loop flags are unreliable for runtime-loaded files)
	_bgm_player.finished.connect(func():
		if not _current_bgm_path.is_empty() and not _bgm_player.stream_paused:
			_bgm_player.play()
	)

func _setup_loop_player() -> void:
	# Create dedicated loop player (separate from SFX pool for long-running loops)
	_loop_player = AudioStreamPlayer.new()
	_loop_player.name = "LoopPlayer"
	
	# IMPORTANT: Add to scene tree BEFORE setting bus
	add_child(_loop_player)
	
	# Set bus after adding to tree
	var sfx_bus_idx = AudioServer.get_bus_index(SFX_BUS)
	if sfx_bus_idx != -1:
		# Use bus name as string, but verify it exists
		_loop_player.bus = SFX_BUS
		#print("[SystemManager.audio] Loop player connected to bus: " + _loop_player.bus + " (index: " + str(sfx_bus_idx) + ")")
	else:
		push_warning("[SystemManager.audio] SFX bus not found, loop player using Master")
		#print("[SystemManager.audio] Available buses: ")
		for i in range(AudioServer.bus_count):
			pass
			#print("  - " + AudioServer.get_bus_name(i))
	
	# Connect to finished signal for manual looping (more reliable than stream loop_mode)
	_loop_player.finished.connect(_on_loop_player_finished)
	
	# Create timer for checking loop condition
	_loop_check_timer = Timer.new()
	_loop_check_timer.name = "LoopCheckTimer"
	_loop_check_timer.wait_time = 0.1
	_loop_check_timer.timeout.connect(_check_loop_condition)
	add_child(_loop_check_timer)

func _check_loop_condition() -> void:
	if not _loop_should_continue.is_valid():
		#print("[SystemManager.audio] Loop condition callable invalid, stopping")
		stop_loop()
		return
	
	var should_continue = _loop_should_continue.call()
	if not should_continue:
		#print("[SystemManager.audio] Loop condition returned false, stopping")
		stop_loop()

func play_loop_while(sfx_name: String, should_continue: Callable, volume_db: float = 0.0, max_loops: int = 0) -> bool:
	"""Play a looping sound while the should_continue callable returns true.
	The callable is checked every 0.1 seconds. When it returns false, the loop stops.
	max_loops > 0 cuts the loop off after that many total plays."""
	#print("[SystemManager.audio] play_loop_while called for: " + sfx_name)

	if not _sfx_library.has(sfx_name):
		push_warning("[SystemManager.audio]: SFX not found: ", sfx_name)
		return false

	# Prevent duplicate loops
	if _loop_player.playing:
		#print("[SystemManager.audio] Loop already playing, ignoring duplicate call")
		return true

	# Use the preloaded stream
	var stream = _sfx_library[sfx_name]
	return play_loop_stream_while(stream, should_continue, volume_db, max_loops)

func play_loop_stream_while(stream: AudioStream, should_continue: Callable, volume_db: float = 0.0, max_loops: int = 0) -> bool:
	"""Play a custom audio stream as a loop while the should_continue callable returns true."""
	#print("[SystemManager.audio] play_loop_stream_while called")

	if not stream:
		#print("[SystemManager.audio] Stream is null!")
		return false

	# Stop any existing loop first
	stop_loop()

	_loop_should_continue = should_continue
	_loop_plays_remaining = max_loops
	
	# Note: We use manual looping via finished signal instead of stream.loop_mode
	# because loop_mode doesn't always work reliably with imported WAV files
	
	#print("[SystemManager.audio] Stream format: " + str(stream.get_class()))
	#print("[SystemManager.audio] Stream length: " + str(stream.get_length()))
	#print("[SystemManager.audio] SFX bus index: " + str(AudioServer.get_bus_index(SFX_BUS)))
	#print("[SystemManager.audio] SFX bus volume (linear): " + str(db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(SFX_BUS)))))
	#print("[SystemManager.audio] SFX bus muted: " + str(AudioServer.is_bus_mute(AudioServer.get_bus_index(SFX_BUS))))
	#print("[SystemManager.audio] Master bus muted: " + str(AudioServer.is_bus_mute(AudioServer.get_bus_index("Master"))))
	
	# Store the stream to prevent garbage collection
	_current_loop_stream = stream
	
	# Reset player state
	_loop_player.stop()
	_loop_player.stream = null
	
	_loop_player.stream = _current_loop_stream
	_loop_player.volume_db = volume_db
	#print("[SystemManager.audio] Loop player bus: " + _loop_player.bus)
	#print("[SystemManager.audio] SFX bus volume: " + str(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(SFX_BUS))))
	#print("[SystemManager.audio] Starting loop playback")
	_loop_player.play()
	#print("[SystemManager.audio] Loop player playing: " + str(_loop_player.playing))
	#print("[SystemManager.audio] Stream valid: " + str(is_instance_valid(_loop_player.stream)))
	#print("[SystemManager.audio] Playback position: " + str(_loop_player.get_playback_position()))
	_loop_check_timer.start()
	#print("[SystemManager.audio] Timer started")
	
	return true

func _on_loop_player_finished() -> void:
	"""Replay the sound when it finishes (manual looping)."""
	# Only restart if timer isn't running (avoid duplicate restarts)
	if _loop_check_timer.is_stopped():
		return
	
	#print("[SystemManager.audio] Loop finished, checking if should continue...")
	
	# Check if we should continue looping
	if not _loop_should_continue.is_valid():
		#print("[SystemManager.audio] Loop callable invalid")
		stop_loop()
		return
	
	var should_continue = _loop_should_continue.call()
	#print("[SystemManager.audio] Should continue: " + str(should_continue))
	
	if not should_continue:
		#print("[SystemManager.audio] Loop condition returned false, not restarting")
		stop_loop()
		return

	# Capped loops cut off at the boundary of the last allowed play
	if _loop_plays_remaining > 0:
		_loop_plays_remaining -= 1
		if _loop_plays_remaining == 0:
			stop_loop()
			return

	# Restart playback
	#print("[SystemManager.audio] Restarting loop")
	_loop_player.play()

func stop_loop() -> void:
	"""Stop the current looping sound."""
	#print("[SystemManager.audio] Stopping loop")
	if _loop_player.playing:
		_loop_player.stop()
	_loop_check_timer.stop()
	_loop_should_continue = Callable()
	_loop_plays_remaining = 0
	_loop_player.stream = null
	_current_loop_stream = null
	#print("[SystemManager.audio] Loop stopped and cleared")

func is_loop_playing() -> bool:
	"""Check if a loop is currently playing."""
	return _loop_player.playing

func _connect_settings() -> void:
	# Connect to DataManager for volume changes
	if DataManager:
		DataManager.setting_changed.connect(_on_setting_changed)

func _apply_initial_volumes() -> void:
	# Apply initial volumes from settings
	if DataManager:
		var music_setting = DataManager.get_setting("dblevel_music")
		var sfx_setting = DataManager.get_setting("dblevel_sfx")
		var bgm_setting = DataManager.get_setting("music_file")

		if music_setting:
			set_music_volume(music_setting.value / 100.0)
		if sfx_setting:
			set_sfx_volume(sfx_setting.value / 100.0)
		if bgm_setting and not str(bgm_setting.value).is_empty():
			play_background_music_file(bgm_setting.value)

	# Pause background music while a game is running (menus-only playback)
	if LaunchManager:
		if not LaunchManager.session_activated.is_connected(_on_game_session_activated):
			LaunchManager.session_activated.connect(_on_game_session_activated)
		if not LaunchManager.session_finalized.is_connected(_on_game_session_finalized):
			LaunchManager.session_finalized.connect(_on_game_session_finalized)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	# Update volumes when settings change
	match setting.property_name:
		"dblevel_music":
			set_music_volume(setting.value / 100.0)
		"dblevel_sfx":
			set_sfx_volume(setting.value / 100.0)
		"music_file":
			var path := str(setting.value)
			if path.is_empty():
				stop_background_music()
			else:
				play_background_music_file(path)

func _on_game_session_activated(session: GameSession, _legacy_pid: int) -> void:
	if not session.is_shuffler():
		pause_background_music()

func _on_game_session_finalized(session: GameSession, _exit_code: int) -> void:
	# A shuffler session owns the music pause end-to-end; don't resume
	# between rounds when an individual game process exits.
	if session.is_shuffler() or LaunchManager.is_session_active():
		return
	resume_background_music()

# ==================== APP FOCUS (Android screen-off / app switch) ====================

func _notification(what: int) -> void:
	# Android-only: screen-off/app-switch must not keep playing audio (battery).
	# Desktop keeps music playing when unfocused, matching existing behavior.
	# NB: do not route this through SystemManager — focus-out can arrive during
	# shutdown, when the autoload is already freed (nil base access).
	if not OS.has_feature("android"):
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_on_app_focus_out()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_on_app_focus_in()

func _on_app_focus_out() -> void:
	"""Pause playback while the app is unfocused (screen off or another app
	visible). BGM paused by a game launch is already paused and stays owned by
	LaunchManager; loading/sync loops pause via stream_paused and continue
	when focus returns."""
	# Focus-out can arrive during shutdown, after the players are freed.
	if not is_instance_valid(_bgm_player) or not is_instance_valid(_loop_player):
		return
	if _bgm_player.playing and not _bgm_player.stream_paused:
		_paused_for_focus = true
		pause_background_music(0.2)
	if _loop_player.playing and not _loop_player.stream_paused:
		_loop_player.stream_paused = true

func _on_app_focus_in() -> void:
	if not is_instance_valid(_bgm_player) or not is_instance_valid(_loop_player):
		return
	# While a game runs (background state) LaunchManager owns the BGM pause —
	# do not resume over it.
	if LaunchManager and (LaunchManager.is_in_background_state() or LaunchManager.is_session_active()):
		_paused_for_focus = false
		return
	if _paused_for_focus:
		_paused_for_focus = false
		resume_background_music(0.3)
	if _loop_player.playing and _loop_player.stream_paused:
		_loop_player.stream_paused = false

func _play_startup_sound() -> void:
	play_sfx("affirm_01")

# ==================== SFX API ====================

func play_sfx(sfx_name: String, volume_db: float = 0.0) -> bool:
	"""Play a sound effect by name from the SFX library."""
	if not _sfx_library.has(sfx_name):
		push_warning("[SystemManager.audio]: SFX not found: ", sfx_name)
		return false
	
	return play_sfx_stream(_sfx_library[sfx_name], volume_db)

func play_sfx_stream(stream: AudioStream, volume_db: float = 0.0) -> bool:
	"""Play a custom audio stream as SFX."""
	if not stream:
		return false
	
	# Find an available SFX player
	var player = _get_available_sfx_player()
	if not player:
		push_warning("[SystemManager.audio]: All SFX players busy")
		return false
	
	player.stream = stream
	player.volume_db = volume_db
	player.play()
	return true

func play_sfx_random(sfx_names: Array[String], volume_db: float = 0.0) -> bool:
	"""Play a random SFX from the provided list of names."""
	if sfx_names.is_empty():
		return false
	
	var random_name = sfx_names[randi() % sfx_names.size()]
	return play_sfx(random_name, volume_db)

func play_sfx_modulate(sfx_name: String, min_pitch: float = 0.95, max_pitch: float = 1.05, volume_db: float = 0.0) -> bool:
	"""Play a sound effect with random pitch modulation."""
	if not _sfx_library.has(sfx_name):
		push_warning("[SystemManager.audio]: SFX not found: ", sfx_name)
		return false
	
	return play_sfx_stream_modulate(_sfx_library[sfx_name], min_pitch, max_pitch, volume_db)

func play_sfx_stream_modulate(stream: AudioStream, min_pitch: float = 0.95, max_pitch: float = 1.05, volume_db: float = 0.0) -> bool:
	"""Play a custom audio stream with random pitch modulation."""
	if not stream:
		return false
	
	# Find an available SFX player
	var player = _get_available_sfx_player()
	if not player:
		push_warning("[SystemManager.audio]: All SFX players busy")
		return false
	
	# Random pitch in range
	var random_pitch = randf_range(min_pitch, max_pitch)
	
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = random_pitch
	player.play()
	
	# Reset pitch after playback (for next use)
	player.finished.connect(func(): player.pitch_scale = 1.0, CONNECT_ONE_SHOT)
	
	return true

func stop_all_sfx() -> void:
	"""Stop all currently playing SFX."""
	for player in _sfx_pool:
		if player.playing:
			player.stop()

func _get_available_sfx_player() -> AudioStreamPlayer:
	"""Get the first available (non-playing) SFX player."""
	for player in _sfx_pool:
		if not player.playing:
			return player
	return null

# ==================== MUSIC API ====================

func play_music(stream: AudioStream, fade_duration: float = DEFAULT_FADE_DURATION) -> void:
	"""Play music with optional fade-in."""
	if not stream:
		return
	
	if _music_player.playing and _current_music_stream == stream:
		# Already playing this track
		return
	
	_current_music_stream = stream
	
	if fade_duration > 0.0 and _music_player.playing:
		# Crossfade from current music
		_crossfade_music(stream, fade_duration)
	else:
		# Play immediately or fade in from silence
		_music_player.stream = stream
		_music_player.play()
		if fade_duration > 0.0:
			_music_player.volume_db = -80.0
			_create_volume_tween(_music_player, 0.0, fade_duration)

func stop_music(fade_duration: float = DEFAULT_FADE_DURATION) -> void:
	"""Stop music with optional fade-out."""
	if not _music_player.playing:
		return
	
	if fade_duration > 0.0:
		_create_volume_tween(_music_player, -80.0, fade_duration, true)
	else:
		_music_player.stop()
		_current_music_stream = null

func crossfade_music(new_stream: AudioStream, duration: float = 2.0) -> void:
	"""Crossfade to a new music track."""
	if not new_stream:
		return
	
	_crossfade_music(new_stream, duration)

func is_music_playing() -> bool:
	"""Check if music is currently playing."""
	return _music_player.playing

func _crossfade_music(new_stream: AudioStream, duration: float) -> void:
	"""Internal crossfade implementation."""
	if not _music_player.playing:
		play_music(new_stream, duration)
		return
	
	# Create temporary player for old music
	var old_player = AudioStreamPlayer.new()
	old_player.stream = _music_player.stream
	old_player.volume_db = _music_player.volume_db
	old_player.bus = _music_player.bus
	old_player.play(_music_player.get_playback_position())
	add_child(old_player)
	
	# Fade out old player
	_create_volume_tween(old_player, -80.0, duration, true)
	
	# Setup and fade in new music
	_music_player.stream = new_stream
	_music_player.volume_db = -80.0
	_music_player.play()
	_create_volume_tween(_music_player, 0.0, duration)
	
	_current_music_stream = new_stream

func _create_volume_tween(player: AudioStreamPlayer, target_db: float, duration: float, stop_after: bool = false) -> void:
	"""Create a tween for volume changes."""
	var tween = create_tween()
	tween.tween_property(player, "volume_db", target_db, duration)
	if stop_after:
		tween.finished.connect(func():
			player.stop()
			if player != _music_player and player != _bgm_player and player != _loop_player and not _sfx_pool.has(player):
				player.queue_free()
			elif player == _music_player:
				_current_music_stream = null
		)

# ==================== BACKGROUND MUSIC API ====================

func play_background_music_file(path: String, fade_duration: float = DEFAULT_FADE_DURATION) -> bool:
	"""Load and loop a user-selected audio file as background music."""
	if path.is_empty():
		stop_background_music(fade_duration)
		return false

	# Resolve/import content:// URIs (Android file picker) to a durable real path
	var effective_path: String = FSM.import_content_file(path, "user://background_music/")
	if effective_path != path and not _persisting_bgm_path:
		# Persist the usable path back to the setting (re-emits setting_changed)
		_persisting_bgm_path = true
		var music_file_setting = DataManager.get_setting("music_file")
		if music_file_setting:
			DataManager.set_setting(effective_path, music_file_setting)
		_persisting_bgm_path = false

	var stream := _load_audio_stream_from_file(effective_path)
	if not stream:
		push_warning("[SystemManager.audio]: Failed to load background music: ", effective_path)
		return false

	_current_bgm_path = effective_path
	_cancel_bgm_pause_tween()
	_bgm_player.stop()
	_bgm_player.stream_paused = false
	_bgm_player.stream = stream
	_bgm_player.play()
	if fade_duration > 0.0:
		_bgm_player.volume_db = -80.0
		_create_volume_tween(_bgm_player, 0.0, fade_duration)
	else:
		_bgm_player.volume_db = 0.0
	return true

func stop_background_music(fade_duration: float = DEFAULT_FADE_DURATION) -> void:
	"""Stop the background music track."""
	_current_bgm_path = ""
	_cancel_bgm_pause_tween()
	if not _bgm_player.playing:
		_bgm_player.stream = null
		return
	if fade_duration > 0.0:
		_create_volume_tween(_bgm_player, -80.0, fade_duration, true)
	else:
		_bgm_player.stop()
		_bgm_player.stream = null

func pause_background_music(fade_duration: float = DEFAULT_FADE_DURATION) -> void:
	"""Pause background music (e.g., while a game is running)."""
	if not _bgm_player.playing or _bgm_player.stream_paused:
		return
	_cancel_bgm_pause_tween()
	if fade_duration > 0.0:
		var tween = create_tween()
		_bgm_pause_tween = tween
		tween.tween_property(_bgm_player, "volume_db", -80.0, fade_duration)
		tween.finished.connect(func():
			# Only pause if this fade is still the current one — a resume may
			# have superseded it while the tween was in flight.
			if _bgm_pause_tween == tween:
				_bgm_pause_tween = null
				if _bgm_player.playing:
					_bgm_player.stream_paused = true
		)
	else:
		_bgm_player.stream_paused = true

func resume_background_music(fade_duration: float = DEFAULT_FADE_DURATION) -> void:
	"""Resume background music after a pause."""
	if _current_bgm_path.is_empty() or not _bgm_player.stream:
		return
	var pause_in_flight := _bgm_pause_tween != null
	_cancel_bgm_pause_tween()
	# Nothing to do if the music is already audibly playing (no pause applied
	# and none in flight).
	if not pause_in_flight and not _bgm_player.stream_paused:
		return
	_bgm_player.stream_paused = false
	if fade_duration > 0.0:
		_bgm_player.volume_db = -80.0
		_create_volume_tween(_bgm_player, 0.0, fade_duration)
	else:
		_bgm_player.volume_db = 0.0

func _cancel_bgm_pause_tween() -> void:
	"""Kill any in-flight BGM pause fade so its finished callback can't pause
	the stream after playback has resumed."""
	if _bgm_pause_tween:
		_bgm_pause_tween.kill()
		_bgm_pause_tween = null

func is_background_music_playing() -> bool:
	"""Check if background music is currently playing."""
	return _bgm_player.playing and not _bgm_player.stream_paused

func _load_audio_stream_from_file(path: String) -> AudioStream:
	"""Load an audio stream from a filesystem path based on file extension."""
	if path.begins_with("res://") or path.begins_with("user://"):
		var res_stream = load(path)
		if res_stream is AudioStream:
			return res_stream
		return null

	match path.get_extension().to_lower():
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
	push_warning("[SystemManager.audio]: Unsupported audio format: ", path)
	return null

# ==================== VOLUME CONTROL ====================

func set_sfx_volume(volume: float) -> void:
	"""Set SFX volume (0.0 to 1.0)."""
	_sfx_volume = clampf(volume, 0.0, 1.0)
	var sfx_bus_idx = AudioServer.get_bus_index(SFX_BUS)
	if sfx_bus_idx != -1:
		AudioServer.set_bus_volume_db(sfx_bus_idx, linear_to_db(_sfx_volume))

func set_music_volume(volume: float) -> void:
	"""Set music volume (0.0 to 1.0)."""
	_music_volume = clampf(volume, 0.0, 1.0)
	var music_bus_idx = AudioServer.get_bus_index(MUSIC_BUS)
	if music_bus_idx != -1:
		AudioServer.set_bus_volume_db(music_bus_idx, linear_to_db(_music_volume))

func get_sfx_volume() -> float:
	"""Get current SFX volume (0.0 to 1.0)."""
	return _sfx_volume

func get_music_volume() -> float:
	"""Get current music volume (0.0 to 1.0)."""
	return _music_volume

func toggle_mute() -> bool:
	"""Toggle global mute state. Returns new mute state."""
	_is_muted = not _is_muted
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), _is_muted)
	return _is_muted

func is_muted() -> bool:
	"""Check if audio is globally muted."""
	return _is_muted

func set_mute(muted: bool) -> void:
	"""Set global mute state."""
	_is_muted = muted
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), _is_muted)
