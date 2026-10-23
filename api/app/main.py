import json
import logging
import os
import time
import uuid
from pathlib import Path

import boto3
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://inference:11434")
MODEL = os.getenv("MODEL_NAME", "tinyllama")
S3_BUCKET = os.getenv("S3_BUCKET") or None
STATIC_DIR = Path(__file__).parent / "static"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("api")

app = FastAPI(title="TinyLlama API")
s3 = boto3.client("s3") if S3_BUCKET else None


class Message(BaseModel):
    role: str = Field(pattern="^(system|user|assistant)$")
    content: str = Field(min_length=1, max_length=4000)


class ChatRequest(BaseModel):
    messages: list[Message] = Field(min_length=1, max_length=50)
    temperature: float = Field(0.7, ge=0, le=2)
    max_tokens: int = Field(256, ge=1, le=1024)


@app.get("/health")
async def health():
    try:
        async with httpx.AsyncClient(timeout=3) as client:
            r = await client.get(f"{OLLAMA_URL}/api/tags")
        return {"status": "ok", "inference": r.status_code == 200, "s3_export": bool(s3)}
    except httpx.HTTPError:
        return {"status": "degraded", "inference": False, "s3_export": bool(s3)}


@app.post("/api/chat")
async def chat(req: ChatRequest):
    payload = {
        "model": MODEL,
        "messages": [m.model_dump() for m in req.messages],
        "stream": False,
        "options": {"temperature": req.temperature, "num_predict": req.max_tokens},
    }
    start = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=180) as client:
            r = await client.post(f"{OLLAMA_URL}/api/chat", json=payload)
            r.raise_for_status()
    except httpx.HTTPError as e:
        log.error(json.dumps({"event": "inference_error", "error": str(e)}))
        raise HTTPException(status_code=502, detail="Inference service unavailable")

    data = r.json()
    latency_ms = round((time.perf_counter() - start) * 1000)
    out_tokens = data.get("eval_count", 0)
    # Structured log line -> CloudWatch metric filters can extract latency/tokens
    log.info(json.dumps({"event": "chat", "latency_ms": latency_ms, "output_tokens": out_tokens}))
    return {"reply": data["message"]["content"], "latency_ms": latency_ms, "output_tokens": out_tokens}


@app.post("/api/export")
def export_conversation(req: ChatRequest):
    if not s3:
        raise HTTPException(status_code=400, detail="S3 export is not configured")
    key = f"conversations/{time.strftime('%Y/%m/%d')}/{uuid.uuid4()}.json"
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=json.dumps(req.model_dump(), ensure_ascii=False).encode("utf-8"),
        ContentType="application/json",
    )
    log.info(json.dumps({"event": "export", "key": key}))
    return {"bucket": S3_BUCKET, "key": key}


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")
