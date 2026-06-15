    INSERT INTO admin_totp (user_id, secret, verified)
    VALUES ('1e5fc727-66da-44aa-9610-30f5b034f09f', 'dfd9b8c8e069322cc6276989835174eb:86aa4bed043585341d1a169589b2bfc99ec3f8fb6c65bfdb69540813a3c3ad87', true)

    ON CONFLICT (user_id) DO UPDATE SET secret = EXCLUDED.secret, verified = true;