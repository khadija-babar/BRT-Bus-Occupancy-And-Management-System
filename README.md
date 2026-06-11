# 🚌 BRT Bus Occupancy & Management System

A full-stack web application that combines **real-time AI-powered bus occupancy detection** with a **role-based fleet management platform** for Bus Rapid Transit (BRT) systems.

---

## Overview

This project addresses a common challenge in public transit — knowing how crowded a bus is before you board. It uses **YOLOv8 computer vision models** to analyze onboard video feeds, count passengers, detect posture (standing vs. seated), and expose that data through a live web dashboard.

Alongside the vision pipeline, a complete **Flask + SQLite** backend handles three distinct user roles — Passenger, Driver, and Admin — each with their own login flow and feature set.

---

## Features

### 🎥 AI Occupancy Detection
- Person detection via **YOLOv8n** with ByteTrack multi-object tracking
- Posture classification (standing / seated) using **YOLOv8n-pose** keypoint analysis
- Per-bus analysis for male, female, or combined sections
- Annotated snapshot saved per analysis run
- Occupancy percentage and available seat count computed automatically

### 👤 Passenger
- Register and log in with a personal account
- Plan trips using routes and stations
- Calculate fares and book tickets
- View balance, recent tickets, and notifications
- Submit complaints

### 🚗 Driver
- Log in with license number
- View assigned schedules, routes, and bus details
- Update schedule status

### 🛠️ Admin
- System-wide dashboard with fleet overview
- Manage routes, buses, drivers, passengers, tickets, recharges, complaints, and notifications
- Respond to complaints
- Update bus status
- Send notifications to passengers

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Python, Flask |
| Database | SQLite |
| Computer Vision | YOLOv8n (detection), YOLOv8n-pose (pose estimation) |
| Tracking | ByteTrack (via Ultralytics) |
| Video Processing | OpenCV |
| Auth | Werkzeug password hashing |
| Frontend | HTML, CSS, JavaScript |

---

## Project Structure

```
BRT-Bus-Occupancy/
├── app.py                    # Flask application & all API routes
├── Bus_Project.py            # YOLOv8 video analysis pipeline
├── bus_videos.py             # Bus → video file mapping
├── brt_database.sql          # SQLite schema and seed data
├── requirements.txt
├── yolov8n.pt                # YOLOv8 detection model weights
├── yolov8n-pose.pt           # YOLOv8 pose estimation weights
├── ui.html/
│   ├── index.html
│   ├── passenger_login.html
│   ├── passenger_signup.html
│   ├── passenger_dashboard.html
│   ├── admin_login.html
│   ├── admin_dashboard.html
│   ├── driver_login.html
│   └── driver_dashboard.html
└── snapshots detection/
    ├── snapshot_Male.jpg
    ├── snapshot_Female.jpg
    └── snapshot_Combined.jpg
```

---

## Getting Started

### Prerequisites

- Python 3.9+
- pip

### Installation

```bash
git clone https://github.com/your-username/BRT-Bus-Occupancy.git
cd BRT-Bus-Occupancy
pip install -r requirements.txt
```

### Run

```bash
python app.py
# or on Windows:
py app.py
```

Then open your browser at:

```
http://127.0.0.1:5000
```

> If you modify the SQL file and need fresh seed data, delete `database.db` and restart the app — it will be recreated automatically.

---

## Demo Credentials

| Role | Field | Value |
|---|---|---|
| Passenger | Username | `demo` |
| | Password | `demo123` |
| Admin | Email | `admin@brt.local` |
| | Password | `admin123` |
| Driver | License No. | `BRT-PWR-001` |
| | Password | `driver123` |

---

## How the Occupancy Detection Works

1. A video clip for the target bus is resolved from `bus_videos.py`
2. The clip is processed frame-by-frame using **YOLOv8n + ByteTrack** to count unique passengers across the video
3. On the final frame, **YOLOv8n-pose** estimates each person's keypoints to determine if they are standing or seated
4. Results (total count, standing, seated, occupancy %, available seats) are returned as a JSON payload and displayed on the dashboard
5. An annotated snapshot is saved to disk for reference

To run the detection pipeline standalone (CLI):

```bash
python Bus_Project.py
```

You will be prompted to enter a bus number and choose male / female / both section analysis.

---

## Database Schema

The SQLite database covers the following entities:

`Passenger` · `Admin` · `Bus` · `Driver` · `Route` · `Station` · `Route_Station` · `Schedule` · `Ticket` · `Recharge` · `Complaint` · `Notification`

---

## Notes

- All passwords are stored as Werkzeug-generated hashes — never in plaintext.
- The frontend is designed for end users and does not expose raw SQL, schema details, or internal triggers.
- The vision models (`yolov8n.pt`, `yolov8n-pose.pt`) are included in the repo for convenience; they are standard Ultralytics weights.
