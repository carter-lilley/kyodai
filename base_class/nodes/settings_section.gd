class_name SettingsSection
extends VBoxContainer

## Grouped settings container: a centered section header (icon + lowercase
## title flanked by horizontal rules) above a rounded "section card".
## Rows added via add_row()/add_content() are separated by inset HSeparators;
## multiple trailing controls in a row are split by a thin VSeparator.
##
## Visual tokens (surface color, rounding, dp metrics) mirror M3Card so
## sections read as the same surface language without subclassing it.

var _card: PanelContainer = null
var _rows: VBoxContainer = null
var _rules: Array[Control] = []
var _header_cluster: HBoxContainer = null

func _init(title: String = "", icon_name: String = "") -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", int(M3Units.dp(8)))

	if not title.is_empty():
		add_child(_build_header(title, icon_name))

	_card = PanelContainer.new()
	_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card_style := StyleBoxFlat.new()
	card_style.anti_aliasing = true
	card_style.set_corner_radius_all(int(M3Units.dp(16)))
	card_style.content_margin_left = M3Units.dp(16)
	card_style.content_margin_right = M3Units.dp(16)
	card_style.content_margin_top = M3Units.dp(12)
	card_style.content_margin_bottom = M3Units.dp(12)
	_card.add_theme_stylebox_override("panel", card_style)
	add_child(_card)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", int(M3Units.dp(8)))
	_card.add_child(_rows)

	refresh_theme()

## Add a settings row: content expands to fill, trailing controls sit at the
## right edge separated by thin vertical rules (e.g. between an action button
## and a switch).
func add_row(content: Control, trailing: Array[Control] = []) -> HBoxContainer:
	_add_separator_if_needed()
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size = Vector2(0, M3Units.dp(64))
	row.add_theme_constant_override("separation", int(M3Units.dp(12)))
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(content)
	var first_trailing := true
	for control in trailing:
		if control == null:
			continue
		if not first_trailing:
			row.add_child(_make_vrule())
		first_trailing = false
		control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(control)
	_rows.add_child(row)
	return row

## Add arbitrary content (grids, panels, stacked controls) to the card body
## without row height/alignment constraints.
func add_content(control: Control, with_separator: bool = true) -> void:
	if with_separator:
		_add_separator_if_needed()
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_child(control)

func get_card() -> PanelContainer:
	return _card

func refresh_theme() -> void:
	var card_style := _card.get_theme_stylebox("panel") as StyleBoxFlat
	if card_style:
		card_style.bg_color = M3Theme.get_surface_container_low()
	var rule_color := M3Theme.get_outline()
	rule_color.a = 0.35
	for rule in _rules:
		var sb := rule.get_theme_stylebox("separator") as StyleBoxLine
		if sb:
			sb.color = rule_color
	if _header_cluster:
		for child in _header_cluster.get_children():
			if child is FontIcon:
				child.icon_settings.icon_color = M3Theme.get_on_surface_variant()

func _build_header(title: String, icon_name: String) -> Control:
	var header := HBoxContainer.new()
	header.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_theme_constant_override("separation", int(M3Units.dp(12)))
	header.add_child(_make_rule())

	_header_cluster = HBoxContainer.new()
	_header_cluster.add_theme_constant_override("separation", int(M3Units.dp(8)))
	if not icon_name.is_empty():
		var icon := FontIcon.new()
		icon.icon_settings = FontIconSettings.new()
		icon.icon_settings.icon_name = icon_name
		icon.icon_settings.icon_size = int(M3Units.dp(18))
		icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_header_cluster.add_child(icon)
	var label := M3Label.new()
	label.text = title.to_lower()
	label.label_style = M3Label.Style.TITLE_MEDIUM
	# M3Label owns font_color; use its variant-color switch rather than an
	# override (which _apply_style would clobber).
	label.use_on_surface_variant = true
	_header_cluster.add_child(label)
	header.add_child(_header_cluster)

	header.add_child(_make_rule())
	return header

func _add_separator_if_needed() -> void:
	if _rows.get_child_count() > 0:
		var sep := _make_rule()
		_rows.add_child(sep)

func _make_rule() -> HSeparator:
	var rule := HSeparator.new()
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxLine.new()
	sb.thickness = 1
	rule.add_theme_stylebox_override("separator", sb)
	_rules.append(rule)
	return rule

func _make_vrule() -> VSeparator:
	var rule := VSeparator.new()
	rule.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxLine.new()
	sb.thickness = 1
	sb.vertical = true
	rule.add_theme_stylebox_override("separator", sb)
	_rules.append(rule)
	return rule
