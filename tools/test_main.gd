extends "res://node_3d.gd"
# The viewer, but it never touches the user's settings file.

func _set_setting(_k, _v):
	pass

func _setting(_k, default):
	return default
