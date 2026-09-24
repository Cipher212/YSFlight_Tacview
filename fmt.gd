# Small text helpers shared by the viewer's scripts.

const WEAPONS = {"AIM9": "AIM-9", "AIM9X": "AIM-9X", "AIM120": "AIM-120", "AGM65": "AGM-65",
	"GUN": "gun", "ROCKET": "rocket", "BOMB500": "bomb", "BOMB250": "bomb", "BOMB500HD": "bomb",
	"FUELTANK": "fuel tank", "FLARE": "flare"}

# 754.2 -> "12:34", 3725 -> "1:02:05"
@warning_ignore("integer_division")
static func clock(t: float) -> String:
	var s := int(maxf(t, 0.0))
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]

# "1:02:03", "12:34", "754" or "754.5" -> seconds; -1 if unreadable
static func parse_time(text: String) -> float:
	var parts := text.strip_edges().split(":")
	var t := 0.0
	for p in parts:
		if not p.strip_edges().is_valid_float():
			return -1.0
		t = t * 60.0 + p.to_float()
	return t

# "LIGHTNING(BLUE/BVR)" -> "LIGHTNING"
static func short_type(t: String) -> String:
	return t.split("(")[0]

# 12345 -> "12,345"
static func thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out

static func weapon(name: String) -> String:
	return WEAPONS.get(name, name)
