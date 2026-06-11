import cv2
from ultralytics import YOLO

from bus_videos import BUS_VIDEO_MAP

# -----------------------------------------------
# Load Models
# -----------------------------------------------
detection_model = YOLO("yolov8n.pt")
pose_model      = YOLO("yolov8n-pose.pt")

# -----------------------------------------------
# POSTURE DETECTION (ONLY detect standing reliably)
# -----------------------------------------------
def detect_posture(frame, x1, y1, x2, y2):
    crop = frame[y1:y2, x1:x2]

    if crop.size == 0:
        return "unknown"

    results = pose_model(crop, verbose=False)

    if not results or results[0].keypoints is None:
        return "unknown"

    kp   = results[0].keypoints.xy
    conf = results[0].keypoints.conf

    if kp is None or len(kp) == 0:
        return "unknown"

    keypoints = kp[0]
    confidences = conf[0] if conf is not None else None

    if len(keypoints) < 17:
        return "unknown"

    def get_y(i): return float(keypoints[i][1])
    def get_conf(i): return float(confidences[i]) if confidences is not None else 1.0

    CONF = 0.3

    # Only check if clearly standing
    if not (get_conf(11)>CONF and get_conf(13)>CONF and get_conf(15)>CONF):
        return "unknown"

    hip   = get_y(11)
    knee  = get_y(13)
    ankle = get_y(15)

    if knee - hip <= 0:
        return "unknown"

    ratio = (ankle - knee) / (knee - hip)

    # Only confidently label standing
    return "standing" if ratio >= 0.75 else "unknown"

# -----------------------------------------------
# HYBRID PROCESSING
# -----------------------------------------------
def process_video_hybrid(video_path, label, seconds=3, bus_capacity=80):
    print(f"\nProcessing {label} video (HYBRID mode {seconds}s)...")

    cap = cv2.VideoCapture(video_path)

    if not cap.isOpened():
        print("Error opening video")
        return {
            "analysis_type": label.lower(),
            "analysis_mode": label.lower(),
            "seconds_analyzed": seconds,
            "people_count": 0,
            "standing": 0,
            "seated": 0,
            "capacity": bus_capacity,
            "available_seats": bus_capacity,
            "occupancy_percent": 0,
            "sampled_frames": 0,
            "snapshot_path": None,
        }

    fps = cap.get(cv2.CAP_PROP_FPS)
    max_frames = int(fps * seconds)

    frame_count = 0
    unique_ids = set()
    last_frame = None

    print("Tracking passengers (fast)...")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame_count += 1
        if frame_count > max_frames:
            break

        if frame_count % 10 != 0:
            continue

        results = detection_model.track(
            frame,
            tracker="bytetrack.yaml",
            persist=True,
            verbose=False
        )

        if results[0].boxes.id is not None:
            for track_id, cls in zip(results[0].boxes.id, results[0].boxes.cls):
                if detection_model.names[int(cls)] == "person":
                    unique_ids.add(int(track_id))

        last_frame = frame.copy()

    cap.release()

    if last_frame is None:
        print("No frame captured")
        return {
            "analysis_type": label.lower(),
            "analysis_mode": label.lower(),
            "seconds_analyzed": seconds,
            "people_count": 0,
            "standing": 0,
            "seated": 0,
            "capacity": bus_capacity,
            "available_seats": bus_capacity,
            "occupancy_percent": 0,
            "sampled_frames": frame_count,
            "snapshot_path": None,
        }

    print("Running posture analysis on snapshot...")

    # -----------------------------------------------
    # SNAPSHOT ANALYSIS
    # -----------------------------------------------
    results = detection_model(last_frame, verbose=False)

    standing = 0
    annotated = last_frame.copy()

    if results[0].boxes is None:
        print("No persons detected")
        return {
            "analysis_type": label.lower(),
            "analysis_mode": label.lower(),
            "seconds_analyzed": seconds,
            "people_count": 0,
            "standing": 0,
            "seated": 0,
            "capacity": bus_capacity,
            "available_seats": bus_capacity,
            "occupancy_percent": 0,
            "sampled_frames": frame_count,
            "snapshot_path": None,
        }

    for box, cls in zip(results[0].boxes.xyxy, results[0].boxes.cls):
        if detection_model.names[int(cls)] != "person":
            continue

        x1, y1, x2, y2 = map(int, box)

        posture = detect_posture(last_frame, x1, y1, x2, y2)

        if posture == "standing":
            standing += 1
            color = (0, 0, 255)
        else:
            color = (0, 255, 0)  # assumed seated

        cv2.rectangle(annotated, (x1,y1), (x2,y2), color, 2)

    # -----------------------------------------------
    # FINAL LOGIC CHANGE HERE
    # -----------------------------------------------
    total_unique = len(unique_ids)
    seated = total_unique - standing

    # Safety clamp
    if seated < 0:
        seated = 0

    # Save snapshot
    snapshot_path = f"snapshot_{label}.jpg"
    cv2.imwrite(snapshot_path, annotated)

    available_seats = max(bus_capacity - total_unique, 0)
    occupancy_percent = round((total_unique * 100.0) / bus_capacity, 0) if bus_capacity else 0

    print(f"\n===== {label.upper()} HYBRID RESULT =====")
    print(f"Seconds Analysed        : {seconds}")
    print(f"Total Unique Passengers : {total_unique}")
    print(f"Standing                : {standing}")
    print(f"Seated (derived)        : {seated}")
    print(f"Snapshot saved as       : {snapshot_path}")

    return {
        "analysis_type": label.lower(),
        "analysis_mode": label.lower(),
        "seconds_analyzed": seconds,
        "people_count": total_unique,
        "standing": standing,
        "seated": seated,
        "capacity": bus_capacity,
        "available_seats": available_seats,
        "occupancy_percent": occupancy_percent,
        "sampled_frames": frame_count,
        "snapshot_path": snapshot_path,
    }


def analyze_video_capacity(video_path, bus_capacity=80, analysis_mode="combined"):
    label = {
        "male": "Male",
        "female": "Female",
        "combined": "Combined",
    }.get((analysis_mode or "combined").lower(), "Combined")
    return process_video_hybrid(video_path, label, seconds=3, bus_capacity=bus_capacity)


def _relative_clip_for_bus(bus_number, analysis_mode="combined"):
    """Resolve bus_videos dict entry to one filename for this CLI run."""
    entry = BUS_VIDEO_MAP.get(bus_number)
    if not isinstance(entry, dict):
        return None
    male = entry.get('male')
    female = entry.get('female')
    if not male or not female or male == female:
        return None
    mode = (analysis_mode or 'combined').lower()
    if mode == 'male':
        return male
    if mode == 'female':
        return female
    combined = entry.get('combined')
    if combined:
        return combined
    print('Note: no "combined" clip in bus_videos.py; using male-section clip for combined run.')
    return male


def analyze_bus_video_capacity(bus_number, bus_capacity=80, analysis_mode="combined"):
    rel = _relative_clip_for_bus(bus_number, analysis_mode=analysis_mode)
    if not rel:
        print("No video assigned to this bus.")
        return None
    return analyze_video_capacity(rel, bus_capacity=bus_capacity, analysis_mode=analysis_mode)


if __name__ == "__main__":
    # -----------------------------------------------
    # USER INPUT
    # -----------------------------------------------
    print("Which bus do you want to analyse?")
    for bus_number, video_entry in BUS_VIDEO_MAP.items():
        if isinstance(video_entry, dict):
            c = video_entry.get('combined')
            extra = f" + combined={c}" if c else ''
            print(f"{bus_number}: male={video_entry.get('male')} | female={video_entry.get('female')}{extra}")
        else:
            print(f"{bus_number}: (invalid entry — use dict with male and female in bus_videos.py)")

    bus_number = input("\nEnter bus number (example B-001): ").strip().upper()

    print("Which result do you want to see?")
    print("1. Male")
    print("2. Female")
    print("3. Both")

    choice = input("\nEnter your choice (1 / 2 / 3): ").strip()

    # -----------------------------------------------
    # RUN
    # -----------------------------------------------
    if choice == "1":
        analyze_bus_video_capacity(bus_number, analysis_mode="male")

    elif choice == "2":
        analyze_bus_video_capacity(bus_number, analysis_mode="female")

    elif choice == "3":
        analyze_bus_video_capacity(bus_number, analysis_mode="combined")

    else:
        print("Invalid choice.")