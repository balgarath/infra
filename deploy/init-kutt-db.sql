-- Creates the kutt database and user for fresh Postgres deployments.
-- This script runs via /docker-entrypoint-initdb.d/ on first Postgres boot only.
-- For existing deployments, use the migration commands in gcloud-setup.sh.

CREATE USER kutt WITH PASSWORD 'kutt';
CREATE DATABASE kutt OWNER kutt;
