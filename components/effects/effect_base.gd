class_name EffectBase
extends ColorRect

@export var effect_name: String = "Effect"
@export var effect_id: String = ""

var _settings: Dictionary = {}
var _container_state: EffectContainerState

signal effect_enabled_changed(enabled: bool)
signal settings_changed(setting_name: String, value: Variant)

func _ready():
	material = ShaderMaterial.new()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Make the ColorRect transparent so shader can control visibility
	color = Color.TRANSPARENT

func initialize(container_state: EffectContainerState, settings: Dictionary) -> void:
	_container_state = container_state
	_settings = settings.duplicate()
	_setup_shader()
	_apply_settings()
	_connect_container_state_signals()

func update_state(container_state: EffectContainerState) -> void:
	_disconnect_container_state_signals()
	_container_state = container_state
	_connect_container_state_signals()
	# Manually trigger size update since the signal may have fired before we reconnected
	if _container_state:
		_on_size_changed(_container_state.container_size)
	_update_shader_params()

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_apply_settings()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _update_shader_params() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	var mat = material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(param, value)

# Reactive signal connections
func _connect_container_state_signals() -> void:
	if not _container_state:
		return
	_container_state.zoom_changed.connect(_on_zoom_changed)
	_container_state.size_changed.connect(_on_size_changed)
	_container_state.orientation_changed.connect(_on_orientation_changed)
	_container_state.corner_radius_changed.connect(_on_corner_radius_changed)
	_container_state.border_inset_changed.connect(_on_border_inset_changed)
	_container_state.shape_changed.connect(_on_shape_changed)

func _disconnect_container_state_signals() -> void:
	if not _container_state:
		return
	if _container_state.zoom_changed.is_connected(_on_zoom_changed):
		_container_state.zoom_changed.disconnect(_on_zoom_changed)
	if _container_state.size_changed.is_connected(_on_size_changed):
		_container_state.size_changed.disconnect(_on_size_changed)
	if _container_state.orientation_changed.is_connected(_on_orientation_changed):
		_container_state.orientation_changed.disconnect(_on_orientation_changed)
	if _container_state.corner_radius_changed.is_connected(_on_corner_radius_changed):
		_container_state.corner_radius_changed.disconnect(_on_corner_radius_changed)
	if _container_state.border_inset_changed.is_connected(_on_border_inset_changed):
		_container_state.border_inset_changed.disconnect(_on_border_inset_changed)
	if _container_state.shape_changed.is_connected(_on_shape_changed):
		_container_state.shape_changed.disconnect(_on_shape_changed)

func _on_zoom_changed(_new_zoom: float) -> void:
	_update_shader_params()

func _on_size_changed(_new_size: Vector2) -> void:
	_update_shader_params()

func _on_orientation_changed(_new_orientation: int) -> void:
	_update_shader_params()

func _on_corner_radius_changed(_new_ratio: float) -> void:
	_update_shader_params()

func _on_border_inset_changed(_new_ratio: float) -> void:
	_update_shader_params()

func _on_shape_changed() -> void:
	_update_shader_params()
