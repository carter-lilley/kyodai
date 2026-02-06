class_name View
extends Control

signal view_ready()
signal view_shown()
signal view_hidden()

var view_name: String = ""

func _ready():
	view_ready.emit()

func on_view_show():
	view_shown.emit()

func on_view_hide():
	view_hidden.emit()
