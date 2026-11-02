extends Node3D
## Canal: dig through a continent until the two seas meet and a ship can sail across.

const N := 96                 # grid cells per side, 1 world unit each
const SEA := 0.0              # sea level held at the left and right edges
const BRUSH := 2.5            # dig radius in cells
const DIG_RATE := 6.0         # height units per second at brush centre
const MIN_H := -4.0
const MAX_H := 8.0
const G := 0.2                # virtual-pipe gravity * dt
const DAMP := 0.995           # flux damping, stops endless sloshing
const SHIP_DEPTH := 0.3       # water depth a ship needs
const SHIP_SPEED := 6.0

var h := PackedFloat32Array()     # terrain height
var h0 := PackedFloat32Array()    # original height (to tint dug sand)
var w := PackedFloat32Array()     # water depth
var rock := PackedFloat32Array()  # 1 = rock, digs 4x slower
var fl := PackedFloat32Array()    # outflow flux left/right/down/up
var fr := PackedFloat32Array()
var fd := PackedFloat32Array()
var fu := PackedFloat32Array()

var buf := PackedFloat32Array()
var img: Image
var tex: ImageTexture

var pivot: Node3D
var cam: Camera3D
var cursor: MeshInstance3D
var zoom := 1.0
var ship: Node3D
var ship_path: Array[Vector3] = []
var ship_i := 0
var check_t := 0.0
var sim_us := 0
var sim_steps := 0


func _ready() -> void:
	randomize()
	_build_scene()
	generate(randi())
	if "--autotest" in OS.get_cmdline_user_args():
		_autotest()


# ---------- world ----------

func generate(seed_: int) -> void:
	var n := FastNoiseLite.new()
	n.seed = seed_
	n.frequency = 0.035
	var rn := FastNoiseLite.new()
	rn.seed = seed_ + 7
	rn.frequency = 0.06
	# Packed arrays are value types: assign fresh ones instead of resizing in a loop
	h = _zeros(); w = _zeros(); rock = _zeros()
	fl = _zeros(); fr = _zeros(); fd = _zeros(); fu = _zeros()
	for j in N:
		for i in N:
			var c := j * N + i
			var land := smoothstep(6.0, 22.0, float(mini(i, N - 1 - i)))
			var r := 1.0 if rn.get_noise_2d(i, j) > 0.3 else 0.0
			h[c] = lerpf(-2.5, 2.2 + n.get_noise_2d(i, j) * 2.5 + r * 1.2, land)
			rock[c] = r * land
			w[c] = maxf(0.0, SEA - h[c])
	h0 = h.duplicate()
	if ship:
		ship.queue_free()
		ship = null


func _zeros() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(N * N)
	a.fill(0.0)
	return a


func _sea_edges() -> void:
	for j in N:
		for i in [0, N - 1]:
			var c: int = j * N + i
			w[c] = maxf(0.0, SEA - h[c])


func step_water() -> void:
	var t := Time.get_ticks_usec()
	# 1) update outflow fluxes from surface height differences
	for j in N:
		for i in N:
			var c := j * N + i
			var s := h[c] + w[c]
			var a := maxf(0.0, fl[c] * DAMP + G * (s - h[c - 1] - w[c - 1])) if i > 0 else 0.0
			var b := maxf(0.0, fr[c] * DAMP + G * (s - h[c + 1] - w[c + 1])) if i < N - 1 else 0.0
			var d := maxf(0.0, fd[c] * DAMP + G * (s - h[c - N] - w[c - N])) if j > 0 else 0.0
			var u := maxf(0.0, fu[c] * DAMP + G * (s - h[c + N] - w[c + N])) if j < N - 1 else 0.0
			var tot := a + b + d + u
			if tot > w[c] and tot > 0.0:   # never move more water than the cell holds
				var k := w[c] / tot
				a *= k; b *= k; d *= k; u *= k
			fl[c] = a; fr[c] = b; fd[c] = d; fu[c] = u
	# 2) apply net flow
	for j in N:
		for i in N:
			var c := j * N + i
			var inflow := 0.0
			if i > 0: inflow += fr[c - 1]
			if i < N - 1: inflow += fl[c + 1]
			if j > 0: inflow += fu[c - N]
			if j < N - 1: inflow += fd[c + N]
			w[c] = maxf(0.0, w[c] + inflow - fl[c] - fr[c] - fd[c] - fu[c])
	_sea_edges()
	sim_us += Time.get_ticks_usec() - t
	sim_steps += 1


func dig_at(p: Vector3, amount: float) -> void:
	var ci := p.x + N * 0.5 - 0.5
	var cj := p.z + N * 0.5 - 0.5
	var r := int(ceil(BRUSH))
	for j in range(maxi(0, int(cj) - r), mini(N, int(cj) + r + 2)):
		for i in range(maxi(0, int(ci) - r), mini(N, int(ci) + r + 2)):
			var dist := Vector2(i - ci, j - cj).length()
			if dist > BRUSH:
				continue
			var c := j * N + i
			var fall := 1.0 - dist / BRUSH
			var soft := 0.25 if rock[c] > 0.5 else 1.0
			h[c] = clampf(h[c] - amount * fall * soft, MIN_H, MAX_H)


func cell_pos(c: int) -> Vector3:
	var i := c % N
	var j := c / N
	return Vector3(i - N * 0.5 + 0.5, h[c] + w[c], j - N * 0.5 + 0.5)


## BFS through water deep enough for a ship, left edge to right edge.
func find_canal() -> Array[Vector3]:
	var prev := PackedInt32Array()
	prev.resize(N * N)
	prev.fill(-2)
	var q := PackedInt32Array()
	for j in N:
		var c := j * N
		if w[c] > SHIP_DEPTH:
			prev[c] = -1
			q.append(c)
	var head := 0
	while head < q.size():
		var c := q[head]
		head += 1
		var i := c % N
		if i == N - 1:
			var path: Array[Vector3] = []
			while c >= 0:
				path.push_front(cell_pos(c))
				c = prev[c]
			return path
		for nb in [c - 1 if i > 0 else -1, c + 1, c - N, c + N]:
			if nb >= 0 and nb < N * N and prev[nb] == -2 and w[nb] > SHIP_DEPTH:
				prev[nb] = c
				q.append(nb)
	return []


# ---------- frame ----------

func _physics_process(_dt: float) -> void:
	step_water()


func _process(dt: float) -> void:
	_camera_input(dt)
	var hit := _pick()
	cursor.visible = hit != Vector3.INF
	if cursor.visible:
		cursor.position = hit + Vector3(0, 0.15, 0)
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			dig_at(hit, DIG_RATE * dt)
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			dig_at(hit, -DIG_RATE * dt)
	_update_ship(dt)
	_upload()


func _upload() -> void:
	for c in N * N:
		buf[c * 4] = h[c]
		buf[c * 4 + 1] = w[c]
		buf[c * 4 + 2] = rock[c]
		buf[c * 4 + 3] = h0[c]
	img.set_data(N, N, false, Image.FORMAT_RGBAF, buf.to_byte_array())
	tex.update(img)


func _update_ship(dt: float) -> void:
	check_t -= dt
	if ship == null and check_t <= 0.0:
		check_t = 0.5
		ship_path = find_canal()
		if not ship_path.is_empty():
			ship = _make_ship()
			ship.position = ship_path[0]
			ship_i = 1
	if ship == null:
		return
	var c := _cell_at(ship.position)
	if ship_i >= ship_path.size() or w[c] < SHIP_DEPTH * 0.5:
		ship.queue_free()   # arrived, or stranded because the canal was filled in
		ship = null
		return
	var target := ship_path[ship_i]
	var flat := Vector3(target.x, ship.position.y, target.z)
	ship.position = ship.position.move_toward(flat, SHIP_SPEED * dt)
	ship.position.y = lerpf(ship.position.y, h[c] + w[c], 0.2)
	if ship.position.distance_to(flat) < 0.6:
		ship_i += 1
	if flat.distance_to(ship.position) > 0.01:
		var look := Basis.looking_at(flat - ship.position)
		ship.basis = ship.basis.slerp(look, 0.15)


func _cell_at(p: Vector3) -> int:
	var i := clampi(int(p.x + N * 0.5), 0, N - 1)
	var j := clampi(int(p.z + N * 0.5), 0, N - 1)
	return j * N + i


func _height_at(p: Vector3) -> float:
	return h[_cell_at(p)]


func _pick() -> Vector3:
	var mp := get_viewport().get_mouse_position()
	var o := cam.project_ray_origin(mp)
	var d := cam.project_ray_normal(mp)
	for s in 400:
		var p := o + d * (s * 0.5)
		if absf(p.x) < N * 0.5 and absf(p.z) < N * 0.5 and p.y <= _height_at(p):
			return p
	return Vector3.INF


func _camera_input(dt: float) -> void:
	var move := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_key_pressed(KEY_A): move.x -= 1
	if Input.is_key_pressed(KEY_D): move.x += 1
	if Input.is_key_pressed(KEY_W): move.y -= 1
	if Input.is_key_pressed(KEY_S): move.y += 1
	var rot := float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	pivot.rotate_y(rot * 1.5 * dt)
	var v := pivot.basis * Vector3(move.x, 0, move.y)
	pivot.position += v.limit_length(1.0) * 30.0 * zoom * dt
	pivot.position = pivot.position.clamp(Vector3(-N / 2, 0, -N / 2), Vector3(N / 2, 0, N / 2))
	cam.position = Vector3(0, 70, 50) * zoom
	cam.look_at(pivot.global_position)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP: zoom = maxf(0.25, zoom * 0.9)
		if e.button_index == MOUSE_BUTTON_WHEEL_DOWN: zoom = minf(1.4, zoom * 1.1)
	if e is InputEventKey and e.pressed and e.keycode == KEY_R:
		generate(randi())


# ---------- scene ----------

func _build_scene() -> void:
	buf.resize(N * N * 4)
	img = Image.create_empty(N, N, false, Image.FORMAT_RGBAF)
	tex = ImageTexture.create_from_image(img)

	var plane := PlaneMesh.new()
	plane.size = Vector2(N, N)
	plane.subdivide_width = N - 2
	plane.subdivide_depth = N - 2
	for spec in [["res://terrain.gdshader", 0], ["res://water.gdshader", 1]]:
		var m := ShaderMaterial.new()
		m.shader = load(spec[0])
		m.set_shader_parameter("field", tex)
		m.set_shader_parameter("size", float(N))
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = m
		mi.extra_cull_margin = 20.0   # vertices are displaced in the shader
		if spec[1] == 1:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 35, 0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.36, 0.42)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.74, 0.80)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.70, 0.84, 0.88)
	env.fog_density = 0.0012
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	pivot = Node3D.new()
	add_child(pivot)
	cam = Camera3D.new()
	cam.fov = 40.0
	pivot.add_child(cam)
	cam.position = Vector3(0, 70, 50)
	cam.look_at_from_position(cam.position, Vector3.ZERO)

	var ring := TorusMesh.new()
	ring.inner_radius = BRUSH - 0.2
	ring.outer_radius = BRUSH
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(1, 1, 1, 0.75)
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cursor = MeshInstance3D.new()
	cursor.mesh = ring
	cursor.material_override = rm
	cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cursor)

	var ui := CanvasLayer.new()
	add_child(ui)
	var title := Label.new()
	title.text = "CANAL"
	title.position = Vector2(24, 16)
	title.add_theme_font_size_override("font_size", 28)
	ui.add_child(title)
	var help := Label.new()
	help.text = "LMB dig · RMB pile · WASD pan · Q/E rotate · wheel zoom · R new continent"
	help.position = Vector2(24, 56)
	help.modulate = Color(1, 1, 1, 0.75)
	ui.add_child(help)


func _make_ship() -> Node3D:
	var root := Node3D.new()
	var model := Node3D.new()   # scale lives here so root's basis stays orthonormal for slerp
	model.scale = Vector3.ONE * 1.4
	root.add_child(model)
	var parts := [
		[BoxMesh.new(), Vector3(0.7, 0.35, 1.8), Vector3(0, 0.15, 0), Color(0.42, 0.29, 0.18)],
		[CylinderMesh.new(), Vector3(0.08, 1.6, 0.08), Vector3(0, 1.0, 0), Color(0.35, 0.25, 0.16)],
		[BoxMesh.new(), Vector3(0.05, 1.0, 0.8), Vector3(0, 1.1, 0.1), Color(0.96, 0.93, 0.85)],
	]
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p[0]
		mi.scale = p[1]
		mi.position = p[2]
		var m := StandardMaterial3D.new()
		m.albedo_color = p[3]
		mi.material_override = m
		model.add_child(mi)
	add_child(root)
	return root


# ---------- self test: `godot --path . -- --autotest` ----------

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % name)
	print("shot ", name)


func _autotest() -> void:
	generate(12345)
	for f in 30: await get_tree().process_frame
	await _shot("01_start")
	var row := N / 2
	var t0 := Time.get_ticks_msec()
	var frames := 0
	for x in range(0, N, 2):
		var p := Vector3(x - N * 0.5 + 0.5, 0, row - N * 0.5 + 0.5)
		while h[row * N + x] > -1.2 or h[row * N + mini(x + 1, N - 1)] > -1.2:
			dig_at(p, 0.3)
			frames += 1
			if frames % 4 == 0:
				await get_tree().process_frame
		if x == N / 2:
			await _shot("02_half")
	print("dug in %.1fs" % ((Time.get_ticks_msec() - t0) / 1000.0))
	var t1 := Time.get_ticks_msec()
	while ship == null and Time.get_ticks_msec() - t1 < 20000:
		await get_tree().process_frame
	print("ship spawned: ", ship != null, " after %.1fs" % ((Time.get_ticks_msec() - t1) / 1000.0))
	for f in 120: await get_tree().process_frame
	await _shot("03_ship")
	zoom = 0.4
	if ship: pivot.position = Vector3(ship.position.x, 0, ship.position.z)
	for f in 10: await get_tree().process_frame
	await _shot("04_close")
	sim_us = 0; sim_steps = 0
	var ft := Time.get_ticks_msec()
	for f in 120: await get_tree().process_frame
	var fps := 120000.0 / (Time.get_ticks_msec() - ft)
	print("sim %.2f ms/step, fps %.0f" % [sim_us / 1000.0 / maxi(1, sim_steps), fps])
	get_tree().quit()
