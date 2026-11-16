BEGIN;

-- Each office has its own candidate list and runoff state.
CREATE TABLE public.election_offices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  round integer NOT NULL DEFAULT 1 CHECK (round IN (1, 2)),
  CONSTRAINT election_offices_name_nonempty CHECK (length(btrim(name)) > 0)
);

INSERT INTO public.election_offices (name, active, sort_order)
VALUES ('Presidente da Câmara dos Deputados', true, 0)
ON CONFLICT (name) DO NOTHING;

ALTER TABLE public.election_offices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.election_offices FROM PUBLIC, anon, authenticated;

ALTER TABLE public.candidates ADD COLUMN office_id uuid;
ALTER TABLE public.ballots ADD COLUMN office_id uuid;
ALTER TABLE public.participation ADD COLUMN office_id uuid;

-- ballots is immutable during normal operation; allow this one-time backfill only.
CREATE OR REPLACE FUNCTION public.block_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_TABLE_NAME = 'ballots'
     AND TG_OP = 'DELETE'
     AND current_setting('app.allow_ballot_reset', true) = 'on' THEN
    RETURN OLD;
  END IF;

  IF TG_TABLE_NAME = 'ballots'
     AND TG_OP = 'UPDATE'
     AND current_setting('app.allow_election_office_migration', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'voters'
     AND TG_OP = 'DELETE'
     AND current_setting('app.allow_voter_delete', true) = 'on' THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'registro imutável';
END;
$$;

DO $$
DECLARE
  v_default_office uuid;
BEGIN
  SELECT id INTO STRICT v_default_office
  FROM public.election_offices
  WHERE name = 'Presidente da Câmara dos Deputados';

  PERFORM set_config('app.allow_election_office_migration', 'on', true);

  UPDATE public.candidates
  SET office_id = v_default_office
  WHERE office_id IS NULL;

  UPDATE public.ballots
  SET office_id = v_default_office
  WHERE office_id IS NULL;

  UPDATE public.participation
  SET office_id = v_default_office
  WHERE office_id IS NULL;
END;
$$;

ALTER TABLE public.candidates
  ALTER COLUMN office_id SET NOT NULL,
  ADD CONSTRAINT candidates_office_id_fkey
    FOREIGN KEY (office_id) REFERENCES public.election_offices(id);

ALTER TABLE public.ballots
  ALTER COLUMN office_id SET NOT NULL,
  ADD CONSTRAINT ballots_office_id_fkey
    FOREIGN KEY (office_id) REFERENCES public.election_offices(id);

ALTER TABLE public.participation
  ALTER COLUMN office_id SET NOT NULL,
  DROP CONSTRAINT participation_pkey,
  ADD CONSTRAINT participation_pkey PRIMARY KEY (voter_id, round, office_id),
  ADD CONSTRAINT participation_office_id_fkey
    FOREIGN KEY (office_id) REFERENCES public.election_offices(id);

ALTER TABLE public.candidates
  DROP CONSTRAINT candidates_number_key,
  ADD CONSTRAINT candidates_office_number_key UNIQUE (office_id, number);

CREATE INDEX ballots_office_round_idx ON public.ballots (office_id, round);
CREATE INDEX participation_office_round_idx ON public.participation (office_id, round);

-- Public ballot configuration. Only active offices are returned.
CREATE OR REPLACE FUNCTION public.public_election_offices()
RETURNS TABLE(id uuid, name text, sort_order integer, round integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.id, o.name, o.sort_order, o.round
  FROM public.election_offices AS o
  WHERE o.active
  ORDER BY o.sort_order, o.name;
$$;

CREATE OR REPLACE FUNCTION public.admin_office_list()
RETURNS TABLE(office_id uuid, name text, active boolean, sort_order integer, round integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  RETURN QUERY
  SELECT o.id, o.name, o.active, o.sort_order, o.round
  FROM public.election_offices AS o
  ORDER BY o.sort_order, o.name;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_save_election_office(
  p_id uuid,
  p_name text,
  p_active boolean,
  p_sort_order integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_status text;
  v_action text;
  v_active boolean := COALESCE(p_active, true);
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'cargo_nome_obrigatorio';
  END IF;

  SELECT status INTO v_status
  FROM public.election_config
  WHERE id = 1
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'configuracao_inexistente';
  END IF;
  IF v_status NOT IN ('draft', 'paused') THEN
    RAISE EXCEPTION 'cargos_bloqueados';
  END IF;
  IF EXISTS (SELECT 1 FROM public.ballots)
     OR EXISTS (SELECT 1 FROM public.participation) THEN
    RAISE EXCEPTION 'cargos_bloqueados_com_votos';
  END IF;

  IF NOT v_active AND NOT EXISTS (
    SELECT 1
    FROM public.election_offices
    WHERE active
      AND (p_id IS NULL OR id <> p_id)
  ) THEN
    RAISE EXCEPTION 'cargo_ativo_obrigatorio';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.election_offices (name, active, sort_order)
    VALUES (v_name, v_active, COALESCE(p_sort_order, 0))
    RETURNING id INTO v_id;
    v_action := 'election_office_created';
  ELSE
    UPDATE public.election_offices
    SET name = v_name,
        active = v_active,
        sort_order = COALESCE(p_sort_order, 0)
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'cargo_nao_encontrado';
    END IF;
    v_action := 'election_office_updated';
  END IF;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (
    auth.uid(),
    v_action,
    jsonb_build_object(
      'office_id', v_id,
      'name', v_name,
      'active', v_active,
      'sort_order', COALESCE(p_sort_order, 0)
    )
  );

  RETURN v_id;
END;
$$;

-- Candidate assignment is now scoped to an office.
DROP FUNCTION public.admin_save_candidate(uuid, text, text, text, text, text, boolean, boolean);

CREATE FUNCTION public.admin_save_candidate(
  p_id uuid,
  p_office_id uuid,
  p_number text,
  p_name text,
  p_party text,
  p_state text,
  p_photo_url text DEFAULT NULL,
  p_active boolean DEFAULT true,
  p_runoff_eligible boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_action text;
  v_status text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  SELECT status INTO v_status
  FROM public.election_config
  WHERE id = 1;
  IF v_status NOT IN ('draft', 'paused') THEN
    RAISE EXCEPTION 'candidaturas_bloqueadas';
  END IF;

  IF p_office_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.election_offices WHERE id = p_office_id
  ) THEN
    RAISE EXCEPTION 'cargo_nao_encontrado';
  END IF;

  IF NULLIF(btrim(p_number), '') IS NULL
     OR NULLIF(btrim(p_name), '') IS NULL
     OR NULLIF(btrim(p_party), '') IS NULL
     OR NULLIF(btrim(p_state), '') IS NULL THEN
    RAISE EXCEPTION 'dados_obrigatorios';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.candidates
      (office_id, number, name, party, state, photo_url, active, runoff_eligible)
    VALUES
      (p_office_id, btrim(p_number), btrim(p_name), btrim(p_party), btrim(p_state),
       NULLIF(btrim(COALESCE(p_photo_url, '')), ''),
       COALESCE(p_active, true), COALESCE(p_runoff_eligible, false))
    RETURNING id INTO v_id;
    v_action := 'candidate_created';
  ELSE
    IF EXISTS (
      SELECT 1
      FROM public.ballots
      WHERE candidate_id = p_id
        AND office_id IS DISTINCT FROM p_office_id
    ) THEN
      RAISE EXCEPTION 'candidato_possui_votos';
    END IF;

    UPDATE public.candidates
    SET office_id = p_office_id,
        number = btrim(p_number),
        name = btrim(p_name),
        party = btrim(p_party),
        state = btrim(p_state),
        photo_url = NULLIF(btrim(COALESCE(p_photo_url, '')), ''),
        active = COALESCE(p_active, true),
        runoff_eligible = COALESCE(p_runoff_eligible, false)
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'candidato_nao_encontrado';
    END IF;
    v_action := 'candidate_updated';
  END IF;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (
    auth.uid(),
    v_action,
    jsonb_build_object(
      'candidate_id', v_id,
      'office_id', p_office_id,
      'number', btrim(p_number),
      'name', btrim(p_name),
      'party', btrim(p_party),
      'state', btrim(p_state),
      'active', COALESCE(p_active, true),
      'runoff_eligible', COALESCE(p_runoff_eligible, false)
    )
  );

  RETURN v_id;
END;
$$;

-- A voter casts one ballot per active office; finalized offices are skipped in a later runoff.
DROP FUNCTION public.cast_vote(text, text);

CREATE FUNCTION public.cast_vote(
  p_office_id uuid,
  p_kind text,
  p_number text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cfg public.election_config%ROWTYPE;
  v public.voters%ROWTYPE;
  o public.election_offices%ROWTYPE;
  c uuid;
BEGIN
  SELECT * INTO cfg
  FROM public.election_config
  WHERE id = 1
  FOR SHARE;

  IF cfg.id IS NULL
     OR cfg.status <> 'open'
     OR now() < COALESCE(cfg.starts_at, '-infinity')
     OR now() > COALESCE(cfg.ends_at, 'infinity') THEN
    RAISE EXCEPTION 'votacao_fechada';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('candidate', 'blank', 'null') THEN
    RAISE EXCEPTION 'tipo_invalido';
  END IF;

  SELECT * INTO o
  FROM public.election_offices
  WHERE id = p_office_id AND active
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cargo_inativo';
  END IF;

  SELECT * INTO v
  FROM public.voters
  WHERE auth_user_id = auth.uid() AND eligible
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'eleitor_nao_habilitado';
  END IF;

  IF p_kind = 'candidate' THEN
    SELECT id INTO c
    FROM public.candidates
    WHERE office_id = o.id
      AND number = p_number
      AND active
      AND (o.round = 1 OR runoff_eligible);
    IF c IS NULL THEN
      RAISE EXCEPTION 'candidato_inexistente';
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.participation (voter_id, round, office_id)
    VALUES (v.id, o.round, o.id);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'ja_votou';
  END;

  INSERT INTO public.ballots (round, office_id, kind, candidate_id)
  VALUES (o.round, o.id, p_kind, c);
END;
$$;

CREATE OR REPLACE FUNCTION public.my_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_eligible boolean;
  v_active_count integer;
  v_pending jsonb;
BEGIN
  SELECT id INTO v_id
  FROM public.voters
  WHERE auth_user_id = auth.uid() AND eligible
  LIMIT 1;
  v_eligible := v_id IS NOT NULL;

  SELECT count(*) INTO v_active_count
  FROM public.election_offices
  WHERE active;

  SELECT COALESCE(
    jsonb_agg(o.id ORDER BY o.sort_order, o.name),
    '[]'::jsonb
  ) INTO v_pending
  FROM public.election_offices AS o
  WHERE o.active
    AND v_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.participation AS p
      WHERE p.voter_id = v_id
        AND p.office_id = o.id
        AND p.round = o.round
    );

  RETURN jsonb_build_object(
    'eligible', v_eligible,
    'voted', v_eligible AND v_active_count > 0 AND jsonb_array_length(v_pending) = 0,
    'active_offices', v_active_count,
    'pending_offices', v_pending
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_turnout()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_eligible integer;
  v_voted integer;
  v_offices jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  SELECT count(*) INTO v_eligible
  FROM public.voters
  WHERE eligible;

  SELECT count(*) INTO v_voted
  FROM public.voters AS v
  WHERE v.eligible
    AND EXISTS (SELECT 1 FROM public.election_offices WHERE active)
    AND NOT EXISTS (
      SELECT 1
      FROM public.election_offices AS o
      WHERE o.active
        AND NOT EXISTS (
          SELECT 1
          FROM public.participation AS p
          WHERE p.voter_id = v.id
            AND p.office_id = o.id
            AND p.round = o.round
        )
    );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'office_id', o.id,
        'name', o.name,
        'round', o.round,
        'voted', (
          SELECT count(*)
          FROM public.participation AS p
          WHERE p.office_id = o.id AND p.round = o.round
        ),
        'eligible', v_eligible
      )
      ORDER BY o.sort_order, o.name
    ),
    '[]'::jsonb
  ) INTO v_offices
  FROM public.election_offices AS o
  WHERE o.active;

  RETURN jsonb_build_object(
    'eligible', v_eligible,
    'voted', v_voted,
    'pending', GREATEST(v_eligible - v_voted, 0),
    'pct', CASE WHEN v_eligible = 0 THEN 0 ELSE round(100.0 * v_voted / v_eligible, 1) END,
    'offices', v_offices
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_tally()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cfg public.election_config%ROWTYPE;
  o record;
  e integer;
  v_completed integer;
  v_total integer := 0;
  v_valid integer := 0;
  v_blank integer := 0;
  v_null integer := 0;
  v_office_total integer;
  v_office_valid integer;
  v_office_blank integer;
  v_office_null integer;
  v_office_participants integer;
  v_candidates jsonb;
  v_offices jsonb := '[]'::jsonb;
  v_top_votes integer;
  v_second_votes integer;
  v_quorum_ok boolean;
  v_all_quorum boolean := true;
  v_won boolean;
  v_needs_runoff boolean;
  v_any_runoff boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  SELECT * INTO cfg
  FROM public.election_config
  WHERE id = 1;
  IF cfg.status <> 'closed' THEN
    RAISE EXCEPTION 'apuracao_so_apos_encerramento';
  END IF;

  SELECT count(*) INTO e
  FROM public.voters
  WHERE eligible;

  IF NOT EXISTS (SELECT 1 FROM public.election_offices WHERE active) THEN
    RAISE EXCEPTION 'nenhum_cargo_ativo';
  END IF;

  SELECT count(*) INTO v_completed
  FROM public.voters AS v
  WHERE v.eligible
    AND NOT EXISTS (
      SELECT 1
      FROM public.election_offices AS active_office
      WHERE active_office.active
        AND NOT EXISTS (
          SELECT 1
          FROM public.participation AS p
          WHERE p.voter_id = v.id
            AND p.office_id = active_office.id
            AND p.round = active_office.round
        )
    );

  FOR o IN
    SELECT id, name, sort_order, round
    FROM public.election_offices
    WHERE active
    ORDER BY sort_order, name
  LOOP
    SELECT
      count(*)::integer,
      count(*) FILTER (WHERE kind = 'candidate')::integer,
      count(*) FILTER (WHERE kind = 'blank')::integer,
      count(*) FILTER (WHERE kind = 'null')::integer
    INTO v_office_total, v_office_valid, v_office_blank, v_office_null
    FROM public.ballots
    WHERE office_id = o.id AND round = o.round;

    SELECT count(*)::integer INTO v_office_participants
    FROM public.participation
    WHERE office_id = o.id AND round = o.round;

    SELECT COALESCE(
      jsonb_agg(x.candidate ORDER BY x.votes DESC, x.number),
      '[]'::jsonb
    ) INTO v_candidates
    FROM (
      SELECT
        jsonb_build_object(
          'candidate_id', c.id,
          'number', c.number,
          'name', c.name,
          'party', c.party,
          'votes', count(b.id)::integer,
          'pct', CASE
            WHEN v_office_valid = 0 THEN 0
            ELSE round(100.0 * count(b.id) / v_office_valid, 2)
          END
        ) AS candidate,
        count(b.id)::integer AS votes,
        c.number
      FROM public.candidates AS c
      LEFT JOIN public.ballots AS b
        ON b.candidate_id = c.id
       AND b.office_id = o.id
       AND b.round = o.round
       AND b.kind = 'candidate'
      WHERE c.office_id = o.id
        AND c.active
        AND (o.round = 1 OR c.runoff_eligible)
      GROUP BY c.id
    ) AS x;

    v_top_votes := COALESCE((v_candidates->0->>'votes')::integer, 0);
    v_second_votes := COALESCE((v_candidates->1->>'votes')::integer, 0);
    v_quorum_ok := v_office_participants * 100 >= cfg.quorum_pct * e;

    v_won := v_quorum_ok
      AND v_top_votes > 0
      AND CASE cfg.majority_rule
        WHEN 'plurality' THEN v_top_votes > v_second_votes
        WHEN 'absolute_valid' THEN v_top_votes * 2 > v_office_valid
        ELSE v_top_votes * 2 > e
      END;

    v_needs_runoff := NOT v_won
      AND v_quorum_ok
      AND cfg.runoff_enabled
      AND o.round = 1
      AND jsonb_array_length(v_candidates) >= 2;

    IF NOT v_quorum_ok THEN
      v_all_quorum := false;
    END IF;
    v_any_runoff := v_any_runoff OR v_needs_runoff;
    v_total := v_total + v_office_total;
    v_valid := v_valid + v_office_valid;
    v_blank := v_blank + v_office_blank;
    v_null := v_null + v_office_null;

    v_offices := v_offices || jsonb_build_array(
      jsonb_build_object(
        'office_id', o.id,
        'name', o.name,
        'round', o.round,
        'eligible', e,
        'participants', v_office_participants,
        'total', v_office_total,
        'valid', v_office_valid,
        'blank', v_office_blank,
        'null', v_office_null,
        'candidates', v_candidates,
        'quorum_ok', v_quorum_ok,
        'winner', CASE WHEN v_won THEN v_candidates->0 ELSE NULL END,
        'needs_runoff', v_needs_runoff
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'round', cfg.round,
    'eligible', e,
    'completed', v_completed,
    'total', v_total,
    'valid', v_valid,
    'blank', v_blank,
    'null', v_null,
    'quorum_ok', v_all_quorum AND (v_completed * 100 >= cfg.quorum_pct * e),
    'offices', v_offices,
    'winner', CASE
      WHEN jsonb_array_length(v_offices) = 1 THEN v_offices->0->'winner'
      ELSE NULL
    END,
    'needs_runoff', v_any_runoff
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_start_runoff()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tally jsonb;
  v_office jsonb;
  v_office_id uuid;
  v_first_id uuid;
  v_second_id uuid;
  v_started integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  v_tally := public.admin_tally();

  FOR v_office IN
    SELECT value
    FROM jsonb_array_elements(v_tally->'offices') AS entries(value)
    WHERE (value->>'needs_runoff')::boolean
  LOOP
    v_office_id := (v_office->>'office_id')::uuid;
    v_first_id := (v_office->'candidates'->0->>'candidate_id')::uuid;
    v_second_id := (v_office->'candidates'->1->>'candidate_id')::uuid;

    IF v_first_id IS NULL OR v_second_id IS NULL THEN
      RAISE EXCEPTION 'segundo_turno_nao_aplicavel';
    END IF;

    UPDATE public.candidates AS c
    SET runoff_eligible = c.id IN (v_first_id, v_second_id)
    WHERE c.office_id = v_office_id
      AND c.runoff_eligible IS DISTINCT FROM (c.id IN (v_first_id, v_second_id));

    UPDATE public.election_offices
    SET round = 2
    WHERE id = v_office_id AND round = 1;
    v_started := v_started + 1;
  END LOOP;

  IF v_started = 0 THEN
    RAISE EXCEPTION 'segundo_turno_nao_aplicavel';
  END IF;

  UPDATE public.election_config
  SET round = 2, status = 'draft'
  WHERE id = 1 AND status = 'closed';

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (auth.uid(), 'runoff', v_tally);
END;
$$;

-- Reset returns each office to round one and keeps the existing audit/count behavior.
CREATE OR REPLACE FUNCTION public.admin_reset_votes(p_confirm text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_ballots integer := 0;
  v_participation integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;
  IF COALESCE(p_confirm, '') <> 'RESETAR VOTOS' THEN
    RAISE EXCEPTION 'confirmacao_invalida';
  END IF;

  SELECT status INTO v_status
  FROM public.election_config
  WHERE id = 1
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'configuracao_inexistente';
  END IF;
  IF v_status NOT IN ('paused', 'closed') THEN
    RAISE EXCEPTION 'reset_exige_votacao_suspensa_ou_encerrada';
  END IF;

  PERFORM set_config('app.allow_ballot_reset', 'on', true);

  DELETE FROM public.ballots
  WHERE EXISTS (
    SELECT 1 FROM public.election_config WHERE id = 1
  );
  GET DIAGNOSTICS v_ballots = ROW_COUNT;

  DELETE FROM public.participation
  WHERE EXISTS (
    SELECT 1 FROM public.election_config WHERE id = 1
  );
  GET DIAGNOSTICS v_participation = ROW_COUNT;

  UPDATE public.candidates
  SET runoff_eligible = false
  WHERE runoff_eligible IS DISTINCT FROM false;

  UPDATE public.election_offices
  SET round = 1
  WHERE round <> 1;

  UPDATE public.election_config
  SET status = 'paused', round = 1
  WHERE id = 1;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (
    auth.uid(),
    'election_votes_reset',
    jsonb_build_object(
      'previous_status', v_status,
      'new_status', 'paused',
      'round_reset_to', 1,
      'ballots_deleted', v_ballots,
      'participation_deleted', v_participation
    )
  );

  RETURN jsonb_build_object(
    'ballots_deleted', v_ballots,
    'participation_deleted', v_participation,
    'status', 'paused',
    'round', 1
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_office_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_office_list() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_save_election_office(uuid, text, boolean, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_save_election_office(uuid, text, boolean, integer) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_save_candidate(uuid, uuid, text, text, text, text, text, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_save_candidate(uuid, uuid, text, text, text, text, text, boolean, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_start_runoff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_start_runoff() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_reset_votes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_votes(text) TO authenticated;
REVOKE ALL ON FUNCTION public.cast_vote(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cast_vote(uuid, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.my_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_status() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_turnout() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_turnout() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_tally() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_tally() TO authenticated;
GRANT EXECUTE ON FUNCTION public.public_election_offices() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
