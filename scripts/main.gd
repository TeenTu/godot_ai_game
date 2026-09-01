extends Node2D
## Minimal smoke-test scene for the Web export pipeline.
## Renders a title and a click counter button, so a successful
## GitHub Pages load proves the whole export worked end to end.

var _count: int = 0

@onready var _label: Label = $Title
@onready var _button: Button = $ClickButton


func _ready() -> void:
	_button.pressed.connect(_on_click_button_pressed)


func _on_click_button_pressed() -> void:
	_count += 1
	_label.text = "You clicked %d time(s). CI/CD works!" % _count
