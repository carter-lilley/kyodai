class_name CardState
extends EffectContainerState

# CardState is now a specialization of EffectContainerState with card-specific defaults.
# It can be passed anywhere EffectContainerState is expected.
# Use .container_size instead of .card_size (alias kept for compat via _get)

func _init() -> void:
	super._init(Vector2(202.0, 270.0))
