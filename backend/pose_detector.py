

import os
import cv2
import mediapipe as mp

MODEL_PATH = os.path.join(
    os.path.dirname(__file__),
    "models",
    "pose_landmarker_lite.task"
)

POSE_LANDMARK_NAMES = [
    "nose",
    "left_eye_inner",
    "left_eye",
    "left_eye_outer",
    "right_eye_inner",
    "right_eye",
    "right_eye_outer",
    "left_ear",
    "right_ear",
    "mouth_left",
    "mouth_right",
    "left_shoulder",
    "right_shoulder",
    "left_elbow",
    "right_elbow",
    "left_wrist",
    "right_wrist",
    "left_pinky",
    "right_pinky",
    "left_index",
    "right_index",
    "left_thumb",
    "right_thumb",
    "left_hip",
    "right_hip",
    "left_knee",
    "right_knee",
    "left_ankle",
    "right_ankle",
    "left_heel",
    "right_heel",
    "left_foot_index",
    "right_foot_index"
]


class PoseDetector:

    def __init__(self):
        if not os.path.exists(MODEL_PATH):
            raise FileNotFoundError("Pose model file not found.")

        options = mp.tasks.vision.PoseLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(
                model_asset_path=MODEL_PATH
            ),
            running_mode=mp.tasks.vision.RunningMode.VIDEO,
            num_poses=1,
            min_pose_detection_confidence=0.5,
            min_pose_presence_confidence=0.5,
            min_tracking_confidence=0.5
        )

        self.landmarker = (
            mp.tasks.vision.PoseLandmarker.create_from_options(options)
        )

        self.last_timestamp_ms = -1

    def detect_pose(self, frame, timestamp_ms):

        if frame is None:
            return {
                "detected": False,
                "landmarks": []
            }

        height, width, _ = frame.shape

        timestamp_ms = max(
            int(timestamp_ms),
            self.last_timestamp_ms + 1
        )

        self.last_timestamp_ms = timestamp_ms

        rgb_frame = cv2.cvtColor(
            frame,
            cv2.COLOR_BGR2RGB
        )

        mp_image = mp.Image(
            image_format=mp.ImageFormat.SRGB,
            data=rgb_frame
        )

        result = self.landmarker.detect_for_video(
            mp_image,
            timestamp_ms
        )

        if not result.pose_landmarks:
            return {
                "detected": False,
                "landmarks": []
            }

        landmarks = []

        for index, landmark in enumerate(result.pose_landmarks[0]):
            landmarks.append({
                "name": POSE_LANDMARK_NAMES[index],
                "x": round(landmark.x * width, 2),
                "y": round(landmark.y * height, 2),
                "z": round(landmark.z, 4),
                "visibility": round(landmark.visibility, 4)
            })

        return {
            "detected": True,
            "landmarks": landmarks
        }

    def close(self):
        self.landmarker.close()