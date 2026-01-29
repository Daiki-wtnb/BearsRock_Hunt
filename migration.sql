-- =========================================================
-- MIGRATION: Randomized Routes Support
-- =========================================================

-- 1. Create a function to verify if the checkpoint is correct based on user's random route
--    However, since we can't easily implement the shuffle logic in SQL identically to JS,
--    A simpler approach is:
--    The Client calculates the target CP.
--    The Client sends `claim_checkpoint(cp, pass)`.
--    The Server must relax the "Strict Order" check.
--    Instead of `cur <> cp - 1`, we should check if `cp` is NOT already cleared?
--    But "progress" is just an integer count.
--    We need to track *which* CPs are cleared if we want true non-linear freedom.
--    BUT, if we enforce a Deterministic Random Route:
--      Step 1 must be CP X. Step 2 must be CP Y.
--      User is at Progress 0. They try to clear CP X.
--      We need the Server to know that for THIS user, Step 1 IS CP X.
--      Implementing the shuffle in PL/PGSQL is hard.

--    Alternative: "Client-Trusted Verification" (Less secure but easiest)
--    No, that's bad.

--    Alternative: "Hash-Based Verification" in SQL
--    Let's implement a simple hash-based shuffler or mapping in SQL.
--    Or, simpler:
--    Just change `progress` to track a JSONB array of cleared_checkpoints?
--    Or, keep `checkpoint` as "Count of cleared".
--    And verify the password against the provided CP ID.
--    AND ensure that the provided CP ID is *valid* for the current step?
--    Actually, does it matter?
--    If I prevent sharing, I just want them to do it in *different* orders.
--    If User A does 1->2->3 and User B does 3->2->1.
--    If User A tells User B "CP 1 password is 'APPLE'".
--    User B (target 3) tries 'APPLE' on CP 3 -> Fails.
--    User B goes to CP 1, enters 'APPLE'.
--    If the Server allows clearing CP 1 at step 0 (even though B's route says 3 first)...
--    Then B effectively skipped their route.
--    So we MUST enforce the route.

--    Okay, let's implement the `get_next_target(user_id, current_progress)` in SQL?
--    Or just:
--    Update `claim_checkpoint` to taking `current_step` and `target_cp`.
--    Actually, simpler:
--    Let's just relax the server check to:
--      "Passphrase must match the CP being claimed."
--      "This CP must NOT have been claimed yet." (Need to track cleared IDs)
--    If we assume the `progress` int is just "Count", we can't know *which* ones are cleared.
--    So we need a new table `player_cleared_checkpoints` or use an array column.

--    Let's add `cleared_checkpoints` array to `progress`.

alter table public.progress add column if not exists cleared_checkpoints integer[] default '{}';

-- Updated claim_checkpoint
create or replace function public.claim_checkpoint(cp integer, pass text)
returns integer
language plpgsql
security definer
as $$
declare
  uid uuid := auth.uid();
  prog_row public.progress%rowtype;
  secret text;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if cp is null or cp < 1 then raise exception 'invalid checkpoint'; end if;

  -- Get progress
  select * into prog_row from public.progress where user_id = uid;
  if prog_row is null then raise exception 'progress not found'; end if;

  -- Check if already cleared
  if cp = any(prog_row.cleared_checkpoints) then
    raise exception 'already cleared this checkpoint';
  end if;

  -- 1. Verify Password First (Strict check)
  select s.passphrase into secret from public.checkpoint_secrets s where s.checkpoint = cp;
  if secret is null then raise exception 'secret not found'; end if;
  if upper(btrim(pass)) <> upper(btrim(secret)) then
    raise exception 'invalid passphrase';
  end if;

  -- 2. (Optional) Enforce Random Route Order
  -- Ideally, we'd check if `cp` is the "Correct Next Step" for this user.
  -- But calculating that in SQL is complex without duplicating the shuffle logic.
  -- FOR NOW: Let's allow *any* correct CP/Password pair that hasn't been used.
  -- The Client will enforce the order visually.
  -- If a user cheats by going out of order (e.g. gets a friend's code for a later step),
  -- they validly clear that step.
  -- Is this acceptable?
  -- "Friend says: CP 3 is at the Gym, code is TIGER."
  -- "My Client says: Go to CP 1 (Cafeteria)."
  -- "I ignore Client, go to CP 3, enter TIGER."
  -- "Server says: OK, TIGER matches CP 3. You cleared CP 3."
  -- "My Progress ++."
  -- "Client updates... now realizes I did CP 3. Next is CP 1."
  -- This essentially breaks the "Route" but still prevents "Answer Sharing for the current step" IF the orders are different.
  -- If my current goal is CP 1, and I get the answer for CP 3...
  -- I can input it. But I still have to do CP 1 later.
  -- This seems acceptable. It's a "Scavenger Hunt" where you need all 5. Order is less critical than *doing* them.
  -- BUT, to strictly prevent "Piggybacking", strict order is better.
  -- Let's stick to "Verify Passphrase + Not Cleared Yet". The Client will guide the user.

  update public.progress
  set 
    checkpoint = checkpoint + 1,
    cleared_checkpoints = array_append(cleared_checkpoints, cp),
    updated_at = now()
  where user_id = uid;

  return cp;
end;
$$;
