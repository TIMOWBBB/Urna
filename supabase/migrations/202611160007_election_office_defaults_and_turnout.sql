BEGIN;

-- Preload common offices so administrators can activate the election format they need.
INSERT INTO public.election_offices (name, active, sort_order)
VALUES
  ('Presidente da República', false, 10),
  ('Governador', false, 20),
  ('Senador', false, 30),
  ('Deputado Federal', false, 40),
  ('Deputado Estadual', false, 50),
  ('Deputado Distrital', false, 60),
  ('Prefeito', false, 70),
  ('Vereador', false, 80)
ON CONFLICT (name) DO NOTHING;

-- The public ballot reads the office identifier from the candidates table.
GRANT SELECT (office_id) ON public.candidates TO anon, authenticated;

REVOKE ALL ON FUNCTION public.public_election_offices() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_election_offices() TO anon, authenticated;

-- A voter is marked complete only after voting in every active office for its current round.
CREATE OR REPLACE FUNCTION public.admin_voter_list()
RETURNS TABLE(display_name text, voted boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  RETURN QUERY
  SELECT
    v.display_name,
    EXISTS (SELECT 1 FROM public.election_offices WHERE active)
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
    ) AS voted
  FROM public.voters AS v
  WHERE v.eligible
  ORDER BY v.display_name;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
