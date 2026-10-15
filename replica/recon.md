# Recon map: Calendly (web)

Scope: the core loop only. A host connects a calendar, sets weekly hours, publishes one one-on-one event type, and shares a link. A guest picks an open slot and books with a name and email, without an account. Both sides are notified. Either side can reschedule or cancel, and the slot frees up.
For: a small-team scheduling product to sell. Not a copy of Calendly's brand, pages, or customer base.
Date: 2026-10-15

No logged-in account was used. Screen routes and states below come from public help articles. Where a state is described but was not opened in a browser, the states column says so. `replica/screens/` has no reference shots yet.

## Sources

| # | source | URL | notes |
| --- | --- | --- | --- |
| 1 | help: create an event type | https://calendly.com/help/how-to-set-up-an-event-type | Scheduling page, editor fields, save, share, calendar connect, buffers, meeting limits, preview troubleshoot |
| 2 | help: customize event types | https://calendly.com/help/how-to-customize-your-event-types | Primary settings vs more options. One event type cannot be converted into another |
| 3 | help: scheduling FAQ | https://calendly.com/help/scheduling-faq | Guest needs no account. Double-book prevention. Buffers. Reminders. Single-use links |
| 4 | help: time zones | https://calendly.com/help/time-zones-overview | Auto-detect, guest override, lock timezone, date-specific hours, DST |
| 5 | help: cancel and reschedule links | https://calendly.com/help/how-to-include-cancel-and-reschedule-links-for-invitees | Links live in the confirmation notification. A written policy does not enforce a cutoff |
| 6 | help: cancellation policy | https://calendly.com/help/how-to-add-a-cancellation-policy | Policy is display text only |
| 7 | help: invitee form | https://calendly.com/help/advanced-booking-form-features | Name and email are required. Extra questions and phone are optional |
| 8 | help: meetings | https://calendly.com/help/how-to-manage-your-meetings | Calendar page, timeline, search, meeting detail |
| 9 | help: reschedule | https://calendly.com/help/how-to-reschedule-a-meeting | Host flow. Free plan drops the host onto the booking page. Paid plans can pick a time or send new times |
| 10 | help: cancel | https://calendly.com/help/how-to-cancel-a-meeting | Confirm dialog, optional message, email to the invitee. External calendar delete can cancel too |
| 11 | help: navigation rename | https://calendly.com/help/meet-the-new-calendly | Meetings page is now Calendar. Scheduling tabs include event types, single-use links, meeting polls, routing forms |
| 12 | help: embed and API | https://calendly.com/help/calendly-embed-and-the-api | Inline, popup widget, popup text. API reads links, users, event types, and scheduled events |
| 13 | pricing | https://calendly.com/pricing | Free is one event type and one calendar. Paid seats gate unlimited types, payments, and multi-person types. Enterprise gates SSO and routing |
| 14 | public API: availability | https://developer.calendly.com/docs/api-guides/view-event-type-and-user-calendar-availability-data | Available times are queried per event type over a bounded window. Busy times are a separate, shorter window |

## Core loop

A host publishes a link to one kind of meeting. A guest opens it, sees only times that are inside the host's hours and free on the host's calendar, and books. The slot is then taken, both people are told, and a link lets the guest move or cancel it.

## Screens

| ID | screen | route / how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S01 | Sign up / log in | marketing site account entry, not opened | Create the host account | email form, OAuth buttons if present | not seen. Hosts need an account; guests do not |
| S02 | Calendar connect | Availability, Calendar settings. Also Settings, Scheduling, Calendars | Let the product read busy time and write new events | provider list (Google, Outlook, Exchange), conflict-calendar picker, destination-calendar picker | disconnected, connected, permission denied (described) |
| S03 | Scheduling home | Scheduling, Event types tab | List the host's event types and the main booking link | event type rows, create button, overflow menu (share, embed), on/off | empty (no types), filled, event off (described) |
| S04 | Create event type | + Create on S03 | Pick a meeting format. One-on-one is the slice | type chooser | not seen as a live screen. Help says the choice is permanent: you create a new type rather than converting |
| S05 | Event editor | open a type from S03, or land here after S04 | Set what the guest will book | name, color, duration, location, availability summary, hosts, live booking-page preview, save | new, saved, validation not seen |
| S06 | More options | bottom of S05 | Rules around the meeting | description, limits and buffers, free/busy rules, booking-page options, invitee form, payment, notifications, confirmation page | sections collapsed. Payment called out as a paid-plan control |
| S07 | Weekly availability | Scheduling, Manage availability. Also the Availability block on S05 | Hours the host is open, in one schedule time zone | day rows, time ranges, time zone dropdown, date-specific hours | default week, a date override (described) |
| S08 | Meetings | Calendar (formerly Meetings) | Upcoming and past bookings | date-grouped timeline, search, filters, meeting row | empty, upcoming, past (described, not seen) |
| S09 | Meeting detail | select a meeting on S08 | Reschedule or cancel as the host | time, invitee, cancel, reschedule, optional message | upcoming. Group events reschedule one invitee at a time (out of slice, noted) |
| S10 | Slot troubleshoot | Preview on an event type, then Troubleshoot | Explain why a time is closed | date/time picker, reason list | a blocked time with reasons (described) |
| S11 | Share | overflow menu on S03, or the home booking link | Hand the guest a URL | copy link, single-use link, add to website | not seen |
| S12 | Public booking page | the shared link, no login | Show open days and times in the guest's zone | month or week calendar, slot list, time zone dropdown, event name, duration, location | slots available, no slots this week, event off, timezone changed (described) |
| S13 | Guest details | next step on S12 after a slot is chosen | Collect who is booking | name, email, optional questions, phone if the location is a call | empty, filled, email invalid (invalid not seen) |
| S14 | Confirmation | after a successful book | Tell the guest the time is held | time in the guest zone, calendar add, reschedule and cancel links when enabled | success. Slot-taken-mid-submit not described as its own screen; treat it as an error on S13 |
| S15 | Guest reschedule | link in the confirmation email | Pick a new open slot without an account | same slot picker as S12, then confirm | open slots, no slots |
| S16 | Guest cancel | link in the confirmation email | Drop the meeting and free the slot | policy text if set, confirm, optional reason | confirm, done (done inferred) |

## Flows

```
F01 Host publishes a one-on-one link
    S01 -> S02 -> S07 -> S04 -> S05 -> S03 -> S11
    happy path clicks: about 12 (estimate; signup and OAuth consent not counted)
    edge: calendar permission denied, no hours set, event left off, only one event type on the free plan

F02 Guest books a time
    S12 -> S13 -> S14
    happy path clicks: 4 (day, slot, submit, plus the link open)
    edge: no slots this week, guest zone differs from host zone, slot taken while the form is open, event turned off, email missing

F03 Guest reschedules
    email link -> S15 -> S14
    happy path clicks: 3
    edge: old slot must free only after the new one is held, no remaining slots, link opened twice

F04 Guest cancels
    email link -> S16
    happy path clicks: 2
    edge: already canceled, policy text is shown but does not block the cancel

F05 Host moves or cancels
    S08 -> S09
    happy path clicks: 3 (open calendar, open meeting, confirm)
    edge: free plan reschedule sends the host through the public booking page; paid plan can assign a time. External calendar delete also cancels

F06 Host explains a closed slot
    S05 preview -> S10
    happy path clicks: 3
    edge: closed because of a calendar conflict, a buffer, a meeting limit, minimum notice, or the event being off
```

## Components

| component | variants | states | used on |
| --- | --- | --- | --- |
| Button | primary, secondary, ghost, danger | default, hover, focus, disabled, loading | all |
| Text field | name, email, long text, phone | empty, filled, error | S13, S16, S06 questions |
| Select | time zone, duration, location kind, calendar | closed, open, selected | S02, S05, S07, S12 |
| Toggle | event active, include cancel links, meeting limits, lock timezone | on, off | S03, S06 |
| Weekly hours editor | one range per day, add range | empty day, one range, several ranges | S07 |
| Date override | unavailable, custom hours | none, one date, a range | S07 |
| Slot list | times in the guest zone | loading, slots, none this day | S12, S15 |
| Month pager | previous, next | current month, past days disabled | S12, S15 |
| Event type row | one-on-one in this slice | active, off | S03 |
| Preview pane | booking page as the guest sees it | updates as S05 changes | S05 |
| Banner | plan limit, connect calendar | info, warning | S02, S03, S06 |
| Dialog | cancel confirm, reschedule choice | open, submitting | S09, S16 |
| Toast | link copied, saved | success, error | S05, S11 |

## Inferred data model

```
User        id, email, time_zone, created_at
            evidence: hosts have accounts; time zone is set at signup and editable in profile (source 4)
            confidence: high

CalendarConnection
            id, user_id, provider (google | outlook | exchange),
            conflict_calendar_ids, destination_calendar_id, status
            evidence: S02 steps in source 1
            confidence: high

Schedule    id, user_id, time_zone, weekly_rules, date_overrides
            evidence: Manage availability, one time zone per schedule, date-specific hours (source 4)
            confidence: high

EventType   id, user_id, schedule_id, name, color, duration_min,
            location_kind (video | phone | in_person | other),
            location_detail, active, slug,
            buffer_before_min, buffer_after_min,
            max_per_day, max_per_week, max_per_month,
            min_notice_min, booking_window,
            start_increment_min, timezone_locked,
            cancellation_policy
            evidence: sources 1, 2, 4, 5. Numeric fields for notice and window are implied by the FAQ, not given as column names
            confidence: medium

BookingQuestion
            id, event_type_id, label, kind, required, position
            evidence: invitee form, source 7. Name and email exist even with no custom questions
            confidence: high

Booking     id, event_type_id, start_at, end_at,
            guest_name, guest_email, guest_timezone,
            status (confirmed | cancelled | rescheduled),
            answers (json), cancel_reason,
            reschedule_token, cancel_token
            evidence: S13 fields, S14, S15, S16, sources 5 and 7
            confidence: high on the fields guests type; medium on token shape (links exist, format was not read)

Notification
            id, booking_id, kind (confirmation | reschedule | cancel | reminder),
            channel (email | sms), send_at, status
            evidence: FAQ and notification settings. SMS is mentioned, not specified
            confidence: medium
```

Relationships: User 1-n CalendarConnection, User 1-n Schedule, User 1-n EventType, Schedule 1-n EventType, EventType 1-n BookingQuestion, EventType 1-n Booking, Booking 1-n Notification.

Invariant, high confidence: two confirmed bookings for the same host cannot overlap, and a slot that is busy on a conflict calendar, inside a buffer, past a meeting cap, or inside minimum notice is not offered. Reschedule frees the old interval only when the new one is confirmed.

## Feature matrix

See `features.csv`. Must: 14, should: 12, could: 6, skip: 7.

## Out of scope (cannot or should not be cloned)

- Calendly's name, logo, colors, marketing copy, and help-center text.
- The existing user network, marketplace of third-party apps, and partner embeds.
- Salesforce and Dynamics routing, SSO, SAML, domain control, audit logs, and the data-deletion API.
- Admin-managed event types and org roles.
- Group, collective, and round-robin meetings, except as later could-haves. This slice is one host, one guest.
- Meeting polls and routing forms.
- Browser extensions.
- Whatever a logged-in account would show that these public articles do not describe.

## Size

Screens 16, flows 6, entities 8. Hard parts: calendar free/busy without double booking, time zones and daylight saving, holding a slot across the form submit, and email (plus optional SMS) delivery. Size: M. A weekend can fake the booking page. The conflict rules and reschedule links are the part that takes weeks. This is not a promise of parity with the whole product.
