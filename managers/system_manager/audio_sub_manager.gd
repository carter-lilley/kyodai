extends Manager
class_name AudioSubManager

# SystemManager.audio - Handles music and SFX playback with pool-based SFX players
# Simple API: play_sfx(), play_music(), stop_music()

const SFX_POOL_SIZE := 4
const DEFAULT_FADE_DURATION := 0.5
const MUSIC_BUS := "Music"
const SFX_BUS := "SFX"

# SFX Assets - Preloaded for instant playback
var _sfx_library: Dictionary[String, AudioStream] = {}
var _sfx_paths: Dictionary[String, String] = {}

# Audio Players
var _sfx_pool: Array[AudioStreamPlayer] = []
var _music_player: AudioStreamPlayer
var _loop_player: AudioStreamPlayer
var _loop_check_timer: Timer
var _loop_should_continue: Callable
var _current_loop_stream: AudioStream = null

# State
var _current_music_stream: AudioStream = null
var _is_muted := false
var _sfx_volume := 1.0
var _music_volume := 1.0

func _ready() -> void:
	_setup_audio_buses()
	_load_sfx_library()
	_setup_sfx_pool()
	_setup_music_player()
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
	
	# Move players to their respective buses
	var music_bus_idx = AudioServer.get_bus_index(MUSIC_BUS)
	var sfx_bus_idx = AudioServer.get_bus_index(SFX_BUS)
	
	if music_bus_idx != -1:
		AudioServer.set_bus_send(music_bus_idx, "Master")
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
			_sfx_paths[sfx_name] = sfx_files[sfx_name]
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

func play_loop_while(sfx_name: String, should_continue: Callable, volume_db: float = 0.0) -> bool:
	"""Play a looping sound while the should_continue callable returns true.
	The callable is checked every 0.1 seconds. When it returns false, the loop stops."""
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
	return play_loop_stream_while(stream, should_continue, volume_db)

func play_loop_stream_while(stream: AudioStream, should_continue: Callable, volume_db: float = 0.0) -> bool:
	"""Play a custom audio stream as a loop while the should_continue callable returns true."""
	#print("[SystemManager.audio] play_loop_stream_while called")
	
	if not stream:
		#print("[SystemManager.audio] Stream is null!")
		return false
	
	# Stop any existing loop first
	stop_loop()
	
	_loop_should_continue = should_continue
	
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
		
		if music_setting:
			set_music_volume(music_setting.value / 100.0)
		if sfx_setting:
			set_sfx_volume(sfx_setting.value / 100.0)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	# Update volumes when settings change
	match setting.property_name:
		"dblevel_music":
			set_music_volume(setting.value / 100.0)
		"dblevel_sfx":
			set_sfx_volume(setting.value / 100.0)

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
			if player != _music_player:
				player.queue_free()
			else:
				_current_music_stream = null
		)

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
