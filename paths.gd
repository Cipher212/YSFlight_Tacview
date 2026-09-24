# Where the viewer's folders are (aircraft, gamefiles, maps, events, Raw_Data, the Python
# pipeline): the project folder when run from Godot, and the folder of the .exe once exported
# (an exported project's res:// is packed inside the .exe and can't be read as plain files).

static func base() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()

# A file or folder of the viewer's, e.g. of("aircraft/weapon")
static func of(rel: String) -> String:
	return base().path_join(rel)
