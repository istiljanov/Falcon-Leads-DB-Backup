


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "api";


ALTER SCHEMA "api" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."call_outcome" AS ENUM (
    'called_no_answer',
    'called_answered_busy',
    'called_successful_conversation'
);


ALTER TYPE "public"."call_outcome" OWNER TO "postgres";


CREATE TYPE "public"."callback_preset" AS ENUM (
    'one_hour',
    'later_today',
    'tomorrow',
    'custom'
);


ALTER TYPE "public"."callback_preset" OWNER TO "postgres";


CREATE TYPE "public"."interaction_type_enum" AS ENUM (
    'field_edit',
    'dropdown_change',
    'textarea_edit',
    'phone_edit',
    'notes_edit',
    'assignment_change',
    'rating_change',
    'status_change'
);


ALTER TYPE "public"."interaction_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."next_action_type" AS ENUM (
    'schedule_callback',
    'appointment',
    'contract_discussion',
    'rejection',
    'none'
);


ALTER TYPE "public"."next_action_type" OWNER TO "postgres";


CREATE TYPE "public"."scraper_task_status" AS ENUM (
    'new',
    'in_progress',
    'completed',
    'blocked',
    'cancelled'
);


ALTER TYPE "public"."scraper_task_status" OWNER TO "postgres";


CREATE TYPE "public"."scraper_task_type" AS ENUM (
    'agent',
    'inventory'
);


ALTER TYPE "public"."scraper_task_type" OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."scraper_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "region" "text" NOT NULL,
    "city" "text",
    "area" "text",
    "target_lead_count" integer NOT NULL,
    "current_lead_count" integer DEFAULT 0 NOT NULL,
    "status" "public"."scraper_task_status" DEFAULT 'new'::"public"."scraper_task_status" NOT NULL,
    "task_type" "public"."scraper_task_type" DEFAULT 'agent'::"public"."scraper_task_type" NOT NULL,
    "assigned_scraper_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "source_agent_order_id" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "property_type" "text",
    "multiplier" numeric DEFAULT 4,
    "qualified_lead_count" integer,
    "linked_agent_total_leads" integer,
    "linked_agent_delivered_leads" integer,
    CONSTRAINT "scraper_tasks_current_lead_count_check" CHECK (("current_lead_count" >= 0)),
    CONSTRAINT "scraper_tasks_target_lead_count_check" CHECK (("target_lead_count" > 0))
);


ALTER TABLE "public"."scraper_tasks" OWNER TO "postgres";


COMMENT ON COLUMN "public"."scraper_tasks"."source_agent_order_id" IS 'Link to the lead_generation_task that requested these leads';



COMMENT ON COLUMN "public"."scraper_tasks"."multiplier" IS 'Multiplier applied to target leads for agent-type tasks';



COMMENT ON COLUMN "public"."scraper_tasks"."qualified_lead_count" IS 'Target count of qualified leads for the linked agent task';



CREATE OR REPLACE FUNCTION "public"."api_assign_scraper_task"("p_task_id" "uuid", "p_scraper_id" "uuid") RETURNS "public"."scraper_tasks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_role text;
  v_task public.scraper_tasks;
  v_assigned_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role not in ('admin','management') then
    raise exception 'Only admin/management can assign scraper tasks';
  end if;

  if p_scraper_id is null then
    raise exception 'assigned_scraper_id is required';
  end if;
  select role into v_assigned_role from public.profiles where id = p_scraper_id;
  if v_assigned_role not in ('scrape','scraper') then
    raise exception 'Assigned user must have scraper role';
  end if;

  update public.scraper_tasks
  set assigned_scraper_id = p_scraper_id,
      status = case when status = 'new' then status else status end,
      updated_at = now()
  where id = p_task_id
  returning * into v_task;

  if not found then
    raise exception 'Task not found';
  end if;

  return v_task;
end;
$$;


ALTER FUNCTION "public"."api_assign_scraper_task"("p_task_id" "uuid", "p_scraper_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."scraper_tasks_scraper_view" AS
 SELECT "id",
    "region",
    "city",
    "area",
    "property_type",
    "target_lead_count",
    "current_lead_count",
    "status",
    "task_type",
    "assigned_scraper_id",
    "created_at",
    "updated_at",
    "source_agent_order_id",
    "multiplier",
    "qualified_lead_count",
    "linked_agent_total_leads",
    "linked_agent_delivered_leads"
   FROM "public"."scraper_tasks";


ALTER VIEW "public"."scraper_tasks_scraper_view" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_complete_my_scraper_task"("p_task_id" "uuid", "p_current_lead_count" integer DEFAULT NULL::integer) RETURNS "public"."scraper_tasks_scraper_view"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_role text;
  v_task public.scraper_tasks;
  v_result public.scraper_tasks_scraper_view%rowtype;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role NOT IN ('scrape','scraper') THEN
    RAISE EXCEPTION 'Only scrapers can complete tasks';
  END IF;
  IF p_current_lead_count IS NOT NULL AND p_current_lead_count < 0 THEN
    RAISE EXCEPTION 'current_lead_count cannot be negative';
  END IF;
  UPDATE public.scraper_tasks
  SET status = 'completed',
        current_lead_count = COALESCE(p_current_lead_count, current_lead_count),
        updated_at = NOW()
  WHERE id = p_task_id
    AND assigned_scraper_id = auth.uid()
  RETURNING * INTO v_task;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found or not assigned to you';
  END IF;
  SELECT *
    INTO v_result
  FROM public.scraper_tasks_scraper_view
  WHERE id = v_task.id;
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."api_complete_my_scraper_task"("p_task_id" "uuid", "p_current_lead_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type" DEFAULT 'agent'::"public"."scraper_task_type", "p_target_lead_count" integer DEFAULT NULL::integer, "p_qualified_lead_count" integer DEFAULT NULL::integer, "p_multiplier" numeric DEFAULT 4, "p_city" "text" DEFAULT NULL::"text", "p_area" "text" DEFAULT NULL::"text", "p_source_agent_order_id" "uuid" DEFAULT NULL::"uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."scraper_tasks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_role text;
  v_final_target integer;
  v_task public.scraper_tasks;
  v_assigned_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role not in ('admin','management') then
    raise exception 'Only admin/management can create scraper tasks';
  end if;

  if p_assigned_scraper_id is null then
    raise exception 'assigned_scraper_id is required';
  end if;

  select role into v_assigned_role from public.profiles where id = p_assigned_scraper_id;
  if v_assigned_role not in ('scrape','scraper') then
    raise exception 'Assigned user must have scraper role';
  end if;

  v_final_target := coalesce(
    p_target_lead_count,
    case when p_qualified_lead_count is not null then ceil(p_qualified_lead_count * coalesce(p_multiplier, 4))::int end,
    p_qualified_lead_count
  );

  if v_final_target is null or v_final_target <= 0 then
    raise exception 'Target lead count is required';
  end if;

  insert into public.scraper_tasks (
    region,
    city,
    area,
    target_lead_count,
    current_lead_count,
    status,
    task_type,
    assigned_scraper_id,
    created_by,
    source_agent_order_id,
    notes
  )
  values (
    p_region,
    p_city,
    p_area,
    v_final_target,
    0,
    'new',
    coalesce(p_task_type, 'agent'),
    p_assigned_scraper_id,
    auth.uid(),
    p_source_agent_order_id,
    p_notes
  )
  returning * into v_task;

  return v_task;
end;
$$;


ALTER FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type" DEFAULT 'agent'::"public"."scraper_task_type", "p_target_lead_count" integer DEFAULT NULL::integer, "p_qualified_lead_count" integer DEFAULT NULL::integer, "p_multiplier" numeric DEFAULT 4, "p_city" "text" DEFAULT NULL::"text", "p_area" "text" DEFAULT NULL::"text", "p_source_agent_order_id" "uuid" DEFAULT NULL::"uuid", "p_notes" "text" DEFAULT NULL::"text", "p_property_type" "text" DEFAULT NULL::"text") RETURNS "public"."scraper_tasks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_role text;
  v_final_target integer;
  v_task public.scraper_tasks;
  v_assigned_role text;
  v_linked_total integer;
  v_linked_delivered integer;
BEGIN
  select role into v_role from public.profiles where id = auth.uid();
  if v_role not in ('admin','management') then
    raise exception 'Only admin/management can create scraper tasks';
  end if;
  if p_assigned_scraper_id is null then
    raise exception 'assigned_scraper_id is required';
  end if;
  select role into v_assigned_role from public.profiles where id = p_assigned_scraper_id;
  if v_assigned_role not in ('scrape','scraper') then
    raise exception 'Assigned user must have scraper role';
  end if;
  v_final_target := coalesce(
    p_target_lead_count,
    case when p_qualified_lead_count is not null then ceil(p_qualified_lead_count * coalesce(p_multiplier, 4))::int end,
    p_qualified_lead_count
  );
  if v_final_target is null or v_final_target <= 0 then
    raise exception 'Target lead count is required';
  end if;
  -- Lookup linked agent task details if p_source_agent_order_id is provided
  IF p_source_agent_order_id IS NOT NULL THEN
    SELECT total_leads_needed, delivered_leads_count
    INTO v_linked_total, v_linked_delivered
    FROM public.lead_generation_tasks
    WHERE id = p_source_agent_order_id;
  END IF;
  insert into public.scraper_tasks (
    region,
    city,
    area,
    target_lead_count,
    current_lead_count,
    status,
    task_type,
    assigned_scraper_id,
    created_by,
    source_agent_order_id,
    notes,
    linked_agent_total_leads,
    linked_agent_delivered_leads,
    property_type,
    multiplier,
    qualified_lead_count
  )
  values (
    p_region,
    p_city,
    p_area,
    v_final_target,
    0,
    'new',
    coalesce(p_task_type, 'agent'),
    p_assigned_scraper_id,
    auth.uid(),
    p_source_agent_order_id,
    p_notes,
    v_linked_total,
    v_linked_delivered,
    p_property_type,
    p_multiplier,
    p_qualified_lead_count
  )
  returning * into v_task;
  return v_task;
END;
$$;


ALTER FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text", "p_property_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_get_my_scraper_task"("p_task_id" "uuid") RETURNS "public"."scraper_tasks_scraper_view"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_task public.scraper_tasks_scraper_view;
BEGIN
  IF NOT is_scraper(auth.uid()) THEN
    RAISE EXCEPTION 'Only scraper users can view assigned scraper tasks';
  END IF;
  SELECT *
    INTO v_task
  FROM public.scraper_tasks_scraper_view
  WHERE id = p_task_id
    AND assigned_scraper_id = auth.uid()
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found or not assigned to you';
  END IF;
  RETURN v_task;
END;
$$;


ALTER FUNCTION "public"."api_get_my_scraper_task"("p_task_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_list_my_scraper_tasks"() RETURNS SETOF "public"."scraper_tasks_scraper_view"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT is_scraper(auth.uid()) THEN
    RAISE EXCEPTION 'Only scraper users can view assigned scraper tasks';
  END IF;
  RETURN QUERY
    SELECT *
    FROM public.scraper_tasks_scraper_view
    WHERE assigned_scraper_id = auth.uid();
END;
$$;


ALTER FUNCTION "public"."api_list_my_scraper_tasks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_list_scraper_tasks"() RETURNS SETOF "public"."scraper_tasks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin_or_management(auth.uid()) then
    raise exception 'Only admin/management can list scraper tasks';
  end if;

  return query
  select *
  from public.scraper_tasks;
end;
$$;


ALTER FUNCTION "public"."api_list_scraper_tasks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_assignment_notification_trigger"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS trigger_notify_assignment_change ON %I', table_name);
  EXECUTE format('
    CREATE TRIGGER trigger_notify_assignment_change
      AFTER UPDATE OF assigned_agent_id ON %I
      FOR EACH ROW
      WHEN (NEW.assigned_agent_id IS NOT NULL AND OLD.assigned_agent_id IS DISTINCT FROM NEW.assigned_agent_id)
      EXECUTE FUNCTION notify_agent_assignment_change()
  ', table_name);
END;
$$;


ALTER FUNCTION "public"."apply_assignment_notification_trigger"("table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."apply_assignment_notification_trigger"("table_name" "text") IS 'Attaches notify_agent_assignment_change() to a listing table.';



CREATE OR REPLACE FUNCTION "public"."apply_email_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  job_email text;
BEGIN
  SELECT email INTO job_email
  FROM scrape_jobs
  WHERE id = NEW.job_id;

  IF job_email IS NOT NULL AND LENGTH(TRIM(job_email)) > 0 THEN
    NEW.email := job_email;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."apply_email_from_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_phone_override_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  job_phone_override text;
BEGIN
  -- Get phone_override from the parent scrape_jobs record using job_id
  SELECT phone_override INTO job_phone_override
  FROM scrape_jobs
  WHERE id = NEW.job_id;

  -- If job has phone_override, unconditionally apply it to both phone_override and fixed_phone
  -- fixed_phone is the dedicated field that won't be touched by scraper
  -- This ensures user input always takes precedence
  IF job_phone_override IS NOT NULL AND LENGTH(TRIM(job_phone_override)) > 0 THEN
    NEW.phone_override := job_phone_override;
    NEW.fixed_phone := job_phone_override;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."apply_phone_override_from_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_task_lead_trigger_to_table"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
EXECUTE format('DROP TRIGGER IF EXISTS trigger_auto_task_lead_on_sent ON %I', table_name);

EXECUTE format('
CREATE TRIGGER trigger_auto_task_lead_on_sent
AFTER UPDATE ON %I
FOR EACH ROW
WHEN (OLD.assignment_status IS DISTINCT FROM NEW.assignment_status)
EXECUTE FUNCTION auto_create_task_lead_on_sent()
', table_name);

RAISE NOTICE 'Applied task_lead trigger to table: %', table_name;
END;
$$;


ALTER FUNCTION "public"."apply_task_lead_trigger_to_table"("table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."apply_task_lead_trigger_to_table"("table_name" "text") IS 'Applies the task_lead management trigger to a listing table. Creates/removes task_leads based on assignment_status changes.';



CREATE OR REPLACE FUNCTION "public"."archive_listing"("p_listing_id" "text", "p_source_table_name" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
v_listing_data record;
v_user_role text;
v_listing_uuid uuid;
BEGIN
SELECT role INTO v_user_role
FROM profiles
WHERE id = auth.uid();

IF v_user_role != 'admin' THEN
RAISE EXCEPTION 'Only admin users can archive listings';
END IF;

v_listing_uuid := p_listing_id::uuid;

EXECUTE format(
'SELECT * FROM %I WHERE id = $1',
p_source_table_name
) INTO v_listing_data USING v_listing_uuid;

IF v_listing_data IS NULL THEN
RAISE EXCEPTION 'Listing not found in source table: %', p_listing_id;
END IF;

INSERT INTO archived_listings (
original_listing_id,
original_table_name,
job_id,
external_id,
internal_id,
title,
title_de,
description,
description_de,
price,
area_sqm,
rooms,
bedrooms,
bathrooms,
city,
ebay_url,
images,
added_on_platform,
scraped_at,
status,
anbieter_type,
anbieter_type_de,
provision,
provision_de,
has_phone,
phone,
views,
seller_name,
plot_area,
year_built,
floors,
assigned_agent_id,
assignment_status,
archived_by
) VALUES (
v_listing_data.id::text,
p_source_table_name,
v_listing_data.job_id,
v_listing_data.external_id,
v_listing_data.internal_id,
v_listing_data.title,
v_listing_data.title_de,
v_listing_data.description,
v_listing_data.description_de,
v_listing_data.price,
v_listing_data.area_sqm,
v_listing_data.rooms,
v_listing_data.bedrooms,
v_listing_data.bathrooms,
v_listing_data.city,
v_listing_data.ebay_url,
v_listing_data.images,
v_listing_data.added_on_platform,
v_listing_data.scraped_at,
v_listing_data.status,
v_listing_data.anbieter_type,
v_listing_data.anbieter_type_de,
v_listing_data.provision,
v_listing_data.provision_de,
v_listing_data.has_phone,
v_listing_data.phone,
v_listing_data.views,
v_listing_data.seller_name,
v_listing_data.plot_area,
v_listing_data.year_built,
v_listing_data.floors,
v_listing_data.assigned_agent_id,
v_listing_data.assignment_status,
auth.uid()
);

DELETE FROM lead_actions
WHERE listing_id = v_listing_uuid
AND source_table_name = p_source_table_name;

EXECUTE format(
'DELETE FROM %I WHERE id = $1',
p_source_table_name
) USING v_listing_uuid;

RETURN true;
EXCEPTION
WHEN others THEN
RAISE EXCEPTION 'Archive failed: %', SQLERRM;
END;
$_$;


ALTER FUNCTION "public"."archive_listing"("p_listing_id" "text", "p_source_table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_assign_single_scrape_internal_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_assign_single_scrape_internal_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_complete_task"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF NEW.delivered_leads_count >= NEW.total_leads_needed AND NEW.status = 'active' THEN
NEW.status = 'completed';
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_complete_task"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_create_task_lead_on_sent"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_task_id uuid;
  v_table_name text;
  v_task_lead_id uuid;
  v_notification_title text;
  v_notification_message text;
BEGIN
  v_table_name := TG_TABLE_NAME;

  -- CASE 1: Assignment status changed TO 'sent' - ensure task_lead + notify agent
  IF NEW.assignment_status = 'sent' AND NEW.assigned_agent_id IS NOT NULL THEN
    IF OLD.assignment_status IS DISTINCT FROM 'sent' THEN
      -- Try to reuse an existing task_lead (e.g., manually inserted earlier)
      SELECT id, task_id INTO v_task_lead_id, v_task_id
      FROM task_leads
      WHERE listing_id = NEW.id
        AND source_table_name = v_table_name
      ORDER BY assigned_at DESC NULLS LAST
      LIMIT 1;

      -- If none exists, create one using the agent's most recent active task
      IF v_task_lead_id IS NULL THEN
        SELECT id INTO v_task_id
        FROM lead_generation_tasks
        WHERE agent_id = NEW.assigned_agent_id
          AND status = 'active'
        ORDER BY created_at DESC
        LIMIT 1;

        IF v_task_id IS NOT NULL THEN
          INSERT INTO task_leads (
            task_id,
            listing_id,
            source_table_name,
            assigned_at
          ) VALUES (
            v_task_id,
            NEW.id,
            v_table_name,
            now()
          )
          RETURNING id INTO v_task_lead_id;

          RAISE NOTICE 'Created task_lead for listing % in table % for task %',
            NEW.id, v_table_name, v_task_id;
        END IF;
      END IF;

      v_notification_title := 'Neuer Lead zugewiesen';
      v_notification_message := 'Ein neuer Lead wurde Ihnen zugewiesen: '
        || COALESCE(NEW.internal_id, 'Neuer Lead');

      INSERT INTO agent_notifications (
        agent_id,
        type,
        title,
        message,
        related_listing_id,
        related_source_table,
        related_internal_id,
        metadata
      ) VALUES (
        NEW.assigned_agent_id,
        'new_lead_assigned',
        v_notification_title,
        v_notification_message,
        NEW.id,
        v_table_name,
        NEW.internal_id,
        jsonb_strip_nulls(jsonb_build_object(
          'task_lead_id', v_task_lead_id,
          'task_id', v_task_id,
          'assignment_status', NEW.assignment_status
        ))
      );
    END IF;
  END IF;

  -- CASE 2: Assignment status changed FROM 'sent' TO 'not_sent' - DELETE task_lead
  IF OLD.assignment_status = 'sent' AND NEW.assignment_status = 'not_sent' THEN
    DELETE FROM task_leads
    WHERE listing_id = NEW.id
      AND source_table_name = v_table_name;

    RAISE NOTICE 'Removed task_lead for listing % in table % (status changed to not_sent)',
      NEW.id, v_table_name;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_create_task_lead_on_sent"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_create_task_lead_on_sent"() IS 'Creates/removes task_leads when assignment_status changes and now also creates agent_notifications when a lead is actually sent.';



CREATE OR REPLACE FUNCTION "public"."auto_populate_single_scrape_job_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
found_job_id uuid;
BEGIN
IF NEW.job_id IS NULL THEN
SELECT id INTO found_job_id
FROM scrape_jobs
WHERE hide_from_ui = true
AND status IN ('pending', 'running', 'completed')
AND created_at >= COALESCE(NEW.created_at, now()) - INTERVAL '5 minutes'
AND created_at <= COALESCE(NEW.created_at, now()) + INTERVAL '5 minutes'
ORDER BY ABS(EXTRACT(EPOCH FROM (created_at - COALESCE(NEW.created_at, now()))))
LIMIT 1;

IF found_job_id IS NULL THEN
SELECT id INTO found_job_id
FROM scrape_jobs
WHERE hide_from_ui = true
AND status IN ('pending', 'running')
ORDER BY created_at DESC
LIMIT 1;
END IF;

IF found_job_id IS NOT NULL THEN
NEW.job_id := found_job_id;
RAISE NOTICE 'Auto-populated job_id % for single_scrape (matched by timestamp)', found_job_id;
END IF;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_populate_single_scrape_job_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_populate_single_scrape_job_id"() IS 'Automatically finds and sets job_id for single_scrapes by matching with scrape_jobs based on creation timestamp. Matches within 5-minute window and with hide_from_ui=true flag.';



CREATE OR REPLACE FUNCTION "public"."auto_progress_scraper_task"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.status in ('blocked','cancelled') then
    return new;
  end if;

  -- First upload -> in_progress
  if new.current_lead_count > 0 and coalesce(old.current_lead_count,0) = 0 and old.status = 'new' then
    new.status := 'in_progress';
  end if;

  -- Hitting target -> completed
  if new.current_lead_count >= new.target_lead_count then
    new.status := 'completed';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."auto_progress_scraper_task"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_set_single_scrape_messaged_status"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_set_single_scrape_messaged_status"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_set_single_scrape_messaged_status"() IS 'Previously auto-set assignment_status to "sent" when agent was assigned. This behavior has been removed to allow admins to manually control when leads are marked as sent. Function kept for backward compatibility.';



CREATE OR REPLACE FUNCTION "public"."auto_set_url_scrape_messaged_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- No-op: do not alter assignment_status on agent assignment.
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_set_url_scrape_messaged_status"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_set_url_scrape_messaged_status"() IS 'No-op stub to avoid auto-setting assignment_status to sent when assigning an agent. Notifications should only fire when sent explicitly.';



CREATE OR REPLACE FUNCTION "public"."backfill_all_assigned_agents"() RETURNS TABLE("table_name" "text", "updated_count" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  table_record RECORD;
  count_result integer;
BEGIN
  -- Backfill single_scrapes
  count_result := backfill_assigned_agent_single_scrapes();
  RETURN QUERY SELECT 'single_scrapes'::text, count_result;

  -- Backfill all dynamic tables
  FOR table_record IN
    SELECT table_name
    FROM scrape_tables_registry
    WHERE is_active = true
    AND table_name NOT IN ('scrape_jobs', 'scrape_tables_registry')
  LOOP
    -- Check if table exists and has assigned_agent_id column
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_name = table_record.table_name
      AND column_name = 'assigned_agent_id'
    ) THEN
      BEGIN
        count_result := backfill_assigned_agent_for_table(table_record.table_name);
        RETURN QUERY SELECT table_record.table_name, count_result;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE WARNING 'Error backfilling table %: %', table_record.table_name, SQLERRM;
          RETURN QUERY SELECT table_record.table_name, 0;
      END;
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."backfill_all_assigned_agents"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."backfill_all_assigned_agents"() IS 'Backfills assigned_agent_id for all tables (single_scrapes and all dynamic tables). Returns a table with table_name and updated_count for each table.';



CREATE OR REPLACE FUNCTION "public"."backfill_assigned_agent_for_table"("table_name" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  updated_count integer := 0;
  job_record RECORD;
BEGIN
  -- Check if table exists and has required columns
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = backfill_assigned_agent_for_table.table_name
    AND column_name = 'assigned_agent_id'
  ) THEN
    RAISE WARNING 'Table % does not have assigned_agent_id column', table_name;
    RETURN 0;
  END IF;

  -- Update all rows that have job_id but no assigned_agent_id
  EXECUTE format('
    WITH job_assignments AS (
      SELECT 
        l.id as listing_id,
        sj.assigned_to
      FROM %I l
      INNER JOIN scrape_jobs sj ON l.job_id = sj.id
      WHERE l.job_id IS NOT NULL
        AND (l.assigned_agent_id IS NULL OR l.assigned_agent_id::text = ''''::text)
        AND sj.assigned_to IS NOT NULL
        AND LENGTH(TRIM(sj.assigned_to)) > 0
    )
    UPDATE %I l
    SET assigned_agent_id = CASE
      WHEN ja.assigned_to ~ ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'' THEN ja.assigned_to::uuid
      ELSE NULL
    END
    FROM job_assignments ja
    WHERE l.id = ja.listing_id
      AND ja.assigned_to ~ ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$''
  ', table_name, table_name);
  
  GET DIAGNOSTICS updated_count = ROW_COUNT;

  RAISE NOTICE 'Backfilled % assignments in table %', updated_count, table_name;
  RETURN updated_count;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Error backfilling table %: %', table_name, SQLERRM;
    RETURN 0;
END;
$_$;


ALTER FUNCTION "public"."backfill_assigned_agent_for_table"("table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."backfill_assigned_agent_for_table"("table_name" "text") IS 'Backfills assigned_agent_id for existing listings in a dynamic table that have job_id but no assigned_agent_id. Returns count of updated rows.';



CREATE OR REPLACE FUNCTION "public"."backfill_assigned_agent_single_scrapes"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  updated_count integer := 0;
BEGIN
  -- Update all single_scrapes that have job_id but no assigned_agent_id
  UPDATE single_scrapes s
  SET assigned_agent_id = CASE
    WHEN sj.assigned_to ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN sj.assigned_to::uuid
    ELSE NULL
  END
  FROM scrape_jobs sj
  WHERE s.job_id = sj.id
    AND s.job_id IS NOT NULL
    AND (s.assigned_agent_id IS NULL OR s.assigned_agent_id::text = ''::text)
    AND sj.assigned_to IS NOT NULL
    AND LENGTH(TRIM(sj.assigned_to)) > 0
    AND sj.assigned_to ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RAISE NOTICE 'Backfilled % assignments in single_scrapes', updated_count;
  RETURN updated_count;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Error backfilling single_scrapes: %', SQLERRM;
    RETURN 0;
END;
$_$;


ALTER FUNCTION "public"."backfill_assigned_agent_single_scrapes"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."backfill_assigned_agent_single_scrapes"() IS 'Backfills assigned_agent_id for existing single_scrapes that have job_id but no assigned_agent_id. Returns count of updated rows.';



CREATE OR REPLACE FUNCTION "public"."calculate_session_duration"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF NEW.closed_at IS NOT NULL AND OLD.closed_at IS NULL THEN
NEW.total_duration_seconds := EXTRACT(EPOCH FROM (NEW.closed_at - NEW.opened_at))::integer;

NEW.browsing_duration_seconds := NEW.total_duration_seconds - COALESCE(NEW.interaction_duration_seconds, 0);
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."calculate_session_duration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_assignment_trigger_applied"("table_name" "text") RETURNS TABLE("trigger_name" "text", "event_manipulation" "text", "action_timing" "text", "action_statement" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    t.trigger_name::text,
    t.event_manipulation::text,
    t.action_timing::text,
    t.action_statement::text
  FROM information_schema.triggers t
  WHERE t.event_object_table = check_assignment_trigger_applied.table_name
    AND t.event_object_schema = 'public'
    AND (t.trigger_name LIKE '%assigned%' OR t.trigger_name LIKE '%populate_assigned%')
  ORDER BY t.trigger_name;
END;
$$;


ALTER FUNCTION "public"."check_assignment_trigger_applied"("table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."check_assignment_trigger_applied"("table_name" "text") IS 'Checks if assignment triggers are applied to a specific table. Returns trigger details.';



CREATE OR REPLACE FUNCTION "public"."check_overdue_calls"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
UPDATE scheduled_calls
SET is_overdue = true
WHERE status = 'pending'
AND scheduled_date < CURRENT_DATE
AND is_overdue = false;
END;
$$;


ALTER FUNCTION "public"."check_overdue_calls"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_upcoming_calls"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  reminder record;
  v_listing_uuid uuid;
  v_internal_id text;
  v_time_window text;
  v_title text;
  v_status_text text;
BEGIN
  FOR reminder IN
    SELECT
      sc.*,
      offsets.offset_minutes
    FROM scheduled_calls sc
    CROSS JOIN (VALUES (60), (15), (0)) AS offsets(offset_minutes)
    WHERE sc.status IN ('pending', 'rescheduled')
      AND now() >= sc.scheduled_date - make_interval(mins => offsets.offset_minutes)
      AND now() < sc.scheduled_date - make_interval(mins => offsets.offset_minutes) + interval '1 minute'
  LOOP
    IF EXISTS (
      SELECT 1 FROM agent_notifications an
      WHERE an.type = 'call_reminder'
        AND an.metadata->>'scheduled_call_id' = reminder.id::text
        AND an.metadata->>'reminder_offset_minutes' = reminder.offset_minutes::text
    ) THEN
      CONTINUE;
    END IF;

    BEGIN
      v_listing_uuid := reminder.listing_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_listing_uuid := NULL;
    END;

    v_internal_id := COALESCE(
      get_listing_internal_id(reminder.source_table_name, reminder.listing_id),
      'Unbekannter Lead'
    );

    IF reminder.call_type = 'time_range' AND reminder.scheduled_date_end IS NOT NULL THEN
      v_time_window := format(
        '%s zwischen %s und %s Uhr',
        to_char(reminder.scheduled_date AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'),
        to_char(reminder.scheduled_date AT TIME ZONE 'Europe/Berlin', 'HH24:MI'),
        to_char(reminder.scheduled_date_end AT TIME ZONE 'Europe/Berlin', 'HH24:MI')
      );
    ELSE
      v_time_window := format(
        '%s um %s Uhr',
        to_char(reminder.scheduled_date AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'),
        to_char(reminder.scheduled_date AT TIME ZONE 'Europe/Berlin', 'HH24:MI')
      );
    END IF;

    v_title := CASE reminder.offset_minutes
      WHEN 60 THEN 'Call in 1 Stunde'
      WHEN 15 THEN 'Call in 15 Minuten'
      ELSE 'Call startet jetzt'
    END;

    v_status_text := CASE reminder.offset_minutes
      WHEN 60 THEN 'startet in 60 Minuten'
      WHEN 15 THEN 'startet in 15 Minuten'
      ELSE 'sollte jetzt beginnen'
    END;

    INSERT INTO agent_notifications (
      agent_id,
      type,
      title,
      message,
      related_listing_id,
      related_source_table,
      related_internal_id,
      metadata
    ) VALUES (
      reminder.agent_id,
      'call_reminder',
      v_title,
      format('Dein Call mit Lead %s %s (%s).', v_internal_id, v_status_text, v_time_window),
      v_listing_uuid,
      reminder.source_table_name,
      v_internal_id,
      jsonb_strip_nulls(jsonb_build_object(
        'scheduled_call_id', reminder.id,
        'reminder_offset_minutes', reminder.offset_minutes,
        'call_type', reminder.call_type,
        'scheduled_date', reminder.scheduled_date,
        'scheduled_date_end', reminder.scheduled_date_end
      ))
    );
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."check_upcoming_calls"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."copy_scrape_notes_to_single_scrapes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
IF NEW.job_id IS NOT NULL THEN
UPDATE single_scrapes
SET scrape_notes = (
SELECT scrape_notes
FROM scrape_jobs
WHERE id = NEW.job_id
)
WHERE id = NEW.id;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."copy_scrape_notes_to_single_scrapes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_assigned_agent_trigger"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS force_assigned_agent_after_update_trigger ON %I;', table_name);
  EXECUTE format('DROP TRIGGER IF EXISTS populate_assigned_agent_trigger ON %I;', table_name);
  EXECUTE format('
    CREATE TRIGGER populate_assigned_agent_trigger
    BEFORE INSERT OR UPDATE ON %I
    FOR EACH ROW
    EXECUTE FUNCTION populate_assigned_agent_from_job();
  ', table_name);
END;
$$;


ALTER FUNCTION "public"."create_assigned_agent_trigger"("table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_assigned_agent_trigger"("table_name" "text") IS 'Helper function to apply the assigned_agent trigger to a dynamic scrape table.';



CREATE OR REPLACE FUNCTION "public"."create_dynamic_table"("table_name" "text", "job_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Create the table with all necessary columns
  EXECUTE format('
    CREATE TABLE IF NOT EXISTS %I (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id uuid DEFAULT %L,
      internal_id text,
      external_id text UNIQUE,
      title text,
      title_de text,
      description text,
      description_de text,
      city text,
      state text,
      nearest_major_city text,
      area_sqm integer,
      rooms numeric,
      price integer,
      images jsonb DEFAULT ''[]''::jsonb,
      anbieter_type text,
      anbieter_type_de text,
      provision text,
      provision_de text,
      phone text,
      has_phone boolean DEFAULT false,
      status text DEFAULT ''active'',
      is_new boolean DEFAULT true,
      ebay_url text,
      added_on_platform timestamptz,
      scraped_at timestamptz DEFAULT now(),
      assigned_to text,
      views integer,
      seller_name text,
      plot_area integer,
      year_built integer,
      floors integer,
      bedrooms integer,
      bathrooms integer,
      call_status text DEFAULT ''not_called'',
      lead_rating text,
      notes_from_call text,
      notes_general text,
      rejection_reason text,
      assigned_agent_id uuid,
      assignment_status text DEFAULT ''not_sent'',
      source_table_name text,
      created_at timestamptz DEFAULT now(),
      call_date date,
      agent_status text,
      is_new_for_agent boolean DEFAULT true,
      agent_viewed_at timestamptz,
      call_completed boolean DEFAULT false,
      call_completed_at timestamptz
    )
  ', table_name, job_id);

  -- Enable RLS
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
  
  -- Apply the standardized RLS policies
  PERFORM fix_dynamic_table_agent_rls(table_name);

  -- Apply task_lead trigger
  PERFORM apply_task_lead_trigger_to_table(table_name);

  -- Apply assignment notification trigger
  PERFORM apply_assignment_notification_trigger(table_name);

  -- Enable realtime
  EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', table_name);

  -- Register in scrape_tables_registry
  INSERT INTO scrape_tables_registry (table_name, job_id)
  VALUES (table_name, job_id)
  ON CONFLICT (table_name) DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."create_dynamic_table"("table_name" "text", "job_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_dynamic_table"("table_name" "text", "job_id" "uuid") IS 'Creates a new dynamic scrape table with RLS, task lead + notification triggers, and realtime enabled.';



CREATE OR REPLACE FUNCTION "public"."create_internal_id_trigger"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
BEGIN
EXECUTE format('
CREATE OR REPLACE FUNCTION %I()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '''' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$func$;
', 'trg_func_internal_id_' || table_name);

EXECUTE format('
DROP TRIGGER IF EXISTS auto_assign_internal_id ON %I;
CREATE TRIGGER auto_assign_internal_id
BEFORE INSERT ON %I
FOR EACH ROW
EXECUTE FUNCTION %I();
', table_name, table_name, 'trg_func_internal_id_' || table_name);

RAISE NOTICE 'Created internal_id trigger for table: %', table_name;
END;
$_$;


ALTER FUNCTION "public"."create_internal_id_trigger"("table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_location_population_trigger"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
EXECUTE format('
DROP TRIGGER IF EXISTS populate_location_trigger ON %I;
CREATE TRIGGER populate_location_trigger
BEFORE INSERT ON %I
FOR EACH ROW
EXECUTE FUNCTION populate_location_from_job();
', table_name, table_name);

RAISE NOTICE 'Created location population trigger for table: %', table_name;
END;
$$;


ALTER FUNCTION "public"."create_location_population_trigger"("table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_scrape_results_table"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
EXECUTE format('
CREATE TABLE IF NOT EXISTS %I (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
job_id uuid REFERENCES scrape_jobs(id) ON DELETE CASCADE,
internal_id text UNIQUE,
external_id text,
title text,
title_de text,
description text,
description_de text,
city text,
state text,
nearest_major_city text,
area_sqm integer,
rooms numeric,
price integer,
images jsonb,
anbieter_type text,
anbieter_type_de text,
provision text,
provision_de text,
phone text,
has_phone boolean DEFAULT false,
status text DEFAULT ''active'',
is_new boolean DEFAULT true,
ebay_url text,
added_on_platform timestamptz,
scraped_at timestamptz DEFAULT now(),
assigned_to text,
views integer,
seller_name text,
plot_area integer,
year_built integer,
floors integer,
bedrooms integer,
bathrooms integer,
call_status text,
lead_rating text,
notes_from_call text,
notes_general text,
rejection_reason text,
assigned_agent_id uuid REFERENCES real_estate_agents(id) ON DELETE SET NULL,
assignment_status text DEFAULT ''not_sent'',
agent_status text,
call_date date,
is_new_for_agent boolean DEFAULT true,
agent_viewed_at timestamptz,
call_completed boolean DEFAULT false,
call_completed_at timestamptz,
source_table_name text,
created_at timestamptz DEFAULT now()
)', table_name);

EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_job_id ON %I(job_id)', table_name, table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_internal_id ON %I(internal_id)', table_name, table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_assigned_agent ON %I(assigned_agent_id)', table_name, table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_call_date ON %I(call_date)', table_name, table_name);

EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);

EXECUTE format('
DROP POLICY IF EXISTS "Admin full access to %I" ON %I;
CREATE POLICY "Admin full access to %I"
ON %I FOR ALL
TO authenticated
USING (
EXISTS (
SELECT 1 FROM profiles
WHERE profiles.id = auth.uid()
AND profiles.role IN (''admin'', ''scrape'', ''view_edit'', ''view_call'')
)
)', table_name, table_name, table_name, table_name);
END;
$$;


ALTER FUNCTION "public"."create_scrape_results_table"("table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_scrape_results_table"("table_name" "text", "job_id_ref" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  EXECUTE format('
    CREATE TABLE IF NOT EXISTS public.%I (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      internal_id text,
      scrape_job_id uuid REFERENCES scrape_jobs(id) ON DELETE CASCADE,
      title text,
      title_de text,
      description text,
      description_de text,
      price numeric,
      city text,
      state text,
      major_city text,
      area_sqm numeric,
      rooms numeric,
      bedrooms integer,
      bathrooms integer,
      plot_area numeric,
      year_built integer,
      floors integer,
      ebay_url text,
      images text[],
      anbieter_name text,
      anbieter_type text,
      anbieter_type_de text,
      phone text,
      has_phone boolean DEFAULT false,
      added_on_platform date,
      scraped_at timestamptz DEFAULT now(),
      is_new boolean DEFAULT true,
      assigned_agent_id uuid REFERENCES real_estate_agents(id) ON DELETE SET NULL,
      assignment_status text DEFAULT ''not_sent'' CHECK (assignment_status IN (''not_sent'', ''sent'')),
      is_new_for_agent boolean DEFAULT true,
      agent_viewed_at timestamptz,
      agent_status text,
      lead_status text DEFAULT ''New'',
      status_overridden boolean DEFAULT false,
      status_override_reason text,
      status_overridden_by uuid,
      status_overridden_at timestamptz,
      status_override_locked boolean DEFAULT false,
      call_date date,
      call_completed boolean DEFAULT false,
      call_completed_at timestamptz,
      fixed_phone text,
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now(),
      UNIQUE(internal_id)
    )
  ', table_name);

  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_name);

  EXECUTE format('
    CREATE POLICY "Authenticated users can view all rows"
      ON public.%I FOR SELECT TO authenticated USING (true)
  ', table_name);

  EXECUTE format('
    CREATE POLICY "Authenticated users can insert rows"
      ON public.%I FOR INSERT TO authenticated WITH CHECK (true)
  ', table_name);

  EXECUTE format('
    CREATE POLICY "Authenticated users can update rows"
      ON public.%I FOR UPDATE TO authenticated USING (true) WITH CHECK (true)
  ', table_name);

  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_agent ON %I(assigned_agent_id)', table_name, table_name);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_status ON %I(assignment_status)', table_name, table_name);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_call_date ON %I(call_date) WHERE call_date IS NOT NULL', table_name, table_name);

  EXECUTE format('
    DROP TRIGGER IF EXISTS trigger_auto_create_task_lead ON %I;
    CREATE TRIGGER trigger_auto_create_task_lead
      AFTER UPDATE ON %I
      FOR EACH ROW
      EXECUTE FUNCTION auto_create_task_lead_on_sent();
  ', table_name, table_name);

  EXECUTE format('
    DROP TRIGGER IF EXISTS update_%I_updated_at ON %I;
    CREATE TRIGGER update_%I_updated_at
      BEFORE UPDATE ON %I
      FOR EACH ROW
      EXECUTE FUNCTION update_updated_at_column();
  ', table_name, table_name, table_name, table_name);

  EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', table_name);

  RETURN true;
END;
$$;


ALTER FUNCTION "public"."create_scrape_results_table"("table_name" "text", "job_id_ref" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scraper_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "scraper_id" "uuid" NOT NULL,
    "task_id" "uuid" NOT NULL,
    "type" "text" DEFAULT 'task_assigned'::"text" NOT NULL,
    "title" "text",
    "message" "text",
    "metadata" "jsonb",
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."scraper_notifications" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_scraper_notification"("p_scraper_id" "uuid", "p_task_id" "uuid", "p_type" "text" DEFAULT 'task_assigned'::"text", "p_title" "text" DEFAULT NULL::"text", "p_message" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."scraper_notifications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_notification public.scraper_notifications;
begin
  insert into public.scraper_notifications (scraper_id, task_id, type, title, message, metadata)
  values (
    p_scraper_id,
    p_task_id,
    coalesce(p_type, 'task_assigned'),
    coalesce(p_title, 'New scraper task assigned'),
    coalesce(p_message, 'You have a new scraper task'),
    p_metadata
  )
  returning * into v_notification;

  return v_notification;
end;
$$;


ALTER FUNCTION "public"."create_scraper_notification"("p_scraper_id" "uuid", "p_task_id" "uuid", "p_type" "text", "p_title" "text", "p_message" "text", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_state_distribution_trigger"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
trigger_name text;
BEGIN
trigger_name := table_name || '_distribute_to_state';

EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', trigger_name, table_name);

EXECUTE format('
CREATE TRIGGER %I
AFTER INSERT ON %I
FOR EACH ROW
EXECUTE FUNCTION distribute_listing_to_state_table()
', trigger_name, table_name);

RAISE NOTICE 'Created state distribution trigger on table %', table_name;

EXCEPTION
WHEN OTHERS THEN
RAISE WARNING 'Failed to create state distribution trigger on %: %', table_name, SQLERRM;
END;
$$;


ALTER FUNCTION "public"."create_state_distribution_trigger"("table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_state_listings_table"("state_table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
EXECUTE format('
CREATE TABLE IF NOT EXISTS %I (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
job_id uuid REFERENCES scrape_jobs(id) ON DELETE SET NULL,
external_id text NOT NULL,
title text NOT NULL,
title_de text,
description text,
description_de text,
city text NOT NULL,
area_sqm integer,
rooms numeric,
price integer,
images jsonb DEFAULT ''[]''::jsonb,
anbieter_type text,
anbieter_type_de text,
provision text,
provision_de text,
phone text,
has_phone boolean DEFAULT false,
status text DEFAULT ''active'',
is_new boolean DEFAULT true,
ebay_url text NOT NULL,
added_on_platform timestamptz,
scraped_at timestamptz DEFAULT now(),
assigned_to text,
views integer,
seller_name text,
plot_area integer,
year_built integer,
floors integer,
bedrooms integer,
bathrooms integer,
call_status text DEFAULT ''not_called'',
lead_rating text,
notes_from_call text,
notes_general text,
rejection_reason text,
source_table_name text,
created_at timestamptz DEFAULT now(),
CONSTRAINT %I UNIQUE (external_id)
)', state_table_name, state_table_name || '_external_id_key');

EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(job_id)', 
'idx_' || state_table_name || '_job_id', state_table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(external_id)', 
'idx_' || state_table_name || '_external_id', state_table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(scraped_at DESC)', 
'idx_' || state_table_name || '_scraped_at', state_table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(call_status)', 
'idx_' || state_table_name || '_call_status', state_table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(lead_rating)', 
'idx_' || state_table_name || '_lead_rating', state_table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(city)', 
'idx_' || state_table_name || '_city', state_table_name);
EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(has_phone)', 
'idx_' || state_table_name || '_has_phone', state_table_name);

EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', state_table_name);

EXECUTE format('
CREATE POLICY "Admin scrape and view_edit can read all %s"
ON %I FOR SELECT
TO authenticated
USING (
EXISTS (
SELECT 1 FROM profiles
WHERE profiles.id = auth.uid()
AND profiles.role IN (''admin'', ''scrape'', ''view_edit'')
)
)', state_table_name, state_table_name);

EXECUTE format('
CREATE POLICY "view_call can read %s with phone"
ON %I FOR SELECT
TO authenticated
USING (
EXISTS (
SELECT 1 FROM profiles
WHERE profiles.id = auth.uid()
AND profiles.role = ''view_call''
)
AND (has_phone = true OR phone IS NOT NULL)
)', state_table_name, state_table_name);

EXECUTE format('
CREATE POLICY "Authenticated users can insert %s"
ON %I FOR INSERT
TO authenticated
WITH CHECK (true)', state_table_name, state_table_name);

EXECUTE format('
CREATE POLICY "Authenticated users can update %s"
ON %I FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true)', state_table_name, state_table_name);

EXECUTE format('
CREATE POLICY "Authenticated users can delete %s"
ON %I FOR DELETE
TO authenticated
USING (true)', state_table_name, state_table_name);
END;
$$;


ALTER FUNCTION "public"."create_state_listings_table"("state_table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_profile_role"() RETURNS "text"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select role from public.profiles where id = auth.uid();
$$;


ALTER FUNCTION "public"."current_profile_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_task_delivered_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Decrement the count, ensuring it doesn't go below 0
  UPDATE lead_generation_tasks
  SET delivered_leads_count = GREATEST(0, COALESCE(delivered_leads_count, 0) - 1)
  WHERE id = OLD.task_id;
  
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."decrement_task_delivered_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_task_cascade"("p_task_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  DELETE FROM task_leads WHERE task_id = p_task_id;
  DELETE FROM task_regions WHERE task_id = p_task_id;
  DELETE FROM task_lead_pricing_blocks WHERE task_id = p_task_id;
  DELETE FROM lead_generation_tasks WHERE id = p_task_id;
END;
$$;


ALTER FUNCTION "public"."delete_task_cascade"("p_task_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."distribute_listing_to_state_table"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
state_name text;
state_table_name text;
source_table text;
BEGIN
source_table := TG_TABLE_NAME;

state_name := NEW.state;

IF state_name IS NULL THEN
SELECT state INTO state_name
FROM scrape_jobs
WHERE id = NEW.job_id;
END IF;

IF state_name IS NULL THEN
RAISE WARNING 'No state found for job_id % in table %', NEW.job_id, source_table;
RETURN NEW;
END IF;

state_table_name := get_state_table_name(state_name);

IF state_table_name IS NULL THEN
RAISE WARNING 'Invalid state name "%" for job_id % in table %', state_name, NEW.job_id, source_table;
RETURN NEW;
END IF;

BEGIN
EXECUTE format('
INSERT INTO %I (
id, job_id, internal_id, external_id, title, title_de, description, description_de,
city, state, nearest_major_city, area_sqm, rooms, price, images, 
anbieter_type, anbieter_type_de, provision, provision_de, phone, has_phone, 
status, is_new, ebay_url, added_on_platform, scraped_at, assigned_to, 
views, seller_name, plot_area, year_built, floors, bedrooms, bathrooms, 
call_status, lead_rating, notes_from_call, notes_general, rejection_reason,
assigned_agent_id, assignment_status, source_table_name, created_at
)
VALUES (
$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16,
$17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27, $28, $29, $30,
$31, $32, $33, $34, $35, $36, $37, $38, $39, $40, $41, $42, $43
)
ON CONFLICT (internal_id) DO UPDATE SET
title = EXCLUDED.title,
title_de = EXCLUDED.title_de,
description = EXCLUDED.description,
description_de = EXCLUDED.description_de,
phone = EXCLUDED.phone,
has_phone = EXCLUDED.has_phone,
status = EXCLUDED.status,
assigned_agent_id = EXCLUDED.assigned_agent_id,
assignment_status = EXCLUDED.assignment_status
', state_table_name)
USING
NEW.id, NEW.job_id, NEW.internal_id, NEW.external_id, NEW.title, NEW.title_de,
NEW.description, NEW.description_de, NEW.city, NEW.state, NEW.nearest_major_city,
NEW.area_sqm, NEW.rooms, NEW.price, NEW.images, NEW.anbieter_type, NEW.anbieter_type_de,
NEW.provision, NEW.provision_de, NEW.phone, NEW.has_phone, NEW.status,
NEW.is_new, NEW.ebay_url, NEW.added_on_platform, NEW.scraped_at,
NEW.assigned_to, NEW.views, NEW.seller_name, NEW.plot_area, NEW.year_built,
NEW.floors, NEW.bedrooms, NEW.bathrooms, NEW.call_status, NEW.lead_rating,
NEW.notes_from_call, NEW.notes_general, NEW.rejection_reason,
NEW.assigned_agent_id, NEW.assignment_status, source_table, NEW.created_at;

RAISE NOTICE 'Successfully distributed listing % (internal_id: %) from % to state table %',
NEW.external_id, NEW.internal_id, source_table, state_table_name;

EXCEPTION
WHEN OTHERS THEN
RAISE WARNING 'Failed to distribute listing % (internal_id: %) from % to state table %: %',
NEW.external_id, NEW.internal_id, source_table, state_table_name, SQLERRM;
END;

RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."distribute_listing_to_state_table"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_scraper_task_update_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();

  -- Only apply guard to scrapers
  if v_role not in ('scrape','scraper') then
    return new;
  end if;

  -- Must own the task
  if new.assigned_scraper_id is distinct from auth.uid() then
    raise exception 'Scrapers can only update their own tasks';
  end if;

  -- Disallow changes to immutable fields for scrapers
  if new.region is distinct from old.region
     or coalesce(new.city,'') is distinct from coalesce(old.city,'')
     or coalesce(new.area,'') is distinct from coalesce(old.area,'')
     or new.target_lead_count is distinct from old.target_lead_count
     or new.assigned_scraper_id is distinct from old.assigned_scraper_id
     or new.task_type is distinct from old.task_type
     or coalesce(new.source_agent_order_id,'00000000-0000-0000-0000-000000000000') is distinct from coalesce(old.source_agent_order_id,'00000000-0000-0000-0000-000000000000')
     or coalesce(new.notes,'') is distinct from coalesce(old.notes,'')
  then
    raise exception 'Scrapers cannot modify task metadata';
  end if;

  -- Status transitions allowed: new|in_progress -> completed; allow current_lead_count bump
  if new.status not in ('new','in_progress','completed') then
    raise exception 'Invalid status transition for scraper';
  end if;
  if new.status = 'new' and old.status <> 'new' then
    raise exception 'Scrapers cannot reset status to new';
  end if;
  if new.status = 'completed' and old.status in ('blocked','cancelled') then
    raise exception 'Cannot complete a blocked/cancelled task';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_scraper_task_update_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fix_dynamic_table_agent_rls"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
BEGIN
  IF table_name IS NULL
     OR table_name !~ '^[a-z][a-z0-9_]{0,62}$'
     OR table_name LIKE 'pg\_%' ESCAPE '\'
  THEN
    RAISE EXCEPTION 'Invalid table name: %', table_name;
  END IF;

  -- Drop existing policies managed by this helper
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Allow all operations on ' || table_name, table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admin scrape and view_edit can view all', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admin scrape management and view_edit can view all', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admins and managers can insert', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admins management scrape and view_edit can insert', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admins and managers can update', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admins management scrape and view_edit can update', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Admins can delete', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'view_call can view listings with phone', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Agents can view sent leads assigned to them', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Agents can update sent leads assigned to them', table_name);
  EXECUTE format('DROP POLICY IF EXISTS %I ON %I', 'Team leaders can view team listings', table_name);

  -- Internal roles: SELECT
  EXECUTE format($sql$
    CREATE POLICY "Admin scrape management and view_edit can view all"
      ON %I
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM profiles
          WHERE profiles.id = (select auth.uid())
            AND profiles.role IN ('admin', 'management', 'manager', 'scrape', 'view_edit')
        )
      )
  $sql$, table_name);

  -- Internal roles: INSERT
  EXECUTE format($sql$
    CREATE POLICY "Admins management scrape and view_edit can insert"
      ON %I
      FOR INSERT
      TO authenticated
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM profiles
          WHERE profiles.id = (select auth.uid())
            AND profiles.role IN ('admin', 'management', 'manager', 'scrape', 'view_edit')
        )
      )
  $sql$, table_name);

  -- Internal roles: UPDATE
  EXECUTE format($sql$
    CREATE POLICY "Admins management scrape and view_edit can update"
      ON %I
      FOR UPDATE
      TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM profiles
          WHERE profiles.id = (select auth.uid())
            AND profiles.role IN ('admin', 'management', 'manager', 'scrape', 'view_edit')
        )
      )
  $sql$, table_name);

  -- Internal roles: DELETE
  EXECUTE format($sql$
    CREATE POLICY "Admins can delete"
      ON %I
      FOR DELETE
      TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM profiles
          WHERE profiles.id = (select auth.uid())
            AND profiles.role IN ('admin', 'management')
        )
      )
  $sql$, table_name);

  -- view_call: base visibility only (not sent + has phone)
  EXECUTE format($sql$
    CREATE POLICY "view_call can view listings with phone"
      ON %I
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM profiles
          WHERE profiles.id = (select auth.uid())
            AND profiles.role = 'view_call'
        )
        AND has_phone = true
        AND COALESCE(assignment_status, 'not_sent') <> 'sent'
      )
  $sql$, table_name);

  -- Agents: SELECT sent leads assigned to them
  EXECUTE format($sql$
    CREATE POLICY "Agents can view sent leads assigned to them"
      ON %I
      FOR SELECT
      TO authenticated
      USING (
        assignment_status = 'sent'
        AND EXISTS (
          SELECT 1
          FROM real_estate_agents a
          WHERE a.profile_id = (select auth.uid())
            AND (a.id = assigned_agent_id OR a.id::text = assigned_to)
        )
      )
  $sql$, table_name);

  -- Agents: UPDATE sent leads assigned to them
  EXECUTE format($sql$
    CREATE POLICY "Agents can update sent leads assigned to them"
      ON %I
      FOR UPDATE
      TO authenticated
      USING (
        assignment_status = 'sent'
        AND EXISTS (
          SELECT 1
          FROM real_estate_agents a
          WHERE a.profile_id = (select auth.uid())
            AND (a.id = assigned_agent_id OR a.id::text = assigned_to)
        )
      )
      WITH CHECK (
        assignment_status = 'sent'
        AND EXISTS (
          SELECT 1
          FROM real_estate_agents a
          WHERE a.profile_id = (select auth.uid())
            AND (a.id = assigned_agent_id OR a.id::text = assigned_to)
        )
      )
  $sql$, table_name);

  -- Team leaders: SELECT team listings
  EXECUTE format($sql$
    CREATE POLICY "Team leaders can view team listings"
      ON %I
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM real_estate_agents team_member
          JOIN real_estate_agents leader
            ON team_member.team_leader_id = leader.id
          WHERE team_member.id = assigned_agent_id
            AND leader.profile_id = (select auth.uid())
        )
      )
  $sql$, table_name);
END;
$_$;


ALTER FUNCTION "public"."fix_dynamic_table_agent_rls"("table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."fix_dynamic_table_agent_rls"("table_name" "text") IS 'Applies standardized RLS policies to dynamic tables. Agents can ONLY view/update leads where assignment_status = sent AND they are assigned.';



CREATE OR REPLACE FUNCTION "public"."fix_dynamic_table_rls"("table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
EXECUTE format('DROP POLICY IF EXISTS "Agents can view their assigned leads in %s" ON %I', table_name, table_name);
EXECUTE format('DROP POLICY IF EXISTS "Agents can update their assigned leads in %s" ON %I', table_name, table_name);

EXECUTE format('
CREATE POLICY "Agents can view their assigned leads in %s"
ON %I
FOR SELECT
TO authenticated
USING (
assigned_agent_id = (
SELECT id FROM real_estate_agents WHERE profile_id = (select auth.uid())
)
)', table_name, table_name);

EXECUTE format('
CREATE POLICY "Agents can update their assigned leads in %s"
ON %I
FOR UPDATE
TO authenticated
USING (
assigned_agent_id = (
SELECT id FROM real_estate_agents WHERE profile_id = (select auth.uid())
)
)
WITH CHECK (
assigned_agent_id = (
SELECT id FROM real_estate_agents WHERE profile_id = (select auth.uid())
)
)', table_name, table_name);
END;
$$;


ALTER FUNCTION "public"."fix_dynamic_table_rls"("table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."force_assigned_agent_after_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN NEW; -- Disabled: assignment is handled by BEFORE triggers that respect manual changes
END;
$$;


ALTER FUNCTION "public"."force_assigned_agent_after_update"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."force_assigned_agent_after_update"() IS 'Disabled placeholder; assignment is handled by BEFORE triggers that respect manual changes.';



CREATE OR REPLACE FUNCTION "public"."generate_ical_data"("call_id" "uuid") RETURNS TABLE("summary" "text", "description" "text", "dtstart" "text", "dtend" "text", "location" "text", "organizer" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
call_record scheduled_calls%ROWTYPE;
agent_record RECORD;
start_time text;
end_time text;
BEGIN
SELECT * INTO call_record FROM scheduled_calls WHERE id = call_id;

IF NOT FOUND THEN
RETURN;
END IF;

SELECT * INTO agent_record 
FROM real_estate_agents 
WHERE id = call_record.agent_id;

IF call_record.call_time_type = 'fixed_time' AND call_record.call_time_fixed IS NOT NULL THEN
start_time := to_char(call_record.scheduled_date, 'YYYYMMDD') || 'T' || to_char(call_record.call_time_fixed, 'HH24MISS');
end_time := to_char(call_record.scheduled_date, 'YYYYMMDD') || 'T' || to_char(call_record.call_time_fixed + interval '30 minutes', 'HH24MISS');
ELSIF call_record.call_time_type = 'time_range' THEN
start_time := to_char(call_record.scheduled_date, 'YYYYMMDD') || 'T' || to_char(call_record.call_time_range_start, 'HH24MISS');
end_time := to_char(call_record.scheduled_date, 'YYYYMMDD') || 'T' || to_char(call_record.call_time_range_end, 'HH24MISS');
ELSE
start_time := to_char(call_record.scheduled_date, 'YYYYMMDD');
end_time := to_char(call_record.scheduled_date + interval '1 day', 'YYYYMMDD');
END IF;

RETURN QUERY SELECT
'Scheduled Call - ' || COALESCE(agent_record.company_name, agent_record.name, 'Lead') AS summary,
'Call scheduled with ' || COALESCE(agent_record.company_name, agent_record.name, 'Agent') || 
CASE WHEN call_record.admin_notes IS NOT NULL THEN E'\n\nNotes: ' || call_record.admin_notes ELSE '' END AS description,
start_time AS dtstart,
end_time AS dtend,
COALESCE(agent_record.street_address, '') AS location,
'FalconLeads CRM' AS organizer;
END;
$$;


ALTER FUNCTION "public"."generate_ical_data"("call_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_url_scrape_internal_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
counter_val integer;
new_internal_id text;
BEGIN
UPDATE lead_counter
SET current_number = current_number + 1
RETURNING current_number INTO counter_val;

new_internal_id := 'US-' || LPAD(counter_val::text, 5, '0');

NEW.internal_id := new_internal_id;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_url_scrape_internal_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_agent_by_profile_id"("p_profile_id" "uuid") RETURNS TABLE("id" "uuid", "name" "text", "company_name" "text", "street_address" "text", "brokers_association" "text", "photo_url" "text", "team_size" integer, "notes" "text", "city" "text", "team_leader_id" "uuid", "buys_own_leads" boolean, "profile_id" "uuid", "portal_username" "text", "contact_email" "text", "last_login_at" timestamp with time zone, "notification_preferences" "jsonb", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
SELECT
id, name, company_name, street_address, brokers_association,
photo_url, team_size, notes, city, team_leader_id, buys_own_leads,
profile_id, portal_username, contact_email, last_login_at,
notification_preferences, created_at, updated_at
FROM real_estate_agents
WHERE real_estate_agents.profile_id = p_profile_id;
$$;


ALTER FUNCTION "public"."get_agent_by_profile_id"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_active_scrape_tables"() RETURNS TABLE("table_name" "text")
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
RETURN QUERY
SELECT str.table_name
FROM scrape_tables_registry str
WHERE str.is_active = true;
END;
$$;


ALTER FUNCTION "public"."get_all_active_scrape_tables"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_listing_internal_id"("p_source_table" "text", "p_listing_id" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  v_listing_uuid uuid;
  v_internal_id text;
BEGIN
  IF p_source_table IS NULL OR p_source_table = '' THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_listing_uuid := p_listing_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_listing_uuid := NULL;
  END;

  IF v_listing_uuid IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    EXECUTE format('SELECT internal_id FROM %I WHERE id = $1', p_source_table)
      INTO v_internal_id
      USING v_listing_uuid;
  EXCEPTION
    WHEN undefined_column THEN
      RETURN NULL;
    WHEN undefined_table THEN
      RETURN NULL;
  END;

  RETURN v_internal_id;
END;
$_$;


ALTER FUNCTION "public"."get_listing_internal_id"("p_source_table" "text", "p_listing_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_next_internal_id"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
next_block integer;
next_number integer;
internal_id text;
counter_id uuid;
BEGIN
SELECT id, current_block, current_number
INTO counter_id, next_block, next_number
FROM lead_counter
ORDER BY created_at
LIMIT 1
FOR UPDATE;

IF counter_id IS NULL THEN
RAISE EXCEPTION 'Lead counter not initialized. Please initialize the lead_counter table.';
END IF;

next_number := next_number + 1;

IF next_number > 99 THEN
next_number := 1;
next_block := next_block + 1;
END IF;

internal_id := 'A' || next_block || '.' || LPAD(next_number::text, 2, '0');

UPDATE lead_counter
SET 
current_block = next_block,
current_number = next_number,
updated_at = now()
WHERE id = counter_id;

RETURN internal_id;
END;
$$;


ALTER FUNCTION "public"."get_next_internal_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_next_table_number"() RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
DECLARE
v_next_number integer;
BEGIN
SELECT COALESCE(MAX(
CASE 
WHEN table_name ~ '_(\d+)$' 
THEN (regexp_match(table_name, '_(\d+)$'))[1]::integer
ELSE 0
END
), 0) + 1
INTO v_next_number
FROM scrape_tables_registry;

RETURN v_next_number;
END;
$_$;


ALTER FUNCTION "public"."get_next_table_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_replacement_request_counts"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_profile profiles%ROWTYPE;
  v_counts jsonb;
BEGIN
  -- Get the user's profile
  SELECT * INTO v_profile
  FROM profiles
  WHERE id = auth.uid();

  IF NOT FOUND OR v_profile.role NOT IN ('admin', 'super_admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only admins can view replacement counts');
  END IF;

  -- Default to current month if not specified
  IF p_start_date IS NULL THEN
    p_start_date := date_trunc('month', CURRENT_DATE)::date;
  END IF;
  
  IF p_end_date IS NULL THEN
    p_end_date := (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
  END IF;

  -- Get counts per agent
  SELECT jsonb_agg(
    jsonb_build_object(
      'agent_id', rea.id,
      'agent_name', rea.name,
      'pending_requests', COALESCE(pending.count, 0),
      'approved_replacements', COALESCE(approved.count, 0)
    )
  ) INTO v_counts
  FROM real_estate_agents rea
  LEFT JOIN (
    SELECT agent_id, COUNT(*) as count
    FROM lead_replacement_requests
    WHERE status = 'pending'
      AND created_at::date >= p_start_date
      AND created_at::date <= p_end_date
    GROUP BY agent_id
  ) pending ON pending.agent_id = rea.id
  LEFT JOIN (
    SELECT agent_id, COUNT(*) as count
    FROM lead_replacement_requests
    WHERE status = 'approved'
      AND resolved_at::date >= p_start_date
      AND resolved_at::date <= p_end_date
    GROUP BY agent_id
  ) approved ON approved.agent_id = rea.id
  WHERE pending.count > 0 OR approved.count > 0 OR EXISTS (
    SELECT 1 FROM lead_generation_tasks lgt
    WHERE lgt.agent_id = rea.id
    AND lgt.status = 'active'
  );

  RETURN jsonb_build_object(
    'success', true,
    'counts', COALESCE(v_counts, '[]'::jsonb),
    'period_start', p_start_date,
    'period_end', p_end_date
  );
END;
$$;


ALTER FUNCTION "public"."get_replacement_request_counts"("p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_replacement_request_counts"("p_start_date" "date", "p_end_date" "date") IS 'Gets counts of pending and approved replacement requests per agent for a time period';



CREATE OR REPLACE FUNCTION "public"."get_state_table_name"("state_name" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
RETURN CASE state_name
WHEN 'Baden-Württemberg' THEN 'baden_wuerttemberg'
WHEN 'Bayern' THEN 'bayern'
WHEN 'Berlin' THEN 'berlin'
WHEN 'Brandenburg' THEN 'brandenburg'
WHEN 'Bremen' THEN 'bremen'
WHEN 'Hamburg' THEN 'hamburg'
WHEN 'Hessen' THEN 'hessen'
WHEN 'Niedersachsen' THEN 'niedersachsen'
WHEN 'Mecklenburg-Vorpommern' THEN 'mecklenburg_vorpommern'
WHEN 'Nordrhein-Westfalen' THEN 'nordrhein_westfalen'
WHEN 'Rheinland-Pfalz' THEN 'rheinland_pfalz'
WHEN 'Saarland' THEN 'saarland'
WHEN 'Sachsen' THEN 'sachsen'
WHEN 'Sachsen-Anhalt' THEN 'sachsen_anhalt'
WHEN 'Schleswig-Holstein' THEN 'schleswig_holstein'
WHEN 'Thüringen' THEN 'thueringen'
ELSE NULL
END;
END;
$$;


ALTER FUNCTION "public"."get_state_table_name"("state_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_task_total_leads_in_blocks"("p_task_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
SELECT COALESCE(SUM(leads_count), 0)::integer
FROM task_lead_pricing_blocks
WHERE task_id = p_task_id;
$$;


ALTER FUNCTION "public"."get_task_total_leads_in_blocks"("p_task_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_task_total_value"("p_task_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
SELECT COALESCE(SUM(leads_count * price_per_lead), 0)
FROM task_lead_pricing_blocks
WHERE task_id = p_task_id;
$$;


ALTER FUNCTION "public"."get_task_total_value"("p_task_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_performance_with_leads"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone) RETURNS TABLE("user_id" "uuid", "user_email" "text", "user_name" "text", "total_contacted" bigint, "a_leads" bigint, "b_leads" bigint, "c_leads" bigint, "d_leads" bigint, "total_time_seconds" numeric, "avg_time_per_lead_seconds" numeric, "total_sessions" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.email::text,
        p.username,
        COUNT(DISTINCT ls.listing_id) as total_contacted,
        COUNT(DISTINCT CASE WHEN la.lead_rating = 'A' THEN ls.listing_id END) as a_leads,
        COUNT(DISTINCT CASE WHEN la.lead_rating = 'B' THEN ls.listing_id END) as b_leads,
        COUNT(DISTINCT CASE WHEN la.lead_rating = 'C' THEN ls.listing_id END) as c_leads,
        COUNT(DISTINCT CASE WHEN la.lead_rating = 'D' THEN ls.listing_id END) as d_leads,
        COALESCE(SUM(ls.total_duration_seconds), 0)::numeric as total_time_seconds,
        COALESCE(AVG(ls.total_duration_seconds), 0)::numeric as avg_time_per_lead_seconds,
        COUNT(DISTINCT ls.id) as total_sessions
    FROM auth.users u
    LEFT JOIN profiles p ON p.id = u.id
    LEFT JOIN listing_sessions ls ON ls.user_id = u.id
        AND ls.closed_at IS NOT NULL
        AND ls.opened_at >= p_start_date
        AND ls.opened_at <= p_end_date
    LEFT JOIN lead_actions la ON la.listing_id = ls.listing_id
        AND la.source_table_name = ls.source_table_name
    WHERE p.role IS NOT NULL
    GROUP BY u.id, u.email, p.username
    HAVING COUNT(DISTINCT ls.id) > 0
    ORDER BY total_contacted DESC;
END;
$$;


ALTER FUNCTION "public"."get_user_performance_with_leads"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_reschedule_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF OLD.scheduled_date IS NOT NULL AND NEW.scheduled_date != OLD.scheduled_date THEN
NEW.reschedule_count := COALESCE(OLD.reschedule_count, 0) + 1;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."increment_reschedule_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_task_delivered_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Increment the count
  UPDATE lead_generation_tasks
  SET delivered_leads_count = COALESCE(delivered_leads_count, 0) + 1
  WHERE id = NEW.task_id;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."increment_task_delivered_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin_or_management"("p_user" "uuid" DEFAULT "auth"."uid"()) RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists(
    select 1 from public.profiles
    where id = coalesce(p_user, auth.uid())
      and role in ('admin','management')
  );
$$;


ALTER FUNCTION "public"."is_admin_or_management"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_scraper"("p_user" "uuid" DEFAULT "auth"."uid"()) RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists(
    select 1 from public.profiles
    where id = coalesce(p_user, auth.uid())
      and role in ('scrape','scraper')
  );
$$;


ALTER FUNCTION "public"."is_scraper"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_assignment_triggers"() RETURNS TABLE("table_name" "text", "trigger_name" "text", "event_manipulation" "text", "action_timing" "text", "action_statement" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    t.event_object_table::text,
    t.trigger_name::text,
    t.event_manipulation::text,
    t.action_timing::text,
    t.action_statement::text
  FROM information_schema.triggers t
  WHERE (t.trigger_name LIKE '%assigned%' OR t.trigger_name LIKE '%populate_assigned%')
    AND t.event_object_schema = 'public'
  ORDER BY t.event_object_table, t.trigger_name;
END;
$$;


ALTER FUNCTION "public"."list_assignment_triggers"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."list_assignment_triggers"() IS 'Lists all assignment-related triggers in the database. Useful for debugging.';



CREATE OR REPLACE FUNCTION "public"."list_lead_replacement_requests"("p_status" "text" DEFAULT NULL::"text", "p_agent_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_profile profiles%ROWTYPE;
  v_requests jsonb;
BEGIN
  -- Get the user's profile
  SELECT * INTO v_profile
  FROM profiles
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  -- Agents can only see their own requests
  IF v_profile.role = 'agent' THEN
    -- Get agent_id for this user
    SELECT id INTO p_agent_id
    FROM real_estate_agents
    WHERE profile_id = auth.uid();
    
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'Agent profile not found');
    END IF;
  END IF;

  -- Build query
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', lrr.id,
      'task_lead_id', lrr.task_lead_id,
      'agent_id', lrr.agent_id,
      'agent_name', rea.name,
      'listing_id', lrr.listing_id,
      'source_table_name', lrr.source_table_name,
      'lead_internal_id', lrr.lead_internal_id,
      'reason', lrr.reason,
      'status', lrr.status,
      'created_at', lrr.created_at,
      'resolved_at', lrr.resolved_at,
      'resolved_by', lrr.resolved_by,
      'resolver_name', COALESCE(resolver_agent.name, resolver_profile.username),
      'resolution_note', lrr.resolution_note
    )
    ORDER BY lrr.created_at DESC
  ) INTO v_requests
  FROM lead_replacement_requests lrr
  JOIN real_estate_agents rea ON rea.id = lrr.agent_id
  LEFT JOIN profiles resolver_profile ON resolver_profile.id = lrr.resolved_by
  LEFT JOIN real_estate_agents resolver_agent ON resolver_agent.profile_id = resolver_profile.id
  WHERE (p_status IS NULL OR lrr.status = p_status)
    AND (p_agent_id IS NULL OR lrr.agent_id = p_agent_id);

  RETURN jsonb_build_object(
    'success', true,
    'requests', COALESCE(v_requests, '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."list_lead_replacement_requests"("p_status" "text", "p_agent_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."list_lead_replacement_requests"("p_status" "text", "p_agent_id" "uuid") IS 'Lists replacement requests with optional filtering by status and agent';



CREATE OR REPLACE FUNCTION "public"."log_lead_event_audit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_actor uuid;
BEGIN
  v_actor := COALESCE((SELECT auth.uid()), NEW.updated_by, OLD.updated_by, NEW.created_by, OLD.created_by);

  INSERT INTO lead_event_audits (event_id, action, changed_by, previous_record, new_record)
  VALUES (
    COALESCE(NEW.id, OLD.id),
    TG_OP,
    v_actor,
    CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
    CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."log_lead_event_audit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."maintain_scraper_task_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Handle INSERT
  IF TG_OP = 'INSERT' THEN
    IF NEW.scraper_task_id IS NOT NULL THEN
      UPDATE public.scraper_tasks
      SET current_lead_count = current_lead_count + 1,
          updated_at = NOW()
      WHERE id = NEW.scraper_task_id;
    END IF;
    RETURN NEW;
  END IF;
  -- Handle UPDATE
  IF TG_OP = 'UPDATE' THEN
    -- If scraper_task_id changed
    IF NEW.scraper_task_id IS DISTINCT FROM OLD.scraper_task_id THEN
      -- Decrement old if exists
      IF OLD.scraper_task_id IS NOT NULL THEN
        UPDATE public.scraper_tasks
        SET current_lead_count = GREATEST(0, current_lead_count - 1),
            updated_at = NOW()
        WHERE id = OLD.scraper_task_id;
      END IF;
      -- Increment new if exists
      IF NEW.scraper_task_id IS NOT NULL THEN
        UPDATE public.scraper_tasks
        SET current_lead_count = current_lead_count + 1,
            updated_at = NOW()
        WHERE id = NEW.scraper_task_id;
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  -- Handle DELETE
  IF TG_OP = 'DELETE' THEN
    IF OLD.scraper_task_id IS NOT NULL THEN
      UPDATE public.scraper_tasks
      SET current_lead_count = GREATEST(0, current_lead_count - 1),
          updated_at = NOW()
      WHERE id = OLD.scraper_task_id;
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."maintain_scraper_task_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_all_notifications_read"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
v_agent_id uuid;
v_updated_count int;
BEGIN
SELECT rea.id INTO v_agent_id
FROM real_estate_agents rea
JOIN profiles p ON p.id = rea.profile_id
WHERE p.id = auth.uid();

IF v_agent_id IS NULL THEN
RETURN jsonb_build_object('success', false, 'error', 'Agent not found');
END IF;

UPDATE agent_notifications
SET is_read = true
WHERE agent_id = v_agent_id
AND is_read = false;

GET DIAGNOSTICS v_updated_count = ROW_COUNT;

RETURN jsonb_build_object('success', true, 'updated_count', v_updated_count);
END;
$$;


ALTER FUNCTION "public"."mark_all_notifications_read"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
v_agent_id uuid;
BEGIN
SELECT rea.id INTO v_agent_id
FROM real_estate_agents rea
JOIN profiles p ON p.id = rea.profile_id
WHERE p.id = auth.uid();

IF v_agent_id IS NULL THEN
RETURN jsonb_build_object('success', false, 'error', 'Agent not found');
END IF;

UPDATE agent_notifications
SET is_read = true
WHERE id = p_notification_id
AND agent_id = v_agent_id;

IF FOUND THEN
RETURN jsonb_build_object('success', true);
ELSE
RETURN jsonb_build_object('success', false, 'error', 'Notification not found or access denied');
END IF;
END;
$$;


ALTER FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_username"("p_username" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF p_username IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN lower(regexp_replace(trim(p_username), '[^a-z0-9._-]', '', 'g'));
END;
$$;


ALTER FUNCTION "public"."normalize_username"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_agent_assignment_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_table_name text := TG_TABLE_NAME;
  v_internal_id text;
  v_title text := 'New Lead Assigned';
  v_message text;
BEGIN
  IF NEW.assigned_agent_id IS NULL OR (OLD.assigned_agent_id IS NOT DISTINCT FROM NEW.assigned_agent_id) THEN
    RETURN NEW;
  END IF;

  v_internal_id := NULLIF(NEW.internal_id, '');
  v_internal_id := COALESCE(v_internal_id, 'New Lead');
  v_message := 'A new lead has been assigned to you: ' || v_internal_id;

  INSERT INTO agent_notifications (
    agent_id,
    type,
    title,
    message,
    related_listing_id,
    related_source_table,
    related_internal_id,
    metadata
  ) VALUES (
    NEW.assigned_agent_id,
    'new_lead_assigned',
    v_title,
    v_message,
    NEW.id,
    v_table_name,
    v_internal_id,
    jsonb_build_object(
      'source_table', v_table_name,
      'assignment_changed_at', now(),
      'previous_agent_id', OLD.assigned_agent_id,
      'assignment_status', 'not_sent'
    )
  );

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_agent_assignment_change"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."notify_agent_assignment_change"() IS 'Creates a new_lead_assigned agent_notification when assigned_agent_id changes.';



CREATE OR REPLACE FUNCTION "public"."notify_agent_call_scheduled"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_listing_uuid uuid;
  v_internal_id text;
  v_time_window text;
  v_message text;
BEGIN
  BEGIN
    v_listing_uuid := NEW.listing_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_listing_uuid := NULL;
  END;

  v_internal_id := COALESCE(get_listing_internal_id(NEW.source_table_name, NEW.listing_id), 'Unbekannter Lead');

  IF NEW.call_type = 'time_range' AND NEW.scheduled_date_end IS NOT NULL THEN
    v_time_window := format(
      '%s zwischen %s und %s Uhr',
      to_char(NEW.scheduled_date AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'),
      to_char(NEW.scheduled_date AT TIME ZONE 'Europe/Berlin', 'HH24:MI'),
      to_char(NEW.scheduled_date_end AT TIME ZONE 'Europe/Berlin', 'HH24:MI')
    );
  ELSE
    v_time_window := format(
      '%s um %s Uhr',
      to_char(NEW.scheduled_date AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'),
      to_char(NEW.scheduled_date AT TIME ZONE 'Europe/Berlin', 'HH24:MI')
    );
  END IF;

  v_message := format('Für Lead %s wurde ein Anruf am %s geplant.', v_internal_id, v_time_window);

  INSERT INTO agent_notifications (
    agent_id,
    type,
    title,
    message,
    related_listing_id,
    related_source_table,
    related_internal_id,
    metadata
  ) VALUES (
    NEW.agent_id,
    'call_scheduled',
    'Neuer Telefontermin',
    v_message,
    v_listing_uuid,
    NEW.source_table_name,
    v_internal_id,
    jsonb_strip_nulls(jsonb_build_object(
      'scheduled_call_id', NEW.id,
      'call_type', NEW.call_type,
      'scheduled_date', NEW.scheduled_date,
      'scheduled_date_end', NEW.scheduled_date_end
    ))
  );

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_agent_call_scheduled"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_agent_new_lead"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  v_agent_id uuid;
  v_listing_record record;
  v_internal_id text;
BEGIN
  -- Get the agent_id from the task
  SELECT agent_id INTO v_agent_id
  FROM lead_generation_tasks
  WHERE id = NEW.task_id;

  IF v_agent_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Get listing details from dynamic table
  EXECUTE format(
    'SELECT internal_id, title FROM %I WHERE id = $1',
    NEW.source_table_name
  ) INTO v_listing_record
  USING NEW.listing_id;

  v_internal_id := v_listing_record.internal_id;

  -- Create notification
  INSERT INTO agent_notifications (
    agent_id,
    type,
    title,
    message,
    related_listing_id,
    related_source_table,
    related_internal_id,
    metadata
  ) VALUES (
    v_agent_id,
    'new_lead_assigned',
    'Neuer Lead zugewiesen',
    'Ein neuer Lead wurde Ihnen zugewiesen: ' || COALESCE(v_internal_id, 'Neuer Lead'),
    NEW.listing_id,
    NEW.source_table_name,
    v_internal_id,
    jsonb_build_object(
      'task_lead_id', NEW.id,
      'task_id', NEW.task_id
    )
  );

  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."notify_agent_new_lead"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_agent_replacement_resolution"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_notification_type text;
  v_title text;
  v_message text;
BEGIN
  -- Only create notification when status changes from pending to approved/denied
  IF OLD.status = 'pending' AND NEW.status IN ('approved', 'denied') THEN
    IF NEW.status = 'approved' THEN
      v_notification_type := 'replacement_approved';
      v_title := 'Ersatzanfrage genehmigt';
      v_message := 'Ihre Ersatzanfrage wurde genehmigt. Der Lead wurde von Ihrem Konto entfernt.';
    ELSE
      v_notification_type := 'replacement_denied';
      v_title := 'Ersatzanfrage abgelehnt';
      v_message := 'Ihre Ersatzanfrage wurde abgelehnt. ' ||
                  COALESCE('Grund: ' || NEW.resolution_note, 'Bitte arbeiten Sie weiter mit diesem Lead.');
    END IF;

    INSERT INTO agent_notifications (
      agent_id,
      type,
      title,
      message,
      related_listing_id,
      related_source_table,
      related_internal_id,
      metadata
    ) VALUES (
      NEW.agent_id,
      v_notification_type,
      v_title,
      v_message,
      NEW.listing_id,
      NEW.source_table_name,
      NEW.lead_internal_id,
      jsonb_build_object(
        'request_id', NEW.id,
        'resolved_at', NEW.resolved_at,
        'resolution_note', NEW.resolution_note
      )
    );
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_agent_replacement_resolution"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_scraper_task_assigned"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.assigned_scraper_id is null then
    return new;
  end if;

  -- Only notify on new assignment or assignment change
  if tg_op = 'INSERT' or (old.assigned_scraper_id is distinct from new.assigned_scraper_id) then
    perform public.create_scraper_notification(
      new.assigned_scraper_id,
      new.id,
      'task_assigned',
      'Scraper task assigned',
      format('Region: %s', coalesce(new.region, '')),
      jsonb_build_object('task_id', new.id, 'region', new.region)
    );
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."notify_scraper_task_assigned"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."populate_assigned_agent_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  job_assigned_to text;
  job_id_to_use uuid;
  should_be_assigned uuid;
BEGIN
  job_id_to_use := CASE
    WHEN TG_OP = 'UPDATE' THEN COALESCE(NEW.job_id, OLD.job_id)
    ELSE NEW.job_id
  END;

  -- Respect manual unassignment (value -> NULL)
  IF TG_OP = 'UPDATE' AND OLD.assigned_agent_id IS NOT NULL AND NEW.assigned_agent_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- INSERT: populate if missing and job_id exists
  IF TG_OP = 'INSERT' THEN
    IF NEW.assigned_agent_id IS NULL AND job_id_to_use IS NOT NULL THEN
      SELECT assigned_to INTO job_assigned_to FROM scrape_jobs WHERE id = job_id_to_use;
      IF job_assigned_to IS NOT NULL AND LENGTH(TRIM(job_assigned_to)) > 0 THEN
        BEGIN
          should_be_assigned := job_assigned_to::uuid;
          NEW.assigned_agent_id := should_be_assigned;
        EXCEPTION
          WHEN invalid_text_representation THEN NULL;
        END;
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: only populate when job_id was just added (NULL -> NOT NULL) and value is missing
  IF TG_OP = 'UPDATE' THEN
    IF NEW.assigned_agent_id IS NULL
       AND job_id_to_use IS NOT NULL
       AND OLD.job_id IS NULL THEN
      SELECT assigned_to INTO job_assigned_to FROM scrape_jobs WHERE id = job_id_to_use;
      IF job_assigned_to IS NOT NULL AND LENGTH(TRIM(job_assigned_to)) > 0 THEN
        BEGIN
          should_be_assigned := job_assigned_to::uuid;
          NEW.assigned_agent_id := should_be_assigned;
        EXCEPTION
          WHEN invalid_text_representation THEN NULL;
        END;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."populate_assigned_agent_from_job"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."populate_assigned_agent_from_job"() IS 'Auto-populates assigned_agent_id in dynamic scrape tables from scrape_jobs.assigned_to only on INSERT or when job_id is first added; respects manual unassignment and will not repopulate on later updates.';



CREATE OR REPLACE FUNCTION "public"."populate_assigned_to_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  job_assigned_to text;
  job_id_to_use uuid;
  should_be_assigned uuid;
BEGIN
  job_id_to_use := CASE
    WHEN TG_OP = 'UPDATE' THEN COALESCE(NEW.job_id, OLD.job_id)
    ELSE NEW.job_id
  END;

  -- Respect explicit unassignment (value -> NULL)
  IF TG_OP = 'UPDATE' AND OLD.assigned_agent_id IS NOT NULL AND NEW.assigned_agent_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- INSERT: populate if missing and job_id exists
  IF TG_OP = 'INSERT' THEN
    IF NEW.assigned_agent_id IS NULL AND job_id_to_use IS NOT NULL THEN
      SELECT assigned_to INTO job_assigned_to FROM scrape_jobs WHERE id = job_id_to_use;
      IF job_assigned_to IS NOT NULL AND LENGTH(TRIM(job_assigned_to)) > 0 THEN
        BEGIN
          should_be_assigned := job_assigned_to::uuid;
          NEW.assigned_agent_id := should_be_assigned;
        EXCEPTION
          WHEN invalid_text_representation THEN NULL;
        END;
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: only populate when job_id was just added (NULL -> NOT NULL) and value is missing
  IF TG_OP = 'UPDATE' THEN
    IF NEW.assigned_agent_id IS NULL
       AND job_id_to_use IS NOT NULL
       AND OLD.job_id IS NULL THEN
      SELECT assigned_to INTO job_assigned_to FROM scrape_jobs WHERE id = job_id_to_use;
      IF job_assigned_to IS NOT NULL AND LENGTH(TRIM(job_assigned_to)) > 0 THEN
        BEGIN
          should_be_assigned := job_assigned_to::uuid;
          NEW.assigned_agent_id := should_be_assigned;
        EXCEPTION
          WHEN invalid_text_representation THEN NULL;
        END;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."populate_assigned_to_from_job"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."populate_assigned_to_from_job"() IS 'Auto-populates assigned_agent_id in single_scrapes from scrape_jobs.assigned_to only on INSERT or when job_id is first added; respects manual unassignment and will not repopulate on later updates.';



CREATE OR REPLACE FUNCTION "public"."populate_location_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
job_state text;
job_major_city text;
BEGIN
IF NEW.job_id IS NOT NULL THEN
SELECT state, next_major_city
INTO job_state, job_major_city
FROM scrape_jobs
WHERE id = NEW.job_id;

IF NEW.state IS NULL AND job_state IS NOT NULL THEN
NEW.state := job_state;
END IF;

IF NEW.nearest_major_city IS NULL AND job_major_city IS NOT NULL THEN
NEW.nearest_major_city := job_major_city;
END IF;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."populate_location_from_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."populate_single_scrape_location_data"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
job_state text;
job_city text;
BEGIN
IF NEW.job_id IS NOT NULL THEN
SELECT state, next_major_city
INTO job_state, job_city
FROM scrape_jobs
WHERE id = NEW.job_id;

IF job_state IS NOT NULL AND (NEW.state IS NULL OR NEW.state = '') THEN
NEW.state := job_state;
END IF;

IF job_city IS NOT NULL AND (NEW.nearest_major_city IS NULL OR NEW.nearest_major_city = '') THEN
NEW.nearest_major_city := job_city;
END IF;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."populate_single_scrape_location_data"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propagate_scrape_error"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF NEW.has_error = true AND (OLD.has_error IS NULL OR OLD.has_error = false) THEN
UPDATE scrape_jobs
SET 
status = 'failed',
completed_at = now()
WHERE id = NEW.scrape_job_id;

RAISE NOTICE 'Scrape job % marked as failed due to error', NEW.scrape_job_id;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."propagate_scrape_error"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."propagate_scrape_error"() IS 'Automatically marks scrape_jobs as failed when has_error is set to true in scrape_progress';



CREATE OR REPLACE FUNCTION "public"."register_scrape_table"("p_table_name" "text", "p_job_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
INSERT INTO scrape_tables_registry (table_name, job_id, is_active)
VALUES (p_table_name, p_job_id, true)
ON CONFLICT (table_name) DO UPDATE
SET is_active = true, job_id = p_job_id;
END;
$$;


ALTER FUNCTION "public"."register_scrape_table"("p_table_name" "text", "p_job_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_lead_replacement"("p_task_lead_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  v_task_lead task_leads%ROWTYPE;
  v_task lead_generation_tasks%ROWTYPE;
  v_agent real_estate_agents%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_listing_record jsonb;
  v_internal_id text;
  v_request_id uuid;
BEGIN
  -- Validate reason length
  IF char_length(trim(p_reason)) < 10 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Reason must be at least 10 characters long'
    );
  END IF;

  -- Get the task lead record
  SELECT * INTO v_task_lead
  FROM task_leads
  WHERE id = p_task_lead_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Task lead assignment not found'
    );
  END IF;

  -- Get the task
  SELECT * INTO v_task
  FROM lead_generation_tasks
  WHERE id = v_task_lead.task_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Task not found'
    );
  END IF;

  -- Get the agent
  SELECT * INTO v_agent
  FROM real_estate_agents
  WHERE id = v_task.agent_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Agent not found'
    );
  END IF;

  -- Get the user's profile
  SELECT * INTO v_profile
  FROM profiles
  WHERE id = auth.uid();

  IF NOT FOUND OR v_profile.role != 'agent' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Only agents can request lead replacements'
    );
  END IF;

  -- Verify the agent profile matches
  IF v_agent.profile_id != auth.uid() THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You can only request replacements for your own assigned leads'
    );
  END IF;

  -- Check for existing pending request
  IF EXISTS (
    SELECT 1 FROM lead_replacement_requests
    WHERE task_lead_id = p_task_lead_id
    AND status = 'pending'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'A pending replacement request already exists for this lead'
    );
  END IF;

  -- Try to get the internal_id from the listing
  BEGIN
    EXECUTE format('SELECT internal_id FROM %I WHERE id = $1', v_task_lead.source_table_name)
    INTO v_internal_id
    USING v_task_lead.listing_id;
  EXCEPTION
    WHEN OTHERS THEN
      v_internal_id := NULL;
  END;

  -- Create the replacement request
  INSERT INTO lead_replacement_requests (
    task_lead_id,
    agent_id,
    listing_id,
    source_table_name,
    lead_internal_id,
    reason,
    status
  ) VALUES (
    p_task_lead_id,
    v_task.agent_id,
    v_task_lead.listing_id,
    v_task_lead.source_table_name,
    v_internal_id,
    trim(p_reason),
    'pending'
  )
  RETURNING id INTO v_request_id;

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_request_id
  );
END;
$_$;


ALTER FUNCTION "public"."request_lead_replacement"("p_task_lead_id" "uuid", "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."request_lead_replacement"("p_task_lead_id" "uuid", "p_reason" "text") IS 'Allows agents to request a lead replacement for their assigned leads';



CREATE OR REPLACE FUNCTION "public"."resolve_lead_replacement_request"("p_request_id" "uuid", "p_status" "text", "p_resolution_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
v_profile profiles%ROWTYPE;
v_request lead_replacement_requests%ROWTYPE;
v_task_lead task_leads%ROWTYPE;
v_sql text;
BEGIN
IF p_status NOT IN ('approved', 'denied') THEN
RETURN jsonb_build_object(
'success', false,
'error', 'Status must be either "approved" or "denied"'
);
END IF;

SELECT * INTO v_profile
FROM profiles
WHERE id = auth.uid();

IF NOT FOUND OR v_profile.role NOT IN ('admin', 'super_admin') THEN
RETURN jsonb_build_object(
'success', false,
'error', 'Only admins can resolve replacement requests'
);
END IF;

SELECT * INTO v_request
FROM lead_replacement_requests
WHERE id = p_request_id;

IF NOT FOUND THEN
RETURN jsonb_build_object(
'success', false,
'error', 'Replacement request not found'
);
END IF;

IF v_request.status != 'pending' THEN
RETURN jsonb_build_object(
'success', false,
'error', 'This request has already been resolved'
);
END IF;

UPDATE lead_replacement_requests
SET
status = p_status,
resolved_at = now(),
resolved_by = auth.uid(),
resolution_note = p_resolution_note
WHERE id = p_request_id;

IF p_status = 'approved' THEN
SELECT * INTO v_task_lead
FROM task_leads
WHERE id = v_request.task_lead_id;

IF FOUND THEN
v_sql := format(
'UPDATE %I SET assigned_agent_id = NULL, assignment_status = %L WHERE id = %L',
v_task_lead.source_table_name,
'replacement_approved',
v_task_lead.listing_id
);
EXECUTE v_sql;

DELETE FROM task_leads WHERE id = v_request.task_lead_id;
END IF;
END IF;

RETURN jsonb_build_object(
'success', true,
'message', 'Replacement request resolved successfully'
);
END;
$$;


ALTER FUNCTION "public"."resolve_lead_replacement_request"("p_request_id" "uuid", "p_status" "text", "p_resolution_note" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."resolve_lead_replacement_request"("p_request_id" "uuid", "p_status" "text", "p_resolution_note" "text") IS 'Allows admins to approve or deny replacement requests';



CREATE OR REPLACE FUNCTION "public"."send_push_notification_on_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_assignment_status text;
  v_functions_host text := 'https://owrnonmqwnluuqarehrf.supabase.co';
  v_internal_token text := 'ce9d6d4728f2bc8c080324850c85f90a34283dab6da0ce296c4d4e32cd5b619d';
  v_anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im93cm5vbm1xd25sdXVxYXJlaHJmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjAyNzI3NDksImV4cCI6MjA3NTg0ODc0OX0.iiSN5urZAF184yL4Bf8YiUg95-V8ymT9YCwFNV4s9Rs';
  v_target_url text;
BEGIN
  -- Gate: leads push only when sent
  IF NEW.type = 'new_lead_assigned' THEN
    BEGIN
      v_assignment_status := NEW.metadata ->> 'assignment_status';
      IF v_assignment_status IS DISTINCT FROM 'sent' THEN
        RETURN NEW;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- If metadata parsing fails, proceed
    END;
  END IF;

  -- Build Deep Linking URL
  IF NEW.related_listing_id IS NOT NULL THEN
    v_target_url := '/agent-portal?leadId=' || NEW.related_listing_id || '&table=' || COALESCE(NEW.related_source_table, 'single_scrapes');
  ELSE
    v_target_url := '/agent-portal';
  END IF;

  -- Attempt to send push notification
  PERFORM net.http_post(
    url := v_functions_host || '/functions/v1/send-agent-push-notification',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Internal-Token', v_internal_token,
      'Authorization', 'Bearer ' || v_anon_key,
      'apikey', v_anon_key
    ),
    body := jsonb_build_object(
      'agentId', NEW.agent_id,
      'title', NEW.title,
      'body', NEW.message,
      'data', jsonb_build_object(
        'notificationId', NEW.id,
        'type', NEW.type,
        'listingId', NEW.related_listing_id,
        'sourceTable', NEW.related_source_table,
        'url', v_target_url
      )
    )
  );

  RETURN NEW;
EXCEPTION WHEN others THEN
  -- Never block the main transaction
  RAISE WARNING 'Push notification failed (dispatcher): %', SQLERRM;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."send_push_notification_on_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_agent_push_subscriptions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_agent_push_subscriptions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_fixed_phone_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  job_phone_override text;
BEGIN
  -- Get phone_override from the parent scrape_jobs record
  SELECT phone_override INTO job_phone_override
  FROM scrape_jobs
  WHERE id = NEW.job_id;

  -- If job has phone_override and fixed_phone is not already set, set it
  -- This ensures fixed_phone is populated on INSERT
  IF job_phone_override IS NOT NULL AND LENGTH(TRIM(job_phone_override)) > 0 THEN
    IF NEW.fixed_phone IS NULL OR LENGTH(TRIM(NEW.fixed_phone)) = 0 THEN
      NEW.fixed_phone := job_phone_override;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_fixed_phone_from_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_scraper_tasks_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_scraper_tasks_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_single_scrape_messaged_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  job_record RECORD;
  approved_flag boolean;
BEGIN
  SELECT single_scrape,
         owner_title,
         owner_name,
         COALESCE(owner_name_approved, false) AS owner_name_approved,
         COALESCE(is_urgent, false) AS is_urgent
  INTO job_record
  FROM scrape_jobs
  WHERE id = NEW.job_id;

  IF job_record.single_scrape IS TRUE THEN
    approved_flag := CASE
      WHEN job_record.owner_name IS NOT NULL AND LENGTH(TRIM(job_record.owner_name)) > 0 THEN true
      ELSE job_record.owner_name_approved
    END;

    INSERT INTO lead_actions (
      listing_id,
      source_table_name,
      ebay_message_status,
      owner_title,
      owner_name,
      owner_name_approved,
      created_at,
      updated_at
    ) VALUES (
      NEW.id,
      'single_scrapes',
      'messaged',
      job_record.owner_title,
      job_record.owner_name,
      approved_flag,
      NOW(),
      NOW()
    )
    ON CONFLICT (listing_id, source_table_name)
    DO UPDATE SET
      ebay_message_status = 'messaged',
      owner_title = COALESCE(EXCLUDED.owner_title, lead_actions.owner_title),
      owner_name = COALESCE(EXCLUDED.owner_name, lead_actions.owner_name),
      owner_name_approved = COALESCE(EXCLUDED.owner_name_approved, lead_actions.owner_name_approved),
      updated_at = NOW();

    IF job_record.owner_name IS NOT NULL AND LENGTH(TRIM(job_record.owner_name)) > 0 THEN
      UPDATE single_scrapes
      SET seller_name = COALESCE(
        seller_name,
        CASE
          WHEN job_record.owner_title IS NOT NULL AND LENGTH(TRIM(job_record.owner_title)) > 0 THEN CONCAT(job_record.owner_title, ' ', job_record.owner_name)
          ELSE job_record.owner_name
        END
      )
      WHERE id = NEW.id;
    END IF;

    IF job_record.is_urgent THEN
      UPDATE single_scrapes
      SET is_urgent = true
      WHERE id = NEW.id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_single_scrape_messaged_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_agent_task_to_scraper_tasks"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Update all scraper tasks linked to this agent task
  UPDATE scraper_tasks
  SET 
    linked_agent_total_leads = NEW.total_leads_needed,
    linked_agent_delivered_leads = NEW.delivered_leads_count,
    -- Adjust target based on delta of total_leads_needed (only on UPDATE)
    target_lead_count = CASE
      WHEN TG_OP = 'UPDATE' THEN
        GREATEST(1, target_lead_count + (
          (NEW.total_leads_needed - OLD.total_leads_needed) * COALESCE(multiplier, 4)
        )::integer)
      ELSE target_lead_count
    END,
    updated_at = NOW()
  WHERE source_agent_order_id = NEW.id;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_agent_task_to_scraper_tasks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_assigned_agent_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.job_id IS NOT NULL THEN
    SELECT assigned_to
    INTO NEW.assigned_agent_id
    FROM scrape_jobs
    WHERE id = NEW.job_id
      AND assigned_to IS NOT NULL;
  END IF;

  -- Leave assignment_status unchanged; Send will set it to 'sent'.
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_assigned_agent_from_job"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_assigned_agent_from_job"() IS 'Copies assigned_to from scrape_jobs into assigned_agent_id without changing assignment_status; send step controls status change.';



CREATE OR REPLACE FUNCTION "public"."sync_email_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF OLD.email IS DISTINCT FROM NEW.email THEN
    UPDATE single_scrapes
    SET email = NEW.email
    WHERE job_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_email_from_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_phone_override_to_single_scrapes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Only proceed if phone_override actually changed
  IF OLD.phone_override IS DISTINCT FROM NEW.phone_override THEN
    -- Update all related single_scrapes records where job_id matches
    UPDATE single_scrapes
    SET
      phone_override = NEW.phone_override,
      fixed_phone = NEW.phone_override,
      -- Update has_phone flag based on new value
      has_phone = CASE
        WHEN NEW.phone_override IS NOT NULL AND LENGTH(TRIM(NEW.phone_override)) > 0 THEN true
        ELSE false
      END,
      updated_at = now()
    WHERE job_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_phone_override_to_single_scrapes"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_phone_override_to_single_scrapes"() IS 'Automatically syncs phone_override from scrape_jobs to all related single_scrapes records when phone_override changes. Updates both fixed_phone and phone_override fields, and recalculates has_phone flag.';



CREATE OR REPLACE FUNCTION "public"."sync_scheduled_call_to_listing"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
call_date_value date;
BEGIN
IF (TG_OP = 'DELETE') THEN
EXECUTE format(
'UPDATE %I SET call_date = NULL WHERE id = $1::uuid',
OLD.source_table_name
) USING OLD.listing_id;
RETURN OLD;
ELSE
call_date_value := NEW.scheduled_date::date;

EXECUTE format(
'UPDATE %I SET call_date = $1 WHERE id = $2::uuid',
NEW.source_table_name
) USING call_date_value, NEW.listing_id;

RETURN NEW;
END IF;
END;
$_$;


ALTER FUNCTION "public"."sync_scheduled_call_to_listing"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_single_scrape_task"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_scraper_task_id UUID;
BEGIN
  -- Look up the parent job's scraper_task_id
  SELECT scraper_task_id INTO v_scraper_task_id
  FROM public.scrape_jobs
  WHERE id = NEW.job_id;
  -- If found, create/update the lead_action
  IF v_scraper_task_id IS NOT NULL THEN
    INSERT INTO public.lead_actions (
        listing_id, 
        source_table_name, 
        scraper_task_id,
        created_at,
        updated_at,
        call_status -- Required field
    )
    VALUES (
        NEW.id,
        'single_scrapes',
        v_scraper_task_id,
        NOW(),
        NOW(),
        'open' -- Default status
    )
    ON CONFLICT (listing_id) 
    DO UPDATE SET
        scraper_task_id = EXCLUDED.scraper_task_id,
        updated_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_single_scrape_task"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."test_assignment_logic"("p_listing_id" "uuid", "table_name" "text") RETURNS TABLE("listing_id" "uuid", "job_id" "uuid", "current_assigned_agent_id" "uuid", "job_assigned_to" "text", "should_be_assigned" "uuid", "needs_update" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  v_job_id uuid;
  v_current_assigned uuid;
  v_job_assigned_to text;
  v_should_be_assigned uuid;
BEGIN
  -- Get listing data
  EXECUTE format('
    SELECT job_id, assigned_agent_id
    INTO v_job_id, v_current_assigned
    FROM %I
    WHERE id = $1
  ', test_assignment_logic.table_name)
  USING p_listing_id;

  -- Get job assigned_to
  IF v_job_id IS NOT NULL THEN
    SELECT assigned_to
    INTO v_job_assigned_to
    FROM scrape_jobs
    WHERE id = v_job_id;

    -- Convert to UUID if valid
    IF v_job_assigned_to IS NOT NULL AND LENGTH(TRIM(v_job_assigned_to)) > 0 THEN
      BEGIN
        v_should_be_assigned := v_job_assigned_to::uuid;
      EXCEPTION
        WHEN invalid_text_representation THEN
          v_should_be_assigned := NULL;
      END;
    END IF;
  END IF;

  RETURN QUERY SELECT 
    p_listing_id,
    v_job_id,
    v_current_assigned,
    v_job_assigned_to,
    v_should_be_assigned,
    (v_current_assigned IS DISTINCT FROM v_should_be_assigned)::boolean;
END;
$_$;


ALTER FUNCTION "public"."test_assignment_logic"("p_listing_id" "uuid", "table_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."test_assignment_logic"("p_listing_id" "uuid", "table_name" "text") IS 'Tests assignment logic for a specific listing. Returns what the assigned_agent_id should be and if it needs updating.';



CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_baden_wuerttemberg"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_baden_wuerttemberg"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_bayern"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_bayern"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_berlin"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_berlin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_brandenburg"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_brandenburg"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_bremen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_bremen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_hamburg"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_hamburg"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_hessen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_hessen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_mecklenburg_vorpommern"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_mecklenburg_vorpommern"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_niedersachsen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_niedersachsen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_nordrhein_westfalen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_nordrhein_westfalen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_rheinland_pfalz"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_rheinland_pfalz"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_saarland"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_saarland"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_sachsen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_sachsen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_sachsen_anhalt"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_sachsen_anhalt"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_schleswig_holstein"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_schleswig_holstein"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_affalterbach_ba"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_affalterbach_ba"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_baden_w_rttembe"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_baden_w_rttembe');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_baden_w_rttembe"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_bebensee_schles"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_bebensee_schles"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_500_1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_500_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_4"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_berlin_50_4');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_4"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_5_5"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_berlin_5_5');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_5_5"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_2_18"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_2_18');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_2_18"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_4_2"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_4_2');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_4_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_10"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_50_10');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_10"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_11"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_50_11');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_11"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_12"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_50_12');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_12"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_8"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_50_8');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_8"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_5_13"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_cologne_5_13');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_5_13"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_daasdorf_a_berg"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_daasdorf_a_berg"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_6"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_dusseldorf_50_6');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_6"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_7"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_dusseldorf_50_7');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_7"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_fachbach_rheinl"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_fachbach_rheinl"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gablenz_sachsen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gablenz_sachsen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gaiberg_5_1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_gaiberg_5_1');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gaiberg_5_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_hilden_nordrhei"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_hilden_nordrhei"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_m_nchen_bayern_"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_m_nchen_bayern_"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_munich_5_4"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_munich_5_4');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_munich_5_4"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_rabenau_hessen_"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_rabenau_hessen_"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_stuttgart_5_14"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_stuttgart_5_14');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_stuttgart_5_14"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_3"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_wolfach_10_3');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_3"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_4"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_wolfach_10_4');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_4"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_wolfach_20_1');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_2"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_apartments_for_sale_wolfach_20_2');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_all_germany_5"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_commercial_properties_all_germany_5');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_all_germany_5"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_frankfurt_50_"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_commercial_properties_frankfurt_50_');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_frankfurt_50_"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_m_nchen_bayer"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_m_nchen_bayer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_munich_5_6"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_commercial_properties_munich_5_6');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_munich_5_6"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_2_17"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_custom_all_germany_2_17');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_2_17"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_50_16"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_custom_all_germany_50_16');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_50_16"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_custom_baden_w_rttemberg_50_15"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_custom_baden_w_rttemberg_50_15');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_custom_baden_w_rttemberg_50_15"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_custom_berlin_50_2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_custom_berlin_50_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_custom_h_rth_nordrhein_westfalen_50"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_custom_h_rth_nordrhein_westfalen_50"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_bayern_2_11"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_bayern_2_11');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_bayern_2_11"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_20_1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_berlin_20_1');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_20_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_berlin_50_1');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_dusseldorf_5_13"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_dusseldorf_5_13');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_dusseldorf_5_13"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_3"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_3"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_4"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_4"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_modautal_hessen_5_1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_modautal_hessen_5_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_100_2"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_munich_100_2');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_100_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_5_5"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_munich_5_5');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_5_5"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_2"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_zeithain_10_2');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_3"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_houses_for_sale_zeithain_10_3');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_3"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_baden_w_rttemberg_5_4"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_land_gardens_baden_w_rttemberg_5_4');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_baden_w_rttemberg_5_4"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_frankfurt_5_3"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_land_gardens_frankfurt_5_3');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_frankfurt_5_3"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_gablenz_sachsen_50_3"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_gablenz_sachsen_50_3"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_10"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_real_estate_baden_w_rttemberg_2_10');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_10"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_9"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_real_estate_baden_w_rttemberg_2_9');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_9"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_bayern_10_6"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_real_estate_bayern_10_6');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_bayern_10_6"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_120_1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_120_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_30_2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_30_2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_50_1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_50_1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_cologne_2_7"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_real_estate_cologne_2_7');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_cologne_2_7"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_dusseldorf_5_12"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id('scrape_real_estate_dusseldorf_5_12');
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_dusseldorf_5_12"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_essen_fulerum_nordrhein"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_essen_fulerum_nordrhein"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_h_rth_nordrhein_westfal"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_scrape_real_estate_h_rth_nordrhein_westfal"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_single_scrapes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_single_scrapes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_func_internal_id_thueringen"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.internal_id IS NULL OR NEW.internal_id = '' THEN
NEW.internal_id := get_next_internal_id();
END IF;
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_func_internal_id_thueringen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unarchive_listing"("p_archived_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
v_archived_data record;
v_user_role text;
v_listing_uuid uuid;
v_job_uuid uuid;
BEGIN
SELECT role INTO v_user_role
FROM profiles
WHERE id = auth.uid();

IF v_user_role != 'admin' THEN
RAISE EXCEPTION 'Only admin users can unarchive listings';
END IF;

SELECT * INTO v_archived_data
FROM archived_listings
WHERE id = p_archived_id;

IF v_archived_data IS NULL THEN
RAISE EXCEPTION 'Archived listing not found';
END IF;

v_listing_uuid := v_archived_data.original_listing_id::uuid;
v_job_uuid := v_archived_data.job_id::uuid;

EXECUTE format(
'INSERT INTO %I (
id, job_id, external_id, internal_id, title, title_de, 
description, description_de, price, area_sqm, rooms, 
bedrooms, bathrooms, city, ebay_url, images,
added_on_platform, scraped_at, status, anbieter_type, anbieter_type_de,
provision, provision_de, has_phone, phone, views, seller_name,
plot_area, year_built, floors, assigned_agent_id, assignment_status,
state, nearest_major_city, is_new, assigned_to,
call_status, lead_rating, notes_from_call, notes_general, rejection_reason,
source_table_name
) VALUES (
$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16,
$17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27, $28, $29, $30, $31, $32,
NULL, NULL, false, NULL,
NULL, NULL, NULL, NULL, NULL,
NULL
)',
v_archived_data.original_table_name
) USING 
v_listing_uuid,
v_job_uuid,
v_archived_data.external_id,
v_archived_data.internal_id,
v_archived_data.title,
v_archived_data.title_de,
v_archived_data.description,
v_archived_data.description_de,
v_archived_data.price,
v_archived_data.area_sqm,
v_archived_data.rooms,
v_archived_data.bedrooms,
v_archived_data.bathrooms,
v_archived_data.city,
v_archived_data.ebay_url,
v_archived_data.images,
v_archived_data.added_on_platform,
v_archived_data.scraped_at,
v_archived_data.status,
v_archived_data.anbieter_type,
v_archived_data.anbieter_type_de,
v_archived_data.provision,
v_archived_data.provision_de,
v_archived_data.has_phone,
v_archived_data.phone,
v_archived_data.views,
v_archived_data.seller_name,
v_archived_data.plot_area,
v_archived_data.year_built,
v_archived_data.floors,
v_archived_data.assigned_agent_id,
v_archived_data.assignment_status;

DELETE FROM archived_listings WHERE id = p_archived_id;

RETURN true;
EXCEPTION
WHEN others THEN
RAISE EXCEPTION 'Unarchive failed: %', SQLERRM;
END;
$_$;


ALTER FUNCTION "public"."unarchive_listing"("p_archived_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_agent_notes_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.updated_at = now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_agent_notes_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_agent_regions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.updated_at = now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_agent_regions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_call_overdue_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF NEW.status = 'pending' AND NEW.scheduled_date < CURRENT_DATE THEN
NEW.is_overdue := true;
ELSIF NEW.status != 'pending' THEN
NEW.is_overdue := false;
END IF;

RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_call_overdue_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_lead_generation_tasks_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.updated_at = now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_lead_generation_tasks_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_lead_replacement_requests_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_lead_replacement_requests_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_phone_override_from_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  job_phone_override text;
BEGIN
  -- Get phone_override from the parent scrape_jobs record
  SELECT phone_override INTO job_phone_override
  FROM scrape_jobs
  WHERE id = NEW.job_id;

  -- If job has phone_override and single_scrapes doesn't have one set, apply it
  -- This allows manual overrides to be preserved, but applies job override if missing
  IF job_phone_override IS NOT NULL AND LENGTH(TRIM(job_phone_override)) > 0 THEN
    IF NEW.phone_override IS NULL OR LENGTH(TRIM(NEW.phone_override)) = 0 THEN
      NEW.phone_override := job_phone_override;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_phone_override_from_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_scheduled_calls_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.updated_at = now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_scheduled_calls_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_scrape_progress_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.updated_at = now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_scrape_progress_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_single_scrape_has_phone"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF NEW.fixed_phone IS NOT NULL AND LENGTH(TRIM(NEW.fixed_phone)) > 0 THEN
NEW.has_phone := true;
ELSIF NEW.phone_override IS NOT NULL AND LENGTH(TRIM(NEW.phone_override)) > 0 THEN
NEW.has_phone := true;
ELSIF NEW.phone IS NOT NULL AND LENGTH(TRIM(NEW.phone)) > 0 THEN
NEW.has_phone := true;
ELSE
NEW.has_phone := false;
END IF;

NEW.updated_at := now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_single_scrape_has_phone"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_state_table_view_call_policy"("state_table_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
EXECUTE format('DROP POLICY IF EXISTS "Authenticated users can read %s" ON %I', 
state_table_name, state_table_name);

EXECUTE format('
CREATE POLICY "Admin scrape and view_edit can read all %s"
ON %I FOR SELECT
TO authenticated
USING (
EXISTS (
SELECT 1 FROM profiles
WHERE profiles.id = auth.uid()
AND profiles.role IN (''admin'', ''scrape'', ''view_edit'')
)
)', state_table_name, state_table_name);

EXECUTE format('
CREATE POLICY "view_call can read %s with phone"
ON %I FOR SELECT
TO authenticated
USING (
EXISTS (
SELECT 1 FROM profiles
WHERE profiles.id = auth.uid()
AND profiles.role = ''view_call''
)
AND (has_phone = true OR phone IS NOT NULL)
)', state_table_name, state_table_name);
END;
$$;


ALTER FUNCTION "public"."update_state_table_view_call_policy"("state_table_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_task_delivered_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
IF TG_OP = 'INSERT' THEN
UPDATE lead_generation_tasks
SET delivered_leads_count = delivered_leads_count + 1
WHERE id = NEW.task_id;
ELSIF TG_OP = 'DELETE' THEN
UPDATE lead_generation_tasks
SET delivered_leads_count = GREATEST(0, delivered_leads_count - 1)
WHERE id = OLD.task_id;
END IF;
RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_task_delivered_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_url_scrape_has_phone"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
IF NEW.phone_override IS NOT NULL AND LENGTH(TRIM(NEW.phone_override)) > 0 THEN
NEW.has_phone := true;
ELSIF NEW.phone IS NOT NULL AND LENGTH(TRIM(NEW.phone)) > 0 THEN
NEW.has_phone := true;
ELSE
NEW.has_phone := false;
END IF;

NEW.updated_at := now();
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_url_scrape_has_phone"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."call_next_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "call_id" "uuid" NOT NULL,
    "action" "public"."next_action_type" NOT NULL,
    "callback_preset" "public"."callback_preset",
    "scheduled_for" timestamp with time zone,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid"
);


ALTER TABLE "public"."call_next_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."calls" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid",
    "agent_id" "uuid" NOT NULL,
    "outcome" "public"."call_outcome" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid"
);


ALTER TABLE "public"."calls" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "listing_id" "uuid" NOT NULL,
    "lead_rating" "text",
    "call_status" "text" DEFAULT 'not_called'::"text",
    "notes_general" "text",
    "notes_from_call" "text",
    "rejection_reason" "text",
    "ai_summary" "text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source_table_name" "text",
    "ebay_message_status" "text" DEFAULT 'not_messaged'::"text",
    "translation_cache" "jsonb" DEFAULT '{}'::"jsonb",
    "photos_included" boolean DEFAULT true,
    "agent_notes" "text",
    "owner_title" "text",
    "owner_name" "text",
    "owner_name_approved" boolean DEFAULT false,
    "selected_task_id" "uuid",
    "scraper_task_id" "uuid"
);


ALTER TABLE "public"."lead_actions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."lead_actions"."selected_task_id" IS 'Task selected for this lead before it is sent';



CREATE TABLE IF NOT EXISTS "public"."listings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text",
    "title" "text" NOT NULL,
    "description" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "provision" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "title_de" "text",
    "description_de" "text",
    "provision_de" "text",
    "anbieter_type_de" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "call_date" "date",
    "agent_status" "text",
    "is_new_for_agent" boolean DEFAULT true,
    "call_reminder_sent_at" timestamp with time zone,
    "agent_viewed_at" timestamp with time zone,
    "call_completed" boolean DEFAULT false,
    "call_completed_at" timestamp with time zone,
    "email" "text",
    "lead_status" "text" DEFAULT 'New'::"text",
    "status_overridden" boolean DEFAULT false,
    "status_override_reason" "text",
    "status_overridden_by" "uuid",
    "status_overridden_at" timestamp with time zone,
    "status_override_locked" boolean DEFAULT false,
    CONSTRAINT "listings_assignment_status_check" CHECK (("assignment_status" = ANY (ARRAY['not_sent'::"text", 'sent'::"text", 'not_assigned'::"text", 'assigned'::"text"])))
);


ALTER TABLE "public"."listings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."real_estate_agents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "company_name" "text",
    "street_address" "text",
    "brokers_association" "text",
    "city" "text",
    "photo_url" "text",
    "notes" "text",
    "team_size" integer,
    "team_leader_id" "uuid",
    "buys_own_leads" boolean,
    "last_login_at" timestamp with time zone,
    "notification_preferences" "jsonb" DEFAULT '{"push": false, "email": true}'::"jsonb",
    "profile_id" "uuid",
    "portal_username" "text",
    "contact_email" "text",
    "role" "text" DEFAULT 'agent'::"text" NOT NULL,
    CONSTRAINT "no_self_team_leader" CHECK (("id" <> "team_leader_id")),
    CONSTRAINT "real_estate_agents_role_check" CHECK (("role" = ANY (ARRAY['agent'::"text", 'team_leader'::"text"])))
);


ALTER TABLE "public"."real_estate_agents" OWNER TO "postgres";


COMMENT ON TABLE "public"."real_estate_agents" IS 'Stores real estate agent information including team hierarchy and contact details';



COMMENT ON COLUMN "public"."real_estate_agents"."city" IS 'City where the agent office is located';



COMMENT ON COLUMN "public"."real_estate_agents"."team_leader_id" IS 'References the agent who is the team leader for this agent';



COMMENT ON COLUMN "public"."real_estate_agents"."buys_own_leads" IS 'True if agent purchases leads themselves, false if team leader purchases for them';



CREATE TABLE IF NOT EXISTS "public"."scheduled_calls" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "listing_id" "text" NOT NULL,
    "source_table_name" "text" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "scheduled_date" timestamp with time zone NOT NULL,
    "admin_notes" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "call_time_type" "text" DEFAULT 'fixed_time'::"text",
    "call_time_fixed" time without time zone,
    "call_time_range_start" time without time zone,
    "call_time_range_end" time without time zone,
    "completion_notes" "text",
    "reschedule_reason" "text",
    "reschedule_count" integer DEFAULT 0,
    "is_overdue" boolean DEFAULT false,
    "overdue_notified_at" timestamp with time zone,
    "calendar_event_id" "text",
    "reminder_minutes_before" integer DEFAULT 30,
    "call_type" "text" DEFAULT 'specific_time'::"text",
    "scheduled_date_end" timestamp with time zone,
    CONSTRAINT "scheduled_calls_call_time_type_check" CHECK (("call_time_type" = ANY (ARRAY['fixed_time'::"text", 'time_range'::"text"]))),
    CONSTRAINT "scheduled_calls_call_type_check" CHECK (("call_type" = ANY (ARRAY['specific_time'::"text", 'time_range'::"text"]))),
    CONSTRAINT "scheduled_calls_time_range_check" CHECK (((("call_type" = 'specific_time'::"text") AND ("scheduled_date_end" IS NULL)) OR (("call_type" = 'time_range'::"text") AND ("scheduled_date_end" IS NOT NULL) AND ("scheduled_date_end" > "scheduled_date")))),
    CONSTRAINT "scheduled_calls_valid_time_range" CHECK ((("call_time_type" = 'fixed_time'::"text") OR (("call_time_range_start" IS NOT NULL) AND ("call_time_range_end" IS NOT NULL) AND ("call_time_range_start" < "call_time_range_end"))))
);


ALTER TABLE "public"."scheduled_calls" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."agent_calendar_events" WITH ("security_invoker"='true') AS
 WITH "calls_with_agent" AS (
         SELECT "c"."id",
            "c"."lead_id",
            "c"."agent_id",
            "c"."outcome",
            "c"."notes",
            "c"."created_at",
            "c"."updated_at",
            "c"."updated_by",
            "c"."deleted_at",
            "c"."deleted_by",
            COALESCE("c"."agent_id", "l"."assigned_agent_id") AS "event_agent_id",
            COALESCE("public"."get_listing_internal_id"("src"."source_table_name", ("c"."lead_id")::"text"), "public"."get_listing_internal_id"('listings'::"text", ("c"."lead_id")::"text"), "l"."external_id", ("c"."lead_id")::"text") AS "lead_internal_id",
            COALESCE("src"."source_table_name", 'listings'::"text") AS "source_table_name"
           FROM (("public"."calls" "c"
             LEFT JOIN "public"."listings" "l" ON (("l"."id" = "c"."lead_id")))
             LEFT JOIN LATERAL ( SELECT "la"."source_table_name"
                   FROM "public"."lead_actions" "la"
                  WHERE (("la"."listing_id" = "c"."lead_id") AND ("la"."source_table_name" IS NOT NULL))
                  ORDER BY "la"."updated_at" DESC NULLS LAST, "la"."created_at" DESC NULLS LAST
                 LIMIT 1) "src" ON (true))
          WHERE ("c"."deleted_at" IS NULL)
        ), "first_calls" AS (
         SELECT "c"."id",
            "c"."lead_id",
            "c"."agent_id",
            "c"."outcome",
            "c"."notes",
            "c"."created_at",
            "c"."updated_at",
            "c"."updated_by",
            "c"."deleted_at",
            "c"."deleted_by",
            "c"."event_agent_id",
            "c"."lead_internal_id",
            "c"."source_table_name",
            "row_number"() OVER (PARTITION BY "c"."lead_id", "c"."event_agent_id" ORDER BY "c"."created_at") AS "rn"
           FROM "calls_with_agent" "c"
        )
 SELECT "concat"('first_call_', "fc"."id") AS "id",
    "fc"."event_agent_id" AS "agent_id",
    "fc"."lead_id",
    "fc"."source_table_name",
    'first_call'::"text" AS "type",
    "fc"."created_at" AS "start_time",
    NULL::timestamp with time zone AS "end_time",
    'First call'::"text" AS "title",
    "jsonb_strip_nulls"("jsonb_build_object"('call_id', "fc"."id", 'outcome', "fc"."outcome", 'notes', "fc"."notes", 'internal_id', "fc"."lead_internal_id", 'source_table_name', "fc"."source_table_name")) AS "meta",
    false AS "is_overdue"
   FROM "first_calls" "fc"
  WHERE ("fc"."rn" = 1)
UNION ALL
 SELECT "concat"('callback_', "na"."id") AS "id",
    "c"."event_agent_id" AS "agent_id",
    "c"."lead_id",
    "c"."source_table_name",
    'callback'::"text" AS "type",
    COALESCE("na"."scheduled_for", "na"."created_at") AS "start_time",
    NULL::timestamp with time zone AS "end_time",
    'Callback scheduled'::"text" AS "title",
    "jsonb_strip_nulls"("jsonb_build_object"('call_id', "na"."call_id", 'action', "na"."action", 'callback_preset', "na"."callback_preset", 'scheduled_for', "na"."scheduled_for", 'notes', "na"."notes", 'internal_id', "c"."lead_internal_id", 'source_table_name', "c"."source_table_name")) AS "meta",
        CASE
            WHEN (COALESCE("na"."scheduled_for", "na"."created_at") < "now"()) THEN true
            ELSE false
        END AS "is_overdue"
   FROM ("public"."call_next_actions" "na"
     JOIN "calls_with_agent" "c" ON (("c"."id" = "na"."call_id")))
  WHERE (("na"."deleted_at" IS NULL) AND ("na"."action" = 'schedule_callback'::"public"."next_action_type"))
UNION ALL
 SELECT "concat"('appointment_', "na"."id") AS "id",
    "c"."event_agent_id" AS "agent_id",
    "c"."lead_id",
    "c"."source_table_name",
    'appointment'::"text" AS "type",
    COALESCE("na"."scheduled_for", "na"."created_at") AS "start_time",
    NULL::timestamp with time zone AS "end_time",
    'Appointment'::"text" AS "title",
    "jsonb_strip_nulls"("jsonb_build_object"('call_id', "na"."call_id", 'action', "na"."action", 'scheduled_for', "na"."scheduled_for", 'notes', "na"."notes", 'internal_id', "c"."lead_internal_id", 'source_table_name', "c"."source_table_name")) AS "meta",
        CASE
            WHEN (COALESCE("na"."scheduled_for", "na"."created_at") < "now"()) THEN true
            ELSE false
        END AS "is_overdue"
   FROM ("public"."call_next_actions" "na"
     JOIN "calls_with_agent" "c" ON (("c"."id" = "na"."call_id")))
  WHERE (("na"."deleted_at" IS NULL) AND ("na"."action" = 'appointment'::"public"."next_action_type"))
UNION ALL
 SELECT "concat"('scheduled_call_', "sc"."id") AS "id",
    "ra"."profile_id" AS "agent_id",
        CASE
            WHEN ("sc"."listing_id" ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::"text") THEN ("sc"."listing_id")::"uuid"
            ELSE NULL::"uuid"
        END AS "lead_id",
    "sc"."source_table_name",
    'scheduled_call'::"text" AS "type",
    "sc"."scheduled_date" AS "start_time",
    "sc"."scheduled_date_end" AS "end_time",
    'Scheduled call'::"text" AS "title",
    "jsonb_strip_nulls"("jsonb_build_object"('internal_id', "public"."get_listing_internal_id"("sc"."source_table_name", "sc"."listing_id"), 'source_table_name', "sc"."source_table_name", 'status', "sc"."status", 'admin_notes', "sc"."admin_notes", 'call_time_type', "sc"."call_time_type", 'call_time_fixed', "sc"."call_time_fixed", 'call_time_range_start', "sc"."call_time_range_start", 'call_time_range_end', "sc"."call_time_range_end")) AS "meta",
        CASE
            WHEN (COALESCE("sc"."status", 'pending'::"text") = ANY (ARRAY['completed'::"text", 'cancelled'::"text"])) THEN false
            WHEN ("sc"."scheduled_date" < "now"()) THEN true
            ELSE false
        END AS "is_overdue"
   FROM ("public"."scheduled_calls" "sc"
     LEFT JOIN "public"."real_estate_agents" "ra" ON (("ra"."id" = "sc"."agent_id")));


ALTER VIEW "public"."agent_calendar_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_listing_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "listing_id" "text" NOT NULL,
    "source_table_name" "text" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agent_listing_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "listing_id" "uuid" NOT NULL,
    "source_table_name" "text" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "note_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agent_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "is_read" boolean DEFAULT false,
    "related_listing_id" "uuid",
    "related_source_table" "text",
    "related_internal_id" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "agent_notifications_type_check" CHECK (("type" = ANY (ARRAY['replacement_approved'::"text", 'replacement_denied'::"text", 'new_lead_assigned'::"text", 'lead_unassigned'::"text", 'task_completed'::"text", 'system_message'::"text", 'upcoming_call'::"text", 'call_scheduled'::"text", 'call_reminder'::"text"])))
);


ALTER TABLE "public"."agent_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "subscription_data" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "endpoint" "text" NOT NULL,
    "p256dh" "text",
    "auth" "text",
    "expiration_time" bigint,
    "user_agent" "text",
    "platform" "text",
    "language" "text",
    "timezone" "text",
    "last_used_at" timestamp with time zone,
    "last_error" "text"
);


ALTER TABLE "public"."agent_push_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_regions_of_activity" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "property_type" "text" NOT NULL,
    "region_city" "text" NOT NULL,
    "radius_km" "text",
    "price_from" integer,
    "price_to" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "price_range_check" CHECK (((("price_from" IS NULL) OR ("price_from" >= 0)) AND (("price_to" IS NULL) OR ("price_to" >= 0)) AND (("price_from" IS NULL) OR ("price_to" IS NULL) OR ("price_from" <= "price_to"))))
);


ALTER TABLE "public"."agent_regions_of_activity" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_regions_of_activity" IS 'Stores flexible regions of activity for real estate agents including property types, locations, and price ranges';



COMMENT ON COLUMN "public"."agent_regions_of_activity"."property_type" IS 'Type of property the agent handles (e.g., houses, flats, apartment buildings, plots)';



COMMENT ON COLUMN "public"."agent_regions_of_activity"."region_city" IS 'The region or city where the agent operates';



COMMENT ON COLUMN "public"."agent_regions_of_activity"."radius_km" IS 'Optional radius in kilometers around the region_city';



COMMENT ON COLUMN "public"."agent_regions_of_activity"."price_from" IS 'Optional minimum price for properties in this region';



COMMENT ON COLUMN "public"."agent_regions_of_activity"."price_to" IS 'Optional maximum price for properties in this region';



CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" character varying(50) NOT NULL,
    "release_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "changelog_title" character varying(200),
    "changelog_items" "jsonb" DEFAULT '{"bug_fixes": [], "improvements": [], "new_features": []}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true,
    "force_update" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."app_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."archived_listings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "original_listing_id" "text" NOT NULL,
    "original_table_name" "text" NOT NULL,
    "job_id" "text",
    "external_id" "text",
    "internal_id" "text",
    "title" "text",
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "price" numeric,
    "area_sqm" numeric,
    "rooms" numeric,
    "bedrooms" integer,
    "bathrooms" integer,
    "city" "text",
    "ebay_url" "text",
    "images" "jsonb",
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'active'::"text",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "has_phone" boolean DEFAULT false,
    "phone" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" numeric,
    "year_built" integer,
    "floors" integer,
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "archived_at" timestamp with time zone DEFAULT "now"(),
    "archived_by" "uuid"
);


ALTER TABLE "public"."archived_listings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."baden_wuerttemberg" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."baden_wuerttemberg" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bayern" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."bayern" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."berlin" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."berlin" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."brandenburg" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."brandenburg" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bremen" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."bremen" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "category_name" "text" NOT NULL,
    "category_txt" "text" NOT NULL,
    "category_code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "category_name_de" "text",
    "provision" "text"
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "city_name" "text",
    "city_txt" "text" NOT NULL,
    "city_code" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "state" "text",
    "next_major_city" "text"
);


ALTER TABLE "public"."cities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."listing_interactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "listing_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "source_table_name" "text",
    "field_name" "text" NOT NULL,
    "interaction_type" "public"."interaction_type_enum" NOT NULL,
    "old_value" "text",
    "new_value" "text",
    "timestamp" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."listing_interactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."listing_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "listing_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "source_table_name" "text",
    "opened_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_at" timestamp with time zone,
    "browsing_duration_seconds" integer DEFAULT 0,
    "interaction_duration_seconds" integer DEFAULT 0,
    "total_duration_seconds" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."listing_sessions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."daily_activity_metrics" AS
 SELECT "date"("ls"."opened_at") AS "activity_date",
    "ls"."user_id",
    "count"(DISTINCT "ls"."listing_id") AS "leads_contacted",
    "count"(DISTINCT "ls"."id") AS "sessions_count",
    "sum"("ls"."total_duration_seconds") AS "total_time_seconds",
    "sum"("ls"."interaction_duration_seconds") AS "interaction_time_seconds",
    "sum"("ls"."browsing_duration_seconds") AS "browsing_time_seconds",
    "count"(DISTINCT "li"."id") AS "total_interactions"
   FROM ("public"."listing_sessions" "ls"
     LEFT JOIN "public"."listing_interactions" "li" ON (("li"."session_id" = "ls"."id")))
  WHERE ("ls"."closed_at" IS NOT NULL)
  GROUP BY ("date"("ls"."opened_at")), "ls"."user_id";


ALTER VIEW "public"."daily_activity_metrics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."error_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "error_message" "text" NOT NULL,
    "error_stack" "text",
    "error_type" "text" DEFAULT 'error'::"text",
    "component" "text",
    "page_url" "text",
    "user_agent" "text",
    "user_id" "uuid",
    "user_role" "text",
    "additional_context" "jsonb" DEFAULT '{}'::"jsonb",
    "is_resolved" boolean DEFAULT false,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "resolution_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "error_logs_error_type_check" CHECK (("error_type" = ANY (ARRAY['error'::"text", 'warning'::"text", 'fatal'::"text", 'unhandled_rejection'::"text"])))
);


ALTER TABLE "public"."error_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."error_logs" IS 'Centralized error logging for frontend error tracking';



CREATE TABLE IF NOT EXISTS "public"."hamburg" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."hamburg" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hessen" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."hessen" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_counter" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "current_block" integer DEFAULT 1 NOT NULL,
    "current_number" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."lead_counter" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_event_audits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "changed_by" "uuid",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "previous_record" "jsonb",
    "new_record" "jsonb",
    CONSTRAINT "lead_event_audits_action_check" CHECK (("action" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "public"."lead_event_audits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "source_table_name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "call_outcome_code" "text",
    "call_outcome_label" "text",
    "next_action" "text",
    "next_action_payload" "jsonb" DEFAULT '{}'::"jsonb",
    "notes" "text",
    "status_after" "text",
    "responsible_agent_id" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "updated_at" timestamp with time zone,
    "updated_by" "uuid",
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid",
    "reminder_sent_at" timestamp with time zone,
    "overdue_notified_at" timestamp with time zone,
    "audit_log" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."lead_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_generation_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "contract_start_date" "date" NOT NULL,
    "contract_end_date" "date" NOT NULL,
    "total_leads_needed" integer NOT NULL,
    "delivered_leads_count" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    "title" "text",
    CONSTRAINT "lead_generation_tasks_delivered_leads_count_check" CHECK (("delivered_leads_count" >= 0)),
    CONSTRAINT "lead_generation_tasks_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'completed'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "lead_generation_tasks_total_leads_needed_check" CHECK (("total_leads_needed" > 0))
);


ALTER TABLE "public"."lead_generation_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_replacement_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_lead_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "listing_id" "uuid" NOT NULL,
    "source_table_name" "text" NOT NULL,
    "lead_internal_id" "text",
    "reason" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "resolution_note" "text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "lead_replacement_requests_reason_check" CHECK (("char_length"(TRIM(BOTH FROM "reason")) >= 10)),
    CONSTRAINT "lead_replacement_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"])))
);


ALTER TABLE "public"."lead_replacement_requests" OWNER TO "postgres";


COMMENT ON TABLE "public"."lead_replacement_requests" IS 'Tracks formal requests from agents to replace assigned leads';



CREATE TABLE IF NOT EXISTS "public"."lead_status_changes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid",
    "status_from" "text",
    "status_to" "text" NOT NULL,
    "source_call_id" "uuid",
    "changed_by" "uuid",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text"
);


ALTER TABLE "public"."lead_status_changes" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."lead_timeline" WITH ("security_invoker"='true') AS
 SELECT "concat"('call_', "c"."id") AS "id",
    'call'::"text" AS "type",
    "c"."created_at" AS "timestamp",
    "c"."agent_id",
    "concat"('Call • ', "initcap"("replace"(("c"."outcome")::"text", '_'::"text", ' '::"text"))) AS "title",
    "c"."notes",
    "jsonb_strip_nulls"("jsonb_build_object"('call_id', "c"."id", 'outcome', "c"."outcome", 'next_action', "na"."action", 'callback_preset', "na"."callback_preset", 'scheduled_for', "na"."scheduled_for", 'next_action_id', "na"."id")) AS "meta",
    "c"."lead_id"
   FROM ("public"."calls" "c"
     LEFT JOIN LATERAL ( SELECT "na_1"."id",
            "na_1"."call_id",
            "na_1"."action",
            "na_1"."callback_preset",
            "na_1"."scheduled_for",
            "na_1"."notes",
            "na_1"."created_at",
            "na_1"."updated_at",
            "na_1"."updated_by",
            "na_1"."deleted_at",
            "na_1"."deleted_by"
           FROM "public"."call_next_actions" "na_1"
          WHERE (("na_1"."call_id" = "c"."id") AND ("na_1"."deleted_at" IS NULL))
          ORDER BY "na_1"."created_at" DESC
         LIMIT 1) "na" ON (true))
  WHERE ("c"."deleted_at" IS NULL)
UNION ALL
 SELECT "concat"('next_action_', "na"."id") AS "id",
    'next_action'::"text" AS "type",
    COALESCE("na"."scheduled_for", "na"."created_at") AS "timestamp",
    "c"."agent_id",
    "concat"('Next action • ', "initcap"("replace"(("na"."action")::"text", '_'::"text", ' '::"text"))) AS "title",
    "na"."notes",
    "jsonb_strip_nulls"("jsonb_build_object"('action', "na"."action", 'callback_preset', "na"."callback_preset", 'scheduled_for', "na"."scheduled_for", 'call_id', "na"."call_id")) AS "meta",
    "c"."lead_id"
   FROM ("public"."call_next_actions" "na"
     JOIN "public"."calls" "c" ON (("c"."id" = "na"."call_id")))
  WHERE (("na"."deleted_at" IS NULL) AND ("c"."deleted_at" IS NULL))
UNION ALL
 SELECT "concat"('status_change_', "lsc"."id") AS "id",
    'status_change'::"text" AS "type",
    "lsc"."changed_at" AS "timestamp",
    "lsc"."changed_by" AS "agent_id",
    "concat"('Status • ', "initcap"("replace"(COALESCE("lsc"."status_to", 'Updated'::"text"), '_'::"text", ' '::"text"))) AS "title",
    "lsc"."notes",
    "jsonb_strip_nulls"("jsonb_build_object"('status_from', "lsc"."status_from", 'status_to', "lsc"."status_to", 'source_call_id', "lsc"."source_call_id")) AS "meta",
    "lsc"."lead_id"
   FROM "public"."lead_status_changes" "lsc"
  WHERE ("lsc"."lead_id" IS NOT NULL)
UNION ALL
 SELECT "concat"('lead_', "l"."id") AS "id",
    'lead_created'::"text" AS "type",
    "l"."created_at" AS "timestamp",
    "l"."assigned_agent_id" AS "agent_id",
    'Lead created'::"text" AS "title",
    NULL::"text" AS "notes",
    "jsonb_strip_nulls"("jsonb_build_object"('lead_status', "l"."lead_status", 'city', "l"."city", 'external_id', "l"."external_id")) AS "meta",
    "l"."id" AS "lead_id"
   FROM "public"."listings" "l";


ALTER VIEW "public"."lead_timeline" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mecklenburg_vorpommern" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."mecklenburg_vorpommern" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."niedersachsen" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."niedersachsen" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nordrhein_westfalen" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."nordrhein_westfalen" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."overdue_calls" AS
 SELECT "sc"."id",
    "sc"."listing_id",
    "sc"."source_table_name",
    "sc"."agent_id",
    "sc"."scheduled_date",
    "sc"."admin_notes",
    "sc"."status",
    "sc"."created_by",
    "sc"."created_at",
    "sc"."updated_at",
    "sc"."call_time_type",
    "sc"."call_time_fixed",
    "sc"."call_time_range_start",
    "sc"."call_time_range_end",
    "sc"."completion_notes",
    "sc"."reschedule_reason",
    "sc"."reschedule_count",
    "sc"."is_overdue",
    "sc"."overdue_notified_at",
    "sc"."calendar_event_id",
    "sc"."reminder_minutes_before",
    "rea"."name" AS "agent_name",
    "rea"."company_name"
   FROM ("public"."scheduled_calls" "sc"
     JOIN "public"."real_estate_agents" "rea" ON (("sc"."agent_id" = "rea"."id")))
  WHERE (("sc"."status" = 'pending'::"text") AND ("sc"."is_overdue" = true))
  ORDER BY "sc"."scheduled_date";


ALTER VIEW "public"."overdue_calls" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "view_call_can_send_leads" boolean DEFAULT false NOT NULL,
    "view_call_allowed_agent_ids" "uuid"[],
    "view_call_can_see_all_leads" boolean DEFAULT false NOT NULL,
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'scrape'::"text", 'view_edit'::"text", 'view_call'::"text", 'agent'::"text", 'team_leader'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."profiles" IS 'User profiles with role-based access control.
Roles:
- admin: Full access including user management
- scrape: Can start scrapes and view all listings
- view_edit: Can view all listings and edit any fields (cannot scrape)
- view_call: Can view all listings and edit only call-related fields';



CREATE TABLE IF NOT EXISTS "public"."rheinland_pfalz" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."rheinland_pfalz" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."saarland" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."saarland" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sachsen" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."sachsen" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sachsen_anhalt" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."sachsen_anhalt" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."schleswig_holstein" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."schleswig_holstein" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scrape_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "search_type" "text",
    "search_query" "text",
    "category" "text",
    "city" "text",
    "radius_km" "text" DEFAULT 50,
    "anbieter" "text" DEFAULT 'all'::"text",
    "provision" "text" DEFAULT 'any'::"text",
    "price_min" integer,
    "price_max" integer,
    "assigned_to" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "total_found" integer DEFAULT 0,
    "new_listings" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone,
    "url_slug" "text",
    "results_count" integer DEFAULT 50,
    "results_table_name" "text",
    "city_name" "text",
    "city_txt" "text",
    "city_code" "text",
    "category_name" "text",
    "category_txt" "text",
    "category_code" "text",
    "price_txt" "text",
    "price_from" integer,
    "price_to" integer,
    "search_txt" "text",
    "search_code" "text",
    "created_by" "uuid",
    "state" "text",
    "next_major_city" "text",
    "scrape_from" "date",
    "scrape_to" "date",
    "url" "text",
    "single_scrape" boolean DEFAULT false,
    "hide_from_ui" boolean DEFAULT false,
    "phone_override" "text",
    "scrape_notes" "text",
    "owner_title" "text",
    "owner_name" "text",
    "owner_name_approved" boolean DEFAULT false,
    "is_urgent" boolean DEFAULT false,
    "email" "text",
    "scraper_task_id" "uuid"
);


ALTER TABLE "public"."scrape_jobs" OWNER TO "postgres";


COMMENT ON TABLE "public"."scrape_jobs" IS 'Scrape jobs table. The created_by column tracks who created the job for audit purposes, but does not restrict visibility.';



COMMENT ON COLUMN "public"."scrape_jobs"."assigned_to" IS 'Deprecated: Use assigned_to in listings table instead';



COMMENT ON COLUMN "public"."scrape_jobs"."total_found" IS 'Calculated field: Can be computed by counting results in dynamic tables';



COMMENT ON COLUMN "public"."scrape_jobs"."new_listings" IS 'Calculated field: Can be computed by counting new results in dynamic tables';



COMMENT ON COLUMN "public"."scrape_jobs"."created_by" IS 'User who initiated the scrape job (single and bulk scrapes).';



COMMENT ON COLUMN "public"."scrape_jobs"."hide_from_ui" IS 'When true, hides the scrape job from loading screen and scrapes page. Used for single URL scrapes that run in background.';



COMMENT ON COLUMN "public"."scrape_jobs"."phone_override" IS 'Phone number override for single scrapes. This value will be automatically applied to single_scrapes records when they are created.';



COMMENT ON COLUMN "public"."scrape_jobs"."scrape_notes" IS 'Admin-only notes about the scrape. Copied to single_scrapes table when processing single URL scrapes.';



COMMENT ON COLUMN "public"."scrape_jobs"."owner_title" IS 'Optional owner/seller title provided when creating a single URL scrape.';



COMMENT ON COLUMN "public"."scrape_jobs"."owner_name" IS 'Optional owner/seller name provided when creating a single URL scrape.';



COMMENT ON COLUMN "public"."scrape_jobs"."owner_name_approved" IS 'Whether the owner name was pre-approved when the single scrape job was created.';



COMMENT ON COLUMN "public"."scrape_jobs"."is_urgent" IS 'Whether the single scrape lead should be treated as urgent.';



COMMENT ON COLUMN "public"."scrape_jobs"."email" IS 'Optional contact email for single URL scrapes.';



CREATE TABLE IF NOT EXISTS "public"."scrape_progress" (
    "scrape_job_id" "uuid" NOT NULL,
    "progress_20_complete" boolean DEFAULT false NOT NULL,
    "progress_20_text" "text",
    "progress_45_complete" boolean DEFAULT false NOT NULL,
    "progress_45_text" "text",
    "progress_70_complete" boolean DEFAULT false NOT NULL,
    "progress_70_text" "text",
    "progress_100_complete" boolean DEFAULT false NOT NULL,
    "progress_100_text" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "has_error" boolean DEFAULT false NOT NULL,
    "error_message" "text"
);


ALTER TABLE "public"."scrape_progress" OWNER TO "postgres";


COMMENT ON TABLE "public"."scrape_progress" IS 'Tracks milestone-based progress for scraping operations at 20%, 45%, 70%, and 100% completion stages';



COMMENT ON COLUMN "public"."scrape_progress"."scrape_job_id" IS 'Foreign key reference to the scrape_jobs table';



COMMENT ON COLUMN "public"."scrape_progress"."progress_20_complete" IS 'Indicates if 20% progress milestone has been reached';



COMMENT ON COLUMN "public"."scrape_progress"."progress_20_text" IS 'Custom status message to display at 20% milestone';



COMMENT ON COLUMN "public"."scrape_progress"."progress_45_complete" IS 'Indicates if 45% progress milestone has been reached';



COMMENT ON COLUMN "public"."scrape_progress"."progress_45_text" IS 'Custom status message to display at 45% milestone';



COMMENT ON COLUMN "public"."scrape_progress"."progress_70_complete" IS 'Indicates if 70% progress milestone has been reached';



COMMENT ON COLUMN "public"."scrape_progress"."progress_70_text" IS 'Custom status message to display at 70% milestone';



COMMENT ON COLUMN "public"."scrape_progress"."progress_100_complete" IS 'Indicates if 100% progress milestone has been reached';



COMMENT ON COLUMN "public"."scrape_progress"."progress_100_text" IS 'Custom status message to display at 100% milestone';



COMMENT ON COLUMN "public"."scrape_progress"."has_error" IS 'Indicates if an error occurred during the scraping process';



COMMENT ON COLUMN "public"."scrape_progress"."error_message" IS 'Detailed error message when has_error is true';



CREATE TABLE IF NOT EXISTS "public"."scrape_real_estate_berlin_120_1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" DEFAULT 'cf8b3849-c49b-43d6-b17d-e474d2ab802a'::"uuid",
    "internal_id" "text",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "state" "text",
    "nearest_major_city" "text",
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "call_date" "date",
    "agent_status" "text",
    "is_new_for_agent" boolean DEFAULT true,
    "agent_viewed_at" timestamp with time zone,
    "call_completed" boolean DEFAULT false,
    "call_completed_at" timestamp with time zone,
    "email" "text",
    "lead_status" "text" DEFAULT 'New'::"text",
    "status_overridden" boolean DEFAULT false,
    "status_override_reason" "text",
    "status_overridden_by" "uuid",
    "status_overridden_at" timestamp with time zone,
    "status_override_locked" boolean DEFAULT false
);


ALTER TABLE "public"."scrape_real_estate_berlin_120_1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scrape_real_estate_berlin_30_2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" DEFAULT '5a0894e3-fd77-443f-b335-ab5e53824796'::"uuid",
    "internal_id" "text",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "state" "text",
    "nearest_major_city" "text",
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "call_date" "date",
    "agent_status" "text",
    "is_new_for_agent" boolean DEFAULT true,
    "agent_viewed_at" timestamp with time zone,
    "call_completed" boolean DEFAULT false,
    "call_completed_at" timestamp with time zone,
    "email" "text",
    "lead_status" "text" DEFAULT 'New'::"text",
    "status_overridden" boolean DEFAULT false,
    "status_override_reason" "text",
    "status_overridden_by" "uuid",
    "status_overridden_at" timestamp with time zone,
    "status_override_locked" boolean DEFAULT false
);


ALTER TABLE "public"."scrape_real_estate_berlin_30_2" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" DEFAULT '41788009-6d94-428d-b6c1-9f5c1cccc3e8'::"uuid",
    "internal_id" "text",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "state" "text",
    "nearest_major_city" "text",
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "call_date" "date",
    "agent_status" "text",
    "is_new_for_agent" boolean DEFAULT true,
    "agent_viewed_at" timestamp with time zone,
    "call_completed" boolean DEFAULT false,
    "call_completed_at" timestamp with time zone,
    "email" "text",
    "lead_status" "text" DEFAULT 'New'::"text",
    "status_overridden" boolean DEFAULT false,
    "status_override_reason" "text",
    "status_overridden_by" "uuid",
    "status_overridden_at" timestamp with time zone,
    "status_override_locked" boolean DEFAULT false
);


ALTER TABLE "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."scrape_tables_registry" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "table_name" "text" NOT NULL,
    "job_id" "uuid",
    "total_listings" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."scrape_tables_registry" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."single_scrapes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "internal_id" "text",
    "external_id" "text",
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "state" "text",
    "nearest_major_city" "text",
    "area_sqm" integer,
    "rooms" numeric,
    "bedrooms" integer,
    "bathrooms" integer,
    "price" integer,
    "anbieter_name" "text",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "phone_override" "text",
    "fixed_phone" "text",
    "has_phone" boolean DEFAULT false,
    "email" "text",
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "views" integer DEFAULT 0,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "assigned_to" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "source_table_name" "text" DEFAULT 'single_scrapes'::"text",
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "translation_cache" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "agent_status" "text",
    "scrape_notes" "text",
    "call_date" "date",
    "call_completed" boolean DEFAULT false,
    "call_completed_at" timestamp with time zone,
    "is_new_for_agent" boolean DEFAULT true,
    "agent_viewed_at" timestamp with time zone,
    "is_urgent" boolean DEFAULT false,
    "lead_status" "text" DEFAULT 'New'::"text",
    "status_overridden" boolean DEFAULT false,
    "status_override_reason" "text",
    "status_overridden_by" "uuid",
    "status_overridden_at" timestamp with time zone,
    "status_override_locked" boolean DEFAULT false
);


ALTER TABLE "public"."single_scrapes" OWNER TO "postgres";


COMMENT ON TABLE "public"."single_scrapes" IS 'Stores listings scraped from single URLs via Make.com integration. Uses global lead_counter for internal_id numbering (A1.01, A2.05, etc.)';



COMMENT ON COLUMN "public"."single_scrapes"."internal_id" IS 'Global sequential ID from lead_counter (format: A1.01, A1.02, etc.)';



COMMENT ON COLUMN "public"."single_scrapes"."external_id" IS 'External listing ID (e.g., eBay Kleinanzeigen ID). UNIQUE for upsert support.';



COMMENT ON COLUMN "public"."single_scrapes"."phone_override" IS 'Phone number override from scrape job, takes priority over scraped phone';



COMMENT ON COLUMN "public"."single_scrapes"."fixed_phone" IS 'Manually corrected phone number, takes priority over phone_override and phone';



COMMENT ON COLUMN "public"."single_scrapes"."assignment_status" IS 'Status: not_sent, sent, qualified, disqualified';



COMMENT ON COLUMN "public"."single_scrapes"."source_table_name" IS 'Always "single_scrapes" - used to track which table the listing came from';



COMMENT ON COLUMN "public"."single_scrapes"."agent_status" IS 'Agent progress status: called_not_reached, viewing_scheduled, broker_contract, follow_up, rejection';



COMMENT ON COLUMN "public"."single_scrapes"."scrape_notes" IS 'Admin-only notes about the scrape. Not visible to agents. Only shown in UI if populated.';



COMMENT ON COLUMN "public"."single_scrapes"."is_urgent" IS 'Marks a single scrape lead as urgent for prioritization.';



CREATE TABLE IF NOT EXISTS "public"."table_counter" (
    "id" integer DEFAULT 1 NOT NULL,
    "current_number" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "single_row_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."table_counter" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_lead_pricing_blocks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "leads_count" integer NOT NULL,
    "price_per_lead" numeric(10,2) NOT NULL,
    "block_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "task_lead_pricing_blocks_leads_count_check" CHECK (("leads_count" > 0)),
    CONSTRAINT "task_lead_pricing_blocks_price_per_lead_check" CHECK (("price_per_lead" >= (0)::numeric))
);


ALTER TABLE "public"."task_lead_pricing_blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "listing_id" "uuid" NOT NULL,
    "source_table_name" "text" NOT NULL,
    "assigned_at" timestamp with time zone DEFAULT "now"(),
    "assigned_by" "uuid"
);


ALTER TABLE "public"."task_leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_regions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "region_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."task_regions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."thueringen" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "source_table_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "internal_id" "text",
    "state" "text",
    "nearest_major_city" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text"
);


ALTER TABLE "public"."thueringen" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."url_scrape" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "internal_id" "text",
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "title_de" "text",
    "description" "text",
    "description_de" "text",
    "city" "text" NOT NULL,
    "state" "text",
    "nearest_major_city" "text",
    "area_sqm" integer,
    "rooms" numeric,
    "price" integer,
    "images" "jsonb" DEFAULT '[]'::"jsonb",
    "anbieter_type" "text",
    "anbieter_type_de" "text",
    "provision" "text",
    "provision_de" "text",
    "phone" "text",
    "phone_override" "text",
    "has_phone" boolean DEFAULT false,
    "status" "text" DEFAULT 'active'::"text",
    "is_new" boolean DEFAULT true,
    "ebay_url" "text" NOT NULL,
    "added_on_platform" timestamp with time zone,
    "scraped_at" timestamp with time zone DEFAULT "now"(),
    "assigned_to" "text",
    "views" integer,
    "seller_name" "text",
    "plot_area" integer,
    "year_built" integer,
    "floors" integer,
    "bedrooms" integer,
    "bathrooms" integer,
    "call_status" "text" DEFAULT 'not_called'::"text",
    "lead_rating" "text",
    "notes_from_call" "text",
    "notes_general" "text",
    "rejection_reason" "text",
    "assigned_agent_id" "uuid",
    "assignment_status" "text" DEFAULT 'not_sent'::"text",
    "source_table_name" "text",
    "translation_cache" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."url_scrape" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."user_performance_summary" AS
 SELECT "u"."id" AS "user_id",
    "u"."email" AS "user_email",
    "p"."username" AS "user_name",
    "count"(DISTINCT "ls"."listing_id") AS "total_leads_contacted",
    "sum"("ls"."total_duration_seconds") AS "total_time_seconds",
    "sum"("ls"."interaction_duration_seconds") AS "total_interaction_seconds",
    "sum"("ls"."browsing_duration_seconds") AS "total_browsing_seconds",
    "avg"("ls"."total_duration_seconds") AS "avg_time_per_lead_seconds",
    "count"(DISTINCT "ls"."id") AS "total_sessions"
   FROM (("auth"."users" "u"
     LEFT JOIN "public"."profiles" "p" ON (("p"."id" = "u"."id")))
     LEFT JOIN "public"."listing_sessions" "ls" ON ((("ls"."user_id" = "u"."id") AND ("ls"."closed_at" IS NOT NULL))))
  GROUP BY "u"."id", "u"."email", "p"."username";


ALTER VIEW "public"."user_performance_summary" OWNER TO "postgres";


ALTER TABLE ONLY "public"."agent_listing_notes"
    ADD CONSTRAINT "agent_listing_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_notes"
    ADD CONSTRAINT "agent_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_notifications"
    ADD CONSTRAINT "agent_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_push_subscriptions"
    ADD CONSTRAINT "agent_push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_regions_of_activity"
    ADD CONSTRAINT "agent_regions_of_activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."app_versions"
    ADD CONSTRAINT "app_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_versions"
    ADD CONSTRAINT "app_versions_version_key" UNIQUE ("version");



ALTER TABLE ONLY "public"."archived_listings"
    ADD CONSTRAINT "archived_listings_original_listing_id_original_table_name_key" UNIQUE ("original_listing_id", "original_table_name");



ALTER TABLE ONLY "public"."archived_listings"
    ADD CONSTRAINT "archived_listings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."baden_wuerttemberg"
    ADD CONSTRAINT "baden_wuerttemberg_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."baden_wuerttemberg"
    ADD CONSTRAINT "baden_wuerttemberg_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bayern"
    ADD CONSTRAINT "bayern_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."bayern"
    ADD CONSTRAINT "bayern_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."berlin"
    ADD CONSTRAINT "berlin_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."berlin"
    ADD CONSTRAINT "berlin_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."brandenburg"
    ADD CONSTRAINT "brandenburg_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."brandenburg"
    ADD CONSTRAINT "brandenburg_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bremen"
    ADD CONSTRAINT "bremen_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."bremen"
    ADD CONSTRAINT "bremen_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."call_next_actions"
    ADD CONSTRAINT "call_next_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_category_name_key" UNIQUE ("category_name");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_city_name_key" UNIQUE ("city_name");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."error_logs"
    ADD CONSTRAINT "error_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hamburg"
    ADD CONSTRAINT "hamburg_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."hamburg"
    ADD CONSTRAINT "hamburg_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hessen"
    ADD CONSTRAINT "hessen_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."hessen"
    ADD CONSTRAINT "hessen_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_actions"
    ADD CONSTRAINT "lead_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_counter"
    ADD CONSTRAINT "lead_counter_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_event_audits"
    ADD CONSTRAINT "lead_event_audits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_events"
    ADD CONSTRAINT "lead_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_generation_tasks"
    ADD CONSTRAINT "lead_generation_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_replacement_requests"
    ADD CONSTRAINT "lead_replacement_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lead_status_changes"
    ADD CONSTRAINT "lead_status_changes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."listing_interactions"
    ADD CONSTRAINT "listing_interactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."listing_sessions"
    ADD CONSTRAINT "listing_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_external_id_key" UNIQUE ("external_id");



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mecklenburg_vorpommern"
    ADD CONSTRAINT "mecklenburg_vorpommern_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."mecklenburg_vorpommern"
    ADD CONSTRAINT "mecklenburg_vorpommern_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."niedersachsen"
    ADD CONSTRAINT "niedersachsen_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."niedersachsen"
    ADD CONSTRAINT "niedersachsen_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nordrhein_westfalen"
    ADD CONSTRAINT "nordrhein_westfalen_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."nordrhein_westfalen"
    ADD CONSTRAINT "nordrhein_westfalen_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."real_estate_agents"
    ADD CONSTRAINT "real_estate_agents_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."real_estate_agents"
    ADD CONSTRAINT "real_estate_agents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rheinland_pfalz"
    ADD CONSTRAINT "rheinland_pfalz_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."rheinland_pfalz"
    ADD CONSTRAINT "rheinland_pfalz_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saarland"
    ADD CONSTRAINT "saarland_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."saarland"
    ADD CONSTRAINT "saarland_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sachsen_anhalt"
    ADD CONSTRAINT "sachsen_anhalt_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."sachsen_anhalt"
    ADD CONSTRAINT "sachsen_anhalt_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sachsen"
    ADD CONSTRAINT "sachsen_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."sachsen"
    ADD CONSTRAINT "sachsen_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scheduled_calls"
    ADD CONSTRAINT "scheduled_calls_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."schleswig_holstein"
    ADD CONSTRAINT "schleswig_holstein_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."schleswig_holstein"
    ADD CONSTRAINT "schleswig_holstein_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_jobs"
    ADD CONSTRAINT "scrape_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_progress"
    ADD CONSTRAINT "scrape_progress_pkey" PRIMARY KEY ("scrape_job_id");



ALTER TABLE ONLY "public"."scrape_real_estate_berlin_120_1"
    ADD CONSTRAINT "scrape_real_estate_berlin_120_1_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."scrape_real_estate_berlin_120_1"
    ADD CONSTRAINT "scrape_real_estate_berlin_120_1_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_real_estate_berlin_30_2"
    ADD CONSTRAINT "scrape_real_estate_berlin_30_2_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."scrape_real_estate_berlin_30_2"
    ADD CONSTRAINT "scrape_real_estate_berlin_30_2_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"
    ADD CONSTRAINT "scrape_real_estate_essen_fulerum_nordrhein_west_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"
    ADD CONSTRAINT "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_tables_registry"
    ADD CONSTRAINT "scrape_tables_registry_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scrape_tables_registry"
    ADD CONSTRAINT "scrape_tables_registry_table_name_key" UNIQUE ("table_name");



ALTER TABLE ONLY "public"."scraper_notifications"
    ADD CONSTRAINT "scraper_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scraper_tasks"
    ADD CONSTRAINT "scraper_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."single_scrapes"
    ADD CONSTRAINT "single_scrapes_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."single_scrapes"
    ADD CONSTRAINT "single_scrapes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."table_counter"
    ADD CONSTRAINT "table_counter_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_lead_pricing_blocks"
    ADD CONSTRAINT "task_lead_pricing_blocks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_leads"
    ADD CONSTRAINT "task_leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_leads"
    ADD CONSTRAINT "task_leads_task_id_listing_id_source_table_name_key" UNIQUE ("task_id", "listing_id", "source_table_name");



ALTER TABLE ONLY "public"."task_regions"
    ADD CONSTRAINT "task_regions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_regions"
    ADD CONSTRAINT "task_regions_task_id_region_id_key" UNIQUE ("task_id", "region_id");



ALTER TABLE ONLY "public"."thueringen"
    ADD CONSTRAINT "thueringen_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."thueringen"
    ADD CONSTRAINT "thueringen_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."url_scrape"
    ADD CONSTRAINT "url_scrape_external_id_key" UNIQUE ("external_id");



ALTER TABLE ONLY "public"."url_scrape"
    ADD CONSTRAINT "url_scrape_internal_id_key" UNIQUE ("internal_id");



ALTER TABLE ONLY "public"."url_scrape"
    ADD CONSTRAINT "url_scrape_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "cna_one_active_per_call" ON "public"."call_next_actions" USING "btree" ("call_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_agent_listing_notes_agent" ON "public"."agent_listing_notes" USING "btree" ("agent_id");



CREATE INDEX "idx_agent_listing_notes_listing" ON "public"."agent_listing_notes" USING "btree" ("listing_id", "source_table_name");



CREATE INDEX "idx_agent_notes_agent_id" ON "public"."agent_notes" USING "btree" ("agent_id");



CREATE INDEX "idx_agent_notes_composite" ON "public"."agent_notes" USING "btree" ("listing_id", "source_table_name", "agent_id");



CREATE INDEX "idx_agent_notes_listing_id" ON "public"."agent_notes" USING "btree" ("listing_id");



CREATE INDEX "idx_agent_notifications_agent_id" ON "public"."agent_notifications" USING "btree" ("agent_id");



CREATE INDEX "idx_agent_notifications_created_at" ON "public"."agent_notifications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_agent_notifications_is_read" ON "public"."agent_notifications" USING "btree" ("agent_id", "is_read");



CREATE INDEX "idx_agent_push_subscriptions_agent_id" ON "public"."agent_push_subscriptions" USING "btree" ("agent_id");



CREATE INDEX "idx_agent_regions_agent_id" ON "public"."agent_regions_of_activity" USING "btree" ("agent_id");



CREATE INDEX "idx_agent_regions_property_type" ON "public"."agent_regions_of_activity" USING "btree" ("property_type");



CREATE INDEX "idx_agent_regions_region_city" ON "public"."agent_regions_of_activity" USING "btree" ("region_city");



CREATE INDEX "idx_agents_city" ON "public"."real_estate_agents" USING "btree" ("city");



CREATE INDEX "idx_agents_team_leader" ON "public"."real_estate_agents" USING "btree" ("team_leader_id");



CREATE INDEX "idx_archived_listings_archived_by" ON "public"."archived_listings" USING "btree" ("archived_by");



COMMENT ON INDEX "public"."idx_archived_listings_archived_by" IS 'Index for foreign key archived_by to improve join performance';



CREATE INDEX "idx_baden_wuerttemberg_call_status" ON "public"."baden_wuerttemberg" USING "btree" ("call_status");



CREATE INDEX "idx_baden_wuerttemberg_city" ON "public"."baden_wuerttemberg" USING "btree" ("city");



CREATE INDEX "idx_baden_wuerttemberg_external_id" ON "public"."baden_wuerttemberg" USING "btree" ("external_id");



CREATE INDEX "idx_baden_wuerttemberg_internal_id" ON "public"."baden_wuerttemberg" USING "btree" ("internal_id");



CREATE INDEX "idx_baden_wuerttemberg_job_id" ON "public"."baden_wuerttemberg" USING "btree" ("job_id");



CREATE INDEX "idx_baden_wuerttemberg_lead_rating" ON "public"."baden_wuerttemberg" USING "btree" ("lead_rating");



CREATE INDEX "idx_baden_wuerttemberg_scraped_at" ON "public"."baden_wuerttemberg" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_baden_wuerttemberg_state" ON "public"."baden_wuerttemberg" USING "btree" ("state");



CREATE INDEX "idx_bayern_call_status" ON "public"."bayern" USING "btree" ("call_status");



CREATE INDEX "idx_bayern_city" ON "public"."bayern" USING "btree" ("city");



CREATE INDEX "idx_bayern_external_id" ON "public"."bayern" USING "btree" ("external_id");



CREATE INDEX "idx_bayern_internal_id" ON "public"."bayern" USING "btree" ("internal_id");



CREATE INDEX "idx_bayern_job_id" ON "public"."bayern" USING "btree" ("job_id");



CREATE INDEX "idx_bayern_lead_rating" ON "public"."bayern" USING "btree" ("lead_rating");



CREATE INDEX "idx_bayern_scraped_at" ON "public"."bayern" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_bayern_state" ON "public"."bayern" USING "btree" ("state");



CREATE INDEX "idx_berlin_call_status" ON "public"."berlin" USING "btree" ("call_status");



CREATE INDEX "idx_berlin_city" ON "public"."berlin" USING "btree" ("city");



CREATE INDEX "idx_berlin_external_id" ON "public"."berlin" USING "btree" ("external_id");



CREATE INDEX "idx_berlin_internal_id" ON "public"."berlin" USING "btree" ("internal_id");



CREATE INDEX "idx_berlin_job_id" ON "public"."berlin" USING "btree" ("job_id");



CREATE INDEX "idx_berlin_lead_rating" ON "public"."berlin" USING "btree" ("lead_rating");



CREATE INDEX "idx_berlin_scraped_at" ON "public"."berlin" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_berlin_state" ON "public"."berlin" USING "btree" ("state");



CREATE INDEX "idx_brandenburg_call_status" ON "public"."brandenburg" USING "btree" ("call_status");



CREATE INDEX "idx_brandenburg_city" ON "public"."brandenburg" USING "btree" ("city");



CREATE INDEX "idx_brandenburg_external_id" ON "public"."brandenburg" USING "btree" ("external_id");



CREATE INDEX "idx_brandenburg_internal_id" ON "public"."brandenburg" USING "btree" ("internal_id");



CREATE INDEX "idx_brandenburg_job_id" ON "public"."brandenburg" USING "btree" ("job_id");



CREATE INDEX "idx_brandenburg_lead_rating" ON "public"."brandenburg" USING "btree" ("lead_rating");



CREATE INDEX "idx_brandenburg_scraped_at" ON "public"."brandenburg" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_brandenburg_state" ON "public"."brandenburg" USING "btree" ("state");



CREATE INDEX "idx_bremen_call_status" ON "public"."bremen" USING "btree" ("call_status");



CREATE INDEX "idx_bremen_city" ON "public"."bremen" USING "btree" ("city");



CREATE INDEX "idx_bremen_external_id" ON "public"."bremen" USING "btree" ("external_id");



CREATE INDEX "idx_bremen_internal_id" ON "public"."bremen" USING "btree" ("internal_id");



CREATE INDEX "idx_bremen_job_id" ON "public"."bremen" USING "btree" ("job_id");



CREATE INDEX "idx_bremen_lead_rating" ON "public"."bremen" USING "btree" ("lead_rating");



CREATE INDEX "idx_bremen_scraped_at" ON "public"."bremen" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_bremen_state" ON "public"."bremen" USING "btree" ("state");



CREATE INDEX "idx_calls_created_at" ON "public"."calls" USING "btree" ("created_at");



CREATE INDEX "idx_calls_deleted_at" ON "public"."calls" USING "btree" ("deleted_at");



CREATE INDEX "idx_calls_lead" ON "public"."calls" USING "btree" ("lead_id");



CREATE INDEX "idx_categories_category_name" ON "public"."categories" USING "btree" ("category_name");



CREATE INDEX "idx_cities_city_name" ON "public"."cities" USING "btree" ("city_name");



CREATE INDEX "idx_cities_state" ON "public"."cities" USING "btree" ("state");



CREATE INDEX "idx_cna_call" ON "public"."call_next_actions" USING "btree" ("call_id");



CREATE INDEX "idx_cna_deleted_at" ON "public"."call_next_actions" USING "btree" ("deleted_at");



CREATE INDEX "idx_error_logs_created_at" ON "public"."error_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_error_logs_error_type" ON "public"."error_logs" USING "btree" ("error_type");



CREATE INDEX "idx_error_logs_is_resolved" ON "public"."error_logs" USING "btree" ("is_resolved");



CREATE INDEX "idx_error_logs_page_url" ON "public"."error_logs" USING "btree" ("page_url");



CREATE INDEX "idx_error_logs_user_id" ON "public"."error_logs" USING "btree" ("user_id");



CREATE INDEX "idx_hamburg_call_status" ON "public"."hamburg" USING "btree" ("call_status");



CREATE INDEX "idx_hamburg_city" ON "public"."hamburg" USING "btree" ("city");



CREATE INDEX "idx_hamburg_external_id" ON "public"."hamburg" USING "btree" ("external_id");



CREATE INDEX "idx_hamburg_internal_id" ON "public"."hamburg" USING "btree" ("internal_id");



CREATE INDEX "idx_hamburg_job_id" ON "public"."hamburg" USING "btree" ("job_id");



CREATE INDEX "idx_hamburg_lead_rating" ON "public"."hamburg" USING "btree" ("lead_rating");



CREATE INDEX "idx_hamburg_scraped_at" ON "public"."hamburg" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_hamburg_state" ON "public"."hamburg" USING "btree" ("state");



CREATE INDEX "idx_hessen_call_status" ON "public"."hessen" USING "btree" ("call_status");



CREATE INDEX "idx_hessen_city" ON "public"."hessen" USING "btree" ("city");



CREATE INDEX "idx_hessen_external_id" ON "public"."hessen" USING "btree" ("external_id");



CREATE INDEX "idx_hessen_internal_id" ON "public"."hessen" USING "btree" ("internal_id");



CREATE INDEX "idx_hessen_job_id" ON "public"."hessen" USING "btree" ("job_id");



CREATE INDEX "idx_hessen_lead_rating" ON "public"."hessen" USING "btree" ("lead_rating");



CREATE INDEX "idx_hessen_scraped_at" ON "public"."hessen" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_hessen_state" ON "public"."hessen" USING "btree" ("state");



CREATE INDEX "idx_lead_actions_listing_id" ON "public"."lead_actions" USING "btree" ("listing_id");



CREATE UNIQUE INDEX "idx_lead_actions_listing_source_unique" ON "public"."lead_actions" USING "btree" ("listing_id", "source_table_name");



CREATE INDEX "idx_lead_actions_scraper_task" ON "public"."lead_actions" USING "btree" ("scraper_task_id");



CREATE INDEX "idx_lead_actions_source_table_name" ON "public"."lead_actions" USING "btree" ("source_table_name");



CREATE INDEX "idx_lead_event_audits_event" ON "public"."lead_event_audits" USING "btree" ("event_id");



CREATE INDEX "idx_lead_events_created_by" ON "public"."lead_events" USING "btree" ("created_by");



CREATE INDEX "idx_lead_events_lead" ON "public"."lead_events" USING "btree" ("lead_id", "source_table_name");



CREATE INDEX "idx_lead_events_next_action" ON "public"."lead_events" USING "btree" ("next_action") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_lead_events_occurred" ON "public"."lead_events" USING "btree" ("occurred_at" DESC);



CREATE INDEX "idx_lead_generation_tasks_agent_id" ON "public"."lead_generation_tasks" USING "btree" ("agent_id");



CREATE INDEX "idx_lead_generation_tasks_created_at" ON "public"."lead_generation_tasks" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_lead_generation_tasks_created_by" ON "public"."lead_generation_tasks" USING "btree" ("created_by");



CREATE INDEX "idx_lead_generation_tasks_status" ON "public"."lead_generation_tasks" USING "btree" ("status");



CREATE INDEX "idx_lead_replacement_requests_agent_id" ON "public"."lead_replacement_requests" USING "btree" ("agent_id");



CREATE INDEX "idx_lead_replacement_requests_created_at" ON "public"."lead_replacement_requests" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_lead_replacement_requests_listing_id" ON "public"."lead_replacement_requests" USING "btree" ("listing_id", "source_table_name");



CREATE INDEX "idx_lead_replacement_requests_resolved_by" ON "public"."lead_replacement_requests" USING "btree" ("resolved_by");



CREATE INDEX "idx_lead_replacement_requests_status" ON "public"."lead_replacement_requests" USING "btree" ("status");



CREATE INDEX "idx_lead_replacement_requests_task_lead_id" ON "public"."lead_replacement_requests" USING "btree" ("task_lead_id");



CREATE UNIQUE INDEX "idx_lead_replacement_requests_unique_pending" ON "public"."lead_replacement_requests" USING "btree" ("task_lead_id") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_listing_interactions_session_id" ON "public"."listing_interactions" USING "btree" ("session_id");



CREATE INDEX "idx_listing_interactions_user_id" ON "public"."listing_interactions" USING "btree" ("user_id");



CREATE INDEX "idx_listing_sessions_closed_at" ON "public"."listing_sessions" USING "btree" ("closed_at" DESC);



CREATE INDEX "idx_listing_sessions_listing_id" ON "public"."listing_sessions" USING "btree" ("listing_id");



CREATE INDEX "idx_listing_sessions_opened_at" ON "public"."listing_sessions" USING "btree" ("opened_at" DESC);



CREATE INDEX "idx_listing_sessions_user_id" ON "public"."listing_sessions" USING "btree" ("user_id");



CREATE INDEX "idx_listing_sessions_user_opened" ON "public"."listing_sessions" USING "btree" ("user_id", "opened_at" DESC);



CREATE INDEX "idx_listings_agent_status" ON "public"."listings" USING "btree" ("agent_status") WHERE ("agent_status" IS NOT NULL);



CREATE INDEX "idx_listings_assigned_agent" ON "public"."listings" USING "btree" ("assigned_agent_id");



CREATE INDEX "idx_listings_assignment_status" ON "public"."listings" USING "btree" ("assignment_status");



CREATE INDEX "idx_listings_call_completed" ON "public"."listings" USING "btree" ("call_completed") WHERE ("call_completed" = true);



CREATE INDEX "idx_listings_call_completed_at" ON "public"."listings" USING "btree" ("call_completed_at") WHERE ("call_completed_at" IS NOT NULL);



CREATE INDEX "idx_listings_call_date" ON "public"."listings" USING "btree" ("call_date") WHERE ("call_date" IS NOT NULL);



CREATE INDEX "idx_listings_job_id" ON "public"."listings" USING "btree" ("job_id");



CREATE INDEX "idx_listings_scraped_at" ON "public"."listings" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_lsc_changed_at" ON "public"."lead_status_changes" USING "btree" ("changed_at");



CREATE INDEX "idx_lsc_lead" ON "public"."lead_status_changes" USING "btree" ("lead_id");



CREATE INDEX "idx_mecklenburg_vorpommern_call_status" ON "public"."mecklenburg_vorpommern" USING "btree" ("call_status");



CREATE INDEX "idx_mecklenburg_vorpommern_city" ON "public"."mecklenburg_vorpommern" USING "btree" ("city");



CREATE INDEX "idx_mecklenburg_vorpommern_external_id" ON "public"."mecklenburg_vorpommern" USING "btree" ("external_id");



CREATE INDEX "idx_mecklenburg_vorpommern_internal_id" ON "public"."mecklenburg_vorpommern" USING "btree" ("internal_id");



CREATE INDEX "idx_mecklenburg_vorpommern_job_id" ON "public"."mecklenburg_vorpommern" USING "btree" ("job_id");



CREATE INDEX "idx_mecklenburg_vorpommern_lead_rating" ON "public"."mecklenburg_vorpommern" USING "btree" ("lead_rating");



CREATE INDEX "idx_mecklenburg_vorpommern_scraped_at" ON "public"."mecklenburg_vorpommern" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_mecklenburg_vorpommern_state" ON "public"."mecklenburg_vorpommern" USING "btree" ("state");



CREATE INDEX "idx_niedersachsen_call_status" ON "public"."niedersachsen" USING "btree" ("call_status");



CREATE INDEX "idx_niedersachsen_city" ON "public"."niedersachsen" USING "btree" ("city");



CREATE INDEX "idx_niedersachsen_external_id" ON "public"."niedersachsen" USING "btree" ("external_id");



CREATE INDEX "idx_niedersachsen_internal_id" ON "public"."niedersachsen" USING "btree" ("internal_id");



CREATE INDEX "idx_niedersachsen_job_id" ON "public"."niedersachsen" USING "btree" ("job_id");



CREATE INDEX "idx_niedersachsen_lead_rating" ON "public"."niedersachsen" USING "btree" ("lead_rating");



CREATE INDEX "idx_niedersachsen_scraped_at" ON "public"."niedersachsen" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_niedersachsen_state" ON "public"."niedersachsen" USING "btree" ("state");



CREATE INDEX "idx_nordrhein_westfalen_call_status" ON "public"."nordrhein_westfalen" USING "btree" ("call_status");



CREATE INDEX "idx_nordrhein_westfalen_city" ON "public"."nordrhein_westfalen" USING "btree" ("city");



CREATE INDEX "idx_nordrhein_westfalen_external_id" ON "public"."nordrhein_westfalen" USING "btree" ("external_id");



CREATE INDEX "idx_nordrhein_westfalen_internal_id" ON "public"."nordrhein_westfalen" USING "btree" ("internal_id");



CREATE INDEX "idx_nordrhein_westfalen_job_id" ON "public"."nordrhein_westfalen" USING "btree" ("job_id");



CREATE INDEX "idx_nordrhein_westfalen_lead_rating" ON "public"."nordrhein_westfalen" USING "btree" ("lead_rating");



CREATE INDEX "idx_nordrhein_westfalen_scraped_at" ON "public"."nordrhein_westfalen" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_nordrhein_westfalen_state" ON "public"."nordrhein_westfalen" USING "btree" ("state");



CREATE INDEX "idx_real_estate_agents_contact_email" ON "public"."real_estate_agents" USING "btree" ("contact_email") WHERE ("contact_email" IS NOT NULL);



CREATE UNIQUE INDEX "idx_real_estate_agents_portal_username" ON "public"."real_estate_agents" USING "btree" ("portal_username") WHERE ("portal_username" IS NOT NULL);



CREATE UNIQUE INDEX "idx_real_estate_agents_profile_id" ON "public"."real_estate_agents" USING "btree" ("profile_id") WHERE ("profile_id" IS NOT NULL);



CREATE INDEX "idx_rheinland_pfalz_call_status" ON "public"."rheinland_pfalz" USING "btree" ("call_status");



CREATE INDEX "idx_rheinland_pfalz_city" ON "public"."rheinland_pfalz" USING "btree" ("city");



CREATE INDEX "idx_rheinland_pfalz_external_id" ON "public"."rheinland_pfalz" USING "btree" ("external_id");



CREATE INDEX "idx_rheinland_pfalz_internal_id" ON "public"."rheinland_pfalz" USING "btree" ("internal_id");



CREATE INDEX "idx_rheinland_pfalz_job_id" ON "public"."rheinland_pfalz" USING "btree" ("job_id");



CREATE INDEX "idx_rheinland_pfalz_lead_rating" ON "public"."rheinland_pfalz" USING "btree" ("lead_rating");



CREATE INDEX "idx_rheinland_pfalz_scraped_at" ON "public"."rheinland_pfalz" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_rheinland_pfalz_state" ON "public"."rheinland_pfalz" USING "btree" ("state");



CREATE INDEX "idx_saarland_call_status" ON "public"."saarland" USING "btree" ("call_status");



CREATE INDEX "idx_saarland_city" ON "public"."saarland" USING "btree" ("city");



CREATE INDEX "idx_saarland_external_id" ON "public"."saarland" USING "btree" ("external_id");



CREATE INDEX "idx_saarland_internal_id" ON "public"."saarland" USING "btree" ("internal_id");



CREATE INDEX "idx_saarland_job_id" ON "public"."saarland" USING "btree" ("job_id");



CREATE INDEX "idx_saarland_lead_rating" ON "public"."saarland" USING "btree" ("lead_rating");



CREATE INDEX "idx_saarland_scraped_at" ON "public"."saarland" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_saarland_state" ON "public"."saarland" USING "btree" ("state");



CREATE INDEX "idx_sachsen_anhalt_call_status" ON "public"."sachsen_anhalt" USING "btree" ("call_status");



CREATE INDEX "idx_sachsen_anhalt_city" ON "public"."sachsen_anhalt" USING "btree" ("city");



CREATE INDEX "idx_sachsen_anhalt_external_id" ON "public"."sachsen_anhalt" USING "btree" ("external_id");



CREATE INDEX "idx_sachsen_anhalt_internal_id" ON "public"."sachsen_anhalt" USING "btree" ("internal_id");



CREATE INDEX "idx_sachsen_anhalt_job_id" ON "public"."sachsen_anhalt" USING "btree" ("job_id");



CREATE INDEX "idx_sachsen_anhalt_lead_rating" ON "public"."sachsen_anhalt" USING "btree" ("lead_rating");



CREATE INDEX "idx_sachsen_anhalt_scraped_at" ON "public"."sachsen_anhalt" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_sachsen_anhalt_state" ON "public"."sachsen_anhalt" USING "btree" ("state");



CREATE INDEX "idx_sachsen_call_status" ON "public"."sachsen" USING "btree" ("call_status");



CREATE INDEX "idx_sachsen_city" ON "public"."sachsen" USING "btree" ("city");



CREATE INDEX "idx_sachsen_external_id" ON "public"."sachsen" USING "btree" ("external_id");



CREATE INDEX "idx_sachsen_internal_id" ON "public"."sachsen" USING "btree" ("internal_id");



CREATE INDEX "idx_sachsen_job_id" ON "public"."sachsen" USING "btree" ("job_id");



CREATE INDEX "idx_sachsen_lead_rating" ON "public"."sachsen" USING "btree" ("lead_rating");



CREATE INDEX "idx_sachsen_scraped_at" ON "public"."sachsen" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_sachsen_state" ON "public"."sachsen" USING "btree" ("state");



CREATE INDEX "idx_scheduled_calls_agent" ON "public"."scheduled_calls" USING "btree" ("agent_id");



CREATE INDEX "idx_scheduled_calls_agent_status" ON "public"."scheduled_calls" USING "btree" ("agent_id", "status", "scheduled_date");



CREATE INDEX "idx_scheduled_calls_call_type" ON "public"."scheduled_calls" USING "btree" ("call_type");



CREATE INDEX "idx_scheduled_calls_created_by" ON "public"."scheduled_calls" USING "btree" ("created_by");



CREATE INDEX "idx_scheduled_calls_date" ON "public"."scheduled_calls" USING "btree" ("scheduled_date");



CREATE INDEX "idx_scheduled_calls_listing" ON "public"."scheduled_calls" USING "btree" ("listing_id", "source_table_name");



CREATE INDEX "idx_scheduled_calls_overdue" ON "public"."scheduled_calls" USING "btree" ("is_overdue", "scheduled_date") WHERE (("is_overdue" = true) AND ("status" = 'pending'::"text"));



CREATE INDEX "idx_scheduled_calls_upcoming" ON "public"."scheduled_calls" USING "btree" ("scheduled_date", "call_time_fixed") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_schleswig_holstein_call_status" ON "public"."schleswig_holstein" USING "btree" ("call_status");



CREATE INDEX "idx_schleswig_holstein_city" ON "public"."schleswig_holstein" USING "btree" ("city");



CREATE INDEX "idx_schleswig_holstein_external_id" ON "public"."schleswig_holstein" USING "btree" ("external_id");



CREATE INDEX "idx_schleswig_holstein_internal_id" ON "public"."schleswig_holstein" USING "btree" ("internal_id");



CREATE INDEX "idx_schleswig_holstein_job_id" ON "public"."schleswig_holstein" USING "btree" ("job_id");



CREATE INDEX "idx_schleswig_holstein_lead_rating" ON "public"."schleswig_holstein" USING "btree" ("lead_rating");



CREATE INDEX "idx_schleswig_holstein_scraped_at" ON "public"."schleswig_holstein" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_schleswig_holstein_state" ON "public"."schleswig_holstein" USING "btree" ("state");



CREATE INDEX "idx_scrape_jobs_created_by" ON "public"."scrape_jobs" USING "btree" ("created_by");



CREATE INDEX "idx_scrape_jobs_hide_from_ui" ON "public"."scrape_jobs" USING "btree" ("hide_from_ui");



CREATE INDEX "idx_scrape_jobs_scraper_task" ON "public"."scrape_jobs" USING "btree" ("scraper_task_id");



CREATE INDEX "idx_scrape_progress_job_id" ON "public"."scrape_progress" USING "btree" ("scrape_job_id");



CREATE INDEX "idx_scrape_real_estate_berlin_120_1_job_id" ON "public"."scrape_real_estate_berlin_120_1" USING "btree" ("job_id");



CREATE INDEX "idx_scrape_real_estate_berlin_120_1_scraped_at" ON "public"."scrape_real_estate_berlin_120_1" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_scrape_real_estate_berlin_30_2_internal_id" ON "public"."scrape_real_estate_berlin_30_2" USING "btree" ("internal_id");



CREATE INDEX "idx_scrape_real_estate_berlin_30_2_job_id" ON "public"."scrape_real_estate_berlin_30_2" USING "btree" ("job_id");



CREATE INDEX "idx_scrape_real_estate_berlin_30_2_scraped_at" ON "public"."scrape_real_estate_berlin_30_2" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_scrape_real_estate_berlin_30_2_state" ON "public"."scrape_real_estate_berlin_30_2" USING "btree" ("state");



CREATE INDEX "idx_scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1_j" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" USING "btree" ("job_id");



CREATE INDEX "idx_scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1_s" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_scrape_tables_registry_created_at" ON "public"."scrape_tables_registry" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_scrape_tables_registry_job_id" ON "public"."scrape_tables_registry" USING "btree" ("job_id");



CREATE INDEX "idx_scraper_notifications_created" ON "public"."scraper_notifications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_scraper_notifications_scraper" ON "public"."scraper_notifications" USING "btree" ("scraper_id");



CREATE INDEX "idx_scraper_tasks_assigned" ON "public"."scraper_tasks" USING "btree" ("assigned_scraper_id");



CREATE INDEX "idx_scraper_tasks_created_at" ON "public"."scraper_tasks" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_scraper_tasks_status" ON "public"."scraper_tasks" USING "btree" ("status");



CREATE INDEX "idx_single_scrapes_agent_call_date" ON "public"."single_scrapes" USING "btree" ("assigned_agent_id", "call_date") WHERE ("assigned_agent_id" IS NOT NULL);



CREATE INDEX "idx_single_scrapes_assigned_agent_id" ON "public"."single_scrapes" USING "btree" ("assigned_agent_id");



CREATE INDEX "idx_single_scrapes_assignment_status" ON "public"."single_scrapes" USING "btree" ("assignment_status");



CREATE INDEX "idx_single_scrapes_call_date" ON "public"."single_scrapes" USING "btree" ("call_date");



CREATE INDEX "idx_single_scrapes_call_status" ON "public"."single_scrapes" USING "btree" ("call_status");



CREATE INDEX "idx_single_scrapes_city" ON "public"."single_scrapes" USING "btree" ("city");



CREATE INDEX "idx_single_scrapes_external_id" ON "public"."single_scrapes" USING "btree" ("external_id");



CREATE INDEX "idx_single_scrapes_internal_id" ON "public"."single_scrapes" USING "btree" ("internal_id");



CREATE INDEX "idx_single_scrapes_is_urgent" ON "public"."single_scrapes" USING "btree" ("is_urgent");



CREATE INDEX "idx_single_scrapes_job_id" ON "public"."single_scrapes" USING "btree" ("job_id");



CREATE INDEX "idx_single_scrapes_lead_rating" ON "public"."single_scrapes" USING "btree" ("lead_rating");



CREATE INDEX "idx_single_scrapes_new_for_agent" ON "public"."single_scrapes" USING "btree" ("assigned_agent_id", "is_new_for_agent") WHERE (("assigned_agent_id" IS NOT NULL) AND ("is_new_for_agent" = true));



CREATE INDEX "idx_single_scrapes_scrape_notes" ON "public"."single_scrapes" USING "btree" ("scrape_notes") WHERE ("scrape_notes" IS NOT NULL);



CREATE INDEX "idx_single_scrapes_scraped_at" ON "public"."single_scrapes" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_single_scrapes_state" ON "public"."single_scrapes" USING "btree" ("state");



CREATE INDEX "idx_task_lead_pricing_blocks_order" ON "public"."task_lead_pricing_blocks" USING "btree" ("task_id", "block_order");



CREATE INDEX "idx_task_lead_pricing_blocks_task_id" ON "public"."task_lead_pricing_blocks" USING "btree" ("task_id");



CREATE INDEX "idx_task_leads_assigned_by" ON "public"."task_leads" USING "btree" ("assigned_by");



CREATE INDEX "idx_task_leads_listing_id" ON "public"."task_leads" USING "btree" ("listing_id");



CREATE INDEX "idx_task_leads_task_id" ON "public"."task_leads" USING "btree" ("task_id");



CREATE INDEX "idx_task_regions_region_id" ON "public"."task_regions" USING "btree" ("region_id");



CREATE INDEX "idx_task_regions_task_id" ON "public"."task_regions" USING "btree" ("task_id");



CREATE INDEX "idx_thueringen_call_status" ON "public"."thueringen" USING "btree" ("call_status");



CREATE INDEX "idx_thueringen_city" ON "public"."thueringen" USING "btree" ("city");



CREATE INDEX "idx_thueringen_external_id" ON "public"."thueringen" USING "btree" ("external_id");



CREATE INDEX "idx_thueringen_internal_id" ON "public"."thueringen" USING "btree" ("internal_id");



CREATE INDEX "idx_thueringen_job_id" ON "public"."thueringen" USING "btree" ("job_id");



CREATE INDEX "idx_thueringen_lead_rating" ON "public"."thueringen" USING "btree" ("lead_rating");



CREATE INDEX "idx_thueringen_scraped_at" ON "public"."thueringen" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_thueringen_state" ON "public"."thueringen" USING "btree" ("state");



CREATE INDEX "idx_url_scrape_assigned_agent_id" ON "public"."url_scrape" USING "btree" ("assigned_agent_id");



CREATE INDEX "idx_url_scrape_assignment_status" ON "public"."url_scrape" USING "btree" ("assignment_status");



CREATE INDEX "idx_url_scrape_call_status" ON "public"."url_scrape" USING "btree" ("call_status");



CREATE INDEX "idx_url_scrape_external_id" ON "public"."url_scrape" USING "btree" ("external_id");



CREATE INDEX "idx_url_scrape_internal_id" ON "public"."url_scrape" USING "btree" ("internal_id");



CREATE INDEX "idx_url_scrape_job_id" ON "public"."url_scrape" USING "btree" ("job_id");



CREATE INDEX "idx_url_scrape_lead_rating" ON "public"."url_scrape" USING "btree" ("lead_rating");



CREATE INDEX "idx_url_scrape_scraped_at" ON "public"."url_scrape" USING "btree" ("scraped_at" DESC);



CREATE INDEX "idx_url_scrape_state" ON "public"."url_scrape" USING "btree" ("state");



CREATE UNIQUE INDEX "lead_actions_listing_id_source_table_key" ON "public"."lead_actions" USING "btree" ("listing_id", "source_table_name") WHERE ("source_table_name" IS NOT NULL);



CREATE UNIQUE INDEX "uq_agent_push_subscriptions_endpoint" ON "public"."agent_push_subscriptions" USING "btree" ("endpoint");



CREATE OR REPLACE TRIGGER "aa_auto_populate_job_id_trigger" BEFORE INSERT OR UPDATE ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."auto_populate_single_scrape_job_id"();



CREATE OR REPLACE TRIGGER "agent_listing_notes_updated_at" BEFORE UPDATE ON "public"."agent_listing_notes" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_notes_updated_at"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."baden_wuerttemberg" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_baden_wuerttemberg"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."bayern" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_bayern"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."berlin" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_berlin"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."brandenburg" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_brandenburg"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."bremen" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_bremen"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."hamburg" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_hamburg"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."hessen" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_hessen"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."mecklenburg_vorpommern" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_mecklenburg_vorpommern"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."niedersachsen" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_niedersachsen"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."nordrhein_westfalen" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_nordrhein_westfalen"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."rheinland_pfalz" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_rheinland_pfalz"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."saarland" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_saarland"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."sachsen" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_sachsen"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."sachsen_anhalt" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_sachsen_anhalt"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."schleswig_holstein" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_schleswig_holstein"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."scrape_real_estate_berlin_120_1" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_120_1"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."scrape_real_estate_berlin_30_2" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_30_2"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_scrape_real_estate_essen_fulerum_nordrhein"();



CREATE OR REPLACE TRIGGER "auto_assign_internal_id" BEFORE INSERT ON "public"."thueringen" FOR EACH ROW EXECUTE FUNCTION "public"."trg_func_internal_id_thueringen"();



CREATE OR REPLACE TRIGGER "auto_complete_task_trigger" BEFORE UPDATE ON "public"."lead_generation_tasks" FOR EACH ROW WHEN (("new"."delivered_leads_count" IS DISTINCT FROM "old"."delivered_leads_count")) EXECUTE FUNCTION "public"."auto_complete_task"();



CREATE OR REPLACE TRIGGER "populate_assigned_agent_trigger" BEFORE INSERT OR UPDATE ON "public"."scrape_real_estate_berlin_120_1" FOR EACH ROW EXECUTE FUNCTION "public"."populate_assigned_agent_from_job"();



CREATE OR REPLACE TRIGGER "populate_assigned_agent_trigger" BEFORE INSERT OR UPDATE ON "public"."scrape_real_estate_berlin_30_2" FOR EACH ROW EXECUTE FUNCTION "public"."populate_assigned_agent_from_job"();



CREATE OR REPLACE TRIGGER "populate_assigned_agent_trigger" BEFORE INSERT OR UPDATE ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR EACH ROW EXECUTE FUNCTION "public"."populate_assigned_agent_from_job"();



CREATE OR REPLACE TRIGGER "populate_assigned_to_trigger" BEFORE INSERT OR UPDATE ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."populate_assigned_to_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."baden_wuerttemberg" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."bayern" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."berlin" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."brandenburg" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."bremen" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."hamburg" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."hessen" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."mecklenburg_vorpommern" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."niedersachsen" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."nordrhein_westfalen" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."rheinland_pfalz" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."saarland" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."sachsen" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."sachsen_anhalt" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."schleswig_holstein" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."scrape_real_estate_berlin_120_1" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."scrape_real_estate_berlin_30_2" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "populate_location_trigger" BEFORE INSERT ON "public"."thueringen" FOR EACH ROW EXECUTE FUNCTION "public"."populate_location_from_job"();



CREATE OR REPLACE TRIGGER "scheduled_calls_overdue_check" BEFORE INSERT OR UPDATE ON "public"."scheduled_calls" FOR EACH ROW EXECUTE FUNCTION "public"."update_call_overdue_status"();



CREATE OR REPLACE TRIGGER "scheduled_calls_reschedule_counter" BEFORE UPDATE ON "public"."scheduled_calls" FOR EACH ROW WHEN (("old"."scheduled_date" IS DISTINCT FROM "new"."scheduled_date")) EXECUTE FUNCTION "public"."increment_reschedule_count"();



CREATE OR REPLACE TRIGGER "scheduled_calls_updated_at" BEFORE UPDATE ON "public"."scheduled_calls" FOR EACH ROW EXECUTE FUNCTION "public"."update_scheduled_calls_updated_at"();



CREATE OR REPLACE TRIGGER "scrape_progress_updated_at" BEFORE UPDATE ON "public"."scrape_progress" FOR EACH ROW EXECUTE FUNCTION "public"."update_scrape_progress_updated_at"();



CREATE OR REPLACE TRIGGER "scrape_real_estate_berlin_120_1_distribute_to_state" AFTER INSERT ON "public"."scrape_real_estate_berlin_120_1" FOR EACH ROW EXECUTE FUNCTION "public"."distribute_listing_to_state_table"();



CREATE OR REPLACE TRIGGER "scrape_real_estate_berlin_30_2_distribute_to_state" AFTER INSERT ON "public"."scrape_real_estate_berlin_30_2" FOR EACH ROW EXECUTE FUNCTION "public"."distribute_listing_to_state_table"();



CREATE OR REPLACE TRIGGER "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1_distr" AFTER INSERT ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR EACH ROW EXECUTE FUNCTION "public"."distribute_listing_to_state_table"();



CREATE OR REPLACE TRIGGER "set_agent_push_subscriptions_updated_at" BEFORE UPDATE ON "public"."agent_push_subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."set_agent_push_subscriptions_updated_at"();



CREATE OR REPLACE TRIGGER "single_scrape_auto_messaged" AFTER INSERT ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."set_single_scrape_messaged_status"();



CREATE OR REPLACE TRIGGER "sync_assigned_agent_on_insert" BEFORE INSERT ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."sync_assigned_agent_from_job"();



CREATE OR REPLACE TRIGGER "trg_lead_events_audit_delete" AFTER DELETE ON "public"."lead_events" FOR EACH ROW EXECUTE FUNCTION "public"."log_lead_event_audit"();



CREATE OR REPLACE TRIGGER "trg_lead_events_audit_insert" AFTER INSERT ON "public"."lead_events" FOR EACH ROW EXECUTE FUNCTION "public"."log_lead_event_audit"();



CREATE OR REPLACE TRIGGER "trg_lead_events_audit_update" AFTER UPDATE ON "public"."lead_events" FOR EACH ROW EXECUTE FUNCTION "public"."log_lead_event_audit"();



CREATE OR REPLACE TRIGGER "trg_maintain_scraper_task_count" AFTER INSERT OR DELETE OR UPDATE ON "public"."lead_actions" FOR EACH ROW EXECUTE FUNCTION "public"."maintain_scraper_task_count"();



CREATE OR REPLACE TRIGGER "trg_scraper_task_notify" AFTER INSERT OR UPDATE ON "public"."scraper_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."notify_scraper_task_assigned"();



CREATE OR REPLACE TRIGGER "trg_scraper_task_scraper_guard" BEFORE UPDATE ON "public"."scraper_tasks" FOR EACH ROW WHEN (("auth"."uid"() IS NOT NULL)) EXECUTE FUNCTION "public"."enforce_scraper_task_update_guard"();



CREATE OR REPLACE TRIGGER "trg_scraper_tasks_auto_progress" BEFORE UPDATE ON "public"."scraper_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."auto_progress_scraper_task"();



CREATE OR REPLACE TRIGGER "trg_scraper_tasks_updated_at" BEFORE UPDATE ON "public"."scraper_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."set_scraper_tasks_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sync_agent_to_scraper" AFTER INSERT OR UPDATE OF "total_leads_needed", "delivered_leads_count" ON "public"."lead_generation_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."sync_agent_task_to_scraper_tasks"();



CREATE OR REPLACE TRIGGER "trg_sync_single_scrape_task" AFTER INSERT ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."sync_single_scrape_task"();



CREATE OR REPLACE TRIGGER "trigger scraper" AFTER INSERT ON "public"."scrape_jobs" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://hook.eu2.make.com/h9dggsk9ipcqpuqd43ajhqmwdxvmj97v', 'POST', '{"Content-type":"application/json"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "trigger_apply_email_from_job" BEFORE INSERT ON "public"."single_scrapes" FOR EACH ROW WHEN (("new"."job_id" IS NOT NULL)) EXECUTE FUNCTION "public"."apply_email_from_job"();



CREATE OR REPLACE TRIGGER "trigger_auto_assign_single_scrape_internal_id" BEFORE INSERT ON "public"."single_scrapes" FOR EACH ROW WHEN ((("new"."internal_id" IS NULL) OR ("new"."internal_id" = ''::"text"))) EXECUTE FUNCTION "public"."auto_assign_single_scrape_internal_id"();



CREATE OR REPLACE TRIGGER "trigger_auto_create_task_lead" AFTER UPDATE ON "public"."listings" FOR EACH ROW EXECUTE FUNCTION "public"."auto_create_task_lead_on_sent"();



CREATE OR REPLACE TRIGGER "trigger_auto_set_single_scrape_messaged" BEFORE INSERT OR UPDATE ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."auto_set_single_scrape_messaged_status"();



CREATE OR REPLACE TRIGGER "trigger_auto_set_url_scrape_messaged" BEFORE INSERT OR UPDATE ON "public"."url_scrape" FOR EACH ROW EXECUTE FUNCTION "public"."auto_set_url_scrape_messaged_status"();



CREATE OR REPLACE TRIGGER "trigger_auto_task_lead_on_sent" AFTER UPDATE ON "public"."scrape_real_estate_berlin_120_1" FOR EACH ROW WHEN (("old"."assignment_status" IS DISTINCT FROM "new"."assignment_status")) EXECUTE FUNCTION "public"."auto_create_task_lead_on_sent"();



CREATE OR REPLACE TRIGGER "trigger_auto_task_lead_on_sent" AFTER UPDATE ON "public"."scrape_real_estate_berlin_30_2" FOR EACH ROW WHEN (("old"."assignment_status" IS DISTINCT FROM "new"."assignment_status")) EXECUTE FUNCTION "public"."auto_create_task_lead_on_sent"();



CREATE OR REPLACE TRIGGER "trigger_auto_task_lead_on_sent" AFTER UPDATE ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR EACH ROW WHEN (("old"."assignment_status" IS DISTINCT FROM "new"."assignment_status")) EXECUTE FUNCTION "public"."auto_create_task_lead_on_sent"();



CREATE OR REPLACE TRIGGER "trigger_auto_task_lead_on_sent" AFTER UPDATE ON "public"."single_scrapes" FOR EACH ROW WHEN (("old"."assignment_status" IS DISTINCT FROM "new"."assignment_status")) EXECUTE FUNCTION "public"."auto_create_task_lead_on_sent"();



CREATE OR REPLACE TRIGGER "trigger_calculate_session_duration" BEFORE UPDATE ON "public"."listing_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."calculate_session_duration"();



CREATE OR REPLACE TRIGGER "trigger_copy_scrape_notes" AFTER INSERT OR UPDATE OF "job_id" ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."copy_scrape_notes_to_single_scrapes"();



CREATE OR REPLACE TRIGGER "trigger_decrement_delivered_leads" AFTER DELETE ON "public"."task_leads" FOR EACH ROW EXECUTE FUNCTION "public"."decrement_task_delivered_count"();



CREATE OR REPLACE TRIGGER "trigger_generate_url_scrape_internal_id" BEFORE INSERT ON "public"."url_scrape" FOR EACH ROW WHEN (("new"."internal_id" IS NULL)) EXECUTE FUNCTION "public"."generate_url_scrape_internal_id"();



CREATE OR REPLACE TRIGGER "trigger_increment_delivered_leads" AFTER INSERT ON "public"."task_leads" FOR EACH ROW EXECUTE FUNCTION "public"."increment_task_delivered_count"();



CREATE OR REPLACE TRIGGER "trigger_notify_assignment_change" AFTER UPDATE OF "assigned_agent_id" ON "public"."scrape_real_estate_berlin_120_1" FOR EACH ROW WHEN ((("new"."assigned_agent_id" IS NOT NULL) AND ("old"."assigned_agent_id" IS DISTINCT FROM "new"."assigned_agent_id"))) EXECUTE FUNCTION "public"."notify_agent_assignment_change"();



CREATE OR REPLACE TRIGGER "trigger_notify_assignment_change" AFTER UPDATE OF "assigned_agent_id" ON "public"."scrape_real_estate_berlin_30_2" FOR EACH ROW WHEN ((("new"."assigned_agent_id" IS NOT NULL) AND ("old"."assigned_agent_id" IS DISTINCT FROM "new"."assigned_agent_id"))) EXECUTE FUNCTION "public"."notify_agent_assignment_change"();



CREATE OR REPLACE TRIGGER "trigger_notify_assignment_change" AFTER UPDATE OF "assigned_agent_id" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR EACH ROW WHEN ((("new"."assigned_agent_id" IS NOT NULL) AND ("old"."assigned_agent_id" IS DISTINCT FROM "new"."assigned_agent_id"))) EXECUTE FUNCTION "public"."notify_agent_assignment_change"();



CREATE OR REPLACE TRIGGER "trigger_notify_assignment_change" AFTER UPDATE OF "assigned_agent_id" ON "public"."single_scrapes" FOR EACH ROW WHEN ((("new"."assigned_agent_id" IS NOT NULL) AND ("old"."assigned_agent_id" IS DISTINCT FROM "new"."assigned_agent_id"))) EXECUTE FUNCTION "public"."notify_agent_assignment_change"();



CREATE OR REPLACE TRIGGER "trigger_notify_assignment_change" AFTER UPDATE OF "assigned_agent_id" ON "public"."url_scrape" FOR EACH ROW WHEN ((("new"."assigned_agent_id" IS NOT NULL) AND ("old"."assigned_agent_id" IS DISTINCT FROM "new"."assigned_agent_id"))) EXECUTE FUNCTION "public"."notify_agent_assignment_change"();



CREATE OR REPLACE TRIGGER "trigger_notify_call_scheduled" AFTER INSERT ON "public"."scheduled_calls" FOR EACH ROW EXECUTE FUNCTION "public"."notify_agent_call_scheduled"();



CREATE OR REPLACE TRIGGER "trigger_notify_replacement_resolution" AFTER UPDATE ON "public"."lead_replacement_requests" FOR EACH ROW EXECUTE FUNCTION "public"."notify_agent_replacement_resolution"();



CREATE OR REPLACE TRIGGER "trigger_populate_single_scrape_location" BEFORE INSERT ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."populate_single_scrape_location_data"();



CREATE OR REPLACE TRIGGER "trigger_propagate_scrape_error" AFTER INSERT OR UPDATE OF "has_error" ON "public"."scrape_progress" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_scrape_error"();



CREATE OR REPLACE TRIGGER "trigger_send_push_notification" AFTER INSERT ON "public"."agent_notifications" FOR EACH ROW EXECUTE FUNCTION "public"."send_push_notification_on_insert"();



CREATE OR REPLACE TRIGGER "trigger_sync_email_to_single_scrapes" AFTER UPDATE ON "public"."scrape_jobs" FOR EACH ROW WHEN (("old"."email" IS DISTINCT FROM "new"."email")) EXECUTE FUNCTION "public"."sync_email_from_job"();



CREATE OR REPLACE TRIGGER "trigger_sync_phone_override_to_single_scrapes" AFTER UPDATE ON "public"."scrape_jobs" FOR EACH ROW WHEN (("old"."phone_override" IS DISTINCT FROM "new"."phone_override")) EXECUTE FUNCTION "public"."sync_phone_override_to_single_scrapes"();



CREATE OR REPLACE TRIGGER "trigger_sync_scheduled_call" AFTER INSERT OR DELETE OR UPDATE ON "public"."scheduled_calls" FOR EACH ROW EXECUTE FUNCTION "public"."sync_scheduled_call_to_listing"();



CREATE OR REPLACE TRIGGER "trigger_update_single_scrape_has_phone" BEFORE INSERT OR UPDATE ON "public"."single_scrapes" FOR EACH ROW EXECUTE FUNCTION "public"."update_single_scrape_has_phone"();



CREATE OR REPLACE TRIGGER "trigger_update_url_scrape_has_phone" BEFORE INSERT OR UPDATE ON "public"."url_scrape" FOR EACH ROW EXECUTE FUNCTION "public"."update_url_scrape_has_phone"();



CREATE OR REPLACE TRIGGER "update_agent_notes_updated_at_trigger" BEFORE UPDATE ON "public"."agent_notes" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_notes_updated_at"();



CREATE OR REPLACE TRIGGER "update_agent_regions_of_activity_updated_at" BEFORE UPDATE ON "public"."agent_regions_of_activity" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_regions_updated_at"();



CREATE OR REPLACE TRIGGER "update_lead_generation_tasks_updated_at_trigger" BEFORE UPDATE ON "public"."lead_generation_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."update_lead_generation_tasks_updated_at"();



CREATE OR REPLACE TRIGGER "update_lead_replacement_requests_updated_at_trigger" BEFORE UPDATE ON "public"."lead_replacement_requests" FOR EACH ROW EXECUTE FUNCTION "public"."update_lead_replacement_requests_updated_at"();



CREATE OR REPLACE TRIGGER "update_task_delivered_count_trigger" AFTER INSERT OR DELETE ON "public"."task_leads" FOR EACH ROW EXECUTE FUNCTION "public"."update_task_delivered_count"();



ALTER TABLE ONLY "public"."agent_listing_notes"
    ADD CONSTRAINT "agent_listing_notes_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_notes"
    ADD CONSTRAINT "agent_notes_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_notifications"
    ADD CONSTRAINT "agent_notifications_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_push_subscriptions"
    ADD CONSTRAINT "agent_push_subscriptions_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_regions_of_activity"
    ADD CONSTRAINT "agent_regions_of_activity_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."archived_listings"
    ADD CONSTRAINT "archived_listings_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."baden_wuerttemberg"
    ADD CONSTRAINT "baden_wuerttemberg_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bayern"
    ADD CONSTRAINT "bayern_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."berlin"
    ADD CONSTRAINT "berlin_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."brandenburg"
    ADD CONSTRAINT "brandenburg_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bremen"
    ADD CONSTRAINT "bremen_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."call_next_actions"
    ADD CONSTRAINT "call_next_actions_call_id_fkey" FOREIGN KEY ("call_id") REFERENCES "public"."calls"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."call_next_actions"
    ADD CONSTRAINT "call_next_actions_deleted_by_fkey" FOREIGN KEY ("deleted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."call_next_actions"
    ADD CONSTRAINT "call_next_actions_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_deleted_by_fkey" FOREIGN KEY ("deleted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."error_logs"
    ADD CONSTRAINT "error_logs_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."error_logs"
    ADD CONSTRAINT "error_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hamburg"
    ADD CONSTRAINT "hamburg_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hessen"
    ADD CONSTRAINT "hessen_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_actions"
    ADD CONSTRAINT "lead_actions_scraper_task_id_fkey" FOREIGN KEY ("scraper_task_id") REFERENCES "public"."scraper_tasks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_actions"
    ADD CONSTRAINT "lead_actions_selected_task_id_fkey" FOREIGN KEY ("selected_task_id") REFERENCES "public"."lead_generation_tasks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."lead_generation_tasks"
    ADD CONSTRAINT "lead_generation_tasks_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_generation_tasks"
    ADD CONSTRAINT "lead_generation_tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."lead_replacement_requests"
    ADD CONSTRAINT "lead_replacement_requests_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_replacement_requests"
    ADD CONSTRAINT "lead_replacement_requests_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."lead_replacement_requests"
    ADD CONSTRAINT "lead_replacement_requests_task_lead_id_fkey" FOREIGN KEY ("task_lead_id") REFERENCES "public"."task_leads"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_status_changes"
    ADD CONSTRAINT "lead_status_changes_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."lead_status_changes"
    ADD CONSTRAINT "lead_status_changes_source_call_id_fkey" FOREIGN KEY ("source_call_id") REFERENCES "public"."calls"("id");



ALTER TABLE ONLY "public"."listing_interactions"
    ADD CONSTRAINT "listing_interactions_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."listing_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."listing_interactions"
    ADD CONSTRAINT "listing_interactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."listing_sessions"
    ADD CONSTRAINT "listing_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_assigned_agent_id_fkey" FOREIGN KEY ("assigned_agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."listings"
    ADD CONSTRAINT "listings_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mecklenburg_vorpommern"
    ADD CONSTRAINT "mecklenburg_vorpommern_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."niedersachsen"
    ADD CONSTRAINT "niedersachsen_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."nordrhein_westfalen"
    ADD CONSTRAINT "nordrhein_westfalen_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."real_estate_agents"
    ADD CONSTRAINT "real_estate_agents_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."real_estate_agents"
    ADD CONSTRAINT "real_estate_agents_team_leader_id_fkey" FOREIGN KEY ("team_leader_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."rheinland_pfalz"
    ADD CONSTRAINT "rheinland_pfalz_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."saarland"
    ADD CONSTRAINT "saarland_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sachsen_anhalt"
    ADD CONSTRAINT "sachsen_anhalt_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sachsen"
    ADD CONSTRAINT "sachsen_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."scheduled_calls"
    ADD CONSTRAINT "scheduled_calls_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scheduled_calls"
    ADD CONSTRAINT "scheduled_calls_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."schleswig_holstein"
    ADD CONSTRAINT "schleswig_holstein_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."scrape_jobs"
    ADD CONSTRAINT "scrape_jobs_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."scrape_jobs"
    ADD CONSTRAINT "scrape_jobs_scraper_task_id_fkey" FOREIGN KEY ("scraper_task_id") REFERENCES "public"."scraper_tasks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."scrape_progress"
    ADD CONSTRAINT "scrape_progress_scrape_job_id_fkey" FOREIGN KEY ("scrape_job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scrape_real_estate_berlin_120_1"
    ADD CONSTRAINT "scrape_real_estate_berlin_120_1_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scrape_real_estate_berlin_30_2"
    ADD CONSTRAINT "scrape_real_estate_berlin_30_2_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"
    ADD CONSTRAINT "scrape_real_estate_essen_fulerum_nordrhein_westfale_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scrape_tables_registry"
    ADD CONSTRAINT "scrape_tables_registry_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."scraper_notifications"
    ADD CONSTRAINT "scraper_notifications_scraper_id_fkey" FOREIGN KEY ("scraper_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."scraper_notifications"
    ADD CONSTRAINT "scraper_notifications_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."scraper_tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scraper_tasks"
    ADD CONSTRAINT "scraper_tasks_assigned_scraper_id_fkey" FOREIGN KEY ("assigned_scraper_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."scraper_tasks"
    ADD CONSTRAINT "scraper_tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."single_scrapes"
    ADD CONSTRAINT "single_scrapes_assigned_agent_id_fkey" FOREIGN KEY ("assigned_agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."single_scrapes"
    ADD CONSTRAINT "single_scrapes_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_lead_pricing_blocks"
    ADD CONSTRAINT "task_lead_pricing_blocks_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."lead_generation_tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_leads"
    ADD CONSTRAINT "task_leads_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."task_leads"
    ADD CONSTRAINT "task_leads_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."lead_generation_tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_regions"
    ADD CONSTRAINT "task_regions_region_id_fkey" FOREIGN KEY ("region_id") REFERENCES "public"."agent_regions_of_activity"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_regions"
    ADD CONSTRAINT "task_regions_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."lead_generation_tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."thueringen"
    ADD CONSTRAINT "thueringen_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."url_scrape"
    ADD CONSTRAINT "url_scrape_assigned_agent_id_fkey" FOREIGN KEY ("assigned_agent_id") REFERENCES "public"."real_estate_agents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."url_scrape"
    ADD CONSTRAINT "url_scrape_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."scrape_jobs"("id") ON DELETE CASCADE;



CREATE POLICY "Admin and management can delete agent regions" ON "public"."agent_regions_of_activity" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admin and management can insert agent regions" ON "public"."agent_regions_of_activity" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admin and management can update agent regions" ON "public"."agent_regions_of_activity" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admin can create listing notes" ON "public"."agent_listing_notes" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can create scheduled calls" ON "public"."scheduled_calls" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can delete archived listings" ON "public"."archived_listings" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admin can delete scheduled calls" ON "public"."scheduled_calls" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can insert archived listings" ON "public"."archived_listings" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admin can read all listing notes" ON "public"."agent_listing_notes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can read all scheduled calls" ON "public"."scheduled_calls" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can update all listing notes" ON "public"."agent_listing_notes" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can update all scheduled calls" ON "public"."scheduled_calls" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin can view archived listings" ON "public"."archived_listings" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admin management scrape and view_edit can view all" ON "public"."scrape_real_estate_berlin_120_1" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin management scrape and view_edit can view all" ON "public"."scrape_real_estate_berlin_30_2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin management scrape and view_edit can view all" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all baden_wuerttemberg" ON "public"."baden_wuerttemberg" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all bayern" ON "public"."bayern" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all berlin" ON "public"."berlin" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all brandenburg" ON "public"."brandenburg" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all bremen" ON "public"."bremen" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all hamburg" ON "public"."hamburg" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all hessen" ON "public"."hessen" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all mecklenburg_vorpommern" ON "public"."mecklenburg_vorpommern" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all niedersachsen" ON "public"."niedersachsen" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all nordrhein_westfalen" ON "public"."nordrhein_westfalen" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all rheinland_pfalz" ON "public"."rheinland_pfalz" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all saarland" ON "public"."saarland" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all sachsen" ON "public"."sachsen" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all sachsen_anhalt" ON "public"."sachsen_anhalt" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all schleswig_holstein" ON "public"."schleswig_holstein" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can read all thueringen" ON "public"."thueringen" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape and view_edit can view all single scrapes" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape management and view_edit can view all" ON "public"."scrape_real_estate_berlin_120_1" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape management and view_edit can view all" ON "public"."scrape_real_estate_berlin_30_2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape management and view_edit can view all" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin scrape management and view_edit can view all" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can create listing notes" ON "public"."agent_listing_notes" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can create scheduled calls" ON "public"."scheduled_calls" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can delete scheduled calls" ON "public"."scheduled_calls" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can read all listing notes" ON "public"."agent_listing_notes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can read all scheduled calls" ON "public"."scheduled_calls" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can update all listing notes" ON "public"."agent_listing_notes" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admin+management can update all scheduled calls" ON "public"."scheduled_calls" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins and management can create pricing blocks" ON "public"."task_lead_pricing_blocks" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can create task regions" ON "public"."task_regions" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can delete" ON "public"."scrape_real_estate_berlin_120_1" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can delete" ON "public"."scrape_real_estate_berlin_30_2" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can delete" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can delete agents" ON "public"."real_estate_agents" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can delete task regions" ON "public"."task_regions" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can delete tasks" ON "public"."lead_generation_tasks" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can insert agents" ON "public"."real_estate_agents" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can insert tasks" ON "public"."lead_generation_tasks" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can update agents" ON "public"."real_estate_agents" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can update pricing blocks" ON "public"."task_lead_pricing_blocks" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can update replacement requests" ON "public"."lead_replacement_requests" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can update tasks" ON "public"."lead_generation_tasks" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can view all agent notes" ON "public"."agent_notes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins and management can view all replacement requests" ON "public"."lead_replacement_requests" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins can delete" ON "public"."scrape_real_estate_berlin_120_1" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins can delete" ON "public"."scrape_real_estate_berlin_30_2" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins can delete" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins can delete" ON "public"."single_scrapes" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



CREATE POLICY "Admins can delete error logs" ON "public"."error_logs" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can delete url scrapes" ON "public"."url_scrape" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can delete versions" ON "public"."app_versions" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can insert versions" ON "public"."app_versions" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can manage versions" ON "public"."app_versions" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can update error logs" ON "public"."error_logs" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can update versions" ON "public"."app_versions" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins can view all error logs" ON "public"."error_logs" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text")))));



CREATE POLICY "Admins management scrape and view_edit can insert" ON "public"."scrape_real_estate_berlin_120_1" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can insert" ON "public"."scrape_real_estate_berlin_30_2" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can insert" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can insert" ON "public"."single_scrapes" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can update" ON "public"."scrape_real_estate_berlin_120_1" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can update" ON "public"."scrape_real_estate_berlin_30_2" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can update" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape and view_edit can update" ON "public"."single_scrapes" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Admins management scrape can delete task leads" ON "public"."task_leads" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text"]))))));



CREATE POLICY "Admins management scrape can insert task leads" ON "public"."task_leads" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text"]))))));



CREATE POLICY "Admins management scrape can update task leads" ON "public"."task_leads" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'manager'::"text", 'scrape'::"text"]))))));



CREATE POLICY "Agents can create own listing notes" ON "public"."agent_listing_notes" FOR INSERT TO "authenticated" WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can create replacement requests" ON "public"."lead_replacement_requests" FOR INSERT TO "authenticated" WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can create their own notes" ON "public"."agent_notes" FOR INSERT TO "authenticated" WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can delete their own notes" ON "public"."agent_notes" FOR DELETE TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can manage their own push subscriptions" ON "public"."agent_push_subscriptions" TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can read own listing notes" ON "public"."agent_listing_notes" FOR SELECT TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can read own scheduled calls" ON "public"."scheduled_calls" FOR SELECT TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update own call status" ON "public"."scheduled_calls" FOR UPDATE TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update own listing notes" ON "public"."agent_listing_notes" FOR UPDATE TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update own notifications" ON "public"."agent_notifications" FOR UPDATE TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update sent leads assigned to them" ON "public"."scrape_real_estate_berlin_120_1" FOR UPDATE TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_berlin_120_1"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_berlin_120_1"."assigned_to"))))))) WITH CHECK ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_berlin_120_1"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_berlin_120_1"."assigned_to")))))));



CREATE POLICY "Agents can update sent leads assigned to them" ON "public"."scrape_real_estate_berlin_30_2" FOR UPDATE TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_berlin_30_2"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_berlin_30_2"."assigned_to"))))))) WITH CHECK ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_berlin_30_2"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_berlin_30_2"."assigned_to")))))));



CREATE POLICY "Agents can update sent leads assigned to them" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR UPDATE TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_to"))))))) WITH CHECK ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_to")))))));



CREATE POLICY "Agents can update sent leads assigned to them" ON "public"."single_scrapes" FOR UPDATE TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (("assigned_agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("assigned_to" IN ( SELECT ("real_estate_agents"."id")::"text" AS "id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))))) WITH CHECK ((("assignment_status" = 'sent'::"text") AND (("assigned_agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("assigned_to" IN ( SELECT ("real_estate_agents"."id")::"text" AS "id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Agents can update their assigned leads" ON "public"."single_scrapes" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Baden-Württemberg" ON "public"."baden_wuerttemberg" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Bayern" ON "public"."bayern" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Berlin" ON "public"."berlin" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Brandenburg" ON "public"."brandenburg" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Bremen" ON "public"."bremen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Hamburg" ON "public"."hamburg" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Hessen" ON "public"."hessen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Mecklenburg-Vorpommer" ON "public"."mecklenburg_vorpommern" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Niedersachsen" ON "public"."niedersachsen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Nordrhein-Westfalen" ON "public"."nordrhein_westfalen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Rheinland-Pfalz" ON "public"."rheinland_pfalz" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Saarland" ON "public"."saarland" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Sachsen" ON "public"."sachsen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Sachsen-Anhalt" ON "public"."sachsen_anhalt" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Schleswig-Holstein" ON "public"."schleswig_holstein" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in Thüringen" ON "public"."thueringen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in baden_wuerttemberg" ON "public"."baden_wuerttemberg" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in bayern" ON "public"."bayern" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in berlin" ON "public"."berlin" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in brandenburg" ON "public"."brandenburg" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in bremen" ON "public"."bremen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in hamburg" ON "public"."hamburg" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in hessen" ON "public"."hessen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in mecklenburg_vorpommer" ON "public"."mecklenburg_vorpommern" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in niedersachsen" ON "public"."niedersachsen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in nordrhein_westfalen" ON "public"."nordrhein_westfalen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in rheinland_pfalz" ON "public"."rheinland_pfalz" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in saarland" ON "public"."saarland" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in sachsen" ON "public"."sachsen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in sachsen_anhalt" ON "public"."sachsen_anhalt" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in schleswig_holstein" ON "public"."schleswig_holstein" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in scrape_real_estate_be" ON "public"."scrape_real_estate_berlin_120_1" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in scrape_real_estate_be" ON "public"."scrape_real_estate_berlin_30_2" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in scrape_real_estate_es" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their assigned leads in thueringen" ON "public"."thueringen" FOR UPDATE TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can update their own notes" ON "public"."agent_notes" FOR UPDATE TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view own notifications" ON "public"."agent_notifications" FOR SELECT TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view sent leads assigned to them" ON "public"."scrape_real_estate_berlin_120_1" FOR SELECT TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_berlin_120_1"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_berlin_120_1"."assigned_to")))))));



CREATE POLICY "Agents can view sent leads assigned to them" ON "public"."scrape_real_estate_berlin_30_2" FOR SELECT TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_berlin_30_2"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_berlin_30_2"."assigned_to")))))));



CREATE POLICY "Agents can view sent leads assigned to them" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR SELECT TO "authenticated" USING ((("assignment_status" = 'sent'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."real_estate_agents" "a"
  WHERE (("a"."profile_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("a"."id" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_agent_id") OR (("a"."id")::"text" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_to")))))));



CREATE POLICY "Agents can view sent leads assigned to them" ON "public"."single_scrapes" FOR SELECT USING ((("assignment_status" = 'sent'::"text") AND (("assigned_agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("assigned_to" IN ( SELECT ("real_estate_agents"."id")::"text" AS "id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))))));



CREATE POLICY "Agents can view their assigned leads in Baden-Württemberg" ON "public"."baden_wuerttemberg" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Bayern" ON "public"."bayern" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Berlin" ON "public"."berlin" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Brandenburg" ON "public"."brandenburg" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Bremen" ON "public"."bremen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Hamburg" ON "public"."hamburg" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Hessen" ON "public"."hessen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Mecklenburg-Vorpommern" ON "public"."mecklenburg_vorpommern" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Niedersachsen" ON "public"."niedersachsen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Nordrhein-Westfalen" ON "public"."nordrhein_westfalen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Rheinland-Pfalz" ON "public"."rheinland_pfalz" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Saarland" ON "public"."saarland" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Sachsen" ON "public"."sachsen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Sachsen-Anhalt" ON "public"."sachsen_anhalt" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Schleswig-Holstein" ON "public"."schleswig_holstein" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in Thüringen" ON "public"."thueringen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in baden_wuerttemberg" ON "public"."baden_wuerttemberg" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in bayern" ON "public"."bayern" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in berlin" ON "public"."berlin" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in brandenburg" ON "public"."brandenburg" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in bremen" ON "public"."bremen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in hamburg" ON "public"."hamburg" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in hessen" ON "public"."hessen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in mecklenburg_vorpommern" ON "public"."mecklenburg_vorpommern" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in niedersachsen" ON "public"."niedersachsen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in nordrhein_westfalen" ON "public"."nordrhein_westfalen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in rheinland_pfalz" ON "public"."rheinland_pfalz" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in saarland" ON "public"."saarland" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in sachsen" ON "public"."sachsen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in sachsen_anhalt" ON "public"."sachsen_anhalt" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in schleswig_holstein" ON "public"."schleswig_holstein" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in scrape_real_estate_berl" ON "public"."scrape_real_estate_berlin_120_1" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in scrape_real_estate_berl" ON "public"."scrape_real_estate_berlin_30_2" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in scrape_real_estate_esse" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their assigned leads in thueringen" ON "public"."thueringen" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their own assigned leads" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING (("assigned_agent_id" = ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their own notes" ON "public"."agent_notes" FOR SELECT TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Agents can view their own replacement requests" ON "public"."lead_replacement_requests" FOR SELECT TO "authenticated" USING (("agent_id" IN ( SELECT "real_estate_agents"."id"
   FROM "public"."real_estate_agents"
  WHERE ("real_estate_agents"."profile_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "All authenticated users can read agent regions" ON "public"."agent_regions_of_activity" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "All authenticated users can read agents" ON "public"."real_estate_agents" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "All authenticated users can view all task leads" ON "public"."task_leads" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "All authenticated users can view all tasks" ON "public"."lead_generation_tasks" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow all operations on lead_actions" ON "public"."lead_actions" USING (true) WITH CHECK (true);



CREATE POLICY "Allow all operations on lead_counter" ON "public"."lead_counter" USING (true) WITH CHECK (true);



CREATE POLICY "Allow all operations on listings" ON "public"."listings" USING (true) WITH CHECK (true);



CREATE POLICY "Allow all operations on scrape_jobs" ON "public"."scrape_jobs" USING (true) WITH CHECK (true);



CREATE POLICY "Allow all operations on scrape_tables_registry" ON "public"."scrape_tables_registry" USING (true) WITH CHECK (true);



CREATE POLICY "Allow anon inserts to url_scrape" ON "public"."url_scrape" FOR INSERT TO "anon", "service_role" WITH CHECK (true);



CREATE POLICY "Allow anon updates to url_scrape" ON "public"."url_scrape" FOR UPDATE TO "anon", "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow anonymous inserts for Make.com" ON "public"."single_scrapes" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "Allow authenticated users to delete progress" ON "public"."scrape_progress" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to insert progress" ON "public"."scrape_progress" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated users to update progress" ON "public"."scrape_progress" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Allow authenticated users to view progress" ON "public"."scrape_progress" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow public read on table_counter" ON "public"."table_counter" FOR SELECT USING (true);



CREATE POLICY "Anyone can read active versions" ON "public"."app_versions" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Anyone can read categories" ON "public"."categories" FOR SELECT USING (true);



CREATE POLICY "Anyone can read cities" ON "public"."cities" FOR SELECT USING (true);



CREATE POLICY "App versions are viewable by authenticated users" ON "public"."app_versions" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



CREATE POLICY "Authenticated users can assign leads" ON "public"."task_leads" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Authenticated users can create tasks" ON "public"."lead_generation_tasks" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Authenticated users can delete baden_wuerttemberg" ON "public"."baden_wuerttemberg" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete bayern" ON "public"."bayern" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete berlin" ON "public"."berlin" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete brandenburg" ON "public"."brandenburg" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete bremen" ON "public"."bremen" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete categories" ON "public"."categories" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete cities" ON "public"."cities" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete hamburg" ON "public"."hamburg" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete hessen" ON "public"."hessen" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete mecklenburg_vorpommern" ON "public"."mecklenburg_vorpommern" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete niedersachsen" ON "public"."niedersachsen" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete nordrhein_westfalen" ON "public"."nordrhein_westfalen" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete pricing blocks" ON "public"."task_lead_pricing_blocks" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Authenticated users can delete rheinland_pfalz" ON "public"."rheinland_pfalz" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete saarland" ON "public"."saarland" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete sachsen" ON "public"."sachsen" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete sachsen_anhalt" ON "public"."sachsen_anhalt" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete schleswig_holstein" ON "public"."schleswig_holstein" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can delete thueringen" ON "public"."thueringen" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can insert baden_wuerttemberg" ON "public"."baden_wuerttemberg" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert bayern" ON "public"."bayern" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert berlin" ON "public"."berlin" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert brandenburg" ON "public"."brandenburg" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert bremen" ON "public"."bremen" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert categories" ON "public"."categories" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert cities" ON "public"."cities" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert hamburg" ON "public"."hamburg" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert hessen" ON "public"."hessen" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert mecklenburg_vorpommern" ON "public"."mecklenburg_vorpommern" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert niedersachsen" ON "public"."niedersachsen" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert nordrhein_westfalen" ON "public"."nordrhein_westfalen" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert rheinland_pfalz" ON "public"."rheinland_pfalz" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert saarland" ON "public"."saarland" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert sachsen" ON "public"."sachsen" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert sachsen_anhalt" ON "public"."sachsen_anhalt" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert schleswig_holstein" ON "public"."schleswig_holstein" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert thueringen" ON "public"."thueringen" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can read all profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can update baden_wuerttemberg" ON "public"."baden_wuerttemberg" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update bayern" ON "public"."bayern" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update berlin" ON "public"."berlin" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update brandenburg" ON "public"."brandenburg" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update bremen" ON "public"."bremen" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update categories" ON "public"."categories" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update cities" ON "public"."cities" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update hamburg" ON "public"."hamburg" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update hessen" ON "public"."hessen" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update mecklenburg_vorpommern" ON "public"."mecklenburg_vorpommern" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update niedersachsen" ON "public"."niedersachsen" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update nordrhein_westfalen" ON "public"."nordrhein_westfalen" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update rheinland_pfalz" ON "public"."rheinland_pfalz" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update saarland" ON "public"."saarland" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update sachsen" ON "public"."sachsen" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update sachsen_anhalt" ON "public"."sachsen_anhalt" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update schleswig_holstein" ON "public"."schleswig_holstein" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can update thueringen" ON "public"."thueringen" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can view all tasks" ON "public"."lead_generation_tasks" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can view pricing blocks" ON "public"."task_lead_pricing_blocks" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can view task regions" ON "public"."task_regions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authorized users can insert url scrapes" ON "public"."url_scrape" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Authorized users can update url scrapes" ON "public"."url_scrape" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Management can update all single scrapes" ON "public"."single_scrapes" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "Management can view all single scrapes" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'management'::"text", 'scrape'::"text", 'view_edit'::"text"]))))));



CREATE POLICY "System can insert notifications" ON "public"."agent_notifications" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Team leaders can read team member listing notes" ON "public"."agent_listing_notes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."profiles" "p"
     JOIN "public"."real_estate_agents" "leader" ON (("leader"."profile_id" = "p"."id")))
     JOIN "public"."real_estate_agents" "member" ON (("member"."team_leader_id" = "leader"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'team_leader'::"text") AND ("agent_listing_notes"."agent_id" = "member"."id")))));



CREATE POLICY "Team leaders can read team member scheduled calls" ON "public"."scheduled_calls" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."profiles" "p"
     JOIN "public"."real_estate_agents" "leader" ON (("leader"."profile_id" = "p"."id")))
     JOIN "public"."real_estate_agents" "member" ON (("member"."team_leader_id" = "leader"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'team_leader'::"text") AND ("scheduled_calls"."agent_id" = "member"."id")))));



CREATE POLICY "Team leaders can update team member scheduled calls" ON "public"."scheduled_calls" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."profiles" "p"
     JOIN "public"."real_estate_agents" "leader" ON (("leader"."profile_id" = "p"."id")))
     JOIN "public"."real_estate_agents" "member" ON (("member"."team_leader_id" = "leader"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'team_leader'::"text") AND ("scheduled_calls"."agent_id" = "member"."id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."profiles" "p"
     JOIN "public"."real_estate_agents" "leader" ON (("leader"."profile_id" = "p"."id")))
     JOIN "public"."real_estate_agents" "member" ON (("member"."team_leader_id" = "leader"."id")))
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'team_leader'::"text") AND ("scheduled_calls"."agent_id" = "member"."id")))));



CREATE POLICY "Team leaders can view team listings" ON "public"."scrape_real_estate_berlin_120_1" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."real_estate_agents" "team_member"
     JOIN "public"."real_estate_agents" "leader" ON (("team_member"."team_leader_id" = "leader"."id")))
  WHERE (("team_member"."id" = "scrape_real_estate_berlin_120_1"."assigned_agent_id") AND ("leader"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Team leaders can view team listings" ON "public"."scrape_real_estate_berlin_30_2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."real_estate_agents" "team_member"
     JOIN "public"."real_estate_agents" "leader" ON (("team_member"."team_leader_id" = "leader"."id")))
  WHERE (("team_member"."id" = "scrape_real_estate_berlin_30_2"."assigned_agent_id") AND ("leader"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Team leaders can view team listings" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."real_estate_agents" "team_member"
     JOIN "public"."real_estate_agents" "leader" ON (("team_member"."team_leader_id" = "leader"."id")))
  WHERE (("team_member"."id" = "scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1"."assigned_agent_id") AND ("leader"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Team leaders can view team listings" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."real_estate_agents" "team_member"
     JOIN "public"."real_estate_agents" "leader" ON (("team_member"."team_leader_id" = "leader"."id")))
  WHERE (("team_member"."id" = "single_scrapes"."assigned_agent_id") AND ("leader"."profile_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Team leaders can view team member interactions" ON "public"."listing_interactions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."profiles" "p"
     JOIN "public"."real_estate_agents" "leader" ON (("leader"."profile_id" = "p"."id")))
     JOIN "public"."real_estate_agents" "member" ON (("member"."team_leader_id" = "leader"."id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."role" = 'team_leader'::"text") AND ("listing_interactions"."user_id" = "member"."profile_id")))));



CREATE POLICY "Team leaders can view team member sessions" ON "public"."listing_sessions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."profiles" "p"
     JOIN "public"."real_estate_agents" "leader" ON (("leader"."profile_id" = "p"."id")))
     JOIN "public"."real_estate_agents" "member" ON (("member"."team_leader_id" = "leader"."id")))
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."role" = 'team_leader'::"text") AND ("listing_sessions"."user_id" = "member"."profile_id")))));



CREATE POLICY "Users can delete tasks they created" ON "public"."lead_generation_tasks" FOR DELETE TO "authenticated" USING (("created_by" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can insert error logs" ON "public"."error_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Users can insert own interactions" ON "public"."listing_interactions" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can insert own sessions" ON "public"."listing_sessions" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can remove lead assignments they created" ON "public"."task_leads" FOR DELETE TO "authenticated" USING (("assigned_by" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update own sessions" ON "public"."listing_sessions" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update tasks they created" ON "public"."lead_generation_tasks" FOR UPDATE TO "authenticated" USING (("created_by" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("created_by" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view interactions" ON "public"."listing_interactions" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text"))))));



CREATE POLICY "Users can view sessions" ON "public"."listing_sessions" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'admin'::"text"))))));



CREATE POLICY "Users can view url scrapes" ON "public"."url_scrape" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = ANY (ARRAY['admin'::"text", 'view_edit'::"text", 'view_only'::"text", 'scrape'::"text"]))))));



ALTER TABLE "public"."agent_listing_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_push_subscriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_regions_of_activity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."archived_listings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."baden_wuerttemberg" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bayern" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."berlin" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."brandenburg" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bremen" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."call_next_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."calls" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "calls_insert" ON "public"."calls" WITH CHECK ((("auth"."uid"() IS NOT NULL) AND ("agent_id" = "auth"."uid"())));



CREATE POLICY "calls_select" ON "public"."calls" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "calls_update" ON "public"."calls" USING ((("deleted_at" IS NULL) AND ("agent_id" = "auth"."uid"()))) WITH CHECK (("agent_id" = "auth"."uid"()));



ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cna_insert" ON "public"."call_next_actions" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "cna_select" ON "public"."call_next_actions" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "cna_update" ON "public"."call_next_actions" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "deny all" ON "public"."app_config" USING (false) WITH CHECK (false);



ALTER TABLE "public"."error_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hamburg" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hessen" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lead_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lead_counter" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lead_event_audits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_event_audits_admin_read" ON "public"."lead_event_audits" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = ANY (ARRAY['admin'::"text", 'management'::"text"]))))));



ALTER TABLE "public"."lead_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_events_admin_all" ON "public"."lead_events" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'admin'::"text")))));



CREATE POLICY "lead_events_agent_read" ON "public"."lead_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = ANY (ARRAY['agent'::"text", 'team_leader'::"text", 'management'::"text"]))))));



CREATE POLICY "lead_events_agent_update" ON "public"."lead_events" FOR UPDATE TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'admin'::"text")))) OR ("created_by" = ( SELECT "auth"."uid"() AS "uid")))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = 'admin'::"text")))) OR ("created_by" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "lead_events_agent_write" ON "public"."lead_events" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("p"."role" = ANY (ARRAY['agent'::"text", 'team_leader'::"text", 'admin'::"text"]))))));



ALTER TABLE "public"."lead_generation_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lead_replacement_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lead_status_changes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."listing_interactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."listing_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."listings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lsc_insert" ON "public"."lead_status_changes" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "lsc_select" ON "public"."lead_status_changes" USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."mecklenburg_vorpommern" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."niedersachsen" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nordrhein_westfalen" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."real_estate_agents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rheinland_pfalz" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."saarland" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sachsen" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sachsen_anhalt" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scheduled_calls" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."schleswig_holstein" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scrape_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scrape_progress" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scrape_real_estate_berlin_120_1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scrape_real_estate_berlin_30_2" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scrape_tables_registry" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scraper_notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "scraper_notifications admin management full" ON "public"."scraper_notifications" TO "authenticated" USING ("public"."is_admin_or_management"("auth"."uid"())) WITH CHECK ("public"."is_admin_or_management"("auth"."uid"()));



CREATE POLICY "scraper_notifications no delete for scraper" ON "public"."scraper_notifications" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "scraper_notifications no insert for scraper" ON "public"."scraper_notifications" FOR INSERT TO "authenticated" WITH CHECK (false);



CREATE POLICY "scraper_notifications scraper read own" ON "public"."scraper_notifications" FOR SELECT TO "authenticated" USING (("scraper_id" = "auth"."uid"()));



CREATE POLICY "scraper_notifications scraper update read flag" ON "public"."scraper_notifications" FOR UPDATE TO "authenticated" USING (("scraper_id" = "auth"."uid"())) WITH CHECK (("scraper_id" = "auth"."uid"()));



ALTER TABLE "public"."scraper_tasks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "scraper_tasks admin management full" ON "public"."scraper_tasks" TO "authenticated" USING ("public"."is_admin_or_management"("auth"."uid"())) WITH CHECK ("public"."is_admin_or_management"("auth"."uid"()));



CREATE POLICY "scraper_tasks scraper complete only" ON "public"."scraper_tasks" FOR UPDATE TO "authenticated" USING (("public"."is_scraper"("auth"."uid"()) AND ("assigned_scraper_id" = "auth"."uid"()))) WITH CHECK (("public"."is_scraper"("auth"."uid"()) AND ("assigned_scraper_id" = "auth"."uid"()) AND ("status" = ANY (ARRAY['new'::"public"."scraper_task_status", 'in_progress'::"public"."scraper_task_status", 'completed'::"public"."scraper_task_status"]))));



CREATE POLICY "scraper_tasks scraper no delete" ON "public"."scraper_tasks" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "scraper_tasks scraper no insert delete" ON "public"."scraper_tasks" FOR INSERT TO "authenticated" WITH CHECK (false);



CREATE POLICY "scraper_tasks scraper read own" ON "public"."scraper_tasks" FOR SELECT TO "authenticated" USING (("public"."is_scraper"("auth"."uid"()) AND ("assigned_scraper_id" = "auth"."uid"())));



ALTER TABLE "public"."single_scrapes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."table_counter" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_lead_pricing_blocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_leads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_regions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."thueringen" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."url_scrape" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "view_call can read baden_wuerttemberg with phone" ON "public"."baden_wuerttemberg" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read bayern with phone" ON "public"."bayern" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read berlin with phone" ON "public"."berlin" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read brandenburg with phone" ON "public"."brandenburg" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read bremen with phone" ON "public"."bremen" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read hamburg with phone" ON "public"."hamburg" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read hessen with phone" ON "public"."hessen" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read mecklenburg_vorpommern with phone" ON "public"."mecklenburg_vorpommern" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read niedersachsen with phone" ON "public"."niedersachsen" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read nordrhein_westfalen with phone" ON "public"."nordrhein_westfalen" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read rheinland_pfalz with phone" ON "public"."rheinland_pfalz" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read saarland with phone" ON "public"."saarland" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read sachsen with phone" ON "public"."sachsen" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read sachsen_anhalt with phone" ON "public"."sachsen_anhalt" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read schleswig_holstein with phone" ON "public"."schleswig_holstein" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can read thueringen with phone" ON "public"."thueringen" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND (("has_phone" = true) OR ("phone" IS NOT NULL))));



CREATE POLICY "view_call can view listings with phone" ON "public"."scrape_real_estate_berlin_120_1" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'view_call'::"text")))) AND ("has_phone" = true) AND (COALESCE("assignment_status", 'not_sent'::"text") <> 'sent'::"text")));



CREATE POLICY "view_call can view listings with phone" ON "public"."scrape_real_estate_berlin_30_2" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'view_call'::"text")))) AND ("has_phone" = true) AND (COALESCE("assignment_status", 'not_sent'::"text") <> 'sent'::"text")));



CREATE POLICY "view_call can view listings with phone" ON "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'view_call'::"text")))) AND ("has_phone" = true) AND (COALESCE("assignment_status", 'not_sent'::"text") <> 'sent'::"text")));



CREATE POLICY "view_call can view listings with phone" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("profiles"."role" = 'view_call'::"text")))) AND ("has_phone" = true) AND (COALESCE("assignment_status", 'not_sent'::"text") <> 'sent'::"text")));



CREATE POLICY "view_call can view single scrapes with phone" ON "public"."single_scrapes" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'view_call'::"text")))) AND ("has_phone" = true)));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."agent_notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."scrape_jobs";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."scrape_progress";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."scrape_real_estate_berlin_120_1";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."scrape_real_estate_berlin_30_2";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."single_scrapes";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."url_scrape";



GRANT USAGE ON SCHEMA "api" TO "anon";
GRANT USAGE ON SCHEMA "api" TO "authenticated";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON TABLE "public"."scraper_tasks" TO "anon";
GRANT ALL ON TABLE "public"."scraper_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."scraper_tasks" TO "service_role";



GRANT ALL ON FUNCTION "public"."api_assign_scraper_task"("p_task_id" "uuid", "p_scraper_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."api_assign_scraper_task"("p_task_id" "uuid", "p_scraper_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_assign_scraper_task"("p_task_id" "uuid", "p_scraper_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."scraper_tasks_scraper_view" TO "anon";
GRANT ALL ON TABLE "public"."scraper_tasks_scraper_view" TO "authenticated";
GRANT ALL ON TABLE "public"."scraper_tasks_scraper_view" TO "service_role";



GRANT ALL ON FUNCTION "public"."api_complete_my_scraper_task"("p_task_id" "uuid", "p_current_lead_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."api_complete_my_scraper_task"("p_task_id" "uuid", "p_current_lead_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_complete_my_scraper_task"("p_task_id" "uuid", "p_current_lead_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text", "p_property_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text", "p_property_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_create_scraper_task"("p_region" "text", "p_assigned_scraper_id" "uuid", "p_task_type" "public"."scraper_task_type", "p_target_lead_count" integer, "p_qualified_lead_count" integer, "p_multiplier" numeric, "p_city" "text", "p_area" "text", "p_source_agent_order_id" "uuid", "p_notes" "text", "p_property_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."api_get_my_scraper_task"("p_task_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."api_get_my_scraper_task"("p_task_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_get_my_scraper_task"("p_task_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."api_list_my_scraper_tasks"() TO "anon";
GRANT ALL ON FUNCTION "public"."api_list_my_scraper_tasks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_list_my_scraper_tasks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."api_list_scraper_tasks"() TO "anon";
GRANT ALL ON FUNCTION "public"."api_list_scraper_tasks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_list_scraper_tasks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_assignment_notification_trigger"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_assignment_notification_trigger"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_assignment_notification_trigger"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_email_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."apply_email_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_email_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_phone_override_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."apply_phone_override_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_phone_override_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_task_lead_trigger_to_table"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_task_lead_trigger_to_table"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_task_lead_trigger_to_table"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."archive_listing"("p_listing_id" "text", "p_source_table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."archive_listing"("p_listing_id" "text", "p_source_table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."archive_listing"("p_listing_id" "text", "p_source_table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_assign_single_scrape_internal_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_assign_single_scrape_internal_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_assign_single_scrape_internal_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_complete_task"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_complete_task"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_complete_task"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_create_task_lead_on_sent"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_create_task_lead_on_sent"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_create_task_lead_on_sent"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_populate_single_scrape_job_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_populate_single_scrape_job_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_populate_single_scrape_job_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_progress_scraper_task"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_progress_scraper_task"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_progress_scraper_task"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_set_single_scrape_messaged_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_set_single_scrape_messaged_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_set_single_scrape_messaged_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_set_url_scrape_messaged_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_set_url_scrape_messaged_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_set_url_scrape_messaged_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."backfill_all_assigned_agents"() TO "anon";
GRANT ALL ON FUNCTION "public"."backfill_all_assigned_agents"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."backfill_all_assigned_agents"() TO "service_role";



GRANT ALL ON FUNCTION "public"."backfill_assigned_agent_for_table"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."backfill_assigned_agent_for_table"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."backfill_assigned_agent_for_table"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."backfill_assigned_agent_single_scrapes"() TO "anon";
GRANT ALL ON FUNCTION "public"."backfill_assigned_agent_single_scrapes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."backfill_assigned_agent_single_scrapes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_session_duration"() TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_session_duration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_session_duration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_assignment_trigger_applied"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_assignment_trigger_applied"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_assignment_trigger_applied"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_overdue_calls"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_overdue_calls"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_overdue_calls"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_upcoming_calls"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_upcoming_calls"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_upcoming_calls"() TO "service_role";



GRANT ALL ON FUNCTION "public"."copy_scrape_notes_to_single_scrapes"() TO "anon";
GRANT ALL ON FUNCTION "public"."copy_scrape_notes_to_single_scrapes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."copy_scrape_notes_to_single_scrapes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_assigned_agent_trigger"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_assigned_agent_trigger"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_assigned_agent_trigger"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_dynamic_table"("table_name" "text", "job_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."create_dynamic_table"("table_name" "text", "job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_dynamic_table"("table_name" "text", "job_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_internal_id_trigger"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_internal_id_trigger"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_internal_id_trigger"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_location_population_trigger"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_location_population_trigger"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_location_population_trigger"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_scrape_results_table"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_scrape_results_table"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_scrape_results_table"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_scrape_results_table"("table_name" "text", "job_id_ref" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."create_scrape_results_table"("table_name" "text", "job_id_ref" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_scrape_results_table"("table_name" "text", "job_id_ref" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."scraper_notifications" TO "anon";
GRANT ALL ON TABLE "public"."scraper_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."scraper_notifications" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_scraper_notification"("p_scraper_id" "uuid", "p_task_id" "uuid", "p_type" "text", "p_title" "text", "p_message" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_scraper_notification"("p_scraper_id" "uuid", "p_task_id" "uuid", "p_type" "text", "p_title" "text", "p_message" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_scraper_notification"("p_scraper_id" "uuid", "p_task_id" "uuid", "p_type" "text", "p_title" "text", "p_message" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_state_distribution_trigger"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_state_distribution_trigger"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_state_distribution_trigger"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_state_listings_table"("state_table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_state_listings_table"("state_table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_state_listings_table"("state_table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_profile_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_profile_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_profile_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_task_delivered_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_task_delivered_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_task_delivered_count"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_task_cascade"("p_task_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_task_cascade"("p_task_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_task_cascade"("p_task_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_task_cascade"("p_task_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."distribute_listing_to_state_table"() TO "anon";
GRANT ALL ON FUNCTION "public"."distribute_listing_to_state_table"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."distribute_listing_to_state_table"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_scraper_task_update_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_scraper_task_update_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_scraper_task_update_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fix_dynamic_table_agent_rls"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fix_dynamic_table_agent_rls"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fix_dynamic_table_agent_rls"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fix_dynamic_table_rls"("table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fix_dynamic_table_rls"("table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fix_dynamic_table_rls"("table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."force_assigned_agent_after_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."force_assigned_agent_after_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."force_assigned_agent_after_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_ical_data"("call_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_ical_data"("call_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_ical_data"("call_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_url_scrape_internal_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_url_scrape_internal_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_url_scrape_internal_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_agent_by_profile_id"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_agent_by_profile_id"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_agent_by_profile_id"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_active_scrape_tables"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_active_scrape_tables"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_active_scrape_tables"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_listing_internal_id"("p_source_table" "text", "p_listing_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_listing_internal_id"("p_source_table" "text", "p_listing_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_listing_internal_id"("p_source_table" "text", "p_listing_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_next_internal_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_next_internal_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_next_internal_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_next_table_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_next_table_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_next_table_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_replacement_request_counts"("p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_replacement_request_counts"("p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_replacement_request_counts"("p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_state_table_name"("state_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_state_table_name"("state_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_state_table_name"("state_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_task_total_leads_in_blocks"("p_task_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_task_total_leads_in_blocks"("p_task_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_task_total_leads_in_blocks"("p_task_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_task_total_value"("p_task_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_task_total_value"("p_task_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_task_total_value"("p_task_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_performance_with_leads"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_performance_with_leads"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_performance_with_leads"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_reschedule_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."increment_reschedule_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_reschedule_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_task_delivered_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."increment_task_delivered_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_task_delivered_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin_or_management"("p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin_or_management"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin_or_management"("p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_scraper"("p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_scraper"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_scraper"("p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_assignment_triggers"() TO "anon";
GRANT ALL ON FUNCTION "public"."list_assignment_triggers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_assignment_triggers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."list_lead_replacement_requests"("p_status" "text", "p_agent_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."list_lead_replacement_requests"("p_status" "text", "p_agent_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_lead_replacement_requests"("p_status" "text", "p_agent_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."log_lead_event_audit"() TO "anon";
GRANT ALL ON FUNCTION "public"."log_lead_event_audit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_lead_event_audit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."maintain_scraper_task_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."maintain_scraper_task_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."maintain_scraper_task_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"() TO "anon";
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_username"("p_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_username"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_username"("p_username" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_agent_assignment_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_agent_assignment_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_agent_assignment_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_agent_call_scheduled"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_agent_call_scheduled"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_agent_call_scheduled"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_agent_new_lead"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_agent_new_lead"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_agent_new_lead"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_agent_replacement_resolution"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_agent_replacement_resolution"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_agent_replacement_resolution"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_scraper_task_assigned"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_scraper_task_assigned"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_scraper_task_assigned"() TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_assigned_agent_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."populate_assigned_agent_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_assigned_agent_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_assigned_to_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."populate_assigned_to_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_assigned_to_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_location_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."populate_location_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_location_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_single_scrape_location_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."populate_single_scrape_location_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_single_scrape_location_data"() TO "service_role";



GRANT ALL ON FUNCTION "public"."propagate_scrape_error"() TO "anon";
GRANT ALL ON FUNCTION "public"."propagate_scrape_error"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."propagate_scrape_error"() TO "service_role";



GRANT ALL ON FUNCTION "public"."register_scrape_table"("p_table_name" "text", "p_job_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."register_scrape_table"("p_table_name" "text", "p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_scrape_table"("p_table_name" "text", "p_job_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."request_lead_replacement"("p_task_lead_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."request_lead_replacement"("p_task_lead_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_lead_replacement"("p_task_lead_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_lead_replacement_request"("p_request_id" "uuid", "p_status" "text", "p_resolution_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_lead_replacement_request"("p_request_id" "uuid", "p_status" "text", "p_resolution_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_lead_replacement_request"("p_request_id" "uuid", "p_status" "text", "p_resolution_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."send_push_notification_on_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."send_push_notification_on_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_push_notification_on_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_agent_push_subscriptions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_agent_push_subscriptions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_agent_push_subscriptions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_fixed_phone_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_fixed_phone_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_fixed_phone_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_scraper_tasks_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_scraper_tasks_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_scraper_tasks_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_single_scrape_messaged_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_single_scrape_messaged_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_single_scrape_messaged_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_agent_task_to_scraper_tasks"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_agent_task_to_scraper_tasks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_agent_task_to_scraper_tasks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_assigned_agent_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_assigned_agent_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_assigned_agent_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_email_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_email_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_email_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_phone_override_to_single_scrapes"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_phone_override_to_single_scrapes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_phone_override_to_single_scrapes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_scheduled_call_to_listing"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_scheduled_call_to_listing"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_scheduled_call_to_listing"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_single_scrape_task"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_single_scrape_task"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_single_scrape_task"() TO "service_role";



GRANT ALL ON FUNCTION "public"."test_assignment_logic"("p_listing_id" "uuid", "table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."test_assignment_logic"("p_listing_id" "uuid", "table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."test_assignment_logic"("p_listing_id" "uuid", "table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_baden_wuerttemberg"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_baden_wuerttemberg"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_baden_wuerttemberg"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_bayern"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_bayern"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_bayern"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_berlin"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_berlin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_berlin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_brandenburg"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_brandenburg"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_brandenburg"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_bremen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_bremen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_bremen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_hamburg"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_hamburg"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_hamburg"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_hessen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_hessen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_hessen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_mecklenburg_vorpommern"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_mecklenburg_vorpommern"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_mecklenburg_vorpommern"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_niedersachsen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_niedersachsen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_niedersachsen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_nordrhein_westfalen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_nordrhein_westfalen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_nordrhein_westfalen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_rheinland_pfalz"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_rheinland_pfalz"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_rheinland_pfalz"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_saarland"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_saarland"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_saarland"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_sachsen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_sachsen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_sachsen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_sachsen_anhalt"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_sachsen_anhalt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_sachsen_anhalt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_schleswig_holstein"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_schleswig_holstein"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_schleswig_holstein"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_affalterbach_ba"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_affalterbach_ba"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_affalterbach_ba"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_baden_w_rttembe"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_baden_w_rttembe"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_baden_w_rttembe"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_bebensee_schles"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_bebensee_schles"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_bebensee_schles"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_500_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_500_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_500_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_4"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_4"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_50_4"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_5_5"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_5_5"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_berlin_5_5"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_2_18"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_2_18"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_2_18"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_4_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_4_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_4_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_10"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_10"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_10"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_11"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_11"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_11"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_12"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_12"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_12"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_8"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_8"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_50_8"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_5_13"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_5_13"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_cologne_5_13"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_daasdorf_a_berg"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_daasdorf_a_berg"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_daasdorf_a_berg"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_6"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_6"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_6"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_7"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_7"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_dusseldorf_50_7"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_fachbach_rheinl"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_fachbach_rheinl"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_fachbach_rheinl"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gablenz_sachsen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gablenz_sachsen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gablenz_sachsen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gaiberg_5_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gaiberg_5_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_gaiberg_5_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_hilden_nordrhei"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_hilden_nordrhei"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_hilden_nordrhei"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_m_nchen_bayern_"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_m_nchen_bayern_"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_m_nchen_bayern_"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_munich_5_4"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_munich_5_4"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_munich_5_4"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_rabenau_hessen_"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_rabenau_hessen_"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_rabenau_hessen_"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_stuttgart_5_14"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_stuttgart_5_14"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_stuttgart_5_14"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_3"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_3"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_3"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_4"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_4"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_10_4"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_apartments_for_sale_wolfach_20_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_all_germany_5"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_all_germany_5"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_all_germany_5"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_frankfurt_50_"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_frankfurt_50_"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_frankfurt_50_"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_m_nchen_bayer"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_m_nchen_bayer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_m_nchen_bayer"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_munich_5_6"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_munich_5_6"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_commercial_properties_munich_5_6"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_2_17"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_2_17"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_2_17"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_50_16"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_50_16"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_all_germany_50_16"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_baden_w_rttemberg_50_15"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_baden_w_rttemberg_50_15"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_baden_w_rttemberg_50_15"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_berlin_50_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_berlin_50_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_berlin_50_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_h_rth_nordrhein_westfalen_50"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_h_rth_nordrhein_westfalen_50"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_custom_h_rth_nordrhein_westfalen_50"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_bayern_2_11"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_bayern_2_11"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_bayern_2_11"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_20_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_20_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_20_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_berlin_50_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_dusseldorf_5_13"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_dusseldorf_5_13"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_dusseldorf_5_13"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_3"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_3"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_3"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_4"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_4"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_m_nchen_bayern_10_4"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_modautal_hessen_5_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_modautal_hessen_5_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_modautal_hessen_5_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_100_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_100_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_100_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_5_5"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_5_5"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_munich_5_5"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_3"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_3"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_houses_for_sale_zeithain_10_3"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_baden_w_rttemberg_5_4"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_baden_w_rttemberg_5_4"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_baden_w_rttemberg_5_4"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_frankfurt_5_3"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_frankfurt_5_3"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_frankfurt_5_3"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_gablenz_sachsen_50_3"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_gablenz_sachsen_50_3"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_land_gardens_gablenz_sachsen_50_3"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_10"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_10"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_10"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_9"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_9"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_baden_w_rttemberg_2_9"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_bayern_10_6"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_bayern_10_6"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_bayern_10_6"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_120_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_120_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_120_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_30_2"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_30_2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_30_2"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_50_1"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_50_1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_berlin_50_1"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_cologne_2_7"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_cologne_2_7"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_cologne_2_7"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_dusseldorf_5_12"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_dusseldorf_5_12"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_dusseldorf_5_12"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_essen_fulerum_nordrhein"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_essen_fulerum_nordrhein"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_essen_fulerum_nordrhein"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_h_rth_nordrhein_westfal"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_h_rth_nordrhein_westfal"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_scrape_real_estate_h_rth_nordrhein_westfal"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_single_scrapes"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_single_scrapes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_single_scrapes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_func_internal_id_thueringen"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_thueringen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_func_internal_id_thueringen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."unarchive_listing"("p_archived_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."unarchive_listing"("p_archived_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unarchive_listing"("p_archived_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_notes_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_notes_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_notes_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_regions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_regions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_regions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_call_overdue_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_call_overdue_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_call_overdue_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_lead_generation_tasks_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_lead_generation_tasks_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_lead_generation_tasks_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_lead_replacement_requests_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_lead_replacement_requests_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_lead_replacement_requests_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_phone_override_from_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_phone_override_from_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_phone_override_from_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_scheduled_calls_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_scheduled_calls_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_scheduled_calls_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_scrape_progress_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_scrape_progress_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_scrape_progress_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_single_scrape_has_phone"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_single_scrape_has_phone"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_single_scrape_has_phone"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_state_table_view_call_policy"("state_table_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_state_table_view_call_policy"("state_table_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_state_table_view_call_policy"("state_table_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_task_delivered_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_task_delivered_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_task_delivered_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_url_scrape_has_phone"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_url_scrape_has_phone"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_url_scrape_has_phone"() TO "service_role";
























GRANT ALL ON TABLE "public"."call_next_actions" TO "anon";
GRANT ALL ON TABLE "public"."call_next_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."call_next_actions" TO "service_role";



GRANT ALL ON TABLE "public"."calls" TO "anon";
GRANT ALL ON TABLE "public"."calls" TO "authenticated";
GRANT ALL ON TABLE "public"."calls" TO "service_role";



GRANT ALL ON TABLE "public"."lead_actions" TO "anon";
GRANT ALL ON TABLE "public"."lead_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_actions" TO "service_role";



GRANT ALL ON TABLE "public"."listings" TO "anon";
GRANT ALL ON TABLE "public"."listings" TO "authenticated";
GRANT ALL ON TABLE "public"."listings" TO "service_role";



GRANT ALL ON TABLE "public"."real_estate_agents" TO "anon";
GRANT ALL ON TABLE "public"."real_estate_agents" TO "authenticated";
GRANT ALL ON TABLE "public"."real_estate_agents" TO "service_role";



GRANT ALL ON TABLE "public"."scheduled_calls" TO "anon";
GRANT ALL ON TABLE "public"."scheduled_calls" TO "authenticated";
GRANT ALL ON TABLE "public"."scheduled_calls" TO "service_role";



GRANT ALL ON TABLE "public"."agent_calendar_events" TO "anon";
GRANT ALL ON TABLE "public"."agent_calendar_events" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_calendar_events" TO "service_role";



GRANT ALL ON TABLE "public"."agent_listing_notes" TO "anon";
GRANT ALL ON TABLE "public"."agent_listing_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_listing_notes" TO "service_role";



GRANT ALL ON TABLE "public"."agent_notes" TO "anon";
GRANT ALL ON TABLE "public"."agent_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_notes" TO "service_role";



GRANT ALL ON TABLE "public"."agent_notifications" TO "anon";
GRANT ALL ON TABLE "public"."agent_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."agent_push_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."agent_push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_push_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."agent_regions_of_activity" TO "anon";
GRANT ALL ON TABLE "public"."agent_regions_of_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_regions_of_activity" TO "service_role";



GRANT ALL ON TABLE "public"."app_config" TO "anon";
GRANT ALL ON TABLE "public"."app_config" TO "authenticated";
GRANT ALL ON TABLE "public"."app_config" TO "service_role";



GRANT ALL ON TABLE "public"."app_versions" TO "anon";
GRANT ALL ON TABLE "public"."app_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."app_versions" TO "service_role";



GRANT ALL ON TABLE "public"."archived_listings" TO "anon";
GRANT ALL ON TABLE "public"."archived_listings" TO "authenticated";
GRANT ALL ON TABLE "public"."archived_listings" TO "service_role";



GRANT ALL ON TABLE "public"."baden_wuerttemberg" TO "anon";
GRANT ALL ON TABLE "public"."baden_wuerttemberg" TO "authenticated";
GRANT ALL ON TABLE "public"."baden_wuerttemberg" TO "service_role";



GRANT ALL ON TABLE "public"."bayern" TO "anon";
GRANT ALL ON TABLE "public"."bayern" TO "authenticated";
GRANT ALL ON TABLE "public"."bayern" TO "service_role";



GRANT ALL ON TABLE "public"."berlin" TO "anon";
GRANT ALL ON TABLE "public"."berlin" TO "authenticated";
GRANT ALL ON TABLE "public"."berlin" TO "service_role";



GRANT ALL ON TABLE "public"."brandenburg" TO "anon";
GRANT ALL ON TABLE "public"."brandenburg" TO "authenticated";
GRANT ALL ON TABLE "public"."brandenburg" TO "service_role";



GRANT ALL ON TABLE "public"."bremen" TO "anon";
GRANT ALL ON TABLE "public"."bremen" TO "authenticated";
GRANT ALL ON TABLE "public"."bremen" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON TABLE "public"."cities" TO "anon";
GRANT ALL ON TABLE "public"."cities" TO "authenticated";
GRANT ALL ON TABLE "public"."cities" TO "service_role";



GRANT ALL ON TABLE "public"."listing_interactions" TO "anon";
GRANT ALL ON TABLE "public"."listing_interactions" TO "authenticated";
GRANT ALL ON TABLE "public"."listing_interactions" TO "service_role";



GRANT ALL ON TABLE "public"."listing_sessions" TO "anon";
GRANT ALL ON TABLE "public"."listing_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."listing_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."daily_activity_metrics" TO "anon";
GRANT ALL ON TABLE "public"."daily_activity_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_activity_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."error_logs" TO "anon";
GRANT ALL ON TABLE "public"."error_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."error_logs" TO "service_role";



GRANT ALL ON TABLE "public"."hamburg" TO "anon";
GRANT ALL ON TABLE "public"."hamburg" TO "authenticated";
GRANT ALL ON TABLE "public"."hamburg" TO "service_role";



GRANT ALL ON TABLE "public"."hessen" TO "anon";
GRANT ALL ON TABLE "public"."hessen" TO "authenticated";
GRANT ALL ON TABLE "public"."hessen" TO "service_role";



GRANT ALL ON TABLE "public"."lead_counter" TO "anon";
GRANT ALL ON TABLE "public"."lead_counter" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_counter" TO "service_role";



GRANT ALL ON TABLE "public"."lead_event_audits" TO "anon";
GRANT ALL ON TABLE "public"."lead_event_audits" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_event_audits" TO "service_role";



GRANT ALL ON TABLE "public"."lead_events" TO "anon";
GRANT ALL ON TABLE "public"."lead_events" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_events" TO "service_role";



GRANT ALL ON TABLE "public"."lead_generation_tasks" TO "anon";
GRANT ALL ON TABLE "public"."lead_generation_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_generation_tasks" TO "service_role";



GRANT ALL ON TABLE "public"."lead_replacement_requests" TO "anon";
GRANT ALL ON TABLE "public"."lead_replacement_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_replacement_requests" TO "service_role";



GRANT ALL ON TABLE "public"."lead_status_changes" TO "anon";
GRANT ALL ON TABLE "public"."lead_status_changes" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_status_changes" TO "service_role";



GRANT ALL ON TABLE "public"."lead_timeline" TO "anon";
GRANT ALL ON TABLE "public"."lead_timeline" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_timeline" TO "service_role";



GRANT ALL ON TABLE "public"."mecklenburg_vorpommern" TO "anon";
GRANT ALL ON TABLE "public"."mecklenburg_vorpommern" TO "authenticated";
GRANT ALL ON TABLE "public"."mecklenburg_vorpommern" TO "service_role";



GRANT ALL ON TABLE "public"."niedersachsen" TO "anon";
GRANT ALL ON TABLE "public"."niedersachsen" TO "authenticated";
GRANT ALL ON TABLE "public"."niedersachsen" TO "service_role";



GRANT ALL ON TABLE "public"."nordrhein_westfalen" TO "anon";
GRANT ALL ON TABLE "public"."nordrhein_westfalen" TO "authenticated";
GRANT ALL ON TABLE "public"."nordrhein_westfalen" TO "service_role";



GRANT ALL ON TABLE "public"."overdue_calls" TO "anon";
GRANT ALL ON TABLE "public"."overdue_calls" TO "authenticated";
GRANT ALL ON TABLE "public"."overdue_calls" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."rheinland_pfalz" TO "anon";
GRANT ALL ON TABLE "public"."rheinland_pfalz" TO "authenticated";
GRANT ALL ON TABLE "public"."rheinland_pfalz" TO "service_role";



GRANT ALL ON TABLE "public"."saarland" TO "anon";
GRANT ALL ON TABLE "public"."saarland" TO "authenticated";
GRANT ALL ON TABLE "public"."saarland" TO "service_role";



GRANT ALL ON TABLE "public"."sachsen" TO "anon";
GRANT ALL ON TABLE "public"."sachsen" TO "authenticated";
GRANT ALL ON TABLE "public"."sachsen" TO "service_role";



GRANT ALL ON TABLE "public"."sachsen_anhalt" TO "anon";
GRANT ALL ON TABLE "public"."sachsen_anhalt" TO "authenticated";
GRANT ALL ON TABLE "public"."sachsen_anhalt" TO "service_role";



GRANT ALL ON TABLE "public"."schleswig_holstein" TO "anon";
GRANT ALL ON TABLE "public"."schleswig_holstein" TO "authenticated";
GRANT ALL ON TABLE "public"."schleswig_holstein" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_jobs" TO "anon";
GRANT ALL ON TABLE "public"."scrape_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_progress" TO "anon";
GRANT ALL ON TABLE "public"."scrape_progress" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_progress" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_real_estate_berlin_120_1" TO "anon";
GRANT ALL ON TABLE "public"."scrape_real_estate_berlin_120_1" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_real_estate_berlin_120_1" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_real_estate_berlin_30_2" TO "anon";
GRANT ALL ON TABLE "public"."scrape_real_estate_berlin_30_2" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_real_estate_berlin_30_2" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" TO "anon";
GRANT ALL ON TABLE "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_real_estate_essen_fulerum_nordrhein_westfalen_20_1" TO "service_role";



GRANT ALL ON TABLE "public"."scrape_tables_registry" TO "anon";
GRANT ALL ON TABLE "public"."scrape_tables_registry" TO "authenticated";
GRANT ALL ON TABLE "public"."scrape_tables_registry" TO "service_role";



GRANT ALL ON TABLE "public"."single_scrapes" TO "anon";
GRANT ALL ON TABLE "public"."single_scrapes" TO "authenticated";
GRANT ALL ON TABLE "public"."single_scrapes" TO "service_role";



GRANT ALL ON TABLE "public"."table_counter" TO "anon";
GRANT ALL ON TABLE "public"."table_counter" TO "authenticated";
GRANT ALL ON TABLE "public"."table_counter" TO "service_role";



GRANT ALL ON TABLE "public"."task_lead_pricing_blocks" TO "anon";
GRANT ALL ON TABLE "public"."task_lead_pricing_blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."task_lead_pricing_blocks" TO "service_role";



GRANT ALL ON TABLE "public"."task_leads" TO "anon";
GRANT ALL ON TABLE "public"."task_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."task_leads" TO "service_role";



GRANT ALL ON TABLE "public"."task_regions" TO "anon";
GRANT ALL ON TABLE "public"."task_regions" TO "authenticated";
GRANT ALL ON TABLE "public"."task_regions" TO "service_role";



GRANT ALL ON TABLE "public"."thueringen" TO "anon";
GRANT ALL ON TABLE "public"."thueringen" TO "authenticated";
GRANT ALL ON TABLE "public"."thueringen" TO "service_role";



GRANT ALL ON TABLE "public"."url_scrape" TO "anon";
GRANT ALL ON TABLE "public"."url_scrape" TO "authenticated";
GRANT ALL ON TABLE "public"."url_scrape" TO "service_role";



GRANT ALL ON TABLE "public"."user_performance_summary" TO "anon";
GRANT ALL ON TABLE "public"."user_performance_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."user_performance_summary" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































