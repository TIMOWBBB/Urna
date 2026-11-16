BEGIN;

-- A urna deve receber somente os cargos habilitados pelo administrador.
CREATE OR REPLACE FUNCTION public.public_election_offices()
RETURNS TABLE(id uuid, name text, sort_order integer, round integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT o.id, o.name, o.sort_order, o.round
  FROM public.election_offices AS o
  WHERE o.active IS TRUE
  ORDER BY o.sort_order, o.name;
$function$;

REVOKE ALL ON FUNCTION public.public_election_offices() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_election_offices() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
