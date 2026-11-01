# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/lucida"

# Snapshot / event enrichment / definition cache / remote-config payload (LC-FLG-28, 29, 45, 46).
class FlagsDepthTest < Minitest::Test
  def on(key, *ctxs, pct: 100)
    { "key" => key, "type" => "boolean", "active" => true, "salt" => "s", "aggregation" => { "kind" => "person" },
      "app_contexts" => ctxs, "conditions" => [{ "rollout_pct" => pct }] }
  end

  def flags = [on("a"), on("b"), on("off", pct: 0), on("web", "web")]

  def test_snapshot_and_enrichment
    lc = Lucida::Client.new("lc_pk_x", secret_key: "lc_sk_x", test_mode: flags, app_contexts: ["api"])
    lc.capture("u", "buy", { "$feature/a" => "mine" }, send_feature_flags: true)
    snap = lc.evaluate_flags("u")
    assert snap.enabled?("a")
    assert_equal %w[a b off], snap.keys
    lc.capture("u", "e1", flags: snap.only_accessed)
    p0 = lc.sink.events[0]["properties"]
    p1 = lc.sink.events[1]["properties"]
    assert_equal "mine", p0["$feature/a"]
    assert_equal false, p0["$feature/off"]
    refute p0.key?("$feature/web")
    assert_equal %w[a b], p0["$active_feature_flags"]
    assert_equal true, p1["$feature/a"]
    refute p1.key?("$feature/b")
    assert(lc.sink.events.none? { |e| e["event"] == "$feature_flag_called" })
  end

  def test_event_props_caller_wins
    assert_equal({ "x" => 1 }, Lucida::FlagSnapshot.event_props({ "x" => 1 }, {}))
    out = Lucida::FlagSnapshot.event_props({ "$active_feature_flags" => [] }, { "a" => "v" })
    assert_equal [], out["$active_feature_flags"]
  end

  def test_definition_cache_adopts_and_publishes
    cache = Lucida::FlagCache::InMemory.new(ttl: 60)
    cache.on_flag_definitions_received(flags)
    calls = 0
    lc = Lucida::Client.new("k", secret_key: "s", flag_poll_interval: 0, flush_interval: 0, flag_definition_cache: cache,
                                 transport: ->(_u, _b, _h) { calls += 1 })
    assert lc.reload_feature_flags
    assert_equal 0, calls
    assert_equal true, lc.get_feature_flag("a", "u", only_evaluate_locally: true)

    fresh = Lucida::FlagCache::InMemory.new(ttl: 60)
    body = JSON.generate("flags" => flags.first(1))
    lc2 = Lucida::Client.new("k", secret_key: "s", flag_poll_interval: 0, flush_interval: 0, flag_definition_cache: fresh,
                                  transport: ->(_u, _b, _h) { [200, nil, body, nil] })
    assert lc2.reload_feature_flags
    assert_equal 1, fresh.flag_definitions.size
  end

  def test_broken_cache_means_fetch
    broken = Object.new
    def broken.should_fetch_flag_definitions? = raise("down")
    assert_nil Lucida::FlagCache.adopt(broken)
  end

  def test_remote_config_payload
    calls = []
    resp = JSON.generate("key" => "a/b", "enabled" => true, "payload" => { "x" => 1 })
    transport = lambda do |u, b, h|
      calls << [u, b, h]
      u.end_with?("/v1/flags/a%2Fb/remote-config") ? [200, nil, resp, nil] : [404, nil, "", nil]
    end
    lc = Lucida::Client.new("k", secret_key: "sk", flag_poll_interval: 0, flush_interval: 0, transport: transport)
    assert_equal({ "x" => 1 }, lc.get_remote_config_payload("a/b"))
    u, b, h = calls.last
    assert_nil b # GET
    assert_equal "Bearer sk", h["Authorization"]
    assert u.end_with?("/v1/flags/a%2Fb/remote-config")
    assert_nil lc.get_remote_config_payload("nope")
    assert_raises(ArgumentError) { Lucida::Client.new("k", flush_interval: 0).get_remote_config_payload("cfg") }
  end
end
