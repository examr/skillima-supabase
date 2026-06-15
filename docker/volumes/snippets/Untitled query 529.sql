SELECT 
  trigger_name,
  event_manipulation,
  event_object_schema,
  event_object_table,
  action_statement
FROM information_schema.triggers
WHERE event_object_schema IN ('public', 'auth')
ORDER BY event_object_table;

SELECT prosrc FROM pg_proc WHERE proname = 'handle_new_user';

-- Check what raw_user_meta_data actually looked like for your test user
SELECT 
  id,
  email,
  raw_user_meta_data,
  created_at
FROM auth.users
ORDER BY created_at DESC
LIMIT 5;


-- Confirm the duplicate
SELECT 
  p.id,
  p.email,
  p.role,
  p.status,
  sp.user_id IS NOT NULL AS has_student_profile,
  mp.user_id IS NOT NULL AS has_mentor_profile
FROM public.profiles p
LEFT JOIN public.student_profiles sp ON sp.user_id = p.id
LEFT JOIN public.mentor_profiles mp ON mp.user_id = p.id
WHERE sp.user_id IS NOT NULL AND mp.user_id IS NOT NULL;


SELECT 
  proname,
  prosrc
FROM pg_proc
WHERE prosrc ILIKE '%mentor_profiles%';

SELECT 
  trigger_name,
  event_manipulation,
  action_statement,
  action_timing
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table = 'profiles';
  