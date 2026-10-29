extends Node
## Bounded two-process loopback lobby smoke; emits machine-readable evidence.

const TIMEOUT: float = 20.0
var _started: bool = false


func _ready() -> void:
	NetSession.seats_changed.connect(_seats_changed)
	NetSession.race_requested.connect(_race_requested)
	get_tree().create_timer(TIMEOUT).timeout.connect(func() -> void: get_tree().quit(2))
	var args: Dictionary = PlaytestArgs.parse(OS.get_cmdline_user_args())
	var port: int = int(args.get("port", 0))
	var profile: LobbyProfile = LobbyProfile.make("QA", &"vortex", 0, {}, 100.0)
	var error: Error = NetSession.host(port, profile)
	if error != OK:
		get_tree().quit(3)
	print("SMOKE_PORT=%d" % NetSession.bound_port())


func _seats_changed(seats: Array) -> void:
	if seats.size() != 2 or _started:
		return
	if not NetSession.local_seat().ready:
		NetSession.set_ready(true)
	for seat: LobbySeat in NetSession.seats():
		if not seat.ready:
			return
	_started = true
	NetSession.request_start(&"coast")


func _race_requested(_track: StringName, race_seed: int) -> void:
	print("SMOKE_SEED=%d" % race_seed)
	print("SMOKE_SEATS=%d" % NetSession.seats().size())
	await get_tree().create_timer(3.0).timeout
	get_tree().quit(0)
