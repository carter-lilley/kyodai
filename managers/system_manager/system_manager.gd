extends Manager

const FileSystemSubManager := preload("res://managers/system_manager/filesystem_sub_manager.gd")
const NetworkSubManager := preload("res://managers/system_manager/network_sub_manager.gd")
const DownloadSubManager := preload("res://managers/system_manager/download_sub_manager.gd")
const NotificationSubManager := preload("res://managers/system_manager/notification_sub_manager.gd")
const MemorySubManager := preload("res://managers/system_manager/memory_sub_manager.gd")
const DisplaySubManager := preload("res://managers/system_manager/display_sub_manager.gd")
const AudioSubManager := preload("res://managers/system_manager/audio_sub_manager.gd")
const PlatformSubManager := preload("res://managers/system_manager/platform_sub_manager.gd")

@onready var filesystem: FileSystemSubManager = $FileSystemSubManager
@onready var network: NetworkSubManager = $NetworkSubManager
@onready var download: DownloadSubManager = $DownloadSubManager
@onready var notifications: NotificationSubManager = $NotificationSubManager
@onready var memory: MemorySubManager = $MemorySubManager
@onready var display: DisplaySubManager = $DisplaySubManager
@onready var audio: AudioSubManager = $AudioSubManager
@onready var platform: PlatformSubManager = $PlatformSubManager

func _ready():
	download._update_concurrency_from_settings()
