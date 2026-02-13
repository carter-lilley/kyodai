import json

# Read the platforms JSON
with open('/mnt/c/Users/carter/Desktop/platforms.json', 'r') as f:
    platforms = json.load(f)

# Sort by name for easier reading
platforms.sort(key=lambda x: x['name'])

# Print all slugs
print("Platform Slugs ({} total):\n".format(len(platforms)))
for p in platforms:
    print("  - {} ({} games)".format(p['slug'], p['rom_count']))
