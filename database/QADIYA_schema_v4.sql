-- =====================================================================
--  QADIYA – PostgreSQL Database Schema  (v4)
--  ---------------------------------------------------------------------
--  Design principle: the database is split into 3 layers
--    (A) Accounts & Assignment  – users, cases assigned to them
--    (B) Case Content           – authored by the Admin, shared by every
--                                 player of the case (read-only in game)
--    (C) Player State           – everything one investigator creates
--                                 while playing; always hangs off
--                                 case_progress (one row per user+case)
--    (D) Ground Truth & Scoring – the hidden solution; NEVER returned by
--                                 any player-facing API before Submit
--    (E) Integrity              – triggers for "same case / same player"
--                                 rules (player AND admin content)
--                                 + atomic, idempotent points spending
--
--  Conventions
--    * PK  = <table>_id  BIGINT identity
--    * "exclusive arc" = several nullable FKs + CHECK num_nonnulls(...)=1
--      used instead of (source_type, source_id) so every reference
--      has a real FOREIGN KEY.
--    * Image coordinates are normalised 0..1 (independent of screen size)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- (A) ACCOUNTS & ASSIGNMENT
-- ---------------------------------------------------------------------

CREATE TABLE users (
    user_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name       VARCHAR(120) NOT NULL,
    username        VARCHAR(50)  NOT NULL UNIQUE,
    email           VARCHAR(255) NOT NULL UNIQUE,
    password_hash   TEXT         NOT NULL,
    role            VARCHAR(20)  NOT NULL DEFAULT 'investigator'
                    CHECK (role IN ('investigator', 'admin')),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE cases (
    case_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_number         VARCHAR(30)  NOT NULL UNIQUE,          -- e.g. QD-2026-014
    title               VARCHAR(200) NOT NULL,
    short_description   TEXT,                                  -- safe teaser for Cases Hub
    case_type           VARCHAR(50)  NOT NULL,                 -- homicide, disappearance, theft...
    case_status         VARCHAR(20)  NOT NULL DEFAULT 'unsolved'
                        CHECK (case_status IN ('unsolved', 'cold', 'open')),
    priority            VARCHAR(10)  NOT NULL DEFAULT 'medium'
                        CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    -- Case Summary (official facts only)
    incident_at         TIMESTAMPTZ,
    incident_location   VARCHAR(255),
    victim_person_id    BIGINT,                                -- FK added after persons
    summary_text        TEXT,
    official_status     VARCHAR(100),                          -- "Under investigation"...
    initial_brief       TEXT,                                  -- Overview page
    cover_image_url     TEXT,
    initial_points      INT          NOT NULL DEFAULT 100 CHECK (initial_points > 0),
    -- point cost of each paid action (v2: columns instead of case_action_costs table)
    cost_start_interview   INT NOT NULL DEFAULT 5 CHECK (cost_start_interview   >= 0),
    cost_confront          INT NOT NULL DEFAULT 2 CHECK (cost_confront          >= 0),
    cost_visual_comparison INT NOT NULL DEFAULT 5 CHECK (cost_visual_comparison >= 0),
    cost_advanced_enhance  INT NOT NULL DEFAULT 3 CHECK (cost_advanced_enhance  >= 0),
    publish_status     VARCHAR(20)  NOT NULL DEFAULT 'draft'
                        CHECK (publish_status IN ('draft', 'published', 'archived')),
    created_by          BIGINT       NOT NULL REFERENCES users(user_id),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- v2: assignment + progress merged into ONE table (they were always 1-to-1).
-- A row is created when the Admin assigns the case; the player "starts" it on first open.
-- points_remaining is THE single shared points variable of the case.
CREATE TABLE case_progress (
    progress_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT      NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    user_id             BIGINT      NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    assigned_by         BIGINT      REFERENCES users(user_id),
    assigned_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    status              VARCHAR(20) NOT NULL DEFAULT 'assigned'
                        CHECK (status IN ('assigned', 'in_progress', 'submitted')),
    points_remaining    INT         NOT NULL CHECK (points_remaining >= 0),  -- v4: filled from cases.initial_points by trigger
    is_admin_preview    BOOLEAN     NOT NULL DEFAULT FALSE,
    started_at          TIMESTAMPTZ,                                       -- first "Open Case"
    last_activity_at    TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,                                       -- = conclusion submitted
    finding_seq         INT         NOT NULL DEFAULT 0,                    -- generates F-001, F-002...
    UNIQUE (case_id, user_id),
    UNIQUE (progress_id, case_id),                                         -- target for composite FKs
    CHECK (status = 'assigned'  OR started_at   IS NOT NULL),
    CHECK (status <> 'submitted' OR completed_at IS NOT NULL)
);


-- ---------------------------------------------------------------------
-- (B) CASE CONTENT  (Admin-authored)
-- ---------------------------------------------------------------------

CREATE TABLE persons (
    person_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    full_name           VARCHAR(120) NOT NULL,
    person_role         VARCHAR(20)  NOT NULL
                        CHECK (person_role IN ('victim', 'suspect', 'witness', 'related')),
    status_label        VARCHAR(60),             -- "Person of Interest", "Suspect"...
    relation_to_victim  VARCHAR(120),
    age                 INT CHECK (age IS NULL OR age BETWEEN 0 AND 120),
    occupation          VARCHAR(120),
    bio                 TEXT,
    stated_alibi        TEXT,                    -- always "claimed/stated", never "verified"
    photo_url           TEXT,
    -- Interrogation AI persona (never sent to the client)
    personality_prompt  TEXT,
    speaking_style      TEXT,
    is_interrogable     BOOLEAN      NOT NULL DEFAULT TRUE,
    is_hidden_initially BOOLEAN      NOT NULL DEFAULT FALSE,   -- revealed by unlock_rules
    display_order       INT          NOT NULL DEFAULT 0,
    UNIQUE (person_id, case_id)                  -- enables composite FKs
);

ALTER TABLE cases
    ADD CONSTRAINT fk_cases_victim
    FOREIGN KEY (victim_person_id) REFERENCES persons(person_id) ON DELETE SET NULL;

-- Officially-known relationships between people (shown in Person Profile → Connections)
CREATE TABLE person_connections (
    connection_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id         BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    person_a_id     BIGINT       NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    person_b_id     BIGINT       NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    relation_label  VARCHAR(100) NOT NULL,       -- "Business partner", "Ex-wife"...
    description     TEXT,
    is_hidden_initially BOOLEAN  NOT NULL DEFAULT FALSE,
    CHECK (person_a_id <> person_b_id)
);

-- What each character knows – the ONLY facts the LLM may use for that person
CREATE TABLE character_knowledge (
    knowledge_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id           BIGINT      NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    fact_text           TEXT        NOT NULL,
    disclosure          VARCHAR(20) NOT NULL
                        CHECK (disclosure IN ('free',          -- says it if asked
                                              'on_confront',   -- only when confronted with reveal_clue
                                              'never')),       -- knows it but never admits it
    reveal_clue_id      BIGINT,                 -- FK added after clues
    is_truthful         BOOLEAN     NOT NULL DEFAULT TRUE,  -- FALSE = the character's lie
    CHECK (disclosure <> 'on_confront' OR reveal_clue_id IS NOT NULL)
);

-- Official documents of the Case File
CREATE TABLE statements (
    statement_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT      NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    person_id           BIGINT      NOT NULL,
    statement_type      VARCHAR(20) NOT NULL
                        CHECK (statement_type IN ('witness', 'suspect_initial', 'other')),
    title               VARCHAR(200),
    statement_text      TEXT        NOT NULL,
    recorded_at         TIMESTAMPTZ,
    source              VARCHAR(150),            -- "Initial Police Interview – Officer Haddad"
    display_order       INT         NOT NULL DEFAULT 0,
    is_hidden_initially BOOLEAN     NOT NULL DEFAULT FALSE,
    FOREIGN KEY (person_id, case_id) REFERENCES persons(person_id, case_id) ON DELETE CASCADE
);

CREATE TABLE police_reports (
    report_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    report_type         VARCHAR(50)  NOT NULL,   -- prelim_autopsy, patrol_log...
    title               VARCHAR(200) NOT NULL,
    author              VARCHAR(120),
    source              VARCHAR(150),
    report_date         TIMESTAMPTZ,
    content             TEXT         NOT NULL,
    display_order       INT          NOT NULL DEFAULT 0,
    is_hidden_initially BOOLEAN      NOT NULL DEFAULT FALSE
);

-- Evidence Items = the central inventory.
--   origin 'police'       → authored by Admin, progress_id IS NULL
--   origin 'investigator' → a Finding created by one player, progress_id NOT NULL
-- "Add to Board / Timeline / Lab" always point to this same row (no copies).
CREATE TABLE evidence_items (
    evidence_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    origin_type         VARCHAR(20)  NOT NULL CHECK (origin_type IN ('police', 'investigator')),
    progress_id         BIGINT,                  -- owner of a finding (NULL for police material)
    media_type          VARCHAR(20)  NOT NULL
                        CHECK (media_type IN ('image', 'video', 'object', 'digital', 'document')),
    title               VARCHAR(200) NOT NULL,
    description         TEXT,
    source              VARCHAR(150),            -- "CSI Unit", "Investigator"...
    associated_person_id BIGINT      REFERENCES persons(person_id) ON DELETE SET NULL, -- only if proven
    status              VARCHAR(30)  NOT NULL DEFAULT 'available'
                        CHECK (status IN ('available', 'logged', 'under_review', 'analyzed')),
    file_url            TEXT,
    thumbnail_url       TEXT,
    collected_at        TIMESTAMPTZ,
    collected_location  VARCHAR(200),
    is_hidden_initially BOOLEAN      NOT NULL DEFAULT FALSE,   -- police materials only
    display_order       INT          NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (evidence_id, progress_id),           -- target for findings' composite FK
    FOREIGN KEY (progress_id, case_id) REFERENCES case_progress(progress_id, case_id) ON DELETE CASCADE,
    CHECK ( (origin_type = 'police'       AND progress_id IS NULL)
         OR (origin_type = 'investigator' AND progress_id IS NOT NULL
                                          AND is_hidden_initially = FALSE) )
);

CREATE TABLE police_observations (
    observation_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    location            VARCHAR(200),
    description         TEXT         NOT NULL,
    source              VARCHAR(150),
    logged_at           TIMESTAMPTZ,
    related_evidence_id BIGINT       REFERENCES evidence_items(evidence_id) ON DELETE SET NULL,
    display_order       INT          NOT NULL DEFAULT 0,
    is_hidden_initially BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE crime_scenes (
    scene_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id         BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    image_url       TEXT         NOT NULL,
    image_width     INT,
    image_height    INT,
    display_order   INT          NOT NULL DEFAULT 0,
    is_hidden_initially BOOLEAN  NOT NULL DEFAULT FALSE      -- secondary scene (optional)
);

CREATE TABLE social_posts (
    post_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    person_id           BIGINT       NOT NULL,                -- author
    platform            VARCHAR(30),
    image_url           TEXT,
    caption             TEXT,
    posted_at           TIMESTAMPTZ,
    location            VARCHAR(200),
    is_hidden_initially BOOLEAN      NOT NULL DEFAULT FALSE,
    FOREIGN KEY (person_id, case_id) REFERENCES persons(person_id, case_id) ON DELETE CASCADE
);

CREATE TABLE social_post_tags (
    post_id     BIGINT NOT NULL REFERENCES social_posts(post_id) ON DELETE CASCADE,
    person_id   BIGINT NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    PRIMARY KEY (post_id, person_id)
);

-- A CLUE is a hidden, Admin-defined "thing that can be discovered"
-- (the necklace, the name on the receipt, the necklace↔photo match...).
-- Findings created by the player get clue_id when they match one.
-- This is what makes scoring deterministic even though players create
-- Findings freely.
CREATE TABLE clues (
    clue_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id         BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    code            VARCHAR(30)  NOT NULL,       -- admin label, e.g. CL-NECKLACE
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    UNIQUE (case_id, code)
);

ALTER TABLE character_knowledge
    ADD CONSTRAINT fk_knowledge_clue
    FOREIGN KEY (reveal_clue_id) REFERENCES clues(clue_id) ON DELETE SET NULL;

-- Hidden rectangles on ANY image (scene / evidence image / social photo).
-- Replaces "scene_hotspots" and also covers OCR text areas.
CREATE TABLE image_regions (
    region_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT        NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    scene_id            BIGINT        REFERENCES crime_scenes(scene_id)   ON DELETE CASCADE,
    evidence_id         BIGINT        REFERENCES evidence_items(evidence_id) ON DELETE CASCADE,
    post_id             BIGINT        REFERENCES social_posts(post_id)    ON DELETE CASCADE,
    region_type         VARCHAR(20)   NOT NULL CHECK (region_type IN ('object', 'text', 'area')),
    x NUMERIC(6,5) NOT NULL CHECK (x BETWEEN 0 AND 1),
    y NUMERIC(6,5) NOT NULL CHECK (y BETWEEN 0 AND 1),
    w NUMERIC(6,5) NOT NULL CHECK (w > 0 AND x + w <= 1),
    h NUMERIC(6,5) NOT NULL CHECK (h > 0 AND y + h <= 1),
    observed_details    TEXT,              -- neutral description shown on "Inspect Closer"
    revealed_text       TEXT,              -- text returned by OCR for region_type='text'
    enhanced_image_url  TEXT,              -- result of "Enhance"
    clue_id             BIGINT        REFERENCES clues(clue_id) ON DELETE SET NULL,
    min_overlap         NUMERIC(3,2)  NOT NULL DEFAULT 0.30,  -- IoU needed to count as "found"
    CHECK (num_nonnulls(scene_id, evidence_id, post_id) = 1)
);

-- Lab rule: comparing region A with region B (similarity ≥ threshold) yields a clue
CREATE TABLE comparison_rules (
    rule_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id         BIGINT       NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    region_a_id     BIGINT       NOT NULL REFERENCES image_regions(region_id) ON DELETE CASCADE,
    region_b_id     BIGINT       NOT NULL REFERENCES image_regions(region_id) ON DELETE CASCADE,
    min_similarity  NUMERIC(4,3) NOT NULL DEFAULT 0.600,
    result_clue_id  BIGINT       NOT NULL REFERENCES clues(clue_id) ON DELETE CASCADE,
    CHECK (region_a_id <> region_b_id)
);

-- Unlock Rules: "discovering X reveals Y"
CREATE TABLE unlock_rules (
    rule_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id             BIGINT      NOT NULL REFERENCES cases(case_id) ON DELETE CASCADE,
    trigger_type        VARCHAR(20) NOT NULL
                        CHECK (trigger_type IN ('clue_found',      -- any finding with trigger_clue_id
                                                'confront')),      -- confronting trigger_person with that clue
    trigger_clue_id     BIGINT      NOT NULL REFERENCES clues(clue_id) ON DELETE CASCADE,
    trigger_person_id   BIGINT      REFERENCES persons(person_id) ON DELETE CASCADE,
    -- target (exactly one)
    unlock_person_id      BIGINT REFERENCES persons(person_id)              ON DELETE CASCADE,
    unlock_evidence_id    BIGINT REFERENCES evidence_items(evidence_id)     ON DELETE CASCADE,
    unlock_statement_id   BIGINT REFERENCES statements(statement_id)        ON DELETE CASCADE,
    unlock_report_id      BIGINT REFERENCES police_reports(report_id)       ON DELETE CASCADE,
    unlock_observation_id BIGINT REFERENCES police_observations(observation_id) ON DELETE CASCADE,
    unlock_post_id        BIGINT REFERENCES social_posts(post_id)           ON DELETE CASCADE,
    unlock_scene_id       BIGINT REFERENCES crime_scenes(scene_id)          ON DELETE CASCADE,
    unlock_connection_id  BIGINT REFERENCES person_connections(connection_id) ON DELETE CASCADE,
    notify_message      VARCHAR(255),           -- "New person added to People"
    CHECK (trigger_type <> 'confront' OR trigger_person_id IS NOT NULL),
    CHECK (num_nonnulls(unlock_person_id, unlock_evidence_id, unlock_statement_id,
                        unlock_report_id, unlock_observation_id, unlock_post_id,
                        unlock_scene_id, unlock_connection_id) = 1)
);


-- ---------------------------------------------------------------------
-- (C) PLAYER STATE  (everything hangs off case_progress)
-- ---------------------------------------------------------------------

-- Which unlock rules have fired for this player
CREATE TABLE progress_unlocks (
    progress_id     BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    rule_id         BIGINT      NOT NULL REFERENCES unlock_rules(rule_id)      ON DELETE CASCADE,
    unlocked_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    seen            BOOLEAN     NOT NULL DEFAULT FALSE,
    PRIMARY KEY (progress_id, rule_id)
);

-- Interview sessions (history is separate per person)
CREATE TABLE interview_sessions (
    session_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id     BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    person_id       BIGINT      NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),     -- the paid "Start Interview"
    last_message_at TIMESTAMPTZ,
    UNIQUE (progress_id, person_id)                          -- v2: one conversation per person
);

CREATE TABLE interview_messages (
    message_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id          BIGINT      NOT NULL REFERENCES interview_sessions(session_id) ON DELETE CASCADE,
    sender_type         VARCHAR(15) NOT NULL CHECK (sender_type IN ('investigator', 'person', 'system')),
    message_type        VARCHAR(15) NOT NULL DEFAULT 'normal'
                        CHECK (message_type IN ('normal', 'confrontation')),
    message_text        TEXT        NOT NULL,
    confront_finding_id BIGINT,                 -- v2: FK → findings (added below), findings only
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (message_type <> 'confrontation' OR confront_finding_id IS NOT NULL)
);

-- Facts a character has already revealed to this player (keeps the LLM consistent)
CREATE TABLE progress_revealed_facts (
    progress_id     BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    knowledge_id    BIGINT      NOT NULL REFERENCES character_knowledge(knowledge_id) ON DELETE CASCADE,
    message_id      BIGINT      REFERENCES interview_messages(message_id) ON DELETE SET NULL,
    revealed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (progress_id, knowledge_id)
);

-- Forensic Lab – Visual Comparison
CREATE TABLE lab_comparisons (
    comparison_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id         BIGINT       NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    -- Source A (evidence item OR social photo)
    a_evidence_id       BIGINT       REFERENCES evidence_items(evidence_id) ON DELETE CASCADE,
    a_post_id           BIGINT       REFERENCES social_posts(post_id)       ON DELETE CASCADE,
    a_frame_time_sec    NUMERIC(8,3),               -- paused video frame
    a_x NUMERIC(6,5) NOT NULL, a_y NUMERIC(6,5) NOT NULL,
    a_w NUMERIC(6,5) NOT NULL, a_h NUMERIC(6,5) NOT NULL,
    a_adjustments       JSONB,                      -- {zoom, brightness, contrast, sharpen}
    a_crop_url          TEXT,
    -- Source B
    b_evidence_id       BIGINT       REFERENCES evidence_items(evidence_id) ON DELETE CASCADE,
    b_post_id           BIGINT       REFERENCES social_posts(post_id)       ON DELETE CASCADE,
    b_frame_time_sec    NUMERIC(8,3),
    b_x NUMERIC(6,5) NOT NULL, b_y NUMERIC(6,5) NOT NULL,
    b_w NUMERIC(6,5) NOT NULL, b_h NUMERIC(6,5) NOT NULL,
    b_adjustments       JSONB,
    b_crop_url          TEXT,
    -- v4: both rectangles normalised and inside their image
    CHECK (a_x >= 0 AND a_y >= 0 AND a_w > 0 AND a_h > 0 AND a_x + a_w <= 1 AND a_y + a_h <= 1),
    CHECK (b_x >= 0 AND b_y >= 0 AND b_w > 0 AND b_h > 0 AND b_x + b_w <= 1 AND b_y + b_h <= 1),
    CHECK (a_frame_time_sec IS NULL OR a_frame_time_sec >= 0),
    CHECK (b_frame_time_sec IS NULL OR b_frame_time_sec >= 0),
    -- Result (always "Potential Visual Correspondence", never a confirmed match)
    similarity_score    NUMERIC(4,3) CHECK (similarity_score BETWEEN 0 AND 1),
    similarities        JSONB,                      -- ["shape", "color", ...]
    differences         JSONB,
    matched_rule_id     BIGINT       REFERENCES comparison_rules(rule_id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(a_evidence_id, a_post_id) = 1),
    CHECK (num_nonnulls(b_evidence_id, b_post_id) = 1)
);

-- Findings = extra details of evidence_items whose origin = 'investigator'
-- (1-to-1 sub-type of evidence_items)
CREATE TABLE findings (
    evidence_id         BIGINT      PRIMARY KEY,
    progress_id         BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    -- v2: composite FK guarantees the finding row and its evidence row have the same owner
    FOREIGN KEY (evidence_id, progress_id) REFERENCES evidence_items(evidence_id, progress_id) ON DELETE CASCADE,
    display_code        VARCHAR(10) NOT NULL,       -- F-007
    created_via         VARCHAR(25) NOT NULL
                        CHECK (created_via IN ('scene_selection', 'ocr', 'enhance',
                                               'lab_comparison', 'social_clue',
                                               'interrogation', 'manual')),
    -- where it came from (at most one)
    src_scene_id        BIGINT REFERENCES crime_scenes(scene_id)        ON DELETE SET NULL,
    src_evidence_id     BIGINT REFERENCES evidence_items(evidence_id)   ON DELETE SET NULL,
    src_post_id         BIGINT REFERENCES social_posts(post_id)         ON DELETE SET NULL,
    src_comparison_id   BIGINT REFERENCES lab_comparisons(comparison_id) ON DELETE SET NULL,
    src_message_id      BIGINT REFERENCES interview_messages(message_id) ON DELETE SET NULL,
    -- selected rectangle on the source image
    sel_x NUMERIC(6,5), sel_y NUMERIC(6,5), sel_w NUMERIC(6,5), sel_h NUMERIC(6,5),
    -- v4: selection is all-or-nothing and inside the image
    CHECK (num_nonnulls(sel_x, sel_y, sel_w, sel_h) IN (0, 4)),
    CHECK (sel_x IS NULL OR (sel_x >= 0 AND sel_y >= 0 AND sel_w > 0 AND sel_h > 0
                             AND sel_x + sel_w <= 1 AND sel_y + sel_h <= 1)),
    crop_url            TEXT,
    ocr_text            TEXT,
    -- hidden matching (never sent to the client)
    matched_region_id   BIGINT REFERENCES image_regions(region_id) ON DELETE SET NULL,
    clue_id             BIGINT REFERENCES clues(clue_id)           ON DELETE SET NULL,
    UNIQUE (progress_id, display_code),
    CHECK (num_nonnulls(src_scene_id, src_evidence_id, src_post_id,
                        src_comparison_id, src_message_id) <= 1)
);

ALTER TABLE lab_comparisons
    ADD COLUMN saved_finding_id BIGINT REFERENCES findings(evidence_id) ON DELETE SET NULL;

ALTER TABLE interview_messages
    ADD CONSTRAINT fk_msg_confront_finding
    FOREIGN KEY (confront_finding_id) REFERENCES findings(evidence_id) ON DELETE SET NULL;

-- Investigation Board
CREATE TABLE board_nodes (
    node_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id         BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    -- the node POINTS to the original record (exactly one)
    person_id           BIGINT REFERENCES persons(person_id)                 ON DELETE CASCADE,
    evidence_id         BIGINT REFERENCES evidence_items(evidence_id)        ON DELETE CASCADE,
    statement_id        BIGINT REFERENCES statements(statement_id)           ON DELETE CASCADE,
    report_id           BIGINT REFERENCES police_reports(report_id)          ON DELETE CASCADE,
    observation_id      BIGINT REFERENCES police_observations(observation_id) ON DELETE CASCADE,
    timeline_event_id   BIGINT,                                   -- FK added after timeline_events
    note_label          VARCHAR(200),                             -- free sticky note
    pos_x               NUMERIC(10,2) NOT NULL DEFAULT 0,
    pos_y               NUMERIC(10,2) NOT NULL DEFAULT 0,
    color               VARCHAR(20),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(person_id, evidence_id, statement_id, report_id,
                        observation_id, timeline_event_id, note_label) = 1)
);

-- the same record can appear only once on a player's board
CREATE UNIQUE INDEX uq_board_person    ON board_nodes(progress_id, person_id)    WHERE person_id    IS NOT NULL;
CREATE UNIQUE INDEX uq_board_evidence  ON board_nodes(progress_id, evidence_id)  WHERE evidence_id  IS NOT NULL;
CREATE UNIQUE INDEX uq_board_statement ON board_nodes(progress_id, statement_id) WHERE statement_id IS NOT NULL;

CREATE TABLE board_connections (
    connection_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id     BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    from_node_id    BIGINT      NOT NULL REFERENCES board_nodes(node_id) ON DELETE CASCADE,
    to_node_id      BIGINT      NOT NULL REFERENCES board_nodes(node_id) ON DELETE CASCADE,
    relation_type   VARCHAR(30) NOT NULL
                    CHECK (relation_type IN ('found_at', 'mentions', 'contradicts', 'possible_motive',
                                             'seen_with', 'owns', 'related_to', 'custom')),
    custom_label    VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (from_node_id <> to_node_id),
    CHECK (relation_type <> 'custom' OR custom_label IS NOT NULL)
);

-- Investigation Timeline (NOT a "verified" timeline)
CREATE TABLE timeline_events (
    event_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id         BIGINT       NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    event_time          TIMESTAMPTZ  NOT NULL,
    time_precision      VARCHAR(10)  NOT NULL DEFAULT 'exact'
                        CHECK (time_precision IN ('exact', 'approx', 'range')),
    event_time_end      TIMESTAMPTZ,
    title               VARCHAR(200) NOT NULL,
    description         TEXT,
    claim_status        VARCHAR(15)  NOT NULL
                        CHECK (claim_status IN ('documented', 'claim')),
    -- source (exactly one)
    src_evidence_id     BIGINT REFERENCES evidence_items(evidence_id)     ON DELETE CASCADE,
    src_statement_id    BIGINT REFERENCES statements(statement_id)        ON DELETE CASCADE,
    src_report_id       BIGINT REFERENCES police_reports(report_id)       ON DELETE CASCADE,
    src_observation_id  BIGINT REFERENCES police_observations(observation_id) ON DELETE CASCADE,
    src_message_id      BIGINT REFERENCES interview_messages(message_id)  ON DELETE CASCADE,
    linked_person_id    BIGINT REFERENCES persons(person_id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(src_evidence_id, src_statement_id, src_report_id,
                        src_observation_id, src_message_id) = 1),
    CHECK (event_time_end IS NULL OR event_time_end >= event_time),
    -- a statement or interrogation answer can never be "documented"
    CHECK (NOT (claim_status = 'documented'
                AND (src_statement_id IS NOT NULL OR src_message_id IS NOT NULL)))
);

ALTER TABLE board_nodes
    ADD CONSTRAINT fk_board_timeline
    FOREIGN KEY (timeline_event_id) REFERENCES timeline_events(event_id) ON DELETE CASCADE;

-- "Potential Conflict" between two events, marked by the player
CREATE TABLE timeline_conflicts (
    conflict_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id     BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    event_a_id      BIGINT      NOT NULL REFERENCES timeline_events(event_id) ON DELETE CASCADE,
    event_b_id      BIGINT      NOT NULL REFERENCES timeline_events(event_id) ON DELETE CASCADE,
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (event_a_id < event_b_id),
    UNIQUE (event_a_id, event_b_id)
);

-- Notebook
CREATE TABLE notebook_notes (
    note_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id     BIGINT       NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    category        VARCHAR(20)  NOT NULL
                    CHECK (category IN ('observation', 'hypothesis', 'question', 'follow_up')),
    title           VARCHAR(200) NOT NULL,
    body            TEXT,
    is_pinned       BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE note_attachments (
    attachment_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note_id             BIGINT NOT NULL REFERENCES notebook_notes(note_id) ON DELETE CASCADE,
    evidence_id         BIGINT REFERENCES evidence_items(evidence_id)  ON DELETE CASCADE,
    person_id           BIGINT REFERENCES persons(person_id)           ON DELETE CASCADE,
    timeline_event_id   BIGINT REFERENCES timeline_events(event_id)    ON DELETE CASCADE,
    statement_id        BIGINT REFERENCES statements(statement_id)     ON DELETE CASCADE,
    CHECK (num_nonnulls(evidence_id, person_id, timeline_event_id, statement_id) = 1)
);

-- Points ledger + Recent Activity in one place.
-- Every paid action:  UPDATE case_progress SET points_remaining = points_remaining - :cost
--                     WHERE progress_id = :id AND points_remaining >= :cost
--                     + INSERT here, inside ONE transaction.
CREATE TABLE progress_activity (
    activity_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id     BIGINT      NOT NULL REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    action_type     VARCHAR(30) NOT NULL,     -- start_interview, confront, visual_comparison,
                                              -- advanced_enhance, save_finding, add_board_node...
    points_delta    INT         NOT NULL DEFAULT 0 CHECK (points_delta <= 0),
    points_after    INT         NOT NULL CHECK (points_after >= 0),
    ref_evidence_id   BIGINT REFERENCES evidence_items(evidence_id)       ON DELETE SET NULL,
    ref_session_id    BIGINT REFERENCES interview_sessions(session_id)    ON DELETE SET NULL,
    ref_comparison_id BIGINT REFERENCES lab_comparisons(comparison_id)    ON DELETE SET NULL,
    description     VARCHAR(255),
    idempotency_key VARCHAR(100),             -- v3: sent by the client per paid click; a retry never charges twice
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (progress_id, idempotency_key)     -- NULLs allowed for free actions
);

-- Final Conclusion
CREATE TABLE final_conclusions (
    conclusion_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    progress_id         BIGINT       NOT NULL UNIQUE REFERENCES case_progress(progress_id) ON DELETE CASCADE,
    reasoning_text      TEXT         NOT NULL,
    submitted_at        TIMESTAMPTZ,                  -- NULL = draft
    -- Investigation Result (filled only after submit)
    score_people        NUMERIC(5,2),
    score_evidence      NUMERIC(5,2),
    score_timeline      NUMERIC(5,2),
    score_relationships NUMERIC(5,2),
    score_efficiency    NUMERIC(5,2),
    overall_score       NUMERIC(5,2),
    result_details      JSONB          -- correct items, missed clues... for the Result page
);

CREATE TABLE conclusion_people (
    conclusion_id   BIGINT NOT NULL REFERENCES final_conclusions(conclusion_id) ON DELETE CASCADE,
    person_id       BIGINT NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    PRIMARY KEY (conclusion_id, person_id)
);

-- 2–5 findings (count enforced by the API at submit time)
CREATE TABLE conclusion_findings (
    conclusion_id   BIGINT NOT NULL REFERENCES final_conclusions(conclusion_id) ON DELETE CASCADE,
    finding_id      BIGINT NOT NULL REFERENCES findings(evidence_id) ON DELETE CASCADE,
    PRIMARY KEY (conclusion_id, finding_id)
);

CREATE TABLE conclusion_events (
    conclusion_id   BIGINT NOT NULL REFERENCES final_conclusions(conclusion_id) ON DELETE CASCADE,
    event_id        BIGINT NOT NULL REFERENCES timeline_events(event_id) ON DELETE CASCADE,
    order_index     INT    NOT NULL CHECK (order_index >= 1),
    PRIMARY KEY (conclusion_id, event_id),
    UNIQUE (conclusion_id, order_index)
);


-- ---------------------------------------------------------------------
-- (D) GROUND TRUTH  (hidden solution – Admin only)
-- ---------------------------------------------------------------------

CREATE TABLE case_solutions (
    case_id             BIGINT PRIMARY KEY REFERENCES cases(case_id) ON DELETE CASCADE,
    solution_narrative  TEXT   NOT NULL,          -- shown on the Result page after submit
    w_people            NUMERIC(4,2) NOT NULL DEFAULT 0.35,
    w_evidence          NUMERIC(4,2) NOT NULL DEFAULT 0.25,
    w_timeline          NUMERIC(4,2) NOT NULL DEFAULT 0.20,
    w_relationships     NUMERIC(4,2) NOT NULL DEFAULT 0.10,
    w_efficiency        NUMERIC(4,2) NOT NULL DEFAULT 0.10,
    CHECK (w_people + w_evidence + w_timeline + w_relationships + w_efficiency = 1)
);

CREATE TABLE solution_culprits (
    case_id     BIGINT NOT NULL REFERENCES case_solutions(case_id) ON DELETE CASCADE,
    person_id   BIGINT NOT NULL REFERENCES persons(person_id) ON DELETE CASCADE,
    PRIMARY KEY (case_id, person_id)
);

-- critical / supporting / red_herring
CREATE TABLE solution_clues (
    case_id     BIGINT      NOT NULL REFERENCES case_solutions(case_id) ON DELETE CASCADE,
    clue_id     BIGINT      NOT NULL REFERENCES clues(clue_id) ON DELETE CASCADE,
    importance  VARCHAR(15) NOT NULL CHECK (importance IN ('critical', 'supporting', 'red_herring')),
    PRIMARY KEY (case_id, clue_id)
);

-- The actual ordered sequence of events
CREATE TABLE solution_timeline (
    sol_event_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id         BIGINT       NOT NULL REFERENCES case_solutions(case_id) ON DELETE CASCADE,
    seq             INT          NOT NULL,
    title           VARCHAR(200) NOT NULL,
    occurred_at     TIMESTAMPTZ,
    -- how a player's event is recognised as this one (exactly one)
    match_clue_id       BIGINT REFERENCES clues(clue_id)              ON DELETE SET NULL,
    match_statement_id  BIGINT REFERENCES statements(statement_id)    ON DELETE SET NULL,
    match_evidence_id   BIGINT REFERENCES evidence_items(evidence_id) ON DELETE SET NULL,
    UNIQUE (case_id, seq),
    CHECK (num_nonnulls(match_clue_id, match_statement_id, match_evidence_id) = 1)
);

-- Correct relationships expected on the board
CREATE TABLE solution_relationships (
    sol_rel_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id         BIGINT      NOT NULL REFERENCES case_solutions(case_id) ON DELETE CASCADE,
    from_person_id  BIGINT REFERENCES persons(person_id) ON DELETE CASCADE,
    from_clue_id    BIGINT REFERENCES clues(clue_id)     ON DELETE CASCADE,
    to_person_id    BIGINT REFERENCES persons(person_id) ON DELETE CASCADE,
    to_clue_id      BIGINT REFERENCES clues(clue_id)     ON DELETE CASCADE,
    relation_type   VARCHAR(30) NOT NULL,
    CHECK (num_nonnulls(from_person_id, from_clue_id) = 1),
    CHECK (num_nonnulls(to_person_id, to_clue_id) = 1)
);


-- ---------------------------------------------------------------------
-- INDEXES (foreign keys used in every page load)
-- ---------------------------------------------------------------------
CREATE INDEX ix_progress_user      ON case_progress(user_id);
CREATE INDEX ix_persons_case       ON persons(case_id);
CREATE INDEX ix_statements_case    ON statements(case_id);
CREATE INDEX ix_reports_case       ON police_reports(case_id);
CREATE INDEX ix_obs_case           ON police_observations(case_id);
CREATE INDEX ix_evidence_case      ON evidence_items(case_id, origin_type);
CREATE INDEX ix_evidence_progress  ON evidence_items(progress_id) WHERE progress_id IS NOT NULL;
CREATE INDEX ix_regions_case       ON image_regions(case_id);
CREATE INDEX ix_posts_person       ON social_posts(person_id);
CREATE INDEX ix_unlock_trigger     ON unlock_rules(case_id, trigger_clue_id);
CREATE INDEX ix_sessions_progress  ON interview_sessions(progress_id, person_id);
CREATE INDEX ix_messages_session   ON interview_messages(session_id, created_at);
-- v3: the same two nodes cannot be linked twice with the same relation (in either direction)
CREATE UNIQUE INDEX uq_board_link ON board_connections
    (progress_id, LEAST(from_node_id, to_node_id), GREATEST(from_node_id, to_node_id), relation_type);
CREATE INDEX ix_board_nodes_prog   ON board_nodes(progress_id);
CREATE INDEX ix_board_conn_prog    ON board_connections(progress_id);
CREATE INDEX ix_timeline_prog      ON timeline_events(progress_id, event_time);
CREATE INDEX ix_notes_prog         ON notebook_notes(progress_id);
CREATE INDEX ix_activity_prog      ON progress_activity(progress_id, created_at DESC);


-- ---------------------------------------------------------------------
-- VIEW: Evidence page for one player = police materials (visible) + own findings
-- usage:  SELECT * FROM v_player_evidence WHERE viewer_progress_id = :progress_id;
-- ---------------------------------------------------------------------
CREATE VIEW v_player_evidence AS
SELECT cp.progress_id AS viewer_progress_id,
       e.evidence_id, e.origin_type, e.media_type, e.title, e.description,
       e.source, e.status, e.thumbnail_url, e.file_url, e.created_at,
       f.display_code
FROM case_progress cp
JOIN evidence_items e ON e.case_id = cp.case_id
LEFT JOIN findings f  ON f.evidence_id = e.evidence_id
WHERE (e.origin_type = 'investigator' AND e.progress_id = cp.progress_id)
   OR (e.origin_type = 'police' AND (
          e.is_hidden_initially = FALSE
       OR EXISTS (SELECT 1 FROM progress_unlocks pu
                  JOIN unlock_rules ur ON ur.rule_id = pu.rule_id
                  WHERE pu.progress_id = cp.progress_id
                    AND ur.unlock_evidence_id = e.evidence_id)));

-- ---------------------------------------------------------------------
-- (E) INTEGRITY  (v2) – "same case / same player" rules that plain FKs
--     cannot express. Every player-state row may only point to content
--     of ITS case and to findings/events of ITS OWN progress.
-- ---------------------------------------------------------------------

CREATE FUNCTION qd_assert_same_case(
    p_progress    BIGINT,
    p_person      BIGINT DEFAULT NULL, p_evidence   BIGINT DEFAULT NULL,
    p_statement   BIGINT DEFAULT NULL, p_report     BIGINT DEFAULT NULL,
    p_observation BIGINT DEFAULT NULL, p_event      BIGINT DEFAULT NULL,
    p_post        BIGINT DEFAULT NULL, p_scene      BIGINT DEFAULT NULL,
    p_message     BIGINT DEFAULT NULL, p_comparison BIGINT DEFAULT NULL,
    p_knowledge   BIGINT DEFAULT NULL, p_rule       BIGINT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_case BIGINT;
BEGIN
    SELECT case_id INTO v_case FROM case_progress WHERE progress_id = p_progress;
    IF v_case IS NULL THEN RAISE EXCEPTION 'progress % not found', p_progress; END IF;

    IF p_person IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM persons WHERE person_id = p_person AND case_id = v_case) THEN
        RAISE EXCEPTION 'person % is not part of case %', p_person, v_case; END IF;
    IF p_evidence IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM evidence_items WHERE evidence_id = p_evidence AND case_id = v_case
          AND (progress_id IS NULL OR progress_id = p_progress)) THEN
        RAISE EXCEPTION 'evidence % is not available to progress %', p_evidence, p_progress; END IF;
    IF p_statement IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM statements WHERE statement_id = p_statement AND case_id = v_case) THEN
        RAISE EXCEPTION 'statement % is not part of case %', p_statement, v_case; END IF;
    IF p_report IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM police_reports WHERE report_id = p_report AND case_id = v_case) THEN
        RAISE EXCEPTION 'report % is not part of case %', p_report, v_case; END IF;
    IF p_observation IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM police_observations WHERE observation_id = p_observation AND case_id = v_case) THEN
        RAISE EXCEPTION 'observation % is not part of case %', p_observation, v_case; END IF;
    IF p_post IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM social_posts WHERE post_id = p_post AND case_id = v_case) THEN
        RAISE EXCEPTION 'post % is not part of case %', p_post, v_case; END IF;
    IF p_scene IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM crime_scenes WHERE scene_id = p_scene AND case_id = v_case) THEN
        RAISE EXCEPTION 'scene % is not part of case %', p_scene, v_case; END IF;
    IF p_knowledge IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM character_knowledge k JOIN persons pe USING (person_id)
         WHERE k.knowledge_id = p_knowledge AND pe.case_id = v_case) THEN
        RAISE EXCEPTION 'knowledge % is not part of case %', p_knowledge, v_case; END IF;
    IF p_rule IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM unlock_rules WHERE rule_id = p_rule AND case_id = v_case) THEN
        RAISE EXCEPTION 'unlock rule % is not part of case %', p_rule, v_case; END IF;
    -- player-owned things must belong to the SAME player
    IF p_event IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM timeline_events WHERE event_id = p_event AND progress_id = p_progress) THEN
        RAISE EXCEPTION 'timeline event % belongs to another player', p_event; END IF;
    IF p_message IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM interview_messages m JOIN interview_sessions s USING (session_id)
         WHERE m.message_id = p_message AND s.progress_id = p_progress) THEN
        RAISE EXCEPTION 'message % belongs to another player', p_message; END IF;
    IF p_comparison IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM lab_comparisons WHERE comparison_id = p_comparison AND progress_id = p_progress) THEN
        RAISE EXCEPTION 'comparison % belongs to another player', p_comparison; END IF;
END $$;

CREATE FUNCTION trg_check_refs() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_prog BIGINT;
BEGIN
    CASE TG_TABLE_NAME
    WHEN 'interview_sessions' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_person => NEW.person_id);
    WHEN 'interview_messages' THEN
        SELECT progress_id INTO v_prog FROM interview_sessions WHERE session_id = NEW.session_id;
        PERFORM qd_assert_same_case(v_prog, p_evidence => NEW.confront_finding_id);
    WHEN 'progress_revealed_facts' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_knowledge => NEW.knowledge_id, p_message => NEW.message_id);
        -- v3: the fact must belong to the person of the conversation it was revealed in
        IF NEW.message_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM interview_messages m
              JOIN interview_sessions s USING (session_id)
              JOIN character_knowledge k ON k.person_id = s.person_id
             WHERE m.message_id = NEW.message_id AND k.knowledge_id = NEW.knowledge_id) THEN
            RAISE EXCEPTION 'fact % does not belong to the person in message %', NEW.knowledge_id, NEW.message_id;
        END IF;
    WHEN 'progress_unlocks' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_rule => NEW.rule_id);
    WHEN 'lab_comparisons' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_evidence => NEW.a_evidence_id, p_post => NEW.a_post_id);
        PERFORM qd_assert_same_case(NEW.progress_id, p_evidence => NEW.b_evidence_id, p_post => NEW.b_post_id);
        IF NEW.saved_finding_id IS NOT NULL THEN
            PERFORM qd_assert_same_case(NEW.progress_id, p_evidence => NEW.saved_finding_id); END IF;
        IF NEW.matched_rule_id IS NOT NULL THEN                       -- v4
            PERFORM qd_assert_case((SELECT case_id FROM case_progress WHERE progress_id = NEW.progress_id),
                                   'rule_cmp', NEW.matched_rule_id::TEXT); END IF;
    WHEN 'findings' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_scene => NEW.src_scene_id,
            p_evidence => NEW.src_evidence_id, p_post => NEW.src_post_id,
            p_comparison => NEW.src_comparison_id, p_message => NEW.src_message_id);
        -- v4: hidden matching fields must point inside the same case
        PERFORM qd_assert_case((SELECT case_id FROM case_progress WHERE progress_id = NEW.progress_id),
                               'clue', NEW.clue_id::TEXT, 'region', NEW.matched_region_id::TEXT);
    WHEN 'progress_activity' THEN                                     -- v4
        PERFORM qd_assert_same_case(NEW.progress_id, p_evidence => NEW.ref_evidence_id,
                                    p_comparison => NEW.ref_comparison_id);
        IF NEW.ref_session_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM interview_sessions
             WHERE session_id = NEW.ref_session_id AND progress_id = NEW.progress_id) THEN
            RAISE EXCEPTION 'session % belongs to another player', NEW.ref_session_id; END IF;
    WHEN 'board_nodes' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_person => NEW.person_id,
            p_evidence => NEW.evidence_id, p_statement => NEW.statement_id, p_report => NEW.report_id,
            p_observation => NEW.observation_id, p_event => NEW.timeline_event_id);
    WHEN 'board_connections' THEN
        IF (SELECT count(*) FROM board_nodes WHERE node_id IN (NEW.from_node_id, NEW.to_node_id)
              AND progress_id = NEW.progress_id) <> 2 THEN
            RAISE EXCEPTION 'both board nodes must belong to progress %', NEW.progress_id; END IF;
    WHEN 'timeline_events' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_person => NEW.linked_person_id,
            p_evidence => NEW.src_evidence_id, p_statement => NEW.src_statement_id,
            p_report => NEW.src_report_id, p_observation => NEW.src_observation_id,
            p_message => NEW.src_message_id);
    WHEN 'timeline_conflicts' THEN
        PERFORM qd_assert_same_case(NEW.progress_id, p_event => NEW.event_a_id);
        PERFORM qd_assert_same_case(NEW.progress_id, p_event => NEW.event_b_id);
    WHEN 'note_attachments' THEN
        SELECT progress_id INTO v_prog FROM notebook_notes WHERE note_id = NEW.note_id;
        PERFORM qd_assert_same_case(v_prog, p_evidence => NEW.evidence_id, p_person => NEW.person_id,
            p_event => NEW.timeline_event_id, p_statement => NEW.statement_id);
    WHEN 'conclusion_people' THEN
        SELECT progress_id INTO v_prog FROM final_conclusions WHERE conclusion_id = NEW.conclusion_id;
        PERFORM qd_assert_same_case(v_prog, p_person => NEW.person_id);
    WHEN 'conclusion_findings' THEN
        SELECT progress_id INTO v_prog FROM final_conclusions WHERE conclusion_id = NEW.conclusion_id;
        PERFORM qd_assert_same_case(v_prog, p_evidence => NEW.finding_id);
    WHEN 'conclusion_events' THEN
        SELECT progress_id INTO v_prog FROM final_conclusions WHERE conclusion_id = NEW.conclusion_id;
        PERFORM qd_assert_same_case(v_prog, p_event => NEW.event_id);
    END CASE;
    RETURN NEW;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['interview_sessions','interview_messages','progress_revealed_facts',
        'progress_unlocks','lab_comparisons','findings','board_nodes','board_connections',
        'timeline_events','timeline_conflicts','note_attachments',
        'conclusion_people','conclusion_findings','conclusion_events','progress_activity']
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_check_refs()', 'chk_refs_' || t, t);
    END LOOP;
END $$;

-- Final Conclusion rules, checked at the moment of Submit
CREATE FUNCTION trg_conclusion_submit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE n_people INT; n_findings INT;
BEGIN
    IF NEW.submitted_at IS NOT NULL AND OLD.submitted_at IS NULL THEN
        SELECT count(*) INTO n_people   FROM conclusion_people   WHERE conclusion_id = NEW.conclusion_id;
        SELECT count(*) INTO n_findings FROM conclusion_findings WHERE conclusion_id = NEW.conclusion_id;
        IF n_people < 1 THEN RAISE EXCEPTION 'choose at least one person'; END IF;
        IF n_findings NOT BETWEEN 2 AND 5 THEN
            RAISE EXCEPTION 'choose 2 to 5 findings (got %)', n_findings; END IF;
    ELSIF OLD.submitted_at IS NOT NULL AND (
             NEW.reasoning_text IS DISTINCT FROM OLD.reasoning_text
          OR NEW.submitted_at   IS DISTINCT FROM OLD.submitted_at
          OR NEW.progress_id    IS DISTINCT FROM OLD.progress_id) THEN
        -- v4: after submit only the score columns (filled by the backend) may change
        RAISE EXCEPTION 'a submitted conclusion cannot be edited';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER chk_conclusion_submit BEFORE UPDATE ON final_conclusions
    FOR EACH ROW EXECUTE FUNCTION trg_conclusion_submit();

CREATE FUNCTION trg_conclusion_delete() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.submitted_at IS NOT NULL THEN RAISE EXCEPTION 'a submitted conclusion cannot be deleted'; END IF;
    RETURN OLD;
END $$;
CREATE TRIGGER chk_conclusion_delete BEFORE DELETE ON final_conclusions
    FOR EACH ROW WHEN (pg_trigger_depth() = 0)          -- deleting the whole case/progress still cascades
    EXECUTE FUNCTION trg_conclusion_delete();

-- v4: selected people / findings / events are frozen once the conclusion is submitted
CREATE FUNCTION trg_conclusion_items_locked() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT := CASE WHEN TG_OP = 'DELETE' THEN OLD.conclusion_id ELSE NEW.conclusion_id END;
BEGIN
    IF EXISTS (SELECT 1 FROM final_conclusions WHERE conclusion_id IN (v_id, OLD.conclusion_id)
                                                 AND submitted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'conclusion % is already submitted', v_id;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['conclusion_people','conclusion_findings','conclusion_events'] LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW
                        WHEN (pg_trigger_depth() = 0) EXECUTE FUNCTION trg_conclusion_items_locked()',
                       'lock_after_submit_' || t, t);
    END LOOP;
END $$;

-- The ONLY way the backend spends points: atomic, never below 0, always logged.
-- v3: row lock + idempotency key, so a double click / network retry charges once.
-- Returns the balance after the charge, or raises 'not enough points'.
CREATE FUNCTION qd_spend_points(p_progress BIGINT, p_action VARCHAR,
                                p_idempotency_key VARCHAR DEFAULT NULL,
                                p_description VARCHAR DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cost INT; v_after INT; v_prev_action VARCHAR;
BEGIN
    -- lock this player's row: concurrent paid actions of the same player run one at a time
    SELECT CASE p_action
             WHEN 'start_interview'   THEN c.cost_start_interview
             WHEN 'confront'          THEN c.cost_confront
             WHEN 'visual_comparison' THEN c.cost_visual_comparison
             WHEN 'advanced_enhance'  THEN c.cost_advanced_enhance END
      INTO v_cost
      FROM case_progress p JOIN cases c USING (case_id)
     WHERE p.progress_id = p_progress
       FOR UPDATE OF p;
    IF v_cost IS NULL THEN RAISE EXCEPTION 'unknown paid action % or progress %', p_action, p_progress; END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT points_after, action_type INTO v_after, v_prev_action FROM progress_activity
         WHERE progress_id = p_progress AND idempotency_key = p_idempotency_key;
        IF FOUND THEN
            IF v_prev_action <> p_action THEN           -- v4: a key belongs to ONE action
                RAISE EXCEPTION 'idempotency key % was already used for %', p_idempotency_key, v_prev_action;
            END IF;
            RETURN v_after;                             -- already charged: return same result
        END IF;
    END IF;

    UPDATE case_progress
       SET points_remaining = points_remaining - v_cost, last_activity_at = now()
     WHERE progress_id = p_progress AND points_remaining >= v_cost
    RETURNING points_remaining INTO v_after;
    IF v_after IS NULL THEN RAISE EXCEPTION 'not enough points'; END IF;

    INSERT INTO progress_activity(progress_id, action_type, points_delta, points_after,
                                  description, idempotency_key)
    VALUES (p_progress, p_action, -v_cost, v_after, p_description, p_idempotency_key);
    RETURN v_after;
END $$;

-- ---------------------------------------------------------------------
-- v3: same-case rules for ADMIN content (a wrong click in the Admin
--     dashboard must not link a clue / person / region of another case)
-- ---------------------------------------------------------------------
CREATE FUNCTION qd_case_of(p_kind TEXT, p_id BIGINT) RETURNS BIGINT
LANGUAGE sql STABLE AS $$
    SELECT CASE p_kind
      WHEN 'person'      THEN (SELECT case_id FROM persons             WHERE person_id      = p_id)
      WHEN 'evidence'    THEN (SELECT case_id FROM evidence_items      WHERE evidence_id    = p_id)
      WHEN 'statement'   THEN (SELECT case_id FROM statements          WHERE statement_id   = p_id)
      WHEN 'report'      THEN (SELECT case_id FROM police_reports      WHERE report_id      = p_id)
      WHEN 'observation' THEN (SELECT case_id FROM police_observations WHERE observation_id = p_id)
      WHEN 'post'        THEN (SELECT case_id FROM social_posts        WHERE post_id        = p_id)
      WHEN 'scene'       THEN (SELECT case_id FROM crime_scenes        WHERE scene_id       = p_id)
      WHEN 'clue'        THEN (SELECT case_id FROM clues               WHERE clue_id        = p_id)
      WHEN 'region'      THEN (SELECT case_id FROM image_regions       WHERE region_id      = p_id)
      WHEN 'connection'  THEN (SELECT case_id FROM person_connections  WHERE connection_id  = p_id)
      WHEN 'rule_cmp'    THEN (SELECT case_id FROM comparison_rules    WHERE rule_id        = p_id)
    END
$$;

-- raises if any (kind, id) pair belongs to a case other than p_case; NULL ids are skipped
CREATE FUNCTION qd_assert_case(p_case BIGINT, VARIADIC p_refs TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE i INT; v BIGINT;
BEGIN
    FOR i IN 1 .. coalesce(array_length(p_refs, 1), 0) BY 2 LOOP
        CONTINUE WHEN p_refs[i + 1] IS NULL;
        v := qd_case_of(p_refs[i], p_refs[i + 1]::BIGINT);
        IF v IS DISTINCT FROM p_case THEN
            RAISE EXCEPTION '% % belongs to case %, expected case %', p_refs[i], p_refs[i + 1], v, p_case;
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION trg_check_content() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_case BIGINT;
BEGIN
    CASE TG_TABLE_NAME
    WHEN 'cases' THEN
        IF NEW.victim_person_id IS NOT NULL THEN
            PERFORM qd_assert_case(NEW.case_id, 'person', NEW.victim_person_id::TEXT); END IF;
    WHEN 'person_connections' THEN
        PERFORM qd_assert_case(NEW.case_id, 'person', NEW.person_a_id::TEXT, 'person', NEW.person_b_id::TEXT);
    WHEN 'character_knowledge' THEN
        v_case := qd_case_of('person', NEW.person_id);
        PERFORM qd_assert_case(v_case, 'clue', NEW.reveal_clue_id::TEXT);
    WHEN 'evidence_items' THEN
        PERFORM qd_assert_case(NEW.case_id, 'person', NEW.associated_person_id::TEXT);
    WHEN 'police_observations' THEN
        PERFORM qd_assert_case(NEW.case_id, 'evidence', NEW.related_evidence_id::TEXT);
    WHEN 'social_post_tags' THEN
        v_case := qd_case_of('post', NEW.post_id);
        PERFORM qd_assert_case(v_case, 'person', NEW.person_id::TEXT);
    WHEN 'image_regions' THEN
        PERFORM qd_assert_case(NEW.case_id, 'scene', NEW.scene_id::TEXT, 'evidence', NEW.evidence_id::TEXT,
                               'post', NEW.post_id::TEXT, 'clue', NEW.clue_id::TEXT);
    WHEN 'comparison_rules' THEN
        PERFORM qd_assert_case(NEW.case_id, 'region', NEW.region_a_id::TEXT, 'region', NEW.region_b_id::TEXT,
                               'clue', NEW.result_clue_id::TEXT);
    WHEN 'unlock_rules' THEN
        PERFORM qd_assert_case(NEW.case_id, 'clue', NEW.trigger_clue_id::TEXT,
            'person', NEW.trigger_person_id::TEXT,      'person', NEW.unlock_person_id::TEXT,
            'evidence', NEW.unlock_evidence_id::TEXT,   'statement', NEW.unlock_statement_id::TEXT,
            'report', NEW.unlock_report_id::TEXT,       'observation', NEW.unlock_observation_id::TEXT,
            'post', NEW.unlock_post_id::TEXT,           'scene', NEW.unlock_scene_id::TEXT,
            'connection', NEW.unlock_connection_id::TEXT);
    WHEN 'solution_culprits' THEN
        PERFORM qd_assert_case(NEW.case_id, 'person', NEW.person_id::TEXT);
    WHEN 'solution_clues' THEN
        PERFORM qd_assert_case(NEW.case_id, 'clue', NEW.clue_id::TEXT);
    WHEN 'solution_timeline' THEN
        PERFORM qd_assert_case(NEW.case_id, 'clue', NEW.match_clue_id::TEXT,
            'statement', NEW.match_statement_id::TEXT, 'evidence', NEW.match_evidence_id::TEXT);
    WHEN 'solution_relationships' THEN
        PERFORM qd_assert_case(NEW.case_id, 'person', NEW.from_person_id::TEXT, 'clue', NEW.from_clue_id::TEXT,
                               'person', NEW.to_person_id::TEXT,   'clue', NEW.to_clue_id::TEXT);
    END CASE;
    RETURN NEW;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['cases','person_connections','character_knowledge','evidence_items',
        'police_observations','social_post_tags','image_regions','comparison_rules','unlock_rules',
        'solution_culprits','solution_clues','solution_timeline','solution_relationships']
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_check_content()', 'chk_case_' || t, t);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- v4: starting points come from the case, never from the caller
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_progress_init_points() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_initial INT;
BEGIN
    SELECT initial_points INTO v_initial FROM cases WHERE case_id = NEW.case_id;
    IF NEW.points_remaining IS NULL THEN
        NEW.points_remaining := v_initial;
    ELSIF NEW.points_remaining > v_initial THEN
        RAISE EXCEPTION 'points_remaining (%) cannot exceed the case budget (%)', NEW.points_remaining, v_initial;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER init_points BEFORE INSERT ON case_progress
    FOR EACH ROW EXECUTE FUNCTION trg_progress_init_points();

-- ---------------------------------------------------------------------
-- v4: ownership columns are write-once. A row can never be moved to
--     another player, case, conversation, note or conclusion.
--     Columns are passed as trigger arguments.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_immutable_cols() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE c TEXT;
BEGIN
    FOREACH c IN ARRAY TG_ARGV LOOP
        IF to_jsonb(NEW) -> c IS DISTINCT FROM to_jsonb(OLD) -> c THEN
            RAISE EXCEPTION '%.% cannot be changed after creation', TG_TABLE_NAME, c;
        END IF;
    END LOOP;
    RETURN NEW;
END $$;

CREATE TRIGGER ro_owner BEFORE UPDATE ON case_progress           FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('case_id','user_id','is_admin_preview');
CREATE TRIGGER ro_owner BEFORE UPDATE ON evidence_items          FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('case_id','origin_type','progress_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON findings                FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','display_code','created_via','clue_id','matched_region_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON progress_unlocks        FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','rule_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON progress_revealed_facts FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','knowledge_id','message_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON interview_sessions      FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','person_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON interview_messages      FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('session_id','sender_type','message_type','message_text','confront_finding_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON lab_comparisons         FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','a_evidence_id','a_post_id','b_evidence_id','b_post_id','similarity_score','matched_rule_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON board_nodes             FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','person_id','evidence_id','statement_id','report_id','observation_id','timeline_event_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON board_connections       FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','from_node_id','to_node_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON timeline_events         FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','src_evidence_id','src_statement_id','src_report_id','src_observation_id','src_message_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON timeline_conflicts      FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id','event_a_id','event_b_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON notebook_notes          FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON note_attachments        FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('note_id');
CREATE TRIGGER ro_owner BEFORE UPDATE ON final_conclusions       FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols('progress_id');
-- the points ledger is append-only
CREATE FUNCTION trg_ledger_append_only() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'progress_activity is append-only';
END $$;
CREATE TRIGGER ro_ledger BEFORE UPDATE ON progress_activity FOR EACH ROW EXECUTE FUNCTION trg_ledger_append_only();

COMMIT;
