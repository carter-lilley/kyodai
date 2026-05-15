class_name M3MenuItem
extends RefCounted

## Material 3 Menu Item Data
## Lightweight data class describing a single menu entry.

enum Type { NORMAL, CHECKABLE, TWO_LINE, SECTION_LABEL, SEPARATOR }

var text: String = ""
var secondary_text: String = ""
var icon: String = ""
var trailing_icon: String = ""
var shortcut_text: String = ""
var checked: bool = false
var checkable: bool = false
var disabled: bool = false
var item_type: Type = Type.NORMAL
var callback: Callable = Callable()
var submenu: M3Menu = null

func _init(p_text: String = "", p_icon: String = "", p_type: Type = Type.NORMAL):
	text = p_text
	icon = p_icon
	item_type = p_type

static func make_normal(label: String, icon_name: String = "", cb: Callable = Callable(), trailing_icon_name: String = "") -> M3MenuItem:
	var item = M3MenuItem.new(label, icon_name, Type.NORMAL)
	item.callback = cb
	item.trailing_icon = trailing_icon_name
	return item

static func make_checkable(label: String, is_checked: bool = false, icon_name: String = "", cb: Callable = Callable(), trailing_icon_name: String = "") -> M3MenuItem:
	var item = M3MenuItem.new(label, icon_name, Type.CHECKABLE)
	item.checked = is_checked
	item.checkable = true
	item.callback = cb
	item.trailing_icon = trailing_icon_name
	return item

static func make_two_line(primary: String, secondary: String, icon_name: String = "", cb: Callable = Callable(), trailing_icon_name: String = "") -> M3MenuItem:
	var item = M3MenuItem.new(primary, icon_name, Type.TWO_LINE)
	item.secondary_text = secondary
	item.callback = cb
	item.trailing_icon = trailing_icon_name
	return item

static func make_section_label(label: String) -> M3MenuItem:
	return M3MenuItem.new(label, "", Type.SECTION_LABEL)

static func make_separator() -> M3MenuItem:
	return M3MenuItem.new("", "", Type.SEPARATOR)

static func make_submenu(label: String, p_submenu: M3Menu, icon_name: String = "") -> M3MenuItem:
	var item = M3MenuItem.new(label, icon_name, Type.NORMAL)
	item.submenu = p_submenu
	return item
