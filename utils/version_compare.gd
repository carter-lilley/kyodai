# version_compare.gd
extends RefCounted
class_name VersionCompare

## Semantic-version comparison (semver.org §11), tolerant of a leading "v"
## and shortened cores ("0.6" == "0.6.0"). Used by the self-update check to
## decide whether a GitHub release tag is newer than the running build.

## Returns 1 when a > b, -1 when a < b, 0 when equal.
static func compare(a: String, b: String) -> int:
	var pa := _parse(a)
	var pb := _parse(b)
	for i in range(3):
		if pa["core"][i] != pb["core"][i]:
			return 1 if pa["core"][i] > pb["core"][i] else -1
	return _compare_prerelease(pa["pre"], pb["pre"])

## True when remote is a strictly newer version than current. Never offers
## downgrades: switching from Experimental to Stable while on a beta build
## simply goes quiet until a newer stable exists.
static func is_newer(remote: String, current: String) -> bool:
	return compare(remote, current) > 0

static func _parse(v: String) -> Dictionary:
	v = v.strip_edges()
	if v.begins_with("v") or v.begins_with("V"):
		v = v.substr(1)
	# Build metadata ("+build") carries no precedence information.
	var plus := v.find("+")
	if plus != -1:
		v = v.substr(0, plus)
	var pre := ""
	var dash := v.find("-")
	if dash != -1:
		pre = v.substr(dash + 1)
		v = v.substr(0, dash)
	var core: Array[int] = [0, 0, 0]
	var parts := v.split(".")
	for i in range(mini(parts.size(), 3)):
		core[i] = parts[i].to_int() if parts[i].is_valid_int() else 0
	return {"core": core, "pre": pre}

static func _compare_prerelease(a: String, b: String) -> int:
	# A release outranks any of its own prereleases (1.0.0 > 1.0.0-beta.2).
	if a == "" and b == "":
		return 0
	if a == "":
		return 1
	if b == "":
		return -1
	var ids_a := a.split(".")
	var ids_b := b.split(".")
	for i in range(maxi(ids_a.size(), ids_b.size())):
		# A shorter identifier set loses when all shared identifiers are equal.
		if i >= ids_a.size():
			return -1
		if i >= ids_b.size():
			return 1
		var ia := ids_a[i]
		var ib := ids_b[i]
		if ia == ib:
			continue
		var a_numeric := ia.is_valid_int()
		var b_numeric := ib.is_valid_int()
		if a_numeric and b_numeric:
			return 1 if ia.to_int() > ib.to_int() else -1
		# Numeric identifiers rank below alphanumeric ones.
		if a_numeric:
			return -1
		if b_numeric:
			return 1
		return 1 if ia > ib else -1
	return 0
