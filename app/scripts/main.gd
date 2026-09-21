extends Node
## Root navigation node. Bootstraps into settings (unconfigured) or albums.


func _ready() -> void:
	_bootstrap.call_deferred()


func _bootstrap() -> void:
	if not Store.is_configured():
		get_tree().change_scene_to_file("res://scenes/settings.tscn")
		return

	# Server unreachable must not lock the user out of their local cache:
	# albums.tscn degrades to the offline snapshot and shows a hint.
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
