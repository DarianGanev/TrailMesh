"""Pure local relevance policy over already verified report projections.

Admission, quarantine, hop and clock checks remain repository responsibilities.
Context dictionaries use the local fixture schema, never the exchange wire format.
"""

import math


EARTH_RADIUS_M = 6371008.8
BOUNDARY_TOLERANCE_M = 0.000001
SAFE_INTEGER = 9007199254740991


def _integer(value, minimum, maximum):
    return type(value) is int and minimum <= value <= maximum


def _point(value):
    return (type(value) is dict and set(value) == {"lat_e7", "lon_e7"}
            and _integer(value["lat_e7"], -900000000, 900000000)
            and _integer(value["lon_e7"], -1800000000, 1800000000))


def _vector(point):
    latitude = math.radians(point["lat_e7"] / 10000000)
    longitude = math.radians(point["lon_e7"] / 10000000)
    return (math.cos(latitude) * math.cos(longitude),
            math.cos(latitude) * math.sin(longitude), math.sin(latitude))


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def _norm(vector):
    return math.sqrt(_dot(vector, vector))


def _angle(a, b):
    return math.atan2(_norm(_cross(a, b)), _dot(a, b))


def segment_distance_m(point, start, end):
    """Shortest spherical distance to the closed minor great-circle arc."""
    p, a, b = _vector(point), _vector(start), _vector(end)
    cross = _cross(a, b)
    length = _norm(cross)
    if length < 1e-15:
        return EARTH_RADIUS_M * _angle(p, a)
    normal = tuple(value / length for value in cross)
    tangent = _cross(normal, a)
    along = math.atan2(_dot(p, tangent), _dot(p, a))
    if 0 <= along <= math.atan2(length, _dot(a, b)):
        distance = math.atan2(abs(_dot(p, normal)),
                              math.hypot(_dot(p, a), _dot(p, tangent)))
        return EARTH_RADIUS_M * distance
    return EARTH_RADIUS_M * min(_angle(p, a), _angle(p, b))


def _area_valid(area, gps=False):
    keys = {"center", "radius_m"}
    if gps:
        keys |= {"accuracy_m", "fix_at_ms"}
    if (type(area) is not dict or set(area) != keys
            or not _point(area["center"])
            or not _integer(area["radius_m"], 100, 50000)):
        return False
    if gps:
        accuracy = area["accuracy_m"]
        return (type(accuracy) in (int, float) and 0 <= accuracy <= SAFE_INTEGER
                and math.isfinite(accuracy)
                and _integer(area["fix_at_ms"], 0, SAFE_INTEGER))
    return True


def _context_valid(context):
    if context is None:
        return True
    if type(context) is not dict or not set(context) <= {"manual_area", "gps_area", "route"}:
        return False
    for key in ("manual_area", "gps_area"):
        if key in context and not _area_valid(context[key], gps=key == "gps_area"):
            return False
    if "route" in context:
        route = context["route"]
        if (type(route) is not dict or not {"points"} <= set(route)
                or not set(route) <= {"points", "corridor_m"}
                or not _integer(route.get("corridor_m", 1000), 100, 10000)):
            return False
        points = route["points"]
        if type(points) is not list or not 1 <= len(points) <= 2048 or not all(map(_point, points)):
            return False
        if any(_dot(_vector(a), _vector(b)) <= -1 + 1e-12
               for a, b in zip(points, points[1:])):
            return False
    return True


def evaluate(report, context, now_ms):
    """Return a typed decision string for an admitted report and local context."""
    if not _integer(now_ms, 0, SAFE_INTEGER) or not _context_valid(context):
        return "invalidConfiguration"
    if report["expires_at_ms"] <= now_ms:
        return "expired"
    context = context or {}
    areas = []
    if "manual_area" in context:
        areas.append(context["manual_area"])
    if "gps_area" in context:
        gps = context["gps_area"]
        if gps["accuracy_m"] <= 1000 and 0 <= now_ms - gps["fix_at_ms"] <= 300000:
            areas.append(gps)
    route = context.get("route")
    if not areas and route is None:
        return "configurationRequired"
    point = {"lat_e7": report["lat_e7"], "lon_e7": report["lon_e7"]}
    for area in areas:
        distance = EARTH_RADIUS_M * _angle(_vector(point), _vector(area["center"]))
        if distance <= area["radius_m"] + BOUNDARY_TOLERANCE_M:
            return "eligible"
    if route is not None:
        points = route["points"]
        segments = zip(points, points[1:]) if len(points) > 1 else [(points[0], points[0])]
        if any(segment_distance_m(point, start, end)
               <= route.get("corridor_m", 1000) + BOUNDARY_TOLERANCE_M
               for start, end in segments):
            return "eligible"
    return "notRelevant"


def select_reports(reports, context, now_ms):
    """Select eligible verified reports, newest first then ID ascending.

    Duplicate IDs are immutable admitted bundles. The first eligible projection
    in deterministic order is retained. Wire inventories sort these IDs ascending.
    """
    selected = {}
    for report in sorted(reports, key=lambda item: (-item["observed_at_ms"], item["id"])):
        if report["id"] not in selected and evaluate(report, context, now_ms) == "eligible":
            selected[report["id"]] = report
    return list(selected.values())
