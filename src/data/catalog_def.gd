class_name CatalogDef
extends Resource
## The content index. New content = append the .tres here; no code changes.

@export var cars: Array[CarDef] = []
@export var parts: Array[PartDef] = []
@export var tracks: Array[TrackDef] = []
