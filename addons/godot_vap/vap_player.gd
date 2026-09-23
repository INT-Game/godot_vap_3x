extends Control

signal animation_ready(config)
signal animation_started
signal animation_finished
signal animation_error(error_message)
signal frame_changed(frame_number)
signal fusion_resource_needed(resource_id, resource_type)
signal fusion_resource_ready(resource_id)

export(bool) var autoplay = false
export(bool) var loop = false
export(bool) var enable_audio = false
export(bool) var debug = false

const Decoder = preload("res://addons/godot_mp4_decoder/native/mp4_decoder.gdns")
const COMPOSITOR_SHADER = preload("res://addons/godot_vap/shaders/vap_compositor.shader")
const FusionManager = preload("res://addons/godot_vap/vap_fusion_manager.gd")

var vap_config = {}
var video_info = {}
var is_playing = false
var current_frame = 0
var fusion_manager = null

var _decoder = null
var _base_rect = null
var _video_image = null
var _video_texture = null
var _frame_time = 1.0 / 30.0
var _time_accumulator = 0.0
var _video_loaded = false
var _audio_player = null
var _audio_playback = null


func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base_rect = TextureRect.new()
	_base_rect.name = "VAPCompositor"
	_base_rect.expand = true
	_base_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_base_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material = ShaderMaterial.new()
	material.shader = COMPOSITOR_SHADER
	_base_rect.material = material
	add_child(_base_rect)
	_audio_player = AudioStreamPlayer.new()
	_audio_player.name = "Audio"
	add_child(_audio_player)

	fusion_manager = FusionManager.new()
	fusion_manager.name = "FusionLayer"
	add_child(fusion_manager)
	fusion_manager.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	fusion_manager.connect("resource_request", self, "_on_fusion_resource_request")
	fusion_manager.connect("resource_ready", self, "_on_fusion_resource_ready")
	fusion_manager.connect("fusion_error", self, "_fail")
	connect("resized", self, "_layout_content")
	_layout_content()


func load_vap_video(video_path, config_path = ""):
	stop()
	var file = File.new()
	var decoder_video_path = _materialize_video(video_path)
	if decoder_video_path.empty():
		return false
	var config = {}
	if not str(config_path).empty():
		config = _load_json_config(config_path)
	else:
		config = extract_vapc_from_mp4(decoder_video_path)
		if config.empty():
			for companion_path in [video_path.get_base_dir().plus_file("vapc.json"), video_path.get_basename() + ".json"]:
				if file.file_exists(companion_path):
					config = _load_json_config(companion_path)
					break
	if not _accept_config(config):
		return false
	if not fusion_manager.setup(vap_config, self):
		return false

	_decoder = Decoder.new()
	if not _decoder.open(decoder_video_path):
		_fail(_decoder.get_last_error())
		_decoder = null
		return false
	if int(_decoder.get_width()) != int(video_info["videoW"]) or int(_decoder.get_height()) != int(video_info["videoH"]):
		_fail("Decoded video size does not match vapc")
		_decoder.close()
		_decoder = null
		return false

	_frame_time = 1.0 / max(1.0, float(video_info["fps"]))
	_configure_audio()
	_configure_compositor()
	if not _decoder.decode_next_frame():
		_fail(_decoder.get_last_error())
		return false
	_update_video_texture()
	current_frame = 0
	_video_loaded = true
	fusion_manager.bind_video_texture()
	fusion_manager.present_frame(0)
	_layout_content()
	emit_signal("animation_ready", vap_config)
	if autoplay:
		play()
	return true


func _materialize_video(video_path):
	var file = File.new()
	var absolute_path = ProjectSettings.globalize_path(video_path)
	if file.file_exists(absolute_path):
		return absolute_path

	# Imported assets live inside the PCK after export. The native decoder cannot
	# read that virtual path, so restore the bytes to a stable user:// cache file.
	var imported_resource = load(video_path)
	if imported_resource == null:
		_fail("VAP video does not exist: " + str(video_path))
		return ""
	var data = imported_resource.get("data")
	if typeof(data) != TYPE_RAW_ARRAY or data.empty():
		_fail("VAP video import does not contain MP4 data: " + str(video_path))
		return ""

	var source_md5 = str(imported_resource.get("source_md5"))
	if source_md5.empty():
		source_md5 = str(video_path).md5_text() + "_" + str(data.size())
	var cache_dir = "user://vap_cache"
	var directory = Directory.new()
	var error = directory.make_dir_recursive(cache_dir)
	if error != OK and error != ERR_ALREADY_EXISTS:
		_fail("Cannot create VAP video cache: " + cache_dir)
		return ""

	var cache_path = cache_dir.plus_file(source_md5 + ".mp4")
	if file.file_exists(cache_path):
		error = file.open(cache_path, File.READ)
		if error == OK:
			var cached_size = file.get_len()
			file.close()
			if cached_size == data.size():
				return ProjectSettings.globalize_path(cache_path)

	error = file.open(cache_path, File.WRITE)
	if error != OK:
		_fail("Cannot write VAP video cache: " + cache_path)
		return ""
	file.store_buffer(data)
	file.close()
	return ProjectSettings.globalize_path(cache_path)


func extract_vapc_from_mp4(video_path):
	var file = File.new()
	if file.open(video_path, File.READ) != OK:
		_fail("Cannot open VAP video: " + video_path)
		return {}
	file.endian_swap = true
	var file_size = file.get_len()
	while file.get_position() + 8 <= file_size:
		var box_start = file.get_position()
		var box_size = int(file.get_32())
		var box_type = file.get_buffer(4).get_string_from_ascii()
		var header_size = 8
		if box_size == 1:
			if file.get_position() + 8 > file_size:
				break
			box_size = int(file.get_64())
			header_size = 16
		elif box_size == 0:
			box_size = file_size - box_start
		if box_size < header_size or box_start + box_size > file_size:
			file.close()
			_fail("Invalid MP4 box while searching for vapc")
			return {}
		if box_type == "vapc":
			var text = file.get_buffer(box_size - header_size).get_string_from_utf8().strip_edges()
			file.close()
			return _parse_json(text, "embedded vapc box")
		file.seek(box_start + box_size)
	file.close()
	_fail("MP4 does not contain a vapc box")
	return {}


func play():
	if not _video_loaded or _decoder == null:
		_fail("No VAP video has been loaded")
		return
	if is_playing:
		return
	is_playing = true
	set_process(true)
	if _audio_player.stream != null:
		if _audio_player.playing:
			_audio_player.stream_paused = false
		else:
			_restart_audio_at(float(current_frame) / max(1.0, float(video_info["fps"])))
	emit_signal("animation_started")


func stop():
	is_playing = false
	set_process(false)
	_time_accumulator = 0.0
	if _audio_player != null:
		_audio_player.stop()
		_audio_player.stream = null
	_audio_playback = null
	if _decoder != null:
		_decoder.close()
		_decoder = null
	_video_loaded = false


func pause():
	is_playing = false
	set_process(false)
	if _audio_player != null:
		_audio_player.stream_paused = true


func resume():
	play()


func seek_to_frame(frame):
	if not _video_loaded or _decoder == null:
		return
	frame = max(0, int(frame))
	if not _decoder.seek_start():
		_fail(_decoder.get_last_error())
		return
	for index in range(frame + 1):
		if not _decoder.decode_next_frame():
			_fail("Cannot seek to VAP frame " + str(frame))
			return
	current_frame = frame
	_update_video_texture()
	fusion_manager.present_frame(frame)
	emit_signal("frame_changed", frame)
	if _audio_player.stream != null:
		_restart_audio_at(float(frame) / max(1.0, float(video_info["fps"])))


func get_playback_info():
	return {
		"is_playing": is_playing,
		"is_ready": _video_loaded,
		"current_frame": current_frame,
		"total_frames": int(video_info.get("f", 0)),
		"fps": int(video_info.get("fps", 0)),
		"content_size": Vector2(int(video_info.get("w", 0)), int(video_info.get("h", 0))),
		"video_size": Vector2(int(video_info.get("videoW", 0)), int(video_info.get("videoH", 0))),
		"is_fusion": int(video_info.get("isVapx", 0)) == 1,
		"fusion_resources": fusion_manager.loaded_textures.size() if fusion_manager != null else 0,
		"audio_enabled": enable_audio,
		"has_audio": _decoder != null and _decoder.has_audio(),
	}


func set_fusion_resource(resource_id, resource_data):
	if fusion_manager == null:
		_fail("Fusion manager is not ready")
		return false
	return fusion_manager.set_resource(str(resource_id), resource_data)


func get_fusion_source_config(resource_id):
	return fusion_manager.get_source_config(str(resource_id)) if fusion_manager != null else {}


func add_fusion_follower(resource_id, node, follow_size = false, offset = Vector2.ZERO, z_offset = 1):
	if fusion_manager == null:
		_fail("Fusion manager is not ready")
		return false
	return fusion_manager.add_follower(str(resource_id), node, follow_size, offset, z_offset)


func remove_fusion_follower(resource_id, node):
	if fusion_manager == null:
		return false
	return fusion_manager.remove_follower(str(resource_id), node)


func get_video_texture():
	return _video_texture


func get_content_display_rect():
	var content_size = Vector2(float(video_info.get("w", 1)), float(video_info.get("h", 1)))
	var scale = min(rect_size.x / content_size.x, rect_size.y / content_size.y)
	var display_size = content_size * scale
	return Rect2((rect_size - display_size) * 0.5, display_size)


func _process(delta):
	if not is_playing or _decoder == null:
		return
	_fill_audio_buffer()
	_time_accumulator += delta
	var decoded = 0
	while _time_accumulator >= _frame_time and decoded < 3:
		_time_accumulator -= _frame_time
		if not _decoder.decode_next_frame():
			if loop and _decoder.seek_start() and _decoder.decode_next_frame():
				current_frame = 0
				if _audio_player.stream != null:
					_restart_audio_at(0.0)
			else:
				is_playing = false
				set_process(false)
				if _audio_player != null:
					_audio_player.stop()
				_audio_playback = null
				emit_signal("animation_finished")
				return
		else:
			current_frame += 1
		_update_video_texture()
		fusion_manager.present_frame(current_frame)
		emit_signal("frame_changed", current_frame)
		decoded += 1


func _configure_audio():
	_audio_player.stop()
	_audio_player.stream = null
	_audio_playback = null
	if not enable_audio or not _decoder.has_audio():
		return
	var stream = AudioStreamGenerator.new()
	stream.mix_rate = _decoder.get_audio_sample_rate()
	stream.buffer_length = 0.5
	_audio_player.stream = stream


func _fill_audio_buffer():
	if _audio_playback == null or _decoder == null or not _decoder.has_audio():
		return
	var available = _audio_playback.get_frames_available()
	if available <= 0:
		return
	var frames = _decoder.decode_audio_frames(min(available, 4096))
	if frames.size() > 0:
		_audio_playback.push_buffer(frames)


func _restart_audio_at(seconds):
	if _audio_player.stream == null or _decoder == null or not _decoder.has_audio():
		return
	_decoder.seek_audio(max(0.0, float(seconds)))
	_audio_player.stop()
	_audio_player.play()
	_audio_playback = _audio_player.get_stream_playback()
	_fill_audio_buffer()
	_audio_player.stream_paused = not is_playing


func _configure_compositor():
	var video_width = float(video_info["videoW"])
	var video_height = float(video_info["videoH"])
	var rgb = video_info["rgbFrame"]
	var alpha = video_info["aFrame"]
	_base_rect.material.set_shader_param("rgb_region", Color(float(rgb[0]) / video_width, float(rgb[1]) / video_height, float(rgb[2]) / video_width, float(rgb[3]) / video_height))
	_base_rect.material.set_shader_param("alpha_region", Color(float(alpha[0]) / video_width, float(alpha[1]) / video_height, float(alpha[2]) / video_width, float(alpha[3]) / video_height))


func _update_video_texture():
	var data = _decoder.get_frame_rgba()
	var image = Image.new()
	image.create_from_data(int(_decoder.get_width()), int(_decoder.get_height()), false, Image.FORMAT_RGBA8, data)
	_video_image = image
	if _video_texture == null:
		_video_texture = ImageTexture.new()
		_video_texture.create_from_image(image, 0)
		_base_rect.texture = _video_texture
	else:
		_video_texture.set_data(image)
		_base_rect.texture = _video_texture
	fusion_manager.bind_video_texture()


func _layout_content():
	if _base_rect == null:
		return
	var display = get_content_display_rect()
	_base_rect.rect_position = display.position
	_base_rect.rect_size = display.size
	if fusion_manager != null:
		fusion_manager.rect_position = Vector2.ZERO
		fusion_manager.rect_size = rect_size
		fusion_manager.present_frame(current_frame)


func _accept_config(config):
	if typeof(config) != TYPE_DICTIONARY or config.empty() or typeof(config.get("info", null)) != TYPE_DICTIONARY:
		_fail("VAP config is missing the info object")
		return false
	var info = config["info"]
	for key in ["v", "f", "w", "h", "fps", "videoW", "videoH", "aFrame", "rgbFrame", "isVapx"]:
		if not info.has(key):
			_fail("VAP config is missing info." + key)
			return false
	if int(info["v"]) != 2:
		_fail("Unsupported VAP version: " + str(info["v"]))
		return false
	if not int(info["isVapx"]) in [0, 1]:
		_fail("Invalid VAP isVapx value")
		return false
	var video_size = Vector2(int(info["videoW"]), int(info["videoH"]))
	if not _valid_region(info["rgbFrame"], video_size) or not _valid_region(info["aFrame"], video_size):
		_fail("VAP rgbFrame or aFrame is outside the video")
		return false
	vap_config = config
	video_info = info
	return true


func _valid_region(value, video_size):
	if typeof(value) != TYPE_ARRAY or value.size() != 4:
		return false
	return int(value[0]) >= 0 and int(value[1]) >= 0 and int(value[2]) > 0 and int(value[3]) > 0 and int(value[0]) + int(value[2]) <= video_size.x and int(value[1]) + int(value[3]) <= video_size.y


func _load_json_config(path):
	var file = File.new()
	if file.open(path, File.READ) != OK:
		_fail("Cannot open VAP config: " + path)
		return {}
	var text = file.get_as_text()
	file.close()
	return _parse_json(text, path)


func _parse_json(text, source):
	var result = JSON.parse(text)
	if result.error != OK:
		_fail("Invalid VAP JSON in %s at line %d: %s" % [source, result.error_line, result.error_string])
		return {}
	if typeof(result.result) != TYPE_DICTIONARY:
		_fail("VAP JSON root must be an object: " + source)
		return {}
	return result.result


func _on_fusion_resource_request(resource_id, resource_type, _config):
	emit_signal("fusion_resource_needed", resource_id, resource_type)


func _on_fusion_resource_ready(resource_id):
	emit_signal("fusion_resource_ready", resource_id)


func _fail(message):
	emit_signal("animation_error", message)
	push_error(message)
