-- =====================================================================
-- Double-entry ledger schema (PostgreSQL)
-- Everything runs in one DB transaction: if any statement fails,
-- nothing is created.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- Direction of an entry. An ENUM means the database itself rejects
-- anything other than 'debit' or 'credit'.
-- ---------------------------------------------------------------------
CREATE TYPE entry_direction AS ENUM ('debit', 'credit');

-- ---------------------------------------------------------------------
-- Accounts (cash, customer wallets, etc.)
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id       uuid,
    name           text NOT NULL CHECK (name <> ''),
    -- '~' is a regex match: exactly 3 uppercase letters, e.g. NGN, USD
    currency       text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    -- Which side INCREASES this account.
    -- Assets/expenses are usually 'debit'; liabilities/equity/income 'credit'.
    normal_balance entry_direction NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    -- id is already unique, but this composite unique key is required so
    -- that entries can use (id, currency) as a foreign key target (see below).
    UNIQUE (id, currency)
);

CREATE INDEX accounts_owner_id_idx ON accounts (owner_id);

-- ---------------------------------------------------------------------
-- Transactions: just a header that groups entries together.
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    description text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Entries: the individual debit/credit lines.
-- ---------------------------------------------------------------------
CREATE TABLE entries (
    -- GENERATED ALWAYS: Postgres assigns the id, you can't set it manually.
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id uuid NOT NULL REFERENCES transactions (id),
    account_id     uuid NOT NULL,
    direction      entry_direction NOT NULL,
    -- Minor units (kobo/cents) as integers: no floating-point errors.
    -- Always positive; the sign comes from `direction`.
    amount         bigint NOT NULL CHECK (amount > 0),
    currency       text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    -- Composite FK: the entry's currency must equal its account's currency,
    -- so you can never post NGN into a USD account.
    FOREIGN KEY (account_id, currency) REFERENCES accounts (id, currency)
);

-- Postgres does NOT auto-index foreign key columns, so add them.
CREATE INDEX entries_transaction_id_idx ON entries (transaction_id);
CREATE INDEX entries_account_id_idx     ON entries (account_id);

-- ---------------------------------------------------------------------
-- Balance check: every transaction must have entries, and for each
-- currency, total debits must equal total credits.
-- One function serves triggers on BOTH tables.
-- ---------------------------------------------------------------------
CREATE FUNCTION check_transaction_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    tx_id uuid;
BEGIN
    -- If fired from `transactions`, the id is NEW.id.
    -- If fired from `entries`, the id is NEW.transaction_id.
    IF TG_TABLE_NAME = 'transactions' THEN
        tx_id := NEW.id;
    ELSE
        tx_id := NEW.transaction_id;
    END IF;

    -- A transaction with zero entries is invalid.
    IF NOT EXISTS (SELECT 1 FROM entries WHERE transaction_id = tx_id) THEN
        RAISE EXCEPTION 'transaction % has no entries', tx_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Debits count as +amount, credits as -amount. Grouped per currency,
    -- any non-zero sum means that currency is out of balance.
    IF EXISTS (
        SELECT 1
        FROM entries
        WHERE transaction_id = tx_id
        GROUP BY currency
        HAVING sum(CASE direction WHEN 'debit' THEN amount ELSE -amount END) <> 0
    ) THEN
        RAISE EXCEPTION 'transaction % is not balanced', tx_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Return value is ignored for AFTER triggers, but a function must return.
    RETURN NULL;
END;
$$;

-- DEFERRABLE INITIALLY DEFERRED = the check runs at COMMIT, not per row.
-- Without it, inserting the first entry would fail because the offsetting
-- entry doesn't exist yet. Insert the transaction + all its entries in one
-- DB transaction and the check happens once, when everything is in.
CREATE CONSTRAINT TRIGGER transactions_balanced
    AFTER INSERT ON transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();

CREATE CONSTRAINT TRIGGER entries_balanced
    AFTER INSERT ON entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();

-- ---------------------------------------------------------------------
-- Immutability: the ledger is append-only. To fix a mistake, post a
-- new reversing transaction instead of editing history.
-- ---------------------------------------------------------------------
CREATE FUNCTION forbid_ledger_changes() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only, post a reversing transaction instead', TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER transactions_append_only
    BEFORE UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION forbid_ledger_changes();

CREATE TRIGGER entries_append_only
    BEFORE UPDATE OR DELETE ON entries
    FOR EACH ROW EXECUTE FUNCTION forbid_ledger_changes();

-- TRUNCATE bypasses row-level triggers, so block it with statement-level ones.
CREATE TRIGGER transactions_no_truncate
    BEFORE TRUNCATE ON transactions
    FOR EACH STATEMENT EXECUTE FUNCTION forbid_ledger_changes();

CREATE TRIGGER entries_no_truncate
    BEFORE TRUNCATE ON entries
    FOR EACH STATEMENT EXECUTE FUNCTION forbid_ledger_changes();

-- ---------------------------------------------------------------------
-- Balances view. An entry on the account's normal side increases the
-- balance; on the opposite side it decreases it.
-- LEFT JOIN keeps accounts with no entries; coalesce turns NULL into 0.
-- Grouping by a.id alone is valid because id is the primary key, so
-- Sname and currency are functionally dependent on it.
-- ---------------------------------------------------------------------
CREATE VIEW account_balances AS
SELECT
    a.id AS account_id,
    a.name,
    a.currency,
    coalesce(sum(
        CASE WHEN e.direction = a.normal_balance THEN e.amount ELSE -e.amount END
    ), 0)::bigint AS balance
FROM accounts a
LEFT JOIN entries e ON e.account_id = a.id
GROUP BY a.id;

COMMIT;
