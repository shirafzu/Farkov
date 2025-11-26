extends CanvasLayer

@export var world_path: NodePath

@onready var _world: Node3D = get_node_or_null(world_path)
@onready var _input: LineEdit = $MarginContainer/HBoxContainer/SeedInput
@onready var _apply_button: Button = $MarginContainer/HBoxContainer/ApplyButton

func _ready() -> void:
	_apply_button.pressed.connect(_on_apply_pressed)
	if _world and _world.has_method("generate"):
		_input.text = str(_world.get("seed"))

func _on_apply_pressed() -> void:
	if _world == null:
		return
	var text := _input.text.strip_edges()
	var seed_value: int
	if text.is_valid_int():
		seed_value = int(text)
	else:
		var rng := RandomNumberGenerator.new()
		seed_value = int(rng.randi())
		_input.text = str(seed_value)
	_world.set("seed", seed_value)
	if _world.has_method("generate"):
		_world.call("generate")
