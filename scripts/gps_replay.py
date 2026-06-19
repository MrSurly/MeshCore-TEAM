#!/usr/bin/env -S uv run --script
"""
Replay a GPS track to the app's debug inject service.

Supported input formats:
  CSV   (no header): lat, lon, speed_mps
  GeoJSON (.geojson or .json): FeatureCollection or Feature with a LineString.
          Coordinates are [lon, lat] per spec. Use --speed to set playback speed.

Points are interpolated and streamed at 2 Hz. Speed determines how quickly
the route advances between waypoints; heading is computed from each segment.

Usage:
    python3 gps_replay.py track.csv
    python3 gps_replay.py track.geojson --speed 1.4
    python3 gps_replay.py track.geojson --host 192.168.1.5 --port 7700 --rate 4
"""

import argparse
import csv
import json
import math
import random
import socket
import sys
import time


EARTH_RADIUS_M = 6_371_000.0


def haversine_m(lat1, lon1, lat2, lon2):
    r = EARTH_RADIUS_M
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2 +
         math.cos(lat1 * p) * math.cos(lat2 * p) *
         math.sin((lon2 - lon1) * p / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


def bearing_deg(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    dlon = (lon2 - lon1) * p
    y = math.sin(dlon) * math.cos(lat2 * p)
    x = (math.cos(lat1 * p) * math.sin(lat2 * p) -
         math.sin(lat1 * p) * math.cos(lat2 * p) * math.cos(dlon))
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def lerp(a, b, t):
    return a + (b - a) * t


def load_csv(path):
    track = []
    with open(path, newline="") as f:
        for i, row in enumerate(csv.reader(f)):
            if not row or row[0].strip().startswith("#"):
                continue
            row = [c.strip() for c in row]
            if len(row) < 3:
                print(f"warning: skipping row {i+1}, expected 3 columns: {row}")
                continue
            try:
                track.append((float(row[0]), float(row[1]), float(row[2])))
            except ValueError as e:
                print(f"warning: skipping row {i+1}: {e}")
    return track


def parse_speed(value):
    """Parse a speed string to m/s. Bare number assumes m/s.
    Accepts suffixes: mps, m/s, mph, kph, kmh, km/h, knots, kts.
    Examples: 1.4, 1.4mps, 5mph, 10kph, 3knots
    """
    s = value.strip().lower()
    for suffix, factor in [
        ("m/s",   1.0),
        ("mps",   1.0),
        ("km/h",  1 / 3.6),
        ("kmh",   1 / 3.6),
        ("kph",   1 / 3.6),
        ("knots", 0.514444),
        ("kts",   0.514444),
        ("mph",   0.44704),
    ]:
        if s.endswith(suffix):
            return float(s[:-len(suffix)]) * factor
    return float(s)  # bare number → m/s


def load_geojson(path, speed):
    with open(path) as f:
        data = json.load(f)

    # Unwrap FeatureCollection → first LineString feature.
    if data.get("type") == "FeatureCollection":
        features = data.get("features", [])
        lines = [f for f in features
                 if f.get("geometry", {}).get("type") == "LineString"]
        if not lines:
            print("error: no LineString feature found in FeatureCollection")
            sys.exit(1)
        coords = lines[0]["geometry"]["coordinates"]
    elif data.get("type") == "Feature":
        coords = data["geometry"]["coordinates"]
    elif data.get("type") == "LineString":
        coords = data["coordinates"]
    else:
        print(f"error: unsupported GeoJSON type: {data.get('type')}")
        sys.exit(1)

    # GeoJSON is [lon, lat]; convert to (lat, lon, speed).
    return [(c[1], c[0], speed) for c in coords]


def load_track(path, speed=1.4):
    ext = path.rsplit(".", 1)[-1].lower()
    if ext in ("geojson", "json"):
        return load_geojson(path, speed)
    return load_csv(path)


def interpolate(track, rate_hz, speed_upper=None):
    """Yield (lat, lon, speed_mps, heading_deg) at `rate_hz` intervals.

    Position advances each tick based on the current speed, so higher speed
    means larger jumps along the segment. With --speed-upper the speed walks
    randomly between --speed and --speed-upper using a bounded random walk.
    """
    interval = 1.0 / rate_hz

    for i in range(len(track) - 1):
        lat1, lon1, spd1 = track[i]
        lat2, lon2, spd2 = track[i + 1]

        dist = haversine_m(lat1, lon1, lat2, lon2)
        hdg = bearing_deg(lat1, lon1, lat2, lon2)

        if dist <= 0:
            yield (lat1, lon1, spd1, hdg)
            continue

        # Random-walk state (only used when speed_upper is set).
        rw_speed = random.uniform(spd1, speed_upper) if speed_upper is not None else spd1
        rw_step = (speed_upper - spd1) * 0.08 if speed_upper is not None else 0.0

        t = 0.0
        while t < 1.0:
            spd = rw_speed if speed_upper is not None else lerp(spd1, spd2, t)
            yield (lerp(lat1, lat2, t), lerp(lon1, lon2, t), spd, hdg)

            # Advance t by how far we travel in one tick at this speed.
            t += (spd * interval) / dist

            # Step the random walk for the next tick.
            if speed_upper is not None:
                rw_speed = max(spd1, min(speed_upper,
                               rw_speed + random.gauss(0, rw_step / 2)))

    lat, lon, spd = track[-1]
    yield (lat, lon, spd, 0.0)


def make_packet(gps_type, lat, lon, speed, heading):
    payload = {"lat": round(lat, 7), "lon": round(lon, 7), "hasFix": True}
    if gps_type == "phone":
        payload["speed"] = round(speed, 2)
        payload["heading"] = round(heading, 1)
    return json.dumps({"type": f"gps_{gps_type}" if gps_type == "companion" else "gps",
                       "payload": payload})


def send_track(track, host, port, rate_hz, source="phone", speed_upper=None):
    interval = 1.0 / rate_hz
    points = list(interpolate(track, rate_hz, speed_upper=speed_upper))

    print(f"connecting to {host}:{port} ...")
    with socket.create_connection((host, port)) as sock:
        print(f"connected. {len(track)} waypoints → {len(points)} points at {rate_hz} Hz  source={source}")
        t0 = time.monotonic()
        for i, (lat, lon, speed, heading) in enumerate(points):
            packet = make_packet(source, lat, lon, speed, heading)
            sock.sendall((packet + "\n").encode())
            elapsed = time.monotonic() - t0
            print(f"  [{i+1}/{len(points)}] {lat:.6f}, {lon:.6f}  "
                  f"spd={speed:.1f} m/s  hdg={heading:.0f}°  t={elapsed:.2f}s")
            if i < len(points) - 1:
                time.sleep(interval)

    elapsed_total = time.monotonic() - t0
    expected_total = (len(points) - 1) * interval
    print(f"replay complete — elapsed {elapsed_total:.2f}s  expected {expected_total:.2f}s  "
          f"drift {elapsed_total - expected_total:+.2f}s")


def main():
    parser = argparse.ArgumentParser(
        description="Replay a GPS track to the debug inject service")
    parser.add_argument("file", nargs="?", help="CSV (lat,lon,speed_mps) or GeoJSON file")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7700)
    parser.add_argument("--rate", type=float, default=2.0,
                        help="output rate in Hz (default: 2)")
    parser.add_argument("--source", choices=["phone", "companion"], default="phone",
                        help="which GPS source to fake (default: phone)")
    parser.add_argument("--speed", type=parse_speed, default=1.4,
                        help="playback speed for GeoJSON input, e.g. 1.4, 5mph, 10kph, 3knots (default: 1.4 m/s)")
    parser.add_argument("--speed-upper", type=parse_speed, default=None,
                        help="when set, speed varies gently between --speed and this value")
    parser.add_argument("--av", action="store_true",
                        help="send a single fixed location (33.567512, -117.722262) and exit")
    args = parser.parse_args()

    if args.av:
        packet = make_packet(args.source, 33.567512, -117.722262, 0.0, 0.0)
        print(f"connecting to {args.host}:{args.port} ...")
        with socket.create_connection((args.host, args.port)) as sock:
            sock.sendall((packet + "\n").encode())
        print(f"sent AV location (source={args.source})")
        return

    if not args.file:
        parser.error("a file argument is required unless --av is used")

    speed_upper = args.speed_upper
    if speed_upper is not None and speed_upper < args.speed:
        parser.error("--speed-upper must be >= --speed")

    track = load_track(args.file, speed=args.speed)
    if len(track) < 2:
        print("error: need at least 2 waypoints")
        sys.exit(1)

    send_track(track, args.host, args.port, args.rate, source=args.source,
               speed_upper=speed_upper)


if __name__ == "__main__":
    main()
