


import os
import tempfile

import cv2
from fastapi import FastAPI, UploadFile, File, HTTPException
from pose_detector import PoseDetector

app = FastAPI(
    title="Batting Analyzer API",
    description="Backend API for AI-powered cricket batting analysis",
    version="1.0.0"
)


@app.get("/")
def home():
    return {
        "message": "Batting Analyzer API is running!",
        "status": "success"
    }


@app.get("/health")
def health_check():
    return {"status": "healthy"}


@app.post("/analyze-video")
async def analyze_video(file: UploadFile = File(...)):

    if not file.content_type or not file.content_type.startswith("video/"):
        raise HTTPException(
            status_code=400,
            detail="Please upload a valid video file."
        )

    temp_path = None
    cap = None
    detector = None

    try:
        with tempfile.NamedTemporaryFile(
            delete=False,
            suffix=".mp4"
        ) as temp_file:
            temp_path = temp_file.name

            while True:
                chunk = await file.read(1024 * 1024)

                if not chunk:
                    break

                temp_file.write(chunk)

        cap = cv2.VideoCapture(temp_path)

        if not cap.isOpened():
            raise HTTPException(
                status_code=400,
                detail="Unable to read this video."
            )

        fps = cap.get(cv2.CAP_PROP_FPS)
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

        if fps <= 0 or total_frames <= 0:
            raise HTTPException(
                status_code=400,
                detail="Invalid video information."
            )

        duration = total_frames / fps

        if duration > 120:
            raise HTTPException(
                status_code=400,
                detail="Video must not exceed 2 minutes."
            )

        detector = PoseDetector()

        sampled_frames = 0
        detected_frames = 0
        frame_interval = max(int(fps), 1)

        pose_frames = []

        for frame_number in range(0, total_frames, frame_interval):

            cap.set(cv2.CAP_PROP_POS_FRAMES, frame_number)
            success, frame = cap.read()

            if not success:
                break

            timestamp_ms = int((frame_number / fps) * 1000)

            pose_result = detector.detect_pose(
                frame,
                timestamp_ms
            )

            sampled_frames += 1

            if pose_result["detected"]:
                detected_frames += 1

                pose_frames.append({
                    "timestamp_ms": timestamp_ms,
                    "landmarks": pose_result["landmarks"]
                })

        return {
            "status": "success",
            "filename": file.filename,
            "duration_seconds": round(duration, 2),
            "fps": round(fps, 2),
            "total_frames": total_frames,
            "sampled_frames": sampled_frames,
            "pose_detected_frames": detected_frames,
            "pose_not_detected_frames": (
                sampled_frames - detected_frames
            ),
            "pose_frames": pose_frames,
            "message": "Video processed with pose detection."
        }

    finally:
        if detector is not None:
            detector.close()

        if cap is not None:
            cap.release()

        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)

        await file.close()
