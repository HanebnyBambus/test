-- Secure the chat behind an explicit membership allow-list.
-- Existing Auth users are approved during the migration; new users must be
-- inserted into public.chat_members by an administrator.

create table public.chat_members (
    user_id uuid primary key references auth.users(id) on delete cascade,
    approved_at timestamptz not null default now()
);

alter table public.chat_members enable row level security;

insert into public.chat_members (user_id)
select id
from auth.users
on conflict (user_id) do nothing;

-- Normalize the existing schema before adding foreign keys and constraints.
alter table public.messages
    alter column user_id set not null,
    alter column nickname set not null,
    alter column message set not null,
    alter column created_at set not null,
    drop constraint messages_pkey,
    add constraint messages_pkey primary key (id),
    add constraint messages_message_length_check
        check (char_length(btrim(message)) between 1 and 500),
    add constraint messages_nickname_length_check
        check (char_length(btrim(nickname)) between 1 and 30);

alter table public.profiles
    alter column nickname set not null,
    add constraint profiles_nickname_length_check
        check (char_length(btrim(nickname)) between 1 and 30),
    add constraint profiles_status_length_check
        check (status is null or char_length(status) <= 20);

alter table public.reactions
    alter column message_id set not null,
    alter column user_id set not null,
    alter column emoji set not null,
    add constraint reactions_message_id_fkey
        foreign key (message_id) references public.messages(id) on delete cascade,
    add constraint reactions_user_id_fkey
        foreign key (user_id) references auth.users(id) on delete cascade,
    add constraint reactions_user_message_emoji_key
        unique (message_id, user_id, emoji),
    add constraint reactions_emoji_check
        check (emoji in ('👍', '👎', '😂', '❤️', '🔥', '💩', '🎉'));

create index messages_user_id_idx on public.messages (user_id);
create index messages_created_at_idx on public.messages (created_at desc);
create index reactions_message_id_idx on public.reactions (message_id);
create index reactions_user_id_idx on public.reactions (user_id);

-- The database, not the browser, is the source of truth for authorship.
create or replace function public.set_message_author()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
    new.user_id := (select auth.uid());

    select profile.nickname
    into new.nickname
    from public.profiles as profile
    where profile.id = (select auth.uid());

    if new.nickname is null then
        raise exception 'A profile is required before sending messages';
    end if;

    return new;
end;
$$;

create trigger messages_set_author
before insert on public.messages
for each row execute function public.set_message_author();

create or replace function public.set_reaction_author()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
    new.user_id := (select auth.uid());
    return new;
end;
$$;

create trigger reactions_set_author
before insert on public.reactions
for each row execute function public.set_reaction_author();

revoke all on function public.set_message_author() from public, anon, authenticated;
revoke all on function public.set_reaction_author() from public, anon, authenticated;

-- Remove the duplicated and overly broad policies currently in the project.
do $$
declare
    policy_record record;
begin
    for policy_record in
        select schemaname, tablename, policyname
        from pg_policies
        where schemaname = 'public'
          and tablename in ('chat_members', 'messages', 'profiles', 'reactions')
    loop
        execute format(
            'drop policy %I on %I.%I',
            policy_record.policyname,
            policy_record.schemaname,
            policy_record.tablename
        );
    end loop;
end;
$$;

create policy "Members can read own membership"
on public.chat_members for select
to authenticated
using (user_id = (select auth.uid()));

create policy "Users can create own profile"
on public.profiles for insert
to authenticated
with check (id = (select auth.uid()));

create policy "Users can read own profile or member profiles"
on public.profiles for select
to authenticated
using (
    id = (select auth.uid())
    or exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Users can update own profile"
on public.profiles for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy "Members can read messages"
on public.messages for select
to authenticated
using (
    exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Members can send own messages"
on public.messages for insert
to authenticated
with check (
    user_id = (select auth.uid())
    and exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Members can update own messages"
on public.messages for update
to authenticated
using (
    user_id = (select auth.uid())
    and exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
)
with check (
    user_id = (select auth.uid())
    and exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Members can delete own messages"
on public.messages for delete
to authenticated
using (
    user_id = (select auth.uid())
    and exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Members can read reactions"
on public.reactions for select
to authenticated
using (
    exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Members can add own reactions"
on public.reactions for insert
to authenticated
with check (
    user_id = (select auth.uid())
    and exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

create policy "Members can remove own reactions"
on public.reactions for delete
to authenticated
using (
    user_id = (select auth.uid())
    and exists (
        select 1
        from public.chat_members as member
        where member.user_id = (select auth.uid())
    )
);

-- Replace broad default privileges with the smallest set used by the client.
revoke all on public.chat_members, public.messages, public.profiles, public.reactions
from anon, authenticated;

grant select (user_id) on public.chat_members to authenticated;

grant select on public.profiles to authenticated;
grant insert (id, nickname) on public.profiles to authenticated;
grant update (nickname, color, status) on public.profiles to authenticated;

grant select, delete on public.messages to authenticated;
-- Keep the legacy author columns writable during the GitHub Pages rollout.
-- The trigger overwrites both values, so the browser still cannot spoof them.
grant insert (message, user_id, nickname) on public.messages to authenticated;
grant update (message, is_edited) on public.messages to authenticated;

grant select, delete on public.reactions to authenticated;
grant insert (message_id, user_id, emoji) on public.reactions to authenticated;

grant usage, select on sequence public.messages_id_seq to authenticated;
grant usage, select on sequence public.reactions_id_seq to authenticated;
