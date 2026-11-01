# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/lucida"

DATA = ENV["LUCIDA_TESTDATA"] || File.expand_path("../../../testdata", __dir__)
def load_json(path) = JSON.parse(File.read(File.join(DATA, path)))

CTX_FIELDS = {
  "distinct_id" => %w[distinct_id bucketing_key], "groups" => %w[groups], "person_properties" => %w[person_properties],
  "group_properties" => %w[group_properties], "device_properties" => %w[device_properties],
  "geo_properties" => %w[geo_properties], "app_version" => %w[app_version]
}.freeze

class ConformanceTest < Minitest::Test
  def supplied(vec)
    return vec["context"] unless vec.key?("needs")

    keep = vec["needs"].flat_map { |n| CTX_FIELDS.fetch(n, []) }
    vec["context"].select { |k, _| keep.include?(k) }
  end

  def check(name)
    d = load_json("flags/#{name}")
    d["hash_vectors"].each { |h| assert_equal h["hash"], Lucida::Evaluator.hash01(h["input"]), h["input"] }
    d["vectors"].each do |v|
      r = Lucida::Evaluator.evaluate_all(d["flags"], supplied(v))[v["flag"]]
      e = v["expected"]
      got = [r.value, r.variant, r.payload, r.reason, r.condition_index]
      want = [e["value"], e["variant"], e["payload"], e["reason"], e["condition_index"]]
      assert_equal want, got, v["name"]
    end
    d["vectors"].size
  end

  def test_basic = assert_operator(check("vectors_basic.json"), :>, 20)
  def test_g10 = assert_operator(check("vectors_g10.json"), :>, 15)
  def test_sticky = assert_operator(check("vectors_sticky.json"), :>=, 19)
  def test_ops_v2 = assert_operator(check("vectors_ops.json"), :>=, 100)
  def test_generated = assert_equal(10_000, check("vectors.json"))
end

class ClientTest < Minitest::Test
  def client(**opts)
    @sent = []
    Lucida::Client.new("lc_pk_x", transport: lambda { |url, body, _h|
      @sent << [url, body]
      200
    }, **opts)
  end

  def events = @sent.flat_map { |_, b| JSON.parse(b)["batch"] }

  def test_event_fixtures
    load_json("events/server_sdk.json")["cases"].each do |c|
      lc = client
      call = c["call"]
      case call["method"]
      when "capture"
        lc.capture(call["distinct_id"], call["event"], call["properties"], groups: call["groups"],
                   timestamp: call["timestamp"], uuid: call["uuid"], set: call["set"], set_once: call["set_once"])
      when "identify" then lc.identify(call["distinct_id"], call["properties"], call["properties_set_once"])
      when "alias" then lc.alias(call["distinct_id"], call["alias"])
      else lc.group_identify(call["group_type"], call["group_key"], call["properties"], call["distinct_id"])
      end
      lc.flush
      assert_equal "lc_pk_x", JSON.parse(@sent[0][1])["api_key"], c["name"]
      ev = events.fetch(0)
      props = ev["properties"].dup
      assert props.delete("$lib").start_with?("lucida-")
      assert props.delete("$lib_version")
      ev = ev.merge("properties" => props)
      want = c["expected"].dup
      %w[uuid timestamp].each { |k| want[k] = ev[k] if want[k] == "*" && !ev[k].to_s.empty? }
      assert_equal want, ev, c["name"]
      assert_equal 1, events.size
    end
  end

  def test_batches_at_flush_at_and_bounds_queue
    lc = client(flush_at: 3, max_queue_size: 5)
    7.times { |i| lc.capture("u", "e#{i}") }
    assert_equal [3, 3], @sent.map { |_, b| JSON.parse(b)["batch"].size }
    lc.flush
    assert_equal 7, events.size
  end

  def test_failed_batch_is_kept_for_next_flush
    ok = false
    lc = Lucida::Client.new("k", transport: ->(_u, _b, _h) { ok ? 200 : 503 }, sleeper: ->(_s) {}, flush_interval: 0)
    lc.capture("u", "e")
    refute lc.flush
    ok = true
    assert lc.flush
  end

  def test_local_flags_with_exposure_dedupe
    lc = client
    lc.definitions = load_json("flags/vectors_basic.json")["flags"]
    key = lc.instance_variable_get(:@defs).first["key"]
    lc.get_feature_flag(key, "user-1")
    lc.get_feature_flag(key, "user-1")
    lc.flush
    assert_equal 2, events.count { |e| e["event"].start_with?("$feature_flag_called", "$exposure") }
  end

  def test_disabled_sends_nothing
    lc = client(disabled: true)
    lc.capture("u", "e")
    lc.flush
    assert_empty @sent
    assert_nil lc.get_feature_flag("x", "u")
  end
end
