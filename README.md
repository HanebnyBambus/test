# Krsmol 2027 chat

Malý soukromý chat postavený jako statická GitHub Pages stránka se Supabase Auth, databází, Presence a Realtime.

## Bezpečnostní model

- Ve zdrojovém kódu není společné heslo místnosti.
- Do chatu se dostanou pouze přihlášení uživatelé uvedení v `public.chat_members`.
- Nově registrovaný účet čeká na schválení správce.
- RLS pravidla povolují úpravu a smazání pouze vlastních zpráv a reakcí.
- Autor zprávy a reakce se doplňuje v databázi, ne z hodnoty zaslané prohlížečem.
- Text zpráv se vykresluje jako textové uzly, takže nemůže spustit vložené HTML nebo JavaScript.

## Nasazení

Databázovou migraci je potřeba nasadit před novou verzí `index.html`:

```sh
supabase db push
```

Migrace automaticky schválí všechny účty, které existují v okamžiku nasazení. Potom lze nasadit obsah větve na GitHub Pages.

## Schválení nového uživatele

V Supabase SQL Editoru spusť jako správce:

```sql
insert into public.chat_members (user_id)
select id
from auth.users
where lower(email) = lower('uzivatel@example.com')
on conflict (user_id) do nothing;
```

Odebrání přístupu:

```sql
delete from public.chat_members
where user_id = (
    select id
    from auth.users
    where lower(email) = lower('uzivatel@example.com')
);
```

## Realtime

Tabulky `messages` a `reactions` musí zůstat přidané v publikaci `supabase_realtime`. Projekt je již má nastavené. Frontend reaguje na změny přes WebSocket a nepřetěžuje databázi dotazem každé tři sekundy.
