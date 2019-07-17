-- This script is a reimplementation of `20181108205650_additional_internal_transaction_constraints.sql`
-- that is meant to be executed on clones (or with the app is not running) of DBs
-- where the number of transactions and/or internal_transactions is very large.
-- One can check in real time, from another client, how many transactions have
-- been updated to have their internal_transactions refetched, by executing:
-- > SELECT last_value FROM updated_transactions_number;
-- NOTE: the sequence value may to be stuck for long periods of time, while the
-- function is fetching a batch.
-- ALSO NOTE: the sequence will be dropped when all updates have been performed,
-- but before the VALIDATE CONSTRAINT are executed (see the end)

-- CREATE A SEQUENCE TO BE ABLE TO CHECK THE PROGRESS FROM ANOTHER CLIENT
CREATE SEQUENCE updated_transactions_number;
DO $$
DECLARE
   batch_size  integer := 10000; -- HOW MANY ITEMS WILL BE UPDATED AT A TIME
   last_transaction_hash bytea; -- WILL CHECK ONLY TRANSACTIONS FOLLOWING THIS HASH (DESC)
   more_to_check boolean;
BEGIN
  CREATE TEMP TABLE transactions_with_deprecated_internal_transactions(hash bytea NOT NULL);

  LOOP
    INSERT INTO transactions_with_deprecated_internal_transactions
    SELECT DISTINCT transaction_hash
    FROM internal_transactions
    WHERE
      (last_transaction_hash IS NULL OR transaction_hash < last_transaction_hash) AND
      -- call_has_call_type CONSTRAINT
      ((type = 'call' AND call_type IS NULL) OR
      -- call_has_input CONSTRAINT
      (type = 'call' AND input IS NULL) OR
      -- create_has_init CONSTRAINT
      (type = 'create' AND init is NULL))
    ORDER BY transaction_hash DESC LIMIT batch_size;

    -- UPDATE TRANSACTIONS AND THE SEQUENCE VISIBLE FROM OUTSIDE
    UPDATE transactions
    SET internal_transactions_indexed_at = NULL,
        error = NULL
    FROM transactions_with_deprecated_internal_transactions
    WHERE transactions.hash = transactions_with_deprecated_internal_transactions.hash
    AND nextval('updated_transactions_number') IS NOT NULL;

    -- REMOVE THE DEPRECATED internal_transaction
    DELETE FROM internal_transactions
    USING transactions_with_deprecated_internal_transactions
    WHERE internal_transactions.transaction_hash = transactions_with_deprecated_internal_transactions.hash;

    -- COMMIT THE BATCH UPDATES
    CHECKPOINT;

   -- EXIT IF ALL internal_transactions HAVE BEEN CHECKED ALREADY
    SELECT INTO more_to_check count(*) = batch_size FROM transactions_with_deprecated_internal_transactions;
    EXIT WHEN NOT more_to_check;


    -- UPDATE last_transaction_hash TO KEEP TRACK OF ROWS ALREADY CHECKED
    SELECT INTO last_transaction_hash hash
    FROM transactions_with_deprecated_internal_transactions
    ORDER BY hash ASC LIMIT 1;

    -- CLEAR THE TEMP TABLE
    DELETE FROM transactions_with_deprecated_internal_transactions;
  END LOOP;

  DROP SEQUENCE updated_transactions_number;
  DROP TABLE transactions_with_deprecated_internal_transactions;

  -- VALIDATE ALL THE CONSTRAINT
  ALTER TABLE internal_transactions VALIDATE CONSTRAINT call_has_call_type;
  ALTER TABLE internal_transactions VALIDATE CONSTRAINT call_has_input;
  ALTER TABLE internal_transactions VALIDATE CONSTRAINT create_has_init;
END $$;
