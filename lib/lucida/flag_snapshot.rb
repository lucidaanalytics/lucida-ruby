# frozen_string_literal: true

module Lucida
  # Flags evaluated once for one distinct id. Reads never call the network or emit exposure events.
  class FlagSnapshot
    attr_reader :values, :payloads

    # `$feature/<key>` per flag plus sorted `$active_feature_flags`; caller properties win.
    def self.event_props(props, values)
      return (props || {}).dup if values.empty?

      out = values.to_h { |k, v| ["$feature/#{k}", v] }
      out["$active_feature_flags"] = values.reject { |_, v| v == false }.keys.sort
      out.merge(props || {})
    end

    def initialize(values, payloads = {})
      @values = values.dup
      @payloads = payloads.dup
      @accessed = {}
      @mutex = Mutex.new
    end

    def get_flag(key)
      @mutex.synchronize { @accessed[key] = true }
      @values[key]
    end

    def enabled?(key)
      v = get_flag(key)
      !v.nil? && v != false
    end

    def get_payload(key) = @payloads[key]

    def keys = @values.keys.sort

    def only(keys)
      ks = keys.to_a
      FlagSnapshot.new(@values.slice(*ks), @payloads.slice(*ks))
    end

    def only_accessed = only(@mutex.synchronize { @accessed.keys })

    def event_props(props = nil) = self.class.event_props(props, @values)
  end
end
