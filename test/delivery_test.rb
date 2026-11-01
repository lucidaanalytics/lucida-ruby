# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "zlib"
require_relative "../lib/lucida"

# Delivery, flag fallback, context, personless, import and test-mode behaviour (no threads unless asked).
class DeliveryTest < Minitest::Test
  def client(statuses = nil, **opts)
    @calls = []
    @sleeps = []
    Lucida::Client.new("lc_pk_x", flush_interval: 0, flag_poll_interval: 0, sleeper: ->(s) { @sleeps << s },
                                  transport: lambda { |url, body, headers|
                                    @calls << [url, body, headers]
                                    statuses ? statuses.shift || 200 : 200
                                  }, **opts)
  end

  def body_json(b) = JSON.parse(b.start_with?("{") ? b : Zlib.gunzip(b))

  def sent = @calls.flat_map { |_, b, _| b ? (body_json(b)["batch"] || []) : [] }

  def test_retries_with_backoff_and_honors_retry_after
    lc = client([[429, 7.0], 503, 200])
    lc.capture("u", "e")
    assert lc.flush
    assert_equal 3, @calls.size
    assert_operator @sleeps[0], :>=, 7.0
    assert_operator @sleeps[1], :<=, 1.0
  end

  def test_gives_up_after_max_retries_and_keeps_batch_and_reports
    errs = []
    lc = client([503] * 10, max_retries: 2, on_error: ->(e) { errs << e })
    lc.capture("u", "e")
    refute lc.flush
    assert_equal 3, @calls.size
    assert_equal 503, errs.last.status
  end

  def test_permanent_4xx_drops_without_retry
    errs = []
    lc = client([400], on_error: ->(e) { errs << e })
    lc.capture("u", "e")
    assert lc.flush
    assert_equal 1, @calls.size
    assert_match(/dropped/, errs.last.message)
    assert lc.flush
    assert_equal 1, @calls.size
  end

  def test_before_send_drop_modify_and_raise
    lc = client(before_send: lambda { |e|
      case e["event"]
      when "drop" then nil
      when "boom" then raise "x"
      else e.merge("event" => "renamed")
      end
    })
    %w[drop boom ok].each { |n| lc.capture("u", n) }
    lc.flush
    assert_equal %w[boom renamed], sent.map { |e| e["event"] }
  end

  def test_max_batch_size_is_separate_from_flush_at
    lc = client(flush_at: 100, max_batch_size: 2)
    5.times { |i| lc.capture("u", "e#{i}") }
    lc.flush
    assert_equal [2, 2, 1], @calls.map { |_, b, _| body_json(b)["batch"].size }
  end

  def test_sync_mode_sends_inline
    lc = client(sync_mode: true)
    lc.capture("u", "e")
    assert_equal 1, sent.size
  end

  def test_background_flush_thread
    lc = client(flush_interval: 0.05)
    lc.capture("u", "e")
    sleep 0.4
    assert_equal 1, sent.size
    lc.shutdown
  end

  def test_after_fork_resets_state_and_restarts_thread
    lc = client(flush_interval: 0.05)
    lc.capture("u", "e")
    lc.after_fork
    assert_equal 0, lc.instance_variable_get(:@queue).size
    lc.capture("u", "e2")
    sleep 0.4
    assert_equal ["e2"], sent.map { |e| e["event"] }
    lc.shutdown
  end

  def test_context_merge_and_explicit_wins
    lc = client
    Lucida.with_context(distinct_id: "ctx", session_id: "s1", properties: { "a" => 1 }) do
      Lucida.with_context(properties: { "b" => 2 }) do
        lc.capture(nil, "x", { "a" => 9 })
        lc.capture("explicit", "y")
      end
      Lucida.with_context(fresh: true, distinct_id: "f") { lc.capture(nil, "z") }
    end
    lc.capture(nil, "dropped")
    lc.flush
    x, y, z = sent
    assert_equal ["ctx", 9, 2, "s1"], [x["distinct_id"], x["properties"]["a"], x["properties"]["b"], x["properties"]["$session_id"]]
    assert_equal "explicit", y["distinct_id"]
    assert_nil z["properties"]["$session_id"]
    assert_equal 3, sent.size
    assert_empty Lucida::Context.stack
  end

  def test_context_from_headers
    h = Lucida.context_from_headers("X-Lucida-Distinct-Id" => " u\x01 1 ", "HTTP_X_LUCIDA_SESSION_ID" => "")
    assert_equal({ distinct_id: "u 1", session_id: nil }, h)
    rack = Lucida.context_from_headers("HTTP_X_LUCIDA_SESSION_ID" => "s" * 2000)
    assert_equal 1000, rack[:session_id].size
  end

  def test_personless_generates_uuid_and_flags_property
    lc = client
    lc.capture(nil, "p", process_person_profile: false)
    lc.capture("u", "q", process_person_profile: false)
    lc.flush
    a, b = sent
    assert_match(/\A\h{8}-\h{4}-4\h{3}-\h{4}-\h{12}\z/, a["distinct_id"])
    assert_equal false, a["properties"]["$process_person_profile"]
    assert_equal "u", b["distinct_id"]
  end

  def test_import_events_uses_secret_and_chunks
    lc = client(secret_key: "lc_sk_x")
    n = lc.import_events((1..1500).map { |i| { distinct_id: "u", event: "old", timestamp: "2020-01-01T00:00:00Z", uuid: "id#{i}" } })
    assert_equal 1500, n
    assert(@calls.all? { |u, _, h| u.include?("/v1/s2s/batch") && h["Authorization"] == "Bearer lc_sk_x" })
    assert_equal 2, @calls.size
    assert_equal "2020-01-01T00:00:00Z", sent.first["timestamp"]
    assert_raises(Lucida::Error) { client.import_events([]) }
  end

  def test_import_failure_raises
    lc = client([500, 500, 500, 500, 500], secret_key: "k")
    assert_raises(Lucida::Error) { lc.import_events([{ distinct_id: "u", event: "e" }]) }
  end

  def test_test_mode_sink_and_no_network
    on = { "key" => "on", "active" => true, "type" => "boolean", "salt" => "s", "conditions" => [{ "rollout_pct" => 100 }] }
    lc = Lucida::Client.new("k", test_mode: { "flags" => [on] })
    lc.capture("u", "e")
    assert_equal ["e"], lc.sink.events.map { |e| e["event"] }
    assert_equal true, lc.get_feature_flag("on", "u")
    assert_nil lc.get_feature_flag("missing", "u")
    assert_equal 2, lc.sink.events.count { |e| e["event"].start_with?("$feature_flag_called", "$exposure") }
    lc.sink.clear
    assert_empty lc.sink.events
  end

  def test_test_mode_fixture_file
    Dir.mktmpdir do |d|
      path = File.join(d, "f.json")
      File.write(path, JSON.generate("flags" => []))
      assert_equal({}, Lucida::Client.new("k", test_mode: path).get_all_flags("u"))
    end
    assert_raises(ArgumentError) { Lucida::Client.new("k", test_mode: { "nope" => 1 }) }
  end
end

class FlagFallbackTest < Minitest::Test
  DEFS = [
    { "key" => "local", "active" => true, "type" => "boolean", "salt" => "s", "conditions" => [{ "rollout_pct" => 100 }] },
    { "key" => "cohorty", "active" => true, "type" => "boolean", "salt" => "s",
      "conditions" => [{ "filters" => [{ "type" => "cohort", "key" => "c1", "op" => "in" }], "rollout_pct" => 100 }] }
  ].freeze

  def client(**opts)
    @posts = []
    remote = JSON.generate("request_id" => "r1", "flags" => { "cohorty" => { "enabled" => true, "value" => "v1", "payload" => { "x" => 1 }, "reason" => "cohort" } })
    lc = Lucida::Client.new("pk", flush_interval: 0, flag_poll_interval: 0, transport: lambda { |url, body, _h|
      @posts << [url, body]
      url.end_with?("/v1/flags") ? [200, nil, remote] : 200
    }, **opts)
    lc.definitions = DEFS
    lc
  end

  def test_undecidable_flag_falls_back_to_remote
    lc = client
    r = lc.get_feature_flag_result("cohorty", "u")
    assert_equal ["v1", { "x" => 1 }, "cohort", false, "r1"], [r.value, r.payload, r.reason, r.locally_evaluated, r.request_id]
    body = JSON.parse(@posts.find { |u, _| u.end_with?("/v1/flags") }[1])
    assert_equal ["u", ["cohorty"]], [body["distinct_id"], body["flag_keys"]]
    assert_equal true, lc.get_feature_flag("local", "u")
    assert_equal 1, @posts.count { |u, _| u.end_with?("/v1/flags") }
  end

  def test_remote_request_carries_anon_distinct_id
    lc = client
    lc.get_feature_flag_result("cohorty", "u", anon_distinct_id: "anon-9")
    body = JSON.parse(@posts.find { |u, _| u.end_with?("/v1/flags") }[1])
    assert_equal "anon-9", body["anon_distinct_id"]
  end

  def test_only_evaluate_locally_never_calls_remote
    lc = client(only_evaluate_locally: true)
    assert_nil lc.get_feature_flag("cohorty", "u")
    assert_empty @posts
    assert_nil client.get_feature_flag("cohorty", "u", only_evaluate_locally: true)
    assert_equal "v1", client.get_feature_flag("cohorty", "u")
  end

  def test_all_flags_and_payloads_merge_remote
    lc = client
    assert_equal({ "local" => true, "cohorty" => "v1" }, lc.get_all_flags("u"))
    assert_equal({ "cohorty" => { "x" => 1 } }, lc.get_all_flags_and_payloads("u")["payloads"])
    assert_equal({ "x" => 1 }, lc.get_feature_flag_payload("cohorty", "u"))
    assert_equal({ "local" => true }, client(only_evaluate_locally: true).get_all_flags("u"))
  end

  def test_remote_failure_is_nil
    lc = Lucida::Client.new("pk", flush_interval: 0, transport: ->(_u, _b, _h) { 500 }, sleeper: ->(_s) {}, flag_poll_interval: 0)
    lc.definitions = DEFS
    assert_nil lc.get_feature_flag("cohorty", "u")
  end

  def test_poll_thread_loads_definitions_and_reuses_etag
    seen = []
    body = JSON.generate("flags" => DEFS)
    lc = Lucida::Client.new("pk", secret_key: "sk", flush_interval: 0, flag_poll_interval: 0.05, transport: lambda { |_u, b, h|
      seen << h["If-None-Match"] if b.nil?
      h["If-None-Match"] ? 304 : [200, nil, body, '"e1"']
    })
    sleep 0.4
    lc.shutdown
    assert_equal true, lc.instance_variable_get(:@defs).any? { |f| f["key"] == "local" }
    assert_nil seen.first
    assert_equal '"e1"', seen.last
  end
end
