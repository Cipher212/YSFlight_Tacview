# YSFlight's own air tables (YSFLIGHT-master/src/dynamics/fsairproperty.cpp), so speeds shown
# here match what pilots saw on their HUD: density and speed of sound every 4,000 m,
# interpolated in between.

const RHO = [1.224991, 0.819122, 0.529999, 0.299988, 0.153000, 0.084991]
const MACH_ONE = [340.294, 324.579, 308.063, 295.069, 295.069, 295.069]
const MS_TO_KT = 1.0 / 0.514444
const M_TO_FT = 1.0 / 0.3048

# FsGetAirDensity: kg/m^3 at altitude alt (metres)
static func air_density(alt: float) -> float:
	var a := int(alt / 4000.0)
	if a > 8:
		return 0.0
	if a < 0:
		return RHO[0]
	if a > 4:
		return RHO[5]
	return lerpf(RHO[a], RHO[a + 1], (alt - 4000.0 * a) / 4000.0)

# FsGetMachOne: speed of sound (m/s) at altitude alt (metres)
static func mach_one(alt: float) -> float:
	var a := int(alt / 4000.0)
	if a < 0:
		return MACH_ONE[0]
	if a > 4:
		return MACH_ONE[4]
	return lerpf(MACH_ONE[a], MACH_ONE[a + 1], (alt - 4000.0 * a) / 4000.0)

# Indicated airspeed from true airspeed (m/s): scaled by the square root of the density ratio
static func ias(tas: float, alt: float) -> float:
	return tas * sqrt(air_density(alt) / RHO[0])
