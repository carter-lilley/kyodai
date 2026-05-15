extends Control

const M3Card = preload("res://addons/m3/components/M3Card.gd")

var _scroll_container: ScrollContainer
var _cards_container: Control
var _cards_data: Array = []

func _ready():
	# Card data: [headline, supporting, variant, actions[], color1, color2]
	_cards_data = [
		["Elden Ring", "Action RPG", M3Card.Variant.ELEVATED, ["Launch"], Color(0.8, 0.2, 0.2), Color(0.3, 0.1, 0.4)],
		["Hades", "Roguelike", M3Card.Variant.FILLED, ["Launch", "Details"], Color(0.2, 0.5, 0.8), Color(0.1, 0.3, 0.6)],
		["Celeste", "Platformer", M3Card.Variant.OUTLINED, [], Color(0.9, 0.6, 0.2), Color(0.7, 0.3, 0.1)],
		["Hollow Knight", "Metroidvania", M3Card.Variant.ELEVATED, ["Launch"], Color(0.2, 0.7, 0.5), Color(0.1, 0.4, 0.3)],
		["Dead Cells", "Action Roguelike", M3Card.Variant.FILLED, ["Launch", "Update"], Color(0.8, 0.4, 0.1), Color(0.5, 0.2, 0.1)],
		["Stardew Valley", "Simulation", M3Card.Variant.OUTLINED, ["Launch"], Color(0.3, 0.7, 0.2), Color(0.1, 0.5, 0.3)],
	]
	
	# Create scroll container for cards (constrains cards to content area)
	_scroll_container = ScrollContainer.new()
	_scroll_container.name = "CardsScroll"
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	$MarginContainer/VBoxContainer.add_child(_scroll_container)
	
	# Move buttons HBox to be first child
	var hbox = $MarginContainer/VBoxContainer/HBoxContainer
	$MarginContainer/VBoxContainer.move_child(hbox, 0)
	
	# Connect view toggle buttons via M3ButtonGroup
	var view_group = hbox.get_node_or_null("M3ButtonGroup")
	if view_group:
		view_group.selection_changed.connect(_on_view_changed)
	
	# Default to grid view
	_on_grid_view()

func _on_view_changed(selected_indices: Array[int]):
	if selected_indices.is_empty():
		return
	match selected_indices[0]:
		0: _on_grid_view()
		1: _on_list_view()
		2: _on_carousel_view()

func _clear_cards():
	if _cards_container and is_instance_valid(_cards_container):
		_cards_container.queue_free()
		_cards_container = null

func _create_card(data: Array, layout_mode: int) -> M3Card:
	var card = M3Card.new()
	card.headline = data[0]
	card.supporting_text = data[1]
	card.card_variant = data[2]
	card.media_texture = _make_gradient_texture(data[4], data[5])
	card.card_layout_mode = layout_mode
	
	for action in data[3]:
		card.add_action(action)
	
	return card

func _on_grid_view():
	_clear_cards()
	
	var grid = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	for data in _cards_data:
		var card = _create_card(data, M3Card.LayoutMode.VERTICAL)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		grid.add_child(card)
	
	_scroll_container.add_child(grid)
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_cards_container = grid

func _on_list_view():
	_clear_cards()
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	for data in _cards_data:
		var card = _create_card(data, M3Card.LayoutMode.HORIZONTAL)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size.y = M3Units.dp(120)
		vbox.add_child(card)
	
	_scroll_container.add_child(vbox)
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_cards_container = vbox

func _on_carousel_view():
	_clear_cards()
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	for data in _cards_data:
		var card = _create_card(data, M3Card.LayoutMode.VERTICAL)
		card.custom_minimum_size.x = M3Units.dp(280)
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		hbox.add_child(card)
	
	_scroll_container.add_child(hbox)
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_cards_container = hbox

func _make_gradient_texture(color1: Color, color2: Color) -> GradientTexture2D:
	var gradient = Gradient.new()
	gradient.colors = PackedColorArray([color1, color2])
	
	var tex = GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 1.0)
	
	return tex
