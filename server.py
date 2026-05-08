"""Song Dissector backend — FastAPI.

Run from this directory:

    pip install fastapi uvicorn python-multipart
    uvicorn server:app --reload

Storage layout (under ./data/):
    data/<project_id>/project.json   — annotations + metadata
    data/<project_id>/audio.<ext>    — original uploaded audio file
"""

from __future__ import annotations

import json
import os
import re
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Body, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

ROOT = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ.get("DATA_DIR") or (ROOT / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
AUDIO_PREFIX = "audio."

app = FastAPI(title="Song Dissector")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def proj_dir(project_id: str) -> Path:
    if not ID_RE.match(project_id):
        raise HTTPException(400, "Invalid project id")
    return DATA_DIR / project_id


def find_audio(d: Path) -> Path | None:
    for f in d.iterdir():
        if f.is_file() and f.name.startswith(AUDIO_PREFIX):
            return f
    return None


def safe_ext(filename: str | None) -> str:
    if not filename or "." not in filename:
        return "bin"
    ext = filename.rsplit(".", 1)[-1].lower()
    if not re.fullmatch(r"[a-z0-9]{1,8}", ext):
        return "bin"
    return ext


# ───────── pages ─────────

@app.get("/")
def page_index():
    return FileResponse(ROOT / "index.html")


@app.get("/editor")
def page_editor():
    return FileResponse(ROOT / "editor.html")


# ───────── projects ─────────

@app.get("/api/projects")
def list_projects():
    out = []
    if not DATA_DIR.exists():
        return out
    for d in DATA_DIR.iterdir():
        if not d.is_dir():
            continue
        meta_file = d / "project.json"
        if not meta_file.exists():
            continue
        try:
            meta = json.loads(meta_file.read_text())
        except Exception:
            continue
        out.append({
            "id": d.name,
            "songName": meta.get("songName") or "(untitled)",
            "bpm": meta.get("bpm"),
            "key": meta.get("key"),
            "duration": meta.get("duration"),
            "sectionCount": len(meta.get("sections", [])),
            "markerCount": len(meta.get("markers", [])),
            "hasLoop": meta.get("loop") is not None,
            "created": meta.get("created"),
            "updated": meta.get("updated"),
        })
    out.sort(key=lambda p: p.get("updated") or "", reverse=True)
    return out


@app.get("/api/projects/{project_id}")
def get_project(project_id: str):
    d = proj_dir(project_id)
    meta_file = d / "project.json"
    if not meta_file.exists():
        raise HTTPException(404, "Project not found")
    meta = json.loads(meta_file.read_text())
    audio = find_audio(d)
    return {
        "id": project_id,
        **meta,
        "audioUrl": f"/api/projects/{project_id}/audio" if audio else None,
        "audioName": audio.name if audio else None,
    }


@app.get("/api/projects/{project_id}/audio")
def get_project_audio(project_id: str):
    d = proj_dir(project_id)
    audio = find_audio(d) if d.exists() else None
    if not audio:
        raise HTTPException(404, "Audio not found")
    return FileResponse(audio)


@app.post("/api/projects")
async def create_project(metadata: str = Form(...), audio: UploadFile = File(...)):
    try:
        meta = json.loads(metadata)
    except json.JSONDecodeError as e:
        raise HTTPException(400, f"Invalid metadata JSON: {e}")

    project_id = uuid.uuid4().hex[:12]
    d = DATA_DIR / project_id
    d.mkdir(parents=True)

    ext = safe_ext(audio.filename)
    audio_path = d / f"{AUDIO_PREFIX}{ext}"
    with audio_path.open("wb") as f:
        shutil.copyfileobj(audio.file, f)

    meta.pop("id", None)
    meta["audioFile"] = audio.filename
    meta["created"] = now_iso()
    meta["updated"] = meta["created"]
    (d / "project.json").write_text(json.dumps(meta, indent=2))

    return {"id": project_id, **meta, "audioUrl": f"/api/projects/{project_id}/audio"}


@app.put("/api/projects/{project_id}")
async def update_project(project_id: str, payload: dict = Body(...)):
    d = proj_dir(project_id)
    meta_file = d / "project.json"
    if not meta_file.exists():
        raise HTTPException(404, "Project not found")
    existing = json.loads(meta_file.read_text())
    payload.pop("id", None)
    existing.update(payload)
    existing["updated"] = now_iso()
    meta_file.write_text(json.dumps(existing, indent=2))
    return {"id": project_id, **existing}


@app.delete("/api/projects/{project_id}")
def delete_project(project_id: str):
    d = proj_dir(project_id)
    if d.exists():
        shutil.rmtree(d)
        return {"ok": True}
    raise HTTPException(404, "Project not found")
