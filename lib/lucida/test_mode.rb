# frozen_string_literal: true

require "json"

module Lucida
  # Offline test mode: fixture definitions, an in-memory sink and a transport that refuses the network.
  class Sink
    attr_reader :events

    def initialize = @events = []
    def add(event) = @events << event
    def clear = @events.clear
  end

  module TestMode
    module_function

    # fixture: path to a `lucida flags fixture` file, a {"flags" => [...]} Hash, or an Array of definitions.
    def load_fixture(src)
      body = src.is_a?(String) || src.respond_to?(:to_path) ? JSON.parse(File.read(src)) : src
      flags = body.is_a?(Hash) ? body["flags"] : body
      raise ArgumentError, 'test_mode fixture must be {"flags" => [...]} or a list of definitions' unless flags.is_a?(Array)

      flags
    end

    def no_network = ->(_url, _body, _headers) { raise "network disabled in test_mode" }
  end
end
