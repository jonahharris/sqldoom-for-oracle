"""Doom music for the Oracle data layer: the reference loader's MUS -> MIDI conversion
(reference/sqldoom/wad_loader.py mus_to_midi, music_lump_for_map, load_music) and the optional
MIDI -> Ogg Vorbis rendering for browser clients (midi_render.py), ported unchanged in behaviour.

music_assets(name, mus_data, midi_data, audio_data, audio_format) and map_music(map_id, music_name)
are filled exactly as the reference loader fills them: every D_* lump that is a MUS score, the
format-0 MIDI made of it, and for every loaded map the lump its name selects. audio_data stays NULL
when FluidSynth, a General MIDI soundfont or ffmpeg is missing (the reference loader then says
"browser clients play no music"); the desktop client plays the MIDI itself.
"""
import ctypes
import os
import re
import shutil
import struct
import subprocess
import tempfile

LE = "<"

MUS_CONTROLLER_TO_MIDI = (
    0, 32, 1, 7, 10, 11, 91, 93, 64, 67, 120, 123, 126, 127, 121,
)

DOOM2_MAP_MUSIC = (
    "RUNNIN", "STALKS", "COUNTD", "BETWEE", "DOOM", "THE_DA",
    "SHAWN", "DDTBLU", "IN_CIT", "DEAD", "STLKS2", "THEDA2",
    "DOOM2", "DDTBL2", "RUNNI2", "DEAD2", "STLKS3", "ROMERO",
    "SHAWN2", "MESSAG", "COUNT2", "DDTBL3", "AMPIE", "THEDA3",
    "ADRIAN", "MESSG2", "ROMER2", "TENSE", "SHAWN3", "OPENIN",
    "EVIL", "ULTIMA",
)

ULTIMATE_DOOM_E4_MUSIC = (
    "E3M4", "E3M2", "E3M3", "E1M5", "E2M7",
    "E2M4", "E2M6", "E2M5", "E1M9",
)


def _midi_varlen(value):
    value = max(0, int(value))
    encoded = [value & 0x7F]
    value >>= 7
    while value:
        encoded.append(0x80 | (value & 0x7F))
        value >>= 7
    return bytes(reversed(encoded))


def _mus_channel(channel):
    if channel == 15:
        return 9
    return channel if channel < 9 else channel + 1


def mus_to_midi(data):
    """Doom's MUS event stream -> a format-0 MIDI file (division 70 at 500,000 us/quarter =
    MUS's 140 ticks/second). Byte-for-byte the reference conversion."""
    if len(data) < 16 or data[:4] != b"MUS\x1a":
        raise ValueError("not a Doom MUS lump")
    score_length, score_start = struct.unpack_from(LE + "HH", data, 4)
    end = min(len(data), score_start + score_length)
    pos = score_start
    velocities = [127] * 16
    pending_delta = 0
    track = bytearray(b"\x00\xff\x51\x03\x07\xa1\x20")
    while pos < end:
        descriptor = data[pos]
        pos += 1
        channel = descriptor & 0x0F
        event_type = (descriptor >> 4) & 0x07
        last_in_group = descriptor & 0x80
        midi_channel = _mus_channel(channel)
        event = None
        if event_type == 0:          # release note
            if pos >= end:
                break
            note = data[pos] & 0x7F
            pos += 1
            event = bytes((0x80 | midi_channel, note, 0))
        elif event_type == 1:        # play note, optional new channel velocity
            if pos >= end:
                break
            note = data[pos]
            pos += 1
            if note & 0x80:
                if pos >= end:
                    break
                velocities[channel] = data[pos] & 0x7F
                pos += 1
            event = bytes((0x90 | midi_channel, note & 0x7F, velocities[channel]))
        elif event_type == 2:        # pitch wheel: MUS 0..255 -> MIDI 0..16320
            if pos >= end:
                break
            pitch = data[pos] << 6
            pos += 1
            event = bytes((0xE0 | midi_channel, pitch & 0x7F, (pitch >> 7) & 0x7F))
        elif event_type == 3:        # system controller
            if pos >= end:
                break
            controller = data[pos]
            pos += 1
            if controller >= len(MUS_CONTROLLER_TO_MIDI):
                raise ValueError(f"invalid MUS system controller {controller}")
            event = bytes((0xB0 | midi_channel, MUS_CONTROLLER_TO_MIDI[controller], 0))
        elif event_type == 4:        # controller or patch change
            if pos + 1 >= end:
                break
            controller, value = data[pos], data[pos + 1]
            pos += 2
            if controller == 0:
                event = bytes((0xC0 | midi_channel, value & 0x7F))
            else:
                if controller >= len(MUS_CONTROLLER_TO_MIDI):
                    raise ValueError(f"invalid MUS controller {controller}")
                event = bytes((0xB0 | midi_channel, MUS_CONTROLLER_TO_MIDI[controller], value & 0x7F))
        elif event_type == 6:        # score end
            break
        else:
            raise ValueError(f"unsupported MUS event type {event_type}")
        if event is not None:
            track.extend(_midi_varlen(pending_delta))
            track.extend(event)
            pending_delta = 0
        if last_in_group:
            delay = 0
            while pos < end:
                value = data[pos]
                pos += 1
                delay = (delay << 7) | (value & 0x7F)
                if not value & 0x80:
                    break
            pending_delta += delay
    track.extend(_midi_varlen(pending_delta))
    track.extend(b"\xff\x2f\x00")
    return (b"MThd" + struct.pack(">IHHH", 6, 0, 1, 70)
            + b"MTrk" + struct.pack(">I", len(track)) + bytes(track))


def music_lump_for_map(map_name):
    map_name = map_name.upper()
    if re.match(r"^E[1-3]M[1-9]$", map_name):
        return "D_" + map_name
    match = re.match(r"^E4M([1-9])$", map_name)
    if match:
        return "D_" + ULTIMATE_DOOM_E4_MUSIC[int(match.group(1)) - 1]
    match = re.match(r"^MAP([0-9][0-9])$", map_name)
    if match:
        index = int(match.group(1)) - 1
        if 0 <= index < len(DOOM2_MAP_MUSIC):
            return "D_" + DOOM2_MAP_MUSIC[index]
    return None


# ------------------------------------------------------------- optional rendering (midi_render.py)
SOUNDFONTS = (
    "/usr/share/sounds/sf2/TimGM6mb.sf2", "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2", "/usr/share/soundfonts/FluidR3_GM.sf2",
    # Homebrew (macOS): `brew install fluid-synth` plus any GM soundfont placed here
    "/opt/homebrew/share/soundfonts/default.sf2", "/usr/local/share/soundfonts/default.sf2",
)
SAMPLE_RATE, GAIN, VORBIS_QUALITY, AUDIO_FORMAT = 22050.0, 0.6, "1", "ogg"
FLUID_PLAYER_PLAYING = 1
_MAX_BLOCKS = 200000
_PROTOTYPES = (
    ("new_fluid_settings", ctypes.c_void_p, []),
    ("new_fluid_synth", ctypes.c_void_p, [ctypes.c_void_p]),
    ("new_fluid_player", ctypes.c_void_p, [ctypes.c_void_p]),
    ("new_fluid_file_renderer", ctypes.c_void_p, [ctypes.c_void_p]),
    ("fluid_synth_sfload", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
    ("fluid_player_add_mem", ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
    ("fluid_player_play", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_player_get_status", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_file_renderer_process_block", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_settings_setstr", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
    ("fluid_settings_setnum", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_double]),
    ("fluid_settings_setint", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
    ("delete_fluid_file_renderer", None, [ctypes.c_void_p]),
    ("delete_fluid_player", None, [ctypes.c_void_p]),
    ("delete_fluid_synth", None, [ctypes.c_void_p]),
    ("delete_fluid_settings", None, [ctypes.c_void_p]),
)


def _load_library():
    for name in ("libfluidsynth.so.3", "libfluidsynth.so.2", "libfluidsynth.so",
                 "libfluidsynth.3.dylib", "libfluidsynth.dylib",
                 "/opt/homebrew/lib/libfluidsynth.dylib", "/usr/local/lib/libfluidsynth.dylib"):
        try:
            lib = ctypes.CDLL(name)
        except OSError:
            continue
        try:
            for fn, restype, argtypes in _PROTOTYPES:
                func = getattr(lib, fn)
                func.restype = restype
                func.argtypes = argtypes
        except AttributeError:
            continue
        return lib
    return None


def soundfont():
    env = os.getenv("DOOM_SOUNDFONT")
    if env and os.path.isfile(env):
        return env
    for path in SOUNDFONTS:
        if os.path.isfile(path):
            return path
    return None


def unavailable_reason():
    if _load_library() is None:
        return "libfluidsynth not found"
    if soundfont() is None:
        return "no General MIDI soundfont installed (DOOM_SOUNDFONT)"
    if shutil.which("ffmpeg") is None:
        return "ffmpeg not found"
    return None


def _render_wav(lib, midi, sf2, wav_path):
    settings = lib.new_fluid_settings()
    synth = player = renderer = None
    try:
        lib.fluid_settings_setstr(settings, b"audio.file.name", wav_path.encode())
        lib.fluid_settings_setstr(settings, b"audio.file.type", b"wav")
        lib.fluid_settings_setstr(settings, b"player.timing-source", b"sample")
        lib.fluid_settings_setint(settings, b"synth.lock-memory", 0)
        lib.fluid_settings_setnum(settings, b"synth.sample-rate", SAMPLE_RATE)
        lib.fluid_settings_setint(settings, b"synth.audio-channels", 1)
        lib.fluid_settings_setnum(settings, b"synth.gain", GAIN)
        synth = lib.new_fluid_synth(settings)
        if not synth or lib.fluid_synth_sfload(synth, sf2.encode(), 1) < 0:
            return False
        player = lib.new_fluid_player(synth)
        if not player:
            return False
        buf = ctypes.create_string_buffer(midi, len(midi))
        if lib.fluid_player_add_mem(player, buf, len(midi)) != 0:
            return False
        lib.fluid_player_play(player)
        renderer = lib.new_fluid_file_renderer(synth)
        if not renderer:
            return False
        blocks = 0
        while lib.fluid_player_get_status(player) == FLUID_PLAYER_PLAYING:
            if lib.fluid_file_renderer_process_block(renderer) != 0:
                break
            blocks += 1
            if blocks >= _MAX_BLOCKS:
                break
        return blocks > 0
    finally:
        if renderer:
            lib.delete_fluid_file_renderer(renderer)
        if player:
            lib.delete_fluid_player(player)
        if synth:
            lib.delete_fluid_synth(synth)
        lib.delete_fluid_settings(settings)


def render(midi):
    """MIDI bytes -> Ogg Vorbis bytes, or None when it cannot be rendered here."""
    lib, sf2 = _load_library(), soundfont()
    if lib is None or sf2 is None or shutil.which("ffmpeg") is None:
        return None
    with tempfile.TemporaryDirectory(prefix="doom-music-") as tmp:
        wav, ogg = os.path.join(tmp, "track.wav"), os.path.join(tmp, "track.ogg")
        try:
            if not _render_wav(lib, midi, sf2, wav) or not os.path.isfile(wav) or os.path.getsize(wav) < 64:
                return None
            result = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", wav,
                                     "-c:a", "libvorbis", "-q:a", VORBIS_QUALITY, "-ac", "1", ogg],
                                    capture_output=True, timeout=300)
            if result.returncode != 0 or not os.path.isfile(ogg):
                return None
            with open(ogg, "rb") as handle:
                return handle.read()
        except (OSError, subprocess.SubprocessError):
            return None


# ------------------------------------------------------------------------------ the loader
def scores(wad, accept_midi=True):
    """{lump name: (original lump, midi)} for every D_* music lump of the WAD (later lumps win, as
    the reference's dict does). The reference converts MUS scores only; Freedoom ships its music as
    standard MIDI files ("MThd"), which the reference loader skips -- so on freedoom1.wad CedarDB
    SQLDoom has no music at all. accept_midi (the default) stores such a lump as it is, original and
    MIDI alike: the one documented extension over the reference loader."""
    out = {}
    for lump in wad.lumps:
        name = lump["name"]
        if not name.startswith("D_") or lump["size"] < 16:
            continue
        mus = wad.raw(lump)
        if accept_midi and mus.startswith(b"MThd"):
            out[name] = (mus, mus)
            continue
        if not mus.startswith(b"MUS\x1a"):
            continue
        try:
            out[name] = (mus, mus_to_midi(mus))
        except ValueError:
            continue
    return out


def load_music(cur, wad, render_audio=True, accept_midi=True):
    """music_assets + map_music as wad_loader.load_music fills them. Returns (tracks, midi bytes,
    rendered audio bytes)."""
    import oracledb
    rows = scores(wad, accept_midi)
    audio = {}
    if render_audio and unavailable_reason() is None:
        cur.execute("SELECT name FROM maps")
        wanted = {music_lump_for_map(n) for (n,) in cur.fetchall()} & set(rows)
        for name in sorted(wanted):
            audio[name] = render(rows[name][1])
    cur.execute("DELETE FROM music_assets")
    cur.execute("DELETE FROM map_music")
    cur.setinputsizes(None, oracledb.DB_TYPE_BLOB, oracledb.DB_TYPE_BLOB, oracledb.DB_TYPE_BLOB, None)
    cur.executemany("INSERT INTO music_assets (name, mus_data, midi_data, audio_data, audio_format) "
                    "VALUES (:1, :2, :3, :4, :5)",
                    [(n, mus, midi, audio.get(n), AUDIO_FORMAT if audio.get(n) else None)
                     for n, (mus, midi) in rows.items()])
    cur.execute("SELECT map_id, name FROM maps")
    maps = [(int(m), music_lump_for_map(n)) for m, n in cur.fetchall()]
    maps = [(m, t) for m, t in maps if t in rows]
    if maps:
        cur.executemany("INSERT INTO map_music (map_id, music_name) VALUES (:1, :2)", maps)
    cur.connection.commit()
    return len(rows), sum(len(v[1]) for v in rows.values()), sum(len(a or b"") for a in audio.values())
