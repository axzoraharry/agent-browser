# Architecture: link booking (a rebuild of the one-on-one scheduling loop)

Reference product: the public one-on-one booking loop mapped in `replica/recon.md`. This is not that product's architecture, name, or API. Calendar and payment calls go to Google, Microsoft, and Stripe with the host's own keys.

## Stack

| layer | choice | why |
| --- | --- | --- |
| web | Next.js (App Router) + TypeScript | One app for the host UI and the public booking page. Server actions keep the service-role key off the client. |
| styling | Tailwind, tokens from replica-design | Utility CSS is enough until the design skill names the real tokens. |
| database | Postgres on Supabase | One database. Exclusion constraints can stop double booking. Row level security matches host-owned rows. |
| ORM | Drizzle | SQL migrations stay in this repo. `replica/schema.sql` is the first one. |
| auth | Supabase Auth | Email login for hosts. Guests have no account. |
| payments | Stripe Checkout | A should-have. Checkout redirects back; the webhook confirms the pending hold. |
| email | Resend | Transactional mail for confirm, reschedule, cancel, and reminders. |
| jobs | Inngest | Retries for mail, hold expiry, and calendar push renewal. Vercel Cron only wakes a route; it does not retry. |
| files | none in this slice | No uploads in the recon. Add Supabase Storage only if a later screen needs one. |
| hosting | Vercel | Fits Next.js. The database stays on Supabase. |

One database. No microservices. The mobile app is out of this slice; the booking page is responsive.

## Schema

Tables: 12. Access rules: row level security for host-owned rows. Guests never receive table grants. Booking, reschedule, and cancel run as `security definer` functions called by the server with the service role, after the route has checked the schedule and the manage token. SQL: `replica/schema.sql`.

| table | owns | on delete |
| --- | --- | --- |
| profiles | the host, keyed to `auth.users` | cascade from auth |
| calendar_connections | OAuth ciphertext for Google or Microsoft | cascade with the host |
| external_calendars | which calendars block time, which one receives the event | cascade with the connection |
| schedules | weekly hours in one time zone | cascade with the host |
| schedule_rules | weekday minute ranges | cascade with the schedule |
| schedule_overrides | a date that is closed or has custom hours | cascade with the schedule |
| event_types | the public meeting definition | restrict if bookings exist (`schedule_id` is restrict; host delete cascades) |
| booking_questions | extra form fields | cascade with the event type |
| bookings | one guest hold or confirmed meeting | restrict on event type, cascade with the host |
| notifications | mail and SMS rows, one per send | cascade with the booking |
| single_use_links | a token that dies after one booking | cascade with the event type |
| webhook_events | Stripe and calendar push ids already handled | service role only |

The overlap rule is an exclusion constraint on `bookings`, not a check in the UI:

```sql
exclude using gist (
  host_id with =,
  tstzrange(blocked_start, blocked_end, '[)') with &&
) where (status in ('pending', 'confirmed'))
```

`blocked_start` and `blocked_end` include the event type's buffers at insert time, so a later buffer edit does not rewrite old meetings. `pending` counts, so two guests cannot hold the same interval. A reschedule sets the old row to `rescheduled` and inserts the new row in one transaction. If the new row collides, the transaction rolls back and the old meeting stays `confirmed`.

Times are `timestamptz` (UTC). Money is integer cents plus `currency`. Manage links store a hash, not the raw token.

## API

Official APIs only: Google Calendar, Microsoft Graph, Stripe, Resend. Never the reference product's endpoints.

| method path | does | who | input | output | flow |
| --- | --- | --- | --- | --- | --- |
| POST /api/auth/sign-up | create host profile and a default schedule | public | email, password, handle, time zone | session | F01 S01 |
| POST /api/auth/sign-in | host session | public | email, password | session | F01 |
| POST /api/auth/sign-out | end session | host | session | ok | |
| GET /api/oauth/google/start | start Google Calendar consent | host | return path | redirect | F01 S02 |
| GET /api/oauth/google/callback | store the connection, list calendars | host | code, state | connection id | F01 S02 |
| GET /api/oauth/microsoft/start | start Microsoft consent | host | return path | redirect | F01 S02 |
| GET /api/oauth/microsoft/callback | store the connection, list calendars | host | code, state | connection id | F01 S02 |
| PATCH /api/external-calendars/:id | set conflict and destination flags | host | two booleans | calendar | F01 S02 |
| DELETE /api/calendar-connections/:id | revoke a connection | host | id | ok | S02 |
| PUT /api/schedules/:id | rename, set the schedule time zone | host | name, time zone | schedule | F01 S07 |
| PUT /api/schedules/:id/rules | replace weekly ranges | host | weekday, start minute, end minute | rules | F01 S07 |
| PUT /api/schedules/:id/overrides | replace date overrides | host | date, unavailable or custom range | overrides | S07 |
| GET /api/event-types | list the host's types, including inactive | host | | types | F01 S03 |
| POST /api/event-types | create a one-on-one type | host | name, slug, duration, location, schedule | type | F01 S04 S05 |
| PATCH /api/event-types/:id | edit settings, active flag, buffers, form, price | host | partial type | type | F01 S05 S06 |
| GET /api/public/:handle/:slug | public event details and questions | anyone | | type, questions | F02 S12 |
| GET /api/public/:handle/:slug/slots | open slots in a guest time zone | anyone | from, to, time zone | slots | F02 F03 S12 S15 |
| POST /api/public/bookings | hold or confirm a slot | anyone | start, name, email, time zone, answers, idempotency key | booking id, manage path | F02 S13 S14 |
| GET /api/public/manage/:token | booking summary for the guest | token holder | | time, status, policy | F03 F04 S14 S15 S16 |
| POST /api/public/manage/:token/reschedule | move the meeting | token holder | new start, idempotency key | new booking | F03 S15 |
| POST /api/public/manage/:token/cancel | cancel and free the slot | token holder | optional reason | ok | F04 S16 |
| GET /api/bookings | host timeline, upcoming and past | host | from, to, query | bookings | F05 S08 |
| POST /api/bookings/:id/reschedule | host moves a meeting | host | new start | booking | F05 S09 |
| POST /api/bookings/:id/cancel | host cancels | host | optional reason | ok | F05 S09 |
| GET /api/event-types/:id/troubleshoot | why a time is closed | host | start | reasons | F06 S10 |
| POST /api/event-types/:id/single-use-links | mint a one-shot link | host | optional expiry | path | S11 |
| POST /api/webhooks/stripe | confirm or expire a paid hold | Stripe | signed event | ok | S13 |
| POST /api/webhooks/google | calendar changed; recheck overlaps | Google | channel headers | ok | F05 |

Webhooks in: Stripe Checkout (`checkout.session.completed`, `checkout.session.expired`), Google Calendar push. Microsoft change notifications land on the same shape later. Webhooks out: none. Creating the calendar event and sending mail are outbound API calls, not webhooks.

Jobs:

| job | schedule | does |
| --- | --- | --- |
| expire-holds | every minute | `pending` rows past `hold_expires_at` become `expired`, which drops them from the exclusion constraint |
| dispatch-notifications | every minute | send queued Resend mail; record `provider_message_id`; retries stay idempotent on `(booking_id, kind, channel, send_at)` |
| renew-calendar-watches | daily | refresh OAuth and renew Google push channels before they lapse |

Confirming a booking enqueues the guest confirmation and the host notice immediately. A reminder row is inserted at confirm time for `start_at` minus the reminder offset.

Slot generation (hours, overrides, minimum notice, window, increment, caps, buffers, local bookings, external busy) lives in the Next.js route, not in SQL. The database only refuses an overlapping insert.

## The parts that bite

- Time zones: weekly rules are minutes in `schedules.time_zone`. Slot instants are UTC. DST is handled by converting that zone with a real tz database, not a fixed offset. A locked event zone ignores the guest's browser zone for in-person meetings. Guest emails print the guest zone.
- Idempotency: `webhook_events (provider, event_id)` ignores a second Stripe or Google delivery. `bookings (host_id, idempotency_key)` ignores a double submit. Notification uniqueness ignores a second enqueue.
- Races: two guests booking one slot hit the exclusion constraint. The loser gets a conflict and the slot list is rebuilt. A busy event that appears on Google between the free/busy read and the insert is not in that constraint. The push job looks for confirmed bookings that now overlap the calendar and emails the host. Do not pretend the UI check is enough.
- Rate limits: Google free/busy and Microsoft `getSchedule` are cached per host for about a minute. The public slots route is cached the same way and does not walk the calendar once per guest click.
- Email deliverability: send from a domain the user verifies in Resend. Confirmation mail is the manage link. There is no SMS provider in the core loop; SMS stays a could-have.
- Multi-tenancy: one host is one `profiles` row. There is no org table in this slice. Team round-robin would add one later.
- GDPR deletion: deleting the auth user cascades host-owned rows. Guest name and email live on `bookings`. A host delete must be an explicit action that also removes those guest fields, not an accident of closing a browser tab.
- Payments: a priced event stays `pending` until Stripe says paid. The hold blocks the slot for 30 minutes. Failure or expiry releases it. The webhook, not the success redirect, flips status to `confirmed`.

## Build order

1. Vertical slice. Ugly end to end, no calendar provider yet. Screens S01, S03, S04, S05, S07, S12, S13, S14, S08. Tables `profiles`, `schedules`, `schedule_rules`, `event_types`, `bookings`, `notifications`. Routes sign-up, event-type create, public slots, book, meetings list. Proves auth, the exclusion constraint, and one confirmation email. Busy time is only other bookings.
2. Must-haves. S02 calendar connect and conflict checks. Date overrides. Event on/off. Guest reschedule and cancel (S15, S16) and host cancel (S09). Guest time zone override. External busy times included in the slot route.
3. Should-haves. Buffers, caps, minimum notice, booking window, increments, custom questions, reminders, video location, Stripe, troubleshoot (S10), single-use links, cancellation policy text, locked time zone.
4. Fixes from replica-entrepreneur. None yet. That skill has not run. Do not invent review complaints here.

## Summary

Next.js and TypeScript on Vercel, Postgres and auth on Supabase, Drizzle, Resend, Stripe, Inngest. 12 tables, 28 routes. Riskiest parts: the overlap constraint together with external calendars, time zones and daylight saving, and webhook idempotency on paid holds. Next step: `/replica-design`.
