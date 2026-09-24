"""Writes a made-up YSFlight replay (.yfs) of a small RvB fight on Luavi (9 minutes, one recorder),
for testing the viewer and the pipeline where the real replays aren't available (cloud sessions).

    python tools/make_test_replay.py OUT.yfs
    python -X utf8 replay_parser.py --fld gamefiles/user/RvB/ww3/Luavi.fld -o OUT.json.gz OUT.yfs

Blue: [BLUE]Tester (F-16, the recorder), [BLUE]Wingman (F-15), [BLUE]Striker (A-10).
Red:  [RED]Bandit1 (MiG-29, killed by an AIM-120, respawns, later leaves in flight near Tester),
      [RED]Bandit2 (Su-25, fires an AIM-9 that is flared, later flies into the island),
      [RED]Bandit3 (J-10, killed by an AIM-9).
Ground: a T-80U (killed by an AGM-65), a SAM, a moving blue destroyer.
Also: bombs, rockets, guns, flares, a dropped fuel tank, an unconfirmed credit, chat, loadouts.
"""
import math
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
import fld_reader  # noqa: E402
import weapon_sim  # noqa: E402

HZ = 20.0
END = 540.0
G = fld_reader.GroundHeight(fld_reader.load_field(os.path.join(REPO, "gamefiles/user/RvB/ww3/Luavi.fld"), "[RVB]LUAVI").grids)


def circle(cx, cz, r, alt, speed, phase, clockwise=True):
    w = speed / r * (1 if clockwise else -1)

    def pos(t):
        a = phase + w * t
        return (cx + r * math.cos(a), alt + 150.0 * math.sin(t / 23.0), cz + r * math.sin(a))
    return pos


def line(p0, p1, t0, t1):
    def pos(t):
        u = (t - t0) / (t1 - t0)
        return tuple(p0[k] + (p1[k] - p0[k]) * u for k in range(3))
    return pos


def attitude(pos, t, bank=0.0):
    a, b = pos(t - 0.05), pos(t + 0.05)
    v = [(b[k] - a[k]) / 0.1 for k in range(3)]
    h = math.atan2(-v[0], v[2])
    p = math.atan2(v[1], math.hypot(v[0], v[2]))
    return h, p, bank


class Sortie:
    def __init__(self, n, typ, name, iff, ident, t0, t1, path, bank=0.35, g=2.5, own=False, leave=False):
        self.n, self.typ, self.name, self.iff, self.ident = n, typ, name, iff, ident
        self.t0, self.t1, self.path, self.bank, self.g, self.own = t0, t1, path, bank, g, own
        self.death = None       # time it starts tumbling (killed / crashed)
        self.leave = leave      # disappears in flight at t1
        self.hit_at = []        # (time, health lost) before the death

    def samples(self):
        out = []
        t = self.t0
        end = self.t1 if self.death is None else self.death + 3.0
        health = 40
        while t <= end + 1e-9:
            x, y, z = self.path(min(t, self.death if self.death else t))
            h, p, b = attitude(self.path, min(t, self.death if self.death else t), self.bank)
            state, gl = 0, self.g
            for when, lost in self.hit_at:
                if abs(t - when) < 0.025:
                    health -= lost
            if self.death is not None and t >= self.death:
                dt = t - self.death             # tumbling down
                y -= 0.5 * 9.8 * dt * dt * 6
                b += dt * 4.0
                p -= dt * 0.8
                state, health, gl = 4, 1, 0.0
            if self.death is not None and t >= self.death + 3.0 - 1e-9:
                state = 3
            if self.death is None and t >= end - 1e-9:
                state = 3                       # every track ends removed
            y = max(y, G(x, z) + (0.0 if state else 1.0))
            ctrl = [state, 0, 0, 0, 0, 0, 0, 0, 1 if (t % 40) < 8 else 0, max(health, 1 if state else health),
                    85, 0, 0, 0, 0, 0, 0, 0]
            out.append((round(t, 3), x, y, z, h, p, b, gl, ctrl))
            t += 1.0 / HZ
        return out


def track_for_sim(s, t_until=None):
    """Samples as weapon_sim.Track wants them (the intact track, as if it never died)."""
    keep = s.death
    s.death = None
    t1 = s.t1
    if t_until:
        s.t1 = t_until
    smp = s.samples()
    s.death, s.t1 = keep, t1
    return weapon_sim.Track([{"t": t, "x": x, "y": y, "z": z, "yaw": h, "pitch": p, "roll": b, "ctrl": c}
                             for t, x, y, z, h, p, b, g, c in smp])


def main(out):
    blue_c, red_c = (16000.0, 9000.0), (23000.0, 9000.0)
    s = [
        Sortie(0, "F-16(BLUE/MULTIROLE)", "[BLUE]Tester", 1, 1, 0.0, END, circle(*blue_c, 2500, 3000, 230, 0.0), own=True),
        Sortie(1, "F-15(BLUE/MULTIROLE)", "[BLUE]Wingman", 1, 2, 5.0, END, circle(*blue_c, 2800, 3300, 240, 0.4)),
        Sortie(2, "A-10(BLUE/CAS)", "[BLUE]Striker", 1, 3, 10.0, END, circle(19500, 14000, 3000, 1500, 170, 2.0, False)),
        Sortie(3, "MIG-29(RED/MULTIROLE)", "[RED]Bandit1", 4, 4, 0.0, END, circle(*red_c, 2500, 3100, 235, math.pi)),
        Sortie(4, "SU-25(RED/CAS)", "[RED]Bandit2", 4, 5, 0.0, END, circle(*red_c, 3000, 2500, 190, 2.5)),
        Sortie(5, "J-10(RED/MULTIROLE)", "[RED]Bandit3", 4, 6, 20.0, END, circle(*red_c, 2200, 3600, 250, 1.0, False)),
        Sortie(6, "MIG-29(RED/MULTIROLE)", "[RED]Bandit1", 4, 7, 400.0, 480.0, circle(*red_c, 2500, 3100, 235, 0.3), leave=True),
    ]
    # Bandit2 flies into the island (x 22000..25000, z 15000) at the end of a dive
    dive_from = s[4].path(280.0)
    target = (24000.0, G(24000.0, 15200.0) - 30.0, 15200.0)
    old = s[4].path
    s[4].path = lambda t, old=old, d=line(dive_from, target, 280.0, 301.0): old(t) if t < 280.0 else d(t)
    ground_y = G(24000.0, 15200.0)
    s[4].death = 280.0 + 21.0 * (dive_from[1] - ground_y) / (dive_from[1] - target[1])

    grounds = [
        {"type": "[GOP]T-80U", "name": "", "iff": 4, "pos": (21000.0, 15800.0), "destroyed": None},
        {"type": "[GOP]SAM", "name": "", "iff": 4, "pos": (22500.0, 15600.0), "destroyed": None},
        {"type": "DESTROYER_BLUE", "name": "", "iff": 1, "pos": (14000.0, 4000.0), "destroyed": None, "moves": True},
    ]

    weapons, kills, booms, events = [], [], [], []

    def launch(t, wtype, shooter, target_idx=-1, velocity=None, rng=5000.0, vmax=900.0, turn=0.7, cone=0.6,
               aim=None):
        x, y, z = shooter.path(t)
        h, p, b = attitude(shooter.path, t)
        if aim is not None:                      # the pilot points at the target (with some lead)
            ax, ay, az = aim
            d = math.dist((x, y, z), aim)
            h, p = math.atan2(-(ax - x), az - z), math.asin((ay - y) / d)
        w = {"t": t, "type": wtype, "x": x, "y": y - 2.0, "z": z, "yaw": h, "pitch": p, "roll": b,
             "velocity": velocity or 240.0, "range": rng, "damage": 12, "owner": "A%d" % shooter.n, "credit": "P",
             "max_speed": vmax, "turn_rate": turn, "seeker_cone": cone, "target": target_idx}
        weapons.append(w)
        return w

    def fly(w, tracks, gtracks=None):
        rec = dict(w, owner=int(w["owner"][1:]))
        return weapon_sim.simulate(rec, tracks, gtracks or {}, [], (0, 0, 0), {k.n: k.iff for k in s})

    # 1. Tester's AIM-120 at Bandit1: its re-flown hit decides when Bandit1 dies
    w = launch(60.0, 6, s[0], 3, rng=30000.0, vmax=1200.0, turn=3.0, cone=0.8, aim=s[3].path(67.0))
    r = fly(w, {k.n: track_for_sim(k) for k in s[:4]})
    assert r["end"]["reason"] == "hit", r["end"]
    s[3].death = r["end"]["t"]
    s[3].t1 = s[3].death + 3.0
    kills.append((6, "A0", "A3", s[3].death + 0.1, s[3].path(s[3].death)))
    booms.append((s[3].death, s[3].path(s[3].death), "A0"))
    events.append((s[3].death + 2.0, "[BLUE]Tester: splash one"))

    # 2. Bandit2's AIM-9 at Wingman, flared (Wingman drops flares): an unconfirmed credit
    launch(95.0, 1, s[4], 1, rng=5000.0, aim=s[1].path(99.0))
    for k in range(6):
        fx, fy, fz = s[1].path(96.0 + 0.3 * k)
        weapons.append({"t": 96.0 + 0.3 * k, "type": 5, "x": fx, "y": fy, "z": fz, "yaw": 0.0, "pitch": -0.5,
                        "roll": 0.0, "velocity": 60.0, "range": 600.0, "damage": 0, "owner": "A1", "credit": "P"})
    kills.append((1, "A4", "A1", 101.0, s[1].path(101.0)))           # Wingman flew on: unconfirmed

    # 3. Striker's AGM-65 at the T-80U (ground object 0)
    gpos = grounds[0]["pos"]
    gtrack = weapon_sim.Track([{"t": 0.0, "x": gpos[0], "y": G(*gpos), "z": gpos[1], "yaw": 0.0, "pitch": 0.0,
                                "roll": 0.0, "state": 0}, {"t": END, "x": gpos[0], "y": G(*gpos), "z": gpos[1],
                                "yaw": 0.0, "pitch": 0.0, "roll": 0.0, "state": 0}])
    gtrack.radius = 8.0
    w = launch(118.0, 2, s[2], 0, rng=12000.0, vmax=320.0, turn=0.4, cone=0.6, velocity=180.0,
               aim=(gpos[0], G(*gpos), gpos[1]))
    r = fly(w, {}, {0: gtrack})
    t_gk = r["end"]["t"] if r["end"]["reason"] == "hit" else 131.0
    grounds[0]["destroyed"] = t_gk
    kills.append((2, "A2", "G0", t_gk, (gpos[0], G(*gpos), gpos[1])))
    booms.append((t_gk, (gpos[0], G(*gpos), gpos[1]), "A2"))

    # 4. Striker's bombs and rockets near the SAM, and a gun burst; Tester drops a fuel tank
    for k, typ in enumerate((3, 3, 7, 9)):
        x, y, z = s[2].path(150.0 + k)
        h, p, b = attitude(s[2].path, 150.0 + k)
        weapons.append({"t": 150.0 + k, "type": typ, "x": x, "y": y - 2, "z": z, "yaw": h, "pitch": p, "roll": b,
                        "velocity": 170.0, "range": 0.0, "damage": 60, "owner": "A2", "credit": "P"})
    for k in range(8):
        x, y, z = s[2].path(170.0 + 0.1 * k)
        h, p, b = attitude(s[2].path, 170.0 + 0.1 * k)
        weapons.append({"t": 170.0 + 0.1 * k, "type": 4, "x": x, "y": y, "z": z, "yaw": h, "pitch": p - 0.15,
                        "roll": b, "velocity": 170.0, "range": 3000.0, "damage": 10, "owner": "A2", "credit": "P",
                        "max_speed": 700.0})
    x, y, z = s[0].path(330.0)
    h, p, b = attitude(s[0].path, 330.0)
    weapons.append({"t": 330.0, "type": 12, "x": x, "y": y - 2, "z": z, "yaw": h, "pitch": p, "roll": b,
                    "velocity": 230.0, "range": 0.0, "damage": 0, "owner": "A0", "credit": "P"})

    # 5. Wingman's AIM-9 at Bandit3 (after Bandit3 shoots Tester with its gun)
    for k in range(20):
        t = 200.0 + 0.1 * k
        x, y, z = s[5].path(t)
        tx, ty, tz = s[0].path(t + 0.8)
        d = math.dist((x, y, z), (tx, ty, tz))
        h = math.atan2(-(tx - x), tz - z)
        p = math.asin((ty - y) / d)
        weapons.append({"t": t, "type": 0, "x": x, "y": y, "z": z, "yaw": h, "pitch": p, "roll": 0.0,
                        "velocity": 1000.0, "range": 2500.0, "damage": 1, "owner": "A5", "credit": "P"})
    s[0].hit_at = [(200.9, 3), (201.4, 2)]
    w = launch(240.0, 1, s[1], 5, rng=9000.0, vmax=1000.0, turn=3.0, cone=0.9, aim=s[5].path(245.0))
    r = fly(w, {k.n: track_for_sim(k) for k in (s[0], s[1], s[5])})
    t_k = r["end"]["t"] if r["end"]["reason"] == "hit" else 256.0
    s[5].death = t_k
    s[5].t1 = t_k + 3.0
    kills.append((1, "A1", "A5", t_k + 0.1, s[5].path(t_k)))
    booms.append((t_k, s[5].path(t_k), "A1"))

    # 6. Bandit2 into the ground; Bandit1 back, then leaves in flight near Tester
    booms.append((s[4].death + 0.5, (24000.0, ground_y, 15200.0), "N"))
    events += [(2.0, "Server: RvB test event starts, good luck"), (s[4].death + 1.0, "[RED]Bandit2: lag spike!!"),
               (482.0, "[RED]Bandit1 has left the server")]

    # --- write the replay ---
    lines = ["YFSVERSI 20181124", "FIELDNAM [RVB]LUAVI 00000000", "CONSTWIND 0.000000m/s 0.000000m/s 0.000000m/s"]
    for k in s:
        smp = k.samples()
        lines += ["AIRPLANE %s %s" % (k.typ, "TRUE" if k.own else "FALSE"), "IDENTIFY %d" % (k.iff - 1),
                  'IDANDTAG %d "%s"' % (k.ident, k.name), "NUMRECOR %d 4" % len(smp)]
        for t, x, y, z, h, p, b, g, c in smp:
            lines += ["%g" % t, "%.2f %.2f %.2f %.4f %.4f %.4f %.1f" % (x, y, z, h, p, b, g),
                      " ".join(str(int(v)) for v in c), "0"]
    for n, g in enumerate(grounds):
        x0, z0 = g["pos"]
        pts = []
        if g.get("moves"):
            for k in range(0, int(END) + 1, 10):
                pts.append((float(k), x0 + 6.0 * k, 0.0, z0, -math.pi / 2, 0))
        else:
            pts.append((0.0, x0, G(x0, z0), z0, 0.0, 0))
            if g["destroyed"]:
                pts.append((g["destroyed"], x0, G(x0, z0), z0, 0.0, 1))
        lines += ["GROUNDOB %s FALSE" % g["type"], "IDENTIFY %d" % (g["iff"] - 1), 'IDANDTAG %d ""' % (100 + n),
                  "NUMGDREC %d 3" % len(pts)]
        for t, x, y, z, h, state in pts:
            lines += ["%g" % t, "%.2f %.2f %.2f %.4f 0.0000 0.0000" % (x, y, z, h), "%d %d" % (state, 0 if state else 20),
                      "0.00 0.00 0.00 0.00 0.00 0.00 0.00 0.00 0.00 0 0 0", "0 0 0 0 0 0", "0"]
    lines.append("EVTBLOCK")
    lines += ["PLRAIR 0.000000 0", "OBJID 1", "ENDEVT"]
    loadouts = {1: [("AIM120", 4), ("AIM9", 2), ("FUEL", 1600), ("GUN", 510), ("FLR", 60)],
                2: [("AIM120", 6), ("AIM9", 2), ("GUN", 940), ("FLR", 60)],
                3: [("AGM65", 2), ("B500", 2), ("B250", 1), ("B500HD", 1), ("RKT", 19), ("GUN", 1174)],
                4: [("AIM120", 2), ("AIM9", 4), ("GUN", 150)], 5: [("AIM9", 2), ("RKT", 40), ("GUN", 250)],
                6: [("AIM120", 4), ("AIM9", 2), ("GUN", 200)], 7: [("AIM120", 2), ("AIM9", 4), ("GUN", 150)]}
    for k in s:
        lines += ["WPNCFG %f 0" % k.t0, "AIRID %d" % k.ident]
        lines += ["CFG %s %d" % c for c in loadouts[k.ident]]
        lines.append("ENDEVT")
    for t, text in sorted(events):
        lines += ["TXTEVT %f 0" % t, "TXT %s" % text, "ENDEVT"]
    lines.append("EDEVTBLK")
    weapons.sort(key=lambda w: w["t"])
    lines += ["BULRECOR", "VERSION 4", "NUMRECO %d" % len(weapons)]
    for w in weapons:
        lines.append("%g %d %.2f %.2f %.2f %.4f %.4f %.4f" % (w["t"], w["type"], w["x"], w["y"], w["z"],
                                                              w["yaw"], w["pitch"], w["roll"]))
        lines.append("%.2f %.2f %d %s %s" % (w["velocity"], w["range"], w["damage"], w["owner"], w["credit"]))
        if w["type"] in (1, 2, 6, 10):
            lines.append("%.2f %.2f %.2f %d" % (w["max_speed"], w["turn_rate"], w["seeker_cone"], w["target"]))
        elif w["type"] == 4:
            lines.append("%.2f" % w["max_speed"])
    lines.append("KILLCREDIT 1 %d" % len(kills))
    for wt, killer, victim, t, (x, y, z) in kills:
        lines.append("%d %s %s P %.2f %.2f %.2f %.2f" % (wt, killer, victim, x, y, z, t))
    lines.append("ENDRECO")
    lines += ["EXPRECOR", "VERSION 3", "NUMRECO %d" % len(booms)]
    for t, (x, y, z), by in booms:
        lines.append("%.2f %.2f %.2f %.2f 2.0 5.0 40.0 %s 1 0" % (t, x, y, z, by))
    lines.append("ENDRECO")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s: %d sorties, %d weapons, %d kill credits; deaths: Bandit1 %.1f, Bandit3 %.1f, Bandit2 crash %.1f, T-80U %.1f"
          % (out, len(s), len(weapons), len(kills), s[3].death, s[5].death, s[4].death, grounds[0]["destroyed"]))


if __name__ == "__main__":
    main(sys.argv[1])
