# BRT Role-Based Management System

## Overview

This is a complete Flask and SQLite web application built around the project ERD. It supports three separate roles:

1. Admin
2. Driver
3. Passenger/User

Each role has its own login page and dashboard. The frontend is designed for normal users and does not expose raw database tables, SQL queries, triggers, or internal schema details.

## Folder Structure

```text
.
├── app.py
├── group13.sql
├── index.html
├── passenger_login.html
├── passenger_signup.html
├── admin_login.html
├── driver_login.html
├── passenger_dashboard.html
├── admin_dashboard.html
├── driver_dashboard.html
├── requirements.txt
└── README.md
```

## Role Features

### Passenger/User

- Separate passenger login and signup
- Trip planner using stations and routes
- Fare calculation
- Ticket booking
- Balance and recent tickets
- Notifications
- Complaint submission

### Driver

- Separate driver login
- Assigned schedules
- Route and bus details
- Status update for schedules

### Admin

- Separate admin login
- System overview
- Route, bus, driver, passenger, ticket, recharge, complaint, and notification summaries
- Complaint response
- Bus status update
- Passenger notification sending

## Database

The database is implemented in `group13.sql` and follows the ERD entities:

- Passenger
- Admin
- Bus
- Driver
- Route
- Station
- Route_Station
- Schedule
- Ticket
- Recharge
- Complaint
- Notification

The app creates `database.db` automatically from `group13.sql` when needed.

## Run Locally

Install dependencies:

```bash
pip install -r requirements.txt
```

Run the app:

```bash
python app.py
```

On Windows you can use:

```powershell
py app.py
```

Open:

```text
http://127.0.0.1:5000
```

If you changed the SQL file and need fresh seed data, delete `database.db` and restart the app.

## Demo Logins

Passenger:

```text
Username: demo
Password: demo123
```

Admin:

```text
Email: admin@brt.local
Password: admin123
```

Driver:

```text
License Number: BRT-PWR-001
Password: driver123
```

## Notes

- Backend APIs perform all database operations.
- Passwords are stored as Werkzeug password hashes.
- Frontend screens show user-friendly transportation features, not raw database internals.
