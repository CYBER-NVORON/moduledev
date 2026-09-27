-- Four total attempts; the three retries wait 200, 400 and 800 ms.
-- Keep already applied migrations and their checksums unchanged.
SET ROLE course_owner;

CREATE OR REPLACE FUNCTION delivery.fail_outbox(
    p_outbox_id uuid, p_owner text, p_lease_version bigint, p_error_code text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    UPDATE delivery.outbox SET last_error_code=p_error_code,
        state=CASE WHEN p_error_code LIKE '%.retryable' AND attempt_count < 4
                   THEN 'RETRY_WAIT' ELSE 'DEAD' END,
        next_attempt_at=CASE
            WHEN p_error_code LIKE '%.retryable' AND attempt_count BETWEEN 1 AND 3
            THEN now()+interval '1 millisecond'*(ARRAY[200,400,800])[attempt_count]
            ELSE next_attempt_at
        END
    WHERE outbox_id=p_outbox_id AND lease_owner=p_owner
      AND lease_version=p_lease_version AND state='LEASED';
    RETURN jsonb_build_object('updated',FOUND);
END;
$$;

RESET ROLE;
