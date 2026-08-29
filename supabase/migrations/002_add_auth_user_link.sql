-- Qtoof_QT_online
-- Migration: 002_add_auth_user_link.sql
-- Purpose: connect a Supabase Auth user to the existing public.users row.
-- Safe to run more than once. No tables or data are deleted.

alter table public.users
  add column if not exists auth_user_id uuid;

create unique index if not exists users_auth_user_id_uidx
  on public.users (auth_user_id)
  where auth_user_id is not null;
