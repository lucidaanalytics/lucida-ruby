# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/lucida"

class IdentityTest < Minitest::Test
  def client
    @sent = []
    Lucida::Client.new("lc_pk_x", flush_interval: 0, transport: lambda { |_u, body, _h|
      @sent << body
      200
    })
  end

  def events = @sent.flat_map { |b| JSON.parse(b)["batch"] }

  def test_super_properties_per_call_wins_and_unregister
    lc = client
    lc.register("app" => "a", "env" => "prod")
    lc.unregister("env")
    lc.capture("u", "e1")
    lc.capture("u", "e2", { "app" => "mine" })
    lc.flush
    assert_equal "a", events[0]["properties"]["app"]
    refute events[0]["properties"].key?("env")
    assert_equal "mine", events[1]["properties"]["app"]
  end

  def test_person_property_events
    lc = client
    lc.set_person_properties("u", { "plan" => "pro" })
    lc.set_person_properties_once("u", { "first" => "x" })
    lc.flush
    assert_equal({ "plan" => "pro" }, events[0]["$set"])
    assert_equal({ "first" => "x" }, events[1]["$set_once"])
    assert_equal %w[$set $set], events.map { |e| e["event"] }
  end

  def test_identify_and_group_dedupe
    lc = client
    3.times do
      lc.identify("u", { "a" => 1 })
      lc.group_identify("org", "acme", { "n" => 1 })
    end
    lc.identify("u", { "a" => 2 })
    lc.flush
    assert_equal %w[$identify $groupidentify $identify], events.map { |e| e["event"] }
  end
end
