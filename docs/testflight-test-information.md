# TestFlight Test Information

Copy-paste for App Store Connect → TestFlight → Test Information. Fields marked
**[you]** need something only you can supply.

---

## Beta App Description

> ParkMax keeps track of the parks you've been to.
>
> It finds parks near you on the map, lets you log a visit with photos, notes and a
> rating, and works out how much of a city or county you've actually explored — a real
> percentage, counted against every park an exhaustive search of that place found, rather
> than against however far you happened to wander.
>
> You can share a six-character code with friends to compare progress, race each other to
> finish a city, and see where they've been. Everything you log stays on your device and
> in your own iCloud; only what you choose to share with friends leaves it.
>
> No account, no sign-up, no ads.

## What to Test

> **Logging visits.** Find a park, log a visit, attach a photo or a video. Check that
> ratings, notes and companions come back the way you left them.
>
> **The map and scanning.** Pan somewhere new and let it search. Anything it files that
> obviously isn't a park — a car park, a lawn, a private garden — can be struck off from
> the park's own page, and shouldn't come back on the next sweep.
>
> **Backups.** Settings → Data → Create a backup, then Import it. Everything should come
> back: parks, visits, photos, the places you've struck off, your saved places. Tell us
> immediately if anything is missing after a restore.
>
> **Friends.** Settings has a six-character code. Swap it with another tester, then check
> the leaderboard, the feed, and Race a place. The races should list nearest first.
>
> **Storage.** Settings → Data → tap the Photos & video figure. It should roughly match
> what you'd expect from the photos you've attached.
>
> Known: the first time you open Friends after logging a lot, it spends a while preparing
> and uploading photos. It should tell you it's doing that, with a progress bar.

## Feedback Email

**[you]** — where tester feedback and screenshots land.

## Contact Information

**[you]** — first name, last name, email, phone. Goes to Apple's review team, not to
testers. Use someone who can actually answer during review.

## Privacy Policy URL

**[you]** — must be a live URL. See `docs/privacy-policy.md`; publish it with GitHub
Pages and point this at the result.

## Beta App Review Notes

> No account or sign-in is required. Open the app and it works.
>
> **Location:** the app asks for location when in use, and uses it to find parks nearby
> and to measure how far away things are. Denying it doesn't block the app — you can set a
> home location by hand in Settings and everything works from there.
>
> **Network:** park search uses MapKit. Without a connection the app still shows
> everything already saved, but won't find anything new.
>
> **iCloud:** the friends features need the device signed into iCloud. Without it, the
> Friends tab shows clearly-labelled sample data instead, so the screen is still
> explorable. Settings → About reports which state the build is in.
>
> **Photos and camera:** only asked for when attaching media to a visit.
