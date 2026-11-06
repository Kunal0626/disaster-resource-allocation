-- ---------------------------------------------------------------------------
-- tools/capabilities.sql -- Phase 1 feature probe.
--
-- Purpose: prove, on the server you are actually pointed at, that every SQL
-- feature this project relies on works. The project targets MySQL 8.0.16+
-- (8.0.16 is the version where CHECK constraints began to be enforced rather
-- than parsed and ignored). Rather than assume, we check.
--
-- Design of the probe:
--   * Tables, triggers and functions are created at the TOP level, because
--     MySQL forbids creating a trigger or routine from inside a routine
--     (error 1303).
--   * Statements that are SUPPOSED to fail run inside a procedure with a
--     CONTINUE HANDLER, so we can capture the error number and compare it to
--     the one we expect. A test that expects an error and gets silence is a
--     failure, which is exactly what the trigger tests in Phase 4 will need.
--   * Results go into a table; run.sh prints it afterwards in a separate
--     connection, so we still see partial results if the script aborts.
--   * The last row, 'probe_completed', is a sentinel: if it is missing, the
--     script died partway and the client's error output says where.
-- ---------------------------------------------------------------------------

DROP DATABASE IF EXISTS dra_probe_tmp;
CREATE DATABASE dra_probe_tmp;
USE dra_probe_tmp;

CREATE TABLE probe_result (
  seq     INT AUTO_INCREMENT PRIMARY KEY,
  feature VARCHAR(48)  NOT NULL,
  verdict VARCHAR(6)   NOT NULL,
  detail  VARCHAR(160) NOT NULL DEFAULT ''
) ENGINE=InnoDB;

-- === 1. InnoDB is the default engine =======================================
-- Everything here needs row-level locking, transactions and foreign keys.
-- MyISAM has none of the three.
INSERT INTO probe_result (feature, verdict, detail)
SELECT 'innodb_is_default',
       IF(@@default_storage_engine = 'InnoDB', 'PASS', 'FAIL'),
       CONCAT('default_storage_engine=', @@default_storage_engine);

-- === 2. CHECK constraints are ENFORCED =====================================
CREATE TABLE t_check (
  n INT NOT NULL,
  CONSTRAINT ck_positive CHECK (n > 0)
) ENGINE=InnoDB;

-- === 3. SIGNAL SQLSTATE '45000' from a trigger =============================
-- This is how every Phase 4 guard trigger will reject bad data.
CREATE TABLE t_signal (n INT NOT NULL) ENGINE=InnoDB;

DELIMITER $$
CREATE TRIGGER trg_t_signal_bi BEFORE INSERT ON t_signal
FOR EACH ROW
BEGIN
  IF NEW.n > 3 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'probe: refused';
  END IF;
END$$
DELIMITER ;

-- === 4. Generated (computed) columns, STORED ===============================
-- Used for items.is_perishable and center_stock.available, so that a value
-- which is derivable cannot be stored inconsistently.
CREATE TABLE t_generated (
  a INT NOT NULL,
  b INT NOT NULL,
  total INT GENERATED ALWAYS AS (a + b) STORED
) ENGINE=InnoDB;
INSERT INTO t_generated (a, b) VALUES (2, 3);

INSERT INTO probe_result (feature, verdict, detail)
SELECT 'generated_column_stored',
       IF(total = 5, 'PASS', 'FAIL'),
       CONCAT('2+3 computed as ', total)
FROM t_generated;

-- === 5. "Partial unique index" emulation ===================================
-- MySQL has no partial / filtered indexes, so we cannot write
--   UNIQUE (center_id, item_id) WHERE status = 'open'
-- the way PostgreSQL can. The workaround: generated columns that are NULL
-- unless the row is open. A multi-column UNIQUE index in MySQL ignores rows
-- where any indexed column is NULL, so resolved rows never collide while open
-- rows are held unique. stock_alerts in Phase 2 depends on this.
CREATE TABLE t_partial (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  center_id INT NOT NULL,
  item_id   INT NOT NULL,
  status    ENUM('open','resolved') NOT NULL,
  open_center_id INT GENERATED ALWAYS AS (IF(status = 'open', center_id, NULL)) STORED,
  open_item_id   INT GENERATED ALWAYS AS (IF(status = 'open', item_id,   NULL)) STORED,
  UNIQUE KEY uq_one_open_alert (open_center_id, open_item_id)
) ENGINE=InnoDB;

INSERT INTO t_partial (center_id, item_id, status) VALUES (1, 1, 'open');
INSERT INTO t_partial (center_id, item_id, status) VALUES (1, 1, 'resolved');
INSERT INTO t_partial (center_id, item_id, status) VALUES (1, 1, 'resolved');

INSERT INTO probe_result (feature, verdict, detail)
SELECT 'partial_unique_allows_resolved_dupes',
       IF(COUNT(*) = 3, 'PASS', 'FAIL'),
       CONCAT(COUNT(*), ' rows accepted (expected 3: 1 open + 2 resolved)')
FROM t_partial;

-- === 6. Composite foreign keys =============================================
-- requests will carry both area_id and disaster_id. A two-column FK makes it
-- impossible for them to disagree, without needing a trigger to police it.
CREATE TABLE t_parent (
  a INT NOT NULL PRIMARY KEY,
  b INT NOT NULL,
  UNIQUE KEY uq_ab (a, b)
) ENGINE=InnoDB;

CREATE TABLE t_child (
  id INT AUTO_INCREMENT PRIMARY KEY,
  a  INT NOT NULL,
  b  INT NOT NULL,
  CONSTRAINT fk_child_ab FOREIGN KEY (a, b) REFERENCES t_parent (a, b)
) ENGINE=InnoDB;

INSERT INTO t_parent (a, b) VALUES (1, 10);
INSERT INTO t_child (a, b) VALUES (1, 10);

-- === 7. ON DELETE CASCADE blocked by a downstream RESTRICT =================
-- The schema relies on this: deleting a request cascades to request_items,
-- but request_items is RESTRICTed by allocations, so a request with
-- allocation history cannot be deleted at all. Worth proving, not assuming.
CREATE TABLE t_req (id INT NOT NULL PRIMARY KEY) ENGINE=InnoDB;
CREATE TABLE t_req_item (
  id     INT NOT NULL PRIMARY KEY,
  req_id INT NOT NULL,
  CONSTRAINT fk_ri_req FOREIGN KEY (req_id) REFERENCES t_req (id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE t_alloc (
  id      INT NOT NULL PRIMARY KEY,
  ri_id   INT NOT NULL,
  CONSTRAINT fk_al_ri FOREIGN KEY (ri_id) REFERENCES t_req_item (id) ON DELETE RESTRICT
) ENGINE=InnoDB;
INSERT INTO t_req VALUES (1);
INSERT INTO t_req_item VALUES (1, 1);
INSERT INTO t_alloc VALUES (1, 1);

-- === 8. Window functions ===================================================
INSERT INTO probe_result (feature, verdict, detail)
SELECT 'window_function_row_number',
       IF(MAX(rn) = 3, 'PASS', 'FAIL'),
       CONCAT('max ROW_NUMBER() = ', MAX(rn))
FROM (
  SELECT ROW_NUMBER() OVER (ORDER BY n) AS rn
  FROM (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3) AS s
) AS w;

-- === 9. Recursive CTE ======================================================
-- regions is a hierarchy (state -> district), walked with WITH RECURSIVE.
INSERT INTO probe_result (feature, verdict, detail)
WITH RECURSIVE counter (n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM counter WHERE n < 5
)
SELECT 'recursive_cte',
       IF(SUM(n) = 15, 'PASS', 'FAIL'),
       CONCAT('sum 1..5 = ', SUM(n))
FROM counter;

-- === 10. GROUP BY ... WITH ROLLUP ==========================================
INSERT INTO probe_result (feature, verdict, detail)
SELECT 'group_by_rollup',
       IF(COUNT(*) = 3, 'PASS', 'FAIL'),
       CONCAT(COUNT(*), ' rows (expected 2 groups + 1 rollup total)')
FROM (
  SELECT g, SUM(v) AS s
  FROM (SELECT 'a' AS g, 1 AS v UNION ALL SELECT 'a', 2 UNION ALL SELECT 'b', 3) AS s
  GROUP BY g WITH ROLLUP
) AS r;

-- === 11. INSERT ... ON DUPLICATE KEY UPDATE as an atomic no-op =============
-- The low-stock trigger uses this instead of "check then insert". A check
-- followed by an insert is a race: two sessions can both pass the check and
-- then one hits the unique index, which would abort the stock update that
-- fired the trigger. The upsert cannot race.
INSERT INTO t_partial (center_id, item_id, status) VALUES (1, 1, 'open')
  ON DUPLICATE KEY UPDATE id = id;

INSERT INTO probe_result (feature, verdict, detail)
SELECT 'upsert_noop_on_duplicate',
       IF(COUNT(*) = 1, 'PASS', 'FAIL'),
       CONCAT(COUNT(*), ' open row(s) after a duplicate upsert (expected 1)')
FROM t_partial WHERE status = 'open';

-- === Negative tests: things that MUST be rejected ==========================
DELIMITER $$
CREATE PROCEDURE probe_negative_tests()
BEGIN
  DECLARE v_errno    INT          DEFAULT 0;
  DECLARE v_sqlstate CHAR(5)      DEFAULT '';
  DECLARE v_msg      VARCHAR(255) DEFAULT '';
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1
      v_errno = MYSQL_ERRNO, v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;

  -- 2b. CHECK must reject n = -1 with errno 3819.
  SET v_errno = 0;
  INSERT INTO t_check (n) VALUES (-1);
  INSERT INTO probe_result (feature, verdict, detail)
  VALUES ('check_constraint_enforced',
          IF(v_errno = 3819, 'PASS', 'FAIL'),
          CONCAT('errno=', v_errno, ' expected 3819; ', LEFT(v_msg, 90)));

  -- 3b. The trigger must raise 45000 / errno 1644 with our exact message.
  SET v_errno = 0; SET v_sqlstate = ''; SET v_msg = '';
  INSERT INTO t_signal (n) VALUES (5);
  INSERT INTO probe_result (feature, verdict, detail)
  VALUES ('trigger_signal_45000',
          IF(v_errno = 1644 AND v_sqlstate = '45000' AND v_msg = 'probe: refused', 'PASS', 'FAIL'),
          CONCAT('errno=', v_errno, ' sqlstate=', v_sqlstate, ' msg="', LEFT(v_msg, 60), '"'));

  -- 5b. A second OPEN row for the same (center,item) must be rejected: 1062.
  SET v_errno = 0;
  INSERT INTO t_partial (center_id, item_id, status) VALUES (1, 1, 'open');
  INSERT INTO probe_result (feature, verdict, detail)
  VALUES ('partial_unique_blocks_second_open',
          IF(v_errno = 1062, 'PASS', 'FAIL'),
          CONCAT('errno=', v_errno, ' expected 1062 (duplicate key)'));

  -- 6b. Composite FK must reject the pair (1,11): parent holds only (1,10).
  SET v_errno = 0;
  INSERT INTO t_child (a, b) VALUES (1, 11);
  INSERT INTO probe_result (feature, verdict, detail)
  VALUES ('composite_fk_rejects_mismatch',
          IF(v_errno = 1452, 'PASS', 'FAIL'),
          CONCAT('errno=', v_errno, ' expected 1452 (no referenced row)'));

  -- 7b. Deleting the parent must fail: the CASCADE hits a RESTRICT below it.
  SET v_errno = 0;
  DELETE FROM t_req WHERE id = 1;
  INSERT INTO probe_result (feature, verdict, detail)
  VALUES ('cascade_blocked_by_restrict',
          IF(v_errno = 1451, 'PASS', 'FAIL'),
          CONCAT('errno=', v_errno, ' expected 1451 (child row constraint)'));
END$$

-- === 12. SELECT ... FOR UPDATE inside an explicit transaction ==============
-- The whole concurrency story in Phase 5 and 7 rests on this.
CREATE PROCEDURE probe_for_update()
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE v_n     INT DEFAULT -1;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    GET DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO;

  START TRANSACTION;
  SELECT a INTO v_n FROM t_generated WHERE a = 2 FOR UPDATE;
  ROLLBACK;

  INSERT INTO probe_result (feature, verdict, detail)
  VALUES ('select_for_update',
          IF(v_errno = 0 AND v_n = 2, 'PASS', 'FAIL'),
          CONCAT('errno=', v_errno, ' locked row a=', v_n));
END$$
DELIMITER ;

CALL probe_negative_tests();
CALL probe_for_update();

-- === 13. Creating a DETERMINISTIC function =================================
-- Deliberately last. If binary logging is on and log_bin_trust_function_
-- creators is off, this fails with errno 1418 and the script stops here --
-- which is itself the answer, and every result above is already recorded.
-- haversine_km() in Phase 5 is exactly this kind of function.
CREATE FUNCTION probe_double(x DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
  NO SQL
  RETURN x * 2;

INSERT INTO probe_result (feature, verdict, detail)
SELECT 'create_deterministic_function',
       IF(probe_double(2) = 4, 'PASS', 'FAIL'),
       'probe_double(2) = 4';

-- === Sentinel ==============================================================
INSERT INTO probe_result (feature, verdict, detail)
VALUES ('probe_completed', 'PASS', 'every probe statement ran to the end');
