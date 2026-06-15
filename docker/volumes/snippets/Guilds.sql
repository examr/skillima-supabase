-- ================================================================
--  SKILLIMA — Skills icon_url column + Guild Skills Seed (v2)
--
--  STEP 1: ALTER skills table — add icon_url column
--  STEP 2: Insert all skills WITH their icon_url
--  STEP 3: Link skills to guilds (guild_skills)
--
--  Icon source: Devicon CDN (MIT licensed, free to use)
--  Base URL: https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/
--  Pattern:  .../icons/{devicon-name}/{devicon-name}-original.svg
--            .../icons/{devicon-name}/{devicon-name}-plain.svg  (fallback for plain-only icons)
--
--  Guild UUIDs (from your live Supabase database):
--    React Artisans      c4e4c6e8-e2ef-4f04-85c6-250b209adca6
--    Python Wizards      2aec05dd-a57d-44bf-bb64-7621c18e6497
--    Android Hunters     ae18c9d1-4794-4ccf-9e80-2c1922ce87e4
--    iOS Crafters        8728da8b-0676-4cb6-9fb4-6aa4ffbf828a
--    DevOps Warriors     fe142837-997d-44c3-bc88-619603398676
--    Data Alchemists     273ff3f5-7e31-4542-9f4b-531f9171e910
--    Full Stack Heroes   4e3cbd8e-ba9e-42cb-b350-999c23ae7cca
--    Cloud Architects    d945bcac-d654-4ef8-b0eb-2445c8fa84b7
--    Blockchain Pioneers f62a1f5a-b813-469d-bb35-0b571f6e0edc
--    Game Smiths         7517e829-cae7-4280-8f30-2a3957696e7d
--
--  Safe to re-run — ON CONFLICT DO NOTHING on all inserts.
-- ================================================================

BEGIN;

-- ================================================================
-- STEP 1: Add icon_url column to skills table
-- ================================================================

ALTER TABLE public.skills
  ADD COLUMN IF NOT EXISTS icon_url text;

COMMENT ON COLUMN public.skills.icon_url IS
  'CDN URL to the skill icon SVG. Uses Devicon CDN '
  '(https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/). '
  'NULL for skills without a Devicon equivalent.';

-- ================================================================
-- STEP 2: Insert all skills with icon_url
-- ================================================================

INSERT INTO public.skills (name, slug, icon_url) VALUES

  -- ── Web / Frontend ──────────────────────────────────────────────
  ('React.js',              'react-js',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/react/react-original.svg'),
  ('Next.js',               'next-js',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/nextjs/nextjs-original.svg'),
  ('TypeScript',            'typescript',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/typescript/typescript-original.svg'),
  ('JavaScript',            'javascript',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/javascript/javascript-original.svg'),
  ('TailwindCSS',           'tailwindcss',        'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/tailwindcss/tailwindcss-original.svg'),
  ('HTML & CSS',            'html-css',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/html5/html5-original.svg'),
  ('Redux',                 'redux',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/redux/redux-original.svg'),
  ('Vite',                  'vite',               'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/vitejs/vitejs-original.svg'),
  ('React Native',          'react-native',       'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/react/react-original.svg'),
  ('GraphQL',               'graphql',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/graphql/graphql-plain.svg'),

  -- ── Backend / Python ────────────────────────────────────────────
  ('Python',                'python',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/python/python-original.svg'),
  ('Django',                'django',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/django/django-plain.svg'),
  ('Flask',                 'flask',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/flask/flask-original.svg'),
  ('FastAPI',               'fastapi',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/fastapi/fastapi-original.svg'),
  ('REST API Design',       'rest-api-design',    'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/fastapi/fastapi-original.svg'),
  ('Celery',                'celery',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/python/python-original.svg'),
  ('SQLAlchemy',            'sqlalchemy',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/sqlalchemy/sqlalchemy-original.svg'),

  -- ── Android ─────────────────────────────────────────────────────
  ('Kotlin',                'kotlin',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/kotlin/kotlin-original.svg'),
  ('Jetpack Compose',       'jetpack-compose',    'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/jetpackcompose/jetpackcompose-original.svg'),
  ('Android SDK',           'android-sdk',        'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/android/android-original.svg'),
  ('MVVM Architecture',     'mvvm-architecture',  'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/android/android-original.svg'),
  ('Retrofit',              'retrofit',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/kotlin/kotlin-original.svg'),
  ('Room Database',         'room-database',      'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/android/android-original.svg'),
  ('Coroutines & Flow',     'coroutines-flow',    'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/kotlin/kotlin-original.svg'),
  ('Hilt / Koin',           'hilt-koin',          'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/kotlin/kotlin-original.svg'),

  -- ── iOS ─────────────────────────────────────────────────────────
  ('Swift',                 'swift',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/swift/swift-original.svg'),
  ('SwiftUI',               'swiftui',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/swift/swift-original.svg'),
  ('UIKit',                 'uikit',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/swift/swift-original.svg'),
  ('Combine',               'combine',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/swift/swift-original.svg'),
  ('Core Data',             'core-data',          'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/apple/apple-original.svg'),
  ('XCTest',                'xctest',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/xcode/xcode-original.svg'),

  -- ── DevOps ──────────────────────────────────────────────────────
  ('Docker',                'docker',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/docker/docker-original.svg'),
  ('Kubernetes',            'kubernetes',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/kubernetes/kubernetes-original.svg'),
  ('CI/CD',                 'ci-cd',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/githubactions/githubactions-original.svg'),
  ('GitHub Actions',        'github-actions',     'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/githubactions/githubactions-original.svg'),
  ('Terraform',             'terraform',          'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/terraform/terraform-original.svg'),
  ('Ansible',               'ansible',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/ansible/ansible-original.svg'),
  ('Linux',                 'linux',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/linux/linux-original.svg'),
  ('Nginx',                 'nginx',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/nginx/nginx-original.svg'),
  ('Prometheus & Grafana',  'prometheus-grafana', 'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/prometheus/prometheus-original.svg'),

  -- ── Data / ML / AI ──────────────────────────────────────────────
  ('Machine Learning',      'machine-learning',   'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/python/python-original.svg'),
  ('Deep Learning',         'deep-learning',      'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/pytorch/pytorch-original.svg'),
  ('Data Engineering',      'data-engineering',   'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/apacheairflow/apacheairflow-original.svg'),
  ('Pandas',                'pandas',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/pandas/pandas-original.svg'),
  ('NumPy',                 'numpy',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/numpy/numpy-original.svg'),
  ('Scikit-learn',          'scikit-learn',       'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/scikitlearn/scikitlearn-original.svg'),
  ('TensorFlow',            'tensorflow',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/tensorflow/tensorflow-original.svg'),
  ('PyTorch',               'pytorch',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/pytorch/pytorch-original.svg'),
  ('Apache Spark',          'apache-spark',       'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/apachespark/apachespark-original.svg'),
  ('Airflow',               'airflow',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/apacheairflow/apacheairflow-original.svg'),
  ('SQL',                   'sql',                'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/postgresql/postgresql-original.svg'),

  -- ── Full Stack ───────────────────────────────────────────────────
  ('Node.js',               'node-js',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/nodejs/nodejs-original.svg'),
  ('Express.js',            'express-js',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/express/express-original.svg'),
  ('MongoDB',               'mongodb',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/mongodb/mongodb-original.svg'),
  ('PostgreSQL',            'postgresql',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/postgresql/postgresql-original.svg'),
  ('Redis',                 'redis',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/redis/redis-original.svg'),
  ('NestJS',                'nestjs',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/nestjs/nestjs-original.svg'),

  -- ── Cloud ────────────────────────────────────────────────────────
  ('AWS',                   'aws',                'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/amazonwebservices/amazonwebservices-original-wordmark.svg'),
  ('Google Cloud Platform', 'gcp',                'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/googlecloud/googlecloud-original.svg'),
  ('Microsoft Azure',       'azure',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/azure/azure-original.svg'),
  ('Serverless',            'serverless',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/amazonwebservices/amazonwebservices-original-wordmark.svg'),
  ('CDN & Networking',      'cdn-networking',     'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/nginx/nginx-original.svg'),

  -- ── Blockchain / Web3 ────────────────────────────────────────────
  ('Solidity',              'solidity',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/solidity/solidity-original.svg'),
  ('Ethereum',              'ethereum',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/ethereum/ethereum-original.svg'),
  ('Web3.js',               'web3-js',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/web3js/web3js-original.svg'),
  ('Hardhat',               'hardhat',            'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/solidity/solidity-original.svg'),
  ('Smart Contracts',       'smart-contracts',    'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/solidity/solidity-original.svg'),
  ('IPFS',                  'ipfs',               'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/solidity/solidity-original.svg'),

  -- ── Game Dev ─────────────────────────────────────────────────────
  ('Unity',                 'unity',              'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/unity/unity-original.svg'),
  ('Unreal Engine',         'unreal-engine',      'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/unrealengine/unrealengine-original.svg'),
  ('C#',                    'csharp',             'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/csharp/csharp-original.svg'),
  ('C++',                   'cpp',                'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/cplusplus/cplusplus-original.svg'),
  ('Game Physics',          'game-physics',       'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/unity/unity-original.svg'),
  ('Shader Programming',    'shader-programming', 'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/opengl/opengl-original.svg'),

  -- ── Cross-guild (shared) ─────────────────────────────────────────
  ('Git & GitHub',          'git-github',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/github/github-original.svg'),
  ('System Design',         'system-design',      'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/linux/linux-original.svg'),
  ('Testing & QA',          'testing-qa',         'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/jest/jest-plain.svg'),
  ('Supabase',              'supabase',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/supabase/supabase-original.svg'),
  ('Firebase',              'firebase',           'https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/firebase/firebase-original.svg')

ON CONFLICT (slug) DO UPDATE
  SET icon_url = EXCLUDED.icon_url;
-- ON CONFLICT: updates icon_url even if skill already exists from a previous seed run

-- ================================================================
-- STEP 3: Link skills to guilds
-- ================================================================

WITH s AS (
  SELECT id, slug FROM public.skills
)
INSERT INTO public.guild_skills (guild_id, skill_id)
SELECT g.guild_id::uuid, s.id
FROM (VALUES
  -- React Artisans
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'react-js'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'next-js'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'typescript'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'javascript'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'tailwindcss'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'html-css'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'redux'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'react-native'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'graphql'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'git-github'),
  ('4ca1b8ef-4690-407a-8308-7ddaf96e76e3', 'testing-qa'),

  -- Python Wizards
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'python'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'django'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'flask'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'fastapi'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'rest-api-design'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'celery'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'sqlalchemy'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'postgresql'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'redis'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'sql'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'git-github'),
  ('f4571470-2d72-4c3f-9fd1-f2d35baaaf4e', 'testing-qa'),

  -- Android Hunters
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'kotlin'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'jetpack-compose'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'android-sdk'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'mvvm-architecture'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'retrofit'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'room-database'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'coroutines-flow'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'hilt-koin'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'firebase'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'git-github'),
  ('815ce5ff-3b93-4eac-8784-bbdb6a6e6f26', 'testing-qa'),

  -- iOS Crafters
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'swift'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'swiftui'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'uikit'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'combine'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'core-data'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'xctest'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'firebase'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'git-github'),
  ('0a19a7c2-1fea-4148-847a-5eeef7a6bedf', 'testing-qa'),

  -- DevOps Warriors
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'docker'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'kubernetes'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'ci-cd'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'github-actions'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'terraform'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'ansible'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'linux'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'nginx'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'prometheus-grafana'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'aws'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'python'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'git-github'),
  ('08a155ae-4b4d-44e6-8042-edbf816939b0', 'system-design'),

  -- Data Alchemists
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'machine-learning'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'deep-learning'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'data-engineering'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'pandas'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'numpy'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'scikit-learn'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'tensorflow'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'pytorch'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'apache-spark'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'airflow'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'python'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'sql'),
  ('be83a108-9559-4f6c-a77b-b01239d69c21', 'git-github'),

  -- Full Stack Heroes
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'node-js'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'express-js'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'react-js'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'next-js'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'typescript'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'mongodb'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'postgresql'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'redis'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'nestjs'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'graphql'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'rest-api-design'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'docker'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'git-github'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'system-design'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'testing-qa'),
  ('62506b21-fa36-4cb0-b395-4f707237dc4e', 'supabase'),

  -- Cloud Architects
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'aws'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'gcp'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'azure'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'terraform'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'kubernetes'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'docker'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'serverless'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'cdn-networking'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'ci-cd'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'linux'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'prometheus-grafana'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'system-design'),
  ('281f3fff-21cd-48d2-bbbd-635fcc643922', 'git-github'),

  -- Blockchain Pioneers
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'solidity'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'ethereum'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'web3-js'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'hardhat'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'smart-contracts'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'ipfs'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'javascript'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'typescript'),
  ('66b09f90-1c41-4ff6-8497-a6d0043e7284', 'git-github'),

  -- Game Smiths
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'unity'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'unreal-engine'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'csharp'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'cpp'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'game-physics'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'shader-programming'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'git-github'),
  ('2f187ed9-a201-41f8-9439-d6d646923ab9', 'testing-qa')

) AS g(guild_id, skill_slug)
JOIN s ON s.slug = g.skill_slug
ON CONFLICT DO NOTHING;

COMMIT;

-- ================================================================
-- VERIFICATION — uncomment and run to confirm
-- ================================================================
-- SELECT gu.name AS guild, COUNT(gs.skill_id) AS skill_count
-- FROM public.guilds gu
-- LEFT JOIN public.guild_skills gs ON gs.guild_id = gu.id
-- GROUP BY gu.name ORDER BY gu.name;

-- SELECT name, slug, icon_url FROM public.skills ORDER BY name;
-- ================================================================

SELECT id, name, icon_url FROM public.guilds ORDER BY name;