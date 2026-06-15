INSERT INTO projects (
    mentor_id,
    guild_id,
    title,
    slug,
    description,
    difficulty,
    estimated_weeks,
    price_paise,
    is_app_sponsored,
    learning_outcomes,
    prerequisites,
    tech_stack,
    status,
    enrollment_count,
    average_rating,
    original_price_paise,
    review_count,
    logo_url,
    image_urls,
    estimated_hours,
    team_size
)
VALUES

-- AI Chat Assistant (Python Wizards)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    'f4571470-2d72-4c3f-9fd1-f2d35baaaf4e',
    'AI Chat Assistant',
    'ai-chat-assistant',
    'Build a ChatGPT-style Android application with streaming AI responses and chat history.',
    'advanced',
    4,
    799000,
    true,
    ARRAY['LLM Integration','Prompt Engineering','Streaming Responses'],
    ARRAY['Android Basics','REST APIs'],
    ARRAY['Kotlin','Compose','OpenAI API','Supabase'],
    'published',
    245,
    4.9,
    999000,
    68,
    'https://images.unsplash.com/photo-1677442136019-21780ecad995',
    ARRAY[
        'https://images.unsplash.com/photo-1676299081847-824916de030a',
        'https://images.unsplash.com/photo-1675557009875-436f8e4d2df0'
    ],
    35,
    3
),

-- Food Delivery App (Full Stack Heroes)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    '62506b21-fa36-4cb0-b395-4f707237dc4e',
    'Food Delivery App',
    'food-delivery-app',
    'Swiggy-inspired food delivery application with live order tracking.',
    'intermediate',
    3,
    599000,
    false,
    ARRAY['Location Tracking','Realtime Orders','Cart Management'],
    ARRAY['Android Basics'],
    ARRAY['Compose','Firebase','Google Maps'],
    'published',
    187,
    4.7,
    799000,
    44,
    'https://images.unsplash.com/photo-1504674900247-0877df9cc836',
    ARRAY[
        'https://images.unsplash.com/photo-1498837167922-ddd27525d352',
        'https://images.unsplash.com/photo-1565299624946-b28f40a0ae38'
    ],
    28,
    4
),

-- Netflix Clone (Cloud Architects)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    '281f3fff-21cd-48d2-bbbd-635fcc643922',
    'Netflix Clone',
    'netflix-clone',
    'OTT streaming application with authentication, watchlists and video playback.',
    'expert',
    4,
    749000,
    true,
    ARRAY['Video Streaming','Authentication','Backend Integration'],
    ARRAY['Networking','Android Basics'],
    ARRAY['Compose','Supabase','ExoPlayer'],
    'published',
    201,
    4.9,
    949000,
    56,
    'https://images.unsplash.com/photo-1574375927938-d5a98e8ffe85',
    ARRAY[
        'https://images.unsplash.com/photo-1522869635100-9f4c5e86aa37',
        'https://images.unsplash.com/photo-1489599849927-2ee91cede3ba'
    ],
    40,
    4
),

-- Customer Churn Predictor (Data Alchemists)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    'be83a108-9559-4f6c-a77b-b01239d69c21',
    'Customer Churn Predictor',
    'customer-churn-predictor',
    'Machine learning project that predicts customer churn using historical business data.',
    'advanced',
    5,
    899000,
    true,
    ARRAY['Classification Models','Feature Engineering','Model Evaluation'],
    ARRAY['Python Basics','Machine Learning Fundamentals'],
    ARRAY['Python','Scikit-Learn','Pandas'],
    'published',
    143,
    4.8,
    1099000,
    29,
    'https://images.unsplash.com/photo-1551288049-bebda4e38f71',
    ARRAY[
        'https://images.unsplash.com/photo-1460925895917-afdab827c52f',
        'https://images.unsplash.com/photo-1551434678-e076c223a692'
    ],
    45,
    2
),

-- Kubernetes CI/CD Platform (DevOps Warriors)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    '08a155ae-4b4d-44e6-8042-edbf816939b0',
    'Kubernetes CI/CD Platform',
    'kubernetes-cicd-platform',
    'Automated deployment platform using Kubernetes, Docker and GitHub Actions.',
    'expert',
    6,
    1199000,
    true,
    ARRAY['Kubernetes','CI/CD','Cloud Deployment'],
    ARRAY['Docker Basics','Linux Fundamentals'],
    ARRAY['Kubernetes','Docker','GitHub Actions','AWS'],
    'published',
    98,
    4.9,
    1499000,
    21,
    'https://images.unsplash.com/photo-1451187580459-43490279c0fa',
    ARRAY[
        'https://images.unsplash.com/photo-1516321318423-f06f85e504b3',
        'https://images.unsplash.com/photo-1558494949-ef010cbdcc31'
    ],
    60,
    3
),

-- Multiplayer Chess Game (Game Smiths)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    '2f187ed9-a201-41f8-9439-d6d646923ab9',
    'Multiplayer Chess Game',
    'multiplayer-chess-game',
    'Realtime multiplayer chess game with matchmaking and rankings.',
    'advanced',
    4,
    699000,
    false,
    ARRAY['Realtime Multiplayer','Game Logic','Matchmaking'],
    ARRAY['Programming Basics'],
    ARRAY['Unity','Firebase','C#'],
    'published',
    165,
    4.8,
    899000,
    34,
    'https://images.unsplash.com/photo-1529699211952-734e80c4d42b',
    ARRAY[
        'https://images.unsplash.com/photo-1518546305927-5a555bb7020d',
        'https://images.unsplash.com/photo-1580541832626-2a7131ee809f'
    ],
    38,
    2
),

-- Airbnb Clone (React Artisans)
(
    '2b8926c5-62b3-4b18-8ea9-99ea5f372ec8',
    '4ca1b8ef-4690-407a-8308-7ddaf96e76e3',
    'Airbnb Clone',
    'airbnb-clone',
    'Full-featured property booking platform inspired by Airbnb.',
    'advanced',
    5,
    849000,
    true,
    ARRAY['Authentication','Booking System','Maps Integration'],
    ARRAY['React Basics','JavaScript Fundamentals'],
    ARRAY['React','Next.js','Supabase'],
    'published',
    178,
    4.8,
    1099000,
    42,
    'https://images.unsplash.com/photo-1566073771259-6a8506099945',
    ARRAY[
        'https://images.unsplash.com/photo-1505693416388-ac5ce068fe85',
        'https://images.unsplash.com/photo-1522708323590-d24dbb6b0267'
    ],
    42,
    3
);