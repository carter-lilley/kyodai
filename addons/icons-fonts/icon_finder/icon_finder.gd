@tool
extends Control

@export var icons_renderers: Array[IconsFontsRender]

@export var tooltip := "click on icon to copy its name to clipboard"

@export
@onready var icons_renderers_tabs: TabContainer

@export
@onready var notify_label: Label

@export
@onready var search_line_edit: LineEdit

@export
@onready var size_slider: HSlider

@export
@onready var size_label: Label

@export
@onready var scroll_container: ScrollContainer

@export
@onready var fonts_dropdown: OptionButton

var icons_renderer: IconsFontsRender

func _ready():
	notify_label.hide()
	search_line_edit.text_changed.connect(update_table)
	size_slider.value_changed.connect(update_icons_size)
	fonts_dropdown.item_selected.connect(on_font_changed)
	size_slider.value = IconsFonts.preview_size

	for renderer: IconsFontsRender in icons_renderers:
		renderer.tooltip_text = ""

func setup():
	# Wait for fonts to be loaded before rendering
	if IconsFonts.material_icons.is_empty() or IconsFonts.emojis.is_empty():
		await IconsFonts.font_loaded
	
	for renderer: IconsFontsRender in icons_renderers:
		if !renderer.is_node_ready(): await ready
		renderer.setup()
		renderer.meta_clicked.connect(_on_meta)
		renderer.meta_hover_started.connect(_on_meta_hover_started.bind(renderer))
		renderer.meta_hover_ended.connect(_on_meta_hover_ended.bind(renderer))
		renderer.update_table("")
	icons_renderer = icons_renderers[0]
	
	# Initial render after setup
	update_table("")

func update_icons_size(value: int):
	size_label.text = str(value)
	if icons_renderer:
		icons_renderer.set_icons_size(value)
		update_table(search_line_edit.text)
	IconsFonts.preview_size = value

func on_font_changed(font_id: int):
	icons_renderers_tabs.current_tab = font_id
	icons_renderer = icons_renderers[font_id]

func update_table(filter := ""):
	if not icons_renderer: return
	icons_renderer.update_table(filter)

func _on_meta(meta: Variant):
	var link := str(meta)
	DisplayServer.clipboard_set(link)
	notify_label.text = "Copied to Clipboard: " + link
	notify_label.show()

	var t := get_tree().create_tween()
	t.tween_property(
		notify_label, "modulate",
		Color.GREEN, 1
	)
	t.chain().tween_property(
		notify_label, "modulate",
		Color.TRANSPARENT, 1
	)
	await t.finished
	notify_label.hide()

func _on_meta_hover_started(meta: Variant, renderer: IconsFontsRender):
	renderer.tooltip_text = str(meta)

func _on_meta_hover_ended(meta: Variant, renderer: IconsFontsRender):
	renderer.tooltip_text = ""
