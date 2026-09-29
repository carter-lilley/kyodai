extends SceneTree

func _init() -> void:
	var script = load("res://effects/background/hero_art_background_effect.gd")
	if script == null:
		print("LOAD_FAILED")
		quit(1)
		return
	var eff = script.new()
	print("INSTANTIATED effect_id=", eff.effect_id, " name=", eff.effect_name)
	for s in eff.get_settings_schema():
		print("SCHEMA: %-8s prop=%-8s default=%-5s range=[%s..%s] step=%s" % [
			s.display_name, s.property_name, str(s.value), str(s.min_value), str(s.max_value), str(s.step)])

	eff.material = ShaderMaterial.new()
	eff._setup_shader()
	eff.update_settings({})
	var mat: ShaderMaterial = eff.material as ShaderMaterial
	print("blur param     = ", mat.get_shader_parameter("blur"))
	print("opacity param  = ", mat.get_shader_parameter("opacity"))
	print("dim param      = ", mat.get_shader_parameter("dim"))

	eff.update_settings({"blur": 0.65, "opacity": 0.4, "dim": 0.1})
	print("after override blur=", mat.get_shader_parameter("blur"),
		" opacity=", mat.get_shader_parameter("opacity"),
		" dim=", mat.get_shader_parameter("dim"))
	eff.free()
	print("ALL_OK")
	quit(0)
