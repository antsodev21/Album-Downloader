#!/usr/bin/env bash
# ============================================
# descargar_album.sh (v44 - Deezer API Limpio + Sin Arrastres de Apple Music)
# ============================================

set -euo pipefail

ARG1=""
FORMATO="flac"
CARPETA="Albumes"
SEARCH_QUERY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--format) FORMATO="$2"; shift 2 ;;
        -o|--output|--carpeta) CARPETA="$2"; shift 2 ;;
        -m|--metadata|-s|--spotify) SEARCH_QUERY="$2"; shift 2 ;;
        -h|--help)
            echo "Uso: $0 \"URL_YOUTUBE_O_CARPETA\" -m \"ENLACE_DEEZER_O_TEXTO\""
            exit 0
            ;;
        *)
            if [[ -z "$ARG1" ]]; then ARG1="$1"; else echo "❌ Error: Argumento extra: $1"; exit 1; fi
            shift
            ;;
    esac
done

if [[ -z "$ARG1" ]]; then echo "❌ Error: Falta URL o carpeta."; exit 1; fi

VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${AZUL}[INFO]${NC} $1"; }
ok()    { echo -e "${VERDE}[OK]${NC} $1"; }
error() { echo -e "${ROJO}[ERROR]${NC} $1"; }

aplicar_metadata_deezer() {
    local dir="$1" query="$2"
    info "Procesando metadatos de forma limpia..."
    
    python3 - "$dir" "$query" <<'PY'
import base64, json, os, re, struct, sys, urllib.parse, urllib.request
from pathlib import Path

import mutagen
import mutagen.id3
import mutagen.mp4
import mutagen.flac
import mutagen.oggopus
import mutagen.oggvorbis
from mutagen.id3 import APIC, TALB, TDRC, TIT2, TPE1, TPE2, TRCK, TCON

subdir, query = sys.argv[1], sys.argv[2]
exts = {".flac", ".mp3", ".m4a", ".opus", ".ogg"}

album_name = "Desconocido"
album_artist = "Desconocido"
release_date = ""
genre_name = "Soundtrack"
tracks_data = []
modo_local = False
cover_data, cover_mime = None, "image/jpeg"

try:
    album_id = None
    if query and "deezer.com" in query:
        m = re.search(r'/album/(\d+)', query)
        if m: album_id = m.group(1)

    if album_id:
        album_url = f"https://api.deezer.com/album/{album_id}"
    elif query:
        encoded_query = urllib.parse.quote(query)
        search_url = f"https://api.deezer.com/search/album?q={encoded_query}&limit=1"
        req = urllib.request.Request(search_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            search_data = json.loads(resp.read().decode())
        data_res = search_data.get("data", [])
        if not data_res:
            raise Exception("No encontrado en Deezer")
        album_id = data_res[0].get("id")
        album_url = f"https://api.deezer.com/album/{album_id}"
    else:
        raise Exception("Sin consulta válida")

    req_album = urllib.request.Request(album_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req_album, timeout=8) as resp:
        album_data = json.loads(resp.read().decode())

    if "error" in album_data:
        raise Exception("Deezer devolvió error")

    album_name = album_data.get("title", "Desconocido")
    album_artist = album_data.get("artist", {}).get("name", "Desconocido")
    release_date = album_data.get("release_date", "")[:4]
    genre_data = album_data.get("genres", {}).get("data", [])
    genre_name = genre_data[0].get("name", "Soundtrack") if genre_data else "Soundtrack"
    tracks_data = album_data.get("tracks", {}).get("data", [])

    raw_cover_url = album_data.get("cover_xl") or album_data.get("cover_big") or album_data.get("cover_medium", "")
    if raw_cover_url:
        req_cover = urllib.request.Request(raw_cover_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req_cover, timeout=10) as r:
            cover_data = r.read()
        if cover_data[:8] == b"\x89PNG\r\n\x1a\n":
            cover_mime = "image/png"
        print(f"  [OK] Portada de Deezer descargada ({len(cover_data)//1024} KB)")

except Exception as e:
    print(f"  [AVISO] No se pudo usar Deezer ({e}). Activando Modo Local / OST...")
    modo_local = True
    album_name = os.path.basename(subdir)
    album_artist = "Video Game Soundtrack"

if modo_local and not cover_data:
    for img_name in ["cover.jpg", "cover.png", "folder.jpg", "folder.png"]:
        img_path = Path(subdir) / img_name
        if img_path.exists():
            with open(img_path, "rb") as img_f:
                cover_data = img_f.read()
            if cover_data[:8] == b"\x89PNG\r\n\x1a\n":
                cover_mime = "image/png"
            print(f"  [OK] Carátula local detectada: {img_name} ({len(cover_data)//1024} KB)")
            break

def picture_block():
    mime = cover_mime.encode()
    return base64.b64encode(b"".join([
        struct.pack(">I", 3),
        struct.pack(">I", len(mime)), mime,
        struct.pack(">I", 0),
        struct.pack(">IIII", 0, 0, 0, 0),
        struct.pack(">I", len(cover_data)), cover_data,
    ])).decode()

def limpio(s):
    return re.sub(r'[\\/:*?"<>|]', "-", s).strip()

def natural_sort_key(path):
    return [int(c) if c.isdigit() else c.lower() for c in re.split(r'(\d+)', path.name)]

okn = 0
archivos = sorted([p for p in Path(subdir).rglob("*") if p.is_file() and p.suffix.lower() in exts], key=natural_sort_key)

print(f"\n  🎵 Álbum: {album_name} — {album_artist} ({len(archivos)} pistas detectadas)")

for idx, p in enumerate(archivos):
    try:
        f = mutagen.File(p)
        if f is None: continue
        
        track_name = ""
        artists = album_artist
        track_no = idx + 1
        match_type = "natural"

        if not modo_local and tracks_data and idx < len(tracks_data):
            best = tracks_data[idx]
            track_name = best.get("title", "Desconocido")
            artists = best.get("artist", {}).get("name", album_artist)
            track_no = best.get("track_position", idx + 1)
            match_type = "deezer"
        else:
            track_name = re.sub(r"^\d+[\s\-_\.]+", "", p.stem).strip()
            if not track_name:
                track_name = p.stem
            match_type = "local"

        if f.tags is None: f.add_tags()

        if isinstance(f.tags, mutagen.id3.ID3):
            f.tags.delall("APIC")
            f.tags.add(TIT2(encoding=3, text=[track_name]))
            f.tags.add(TPE1(encoding=3, text=[artists]))
            f.tags.add(TALB(encoding=3, text=[album_name]))
            f.tags.add(TPE2(encoding=3, text=[album_artist]))
            f.tags.add(TRCK(encoding=3, text=[str(track_no)]))
            if release_date: f.tags.add(TDRC(encoding=3, text=[release_date]))
            if genre_name: f.tags.add(TCON(encoding=3, text=[genre_name]))
            if cover_data: f.tags.add(APIC(encoding=3, mime=cover_mime, type=3, desc="Cover", data=cover_data))
        elif isinstance(f.tags, mutagen.mp4.MP4Tags):
            f.tags["\xa9nam"] = [track_name]
            f.tags["\xa9ART"] = [artists]
            f.tags["\xa9alb"] = [album_name]
            f.tags["\xa9aART"] = [album_artist]
            f.tags["trkn"] = [(track_no, 0)]
            if release_date: f.tags["\xa9day"] = [release_date]
            if genre_name: f.tags["\xa9gen"] = [genre_name]
            if cover_data:
                fmt = mutagen.mp4.MP4Cover.FORMAT_PNG if cover_mime == "image/png" else mutagen.mp4.MP4Cover.FORMAT_JPEG
                f.tags["covr"] = [mutagen.mp4.MP4Cover(cover_data, imageformat=fmt)]
        elif isinstance(f, mutagen.flac.FLAC):
            f["title"] = track_name
            f["artist"] = artists
            f["album"] = album_name
            f["albumartist"] = album_artist
            f["tracknumber"] = str(track_no)
            if release_date: f["date"] = release_date
            if genre_name: f["genre"] = genre_name
            
            if cover_data:
                f.clear_pictures()
                pic = mutagen.flac.Picture()
                pic.type = 3
                pic.mime = cover_mime
                pic.desc = "Cover"
                pic.data = cover_data
                f.add_picture(pic)
        elif isinstance(f, (mutagen.oggopus.OggOpus, mutagen.oggvorbis.OggVorbis)):
            f["title"] = track_name
            f["artist"] = artists
            f["album"] = album_name
            f["albumartist"] = album_artist
            f["tracknumber"] = str(track_no)
            if release_date: f["date"] = release_date
            if genre_name: f["genre"] = genre_name
            if cover_data:
                f["metadata_block_picture"] = [picture_block()]
        else:
            f.tags["title"] = [track_name]
            f.tags["artist"] = [artists]
            f.tags["album"] = [album_name]
            f.tags["albumartist"] = [album_artist]
            f.tags["tracknumber"] = [str(track_no)]
            if release_date: f.tags["date"] = release_date
            if genre_name: f.tags["genre"] = genre_name

        f.save()

        nombre_base = limpio(track_name)
        nuevo = f"{track_no:02d} - {nombre_base}{p.suffix}"
        dest = p.with_name(nuevo)
        
        contador = 1
        while dest.exists() and dest.resolve() != p.resolve():
            nuevo = f"{track_no:02d} - {nombre_base} ({contador}){p.suffix}"
            dest = p.with_name(nuevo)
            contador += 1

        if nuevo != p.name: p.rename(dest)
        okn += 1
        print(f"  OK [{match_type}]: {p.name} ➡️ {nuevo}")
    except Exception as e:
        print(f"  aviso {p.name}: {e}")

print(f"\n  ✨ Metadatos aplicados correctamente a {okn} archivos.")
PY
}

info "Verificando dependencias..."
for cmd in python3 ffmpeg; do
    if ! command -v "$cmd" &>/dev/null; then error "Falta: $cmd"; exit 1; fi
done
if ! python3 -c "import mutagen" &>/dev/null; then
    error "Falta la librería 'mutagen'. Instálala con: pip install -U mutagen"
    exit 1
fi
ok "Dependencias OK"

if [[ -d "$ARG1" ]]; then
    ok "Modo tags-only detectado sobre carpeta: $ARG1"
    aplicar_metadata_deezer "$ARG1" "$SEARCH_QUERY"
else
    mkdir -p "$CARPETA"
    info "Descargando audio de YouTube..."
    ALBUM_FIJO=$(yt-dlp --flat-playlist --playlist-items 1 --print "%(playlist_title)s" "$ARG1" 2>/dev/null | head -n1 || echo "Desconocido")
    ALBUM_FIJO="${ALBUM_FIJO#"Album - "}"
    ALBUM_FIJO=$(printf '%s' "$ALBUM_FIJO" | sed 's#[/:]# - #g; s/|/-/g; s/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    yt-dlp \
      --yes-playlist --ignore-errors --no-overwrites \
      -x --audio-format "$FORMATO" --audio-quality 0 \
      --embed-metadata \
      -o "$CARPETA/$ALBUM_FIJO/%(playlist_index,playlist_autonumber)02d - %(title)s.%(ext)s" \
      --progress \
      "$ARG1"

    SUBDIR="$CARPETA/$ALBUM_FIJO"
    [[ -z "$SEARCH_QUERY" ]] && SEARCH_QUERY=""
    aplicar_metadata_deezer "$SUBDIR" "$SEARCH_QUERY"
fi

ok "¡Listo!"
