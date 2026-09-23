tool
extends EditorImportPlugin

const MP4DataResource = preload("res://addons/godot_vap/mp4_data_resource.gd")


func get_importer_name():
	return "godot_vap.mp4_data"


func get_visible_name():
	return "MP4 Data"


func get_recognized_extensions():
	return ["mp4"]


func get_save_extension():
	return "res"


func get_resource_type():
	return "Resource"


func get_preset_count():
	return 1


func get_preset_name(preset):
	return "Default"


func get_import_options(preset):
	return []


func get_option_visibility(option, options):
	return true


func import(source_file, save_path, options, platform_variants, gen_files):
	var file = File.new()
	var error = file.open(source_file, File.READ)
	if error != OK:
		return error

	var mp4_resource = MP4DataResource.new()
	mp4_resource.resource_name = source_file.get_file()
	mp4_resource.source_md5 = file.get_md5(source_file)
	mp4_resource.data = file.get_buffer(file.get_len())
	file.close()
	return ResourceSaver.save(save_path + "." + get_save_extension(), mp4_resource)
