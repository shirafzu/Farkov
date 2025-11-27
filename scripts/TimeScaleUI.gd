extends CanvasLayer

@export var world_path: NodePath

@onready var _world: Node3D = get_node_or_null(world_path)
@onready var _input: LineEdit = $MarginContainer/HBoxContainer/TimeScaleInput
@onready var _apply_button: Button = $MarginContainer/HBoxContainer/ApplyButton

func _ready() -> void:
	_apply_button.pressed.connect(_on_apply_pressed)
	if _world:
		_input.text = str(_world.get("time_scale"))

func _on_apply_pressed() -> void:
	if _world == null:
		return
	var text := _input.text.strip_edges()
	var scale_value: float
	if text.is_valid_float():
		scale_value = float(text)
	else:
		scale_value = 1.0
		_input.text = str(scale_value)
	_world.set("time_scale", scale_value)
