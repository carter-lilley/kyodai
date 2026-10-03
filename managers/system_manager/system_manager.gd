extends Manager

@onready var filesystem: FileSystemSubManager = $FileSystemSubManager
@onready var network: NetworkSubManager = $NetworkSubManager
@onready var download: DownloadSubManager = $DownloadSubManager
@onready var notifications: NotificationSubManager = $NotificationSubManager
@onready var memory: MemorySubManager = $MemorySubManager
@onready var display: DisplaySubManager = $DisplaySubManager
@onready var audio: AudioSubManager = $AudioSubManager
@onready var platform: PlatformSubManager = $PlatformSubManager
@onready var config: ConfigSubManager = $ConfigSubManager
@onready var resolution: ResolutionSubManager = $ResolutionSubManager

func _ready():
	download._update_concurrency_from_settings()
	# Compile all shader pipelines during the remaining startup window — before
	# the first visible frame — so first paint/focus/scroll never pay lazy
	# pipeline-compile hitches. Paced per frame by WarmupBudget gates inside
	# the prewarmer; Main keeps a later fallback kick (prewarm is idempotent).
	call_deferred("_kick_shader_prewarm")

func _kick_shader_prewarm() -> void:
	# Let the autoload chain finish constructing before touching the viewport.
	await get_tree().process_frame
	await get_tree().process_frame
	ShaderPrewarmer.prewarm(get_tree())
