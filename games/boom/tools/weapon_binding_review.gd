extends SceneTree
## 武器绑定验收工具（三种模式，可组合）：
##   1. 默认        headless 数据一致性检查：HANDS/GRIPS 帧数对齐、STOWED 收起、
##                  纹理边界、锚点 Alpha。失败累计后以退出码 1 结束。
##   2. --capture-dir=<绝对目录>
##                  真实渲染器逐动作横向帧排截图（不能 headless）。
##   3. --sheet-dir=<绝对目录>
##                  headless 图像空间标定图：按真实 resolve() 偏移合成身体+武器，
##                  2x 最近邻放大、32px 网格、掌心红叉/握柄青叉；另出纯身体/纯武器图。
## 用法示例：
##   godot --headless --path games/boom --script res://tools/weapon_binding_review.gd
##   godot --path games/boom --resolution 1536x512 --audio-driver Dummy \
##     --script res://tools/weapon_binding_review.gd -- --capture-dir=E:/abs/dir

const WeaponBinding := preload("res://scripts/core/boom_weapon_binding.gd")
## 标定图放大倍数与网格步长（身体画布像素）。
const SHEET_ZOOM: int = 2
const SHEET_GRID: int = 32
const MARKER_LEN: int = 14
const COL_HAND := Color(1.0, 0.15, 0.15)
const COL_GRIP := Color(0.15, 0.9, 1.0)
const COL_GRID := Color(1.0, 1.0, 1.0, 0.14)
const COL_GRID_CENTER := Color(1.0, 1.0, 0.4, 0.38)

## 验收覆盖全部注册配置（含 test_pennant，证明第三武器可配置接入）。
var visual_ids: Array = WeaponBinding.CONFIGS.keys()
var _failures: int = 0
var _checked: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _fail(msg: String) -> void:
	_failures += 1
	printerr("BINDING_FAIL: ", msg)


func _run() -> void:
	var capture_dir := ""
	var sheet_dir := ""
	var contact_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
		elif arg.begins_with("--sheet-dir="):
			sheet_dir = arg.trim_prefix("--sheet-dir=")
		elif arg.begins_with("--contact-dir="):
			contact_dir = arg.trim_prefix("--contact-dir=")
	root.content_scale_size = Vector2i(1536, 512)
	root.size = Vector2i(1536, 512)
	_check_data()
	if not sheet_dir.is_empty():
		_make_sheets(sheet_dir)
	if not contact_dir.is_empty():
		_make_contacts(contact_dir)
	if not capture_dir.is_empty():
		await _capture_strips(capture_dir)
	var verdict := "PASS" if _failures == 0 else "FAIL"
	print("WEAPON_BINDING_REVIEW result=", verdict, " checks=", _checked, " failures=", _failures)
	quit(0 if _failures == 0 else 1)


## ---------- 模式 1：headless 数据一致性 ----------


func _weapon_pixel(vid: String) -> float:
	return WeaponBinding.config(vid).get("weapon_pixel", 0.006)


func _check_data() -> void:
	for vid in visual_ids:
		var wp: float = _weapon_pixel(vid)
		var form: String = WeaponBinding.config(vid).get("form", "bubble")
		for action in BoomPlayer.FORM_STRIPS[form]:
			var count: int = BoomPlayer.FORM_STRIPS[form][action][1]
			var hands: Array = WeaponBinding.HANDS.get(action, [])
			if action not in WeaponBinding.STOWED and hands.size() != count:
				_fail(
					"%s/%s: HANDS frames=%d but body strip=%d" % [form, action, hands.size(), count]
				)
			var stowed: bool = action in WeaponBinding.STOWED
			for frame in count:
				_checked += 1
				var binding: Dictionary = WeaponBinding.resolve(
					vid, action, frame, WeaponBinding.BODY_PIXEL, wp
				)
				if stowed:
					if binding.get("visible", true):
						_fail("%s/%s/%d: stowed action must hide weapon" % [form, action, frame])
					continue
				if not binding.get("visible", false):
					continue
				_check_strip_frame(vid, form, action, frame, binding)


func _check_strip_frame(
	vid: String, form: String, action: String, frame: int, binding: Dictionary
) -> void:
	if not binding.get("visible", false):
		# 缺失动作且策略为 stow：预期隐藏，属于合法配置行为。
		return
	var strips: Dictionary = WeaponBinding.config(vid).get("strips", {})
	var wspec: Array = strips.get(binding["action"], [null, -1])
	var wcount: int = int(wspec[1])
	if wcount <= 0 or binding["frame"] >= wcount:
		_fail(
			(
				"%s/%s/%d: weapon strip %s has %d frames"
				% [form, action, frame, binding["action"], wcount]
			)
		)
		return
	var body_path: String = (
		BoomPlayer.STRIP_DIR + (BoomPlayer.FORM_STRIPS[form][action][0] as String) + ".png"
	)
	var weapon_path: String = (
		WeaponBinding.config(vid).get("weapon_dir", "") + (wspec[0] as String) + ".png"
	)
	var body_img := _load_or_fail(body_path, "%s body strip" % form)
	var weapon_img := _load_or_fail(weapon_path, "%s weapon strip" % form)
	if body_img == null or weapon_img == null:
		return
	var hand: Vector2 = WeaponBinding.HANDS[action][frame]
	if hand.x < 0.0 or hand.x >= 256.0 or hand.y < 0.0 or hand.y >= 256.0:
		_fail("%s/%s/%d: hand %s outside 256 canvas" % [form, action, frame, hand])
	elif body_img.get_pixel(int(hand.x) + frame * 256, int(hand.y)).a < 0.5:
		_fail("%s/%s/%d: hand anchor on transparent pixel %s" % [form, action, frame, hand])
	var grips: Dictionary = WeaponBinding.GRIPS[WeaponBinding.config(vid)["grips"]]
	var grip: Vector2 = grips[binding["action"]][frame]
	# Alpha 校验用原始 grip 测原始武器图（flip 后 alpha 逐像素对称；镜像只影响显示）。
	if grip.x < 0.0 or grip.x >= 256.0 or grip.y < 0.0 or grip.y >= 256.0:
		_fail("%s/%s/%d: grip %s outside 256 canvas" % [form, action, frame, grip])
	elif weapon_img.get_pixel(int(grip.x) + frame * 256, int(grip.y)).a < 0.5:
		printerr(
			(
				"GRIPDEBUG path=%s px=(%d,%d) a=%.3f fmt=%s"
				% [
					weapon_path,
					int(grip.x) + frame * 256,
					int(grip.y),
					weapon_img.get_pixel(int(grip.x) + frame * 256, int(grip.y)).a,
					weapon_img.get_format()
				]
			)
		)
		_fail("%s/%s/%d: grip anchor on transparent pixel %s" % [form, action, frame, grip])
	# GRIPS 帧数必须与武器条一致（禁止静默截断）。
	var declared: Array = WeaponBinding.GRIPS[WeaponBinding.config(vid)["grips"]][binding["action"]]
	if declared.size() != wcount:
		_fail(
			(
				"%s grip '%s': GRIPS frames=%d but strip=%d"
				% [form, binding["action"], declared.size(), wcount]
			)
		)


func _load_or_fail(path: String, label: String) -> Image:
	if not ResourceLoader.exists(path):
		_fail("%s: missing texture %s" % [label, path])
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		_fail("%s: cannot decode %s" % [label, path])
	return img


## ---------- 模式 3：headless 标定图 ----------


func _make_sheets(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for vid in visual_ids:
		var wp: float = _weapon_pixel(vid)
		var form: String = WeaponBinding.config(vid).get("form", "bubble")
		for action in BoomPlayer.FORM_STRIPS[form]:
			var count: int = BoomPlayer.FORM_STRIPS[form][action][1]
			for frame in count:
				_sheet_frame(dir, vid, form, action, frame, wp)
	print("SHEETS written to ", dir)


func _sheet_frame(
	dir: String, vid: String, form: String, action: String, frame: int, wp: float
) -> void:
	var binding: Dictionary = WeaponBinding.resolve(
		vid, action, frame, WeaponBinding.BODY_PIXEL, wp
	)
	var tag := "%s__%s__f%d" % [form, action, frame]
	if action in WeaponBinding.STOWED or not binding.get("visible", false):
		return
	var body_img := _crop_frame(
		BoomPlayer.STRIP_DIR + (BoomPlayer.FORM_STRIPS[form][action][0] as String) + ".png", frame
	)
	var wspec: Array = WeaponBinding.config(vid)["strips"][binding["action"]]
	var weapon_img := _crop_frame(
		WeaponBinding.config(vid)["weapon_dir"] + (wspec[0] as String) + ".png", frame
	)
	if body_img == null or weapon_img == null:
		return
	# 纯身体图（掌心红叉）。
	var hand := Vector2(WeaponBinding.HANDS[action][frame])
	_sheet_save(body_img.duplicate(), hand, COL_HAND, dir, tag + "__body.png")
	# 纯武器图（握柄青叉；镜像动作翻转武器并镜像 grip 标记）。
	var grips: Dictionary = WeaponBinding.GRIPS[WeaponBinding.config(vid)["grips"]]
	var grip := Vector2(grips[binding["action"]][frame])
	var grip_draw := Vector2(grip)
	if binding["flip_h"]:
		grip_draw.x = 256.0 - grip.x
		weapon_img = weapon_img.duplicate()
		weapon_img.flip_x()
	_sheet_save(weapon_img, grip_draw, COL_GRIP, dir, tag + "__weapon.png")
	# 合成图：武器缩放 wp/bp 后按 resolve 偏移贴到身体画布。
	var scale_f: float = wp / WeaponBinding.BODY_PIXEL
	var scaled := weapon_img.duplicate()
	scaled.resize(
		int(round(256.0 * scale_f)), int(round(256.0 * scale_f)), Image.INTERPOLATE_BILINEAR
	)
	var off := Vector2(binding["offset"]) * scale_f
	var origin := Vector2(128.0, 128.0) + off - Vector2(128.0, 128.0) * scale_f
	var combo := body_img.duplicate()
	combo.blend_rect(
		scaled, Rect2i(0, 0, scaled.get_width(), scaled.get_height()), Vector2i(origin)
	)
	# 合成图标记：红叉=掌心（身体画布坐标），青叉=握柄投影到合成画布。
	var grip_canvas: Vector2 = origin + Vector2(grip) * scale_f
	_sheet_save_two(combo, hand, grip_canvas, dir, tag + "__combo.png")


func _crop_frame(strip_path: String, frame: int) -> Image:
	var img := _load_or_fail(strip_path, "sheet")
	if img == null:
		return null
	var x := frame * 256
	if x + 256 > img.get_width():
		_fail("strip too short: %s frame %d" % [strip_path, frame])
		return null
	return img.get_region(Rect2i(x, 0, 256, 256))


## ---------- 模式 4：动作接触表（headless，一图看全帧） ----------


## 每动作一张：上排=身体帧+红叉掌心，下排=武器帧+青叉握柄（镜像动作画翻转帧）。
## 帧号以左上角短横条计数标注（自左向右 0..n-1）。
func _make_contacts(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for vid in visual_ids:
		var wp: float = _weapon_pixel(vid)
		var form: String = WeaponBinding.config(vid).get("form", "bubble")
		for action in BoomPlayer.FORM_STRIPS[form]:
			if action in WeaponBinding.STOWED:
				continue
			_contact_action(dir, vid, form, action, wp)
	print("CONTACTS written to ", dir)


func _contact_action(dir: String, vid: String, form: String, action: String, wp: float) -> void:
	var count: int = BoomPlayer.FORM_STRIPS[form][action][1]
	var binding := WeaponBinding.resolve(vid, action, 0, WeaponBinding.BODY_PIXEL, wp)
	if not binding.get("visible", false):
		return
	var wspec: Array = WeaponBinding.config(vid)["strips"][binding["action"]]
	if int(wspec[1]) <= 0:
		return
	var body_img := _load_or_fail(
		BoomPlayer.STRIP_DIR + (BoomPlayer.FORM_STRIPS[form][action][0] as String) + ".png",
		"contact"
	)
	var weapon_img := _load_or_fail(
		WeaponBinding.config(vid)["weapon_dir"] + (wspec[0] as String) + ".png", "contact"
	)
	if body_img == null or weapon_img == null:
		return
	var cols := mini(count, 3)
	var rows := int(ceil(count / 3.0))
	var cell := 512
	var sheet := Image.create(cols * cell, rows * 2 * cell, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.05, 0.06, 0.10))
	for frame in count:
		var cx := (frame % cols) * cell
		var cy := int(frame / float(cols)) * 2 * cell
		var body_frame := body_img.get_region(Rect2i(frame * 256, 0, 256, 256))
		_draw_grid_on(body_frame)
		var hand := Vector2(WeaponBinding.HANDS[action][frame])
		_draw_cross(body_frame, hand, COL_HAND)
		_frame_ticker(body_frame, frame)
		blit_zoomed(sheet, body_frame, cx, cy)
		var weapon_frame := weapon_img.get_region(Rect2i(frame * 256, 0, 256, 256))
		var grips: Dictionary = WeaponBinding.GRIPS[WeaponBinding.config(vid)["grips"]]
		var grip := Vector2(grips[binding["action"]][frame])
		if action.ends_with("_left"):
			weapon_frame.flip_x()
			grip.x = 256.0 - grip.x
		_draw_grid_on(weapon_frame)
		_draw_cross(weapon_frame, grip, COL_GRIP)
		_frame_ticker(weapon_frame, frame)
		blit_zoomed(sheet, weapon_frame, cx, cy + cell)
	sheet.save_png(dir.path_join("%s__%s.png" % [form, action]))


func blit_zoomed(sheet: Image, frame: Image, ox: int, oy: int) -> void:
	frame.resize(512, 512, Image.INTERPOLATE_NEAREST)
	sheet.blend_rect(frame, Rect2i(0, 0, 512, 512), Vector2i(ox, oy))


## 帧号刻度：左上角画 frame+1 个 24px 白条，防止与网格混淆。
func _frame_ticker(img: Image, frame: int) -> void:
	for i in frame + 1:
		for x in range(6, 30):
			for y in range(6 + i * 30, 26 + i * 30):
				img.set_pixel(x, y, Color(1, 1, 1, 0.9))


func _draw_grid_on(img: Image) -> void:
	_draw_grid(img)


func _sheet_save(img: Image, marker: Vector2, col: Color, dir: String, fname: String) -> void:
	_draw_grid(img)
	_draw_cross(img, marker, col)
	img.resize(256 * SHEET_ZOOM, 256 * SHEET_ZOOM, Image.INTERPOLATE_NEAREST)
	img.save_png(dir.path_join(fname))


func _sheet_save_two(img: Image, m1: Vector2, m2: Vector2, dir: String, fname: String) -> void:
	_draw_grid(img)
	_draw_cross(img, m1, COL_HAND)
	_draw_cross(img, m2, COL_GRIP)
	img.resize(256 * SHEET_ZOOM, 256 * SHEET_ZOOM, Image.INTERPOLATE_NEAREST)
	img.save_png(dir.path_join(fname))


func _draw_grid(img: Image) -> void:
	for p in range(0, 256, SHEET_GRID):
		var col := COL_GRID_CENTER if p == 128 else COL_GRID
		for t in 256:
			img.set_pixel(p, t, img.get_pixel(p, t).lerp(col, 0.85))
			img.set_pixel(t, p, img.get_pixel(t, p).lerp(col, 0.85))


func _draw_cross(img: Image, at: Vector2, col: Color) -> void:
	var c := Vector2i(at)
	for d in range(-MARKER_LEN, MARKER_LEN + 1):
		for thick in 2:
			var hx := c.x + d
			var hy := c.y + thick
			if hx >= 0 and hx < 256 and hy >= 0 and hy < 256:
				img.set_pixel(hx, hy, col)
			var vx := c.x + thick
			var vy := c.y + d
			if vx >= 0 and vx < 256 and vy >= 0 and vy < 256:
				img.set_pixel(vx, vy, col)


## ---------- 模式 2：真实渲染帧排（需非 headless） ----------


func _capture_strips(output: String) -> void:
	if DisplayServer.get_name() == "headless":
		_fail("capture mode needs an actual renderer")
		return
	DirAccess.make_dir_recursive_absolute(output)
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 14.0
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.position = Vector3(5.5, 1.0, 10.0)
	world.add_child(camera)
	camera.current = true
	for vid in visual_ids:
		var form: String = WeaponBinding.config(vid).get("form", "bubble")
		var combat_id: String = WeaponBinding.config(vid)["combat_ids"][0]
		for action in BoomPlayer.FORM_STRIPS[form]:
			var count: int = BoomPlayer.FORM_STRIPS[form][action][1]
			var actors: Array[BoomPlayer] = []
			for frame in count:
				var player := BoomPlayer.new()
				world.add_child(player)
				var known := false
				for w in BoomWeapons.all():
					known = known or w.id == combat_id
				if known:
					player.apply_weapon(BoomWeapons.get_def(combat_id))
				else:
					# 测试配置借用同形态 def + 显式视觉覆盖。
					player.apply_weapon(
						BoomWeapons.get_def("bubble" if form == "bubble" else "greatsword"), vid
					)
				await process_frame
				player.position.x = frame * 2.2
				player.play_anim_once(action)
				var body: AnimatedSprite3D = player._anim
				body.pause()
				body.set_frame_and_progress(frame, 0.0)
				player.physics_update(0.0, 30.0, 30.0)
				var weapon: AnimatedSprite3D = player._weapon_anim
				var expect_visible: bool = (
					action not in WeaponBinding.STOWED
					and (
						WeaponBinding
						. resolve(vid, action, 0, WeaponBinding.BODY_PIXEL, _weapon_pixel(vid))
						. get("visible", false)
					)
				)
				if expect_visible:
					if not weapon.visible:
						_fail("%s/%s/%d: runtime weapon hidden" % [form, action, frame])
					elif weapon.is_playing():
						_fail("%s/%s/%d: weapon runs independent clock" % [form, action, frame])
					elif weapon.frame != body.frame:
						_fail("%s/%s/%d: body/weapon frame mismatch" % [form, action, frame])
				var swing_fx: AnimatedSprite3D = player._weapon_fx_anim
				if action == "swing" and WeaponBinding.config(vid).has("effect_strip"):
					if swing_fx == null or not swing_fx.visible:
						_fail("%s/swing/%d: independent swing VFX hidden" % [form, frame])
					elif swing_fx.frame != body.frame:
						_fail("%s/swing/%d: body/VFX frame mismatch" % [form, frame])
				actors.append(player)
			await process_frame
			await RenderingServer.frame_post_draw
			var path := output.path_join(vid + "_" + action + ".png")
			if root.get_texture().get_image().save_png(path) != OK:
				_fail("capture failed: " + path)
			for player in actors:
				player.queue_free()
			await process_frame
	world.queue_free()
	await process_frame
