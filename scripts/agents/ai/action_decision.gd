class_name ActionDecision
extends RefCounted

var selected_action: StringName = StringName()
var raw_scores: Dictionary = {}
var final_scores: Dictionary = {}
var reason: String = ""
var target_data: Dictionary = {}
var switched: bool = false
