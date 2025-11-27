extends CanvasLayer

@export var world_path: NodePath

@onready var _world: Node3D = get_node_or_null(world_path)
@onready var _mode_button: OptionButton = $MarginContainer/VBoxContainer/HBoxContainer/ModeButton
@onready var _mode_label: Label = $MarginContainer/VBoxContainer/ModeLabel

const MODE_NAMES: Array[String] = [
	"Normal",
	"Insolation (R)",
	"Precipitation (G)",
	"Thermal Inertia (B)",
	"Terrain Mask (A)"
]

const MODE_DESCRIPTIONS: Array[String] = [
	"Original biome rendering",
	"Annual sun exposure (0=polar, 1=equator)",
	"Rainfall potential (Hadley Cell model)",
	"Temperature change rate (ocean=slow, land=fast)",
	"Terrain type (deep ocean/shallow/lowland/highland)"
]

func _ready() -> void:
	# Populate dropdown
	for i in range(MODE_NAMES.size()):
		_mode_button.add_item(MODE_NAMES[i], i)

	_mode_button.selected = 0
	_mode_button.item_selected.connect(_on_mode_selected)
	_update_mode_label(0)

func _on_mode_selected(index: int) -> void:
	if _world == null:
		print("ClimateDebugUI: World is null")
		return

	# Get the material from WorldGenerator
	var material: ShaderMaterial = _world.get("_material") as ShaderMaterial
	if material == null:
		print("ClimateDebugUI: Material is null")
		return

	# Set shader debug_mode parameter
	material.set_shader_parameter("debug_mode", index)
	print("ClimateDebugUI: Set debug_mode to ", index, " (", MODE_NAMES[index], ")")

	# Verify the climate_map texture is set
	var climate_tex = material.get_shader_parameter("climate_map")
	print("ClimateDebugUI: climate_map texture exists: ", climate_tex != null)

	_update_mode_label(index)

func _update_mode_label(index: int) -> void:
	if index >= 0 and index < MODE_DESCRIPTIONS.size():
		_mode_label.text = MODE_DESCRIPTIONS[index]
	else:
		_mode_label.text = ""
