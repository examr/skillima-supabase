INSERT INTO projects (
    id, mentor_id, guild_id, title, slug, description, difficulty,
    estimated_weeks, price_paise, original_price_paise, is_app_sponsored,
    learning_outcomes, prerequisites, tech_stack, status,
    enrollment_count, average_rating, review_count, logo_url
) VALUES
(
    gen_random_uuid(), '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8', NULL,
    'Build a fintech mobile app',
    'build-a-fintech-mobile-app',
    'Design and develop a cross-platform mobile app for personal finance tracking with real-time data sync.',
    'intermediate', 4,
    3600000, 4500000, false,
    ARRAY['Kotlin', 'Jetpack Compose', 'Firebase'],
    ARRAY['Basic Android', 'Kotlin basics'],
    ARRAY['Kotlin', 'Firebase', 'Compose'],
    'published', 320, 4.8, 124,
    'https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Amazon_logo.svg/1200px-Amazon_logo.svg.png'
),
(
    gen_random_uuid(), '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8', NULL,
    'E-commerce website redesign',
    'e-commerce-website-redesign',
    'Redesign an existing e-commerce platform with a modern UI, improved UX flows, and faster checkout.',
    'beginner', 6,
    2200000, 2800000, false,
    ARRAY['Figma', 'UI/UX', 'Prototyping'],
    ARRAY['Basic design sense', 'Figma basics'],
    ARRAY['Figma', 'React', 'Tailwind'],
    'published', 210, 4.6, 87,
    'https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Google_2015_logo.svg/1200px-Google_2015_logo.svg.png'
),
(
    gen_random_uuid(), '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8', NULL,
    'ML model for stock prediction',
    'ml-model-for-stock-prediction',
    'Build and train a machine learning model to predict stock prices using historical data and LSTM networks.',
    'advanced', 8,
    5400000, 7000000, false,
    ARRAY['Python', 'TensorFlow', 'LSTM'],
    ARRAY['Python', 'Basic ML concepts'],
    ARRAY['Python', 'TensorFlow', 'Pandas'],
    'published', 180, 4.9, 203,
    'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/1200px-Microsoft_logo.svg.png'
),
(
    gen_random_uuid(), '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8', NULL,
    'Social media dashboard',
    'social-media-dashboard',
    'Create a unified social media analytics dashboard that aggregates data from multiple platforms in real time.',
    'intermediate', 5,
    1800000, 2400000, false,
    ARRAY['React', 'Chart.js', 'REST APIs'],
    ARRAY['JavaScript', 'Basic React'],
    ARRAY['React', 'Node.js', 'Chart.js'],
    'published', 145, 4.5, 65,
    'https://upload.wikimedia.org/wikipedia/commons/thumb/0/08/Netflix_2015_logo.svg/1200px-Netflix_2015_logo.svg.png'
);