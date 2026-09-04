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

func _ready():
	download._update_concurrency_from_settings()
