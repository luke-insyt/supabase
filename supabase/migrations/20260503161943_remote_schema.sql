


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


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  INSERT INTO public.users (id, email, username, display_name, profile_image_url)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data ->> 'username',
    NEW.raw_user_meta_data ->> 'display_name',
    NEW.raw_user_meta_data ->> 'profile_image_url'
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."agreement_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" character varying NOT NULL,
    "title" character varying NOT NULL,
    "url" character varying NOT NULL,
    "effective_date" "date" NOT NULL,
    "is_current" boolean DEFAULT false,
    "changelog" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agreement_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "email" character varying NOT NULL,
    "username" character varying,
    "display_name" character varying,
    "profile_image_url" character varying,
    "bio" "text",
    "organization" character varying,
    "organization_type" "text",
    "role" "text" DEFAULT 'user'::"text" NOT NULL,
    "is_creator" boolean DEFAULT false,
    "creator_terms_accepted_at" timestamp with time zone,
    "creator_activated_at" timestamp with time zone,
    "credentials" "text",
    "experience_years" integer,
    "specializations" "text"[],
    "subscription_price_usd" integer,
    "stripe_subscription_price_id" character varying,
    "is_verified" boolean DEFAULT false,
    "stripe_customer_id" character varying,
    "stripe_connect_id" character varying,
    "stripe_connect_onboarded" boolean DEFAULT false,
    "follower_count" integer DEFAULT 0,
    "following_count" integer DEFAULT 0,
    "report_count" integer DEFAULT 0,
    "total_earnings_usd" integer DEFAULT 0,
    "reports_purchased_count" integer DEFAULT 0,
    "last_logged_in_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "auth_user_id" "uuid",
    "agreement_version" character varying,
    "signature_name" character varying,
    "signature_ip" character varying,
    "signed_at" timestamp with time zone,
    CONSTRAINT "users_organization_type_check" CHECK (("organization_type" = ANY (ARRAY['club'::"text", 'agency'::"text", 'media'::"text", 'personal'::"text"]))),
    CONSTRAINT "users_role_check" CHECK (("role" = ANY (ARRAY['user'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."author_profiles" AS
 SELECT "email",
    "display_name",
    "bio"
   FROM "public"."users";


ALTER VIEW "public"."author_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."insyts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" character varying(150) NOT NULL,
    "abstract" "text" NOT NULL,
    "content_type" character varying,
    "sport" character varying DEFAULT 'soccer'::character varying,
    "storage_path" character varying,
    "video_url" character varying,
    "thumbnail_url" character varying,
    "price_eur" integer NOT NULL,
    "stripe_product_id" character varying,
    "stripe_price_id" character varying,
    "stripe_payment_link_url" character varying,
    "stripe_payment_link_id" character varying,
    "webflow_item_id" character varying,
    "status" character varying DEFAULT 'review'::character varying,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "creator_email" character varying,
    "insyt_id" character varying,
    "body_text" "text",
    "tags" "text"[],
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_hidden" boolean DEFAULT false
);


ALTER TABLE "public"."insyts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchases" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "buyer_email" "text",
    "insyt_id" "text",
    "amount_paid" bigint,
    "stripe_session_id" "text",
    "insyt_link" "text",
    "payment_status" "text",
    "stripe_blob" json,
    "creator_email" character varying,
    "purchased_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."purchases" OWNER TO "postgres";


ALTER TABLE "public"."purchases" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."purchases_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."agreement_versions"
    ADD CONSTRAINT "agreement_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agreement_versions"
    ADD CONSTRAINT "agreement_versions_version_key" UNIQUE ("version");



ALTER TABLE ONLY "public"."insyts"
    ADD CONSTRAINT "insyts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_auth_user_id_key" UNIQUE ("auth_user_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Creators read own insyts" ON "public"."insyts" FOR SELECT USING ((("creator_email")::"text" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "Public read" ON "public"."agreement_versions" FOR SELECT USING (true);



CREATE POLICY "Public read published" ON "public"."insyts" FOR SELECT USING ((("status")::"text" = 'published'::"text"));



CREATE POLICY "Service insert" ON "public"."insyts" FOR INSERT WITH CHECK (true);



CREATE POLICY "Users read own" ON "public"."users" FOR SELECT USING (("auth"."uid"() = "auth_user_id"));



CREATE POLICY "Users update own" ON "public"."users" FOR UPDATE USING (("auth"."uid"() = "auth_user_id"));



ALTER TABLE "public"."agreement_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "buyers_check_own_purchases" ON "public"."purchases" FOR SELECT USING (("buyer_email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "buyers_read_own_purchases" ON "public"."purchases" FOR SELECT USING (("buyer_email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "buyers_read_purchased_insyts" ON "public"."insyts" FOR SELECT USING (((("status")::"text" = 'live'::"text") OR (("creator_email")::"text" = ("auth"."jwt"() ->> 'email'::"text"))));



CREATE POLICY "creators_read_own_sales" ON "public"."purchases" FOR SELECT USING ((("creator_email")::"text" = ("auth"."jwt"() ->> 'email'::"text")));



ALTER TABLE "public"."insyts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."purchases" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_insert_own" ON "public"."users" FOR INSERT WITH CHECK (("auth"."uid"() = "auth_user_id"));



ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_update_own" ON "public"."users" FOR UPDATE USING (("auth_user_id" = "auth"."uid"()));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";


















GRANT ALL ON TABLE "public"."agreement_versions" TO "anon";
GRANT ALL ON TABLE "public"."agreement_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."agreement_versions" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."author_profiles" TO "anon";
GRANT ALL ON TABLE "public"."author_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."author_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."insyts" TO "anon";
GRANT ALL ON TABLE "public"."insyts" TO "authenticated";
GRANT ALL ON TABLE "public"."insyts" TO "service_role";



GRANT ALL ON TABLE "public"."purchases" TO "anon";
GRANT ALL ON TABLE "public"."purchases" TO "authenticated";
GRANT ALL ON TABLE "public"."purchases" TO "service_role";



GRANT ALL ON SEQUENCE "public"."purchases_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."purchases_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."purchases_id_seq" TO "service_role";









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































drop extension if exists "pg_net";

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


  create policy "Anyone can view avatars 1oj01fe_0"
  on "storage"."objects"
  as permissive
  for select
  to public
using (true);



  create policy "Users can delete their own avatar 1oj01fe_0"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can delete their own avatar 1oj01fe_1"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can update their own avatar 1oj01fe_0"
  on "storage"."objects"
  as permissive
  for update
  to authenticated
using (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can update their own avatar 1oj01fe_1"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can upload their own avatar 1oj01fe_0"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "public_read_thumbnails"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'insyts-thumbnails'::text));



