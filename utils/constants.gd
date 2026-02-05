class_name Constants
extends RefCounted

# API Configuration
const API_VERSION = "v1"
const DEFAULT_PAGE_SIZE = 100

# Cache Configuration
const MAX_IMAGE_CACHE_MB = 500
const MAX_IMAGE_CACHE_BYTES = MAX_IMAGE_CACHE_MB * 1024 * 1024

# Download Configuration
const MAX_CONCURRENT_DOWNLOADS = 3

# UI Configuration
const GAME_CARD_SIZE = Vector2(200, 280)
const GRID_COLUMNS_DEFAULT = 5

# Database Configuration
const DB_PATH = "user://database/kyodai.db"

# File Paths
const CACHE_FOLDER = "user://cache/covers/"

# Keyring Keys
const KEYRING_PASSWORD_KEY = "kyodai_romm_password"
