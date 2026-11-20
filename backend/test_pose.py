

import cv2
from pose_detector import PoseDetector

video_path = r"C:\Users\obaid\Downloads\WhatsApp Video 2026-11-18 at 3.32.56 AM.mp4"

cap = cv2.VideoCapture(video_path)
detector = PoseDetector()

try:
    for second in range(1, 11):
        cap.set(cv2.CAP_PROP_POS_MSEC, second * 1000)
        ret, frame = cap.read()

        if ret:
            result = detector.detect_pose(
                frame,
                second * 1000
            )

            print(
                f"Second {second}: "
                f"Detected={result['detected']}, "
                f"Landmarks={len(result['landmarks'])}"
            )

            if result["detected"] and second == 1:
                print("\nFirst frame landmark names:")

                for landmark in result["landmarks"]:
                    print(landmark)

finally:
    detector.close()
    cap.release()
