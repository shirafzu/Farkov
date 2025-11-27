extends Camera3D

@export var target_path: NodePath
@export var distance: float = 90.0
@export var min_distance: float = 35.0
@export var max_distance: float = 140.0
@export_range(-89.0, 89.0, 1.0) var min_pitch_deg: float = -80.0
@export_range(-89.0, 89.0, 1.0) var max_pitch_deg: float = 80.0
@export var orbit_speed: float = 0.4
@export var zoom_speed: float = 0.08
@export var rotation_smooth: float = 10.0

var _yaw: float = 0.0
var _pitch: float = deg_to_rad(-45.0)
var _dragging: bool = false
var _drag_touch_id: int = -1
var _current_dir: Vector3 = Vector3(0, 0, 1)
var _target_dir: Vector3 = Vector3(0, 0, 1)

# Pinch zoom tracking
var _touch_points: Dictionary = {}  # touch_id -> position
var _pinch_start_distance: float = 0.0
var _pinch_start_zoom: float = 0.0

@onready var _target: Node3D = get_node_or_null(target_path)

func _ready() -> void:
	_target_dir = _calc_dir()
	_current_dir = _target_dir
	_update_transform()
	set_process_unhandled_input(true)
	set_process(true)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(-1.0)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0)
	elif event is InputEventMouseMotion and _dragging:
		_orbit(event.relative)
	elif event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMagnifyGesture:
		_zoom((1.0 - event.factor) * 5.0)

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touch_points[event.index] = event.position
		if _touch_points.size() == 1:
			# Single finger - start drag
			_drag_touch_id = event.index
			_dragging = true
		elif _touch_points.size() == 2:
			# Two fingers - start pinch zoom
			_dragging = false
			_start_pinch_zoom()
	else:
		_touch_points.erase(event.index)
		if event.index == _drag_touch_id:
			_drag_touch_id = -1
			_dragging = false
		# If one finger remains after releasing, resume drag with that finger
		if _touch_points.size() == 1:
			_drag_touch_id = _touch_points.keys()[0]
			_dragging = true

func _handle_drag(event: InputEventScreenDrag) -> void:
	_touch_points[event.index] = event.position

	if _touch_points.size() == 2:
		# Pinch zoom active
		_update_pinch_zoom()
	elif _touch_points.size() == 1 and event.index == _drag_touch_id:
		# Single finger drag for orbit
		_orbit(event.relative)

func _start_pinch_zoom() -> void:
	var points: Array = _touch_points.values()
	_pinch_start_distance = points[0].distance_to(points[1])
	_pinch_start_zoom = distance

func _update_pinch_zoom() -> void:
	var points: Array = _touch_points.values()
	var current_distance: float = points[0].distance_to(points[1])

	if _pinch_start_distance > 0.0:
		var zoom_ratio: float = _pinch_start_distance / current_distance
		distance = clamp(_pinch_start_zoom * zoom_ratio, min_distance, max_distance)
		_update_transform()

func _orbit(relative: Vector2) -> void:
	_yaw -= relative.x * orbit_speed * 0.01
	_pitch = clamp(_pitch - relative.y * orbit_speed * 0.01, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	_target_dir = _calc_dir()

func _zoom(delta: float) -> void:
	distance = clamp(distance + delta * distance * zoom_speed, min_distance, max_distance)
	_update_transform()

func _process(delta: float) -> void:
	var t: float = clamp(delta * rotation_smooth, 0.0, 1.0)
	_current_dir = _current_dir.slerp(_target_dir, t).normalized()
	_update_transform()

func _update_transform() -> void:
	var focus := _target.global_transform.origin if _target else Vector3.ZERO
	var offset := _current_dir * distance
	global_transform.origin = focus + offset
	look_at(focus, Vector3.UP)

func _calc_dir() -> Vector3:
	var q_yaw: Quaternion = Quaternion(Vector3.UP, _yaw)
	var q_pitch: Quaternion = Quaternion(Vector3.RIGHT, _pitch)
	var q: Quaternion = q_yaw * q_pitch
	return (q * Vector3(0, 0, 1)).normalized()
