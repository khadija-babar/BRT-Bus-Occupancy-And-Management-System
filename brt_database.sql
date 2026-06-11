PRAGMA foreign_keys = ON;
-- SQLite disables foreign keys by default.
-- This line turns them ON so that all FOREIGN KEY constraints are actually enforced.
-- Without this, you could insert invalid foreign key values without any error.

-- ============================================================
-- STEP 1: CLEANUP — Drop everything before rebuilding.
-- Views must be dropped first because they depend on tables.
-- Triggers must be dropped before their tables too.
-- Tables are dropped in reverse dependency order:
--   child tables first, then parent tables.
-- IF EXISTS prevents errors if the object doesn't exist yet.
-- ============================================================

-- Rebuild the academic demo database from a clean state.
DROP VIEW IF EXISTS v_passenger_recharge_summary;   -- depends on Passenger + Recharge
DROP VIEW IF EXISTS v_open_complaints;              -- depends on Complaint + Passenger + Admin
DROP VIEW IF EXISTS v_route_stations;               -- depends on Route + Route_Station + Station
DROP VIEW IF EXISTS v_passenger_tickets;            -- depends on Passenger + Ticket + Schedule + Route
DROP VIEW IF EXISTS v_active_schedules;             -- depends on Schedule + Bus + Route + Driver

DROP TRIGGER IF EXISTS trg_complaint_updated;       -- fires on Complaint table
DROP TRIGGER IF EXISTS trg_schedule_updated;        -- fires on Schedule table
DROP TRIGGER IF EXISTS trg_route_updated;           -- fires on Route table
DROP TRIGGER IF EXISTS trg_driver_updated;          -- fires on Driver table
DROP TRIGGER IF EXISTS trg_bus_updated;             -- fires on Bus table
DROP TRIGGER IF EXISTS trg_passenger_updated;       -- fires on Passenger table

-- Drop tables in child-first order to respect foreign key dependencies.
-- e.g. Notification references Passenger, so Notification is dropped first.
DROP TABLE IF EXISTS Notification;
DROP TABLE IF EXISTS Complaint;
DROP TABLE IF EXISTS Recharge;
DROP TABLE IF EXISTS Ticket;
DROP TABLE IF EXISTS Schedule;
DROP TABLE IF EXISTS Route_Station;  -- junction table dropped before Route and Station
DROP TABLE IF EXISTS Station;
DROP TABLE IF EXISTS Route;
DROP TABLE IF EXISTS Driver;
DROP TABLE IF EXISTS Bus;
DROP TABLE IF EXISTS Admin;
DROP TABLE IF EXISTS Passenger;      -- parent of most tables, dropped last

-- ============================================================
-- STEP 2: DDL — CREATE TABLES
-- DDL = Data Definition Language (CREATE, DROP, ALTER)
-- Each table defines its structure, data types, constraints,
-- and relationships to other tables.
-- ============================================================

-- TABLE: Passenger
-- Stores registered passenger accounts.
-- Each passenger has a unique email and a card_balance for fare payments.
CREATE TABLE Passenger (
    passenger_id    INTEGER PRIMARY KEY AUTOINCREMENT,  -- unique ID, auto-assigned by SQLite
    name            TEXT    NOT NULL,                   -- passenger's full name, cannot be empty
    email           TEXT    UNIQUE NOT NULL,            -- must be unique across all passengers (used for login)
    phone_number    TEXT,                               -- optional phone number (no NOT NULL = nullable)
    password        TEXT    NOT NULL,                   -- stored as a scrypt hash, never plain text
    card_balance    REAL    DEFAULT 0.0,                -- wallet balance for ticket payments; starts at 0
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- auto-set when row is inserted
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP  -- auto-updated by trigger trg_passenger_updated
);

-- TABLE: Admin
-- Stores system administrator accounts.
-- Admins manage complaints, send notifications, and oversee the system.
CREATE TABLE Admin (
    admin_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    email       TEXT UNIQUE NOT NULL,   -- admin login identifier; must be unique
    password    TEXT NOT NULL,          -- scrypt hashed password
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- TABLE: Bus
-- Stores the BRT bus fleet.
-- Tracks type, capacity, live passenger count, and operational status.
CREATE TABLE Bus (
    bus_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    bus_number  TEXT UNIQUE NOT NULL,   -- e.g. 'B-001'; each bus has a unique number
    bus_type    TEXT NOT NULL CHECK(bus_type IN ('standard', 'express')),
    -- CHECK constraint: bus_type can only be 'standard' or 'express', nothing else
    capacity    INTEGER NOT NULL DEFAULT 80 CHECK(capacity > 0),
    -- capacity must be a positive number; defaults to 80 seats
    current_passengers INTEGER NOT NULL DEFAULT 0 CHECK(current_passengers >= 0),
    -- cannot be negative; represents live headcount on the bus
    status      TEXT DEFAULT 'active' CHECK(status IN ('active', 'maintenance', 'inactive')),
    -- only 3 allowed statuses for a bus
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CHECK(current_passengers <= capacity)
    -- TABLE-LEVEL CHECK: involves two columns together.
    -- Prevents overbooking — passengers on bus can never exceed its capacity.
    -- This cannot be written as a column-level constraint because it compares two columns.
);

-- TABLE: Driver
-- Stores BRT driver records including license number used for login.
CREATE TABLE Driver (
    driver_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    phone_number    TEXT,               -- optional
    license_number  TEXT UNIQUE NOT NULL,  -- used as driver login identifier; must be unique
    password        TEXT NOT NULL,
    status          TEXT DEFAULT 'active' CHECK(status IN ('active', 'inactive', 'on_leave')),
    -- driver can only be in one of these 3 states
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- TABLE: Route
-- Stores all BRT routes with fare rules, frequency (headway), and platform info.
CREATE TABLE Route (
    route_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    route_code  TEXT UNIQUE NOT NULL,   -- e.g. 'ER01', 'SR02' — short code for the route
    route_name  TEXT NOT NULL,          -- full human-readable name
    route_type  TEXT NOT NULL CHECK(route_type IN ('standard', 'express')),
    total_stops INTEGER NOT NULL,       -- total number of stops on this route
    direction   TEXT NOT NULL CHECK(direction IN ('Inbound', 'Outbound')),
    -- direction of travel; only these two values allowed
    platform    TEXT NOT NULL,          -- platform number at the BRT station
    headway_min INTEGER NOT NULL CHECK(headway_min > 0),
    -- minimum wait time (minutes) between buses on this route
    headway_max INTEGER NOT NULL CHECK(headway_max >= headway_min),
    -- maximum wait time; must be >= headway_min (ensures logical range)
    fare_per_stop REAL NOT NULL DEFAULT 10 CHECK(fare_per_stop > 0),
    -- fare charged per stop travelled; default Rs. 10
    distance_per_stop_km REAL NOT NULL DEFAULT 1.5 CHECK(distance_per_stop_km > 0),
    -- approximate km distance per stop; used for travel distance calculation
    minutes_per_stop INTEGER NOT NULL DEFAULT 2 CHECK(minutes_per_stop > 0),
    -- estimated travel time per stop in minutes
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- TABLE: Station
-- Stores individual BRT stations (bus stops).
-- A station is independent of any route; routes link to stations via Route_Station.
CREATE TABLE Station (
    station_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    station_name    TEXT UNIQUE NOT NULL,   -- e.g. 'Chamkani'; no two stations have same name
    location_area   TEXT,                   -- optional area description
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- TABLE: Route_Station
-- JUNCTION TABLE: resolves the many-to-many relationship between Route and Station.
-- One route has many stations; one station can appear on many routes.
-- Also stores stop_order so we know the sequence of stops on each route.
-- route_station_id added as surrogate PK (was missing in ERD v1)
CREATE TABLE Route_Station (
    route_station_id    INTEGER PRIMARY KEY AUTOINCREMENT,  -- surrogate PK added for convenience
    route_id            INTEGER NOT NULL,
    station_id          INTEGER NOT NULL,
    stop_order          INTEGER NOT NULL,   -- position of this station on the route (1 = first stop)
    UNIQUE(route_id, station_id),
    -- COMPOSITE UNIQUE: the same station cannot appear twice on the same route
    FOREIGN KEY (route_id)   REFERENCES Route(route_id)     ON DELETE CASCADE,
    -- if a Route is deleted, all its Route_Station rows are automatically deleted too
    FOREIGN KEY (station_id) REFERENCES Station(station_id) ON DELETE CASCADE
    -- if a Station is deleted, its entries in Route_Station are also deleted
);

-- TABLE: Schedule
-- Links a Bus, a Route, and a Driver together for a specific trip.
-- NOTE: ticket_id has been REMOVED to break the circular FK
-- with Ticket. Relationship is now: Ticket.schedule_id -> Schedule
-- (Circular FKs cause insertion deadlocks — you can't insert A without B and B without A)
CREATE TABLE Schedule (
    schedule_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    bus_id              INTEGER NOT NULL,   -- which bus is assigned
    route_id            INTEGER NOT NULL,   -- which route it runs
    driver_id           INTEGER NOT NULL,   -- which driver is driving
    departure_time      TEXT NOT NULL,      -- e.g. '07:00'
    arrival_time        TEXT NOT NULL,      -- e.g. '07:45'
    actual_arrival_time TEXT,              -- filled in after trip completes; nullable
    operating_days      TEXT,              -- e.g. 'Daily', 'Mon-Fri'; free text
    status              TEXT DEFAULT 'scheduled'
                             CHECK(status IN ('scheduled', 'active', 'delayed', 'cancelled')),
    -- schedule can only be in one of these 4 states
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (bus_id)    REFERENCES Bus(bus_id)       ON DELETE RESTRICT,
    -- RESTRICT: cannot delete a Bus if it has schedules referencing it
    FOREIGN KEY (route_id)  REFERENCES Route(route_id)   ON DELETE RESTRICT,
    -- RESTRICT: cannot delete a Route if it has active schedules
    FOREIGN KEY (driver_id) REFERENCES Driver(driver_id) ON DELETE RESTRICT
    -- RESTRICT: cannot delete a Driver who is assigned to a schedule
);

-- TABLE: Ticket
-- Stores a ticket purchased by a passenger for a specific schedule.
-- schedule_id FK added here (one Schedule -> many Tickets)
-- This replaces the removed ticket_id on Schedule
CREATE TABLE Ticket (
    ticket_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    passenger_id    INTEGER NOT NULL,   -- which passenger bought this ticket
    schedule_id     INTEGER,            -- which schedule (trip) this ticket is for; nullable
    purchase_time   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,  -- when the ticket was bought
    status          TEXT DEFAULT 'active' CHECK(status IN ('active', 'used', 'cancelled')),
    -- ticket lifecycle: active -> used after travel, or cancelled if refunded
    fixed_fare      REAL NOT NULL,      -- fare at time of purchase (stored so future fare changes don't affect old tickets)
    start_station   TEXT,               -- boarding station name (stored as text for simplicity)
    end_station     TEXT,               -- destination station name
    FOREIGN KEY (passenger_id) REFERENCES Passenger(passenger_id) ON DELETE CASCADE,
    -- if a Passenger is deleted, all their tickets are deleted too
    FOREIGN KEY (schedule_id)  REFERENCES Schedule(schedule_id)   ON DELETE SET NULL
    -- SET NULL: if the schedule is deleted, ticket remains but schedule_id becomes NULL
    -- (ticket history is preserved even if the schedule no longer exists)
);

-- TABLE: Recharge
-- Records every top-up transaction on a passenger's card balance.
CREATE TABLE Recharge (
    recharge_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    passenger_id    INTEGER NOT NULL,
    amount          REAL NOT NULL CHECK(amount > 0),
    -- recharge amount must be positive; cannot top up zero or negative
    payment_method  TEXT NOT NULL CHECK(payment_method IN ('EasyPaisa', 'JazzCash', 'card', 'cash')),
    -- only these 4 payment methods are accepted
    recharge_time   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status          TEXT DEFAULT 'pending' CHECK(status IN ('pending', 'success', 'failed')),
    -- starts as 'pending', updated to 'success' or 'failed' after payment processing
    FOREIGN KEY (passenger_id) REFERENCES Passenger(passenger_id) ON DELETE CASCADE
    -- if passenger account is deleted, their recharge history is deleted too
);

-- TABLE: Complaint
-- Stores complaints submitted by passengers.
-- admin_id is nullable — complaint may not yet be assigned to an admin.
CREATE TABLE Complaint (
    complaint_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    passenger_id    INTEGER NOT NULL,   -- who filed the complaint
    admin_id        INTEGER,            -- which admin is handling it (NULL if unassigned)
    complaint_text  TEXT NOT NULL,      -- the actual complaint content
    status          TEXT DEFAULT 'open' CHECK(status IN ('open', 'in_progress', 'resolved')),
    -- complaint lifecycle: open -> in_progress (admin picks it up) -> resolved
    response_text   TEXT,              -- admin's reply; NULL until admin responds
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (passenger_id) REFERENCES Passenger(passenger_id) ON DELETE CASCADE,
    FOREIGN KEY (admin_id)     REFERENCES Admin(admin_id)         ON DELETE SET NULL
    -- SET NULL: if admin account is deleted, complaint stays but admin_id becomes NULL
);

-- TABLE: Notification
-- Stores messages sent to passengers (e.g. ticket confirmations, admin alerts).
-- is_read column added (was missing in ERD v1)
CREATE TABLE Notification (
    notification_id INTEGER PRIMARY KEY AUTOINCREMENT,
    admin_id        INTEGER,            -- which admin sent it (NULL if system-generated)
    passenger_id    INTEGER NOT NULL,   -- which passenger receives this notification
    message         TEXT NOT NULL,      -- notification content
    type            TEXT,              -- e.g. 'ticket', 'alert'; free text category
    is_read         INTEGER DEFAULT 0 CHECK(is_read IN (0, 1)),
    -- SQLite has no BOOLEAN type; 0 = unread, 1 = read (simulated boolean)
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (admin_id)     REFERENCES Admin(admin_id)         ON DELETE SET NULL,
    FOREIGN KEY (passenger_id) REFERENCES Passenger(passenger_id) ON DELETE CASCADE
);

-- ============================================================
-- STEP 3: INDEXES
-- Indexes speed up SELECT queries on frequently searched columns.
-- Without an index, SQLite does a full table scan (reads every row).
-- With an index, it jumps directly to matching rows like a book index.
-- Trade-off: indexes use extra storage and slightly slow down INSERTs/UPDATEs.
-- ============================================================

CREATE INDEX idx_passenger_email       ON Passenger(email);
-- speeds up login queries: WHERE email = 'user@example.com'

CREATE INDEX idx_bus_status            ON Bus(status);
-- speeds up filtering active/inactive buses

CREATE INDEX idx_driver_status         ON Driver(status);
-- speeds up queries for active drivers

CREATE INDEX idx_route_type            ON Route(route_type);
-- speeds up filtering standard vs express routes

CREATE INDEX idx_route_station_route   ON Route_Station(route_id);
-- speeds up: "find all stations for a given route"

CREATE INDEX idx_route_station_station ON Route_Station(station_id);
-- speeds up: "find all routes passing through a given station"

CREATE INDEX idx_schedule_route        ON Schedule(route_id);
CREATE INDEX idx_schedule_bus          ON Schedule(bus_id);
CREATE INDEX idx_schedule_driver       ON Schedule(driver_id);
-- these 3 speed up joins between Schedule and Route/Bus/Driver

CREATE INDEX idx_schedule_departure    ON Schedule(departure_time);
-- speeds up sorting/filtering schedules by departure time

CREATE INDEX idx_schedule_status       ON Schedule(status);
-- speeds up: WHERE status IN ('scheduled', 'active')

CREATE INDEX idx_ticket_passenger      ON Ticket(passenger_id);
-- speeds up: "find all tickets for a passenger"

CREATE INDEX idx_ticket_schedule       ON Ticket(schedule_id);
-- speeds up joining tickets to their schedule

CREATE INDEX idx_ticket_status         ON Ticket(status);
-- speeds up filtering active/used/cancelled tickets

CREATE INDEX idx_recharge_passenger    ON Recharge(passenger_id);
-- speeds up: "find all recharges for a passenger"

CREATE INDEX idx_recharge_status       ON Recharge(status);
-- speeds up filtering successful recharges

CREATE INDEX idx_complaint_passenger   ON Complaint(passenger_id);
-- speeds up: "find all complaints by a passenger"

CREATE INDEX idx_complaint_status      ON Complaint(status);
-- speeds up filtering open/in_progress complaints

CREATE INDEX idx_notification_passenger ON Notification(passenger_id);
-- speeds up: "find all notifications for a passenger"

CREATE INDEX idx_notification_created  ON Notification(created_at);
-- speeds up sorting notifications by time (most recent first)

-- ============================================================
-- STEP 4: TRIGGERS
-- Triggers are automatic actions that fire when a DB event occurs.
-- These 6 triggers all fire AFTER UPDATE on their respective tables
-- and automatically set updated_at = current time.
-- NEW refers to the new version of the row being updated.
-- This ensures updated_at is always accurate without the app needing to set it manually.
-- ============================================================

-- TRIGGERS — keep updated_at in sync
CREATE TRIGGER trg_passenger_updated
AFTER UPDATE ON Passenger          -- fires every time any column in Passenger is updated
BEGIN
    UPDATE Passenger SET updated_at = CURRENT_TIMESTAMP
    WHERE passenger_id = NEW.passenger_id;  -- NEW = the row that was just updated
END;

CREATE TRIGGER trg_bus_updated
AFTER UPDATE ON Bus
BEGIN
    UPDATE Bus SET updated_at = CURRENT_TIMESTAMP
    WHERE bus_id = NEW.bus_id;
END;

CREATE TRIGGER trg_driver_updated
AFTER UPDATE ON Driver
BEGIN
    UPDATE Driver SET updated_at = CURRENT_TIMESTAMP
    WHERE driver_id = NEW.driver_id;
END;

CREATE TRIGGER trg_route_updated
AFTER UPDATE ON Route
BEGIN
    UPDATE Route SET updated_at = CURRENT_TIMESTAMP
    WHERE route_id = NEW.route_id;
END;

CREATE TRIGGER trg_schedule_updated
AFTER UPDATE ON Schedule
BEGIN
    UPDATE Schedule SET updated_at = CURRENT_TIMESTAMP
    WHERE schedule_id = NEW.schedule_id;
END;

CREATE TRIGGER trg_complaint_updated
AFTER UPDATE ON Complaint
BEGIN
    UPDATE Complaint SET updated_at = CURRENT_TIMESTAMP
    WHERE complaint_id = NEW.complaint_id;
END;

-- ============================================================
-- STEP 5: VIEWS
-- Views are saved SELECT queries stored in the database.
-- They behave like virtual tables — you query them like a table
-- but they contain no data of their own; data is fetched live from real tables.
-- Benefits: simplify complex joins, reuse query logic, hide complexity from app code.
-- ============================================================

-- VIEWS
-- Active schedules with full join details
-- Joins 4 tables: Schedule, Bus, Route, Driver
-- Filters to only show schedules that are currently running or upcoming
CREATE VIEW v_active_schedules AS
SELECT
    s.schedule_id,
    s.departure_time,
    s.arrival_time,
    s.actual_arrival_time,
    s.operating_days,
    s.status,
    b.bus_number,
    b.bus_type,
    r.route_code,
    r.route_name,
    r.direction,
    r.platform,
    r.headway_min,
    r.headway_max,
    d.name AS driver_name       -- aliased so it doesn't clash with other 'name' columns
FROM Schedule s
JOIN Bus    b ON s.bus_id    = b.bus_id     -- INNER JOIN: schedule must have a valid bus
JOIN Route  r ON s.route_id  = r.route_id   -- INNER JOIN: schedule must have a valid route
JOIN Driver d ON s.driver_id = d.driver_id  -- INNER JOIN: schedule must have a valid driver
WHERE s.status IN ('scheduled', 'active');  -- only show active/upcoming, exclude delayed/cancelled

-- Full ticket history per passenger
-- Uses LEFT JOIN for Schedule and Route so that tickets without a schedule
-- (schedule_id = NULL) still appear in results — we don't lose ticket history
CREATE VIEW v_passenger_tickets AS
SELECT
    p.passenger_id,
    p.name          AS passenger_name,   -- aliased to avoid ambiguity with other name columns
    t.ticket_id,
    t.purchase_time,
    t.status        AS ticket_status,    -- aliased because both Passenger and Ticket have 'status'
    t.fixed_fare,
    s.schedule_id,
    s.departure_time,
    s.arrival_time,
    r.route_code,
    r.route_name,
    t.start_station,
    t.end_station
FROM Passenger p
JOIN Ticket   t ON p.passenger_id  = t.passenger_id   -- INNER JOIN: only passengers who have tickets
LEFT JOIN Schedule s ON t.schedule_id  = s.schedule_id -- LEFT JOIN: ticket stays even if schedule deleted (NULL)
LEFT JOIN Route    r ON s.route_id     = r.route_id;   -- LEFT JOIN: route info shown if available

-- Ordered stations per route
-- Joins Route, Route_Station (junction table), and Station
-- ORDER BY ensures stops appear in correct sequence for each route
CREATE VIEW v_route_stations AS
SELECT
    r.route_id,
    r.route_code,
    r.route_name,
    r.route_type,
    r.direction,
    r.platform,
    r.headway_min,
    r.headway_max,
    r.fare_per_stop,
    st.station_name,
    st.location_area,
    rs.stop_order           -- the sequence number of this station on the route
FROM Route         r
JOIN Route_Station rs ON r.route_id    = rs.route_id    -- join through the junction table
JOIN Station       st ON rs.station_id = st.station_id  -- get the actual station details
ORDER BY r.route_id, rs.stop_order;
-- ORDER BY route first, then stop number — so stops are listed in journey order

-- Unresolved complaints with assigned admin
-- LEFT JOIN Admin so complaints without an assigned admin (admin_id = NULL) still show up
CREATE VIEW v_open_complaints AS
SELECT
    c.complaint_id,
    c.status,
    c.complaint_text,
    c.created_at,
    p.name  AS passenger_name,     -- who filed the complaint
    p.email AS passenger_email,
    a.name  AS assigned_admin      -- NULL if no admin assigned yet
FROM Complaint c
JOIN Passenger p ON c.passenger_id = p.passenger_id   -- INNER JOIN: complaint always has a passenger
LEFT JOIN Admin a ON c.admin_id    = a.admin_id        -- LEFT JOIN: admin may not be assigned yet
WHERE c.status IN ('open', 'in_progress');             -- exclude resolved complaints

-- Recharge summary per passenger
-- Uses GROUP BY to aggregate recharge records per passenger
-- COALESCE handles passengers with no recharges (SUM would return NULL; COALESCE returns 0 instead)
CREATE VIEW v_passenger_recharge_summary AS
SELECT
    p.passenger_id,
    p.name,
    p.card_balance,
    COUNT(r.recharge_id)                            AS total_recharges,
    -- counts how many recharge records exist for this passenger
    COALESCE(SUM(CASE WHEN r.status = 'success'
                      THEN r.amount END), 0)        AS total_recharged
    -- CASE WHEN: only sums amounts where status = 'success' (ignores pending/failed)
    -- COALESCE(..., 0): if passenger has no successful recharges, returns 0 instead of NULL
FROM Passenger p
LEFT JOIN Recharge r ON p.passenger_id = r.passenger_id
-- LEFT JOIN: includes passengers who have never recharged (their recharge columns will be NULL)
GROUP BY p.passenger_id, p.name, p.card_balance;
-- GROUP BY: one result row per passenger, with aggregated recharge totals

-- ============================================================
-- STEP 6: DML — SEED DATA
-- DML = Data Manipulation Language (INSERT, UPDATE, DELETE)
-- This section inserts demo/test data so the app works immediately after setup.
-- ============================================================

-- DML SEED DATA
-- Demo users and operational records make the frontend usable immediately.

-- Insert the single system admin account.
-- Password is a scrypt hash of 'admin123' (never stored as plain text).
INSERT INTO Admin (name, email, password) VALUES
('BRT Admin', 'admin@brt.local', 'scrypt:32768:8:1$Gx7a7Ay94xR8GQQg$c0e5949f7039628d440006eaf3b9740b6048642a10ad0783ad77ed696fe33dc68e52c411274d402d192c60e8de6c22797295376461466f815651d7ec75a33b54');

-- Insert demo passenger account with Rs. 500 starting balance.
-- Password is scrypt hash of 'demo123'.
INSERT INTO Passenger (name, email, phone_number, password, card_balance) VALUES
('demo', 'demo@brt.local', '03000000000', 'scrypt:32768:8:1$G0z0FIxqsFIuC5Tw$eb21c0ca7d6527160b8da010966f0ed432709c3bef9ac702f83774a3eb1a4228c9edb846dd48ae49072c31bde7d4ceae5e781952bd0d8c7a7400a12723f02ca6', 500.0);

-- Insert 10 drivers with unique license numbers (BRT-PWR-001 to BRT-PWR-010).
-- All passwords are scrypt hashes of 'driver123'.
INSERT INTO Driver (name, phone_number, license_number, password, status) VALUES
('Aftab Khan', '03001110001', 'BRT-PWR-001', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Bilal Ahmad', '03001110002', 'BRT-PWR-002', 'scrypt:32768:8:1$lCOOczlQ9D3Pfx9r$0111a181e0a6d12b2b68ea82ffe6658ab878e63ce931566dd94d5f30e72ee2ed59533d118b3c34a12035e6b10973e995b55ec55429715fc11a4767d58db93a97', 'active'),
('Haris Khan', '03001110003', 'BRT-PWR-003', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Imran Ali', '03001110004', 'BRT-PWR-004', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Kamran Shah', '03001110005', 'BRT-PWR-005', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Noman Yousaf', '03001110006', 'BRT-PWR-006', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Sajid Iqbal', '03001110007', 'BRT-PWR-007', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Tariq Mehmood', '03001110008', 'BRT-PWR-008', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Usman Gul', '03001110009', 'BRT-PWR-009', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active'),
('Zahid Afridi', '03001110010', 'BRT-PWR-010', 'scrypt:32768:8:1$TUW8UDJyo9k29AXF$411fb81197d8c6ffaf8bd1490a1879891f05795abee71ad36c94ae7b3d1332b6d60bdffbf409375441fe95ba55bd6badcc67983ef8f89b6b62d3676a8f73eb81', 'active');

-- Insert 10 buses (B-001 to B-010).
-- 3 are express, 7 are standard. All have capacity 80. All currently active.
INSERT INTO Bus (bus_number, bus_type, capacity, current_passengers, status) VALUES
('B-001', 'express', 80, 36, 'active'),
('B-002', 'standard', 80, 62, 'active'),
('B-003', 'standard', 80, 26, 'active'),
('B-004', 'standard', 80, 73, 'active'),
('B-005', 'standard', 80, 45, 'active'),
('B-006', 'standard', 80, 18, 'active'),
('B-007', 'standard', 80, 54, 'active'),
('B-008', 'standard', 80, 70, 'active'),
('B-009', 'express', 80, 27, 'active'),
('B-010', 'express', 80, 58, 'active');

-- Insert 10 BRT routes covering Peshawar.
-- fare_per_stop = Rs. 10 for all routes (total fare = stops travelled x 10).
INSERT INTO Route (route_code, route_name, route_type, total_stops, direction, platform, headway_min, headway_max, fare_per_stop) VALUES
('ER01', 'ER-01: Chamkani to Kharkhano', 'express', 11, 'Outbound', '3', 4, 6, 10),
('SR02', 'SR-02: Chamkani to Kharkhano (Full)', 'standard', 30, 'Outbound', '1', 5, 6, 10),
('DR03A', 'DR-03A: Dabgari Gardens to Kohat Adda', 'standard', 10, 'Outbound', '3', 5, 10, 10),
('DR03B', 'DR-03B: Malik Saad Shaheed to Shah Alam Pul', 'standard', 23, 'Outbound', '4', 7, 10, 10),
('DR05', 'DR-05: Mall of Hayatabad to Phase 6', 'standard', 9, 'Outbound', '3', 10, 15, 10),
('DR06', 'DR-06: Mall of Hayatabad to Phase 7', 'standard', 16, 'Outbound', '2', 8, 15, 10),
('DR07', 'DR-07: Karkhano Market to Phase 7', 'standard', 14, 'Outbound', '2', 15, 15, 10),
('SR08', 'SR-08: Gulbahar Chowk to Mall of Hayatabad', 'standard', 18, 'Outbound', '2', 4, 6, 10),
('ER09', 'ER-09: Gulbahar Chowk to Phase 6', 'express', 14, 'Outbound', '2', 5, 6, 10),
('ER10', 'ER-10: Hospital Chowk to Kohat Adda', 'express', 10, 'Outbound', '2', 4, 6, 10);

-- Insert schedules using a SELECT-based INSERT (INSERT INTO ... SELECT ...).
-- Instead of manually writing each schedule, this generates them automatically
-- by joining Route, Bus, and Driver tables.
-- printf('%02d:00', 6 + r.route_id) generates departure times: 07:00, 08:00, 09:00...
-- printf('B-%03d', r.route_id) produces 'B-001', 'B-002'... to match bus numbers.
-- CASE WHEN sets routes 1, 2, 8 as 'active' and the rest as 'scheduled'.
INSERT INTO Schedule (bus_id, route_id, driver_id, departure_time, arrival_time, operating_days, status)
SELECT b.bus_id, r.route_id, d.driver_id,
       printf('%02d:00', 6 + r.route_id),   -- departure: 07:00 for route 1, 08:00 for route 2, etc.
       printf('%02d:45', 6 + r.route_id),   -- arrival: always 45 minutes after departure
       'Daily',
       CASE WHEN r.route_id IN (1, 2, 8) THEN 'active' ELSE 'scheduled' END
FROM Route r
JOIN Bus b ON b.bus_number = printf('B-%03d', r.route_id)          -- matches each route to its bus
JOIN Driver d ON d.license_number = printf('BRT-PWR-%03d', r.route_id); -- matches each route to its driver

-- Insert route stations from the rough frontend data and keep the stop order accurate.
-- STEP 1: Insert unique station names first.
-- Uses a CTE (Common Table Expression) — WITH ... AS defines a temporary named result set.
-- VALUES(...) lists all station names for all routes.
-- SELECT DISTINCT station_name ensures no duplicate station entries (some stations appear on multiple routes).
-- INSERT OR IGNORE means if a station already exists (UNIQUE constraint), skip it silently.
INSERT OR IGNORE INTO Station (station_name)
WITH route_stop(route_code, stop_order, station_name) AS (
    VALUES
    ('ER01', 1, 'Chamkani'), ('ER01', 2, 'Sardar Garhi'), ('ER01', 3, 'Lahore Adda'), ('ER01', 4, 'Hashtnagri'), ('ER01', 5, 'Malik Saad Shaheed'), ('ER01', 6, 'Khyber Bazar'), ('ER01', 7, 'Dabgari Gardens'), ('ER01', 8, 'Saddar Bazar'), ('ER01', 9, 'University of Peshawar'), ('ER01', 10, 'Mall of Hayatabad'), ('ER01', 11, 'Karkhano Market'),
    ('SR02', 1, 'Chamkani'), ('SR02', 2, 'Sardar Garhi'), ('SR02', 3, 'Chughal Pura'), ('SR02', 4, 'Faisal Colony'), ('SR02', 5, 'Old Haji Camp'), ('SR02', 6, 'Lahore Adda'), ('SR02', 7, 'Gulbahar Chowk'), ('SR02', 8, 'Hashtnagri'), ('SR02', 9, 'Malik Saad Shaheed'), ('SR02', 10, 'Khyber Bazar'), ('SR02', 11, 'Shoba Bazar'), ('SR02', 12, 'Dabgari Gardens'), ('SR02', 13, 'Railway Station'), ('SR02', 14, 'FC Chowk'), ('SR02', 15, 'Saddar Bazar'), ('SR02', 16, 'Mall Road'), ('SR02', 17, 'Tehkal Payyan'), ('SR02', 18, 'Tehkal Bala'), ('SR02', 19, 'Abdara Road'), ('SR02', 20, 'University Town'), ('SR02', 21, 'University of Peshawar'), ('SR02', 22, 'Islamia College'), ('SR02', 23, 'Board Bazar'), ('SR02', 24, 'Mall of Hayatabad'), ('SR02', 25, 'Bab-e-Peshawar'), ('SR02', 26, 'Hayatabad Phase 3'), ('SR02', 27, 'Tatara Park'), ('SR02', 28, 'PDA'), ('SR02', 29, 'Hospital Chowk'), ('SR02', 30, 'Karkhano Market'),
    ('DR03A', 1, 'Dabgari Gardens'), ('DR03A', 2, 'Shaheed Saqib Ghani School'), ('DR03A', 3, 'Civil Quarters'), ('DR03A', 4, 'Bhana Marri'), ('DR03A', 5, 'Civil Colony'), ('DR03A', 6, 'Technical College'), ('DR03A', 7, 'Landi Arbab'), ('DR03A', 8, 'Ghari Qamar Din'), ('DR03A', 9, 'Gulshan Rehman Colony'), ('DR03A', 10, 'Kohat Adda'),
    ('DR03B', 1, 'Malik Saad Shaheed'), ('DR03B', 2, 'Bacha Khan Chowk'), ('DR03B', 3, 'Shahi Bagh'), ('DR03B', 4, 'Eid Gah'), ('DR03B', 5, 'Charsadda Adda'), ('DR03B', 6, 'Shaheed Tehseen Chowk'), ('DR03B', 7, 'Budhni Pul'), ('DR03B', 8, 'Nishat Mill'), ('DR03B', 9, 'Landey Sarrak'), ('DR03B', 10, 'Shero Jhangi'), ('DR03B', 11, 'Habib Abad'), ('DR03B', 12, 'Ibrahim Abad'), ('DR03B', 13, 'Bakhshu Pul'), ('DR03B', 14, 'Muslim Abad'), ('DR03B', 15, 'Nasapa'), ('DR03B', 16, 'Nasapa Bala'), ('DR03B', 17, 'Sugar Mill'), ('DR03B', 18, 'Sewan'), ('DR03B', 19, 'Faqeer Abad'), ('DR03B', 20, 'Khazana'), ('DR03B', 21, 'Tauda'), ('DR03B', 22, 'Wahid Ghari'), ('DR03B', 23, 'Shah Alam Pul'),
    ('DR05', 1, 'Mall of Hayatabad'), ('DR05', 2, 'Bakht Khan Market'), ('DR05', 3, 'Basharat Market'), ('DR05', 4, 'Yousafzai Market'), ('DR05', 5, 'Ring Road Bridge'), ('DR05', 6, 'Itwar Bazar'), ('DR05', 7, 'Achini'), ('DR05', 8, 'Shalman Park'), ('DR05', 9, 'Phase 6 Terminal'),
    ('DR06', 1, 'Mall of Hayatabad'), ('DR06', 2, 'Bab-e-Peshawar'), ('DR06', 3, 'Hayatabad Phase 3'), ('DR06', 4, 'Bagh-e-Naran'), ('DR06', 5, 'Iqra University'), ('DR06', 6, 'Itwar Bazar'), ('DR06', 7, 'Zarghuni Masjid'), ('DR06', 8, 'Lalazar'), ('DR06', 9, 'Malik Saad Market'), ('DR06', 10, 'Rehman Baba Market'), ('DR06', 11, 'Haji Camp'), ('DR06', 12, 'Judicial Complex'), ('DR06', 13, 'Madrassa'), ('DR06', 14, 'Football Ground'), ('DR06', 15, 'IMSciences'), ('DR06', 16, 'Phase 7 Terminal'),
    ('DR07', 1, 'Karkhano Market'), ('DR07', 2, 'Karkhano Chowk'), ('DR07', 3, 'TEVTA'), ('DR07', 4, 'Fort'), ('DR07', 5, 'Industrial Estate'), ('DR07', 6, 'Fast University'), ('DR07', 7, 'Shamali Market'), ('DR07', 8, 'Lalazar'), ('DR07', 9, 'Zarghuni Masjid'), ('DR07', 10, 'Deans Heights'), ('DR07', 11, 'Phase 7 Chowk'), ('DR07', 12, 'Gol Chowk'), ('DR07', 13, 'Bangash Market'), ('DR07', 14, 'Phase 7 Terminal'),
    ('SR08', 1, 'Gulbahar Chowk'), ('SR08', 2, 'Hashtnagri'), ('SR08', 3, 'Malik Saad Shaheed'), ('SR08', 4, 'Khyber Bazar'), ('SR08', 5, 'Shoba Bazar'), ('SR08', 6, 'Dabgari Gardens'), ('SR08', 7, 'Railway Station'), ('SR08', 8, 'FC Chowk'), ('SR08', 9, 'Saddar Bazar'), ('SR08', 10, 'Mall Road'), ('SR08', 11, 'Tehkal Payyan'), ('SR08', 12, 'Tehkal Bala'), ('SR08', 13, 'Abdara Road'), ('SR08', 14, 'University Town'), ('SR08', 15, 'University of Peshawar'), ('SR08', 16, 'Islamia College'), ('SR08', 17, 'Board Bazar'), ('SR08', 18, 'Mall of Hayatabad'),
    ('ER09', 1, 'Gulbahar Chowk'), ('ER09', 2, 'Malik Saad Shaheed'), ('ER09', 3, 'Dabgari Gardens'), ('ER09', 4, 'Saddar Bazar'), ('ER09', 5, 'Abdara Road'), ('ER09', 6, 'University of Peshawar'), ('ER09', 7, 'Board Bazar'), ('ER09', 8, 'Basharat Market'), ('ER09', 9, 'Yousafzai Market'), ('ER09', 10, 'Ring Road Bridge'), ('ER09', 11, 'Zarghuni Masjid'), ('ER09', 12, 'Gol Chowk'), ('ER09', 13, 'Nawab Market'), ('ER09', 14, 'Phase 6 Terminal'),
    ('ER10', 1, 'Hospital Chowk'), ('ER10', 2, 'Hayatabad Phase 3'), ('ER10', 3, 'Mall of Hayatabad'), ('ER10', 4, 'University of Peshawar'), ('ER10', 5, 'Tehkal Payyan'), ('ER10', 6, 'Saddar Bazar'), ('ER10', 7, 'Bhana Marri'), ('ER10', 8, 'Technical College'), ('ER10', 9, 'Ghari Qamar Din'), ('ER10', 10, 'Kohat Adda')
)
SELECT DISTINCT station_name FROM route_stop;
-- DISTINCT ensures each station name is inserted only once even if it appears in multiple routes

-- STEP 2: Now populate the junction table Route_Station.
-- Uses the same CTE pattern to link route_id + station_id + stop_order.
-- Joins the CTE to Route (to get route_id from route_code)
-- and to Station (to get station_id from station_name).
INSERT INTO Route_Station (route_id, station_id, stop_order)
WITH route_stop(route_code, stop_order, station_name) AS (
    VALUES
    ('ER01', 1, 'Chamkani'), ('ER01', 2, 'Sardar Garhi'), ('ER01', 3, 'Lahore Adda'), ('ER01', 4, 'Hashtnagri'), ('ER01', 5, 'Malik Saad Shaheed'), ('ER01', 6, 'Khyber Bazar'), ('ER01', 7, 'Dabgari Gardens'), ('ER01', 8, 'Saddar Bazar'), ('ER01', 9, 'University of Peshawar'), ('ER01', 10, 'Mall of Hayatabad'), ('ER01', 11, 'Karkhano Market'),
    ('SR02', 1, 'Chamkani'), ('SR02', 2, 'Sardar Garhi'), ('SR02', 3, 'Chughal Pura'), ('SR02', 4, 'Faisal Colony'), ('SR02', 5, 'Old Haji Camp'), ('SR02', 6, 'Lahore Adda'), ('SR02', 7, 'Gulbahar Chowk'), ('SR02', 8, 'Hashtnagri'), ('SR02', 9, 'Malik Saad Shaheed'), ('SR02', 10, 'Khyber Bazar'), ('SR02', 11, 'Shoba Bazar'), ('SR02', 12, 'Dabgari Gardens'), ('SR02', 13, 'Railway Station'), ('SR02', 14, 'FC Chowk'), ('SR02', 15, 'Saddar Bazar'), ('SR02', 16, 'Mall Road'), ('SR02', 17, 'Tehkal Payyan'), ('SR02', 18, 'Tehkal Bala'), ('SR02', 19, 'Abdara Road'), ('SR02', 20, 'University Town'), ('SR02', 21, 'University of Peshawar'), ('SR02', 22, 'Islamia College'), ('SR02', 23, 'Board Bazar'), ('SR02', 24, 'Mall of Hayatabad'), ('SR02', 25, 'Bab-e-Peshawar'), ('SR02', 26, 'Hayatabad Phase 3'), ('SR02', 27, 'Tatara Park'), ('SR02', 28, 'PDA'), ('SR02', 29, 'Hospital Chowk'), ('SR02', 30, 'Karkhano Market'),
    ('DR03A', 1, 'Dabgari Gardens'), ('DR03A', 2, 'Shaheed Saqib Ghani School'), ('DR03A', 3, 'Civil Quarters'), ('DR03A', 4, 'Bhana Marri'), ('DR03A', 5, 'Civil Colony'), ('DR03A', 6, 'Technical College'), ('DR03A', 7, 'Landi Arbab'), ('DR03A', 8, 'Ghari Qamar Din'), ('DR03A', 9, 'Gulshan Rehman Colony'), ('DR03A', 10, 'Kohat Adda'),
    ('DR03B', 1, 'Malik Saad Shaheed'), ('DR03B', 2, 'Bacha Khan Chowk'), ('DR03B', 3, 'Shahi Bagh'), ('DR03B', 4, 'Eid Gah'), ('DR03B', 5, 'Charsadda Adda'), ('DR03B', 6, 'Shaheed Tehseen Chowk'), ('DR03B', 7, 'Budhni Pul'), ('DR03B', 8, 'Nishat Mill'), ('DR03B', 9, 'Landey Sarrak'), ('DR03B', 10, 'Shero Jhangi'), ('DR03B', 11, 'Habib Abad'), ('DR03B', 12, 'Ibrahim Abad'), ('DR03B', 13, 'Bakhshu Pul'), ('DR03B', 14, 'Muslim Abad'), ('DR03B', 15, 'Nasapa'), ('DR03B', 16, 'Nasapa Bala'), ('DR03B', 17, 'Sugar Mill'), ('DR03B', 18, 'Sewan'), ('DR03B', 19, 'Faqeer Abad'), ('DR03B', 20, 'Khazana'), ('DR03B', 21, 'Tauda'), ('DR03B', 22, 'Wahid Ghari'), ('DR03B', 23, 'Shah Alam Pul'),
    ('DR05', 1, 'Mall of Hayatabad'), ('DR05', 2, 'Bakht Khan Market'), ('DR05', 3, 'Basharat Market'), ('DR05', 4, 'Yousafzai Market'), ('DR05', 5, 'Ring Road Bridge'), ('DR05', 6, 'Itwar Bazar'), ('DR05', 7, 'Achini'), ('DR05', 8, 'Shalman Park'), ('DR05', 9, 'Phase 6 Terminal'),
    ('DR06', 1, 'Mall of Hayatabad'), ('DR06', 2, 'Bab-e-Peshawar'), ('DR06', 3, 'Hayatabad Phase 3'), ('DR06', 4, 'Bagh-e-Naran'), ('DR06', 5, 'Iqra University'), ('DR06', 6, 'Itwar Bazar'), ('DR06', 7, 'Zarghuni Masjid'), ('DR06', 8, 'Lalazar'), ('DR06', 9, 'Malik Saad Market'), ('DR06', 10, 'Rehman Baba Market'), ('DR06', 11, 'Haji Camp'), ('DR06', 12, 'Judicial Complex'), ('DR06', 13, 'Madrassa'), ('DR06', 14, 'Football Ground'), ('DR06', 15, 'IMSciences'), ('DR06', 16, 'Phase 7 Terminal'),
    ('DR07', 1, 'Karkhano Market'), ('DR07', 2, 'Karkhano Chowk'), ('DR07', 3, 'TEVTA'), ('DR07', 4, 'Fort'), ('DR07', 5, 'Industrial Estate'), ('DR07', 6, 'Fast University'), ('DR07', 7, 'Shamali Market'), ('DR07', 8, 'Lalazar'), ('DR07', 9, 'Zarghuni Masjid'), ('DR07', 10, 'Deans Heights'), ('DR07', 11, 'Phase 7 Chowk'), ('DR07', 12, 'Gol Chowk'), ('DR07', 13, 'Bangash Market'), ('DR07', 14, 'Phase 7 Terminal'),
    ('SR08', 1, 'Gulbahar Chowk'), ('SR08', 2, 'Hashtnagri'), ('SR08', 3, 'Malik Saad Shaheed'), ('SR08', 4, 'Khyber Bazar'), ('SR08', 5, 'Shoba Bazar'), ('SR08', 6, 'Dabgari Gardens'), ('SR08', 7, 'Railway Station'), ('SR08', 8, 'FC Chowk'), ('SR08', 9, 'Saddar Bazar'), ('SR08', 10, 'Mall Road'), ('SR08', 11, 'Tehkal Payyan'), ('SR08', 12, 'Tehkal Bala'), ('SR08', 13, 'Abdara Road'), ('SR08', 14, 'University Town'), ('SR08', 15, 'University of Peshawar'), ('SR08', 16, 'Islamia College'), ('SR08', 17, 'Board Bazar'), ('SR08', 18, 'Mall of Hayatabad'),
    ('ER09', 1, 'Gulbahar Chowk'), ('ER09', 2, 'Malik Saad Shaheed'), ('ER09', 3, 'Dabgari Gardens'), ('ER09', 4, 'Saddar Bazar'), ('ER09', 5, 'Abdara Road'), ('ER09', 6, 'University of Peshawar'), ('ER09', 7, 'Board Bazar'), ('ER09', 8, 'Basharat Market'), ('ER09', 9, 'Yousafzai Market'), ('ER09', 10, 'Ring Road Bridge'), ('ER09', 11, 'Zarghuni Masjid'), ('ER09', 12, 'Gol Chowk'), ('ER09', 13, 'Nawab Market'), ('ER09', 14, 'Phase 6 Terminal'),
    ('ER10', 1, 'Hospital Chowk'), ('ER10', 2, 'Hayatabad Phase 3'), ('ER10', 3, 'Mall of Hayatabad'), ('ER10', 4, 'University of Peshawar'), ('ER10', 5, 'Tehkal Payyan'), ('ER10', 6, 'Saddar Bazar'), ('ER10', 7, 'Bhana Marri'), ('ER10', 8, 'Technical College'), ('ER10', 9, 'Ghari Qamar Din'), ('ER10', 10, 'Kohat Adda')
)
SELECT r.route_id, s.station_id, rs.stop_order
FROM route_stop rs
JOIN Route r ON r.route_code = rs.route_code       -- lookup the route_id using route_code
JOIN Station s ON s.station_name = rs.station_name; -- lookup the station_id using station_name

-- Give the demo passenger an initial recharge of Rs. 500 via EasyPaisa.
-- Uses a SELECT subquery to find the passenger_id dynamically by email.
INSERT INTO Recharge (passenger_id, amount, payment_method, status)
SELECT passenger_id, 500, 'EasyPaisa', 'success'
FROM Passenger
WHERE email = 'demo@brt.local';

-- ============================================================
-- STEP 7: DQL EXAMPLES
-- DQL = Data Query Language (SELECT statements)
-- These 3 example queries demonstrate real use cases of the database.
-- ============================================================

-- DQL EXAMPLES
-- 1. List every route with its platform, fare rule, and frequency.
-- || is the string concatenation operator in SQLite (like + in Python for strings).
-- headway_min || '-' || headway_max || ' min' produces e.g. '4-6 min'
SELECT route_code, route_name, platform, fare_per_stop, headway_min || '-' || headway_max || ' min' AS frequency
FROM Route
ORDER BY route_code;

-- 2. Find all direct routes between two stations and calculate fare.
-- Route_Station is joined TWICE using different aliases (origin, destination).
-- This is called a SELF-JOIN pattern on the same table.
-- ABS() gives the absolute value so direction (Inbound/Outbound) doesn't matter.
-- Fare = number of stops between origin and destination * fare per stop (Rs. 10).
SELECT r.route_code, r.route_name, r.platform,
       ABS(destination.stop_order - origin.stop_order) AS stops,
       ABS(destination.stop_order - origin.stop_order) * r.fare_per_stop AS fare
FROM Route r
JOIN Route_Station origin ON origin.route_id = r.route_id           -- first join: for the starting station
JOIN Station origin_station ON origin_station.station_id = origin.station_id
JOIN Route_Station destination ON destination.route_id = r.route_id  -- second join: for the ending station
JOIN Station destination_station ON destination_station.station_id = destination.station_id
WHERE origin_station.station_name = 'Chamkani'
  AND destination_station.station_name = 'Karkhano Market'
  AND origin.stop_order <> destination.stop_order  -- exclude rows where start = end (same station)
ORDER BY stops;

-- 3. Show live bus occupancy from schedule, bus, and route tables.
-- Joins 3 tables: Bus, Schedule, Route.
-- Calculates occupancy as a percentage: (current_passengers / capacity) * 100.
-- 100.0 (not 100) forces floating point division — integer division would give wrong results.
-- ROUND(..., 0) rounds to zero decimal places (whole number percentage).
-- GROUP BY b.bus_id in app.py version prevents duplicate rows when a bus has multiple schedules.
SELECT b.bus_number, r.route_code, r.route_name, r.platform,
       ROUND((b.current_passengers * 100.0) / b.capacity, 0) AS occupancy_percent
FROM Bus b
JOIN Schedule s ON s.bus_id = b.bus_id      -- link bus to its schedule
JOIN Route r ON r.route_id = s.route_id    -- link schedule to the route
WHERE b.status = 'active';                  -- only show buses that are currently operational