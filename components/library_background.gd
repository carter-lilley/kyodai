class_name LibraryBackground
extends Control

@onready var color_rect: ColorRect = $ColorRect

var _material: ShaderMaterial = null

# XMB Shader Parameters (exposed for easy access)
@export var time_scale: float = 1.0:
	set(value):
		time_scale = value
		if _material:
			_material.set_shader_parameter("time_scale", value)

@export var show_dust: bool = true:
	set(value):
		show_dust = value
		if _material:
			_material.set_shader_parameter("show_dust", value)

@export var wave_intensity: float = 1.0:
	set(value):
		wave_intensity = value
		if _material:
			_material.set_shader_parameter("wave_intensity", value)

@export var star_threshold: float = 0.99:
	set(value):
		star_threshold = value
		if _material:
			_material.set_shader_parameter("star_threshold", value)

func _ready():
	# Get the shader material
	if color_rect and color_rect.material is ShaderMaterial:
		_material = color_rect.material
		# Apply initial values
		_material.set_shader_parameter("time_scale", time_scale)
		_material.set_shader_parameter("show_dust", show_dust)
		_material.set_shader_parameter("wave_intensity", wave_intensity)
		_material.set_shader_parameter("star_threshold", star_threshold)
	else:
		push_error("[LibraryBackground] No material found!")

# Legacy method for backward compatibility with the solid color shader
func set_background_color(color: Color) -> void:
	# This method is kept for backward compatibility but doesn't apply to XMB shader
	# The XMB shader has its own colors built-in
	pass

# XMB-specific control methods
func set_time_scale(value: float) -> void:
	time_scale = value

func set_show_dust(value: bool) -> void:
	show_dust = value

func set_wave_intensity(value: float) -> void:
	wave_intensity = value

func set_star_threshold(value: float) -> void:
	star_threshold = value
