CREATE OR REPLACE FUNCTION public.check_auth_user()
RETURNS trigger AS $$
BEGIN
  -- Prevent email-only signups (users must use Google or Phone Auth)
  IF NEW.raw_app_meta_data->>'provider' = 'email' THEN
    RAISE EXCEPTION 'Email-only signups are not allowed.';
  END IF;
  
  -- If using Phone Auth, Supabase sets NEW.phone.
  -- If using Google Auth, we allow it (phone is collected later in phone_setup_screen).
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS check_auth_user_trigger ON auth.users;
CREATE TRIGGER check_auth_user_trigger
BEFORE INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.check_auth_user();

-- Add a constraint to ensure profiles always have a phone number
ALTER TABLE public.profiles
ADD CONSTRAINT profiles_phone_check 
CHECK (phone_e164 IS NOT NULL AND phone_e164 <> '');
