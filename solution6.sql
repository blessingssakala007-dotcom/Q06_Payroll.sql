-- Q6 - Monthly Payroll Processing
-- gross = basic_salary + allowance, net = gross - deduction

-- (a) Tables
CREATE TABLE IF NOT EXISTS employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (pay_month = DATE_TRUNC('month', pay_month)::DATE),
    gross_pay NUMERIC(12,2) NOT NULL,
    net_pay NUMERIC(12,2) NOT NULL,
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE IF NOT EXISTS salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function: net pay from current salary
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT (basic_salary + allowance - deduction) INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay is negative for employee %: %', p_employee_id, v_net;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: process payroll for a month, FOR loop over ACTIVE only
-- Existing row is left unchanged. Invalid employee fails the whole call.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
AS $$
DECLARE
    r RECORD;
    v_gross NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> DATE_TRUNC('month', p_month)::DATE THEN
        RAISE EXCEPTION 'p_month must be the first date of a month, got %', p_month;
    END IF;
    FOR r IN SELECT * FROM employees WHERE active = TRUE ORDER BY employee_id LOOP
        v_gross := r.basic_salary + r.allowance;
        v_net := fn_net_pay(r.employee_id); -- raises if negative, fails whole call
        INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING; -- leave existing unchanged
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: log actual basic_salary changes only
CREATE OR REPLACE FUNCTION trg_salary_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit(employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_salary_audit ON employees;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_salary_audit_fn();

-- (a) Seed data: active + inactive, for 2 months
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
('Chanda Mwila', 8000.00, 1000.00, 500.00, TRUE),
('Grace Banda', 6000.00, 800.00, 400.00, TRUE),
('Peter Phiri', 5000.00, 500.00, 300.00, TRUE),
('Mary Zulu', 7000.00, 900.00, 600.00, FALSE) -- inactive, gets NO new payroll
ON CONFLICT DO NOTHING;

-- Process 2 months, then make one employee inactive to test history in view
CALL pr_process_payroll('2026-01-01');
CALL pr_process_payroll('2026-02-01');
-- Re-run must NOT change existing rows:
CALL pr_process_payroll('2026-01-01');
-- Example salary change (creates 1 audit row):
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;
-- This update must NOT create an audit row (salary unchanged):
UPDATE employees SET allowance = 1100.00 WHERE employee_id = 2;

-- (e) View: report, includes history for later-inactive employees
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index: report filtered by pay_month across all employees
-- Justification: A single-column index on pay_month matches
-- WHERE pay_month = ? exactly. We do NOT create (employee_id, pay_month)
-- again - that already exists as the UNIQUE constraint on payroll.
-- This index is for month-wide reports, not per-employee lookups.
CREATE INDEX IF NOT EXISTS idx_payroll_pay_month
ON payroll(pay_month);

-- Matching query + plan:
-- EXPLAIN SELECT * FROM v_payroll_report WHERE pay_month = '2026-01-01';
EXPLAIN SELECT * FROM payroll WHERE pay_month = '2026-01-01';

-- (g) Scheduled job: 02:00 on 1st of each month, for previous month
-- pg_cron: '0 2 1 * *' = 02:00 on day 1 every month
-- Previous month first date = DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
-- SELECT cron.schedule('process-payroll-monthly', '0 2 1 * *',
--   $$CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE)$$);

-- How to inspect the job and its run history:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Checks:
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;
SELECT fn_net_pay(1);
SELECT * FROM salary_audit;