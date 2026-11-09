# lucida (Ruby)

Server SDK for Lucida, standard library only (Ruby >= 3.1). Pass a `distinct_id` on every call, or set one for the
current request with `Lucida.with_context`.

## Install

From GitHub, [lucidaanalytics/lucida-ruby](https://github.com/lucidaanalytics/lucida-ruby), release `v0.1.0`:

```ruby
# Gemfile
gem "lucida", git: "https://github.com/lucidaanalytics/lucida-ruby.git", tag: "v0.1.0"
```

The release also attaches the built `.gem`. `gem install lucida` / `gem "lucida"` from RubyGems is coming.


```ruby
require "lucida"

lc = Lucida::Client.new("lc_pk_...", host: "https://capture.lucidace.com", secret_key: "lc_sk_...")
lc.capture("u1", "purchase", { "total" => 12 }, groups: { "company" => "acme" })
lc.identify("u1", { "plan" => "pro" })
lc.alias("u1", "anon-9")
lc.group_identify("company", "acme", { "seats" => 5 })
lc.is_feature_enabled("new-checkout", "u1", person_properties: { "plan" => "pro" })
lc.shutdown # stops the threads and flushes
```

## Delivery

- Events queue in memory (bounded by `max_queue_size`, oldest dropped, counted in `dropped_events`). A background
  thread flushes every `flush_interval` seconds (default 5, `0` disables it); reaching `flush_at` (20) also flushes.
  One request carries at most `max_batch_size` (100) events. `sync_mode: true` sends each event inline (no queue, no thread).
- Failures retry with exponential backoff and jitter (`max_retries: 3`, `retry_delay: 0.5`), honoring `Retry-After`
  (capped at 60 s). Retryable: network errors, 408, 429, 5xx. After the retries a batch stays queued for the next flush;
  other 4xx batches are dropped. Both report through `on_error: ->(err) { ... }` (`err.status`, `err.message`).
- `before_send: ->(event) { ... }` runs per event; return the (modified) event, `nil` to drop it. If it raises, the original event is sent.
- `timeout:` (seconds, default 10) for connect and read; `debug: true` (or `logger:`) logs to stderr.
- Bodies over 1 KB are gzipped (`?compression=gzip`). `disabled: true` sends nothing.
- Personless events: `lc.capture(nil, "pageview", process_person_profile: false)` sends `$process_person_profile: false`
  and generates a random UUID distinct id when none is given.
- Historical import with the secret key: `lc.import_events([{ distinct_id: "u", event: "old", timestamp: "2020-01-01T00:00:00Z" }])`
  posts to `/v1/s2s/batch` in chunks of 1000 and raises `Lucida::Error` on a rejected chunk.

### Forking servers

Threads do not survive `fork`. Puma cluster / Unicorn / Spring: call `Lucida.client.after_fork` (or `Lucida.after_fork`
after setting `Lucida.client = lc`) in `on_worker_boot` / `after_fork`. The child drops the parent's queue and restarts the
threads. The client also notices a changed pid on the next `capture`.

## Request context

```ruby
Lucida.with_context(distinct_id: "u1", session_id: "s1", properties: { "tenant" => "acme" }) do
  lc.capture(nil, "clicked")          # distinct_id, $session_id and tenant come from the context
  lc.capture("other", "clicked")      # explicit arguments win
end
Lucida.with_context(fresh: true, distinct_id: "x") { ... } # ignores the enclosing context
Lucida.context_from_headers(request.headers) # => { distinct_id:, session_id: } from X-Lucida-Distinct-Id / X-Lucida-Session-Id
```

The stack is Thread/Fiber-local. The tracing headers are client-controlled (stripped of control characters, capped at
1000 chars): never use them for authentication or authorization. Accepts a header Hash or a Rack env.

## Flags

- Definitions load from `/v1/flags/definitions` (needs `secret_key`) on a poll thread every `flag_poll_interval` seconds
  (default 30, `0` disables), reusing the ETag. `reload_feature_flags` fetches on demand.
- Flags the definitions cannot decide (cohorts, no definitions yet) fall back to `POST /v1/flags`, unless
  `only_evaluate_locally: true` (client option or per call).
- `get_feature_flag`, `is_feature_enabled`, `get_feature_flag_payload`, `get_all_flags`, `get_all_flags_and_payloads`
  (`{"flags" =>, "payloads" =>}`), and `get_feature_flag_result` (a `FlagResult` with `value`, `payload`, `reason`,
  `locally_evaluated`, `request_id`). Single-flag calls record `$feature_flag_called` and `$exposure` once per user, flag and value.

### Fallbacks and details

`Lucida::Client.new("k", fallbacks: { "new-nav" => false, "plan" => "free" })`: when a read fails (network error, no
definitions, quota limit, unknown flag) and the key is listed, the flag returns that value with reason `fallback` and
records no exposure. `get_feature_flag_details(key, id)` (same as `get_feature_flag_result`) returns a `FlagResult` with
`value`, `payload`, `variant`, `reason`, `condition_index`, `request_id` and `locally_evaluated`.

## Test mode

```ruby
lc = Lucida::Client.new("k", test_mode: "flags-fixture.json") # path, {"flags" => [...]} or an Array
lc.capture("u", "e")
lc.sink.events # every captured event (including exposures); nothing is sent, the network is refused
lc.sink.clear
```

`ruby -Ilib -e 'Dir["test/*_test.rb"].each { |f| require "./#{f}" }'` (or `make sdk-ruby`) runs the tests, including the
shared `testdata/flags` conformance vectors (10,000+) and the `testdata/events/server_sdk.json` wire fixtures.

---

This repository is a read-only mirror of the Lucida monorepo (synced by a script, never edited by hand); releases and provenance attestations are built here by GitHub Actions. Issues are welcome, changes land upstream.
